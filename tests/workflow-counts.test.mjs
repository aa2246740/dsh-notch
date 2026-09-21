import { after, test } from 'node:test'
import assert from 'node:assert/strict'
import os from 'node:os'
import { mkdtempSync, rmSync } from 'node:fs'
import { syncBuiltinESMExports } from 'node:module'

const home = mkdtempSync(os.tmpdir() + '/notch-workflow-')
const originalHomedir = os.homedir
os.homedir = () => home
syncBuiltinESMExports()
const { Board } = await import('../src/board.ts')
os.homedir = originalHomedir
syncBuiltinESMExports()
after(() => rmSync(home, { recursive: true, force: true }))

function fixture() {
  const sessions = []
  const statuses = new Map()
  const ctx = {
    sessions: { list: () => sessions },
    agents: { get: id => ({ status: statuses.get(id) ?? 'idle' }) },
    get: name => name === 'sessionTitle' ? { get: session => ({ title: session.title }) } : undefined,
    logger: { warn() {} },
  }
  const board = new Board(ctx)
  function add(id, header = {}, running = true) {
    const events = [{ type: 'turn/start', time: Date.now() }]
    const session = { id, title: id, header, snapshotEvents: () => events, events }
    sessions.push(session)
    statuses.set(id, running ? 'running' : 'idle')
    return session
  }
  const child = (id, parent, running = true) => add(id, { parentSession: parent.id, origin: 'subagent', delegationDepth: 1 }, running)
  function finish(session, kind = 'completed') {
    statuses.set(session.id, 'idle')
    session.events.push({ type: 'turn/end', time: Date.now() + 1, data: { reason: { kind } } })
  }
  function question(session, id) {
    const controller = new AbortController()
    const request = { agent: { id: session.id }, signal: controller.signal, questions: [{ id, question: id }] }
    let webAborted = false
    const promise = board.holdAsk(request, () => new Promise((_, reject) => {
      request.signal.addEventListener('abort', () => { webAborted = true; reject(Error('settled elsewhere')) }, { once: true })
    }))
    return { promise, controller, webAborted: () => webAborted }
  }
  return { board, sessions, statuses, add, child, finish, question, rows: () => board.snapshot('').rows }
}

// The live SkillHub workflow has four completed parallel workers and one
// integration worker. Titles/providers must not determine classification.
test('two user tasks plus a five-worker workflow count as two, even during integration', () => {
  const f = fixture()
  const root = f.add('session-skillhub')
  f.add('session-watcher')
  for (let i = 0; i < 4; i++) f.finish(f.child('parallel-' + i, root))
  f.child('uuid-integration-worker', root).title = 'You are fixing findings from'
  assert.deepEqual(f.rows().map(r => [r.id, r.busy, r.child]), [
    [root.id, true, false], ['session-watcher', true, false],
  ])
})

test('nested workers roll up through delegation; independent user forks remain separate', () => {
  const f = fixture()
  const root = f.add('session-root')
  const fork = f.add('session-user-fork', { parentSession: root.id, isSeeded: true })
  f.child('grandchild', f.child('child', root))
  f.child('fork-worker', fork)
  assert.deepEqual(f.rows().map(r => r.id), [root.id, fork.id])
})

test('worker success and failure do not produce owner result lamps while workflow runs', () => {
  const f = fixture()
  const root = f.add('session-owner')
  const a = f.child('success-worker', root), b = f.child('error-worker', root)
  f.rows()
  f.finish(a)
  f.finish(b, 'error')
  assert.deepEqual(f.rows().map(r => [r.id, r.busy, r.unread, r.lastTurn]), [[root.id, true, false, undefined]])
  f.finish(root)
  const done = f.rows()
  assert.equal(done.length, 1)
  assert.equal(done[0].busy, false)
  assert.equal(done[0].unread, true)
  assert.equal(done[0].lastTurn.failed, false)
})

test('an owner failure produces exactly one failure after its children settle', () => {
  const f = fixture(), root = f.add('session-failure')
  const child = f.child('failure-worker', root)
  f.board.markSeen(root.id) // The Host's turn/start hook marks the owner read.
  f.rows(); f.finish(root, 'error'); f.finish(child, 'error')
  const rows = f.rows()
  assert.equal(rows.length, 1)
  assert.equal(rows[0].id, root.id)
  assert.equal(rows[0].lastTurn.failed, true)
})

test('a child finishing cannot replay an old owner completion', () => {
  const f = fixture(), root = f.add('session-old-owner', {}, false)
  root.events.push({ type: 'turn/end', time: 1, data: { reason: { kind: 'completed' } } })
  f.board.markSeen(root.id)
  const child = f.child('later-child', root)
  assert.equal(f.rows()[0].busy, true)
  f.finish(child)
  assert.deepEqual(f.rows(), [])
})

test('a background child keeps its idle owner running; root completion waits for it', () => {
  const f = fixture(), root = f.add('session-background')
  const child = f.child('background-child', root)
  f.rows(); f.finish(root)
  assert.deepEqual(f.rows().map(r => [r.id, r.busy, r.unread, r.lastTurn]), [[root.id, true, false, undefined]])
  f.finish(child)
  assert.deepEqual(f.rows().map(r => [r.id, r.busy, r.unread]), [[root.id, false, true]])
})

