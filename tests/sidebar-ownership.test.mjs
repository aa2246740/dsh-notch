import { test } from 'node:test'
import assert from 'node:assert/strict'
import { Board } from './isolated-board.mjs'

function fixture(id) {
  const events = [], agent = { status: 'idle' }
  const session = { id: 'session-' + id, header: {}, snapshotEvents: () => events }
  const board = new Board({ sessions: { list: () => [session] }, agents: { get: () => agent }, get() {}, logger: { warn() {} } })
  const post = (clientId, completed, at, viewed = false, focused = true) => board.syncSidebar({
    clientId, focused, projectionVersion: 3,
    rows: [{ id: session.id, title: 'Fixture', running: false, completed, updatedAt: at }],
    ...(viewed ? { viewed: { id: session.id, at } } : {}),
  })
  const end = (at, kind = 'completed') => {
    events.push({ type: 'turn/end', time: at, data: { reason: { kind } } })
    board.noteTurnEnd(session, at)
  }
  return { board, session, events, agent, post, end, rows: () => board.snapshot('').rows }
}

test('two focused pages with conflicting local completion flags cannot toggle the same result', () => {
  const f = fixture('two-mirrors'); f.end(100)
  for (let cycle = 0; cycle < 30; cycle++) {
    f.post('app', true, 100)
    assert.equal(f.rows()[0]?.unread, true)
    f.post('browser', false, 100)
    assert.equal(f.rows()[0]?.unread, true, 'absence of a page-local reminder is not a reading acknowledgement')
  }
  f.post('app', false, 100, true)
  for (let cycle = 0; cycle < 30; cycle++) {
    f.post('browser', true, 100)
    f.post('app', false, 100)
    assert.deepEqual(f.rows(), [], 'stale browser reminder cannot resurrect a read turn')
  }
})

test('late acknowledgement of the previous turn cannot clear the current completion', () => {
  const f = fixture('read-watermark'); f.end(100); f.post('app', false, 100, true)
  f.end(200)
  f.post('browser', false, 100, true)
  assert.equal(f.rows()[0]?.lastTurn.at, 200)
  f.post('app', false, 200, true)
  assert.deepEqual(f.rows(), [])
})

test('an inactive page cannot acknowledge reading', () => {
  const f = fixture('inactive-read'); f.end(100)
  f.post('hidden-browser', false, 100, true, false)
  assert.equal(f.rows()[0]?.unread, true)
})

test('reading a finished task uses observation time rather than its original prompt timestamp', () => {
  const f = fixture('prompt-time'); f.end(200)
  f.board.syncSidebar({ clientId: 'app', focused: true, projectionVersion: 3,
    rows: [{ id: f.session.id, title: 'Fixture', running: false, completed: false, updatedAt: 100 }],
    viewed: { id: f.session.id, at: 201 } })
  assert.deepEqual(f.rows(), [])
  f.end(300)
  f.board.syncSidebar({ clientId: 'app', focused: true, projectionVersion: 3,
    rows: [{ id: f.session.id, title: 'Fixture', running: false, completed: false, updatedAt: 100 }],
    viewed: { id: f.session.id, at: 201 } })
  assert.equal(f.rows()[0]?.lastTurn.at, 300, 'a delayed view cannot clear a later automatic continuation of the same prompt')
})

test('an unloaded session can report a new completion after an earlier result was read', () => {
  const board = new Board({ sessions: { list: () => [] }, agents: { get() {} }, get() {}, logger: { warn() {} } })
  const row = { id: 'session-cold-new-result', title: 'Cold', running: false, completed: true, updatedAt: 100 }
  const post = (row, at) => board.syncSidebar({ clientId: 'app', focused: true, projectionVersion: 3,
    rows: [row], ...(at === undefined ? {} : { viewed: { id: row.id, at } }) })
  post(row); assert.equal(board.snapshot('').rows[0]?.unread, true)
  post({ ...row, completed: false }, 150); assert.deepEqual(board.snapshot('').rows, [])
  post({ ...row, updatedAt: 200 }); assert.equal(board.snapshot('').rows[0]?.unread, true)
  post({ ...row, completed: false }, 175); assert.equal(board.snapshot('').rows[0]?.unread, true)
  post({ ...row, completed: false, updatedAt: 200 }, 250); assert.deepEqual(board.snapshot('').rows, [])
})

