#!/usr/bin/env node
/**
 * Single entry for every Claude Code hook this plugin registers. Reads the hook
 * input from stdin, makes sure the bridge is running, and forwards the event.
 *
 * Never breaks the session: any failure exits 0 with no output, which leaves
 * Claude Code's own flow (terminal dialogs, questions) untouched.
 */
import { spawn } from 'node:child_process'
import { openSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { alive, claudePid, ensureDir, hostBundleId, paths, readJson } from './lib/runtime.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const files = paths()

function readStdin() {
  return new Promise(resolve => {
    const chunks = []
    process.stdin.on('data', chunk => chunks.push(chunk))
    process.stdin.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
    process.stdin.on('error', () => resolve(''))
  })
}

async function call(runtime, path, body, { method = 'POST', timeoutMs = 3000 } = {}) {
  const response = await fetch(`${runtime.origin}/dsh-notch${path}`, {
    method,
    headers: { authorization: `Bearer ${runtime.token}`, 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    signal: AbortSignal.timeout(timeoutMs),
  })
  if (!response.ok) throw new Error(`bridge ${path} ${response.status}`)
  return response.json()
}

async function reachable(runtime) {
  if (!runtime?.origin || !runtime?.token || !alive(runtime.pid)) return false
  try { return (await call(runtime, '/ping', undefined, { method: 'GET', timeoutMs: 1000 })).ok === true } catch { return false }
}

async function ensureBridge({ start }) {
  const current = readJson(files.runtime)
  if (await reachable(current)) return current
  if (!start) return undefined
  ensureDir(files.dir)
  const out = openSync(files.log, 'a', 0o600)
  const child = spawn(process.execPath, [join(HERE, 'bridge.mjs')], {
    detached: true, stdio: ['ignore', out, out], env: process.env,
  })
  child.unref()
  for (let i = 0; i < 50; i++) {
    await new Promise(resolve => setTimeout(resolve, 100))
    // Either our child or, after losing the lock race to a concurrent hook, the winner.
    const next = readJson(files.runtime)
    if (next && next.pid !== current?.pid && await reachable(next)) return next
  }
  return undefined
}

function approvalWaitMs() {
  const raw = process.env.CLAUDE_PLUGIN_OPTION_APPROVAL_WAIT_SECONDS ?? process.env.DSH_NOTCH_APPROVAL_WAIT_SECONDS
  const seconds = raw === undefined || raw === '' ? 300 : Number(raw)
  return Number.isFinite(seconds) && seconds > 0 ? Math.min(seconds, 3300) * 1000 : 0
}

async function main() {
  const text = await readStdin()
  let input
  try { input = JSON.parse(text) } catch { return }
  if (!input || typeof input.session_id !== 'string') return
  const event = String(input.hook_event_name)
  const enriched = { ...input, at: Date.now(), claude_pid: claudePid(), bundle_id: hostBundleId() }
  // A subagent's prompt text is not the conversation title.
  if (input.agent_id) delete enriched.prompt

  const runtime = await ensureBridge({ start: event !== 'SessionEnd' })
  if (!runtime) return

  if (event === 'PermissionRequest') {
    const waitMs = approvalWaitMs()
    if (!waitMs) return
    const result = await call(runtime, '/hold', { input: enriched, waitMs }, { timeoutMs: waitMs + 5000 })
    if (!result?.decision) return
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: { hookEventName: 'PermissionRequest', decision: result.decision },
    }))
    return
  }
  await call(runtime, '/hook', enriched)
}

main().catch(() => {}).finally(() => process.exit(0))
