import { test } from 'node:test'
import assert from 'node:assert/strict'
import { Board } from '../src/board.ts'

function fixture() {
  const sessions = [], agents = new Map(), jobs = []
  const ctx = {
    sessions: { list: () => sessions },
    agents: { get: id => agents.get(id) },
    get: name => name === 'jobs' ? {
      // Match JobRegistry.list: owned + unowned records, non-consuming.
      list: agent => jobs.filter(job => !job.ownerSession || job.ownerSession === agent.id),
    } : undefined,
    logger: { warn() {} },
  }
  const board = new Board(ctx)
  function add(id, header = {}, status = 'idle') {
    const session = { id, header, snapshotEvents: () => [] }
    sessions.push(session)
    agents.set(id, { id, status })
    return session
  }
  const job = (owner, status = 'running', kind = 'subagent') => {
    const record = { id: 'job-' + jobs.length, kind, status, ownerSession: owner?.id, reported: false }
    jobs.push(record)
    return record
  }
  return { add, job, agents, jobs, rows: () => board.snapshot('').rows }
}

test('remote background subagents keep an idle owner blue without any local child Session', () => {
  const f = fixture(), root = f.add('session-remote-owner')
  f.job(root); f.job(root)
  assert.deepEqual(f.rows().map(row => [row.id, row.busy, row.unread]), [[root.id, true, false]])
  assert.ok(f.jobs.every(job => !job.reported), 'observing must not consume completion notices')
})

test('local child and its background job do not count twice', () => {
  const f = fixture(), root = f.add('session-local-owner')
  f.add('local-child', { parentSession: root.id, origin: 'subagent' }, 'running')
  f.job(root)
  assert.deepEqual(f.rows().map(row => row.id), [root.id])
})

test('remote work delegated by a nested child stays on the original owner', () => {
  const f = fixture(), root = f.add('session-nested-owner')
  const child = f.add('nested-child', { parentSession: root.id, origin: 'subagent' })
  f.job(child)
  assert.deepEqual(f.rows().map(row => row.id), [root.id])
})

test('stopping remains active until settlement; terminal jobs leave no orphan lamp', () => {
  for (const terminal of ['completed', 'failed', 'killed']) {
    const f = fixture(), root = f.add('session-stop-' + terminal), job = f.job(root)
    assert.equal(f.rows()[0]?.busy, true)
    job.status = 'stopping'
    assert.equal(f.rows()[0]?.busy, true)
    job.status = terminal
    assert.deepEqual(f.rows(), [])
  }
})

test('unowned jobs, another owner, and long-running shell servers do not light every conversation', () => {
  const f = fixture(), first = f.add('session-first'), second = f.add('session-second')
  f.job(undefined)
  f.job(first, 'running', 'bash')
  f.job(second)
  assert.deepEqual(f.rows().map(row => row.id), [second.id])
})

test('agent disposal cannot leave a job-derived running row', () => {
  const f = fixture(), root = f.add('session-disposed-owner')
  f.job(root)
  assert.equal(f.rows()[0]?.busy, true)
  f.agents.delete(root.id)
  assert.deepEqual(f.rows(), [])
})
