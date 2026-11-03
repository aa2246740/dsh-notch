import assert from 'node:assert/strict'
import cp from 'node:child_process'
import { EventEmitter } from 'node:events'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { syncBuiltinESMExports } from 'node:module'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

const dir = mkdtempSync(join(tmpdir(), 'notch-launch-'))
const executable = join(dir, 'dsh-notch-win.exe')
writeFileSync(executable, 'launcher disposal fixture')
process.env.DSH_NOTCH_WIN_EXE = executable
process.env.DSH_NOTCH_WIN_LAUNCH = '1'
Object.defineProperty(process, 'platform', { value: 'win32' })

const launches = []
const kills = []
let tasklist = null
let reportedImage = executable

cp.execFile = (_file, _args, _options, done) => {
  tasklist = done
}
cp.execFileSync = () => {
  if (reportedImage == null) throw new Error('image unavailable')
  return reportedImage
}
cp.spawn = (file, args, options) => {
  const child = new EventEmitter()
  child.pid = 4242
  child.exitCode = null
  child.unrefed = false
  child.killed = false
  child.unref = () => { child.unrefed = true }
  child.kill = () => { kills.push(child.pid); child.killed = true; return true }
  launches.push({ file, args, options, child })
  return child
}
syncBuiltinESMExports()

const { apply } = await import('../windows/launcher/notch-launcher.ts')

function scope() {
  const effects = []
  return {
    effects,
    ctx: { effect: (fn) => effects.push(fn) },
    dispose() {
      for (const effect of effects) effect()?.()
    },
  }
}

async function settle() {
  await new Promise((resolve) => setImmediate(resolve))
}

test('windows launcher stays bound to plugin disposal', async () => {
  const pending = scope()
  apply(pending.ctx)
  assert.equal(typeof tasklist, 'function')
  pending.dispose()
  tasklist(null, '')
  await settle()
  assert.equal(launches.length, 0)
  assert.equal(kills.length, 0)

  launches.length = 0
  kills.length = 0
  reportedImage = executable
  const started = scope()
  apply(started.ctx)
  tasklist(null, '')
  await settle()
  assert.equal(launches.length, 1)
  assert.equal(launches[0].file, executable)
  assert.equal(launches[0].options.detached, true)
  assert.equal(launches[0].options.stdio, 'ignore')
  assert.equal(launches[0].child.unrefed, true)
  started.dispose()
  assert.equal(kills.length, 1)
  assert.equal(launches[0].child.killed, true)

  launches.length = 0
  kills.length = 0
  reportedImage = `\\\\?\\${executable}`
  const extended = scope()
  apply(extended.ctx)
  tasklist(null, '')
  await settle()
  extended.dispose()
  assert.equal(kills.length, 1)

  launches.length = 0
  kills.length = 0
  reportedImage = `${executable}.other`
  const reused = scope()
  apply(reused.ctx)
  tasklist(null, '')
  await settle()
  reused.dispose()
  assert.equal(launches.length, 1)
  assert.equal(kills.length, 0)
  assert.equal(launches[0].child.killed, false)

  launches.length = 0
  kills.length = 0
  reportedImage = null
  const unknown = scope()
  apply(unknown.ctx)
  tasklist(null, '')
  await settle()
  unknown.dispose()
  assert.equal(kills.length, 0)

  launches.length = 0
  const busy = scope()
  apply(busy.ctx)
  tasklist(null, '"dsh-notch-win.exe","1234","Console","1","10 K"')
  await settle()
  busy.dispose()
  assert.equal(launches.length, 0)
  assert.equal(kills.length, 0)
})

test.after(() => {
  rmSync(dir, { recursive: true, force: true })
})
