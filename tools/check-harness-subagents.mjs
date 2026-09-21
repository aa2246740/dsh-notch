/** Offline compatibility probe using the selected Harness's real Cordis and jobs modules. */
import assert from 'node:assert/strict'
import { createRequire, syncBuiltinESMExports } from 'node:module'
import { pathToFileURL } from 'node:url'
import { resolve, join } from 'node:path'
import { mkdtempSync, rmSync } from 'node:fs'
import os from 'node:os'

const harness = process.env.DSHX_HARNESS
if (!harness) throw Error('Set DSHX_HARNESS to the built Harness checkout being audited')
const requireFromHarness = createRequire(resolve(harness, 'packages/jobs/jobs-local/package.json'))
const load = path => import(pathToFileURL(path).href)
const { Context } = await load(requireFromHarness.resolve('@deepseek-ai/cordis'))
const { default: AgentRegistry } = await load(requireFromHarness.resolve('@deepseek-ai/dsh-agent'))
const { default: SessionStore, SessionId } = await load(requireFromHarness.resolve('@deepseek-ai/dsh-session'))
const { default: LocalJobRegistry } = await load(resolve(harness, 'packages/jobs/jobs-local/lib/index.js'))
const { childSessionMeta, subprocessRunHandle } = await load(resolve(harness, 'packages/subagent/subagent/lib/index.js'))

const home = mkdtempSync(join(os.tmpdir(), 'notch-harness-proof-'))
const originalHomedir = os.homedir
os.homedir = () => home
syncBuiltinESMExports()
const { Board } = await import('../src/board.ts')
os.homedir = originalHomedir
syncBuiltinESMExports()

const ctx = new Context(), pending = []
const tick = () => new Promise(resolve => setImmediate(resolve))
const proofs = []
try {
  await ctx.plugin(SessionStore)
  await ctx.plugin(AgentRegistry)
  await ctx.plugin(LocalJobRegistry, {})
  ctx.jobs.attachController('isolated-notch-proof')
  let board
  await ctx.plugin({
    name: 'notch-subagent-proof', inject: ['sessions', 'agents'],
    apply(pluginCtx) { board = new Board(pluginCtx) },
  })
  const rootId = SessionId('session-notched-root')
  const scope = ctx.plugin(() => {})
  const session = ctx.sessions.create(rootId)
  const root = {
    id: rootId, session, ctx: scope.ctx, status: 'idle', options: {},
    whenIdle: () => Promise.resolve(), cancel() {},
    send() {}, followup() {}, inject() {},
    runMaintenance: job => job(new AbortController().signal),
  }
  ctx.agents.register(root)
  const expectedChild = childSessionMeta(root, 1, false)
  assert.equal(expectedChild.parentSession, rootId)
  assert.equal(expectedChild.origin, 'subagent')
  assert.equal(childSessionMeta(root, 1, true).origin, 'subagent')
  proofs.push('official spawn and agent-fork metadata both declare subagent origin')

  let finishRemote
  const result = new Promise(resolve => { finishRemote = resolve })
  pending.push(() => finishRemote({ output: [], stopReason: 'aborted' }))
  const remote = subprocessRunHandle({
    id: SessionId('isolated-remote-run'), result,
    signal: new AbortController().signal, onAbort() {}, requestCancel() {},
    teardown: async () => {},
  })
  assert.equal(remote.localAgent, undefined)
  const id = ctx.jobs.start({
    kind: 'subagent', label: 'offline remote child', owner: root,
    run: () => ({ cancel() {}, done: remote.result.then(value => ({
      status: value.stopReason === 'completed' ? 'completed' : 'killed',
    })) }),
  })
  assert.deepEqual(board.snapshot('').rows.map(r => [r.id, r.busy]), [[rootId, true]])
  assert.equal(ctx.jobs.get(id, root).reported, false)
  proofs.push('real JobRegistry plus remote run keeps idle parent active without consuming notice')

  // A new observer must discover an already-running job without a start event.
  let replacement
  await ctx.plugin({
    name: 'notch-replacement-proof', inject: ['sessions', 'agents'],
    apply(pluginCtx) { replacement = new Board(pluginCtx) },
  })
  assert.equal(replacement.snapshot('').rows[0]?.busy, true)
  proofs.push('late-loaded Board discovers existing remote job')

  ctx.jobs.kill(id, root)
  assert.equal(ctx.jobs.get(id, root).status, 'stopping')
  assert.equal(board.snapshot('').rows[0]?.busy, true)
  finishRemote({ output: [], stopReason: 'aborted' })
  await tick()
  assert.deepEqual(board.snapshot('').rows, [])
  proofs.push('real cancellation stays running through stopping and clears on settlement')

  const fork = ctx.sessions.create(SessionId('session-independent-fork'), {
    seed: [], inheritedEventCount: 0, meta: { parentSession: rootId, isSeeded: true },
  })
  ctx.agents.register({ ...root, id: fork.id, session: fork, status: 'running' })
  const child = ctx.sessions.create(SessionId('session-delegated-fork'), {
    seed: [], inheritedEventCount: 0, meta: childSessionMeta(root, 1, true),
  })
  ctx.agents.register({ ...root, id: child.id, session: child, status: 'running' })
  assert.deepEqual(new Set(board.snapshot('').rows.map(r => r.id)), new Set([rootId, fork.id]))
  proofs.push('actual Session headers distinguish user fork from seeded subagent fork')
  console.log(JSON.stringify({ ok: true, modelCalls: 0, proofs }, null, 2))
} finally {
  for (const finish of pending) finish()
  await tick()
  await ctx.fiber.dispose()
  rmSync(home, { recursive: true, force: true })
}
