#!/usr/bin/env node
/**
 * Local stand-in for the DSH Host plugin. Claude Code hooks post session events
 * here, and the unchanged native Notch helper reads the same /dsh-notch/* HTTP
 * contract it reads from DSH, located through DSH_NOTCH_RUNTIME_FILE.
 *
 * One bridge per user. It exits once no Claude Code process it tracks is alive,
 * and the helper (which follows the runtime file's pid) exits with it.
 */
import { execFile } from 'node:child_process'
import { randomBytes, randomUUID } from 'node:crypto'
import { createWriteStream, existsSync, openSync, closeSync, writeSync, readFileSync, unlinkSync } from 'node:fs'
import { createServer } from 'node:http'
import { ClaudeBoard } from './lib/board.mjs'
import { superviseNotch } from './lib/notch-lifecycle.mjs'
import { BUNDLE_ID, alive, ensureDir, paths, readJson, writePrivateJson } from './lib/runtime.mjs'

const PREFIX = '/dsh-notch'
const IDLE_EXIT_MS = Number(process.env.DSH_NOTCH_IDLE_EXIT_MS) || 60_000
const PRUNE_MS = 2_000
const SEEN_TTL_MS = 30 * 24 * 60 * 60 * 1000

const files = paths()
ensureDir(files.dir)

function log(text) {
  process.stderr.write(`[dsh-notch bridge ${new Date().toISOString()}] ${text}\n`)
}

/** Single instance: an exclusive lock file naming its live owner. */
function acquireLock() {
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const fd = openSync(files.lock, 'wx', 0o600)
      writeSync(fd, `${process.pid}\n`)
      closeSync(fd)
      return true
    } catch (error) {
      if (error.code !== 'EEXIST') throw error
      const owner = Number(readFileSync(files.lock, 'utf8').trim())
      if (owner !== process.pid && alive(owner)) return false
      try { unlinkSync(files.lock) } catch {}
    }
  }
  return false
}

function releaseLock() {
  try {
    if (Number(readFileSync(files.lock, 'utf8').trim()) === process.pid) unlinkSync(files.lock)
  } catch {}
}

if (!acquireLock()) {
  log('another bridge owns the lock; exiting')
  process.exit(0)
}

const seen = (() => {
  const value = readJson(files.seen)
  if (!value || typeof value !== 'object') return {}
  const cutoff = Date.now() - SEEN_TTL_MS
  return Object.fromEntries(Object.entries(value).filter(([, at]) => typeof at === 'number' && at > cutoff))
})()

const streams = new Map()
let origin = ''
let saveTimer
const board = new ClaudeBoard({
  seen,
  onChange: () => {
    push()
    clearTimeout(saveTimer)
    saveTimer = setTimeout(() => { try { writePrivateJson(files.seen, board.seen) } catch {} }, 200)
  },
})

function push() {
  const payload = `data: ${JSON.stringify(board.snapshot(origin))}\n\n`
  for (const [id, res] of streams) {
    try { res.write(payload) } catch { streams.delete(id) }
  }
}

const existing = readJson(files.runtime)
const token = typeof existing?.token === 'string' && existing.token.length >= 16 ? existing.token : randomBytes(24).toString('hex')

function isLoopback(req) {
  const ip = req.socket.remoteAddress ?? ''
  return ip === '127.0.0.1' || ip === '::1' || ip === '::ffff:127.0.0.1'
}

function send(res, status, body) {
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' })
  res.end(JSON.stringify(body))
}

function readBody(req, limit = 1024 * 1024) {
  return new Promise((resolve, reject) => {
    const chunks = []
    let size = 0
    req.on('data', chunk => {
      size += chunk.length
      if (size > limit) { reject(new Error('body too large')); req.destroy(); return }
      chunks.push(chunk)
    })
    req.on('end', () => {
      const text = Buffer.concat(chunks).toString('utf8')
      try { resolve(text ? JSON.parse(text) : {}) } catch (error) { reject(error) }
    })
    req.on('error', reject)
  })
}

/** Bring the terminal / editor / Claude Desktop that hosts the session forward. */
function activate(bundleId) {
  if (process.platform !== 'darwin' || !bundleId || !BUNDLE_ID.test(bundleId)) return
  execFile('/usr/bin/open', ['-b', bundleId], error => { if (error) log(`activate ${bundleId} failed: ${error.message}`) })
}

