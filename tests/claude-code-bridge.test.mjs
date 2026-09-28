import { test } from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HOOK = fileURLToPath(new URL('../claude-code/scripts/hook.mjs', import.meta.url))
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))

/** Run hook.mjs exactly as Claude Code does: JSON on stdin, decision on stdout. */
function hook(env, input) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [HOOK], { env, stdio: ['pipe', 'pipe', 'pipe'] })
    let stdout = ''
    child.stdout.on('data', chunk => { stdout += chunk })
    child.on('error', reject)
    child.on('exit', code => resolve({ code, stdout }))
    child.stdin.end(JSON.stringify(input))
  })
}

function setup(t, extra = {}) {
  const home = mkdtempSync(join(tmpdir(), 'notch-claude-'))
  const env = { ...process.env, BOT_NOTCH_HOME: home, BOT_NOTCH_IDLE_EXIT_MS: '400',
    __CFBundleIdentifier: 'com.apple.Terminal', ...extra }
  delete env.CLAUDE_PLUGIN_OPTION_HELPER_PATH
  const runtime = () => JSON.parse(readFileSync(join(home, 'runtime.json'), 'utf8'))
  const api = async (path, body) => {
    const { origin, token } = runtime()
    const response = await fetch(`${origin}/dsh-notch${path}`, {
      method: body === undefined ? 'GET' : 'POST',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    })
    return { status: response.status, body: await response.json() }
  }
  t.after(async () => {
    try { process.kill(runtime().pid, 'SIGTERM') } catch {}
    await sleep(300)
    rmSync(home, { recursive: true, force: true })
  })
  const base = { session_id: 'sess-1', cwd: '/work/notch', transcript_path: '/dev/null' }
  return { home, env, runtime, api, fire: (hook_event_name, input = {}) => hook(env, { ...base, hook_event_name, ...input }) }
}

async function until(check, ms = 3000) {
  const end = Date.now() + ms
  for (;;) {
    const value = await check()
    if (value) return value
    if (Date.now() > end) throw new Error('timed out')
    await sleep(25)
  }
}

test('hooks start the bridge and drive the helper contract end to end', async t => {
  const f = setup(t)
  assert.equal((await f.fire('SessionStart', { source: 'startup' })).code, 0)
  const runtime = f.runtime()
  assert.match(runtime.origin, /^http:\/\/127\.0\.0\.1:\d+$/)
  assert.equal(runtime.source, 'claude-code')
  assert.equal(statSync(join(f.home, 'runtime.json')).mode & 0o777, 0o600)

  const forbidden = await fetch(`${runtime.origin}/dsh-notch/status`)
  assert.equal(forbidden.status, 403)

  await f.fire('UserPromptSubmit', { prompt: 'Ship the plugin' })
  let status = (await f.api('/status')).body
  assert.deepEqual(status.rows.map(({ title, busy, unread }) => ({ title, busy, unread })),
    [{ title: 'notch · Ship the plugin', busy: true, unread: false }])

  // A PermissionRequest hook blocks until Notch answers, then prints the decision.
  const pending = f.fire('PermissionRequest', { tool_name: 'Bash', tool_input: { command: 'npm publish' } })
  const approval = await until(async () => (await f.api('/status')).body.rows[0]?.approval)
  assert.equal(approval.reason, 'Bash: npm publish')
  assert.equal((await f.api('/approve', { id: approval.id, outcome: 'allowed-once' })).status, 200)
  const decided = await pending
  assert.deepEqual(JSON.parse(decided.stdout), {
    hookSpecificOutput: { hookEventName: 'PermissionRequest', decision: { behavior: 'allow' } } })
  assert.equal((await f.api('/approve', { id: approval.id, outcome: 'allowed-once' })).status, 404)

  // AskUserQuestion is answered with updatedInput.answers.
  const questions = [{ question: 'Release channel?', header: 'Channel', multiSelect: false,
    options: [{ label: 'stable' }, { label: 'beta' }] }]
  const asking = f.fire('PermissionRequest', { tool_name: 'AskUserQuestion', tool_input: { questions } })
  const ask = await until(async () => (await f.api('/status')).body.rows[0]?.ask)
  await f.api('/answer', { id: ask.id, answers: [{ id: '0', selected: ['beta'] }] })
  assert.deepEqual(JSON.parse((await asking).stdout).hookSpecificOutput.decision,
    { behavior: 'allow', updatedInput: { questions, answers: { 'Release channel?': 'beta' } } })

  await f.fire('Stop', { background_tasks: [] })
  status = (await f.api('/status')).body
  assert.equal(status.rows[0].unread, true)
  assert.equal((await f.api('/focus', { sessionId: 'sess-1' })).status, 200)
  assert.equal((await f.api('/focus', { sessionId: 'nope' })).status, 404)
  await f.api('/seen', { sessionId: 'sess-1' })
  assert.deepEqual((await f.api('/status')).body.rows, [])
  // Persisted on a short debounce so a restarted bridge keeps read results read.
  await until(() => { try { return JSON.parse(readFileSync(join(f.home, 'seen.json'), 'utf8'))['sess-1'] > 0 } catch { return false } })

  const diagnostics = (await f.api('/diagnostics')).body
  assert.equal(diagnostics.sessions[0].bundleId, 'com.apple.Terminal')
  assert.equal(diagnostics.sessions[0].pid, process.pid, 'owner is the process that ran the hook')
})

test('an unanswered prompt falls back to Claude Code with no decision', async t => {
  const f = setup(t, { CLAUDE_PLUGIN_OPTION_APPROVAL_WAIT_SECONDS: '0.3' })
  await f.fire('SessionStart', { source: 'startup' })
  const started = Date.now()
  const result = await f.fire('PermissionRequest', { tool_name: 'Bash', tool_input: { command: 'ls' } })
  assert.equal(result.code, 0)
  assert.equal(result.stdout, '')
  assert.ok(Date.now() - started < 3000)
  assert.equal((await f.api('/status')).body.rows.length, 0)
})

test('approval window 0 never holds; a missing bridge never blocks SessionEnd', async t => {
  const f = setup(t, { CLAUDE_PLUGIN_OPTION_APPROVAL_WAIT_SECONDS: '0' })
  const alone = await f.fire('SessionEnd', { end_reason: 'other' })
  assert.equal(alone.code, 0)
  assert.throws(() => f.runtime(), 'SessionEnd does not start a bridge')
  await f.fire('SessionStart', { source: 'startup' })
  assert.equal((await f.fire('PermissionRequest', { tool_name: 'Bash', tool_input: {} })).stdout, '')
  assert.equal((await f.fire('not json at all')).code, 0)
})

test('the bridge exits once no tracked Claude Code process is alive', async t => {
  const f = setup(t)
  const owner = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 60000)'])
  t.after(() => owner.kill())
  // Pretend the hook ran under that short-lived process.
  await f.fire('SessionStart', { source: 'startup' })
  const { pid } = f.runtime()
  await f.api('/hook', { session_id: 'other', hook_event_name: 'SessionStart', claude_pid: owner.pid })
  await f.fire('SessionEnd', { end_reason: 'prompt_input_exit' })
  await sleep(2600)
  assert.doesNotThrow(() => process.kill(pid, 0), 'still serving a live session')
  owner.kill()
  await until(() => { try { process.kill(pid, 0); return false } catch { return true } }, 8000)
})
