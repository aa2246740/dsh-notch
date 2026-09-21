import { randomUUID } from 'node:crypto'
import type { Context } from '@deepseek-ai/cordis'
import type { Session } from '@deepseek-ai/dsh-session'
import type { JobRegistry } from '@deepseek-ai/dsh-jobs'
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

interface SidebarRow { id: string; title: string; completed: boolean; running: boolean; updatedAt?: number }
export class Board {
  private sidebar: { clientId: string; at: number; focused: boolean; rows: SidebarRow[]; projectionVersion?: number } | undefined
  private readonly instance = randomUUID()
  private readonly traces: Record<string, unknown>[] = []
  private lastMirrorTrace = ''
  private lastRowTrace = ''

  /** Bounded, content-free diagnostics for state-source races. */
  diagnostics(): unknown {
    return { stateRevision: 4, instance: this.instance,
      sidebar: this.sidebar && { clientId: this.sidebar.clientId, at: this.sidebar.at, focused: this.sidebar.focused },
      traces: this.traces }
  }

  private trace(event: string, value: Record<string, unknown>): void {
    this.traces.push({ at: Date.now(), event, ...value })
    if (this.traces.length > 160) this.traces.shift()
  }

  syncSidebar(input: unknown): boolean {
    if (!input || typeof input !== 'object') return false
    const data = input as { clientId?: unknown; focused?: unknown; rows?: unknown; projectionVersion?: unknown; viewed?: { id?: unknown; at?: unknown } }
    if (typeof data.clientId !== 'string' || !Array.isArray(data.rows) || data.rows.length > 1000) return false
    const rows: SidebarRow[] = []
    for (const row of data.rows) {
      if (!row || typeof row.id !== 'string' || !row.id.startsWith('session-') || typeof row.title !== 'string' || typeof row.completed !== 'boolean' || typeof row.running !== 'boolean') return false
      rows.push({ id: row.id, title: row.title.slice(0, 512), completed: row.completed, running: row.running,
        ...(typeof row.updatedAt === 'number' && Number.isFinite(row.updatedAt) ? { updatedAt: row.updatedAt } : {}) })
    }
    const sessions = new Map(this.ctx.sessions.list().map(session => [session.id, session]))
    // Completion is a fact, not a page-local negative flag. A page that was
    // reloaded or selected a different conversation cannot retract another
    // page's reminder. Explicit, timestamped reading acknowledgements can.
    for (const row of rows) {
      if (!row.completed || row.running) continue
      const session = sessions.get(row.id)
      if (session && (isChildSession(session) || this.isBusy(session))) continue
      const turn = session ? foldSession(session).lastTurn : undefined
      const seen = this.seen[row.id]
      const completedAt = turn?.at ?? row.updatedAt
      if (seen !== undefined && (completedAt === undefined || seen >= completedAt)) continue
      this.browserCompletions.set(row.id, row)
    }
    const viewed = data.viewed
    if (data.projectionVersion === 3 && data.focused === true && viewed
      && typeof viewed.id === 'string' && typeof viewed.at === 'number' && Number.isFinite(viewed.at)
      && rows.some(row => row.id === viewed.id && !row.running)) {
      const session = sessions.get(viewed.id)
      if (!session || (!isChildSession(session) && !this.conversationBusy(session, sessions))) this.readThrough(viewed.id, Math.min(viewed.at, Date.now()))
    }
    // Legacy clients can acknowledge only a reminder they themselves showed.
    if (data.projectionVersion !== 3 && data.focused === true && this.sidebar?.clientId === data.clientId) {
      for (const previous of this.sidebar.rows) {
        if (!previous.completed || rows.some(row => row.id === previous.id && row.completed)) continue
        const session = sessions.get(previous.id)
        const at = session ? foldSession(session).lastTurn?.at : Date.now()
        if (at !== undefined && (!session || !this.conversationBusy(session, sessions))) this.readThrough(previous.id, at)
      }
    }
    // A background browser cannot overwrite the last foreground page's state.
    if (this.sidebar && this.sidebar.clientId !== data.clientId && data.focused !== true && Date.now() - this.sidebar.at < 5000) { this.bump(); return true }
    this.sidebar = { clientId: data.clientId, at: Date.now(), focused: data.focused === true, rows,
      ...(data.projectionVersion === 2 || data.projectionVersion === 3 ? { projectionVersion: data.projectionVersion } : {}) }
    const mirrorTrace = { clientId: data.clientId, focused: data.focused === true,
      rows: rows.map(({ id, running, completed }) => ({ id, running, completed })) }
    const signature = JSON.stringify(mirrorTrace)
    if (signature !== this.lastMirrorTrace) { this.lastMirrorTrace = signature; this.trace('sidebar', mirrorTrace) }
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
  private readonly browserCompletions = new Map<string, SidebarRow>()
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
    const freshSidebar = this.sidebarRows()
    const coldRows = new Map(this.browserCompletions)
    for (const source of freshSidebar ?? []) {
      if (source.running) coldRows.set(source.id, source)
    }
    for (const source of coldRows.values()) {
      // The Host owns loaded session classification. A stale mirror must not
      // resurrect a filtered child as child:false or override a settled root.
      if (byId.has(source.id) || (!source.completed && !source.running)) continue
      // Heartbeat freshness is a liveness lease, not an unread-state change.
      // Retain completed cold rows until acknowledged; expire running-only
      // claims when their source stops reporting.
      if (source.running && !freshSidebar) continue
      const seen = this.seen[source.id]
      if (source.completed && seen !== undefined && (source.updatedAt === undefined || seen >= source.updatedAt)) continue
      rows.push({ id: source.id, title: source.title, child: false, busy: source.running, unread: source.completed })
    }
    rows.sort((a, b) => Number(Boolean(b.approval || b.ask)) - Number(Boolean(a.approval || a.ask))
      || Number(b.busy) - Number(a.busy)
      || Number(b.unread) - Number(a.unread)
      || (b.lastTurn?.at ?? 0) - (a.lastTurn?.at ?? 0))
    this.running = new Set(
      sessions.filter((session) => this.isBusy(session)).map((session) => session.id),
    )
    const stateRows = rows.map(row => ({ id: row.id, busy: row.busy, unread: row.unread,
      turnAt: row.lastTurn?.at, action: Boolean(row.ask || row.approval) }))
    const rowSignature = JSON.stringify(stateRows)
    if (rowSignature !== this.lastRowTrace) {
      this.lastRowTrace = rowSignature
      this.trace('snapshot', { rows: stateRows, clientId: this.sidebar?.clientId,
        mirrorAt: this.sidebar?.at, running: [...this.running], pendingUnread: [...this.pendingUnread] })
    }
    return { ok: true, stateRevision: 4, generatedAt: Date.now(), origin, rows,
      sidebarSyncedAt: freshSidebar ? this.sidebar?.at : undefined,
      sidebarProjectionVersion: freshSidebar ? this.sidebar?.projectionVersion : undefined }
  }