async function handle(req, res) {
  const url = new URL(req.url ?? '/', 'http://127.0.0.1')
  const path = url.pathname
  const method = req.method ?? 'GET'
  if (!isLoopback(req) || req.headers.authorization !== `Bearer ${token}`) {
    send(res, 403, { ok: false, error: 'forbidden' })
    return
  }

  // ---- Native helper contract (same as src/http.ts) ----
  if (method === 'GET' && path === `${PREFIX}/status`) return send(res, 200, board.snapshot(origin))
  if (method === 'GET' && path === `${PREFIX}/diagnostics`) return send(res, 200, { pid: process.pid, ...board.diagnostics() })
  if (method === 'GET' && path === `${PREFIX}/events`) {
    const id = randomUUID()
    res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', connection: 'keep-alive' })
    streams.set(id, res)
    res.write(`data: ${JSON.stringify(board.snapshot(origin))}\n\n`)
    req.on('close', () => { streams.delete(id) })
    return
  }
  if (method === 'POST' && path === `${PREFIX}/seen`) {
    const body = await readBody(req)
    if (body.all) { board.markAllSeen(); return send(res, 200, { ok: true }) }
    if (typeof body.sessionId !== 'string') return send(res, 400, { ok: false, error: 'sessionId required' })
    board.markSeen(body.sessionId)
    return send(res, 200, { ok: true })
  }
  if (method === 'POST' && path === `${PREFIX}/approve`) {
    const body = await readBody(req)
    if (typeof body.id !== 'string') return send(res, 400, { ok: false, error: 'id and outcome required' })
    return board.decideApproval(body.id, body.outcome)
      ? send(res, 200, { ok: true }) : send(res, 404, { ok: false, error: 'not pending' })
  }
  if (method === 'POST' && path === `${PREFIX}/answer`) {
    const body = await readBody(req)
    if (typeof body.id !== 'string' || !Array.isArray(body.answers)) return send(res, 400, { ok: false, error: 'id and answers required' })
    return board.answerAsk(body.id, body.answers)
      ? send(res, 200, { ok: true }) : send(res, 404, { ok: false, error: 'not pending' })
  }
  if (method === 'POST' && path === `${PREFIX}/focus`) {
    const body = await readBody(req)
    const session = typeof body.sessionId === 'string' ? board.requestFocus(body.sessionId) : undefined
    if (!session) return send(res, 404, { ok: false, error: 'unknown session' })
    activate(session.bundleId)
    return send(res, 200, { ok: true })
  }

  // ---- Claude Code hook side ----
  if (method === 'GET' && path === `${PREFIX}/ping`) return send(res, 200, { ok: true, pid: process.pid })
  if (method === 'POST' && path === `${PREFIX}/hook`) {
    const ok = board.apply(await readBody(req))
    return send(res, ok ? 200 : 400, { ok })
  }
  if (method === 'POST' && path === `${PREFIX}/hold`) {
    const body = await readBody(req)
    const input = body.input
    const waitMs = Math.max(0, Math.min(Number(body.waitMs) || 0, 55 * 60 * 1000))
    if (!input || typeof input.session_id !== 'string' || !waitMs) return send(res, 200, { ok: true, decision: null })
    const held = board.hold(input)
    let settled = false
    const finish = decision => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      if (!res.writableEnded && !res.destroyed) send(res, 200, { ok: true, decision })
    }
    const timer = setTimeout(() => { held.cancel(); finish(null) }, waitMs)
    // Claude Code cancels the hook when the dialog is answered in the terminal.
    res.on('close', () => { if (!settled) { settled = true; clearTimeout(timer); held.cancel() } })
    held.decision.then(finish)
    return
  }
  if (method === 'POST' && path === `${PREFIX}/shutdown`) {
    send(res, 200, { ok: true })
    setImmediate(() => shutdown('requested'))
    return
  }
  send(res, 404, { ok: false, error: 'not found' })
}

const server = createServer((req, res) => {
  handle(req, res).catch(error => { if (!res.headersSent) send(res, 400, { ok: false, error: String(error) }) })
})

let helper
let helperLog
let pruneTimer
let idleSince = Date.now()
let stopping = false

function shutdown(reason) {
  if (stopping) return
  stopping = true
  log(`shutting down: ${reason}`)
  clearInterval(pruneTimer)
  for (const held of [...board.holds.keys()]) board.release(held)
  for (const res of streams.values()) { try { res.end() } catch {} }
  streams.clear()
  helper?.stop()
  helperLog?.end()
  try { writePrivateJson(files.seen, board.seen) } catch {}
  releaseLock()
  server.close()
  setTimeout(() => process.exit(0), 200).unref()
}

server.listen(0, '127.0.0.1', () => {
  const address = server.address()
  origin = `http://127.0.0.1:${address.port}`
  writePrivateJson(files.runtime, { origin, token, pid: process.pid, writtenAt: Date.now(), source: 'claude-code' })
  log(`listening on ${origin}`)

  const helperPath = process.env.CLAUDE_PLUGIN_OPTION_HELPER_PATH || process.env.DSH_NOTCH_HELPER || ''
  if (helperPath) {
    if (!existsSync(helperPath)) log(`configured helper does not exist: ${helperPath}`)
    else {
      helperLog = createWriteStream(files.helperLog, { flags: 'a', mode: 0o600 })
      helper = superviseNotch({ bin: helperPath, pidPath: files.helperPid, log: helperLog,
        env: { ...process.env, DSH_NOTCH_RUNTIME_FILE: files.runtime } })
    }
  }

  pruneTimer = setInterval(() => {
    board.prune(alive)
    if (board.sessions.size > 0 || board.holds.size > 0) { idleSince = Date.now(); return }
    if (Date.now() - idleSince >= IDLE_EXIT_MS) shutdown('no live Claude Code sessions')
  }, PRUNE_MS)
})

process.on('SIGTERM', () => shutdown('SIGTERM'))
process.on('SIGINT', () => shutdown('SIGINT'))
process.on('exit', releaseLock)
