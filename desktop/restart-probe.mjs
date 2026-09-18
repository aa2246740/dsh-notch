// Real native helper + disposable sleep processes; never starts DSH or calls a model.
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { once } from 'node:events'
import { mkdtempSync, writeFileSync, rmSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { Writable } from 'node:stream'
import { superviseNotch, processIdentity } from './notch-lifecycle.mjs'

const bin = fileURLToPath(new URL('../macos/.build/release/dsh-notch', import.meta.url))
const delay = ms => new Promise(resolve => setTimeout(resolve, ms))
const logs = new Writable({ write(_chunk, _encoding, callback) { callback() } })
const running = child => child.exitCode === null && child.signalCode === null
async function owner() {
  const child = spawn('/bin/sleep', ['60']); await once(child, 'spawn'); return child
}
async function stop(child) {
  if (!child || !running(child)) return
  const exited = once(child, 'exit'); child.kill('SIGTERM'); await exited
}

for (const gap of [0, 50, 1200]) {
  const root = mkdtempSync(join(tmpdir(), 'notch-restart-'))
  const runtime = join(root, 'runtime.json'), pidPath = join(root, 'helper.pid')
  const children = []
  let first, second, manager
  const writeOwner = child => writeFileSync(runtime, JSON.stringify({ pid: child.pid,
    writtenAt: Date.now(), origin: 'http://127.0.0.1:9', token: 'offline-test' }))
  const launch = (file, args, options) => {
    const child = spawn(file, args, { ...options, env: { ...process.env, DSH_NOTCH_RUNTIME_FILE: runtime } })
    children.push(child); return child
  }
  try {
    first = await owner(); writeOwner(first)
    const old = launch(bin, [], { stdio: 'ignore', detached: true }); await once(old, 'spawn')
    writeFileSync(pidPath, String(old.pid))
    await delay(800)
    assert.equal(processIdentity(old.pid).command, bin)
    await stop(first)
    await delay(gap)
    second = await owner(); writeOwner(second)
    manager = superviseNotch({ bin, pidPath, launch, log: logs, interval: 25 })
    await delay(900)
    const live = children.filter(running)
    assert.equal(live.length, 1, `gap ${gap}: exactly one helper expected`)
    assert.equal(manager.pid, live[0].pid)
    assert.equal(Number(readFileSync(pidPath, 'utf8')), live[0].pid)
    const start = performance.now()
    manager.stop()
    while (children.some(running) && performance.now() - start < 1000) await delay(10)
    assert.equal(children.filter(running).length, 0, 'quit must also close an adopted helper')
    console.log(`PASS restart gap=${gap}ms: one live helper; quit ${(performance.now() - start).toFixed(0)}ms`)
  } finally {
    manager?.stop()
    await Promise.all(children.map(stop))
    await stop(first); await stop(second)
    rmSync(root, { recursive: true, force: true })
  }
}
