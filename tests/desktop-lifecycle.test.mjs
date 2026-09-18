import { test } from 'node:test'
import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { mkdtempSync, writeFileSync, readFileSync, rmSync, unlinkSync, existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { superviseNotch } from '../desktop/notch-lifecycle.mjs'

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))
function fixture(t, initial = 42) {
  const root = mkdtempSync(join(tmpdir(), 'notch-supervisor-'))
  const pidPath = join(root, 'helper.pid'), bin = '/test/dsh-notch'
  const processes = new Map(), killed = [], children = []
  let next = 100
  const live = (pid, stamp = String(pid), command = bin) => processes.set(pid, { state: 'alive', stamp, command })
  if (initial) { live(initial); writeFileSync(pidPath, String(initial)) }
  const probe = pid => processes.get(pid) ?? { state: 'dead' }
  const signal = pid => { killed.push(pid); processes.delete(pid) }
  const launch = () => {
    const child = new EventEmitter(); child.pid = next++
    child.kill = () => { signal(child.pid); child.emit('exit', 0) }
    live(child.pid); children.push(child)
    queueMicrotask(() => child.emit('spawn'))
    return child
  }
  const manager = superviseNotch({ bin, pidPath, interval: 5, log: { write() {} }, probe,
    alive: pid => probe(pid).state, launch, signal })
  t.after(() => { manager.stop(); rmSync(root, { recursive: true, force: true }) })
  return { manager, processes, killed, children, pidPath, live, bin }
}

test('quit also terminates an adopted detached helper, without spawning another', t => {
  const f = fixture(t)
  assert.equal(f.manager.pid, 42)
  f.manager.stop()
  assert.deepEqual(f.killed, [42]); assert.equal(f.children.length, 0)
  assert.equal(existsSync(f.pidPath), false)
})
test('helper exits immediately after being adopted: exactly one replacement is started', async t => {
  const f = fixture(t); f.processes.delete(42)
  await sleep(50)
  assert.equal(f.children.length, 1); assert.equal(f.manager.pid, 100)
  assert.equal(readFileSync(f.pidPath, 'utf8').trim(), '100')
})
test('old PID already dead at startup: new helper starts', async t => {
  const f = fixture(t, 0); await sleep(20)
  assert.equal(f.manager.pid, 100); assert.equal(f.children.length, 1)
})
test('quit during replacement spawn never respawns', async t => {
  const f = fixture(t, 0); f.manager.stop(); await sleep(30)
  assert.equal(f.children.length, 1); assert.deepEqual(f.killed, [100])
})
test('reused PID belonging to another executable is never signalled on quit', t => {
  const f = fixture(t); f.live(42, 'new-process', '/test/unrelated')
  f.manager.stop(); assert.deepEqual(f.killed, [])
})
test('unavailable process visibility never starts a duplicate or kills blindly', async t => {
  const f = fixture(t); f.processes.set(42, { state: 'unknown' })
  await sleep(30); f.manager.stop()
  assert.equal(f.children.length, 0); assert.deepEqual(f.killed, [])
})
test('hot replacement lease prevents an auto-spawn while installer switches PIDs', async t => {
  const f = fixture(t)
  writeFileSync(`${f.pidPath}.updating`, 'installing')
  f.processes.delete(42); await sleep(30)
  assert.equal(f.children.length, 0)
  f.live(71); writeFileSync(f.pidPath, '71'); unlinkSync(`${f.pidPath}.updating`)
  await sleep(30)
  assert.equal(f.manager.pid, 71); assert.equal(f.children.length, 0)
})
test('quit catches a hot replacement written after the last observation', t => {
  const f = fixture(t); f.processes.delete(42); f.live(71); writeFileSync(f.pidPath, '71')
  f.manager.stop(); assert.deepEqual(f.killed, [71])
})
