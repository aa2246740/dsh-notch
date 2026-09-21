import { randomUUID } from 'node:crypto'
import type { Context } from '@deepseek-ai/cordis'
import type { Session } from '@deepseek-ai/dsh-session'
import type { ApprovalOutcome, ApprovalRequest } from '@deepseek-ai/dsh-user-approval'
import type {
  AskUserQuestionAnswer,
  AskUserQuestionRequest,
} from '@deepseek-ai/dsh-user-questions'
import { conversationOwner, foldSession, isChildSession } from './session-state.ts'
import { loadSeen, saveSeen } from './store.ts'
import type {
  ApprovalOutcomeWire,
  NotchAnswerItem,
  NotchApproval,
  NotchAsk,
  NotchFocus,
  NotchQuestion,
  NotchRow,
  NotchSnapshot,
} from './types.ts'

interface HeldApproval {
  kind: 'approval'
  id: string
  sessionId: string
  toolName: string
  reason?: string
  resolve: (outcome: ApprovalOutcome) => void
}

interface HeldAsk {
  kind: 'ask'
  id: string
  sessionId: string
  questions: NotchQuestion[]
  resolve: (answer: AskUserQuestionAnswer) => void
}

type Held = HeldApproval | HeldAsk

interface SidebarRow { id: string; title: string; completed: boolean; running: boolean }
export class Board {
  private sidebar: { clientId: string; at: number; rows: SidebarRow[] } | undefined

  syncSidebar(input: unknown): boolean {
    if (!input || typeof input !== 'object') return false
    const data = input as { clientId?: unknown; focused?: unknown; rows?: unknown }
    if (typeof data.clientId !== 'string' || !Array.isArray(data.rows) || data.rows.length > 1000) return false
    const rows: SidebarRow[] = []
    for (const row of data.rows) {
      if (!row || typeof row.id !== 'string' || !row.id.startsWith('session-') || typeof row.title !== 'string' || typeof row.completed !== 'boolean' || typeof row.running !== 'boolean') return false
      rows.push({ id: row.id, title: row.title.slice(0, 512), completed: row.completed, running: row.running })
    }
    // A background browser cannot overwrite the last foreground page's state.
    if (this.sidebar && this.sidebar.clientId !== data.clientId && data.focused !== true && Date.now() - this.sidebar.at < 5000) return true
    this.sidebar = { clientId: data.clientId, at: Date.now(), rows }
    this.bump()
    return true
  }

  private sidebarRows(): SidebarRow[] | undefined {
    return this.sidebar && Date.now() - this.sidebar.at < 5000 ? this.sidebar.rows : undefined
  }

  private readonly pending = new Map<string, Held>()
  private readonly seen = loadSeen()
  private running = new Set<string>()
  private readonly pendingUnread = new Set<string>()
  private readonly listeners = new Set<() => void>()
  private focus: NotchFocus | null = null

  constructor(private readonly ctx: Context) {}

  onChange(fn: () => void): () => void {
    this.listeners.add(fn)
    return () => { this.listeners.delete(fn) }
  }

  notify(): void {
    this.bump()
  }

  private bump(): void {
    for (const fn of this.listeners) {
      try { fn() } catch (error) { this.ctx.logger.warn('dsh-notch: subscriber failed: %s', String(error)) }
    }
  }