  markSeen(sessionId: string): void {
    this.pendingUnread.delete(sessionId)
    this.browserCompletions.delete(sessionId)
    this.seen[sessionId] = Date.now()
    saveSeen(this.seen)
    this.bump()
  }

  markAllSeen(): void {
    this.pendingUnread.clear()
    const now = Date.now()
    for (const id of this.browserCompletions.keys()) this.seen[id] = now
    this.browserCompletions.clear()
    for (const session of this.ctx.sessions.list()) {
      this.seen[session.id] = now
    }
    saveSeen(this.seen)
    this.bump()
  }

  private readThrough(sessionId: string, at: number): void {
    const seen = this.seen[sessionId]
    if ((seen ?? -Infinity) >= at) return
    const session = this.ctx.sessions.list().find(item => item.id === sessionId)
    const turn = session && foldSession(session).lastTurn
    const completedAt = turn?.at ?? this.browserCompletions.get(sessionId)?.updatedAt
    // An idle focused page reports every 400 ms. Persist once per result,
    // not on every heartbeat for as long as that conversation stays open.
    if (seen !== undefined && (completedAt === undefined || seen >= completedAt)) return
    this.seen[sessionId] = at
    if (completedAt === undefined || completedAt <= at) {
      this.pendingUnread.delete(sessionId)
      this.browserCompletions.delete(sessionId)
    }
    saveSeen(this.seen)
    this.trace('read', { sessionId, through: at })
  }

  noteTurnEnd(session: Session, at = foldSession(session).lastTurn?.at): void {
    if (isChildSession(session)) return
    if (at !== undefined && (this.seen[session.id] ?? -Infinity) < at) this.pendingUnread.add(session.id)
  }

  /**
   * Record a "show this session in a DSH UI" wish from the native helper.
   * Returns false for unknown sessions. The wish expires after 60s; every
   * open DSH page consumes it idempotently, so no per-client cursor is kept.
   */
  requestFocus(sessionId: string): boolean {
    const known = this.ctx.sessions.list().some((session) => session.id === sessionId)
    const mirrored = this.browserCompletions.has(sessionId) || this.sidebarRows()?.some(row => row.id === sessionId)
    if (!known && !mirrored) return false
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

  private conversationBusy(owner: Session, sessions: ReadonlyMap<string, Session>): boolean {
    for (const member of sessions.values()) {
      if (conversationOwner(member, sessions)?.id === owner.id
        && (this.isBusy(member) || this.hasSubagentJob(member))) return true
    }
    return false
  }

  private hasSubagentJob(session: Session): boolean {
    const agent = this.ctx.agents.get(session.id)
    if (!agent) return false
    // Remote backends have no local Agent/Session. The official background
    // job registry retains their owner through running and stopping, including
    // jobs that were already active when Notch was hot-loaded.
    const jobs = this.ctx.get('jobs') as Pick<JobRegistry, 'list'> | undefined
    return jobs?.list(agent).some(job => job.ownerSession === session.id
      && job.kind === 'subagent'
      && (job.status === 'running' || job.status === 'stopping')) ?? false
  }

  private rowFor(session: Session, members: Session[]): NotchRow | undefined {
    const folded = foldSession(session)
    const child = isChildSession(session)
    const lastSeen = this.seen[session.id]
    const busy = members.some(member => this.isBusy(member) || this.hasSubagentJob(member))
    // Completion belongs to the owner's turn, never an individual worker.
    if (folded.busy) {
      this.pendingUnread.delete(session.id)
    } else if (this.running.has(session.id) && folded.lastTurn) {
      this.pendingUnread.add(session.id)
    }
    const dismissed = lastSeen !== undefined && (folded.lastTurn === undefined || lastSeen >= folded.lastTurn.at)
    const unread = !dismissed && !busy
      && (this.pendingUnread.has(session.id) || this.browserCompletions.has(session.id))
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
