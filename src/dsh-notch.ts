import type { Context } from '@deepseek-ai/cordis'
import type { ApprovalOutcome, ApprovalRequest } from '@deepseek-ai/dsh-user-approval'
import type { AskUserQuestionAnswer, AskUserQuestionRequest } from '@deepseek-ai/dsh-user-questions'
import type {} from '@deepseek-ai/dsh-host-webserver'
import type {} from '@deepseek-ai/dsh-session'
import { Board } from './board.ts'
import { attachHttp } from './http.ts'
import { loadOrCreateToken, writeRuntime } from './store.ts'

export const name = 'dsh-notch'
export const inject = ['sessions', 'webServer', 'approval', 'userQuestions', 'agents']

export function apply(ctx: Context) {
  console.log('[my-plugins/dsh-notch] loaded')
  const board = new Board(ctx)
  const token = loadOrCreateToken()
  const origin = `http://${ctx.webServer.host}:${String(ctx.webServer.port)}`
  writeRuntime({
    origin,
    token,
    pid: process.pid,
    writtenAt: Date.now(),
  })

  ctx.effect(() => attachHttp(ctx, board, token, origin), 'dsh-notch: http')

  const notify = debounce(() => board.notify(), 80)
  ctx.effect(() => notify.dispose, 'dsh-notch: notification timer')
  ctx.effect(() => ctx.on('session/created', notify), 'dsh-notch: created')
  ctx.effect(() => ctx.on('session/disposed', notify), 'dsh-notch: disposed')
  ctx.effect(() => ctx.on('session/event', (session, event) => {
    const type = String(event.type)
    if (type === 'turn/end') board.noteTurnEnd(session, event.time)
    if (type === 'turn/start' || type === 'turn/end' || type === 'session/title') {
      notify()
    }
    // When a turn starts or user sends a message in DSH, mark session as read
    if (type === 'turn/start' || (type === 'user/message' && (event.data as Record<string, unknown>)?.source === 'user')) {
      board.markSeen(session.id)
    }
  }), 'dsh-notch: events')
  ctx.effect(() => ctx.on('agent/status', notify), 'dsh-notch: agent-status')


  // Only intercept user-questions/request (AskUserQuestion).
  // Do NOT intercept internal tool approval/request which causes false alarms
  // when background agent tools run sandbox checks.
  ctx.on('user-questions/request', (
    request: AskUserQuestionRequest,
    next: () => Promise<AskUserQuestionAnswer>,
  ) => board.holdAsk(request, next), { prepend: true })
}

function debounce(fn: () => void, ms: number): (() => void) & { dispose: () => void } {
  let timer: ReturnType<typeof setTimeout> | undefined
  const notify = () => {
    if (timer) clearTimeout(timer)
    timer = setTimeout(() => { timer = undefined; fn() }, ms)
  }
  return Object.assign(notify, { dispose: () => { if (timer) clearTimeout(timer); timer = undefined } })
}
