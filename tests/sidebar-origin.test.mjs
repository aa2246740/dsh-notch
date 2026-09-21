import { test } from 'node:test'
import assert from 'node:assert/strict'
import { apply } from '../companions/dsh-notch-focus/src/client/index.tsx'
import { Board } from './isolated-board.mjs'

test('browser mirror keeps cold user forks and excludes all durable subagents', async () => {
  const old = { window: globalThis.window, document: globalThis.document, fetch: globalThis.fetch }
  const sent = [], disposers = []
  const rows = [
    { id: 'session-root', displayTitle: 'Root', running: true },
    { id: 'session-user-fork', parentId: 'session-root', displayTitle: 'User fork', running: false, completed: true, updatedAt: 100 },
    { id: 'session-seeded-agent', parentId: 'session-root', origin: 'subagent', displayTitle: 'Delegated fork', running: true },
    { id: 'session-orphan-agent', origin: 'subagent', displayTitle: 'Unloaded parent', running: true },
  ]
  globalThis.window = { setTimeout: () => 1, clearTimeout() {}, focus() {} }
  globalThis.document = { hasFocus: () => true }
  globalThis.fetch = async (url, options) => {
    if (url === '/dsh-notch/sidebar') sent.push(JSON.parse(options.body))
    return { ok: true, json: async () => ({ ok: true, focus: null }) }
  }
  try {
    const before = Date.now()
    apply({
      sessions: {
        list: { getSnapshot: () => ({ phase: 'ready', current: 'session-user-fork', ids: rows.map(r => r.id), byId: Object.fromEntries(rows.map(r => [r.id, r])) }) },
        open() {}, refresh: async () => {},
      },
      effect: setup => { disposers.push(setup()) },
    })
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(sent.length, 1)
    assert.equal(sent[0].viewed.id, 'session-user-fork')
    assert.ok(sent[0].viewed.at >= before && sent[0].viewed.at <= Date.now(), 'reading time is independent of the much older prompt timestamp')
    const board = new Board({ sessions: { list: () => [] }, agents: { get() {} }, get() {}, logger: { warn() {} } })
    assert.equal(board.syncSidebar(sent[0]), true)
    assert.equal(board.snapshot('').sidebarProjectionVersion, 3)
    assert.deepEqual(sent[0].rows.map(row => row.id), ['session-root', 'session-user-fork'])
  } finally {
    for (const dispose of disposers) dispose()
    for (const [key, value] of Object.entries(old)) {
      if (value === undefined) delete globalThis[key]
      else globalThis[key] = value
    }
  }
})
