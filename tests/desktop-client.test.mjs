import { test } from 'node:test'
import assert from 'node:assert/strict'
import { apply } from '../companions/dsh-notch-focus/src/client/index.tsx'

test('RC2 current-session retention produces Desktop-compatible reading acknowledgements', async () => {
  const old = { window: globalThis.window, document: globalThis.document, fetch: globalThis.fetch }
  const sent = [], disposers = [], timers = []
  let focused = true, running = false
  const row = { id: 'session-current', displayTitle: 'Current', retainedBy: { mainView: 1 }, updatedAt: 100 }
  globalThis.window = { setTimeout: callback => { timers.push(callback); return timers.length }, clearTimeout() {}, focus() {} }
  globalThis.document = { hasFocus: () => focused }
  globalThis.fetch = async (url, options) => {
    if (url === '/dsh-notch/sidebar') sent.push({ headers: options.headers, body: JSON.parse(options.body) })
    return { ok: true, json: async () => ({ ok: true, focus: null }) }
  }
  try {
    const sessions = { list: { getSnapshot: () => ({ phase: 'ready', ids: [row.id], byId: { [row.id]: { ...row, running } } }) } }
    apply({ get: name => name === 'sessions' ? sessions : undefined, uiSession: { sessionStatus: { getSnapshot: () => new Map() } }, effect: setup => disposers.push(setup()) })
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(sent[0].headers['x-dsh-notch-client'], '1')
    assert.equal(sent[0].body.viewed.id, row.id)
    assert.ok(sent[0].body.viewed.at > row.updatedAt)
    focused = false
    timers.shift()()
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(sent[1].body.viewed, undefined)
    focused = true; running = true
    timers.shift()()
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(sent[2].body.viewed, undefined)
  } finally {
    disposers.forEach(dispose => dispose())
    for (const [key, value] of Object.entries(old)) {
      if (value === undefined) delete globalThis[key]
      else globalThis[key] = value
    }
  }
})

test('RC2 navigation ignores an old wish, opens a fresh wish through uiWorkspace, and retries after refresh', async () => {
  const old = { window: globalThis.window, document: globalThis.document, fetch: globalThis.fetch }
  const timers = [], disposers = [], opened = []
  let wish = { sessionId: 'custom-old', at: 1 }, refreshes = 0, stale = false
  globalThis.window = { setTimeout: callback => { timers.push(callback); return timers.length }, clearTimeout() {}, focus() {} }
  globalThis.document = { hasFocus: () => true }
  globalThis.fetch = async () => ({ ok: true, json: async () => ({ ok: true, focus: wish }) })
  const settle = () => new Promise(resolve => setImmediate(resolve))
  try {
    const sessions = {
      list: { getSnapshot: () => ({ phase: 'ready', ids: [], byId: {} }) },
      refresh: async () => { refreshes++; stale = false },
    }
    apply({
      get: name => name === 'sessions' ? sessions : undefined,
      uiSession: { sessionStatus: { getSnapshot: () => new Map() } },
      uiWorkspace: { openSession: id => { if (stale) throw new Error('stale list'); opened.push(id) } },
      effect: setup => disposers.push(setup()),
    })
    await settle()
    assert.deepEqual(opened, [], 'reopening a page must not replay an old focus wish')
    wish = { sessionId: 'custom-next', at: 2 }
    timers.shift()(); await settle()
    assert.deepEqual(opened, ['custom-next'])
    timers.shift()(); await settle()
    assert.deepEqual(opened, ['custom-next'], 'the same wish must not reopen a session every poll')
    wish = { sessionId: 'custom-retry', at: 3 }; stale = true
    timers.shift()(); await settle()
    assert.equal(refreshes, 1)
    assert.deepEqual(opened, ['custom-next', 'custom-retry'])
  } finally {
    disposers.forEach(dispose => dispose())
    for (const [key, value] of Object.entries(old)) {
      if (value === undefined) delete globalThis[key]
      else globalThis[key] = value
    }
  }
})