  snapshot(origin: string): NotchSnapshot {
    const rows: NotchRow[] = []
    const sessions = this.ctx.sessions.list()
    const byId = new Map<string, Session>(sessions.map(session => [session.id, session]))
    const groups = new Map<Session, Session[]>()
    for (const session of sessions) {
      const owner = conversationOwner(session, byId)
      if (!owner) {
        // Broken/unloaded lineage must not invent a task or lose a user question.
        const ids = new Set([session.id])
        const approval = this.heldApproval(ids)
        const ask = this.heldAsk(ids)
        if (approval || ask) rows.push({
          id: session.id, title: this.titleOf(session), child: true,
          busy: false, unread: false,
          ...(approval ? { approval } : {}), ...(ask ? { ask } : {}),
        })
        continue
      }
      const members = groups.get(owner) ?? []
      members.push(session)
      groups.set(owner, members)
    }
    for (const [owner, members] of groups) {
      const row = this.rowFor(owner, members)
      if (row) rows.push(row)
    }
    for (const source of this.sidebarRows() ?? []) {
      // The Host owns loaded session classification. A stale mirror must not
      // resurrect a filtered child as child:false or override a settled root.
      if (byId.has(source.id) || (!source.completed && !source.running)) continue
      if (source.completed && this.seen[source.id] !== undefined) continue
      rows.push({ id: source.id, title: source.title, child: false, busy: source.running, unread: source.completed })
    }
    rows.sort((a, b) => Number(Boolean(b.approval || b.ask)) - Number(Boolean(a.approval || a.ask))
      || Number(b.busy) - Number(a.busy)
      || Number(b.unread) - Number(a.unread)
      || (b.lastTurn?.at ?? 0) - (a.lastTurn?.at ?? 0))
    this.running = new Set(
      sessions.filter((session) => this.isBusy(session)).map((session) => session.id),
    )
    return { ok: true, generatedAt: Date.now(), origin, rows, sidebarSyncedAt: this.sidebarRows() ? this.sidebar?.at : undefined }
  }

  markSeen(sessionId: string): void {
    this.pendingUnread.delete(sessionId)
    this.seen[sessionId] = Date.now()
    saveSeen(this.seen)
    this.bump()
  }

  markAllSeen(): void {
    this.pendingUnread.clear()
    const now = Date.now()
    for (const session of this.ctx.sessions.list()) {
      this.seen[session.id] = now
    }
    saveSeen(this.seen)
    this.bump()
  }

  /**
   * Record a "show this session in a DSH UI" wish from the native helper.
   * Returns false for unknown sessions. The wish expires after 60s; every
   * open DSH page consumes it idempotently, so no per-client cursor is kept.
   */
  requestFocus(sessionId: string): boolean {
    const known = this.ctx.sessions.list().some((session) => session.id === sessionId)
    if (!known && !this.sidebarRows()?.some(row => row.id === sessionId)) return false
    this.focus = { sessionId, at: Date.now() }
    this.bump()
    return true
  }

  peekFocus(): NotchFocus | null {
    if (this.focus === null) return null
    if (Date.now() - this.focus.at > 60_000) {
      this.focus = null
      return null
    }
    return this.focus
  }

  decideApproval(id: string, outcome: ApprovalOutcomeWire): boolean {
    const held = this.pending.get(id)
    if (!held || held.kind !== 'approval') return false
    this.pending.delete(id)
    this.seen[held.sessionId] = Date.now()
    saveSeen(this.seen)
    held.resolve(outcome)
    this.bump()
    return true
  }

  answerAsk(id: string, answers: NotchAnswerItem[]): boolean {
    const held = this.pending.get(id)
    if (!held || held.kind !== 'ask') return false
    this.pending.delete(id)
    this.seen[held.sessionId] = Date.now()
    saveSeen(this.seen)
    held.resolve({ answers })
    this.bump()
    return true
  }

  holdApproval(request: ApprovalRequest, next: () => Promise<ApprovalOutcome>): Promise<ApprovalOutcome> {
    const sessionId = String(request.agent.id)
    const id = randomUUID()
    const fromNotch = new Promise<ApprovalOutcome>((resolve) => {
      const held: HeldApproval = {
        kind: 'approval',
        id,
        sessionId,
        toolName: request.toolName,
        resolve,
      }
      if (request.reason) held.reason = request.reason
      this.pending.set(id, held)
      this.bump()
      request.signal?.addEventListener('abort', () => {
        if (!this.pending.delete(id)) return
        this.bump()
      }, { once: true })
    })
    return Promise.race([fromNotch, next()]).finally(() => {
      if (this.pending.delete(id)) this.bump()
    })
  }

