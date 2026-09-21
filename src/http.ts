import { randomUUID } from 'node:crypto'
import type { IncomingMessage, ServerResponse } from 'node:http'
import type { Context } from '@deepseek-ai/cordis'
import type { Board } from './board.ts'
import type { ApprovalOutcomeWire, NotchAnswerItem } from './types.ts'

const PREFIX = '/dsh-notch'

export function isLoopback(req: IncomingMessage): boolean {
  const ip = req.socket.remoteAddress ?? ''
  return ip === '127.0.0.1' || ip === '::1' || ip === ':ffff:127.0.0.1' || ip === '::ffff:127.0.0.1'
}

export function authorized(req: IncomingMessage, token: string): boolean {
  const header = req.headers.authorization
  if (header === `Bearer ${token}`) return true
  try {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1')
    return url.searchParams.get('token') === token
  } catch {
    return false
  }
}

/**
 * Browser-side trust for pages served by this same Host: loopback remote,
 * never cross-site, and a matching Origin when one is present. Same rule the
 * shipped workspace file panel uses — no secret ever lands in page JS.
 */
export function browserTrusted(req: IncomingMessage): boolean {
  if (!isLoopback(req)) return false
  if (req.headers['sec-fetch-site'] === 'cross-site') return false
  const host = req.headers.host
  if (host === undefined) return false
  const origin = req.headers.origin
  if (origin === undefined) return true
  try {
    return new URL(origin).host === new URL(`http://${host}`).host
  } catch {
    return false
  }
}

function send(res: ServerResponse, status: number, body: unknown): void {
  const json = JSON.stringify(body)
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
  })
  res.end(json)
}

function readBody(req: IncomingMessage, limit = 64 * 1024): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = []
    let size = 0
    req.on('data', (chunk: Buffer) => {
      size += chunk.length
      if (size > limit) {
        reject(new Error('body too large'))
        req.destroy()
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
    req.on('error', reject)
  })
}

export function attachHttp(ctx: Context, board: Board, token: string, origin: string): () => void {
  const streams = new Map<string, ServerResponse>()
  const push = () => {
    const payload = `data: ${JSON.stringify(board.snapshot(origin))}\n\n`
    for (const [id, res] of streams) {
      try {
        res.write(payload)
      } catch {
        streams.delete(id)
      }
    }
  }
  const stopListen = board.onChange(push)

  const handler = async (req: IncomingMessage, res: ServerResponse): Promise<void> => {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1')
    const path = url.pathname
    const method = req.method ?? 'GET'

    // Browser pages served by this same Host consume focus wishes through
    // same-origin trust (no secret in page JS); everything else keeps the
    // notch Bearer token.
    if (method === 'GET' && path === `${PREFIX}/pending-focus`) {
      if (!browserTrusted(req)) {
        send(res, 403, { ok: false, error: 'forbidden' })
        return
      }
      send(res, 200, { ok: true, focus: board.peekFocus() })
      return
    }

    if (method === 'POST' && path === `${PREFIX}/sidebar`) {
      // JSON, explicit same origin, and browser fetch metadata prevent cross-site writes.
      if (!browserTrusted(req) || !req.headers.origin || !req.headers['content-type']?.startsWith('application/json')) {
        send(res, 403, { ok: false, error: 'forbidden' })
        return
      }
      const ok = board.syncSidebar(JSON.parse(await readBody(req, 512 * 1024)))
      send(res, ok ? 200 : 400, { ok })
      return
    }

    if (!isLoopback(req) || !authorized(req, token)) {
      send(res, 403, { ok: false, error: 'forbidden' })
      return
    }

    if (method === 'GET' && path === `${PREFIX}/status`) {
      send(res, 200, board.snapshot(origin))
      return
    }

    if (method === 'GET' && path === `${PREFIX}/diagnostics`) {
      send(res, 200, board.diagnostics())
      return
    }

    if (method === 'GET' && path === `${PREFIX}/events`) {
      const id = randomUUID()
      res.writeHead(200, {
        'content-type': 'text/event-stream',
        'cache-control': 'no-cache',
        connection: 'keep-alive',
      })
      streams.set(id, res)
      res.write(`data: ${JSON.stringify(board.snapshot(origin))}\n\n`)
      req.on('close', () => { streams.delete(id) })
      return
    }

    if (method === 'POST' && path === `${PREFIX}/seen`) {
      const body = JSON.parse(await readBody(req)) as { sessionId?: string; all?: boolean }
      if (body.all) {
        board.markAllSeen()
        send(res, 200, { ok: true })
        return
      }
      if (!body.sessionId) {
        send(res, 400, { ok: false, error: 'sessionId required' })
        return
      }
      board.markSeen(body.sessionId)
      send(res, 200, { ok: true })
      return
    }

    if (method === 'POST' && path === `${PREFIX}/approve`) {
      const body = JSON.parse(await readBody(req)) as { id?: string; outcome?: ApprovalOutcomeWire }
      if (!body.id || (body.outcome !== 'allowed-once' && body.outcome !== 'rejected')) {
        send(res, 400, { ok: false, error: 'id and outcome required' })
        return
      }
      if (!board.decideApproval(body.id, body.outcome)) {
        send(res, 404, { ok: false, error: 'not pending' })
        return
      }
      send(res, 200, { ok: true })
      return
    }

    if (method === 'POST' && path === `${PREFIX}/answer`) {
      const body = JSON.parse(await readBody(req)) as { id?: string; answers?: NotchAnswerItem[] }
      if (!body.id || !Array.isArray(body.answers)) {
        send(res, 400, { ok: false, error: 'id and answers required' })
        return
      }
      if (!board.answerAsk(body.id, body.answers)) {
        send(res, 404, { ok: false, error: 'not pending' })
        return
      }
      send(res, 200, { ok: true })
      return
    }

    if (method === 'POST' && path === `${PREFIX}/focus`) {
      const body = JSON.parse(await readBody(req)) as { sessionId?: string }
      if (!body.sessionId) {
        send(res, 400, { ok: false, error: 'sessionId required' })
        return
      }
      if (!board.requestFocus(body.sessionId)) {
        send(res, 404, { ok: false, error: 'unknown session' })
        return
      }
      send(res, 200, { ok: true })
      return
    }

    send(res, 404, { ok: false, error: 'not found' })
  }

  const disposeRoute = ctx.webServer.register({
    kind: 'prefix',
    path: PREFIX,
    handler: (req, res) => {
      void handler(req, res).catch((error: unknown) => {
        if (!res.headersSent) send(res, 400, { ok: false, error: String(error) })
      })
    },
  })

  return () => {
    stopListen()
    for (const res of streams.values()) {
      try { res.end() } catch { /* already closed */ }
    }
    streams.clear()
    disposeRoute()
  }
}
