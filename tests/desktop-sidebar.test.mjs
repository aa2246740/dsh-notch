import { test } from 'node:test'
import assert from 'node:assert/strict'
import { PassThrough } from 'node:stream'
import { attachHttp } from '../src/http.ts'
import { Board } from './isolated-board.mjs'

const origin = 'http://127.0.0.1:19387'
const headers = { host: '127.0.0.1:19387', 'content-type': 'application/json', 'x-dsh-notch-client': '1' }

function fixture() {
  let handler
  const board = new Board({ sessions: { list: () => [] }, agents: { get() {} }, get() {}, logger: { warn() {} } })
  const dispose = attachHttp({ webServer: { register: route => { handler = route.handler; return () => {} } } }, board, 'fixture-token', origin)
  const send = (body, requestHeaders = headers, remoteAddress = '127.0.0.1') => new Promise(resolve => {
    const req = new PassThrough()
    Object.assign(req, { url: '/dsh-notch/sidebar', method: 'POST', headers: requestHeaders, socket: { remoteAddress } })
    const res = { headersSent: false, writeHead(status) { this.status = status; this.headersSent = true }, end(body) { resolve({ status: this.status, body: JSON.parse(body) }) } }
    handler(req, res)
    req.end(JSON.stringify(body))
  })
  return { board, dispose, send }
}

test('Desktop sidebar projection clears a completed result only when its session is viewed in the foreground', async () => {
  const f = fixture()
  const row = { id: 'session-desktop-read', title: 'Desktop read', completed: true, running: false, updatedAt: 100 }
  const payload = { clientId: 'desktop', projectionVersion: 3, focused: true, rows: [row] }
  try {
    assert.equal((await f.send(payload)).status, 200)
    assert.equal(f.board.snapshot('').rows[0]?.unread, true)
    assert.equal((await f.send({ ...payload, focused: false, viewed: { id: row.id, at: 200 } })).status, 200)
    assert.equal(f.board.snapshot('').rows[0]?.unread, true)
    assert.equal((await f.send({ ...payload, viewed: { id: row.id, at: 200 } })).status, 200)
    assert.deepEqual(f.board.snapshot('').rows, [])
  } finally { f.dispose() }
})

test('Web same-origin projection remains supported', async () => {
  const f = fixture()
  try {
    assert.equal((await f.send({ clientId: 'web', rows: [] }, { host: headers.host, 'content-type': 'application/json', origin, 'sec-fetch-site': 'same-origin' })).status, 200)
  } finally { f.dispose() }
})

test('a custom Session ID does not reject the whole sidebar or prevent another session being read', async () => {
  const f = fixture()
  const rows = [
    { id: 'session-normal', title: 'Normal', completed: true, running: false, updatedAt: 100 },
    { id: 'fusion-adaptive-closure', title: 'Custom ID', completed: true, running: false, updatedAt: 100 },
  ]
  const payload = { clientId: 'desktop-custom', projectionVersion: 3, focused: true, rows }
  try {
    assert.equal((await f.send(payload)).status, 200)
    assert.equal(f.board.snapshot('').rows.length, 2)
    assert.equal((await f.send({ ...payload, viewed: { id: rows[0].id, at: 200 } })).status, 200)
    assert.deepEqual(f.board.snapshot('').rows.map(row => row.id), [rows[1].id])
    assert.equal((await f.send({ ...payload, viewed: { id: rows[1].id, at: 200 } })).status, 200)
    assert.deepEqual(f.board.snapshot('').rows, [])
    assert.equal((await f.send({ ...payload, rows: [{ ...rows[0], id: '' }] })).status, 400)
  } finally { f.dispose() }
})

test('Desktop exception rejects foreign origins, missing markers, cross-site metadata, wrong Host, and remote peers', async () => {
  const f = fixture()
  try {
    for (const change of [
      { origin: 'https://foreign.example' }, { origin: 'null' },
      { 'x-dsh-notch-client': undefined }, { 'x-dsh-notch-client': '0' },
      { 'sec-fetch-site': 'cross-site' }, { 'sec-fetch-site': 'same-site' },
      { host: 'foreign.example:19387' }, { host: '127.0.0.1:9999' },
      { 'content-type': 'text/plain' },
    ]) assert.equal((await f.send({ clientId: 'rejected', rows: [] }, { ...headers, ...change })).status, 403, JSON.stringify(change))
    assert.equal((await f.send({ clientId: 'remote', rows: [] }, headers, '192.0.2.1')).status, 403)
    assert.equal(f.board.diagnostics().sidebar, undefined)
  } finally { f.dispose() }
})