test('stale sidebar data cannot resurrect running or finished loaded child rows', () => {
  const f = fixture(), root = f.add('session-mirror-owner')
  const child = f.child('session-mirror-child', root)
  for (const completed of [false, true]) {
    if (completed) f.finish(child)
    assert.equal(f.board.syncSidebar({ clientId: 'app', focused: true, rows: [
      { id: child.id, title: child.title, running: !completed, completed },
    ] }), true)
    assert.deepEqual(f.rows().map(r => r.id), [root.id])
  }
})

test('child questions share one yellow owner row and settle their original callers in order', async () => {
  const f = fixture(), root = f.add('session-question-owner')
  const a = f.child('question-a', root), b = f.child('question-b', root)
  const first = f.question(a, 'qa'), second = f.question(b, 'qb')
  await Promise.resolve()
  let rows = f.rows()
  assert.equal(rows.length, 1)
  assert.equal(rows[0].id, root.id)
  assert.equal(rows[0].ask.questions[0].id, 'qa')
  const firstId = rows[0].ask.id
  const answer = [{ id: 'qa', selected: ['A'] }]
  assert.equal(f.board.answerAsk(firstId, answer), true)
  assert.deepEqual(await first.promise, { answers: answer })
  assert.equal(first.webAborted(), true)
  assert.equal(first.controller.signal.aborted, false)
  rows = f.rows()
  assert.equal(rows.length, 1)
  assert.equal(rows[0].ask.questions[0].id, 'qb')
  assert.equal(f.board.answerAsk(firstId, answer), false)
  assert.equal(f.board.answerAsk(rows[0].ask.id, []), true)
  assert.deepEqual(await second.promise, { answers: [] })
  assert.deepEqual(f.rows().map(r => [r.id, r.busy, r.ask]), [[root.id, true, undefined]])
  assert.equal(f.board.requestFocus(root.id), true)
  assert.equal(f.board.peekFocus().sessionId, root.id)
})

test('a child approval remains actionable on its owner without an extra task', async () => {
  const f = fixture(), root = f.add('session-approval-owner'), child = f.child('approval-child', root)
  const approval = f.board.holdApproval({ agent: { id: child.id }, toolName: 'write_file' }, () => new Promise(() => {}))
  const rows = f.rows()
  assert.equal(rows.length, 1)
  assert.equal(rows[0].id, root.id)
  assert.equal(f.board.decideApproval(rows[0].approval.id, 'allowed-once'), true)
  assert.equal(await approval, 'allowed-once')
  assert.equal(f.rows()[0].approval, undefined)
})

test('missing parents and malformed cycles do not inflate tasks or hang; questions survive', async () => {
  const f = fixture()
  const orphan = f.add('orphan', { origin: 'subagent', parentSession: 'absent' })
  f.add('a', { origin: 'subagent', parentSession: 'b' })
  f.add('b', { origin: 'subagent', parentSession: 'a' })
  assert.deepEqual(f.rows(), [])
  const pending = f.question(orphan, 'orphan-question')
  await Promise.resolve()
  const rows = f.rows()
  assert.equal(rows.length, 1)
  assert.equal(rows[0].id, orphan.id)
  assert.equal(rows[0].busy, false)
  assert.equal(rows[0].unread, false)
  f.board.answerAsk(rows[0].ask.id, [])
  await pending.promise
  assert.deepEqual(f.rows(), [])
})

test('Ralph-style sequential fresh workers never pulse extra running or result lamps', () => {
  const f = fixture(), root = f.add('session-ralph-owner')
  for (let round = 0; round < 5; round++) {
    const child = f.child('round-' + round, root)
    assert.deepEqual(f.rows().map(r => [r.id, r.busy, r.unread]), [[root.id, true, false]])
    f.finish(child, round === 1 ? 'aborted' : 'completed')
    f.sessions.splice(f.sessions.indexOf(child), 1)
    assert.deepEqual(f.rows().map(r => [r.id, r.busy, r.unread]), [[root.id, true, false]])
  }
})

test('resumed continuable child retains its owner regardless of load order and idle epochs', () => {
  const f = fixture(), root = f.add('session-resume-owner', {}, false)
  const child = f.child('resumed-child', root, false)
  f.sessions.reverse()
  assert.deepEqual(f.rows(), [])
  for (let turn = 0; turn < 3; turn++) {
    f.statuses.set(child.id, 'running')
    assert.deepEqual(f.rows().map(r => r.id), [root.id])
    f.finish(child)
    assert.deepEqual(f.rows(), [])
  }
})

test('cancelling a child question clears yellow on the owner without leaving a stale action', async () => {
  const f = fixture(), root = f.add('session-cancel-owner'), child = f.child('cancel-child', root)
  const pending = f.question(child, 'cancelled-question')
  await Promise.resolve()
  assert.equal(f.rows()[0].ask.questions[0].id, 'cancelled-question')
  const settled = assert.rejects(pending.promise, /settled elsewhere/)
  pending.controller.abort()
  await settled
  assert.deepEqual(f.rows().map(r => [r.id, r.busy, r.ask]), [[root.id, true, undefined]])
})