test('a focused idle page persists a reading acknowledgement once per completed turn', () => {
  const f = fixture('idle-read-writes'); f.end(100)
  for (let at = 101; at < 300; at++) f.post('app', false, at, true)
  assert.equal(f.board.diagnostics().traces.filter(event => event.event === 'read').length, 1)
  f.end(400); f.post('app', false, 401, true)
  assert.equal(f.board.diagnostics().traces.filter(event => event.event === 'read').length, 2)
  assert.deepEqual(f.rows(), [])
})

test('a cold load does not replay historical results solely because an older seen timestamp exists', () => {
  const f = fixture('cold-read')
  f.post('app', false, 10, true)
  f.events.push({ type: 'turn/end', time: 100, data: { reason: { kind: 'completed' } } })
  const reloaded = new Board({ sessions: { list: () => [f.session] }, agents: { get: () => f.agent }, get() {}, logger: { warn() {} } })
  assert.deepEqual(reloaded.snapshot('').rows, [])
})

test('short and failed root turns are recorded even if no polling request observed them running', () => {
  for (const reason of ['completed', 'error']) {
    const f = fixture('short-' + reason)
    f.end(100, reason)
    assert.equal(f.rows()[0]?.unread, true)
    assert.equal(f.rows()[0]?.lastTurn.failed, reason === 'error')
  }
})

test('turn-end recording survives the agent still reporting running during settlement', () => {
  const f = fixture('settling'); f.agent.status = 'running'; f.end(100)
  assert.equal(f.rows()[0]?.busy, true)
  f.agent.status = 'idle'
  assert.equal(f.rows()[0]?.unread, true)
})

test('reading an idle owner while its child or remote job runs cannot acknowledge the eventual result', () => {
  for (const kind of ['local-child', 'remote-job']) {
    const id = 'session-active-owner-' + kind
    const root = { id, header: {}, snapshotEvents: () => [{ type: 'turn/end', time: 100, data: { reason: { kind: 'completed' } } }] }
    const child = { id: id + '-child', header: { origin: 'subagent', parentSession: id }, snapshotEvents: () => [] }
    const agent = { status: 'idle' }, childAgent = { status: 'running' }
    const jobs = [{ ownerSession: id, kind: 'subagent', status: 'running' }]
    const sessions = kind === 'local-child' ? [root, child] : [root]
    const board = new Board({ sessions: { list: () => sessions },
      agents: { get: key => key === id ? agent : childAgent },
      get: key => key === 'jobs' ? { list: () => kind === 'remote-job' ? jobs : [] } : undefined,
      logger: { warn() {} } })
    board.noteTurnEnd(root, 100)
    board.syncSidebar({ clientId: 'app', focused: true, projectionVersion: 3,
      rows: [{ id, title: 'Owner', completed: false, running: false, updatedAt: 50 }], viewed: { id, at: 200 } })
    assert.equal(board.snapshot('').rows[0]?.busy, true)
    childAgent.status = 'idle'; jobs[0].status = 'completed'
    assert.equal(board.snapshot('').rows[0]?.unread, true, kind)
  }
})

test('diagnostics are bounded and contain no titles or question text', () => {
  const f = fixture('diagnostics')
  for (let index = 0; index < 200; index++) f.post('client-' + index, false, index)
  const diagnostics = f.board.diagnostics()
  assert.ok(diagnostics.traces.length <= 160)
  assert.ok(!JSON.stringify(diagnostics).includes('Fixture'))
})