  holdAsk(request: AskUserQuestionRequest, next: () => Promise<AskUserQuestionAnswer>): Promise<AskUserQuestionAnswer> {
    const sessionId = request.agent ? String(request.agent.id) : ''
    if (!sessionId) return next()
    const originalSignal = request.signal
    const downstream = new AbortController()
    request.signal = originalSignal
      ? AbortSignal.any([originalSignal, downstream.signal])
      : downstream.signal
    const id = randomUUID()
    const questions: NotchQuestion[] = request.questions.map((item) => ({
      id: item.id,
      question: item.question,
      ...(item.detail === undefined ? {} : { detail: item.detail }),
      ...(item.header === undefined ? {} : { header: item.header }),
      ...(item.options === undefined ? {} : { options: item.options }),
      ...(item.multiSelect === undefined ? {} : { multiSelect: item.multiSelect }),
      ...(item.intent === undefined ? {} : { intent: item.intent }),
    }))
    const fromNotch = new Promise<AskUserQuestionAnswer>((resolve) => {
      this.pending.set(id, { kind: 'ask', id, sessionId, questions, resolve })
      this.bump()
      request.signal?.addEventListener('abort', () => {
        if (!this.pending.delete(id)) return
        this.bump()
      }, { once: true })
    })
    return Promise.race([fromNotch, Promise.resolve().then(next)]).finally(() => {
      // The losing Web answerer must end too, so its pending interaction unmounts.
      // Cancel only this delegated wait, never the owning agent's signal.
      downstream.abort(new Error('Question settled through another answerer'))
      if (originalSignal === undefined) delete request.signal
      else request.signal = originalSignal
      if (this.pending.delete(id)) this.bump()
    })
  }

  private isBusy(session: Session): boolean {
    return this.ctx.agents.get(session.id)?.status === 'running'
  }

  private rowFor(session: Session, members: Session[]): NotchRow | undefined {
    const folded = foldSession(session)
    const child = isChildSession(session)
    const lastSeen = this.seen[session.id]
    const busy = members.some(member => this.isBusy(member))
    // Completion belongs to the owner's turn, never an individual worker.
    if (this.isBusy(session)) {
      this.pendingUnread.delete(session.id)
    } else if (this.running.has(session.id) && folded.lastTurn && !folded.lastTurn.failed) {
      this.pendingUnread.add(session.id)
    }
    const dismissed = lastSeen !== undefined && (folded.lastTurn === undefined || lastSeen >= folded.lastTurn.at)
    const mirror = this.sidebarRows()
    const unread = dismissed || busy
      ? false
      : mirror !== undefined
        ? mirror.some(row => row.id === session.id && row.completed)
        : this.pendingUnread.has(session.id)
          || (folded.lastTurn !== undefined && lastSeen !== undefined && folded.lastTurn.at > lastSeen)
    const memberIds = new Set(members.map(member => member.id))
    // Keep the original request id/resolver so answering the root's yellow
    // lamp settles the correct child. Further child questions queue here.
    const approval = this.heldApproval(memberIds)
    const ask = this.heldAsk(memberIds)
    if (!busy && !unread && !approval && !ask) return undefined
    const title = this.titleOf(session)
    const row: NotchRow = {
      id: session.id,
      title,
      child,
      busy,
      unread,
    }
    if (folded.lastTurn && !busy) row.lastTurn = folded.lastTurn
    if (approval) row.approval = approval
    if (ask) row.ask = ask
    return row
  }

  private heldApproval(sessionIds: ReadonlySet<string>): NotchApproval | undefined {
    for (const held of this.pending.values()) {
      if (held.kind === 'approval' && sessionIds.has(held.sessionId)) {
        return {
          id: held.id,
          toolName: held.toolName,
          ...(held.reason === undefined ? {} : { reason: held.reason }),
        }
      }
    }
    return undefined
  }

  private heldAsk(sessionIds: ReadonlySet<string>): NotchAsk | undefined {
    for (const held of this.pending.values()) {
      if (held.kind === 'ask' && sessionIds.has(held.sessionId)) {
        return { id: held.id, questions: held.questions }
      }
    }
    return undefined
  }

  private titleOf(session: Session): string {
    const service = this.ctx.get('sessionTitle') as { get(target: Session): { title: string } | undefined } | undefined
    const title = service?.get(session)?.title?.trim()
    if (title) return title
    return session.id.slice(0, 8)
  }
}
