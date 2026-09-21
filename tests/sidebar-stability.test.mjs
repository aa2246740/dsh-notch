import { test } from 'node:test'
import assert from 'node:assert/strict'
import { Board } from '../src/board.ts'

function scenario(run) {
  const originalNow = Date.now
  let now = 1_900_000_000_000
  Date.now = () => now
  const sessions = [], agents = new Map()
  const board = new Board({
    sessions: { list: () => sessions }, agents: { get: id => agents.get(id) },
    get() {}, logger: { warn() {} },
  })
  const add = id => {
    const events = [{ type: 'turn/start', time: now }]
    const session = { id, header: {}, snapshotEvents: () => events }
    const agent = { status: 'running' }
    sessions.push(session); agents.set(id, agent)
    return {
      id,
      start() { agent.status = 'running'; events.push({ type: 'turn/start', time: ++now }) },
      finish() { agent.status = 'idle'; events.push({ type: 'turn/end', time: ++now, data: { reason: { kind: 'completed' } } }) },
    }
  }
  const mirror = rows => board.syncSidebar({ clientId: 'app', focused: true, projectionVersion: 2, rows })
  try { run({ board, add, mirror, advance: ms => { now += ms }, rows: () => board.snapshot('').rows }) }
  finally { Date.now = originalNow }
}

test('read completion stays dismissed across repeated heartbeat expiry and recovery', () => scenario(f => {
  const root = f.add('session-heartbeat-read')
  f.rows(); root.finish()
  assert.equal(f.rows()[0].unread, true)
  f.mirror([]) // The user has opened it in DSH.
  for (let cycle = 0; cycle < 8; cycle++) {
    assert.deepEqual(f.rows(), [])
    f.advance(5_100)
    assert.deepEqual(f.rows(), [], 'expiry must not resurrect an acknowledged completion')
    f.mirror([])
  }
}))

test('loaded completion observed only through the browser survives an idle heartbeat', () => scenario(f => {
  const root = f.add('session-heartbeat-loaded')
  root.finish() // Notch was mounted after the turn, so no running edge was observed.
  f.mirror([{ id: root.id, title: 'Finished', running: false, completed: true }])
  assert.equal(f.rows()[0].unread, true)
  f.advance(60_000)
  assert.equal(f.rows()[0]?.unread, true)
  f.mirror([])
  f.advance(60_000)
  assert.deepEqual(f.rows(), [])
}))

test('cold completed rows remain stable until a newer sidebar snapshot clears them', () => scenario(f => {
  const row = { id: 'session-heartbeat-cold', title: 'Cold', running: false, completed: true }
  f.mirror([row])
  for (let cycle = 0; cycle < 8; cycle++) {
    f.advance(5_100)
    assert.deepEqual(f.rows().map(r => [r.id, r.unread]), [[row.id, true]])
    assert.equal(f.board.requestFocus(row.id), true, 'a retained completion must remain openable')
    f.mirror([row])
  }
  f.mirror([])
  f.advance(60_000)
  assert.deepEqual(f.rows(), [])
}))

test('stale running-only browser rows still expire instead of inventing a completed task', () => scenario(f => {
  f.mirror([{ id: 'session-heartbeat-running', title: 'Cold running', running: true, completed: false }])
  assert.equal(f.rows()[0].busy, true)
  f.advance(5_100)
  assert.deepEqual(f.rows(), [])
}))

test('cached read state from an earlier turn cannot suppress a new completion', () => scenario(f => {
  const root = f.add('session-heartbeat-new-turn')
  f.rows(); root.finish(); f.rows()
  f.mirror([])
  assert.deepEqual(f.rows(), [])
  f.advance(1_000) // Even a still-fresh browser frame predates this new turn.
  root.start(); assert.equal(f.rows()[0].busy, true)
  root.finish()
  assert.equal(f.rows()[0].unread, true)
  f.advance(60_000)
  assert.equal(f.rows()[0].unread, true)
}))
