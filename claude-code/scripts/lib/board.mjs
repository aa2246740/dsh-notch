import { randomUUID } from 'node:crypto'
import { basename } from 'node:path'

/**
 * Claude Code session state folded from hook events into the same NotchSnapshot
 * wire contract the native helper already reads from the DSH Host plugin
 * (see src/types.ts). Pure: no I/O, clock injected, so tests drive it directly.
 */

// Background work that re-wakes the main agent when it settles. Shell tasks
// such as `tail -f` never settle, so they do not keep a conversation blue.
const OWNED_BACKGROUND = new Set(['subagent', 'workflow', 'teammate', 'cloud session'])
const SETTLED = new Set(['completed', 'failed', 'killed', 'stopped', 'cancelled', 'canceled', 'error'])
const TITLE_LIMIT = 96
const REASON_LIMIT = 400

export function stableKey(toolName, input) {
  const rest = input && typeof input === 'object' ? { ...input } : {}
  // AskUserQuestion comes back from PostToolUse with the answers filled in.
  delete rest.answers
  return `${toolName}:${stableStringify(rest)}`
}

function stableStringify(value) {
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(',')}]`
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${stableStringify(value[key])}`).join(',')}}`
  }
  return JSON.stringify(value) ?? 'null'
}

function clip(text, limit) {
  const flat = String(text).replace(/\s+/g, ' ').trim()
  return flat.length > limit ? `${flat.slice(0, limit - 1)}…` : flat
}

/** One readable line for the Notch approval card. */
export function describeTool(toolName, input = {}) {
  const pick = (...keys) => keys.map(key => input[key]).find(value => typeof value === 'string' && value.trim())
  let detail
  if (toolName === 'ExitPlanMode') {
    const plan = typeof input.plan === 'string' ? input.plan : ''
    const heading = plan.split('\n').map(line => line.replace(/^#+\s*/, '').trim()).find(Boolean)
    return clip(heading ? `Approve plan: ${heading}` : 'Approve plan', REASON_LIMIT)
  }
  detail = pick('command', 'file_path', 'notebook_path', 'url', 'path', 'pattern', 'query', 'description', 'prompt')
  if (!detail && Object.keys(input).length) detail = stableStringify(input)
  return clip(detail ? `${toolName}: ${detail}` : toolName, REASON_LIMIT)
}

export function hasOwnedBackground(tasks) {
  if (!Array.isArray(tasks)) return false
  return tasks.some(task => task && OWNED_BACKGROUND.has(String(task.type))
    && !SETTLED.has(String(task.status).toLowerCase()))
}

function toQuestions(input) {
  const questions = Array.isArray(input?.questions) ? input.questions : []
  return questions.filter(item => item && typeof item.question === 'string').map((item, index) => ({
    id: String(index),
    question: item.question,
    ...(typeof item.header === 'string' ? { header: item.header } : {}),
    ...(Array.isArray(item.options) ? {
      options: item.options.filter(option => option && typeof option.label === 'string').map(option => ({
        label: option.label,
        ...(typeof option.description === 'string' ? { description: option.description } : {}),
      })),
    } : {}),
    ...(typeof item.multiSelect === 'boolean' ? { multiSelect: item.multiSelect } : {}),
  }))
}

/** Map Notch answers onto AskUserQuestion's `answers` object (question text → label(s)). */
export function toAskAnswers(questions, answers) {
  const byId = new Map((Array.isArray(answers) ? answers : []).map(item => [String(item?.id), item]))
  const result = {}
  for (const question of questions) {
    const item = byId.get(question.id)
    const picked = Array.isArray(item?.selected) ? item.selected.filter(value => typeof value === 'string') : []
    const custom = typeof item?.custom === 'string' ? item.custom.trim() : ''
    const parts = custom ? [...picked, custom] : picked
    result[question.question] = parts.length ? parts.join(', ') : 'Skipped'
  }
  return result
}

export class ClaudeBoard {
  constructor({ now = Date.now, seen = {}, onChange = () => {} } = {}) {
    this.now = now
    this.seen = seen
    this.onChange = onChange
    this.sessions = new Map()
    this.holds = new Map()
    this.focus = null
  }

  session(id) {
    return this.sessions.get(id)
  }

  upsert(input) {
    const id = String(input.session_id)
    let session = this.sessions.get(id)
    if (!session) {
      session = { id, project: '', prompt: '', title: '', pid: 0, bundleId: '', busy: false,
        unread: false, lastTurn: undefined, stateAt: 0, touchedAt: 0 }
      this.sessions.set(id, session)
    }
    if (typeof input.cwd === 'string' && input.cwd) session.project = basename(input.cwd)
    if (typeof input.session_title === 'string' && input.session_title.trim()) session.title = clip(input.session_title, TITLE_LIMIT)
    if (Number.isSafeInteger(input.claude_pid) && input.claude_pid > 1) session.pid = input.claude_pid
    if (typeof input.bundle_id === 'string' && input.bundle_id) session.bundleId = input.bundle_id
    session.touchedAt = this.now()
    return session
  }

  /** Apply one hook event. `at` is when the hook fired, so async hooks that land late stay ordered. */
  apply(input) {
    if (!input || typeof input.session_id !== 'string' || !input.session_id) return false
    const event = String(input.hook_event_name)
    const at = Number.isFinite(input.at) ? input.at : this.now()
    if (event === 'SessionEnd') {
      this.end(input.session_id)
      return true
    }
    const session = this.upsert(input)
    // A turn transition older than the one already applied is a late async hook.
    const fresh = at >= session.stateAt
    switch (event) {
      case 'UserPromptSubmit': {
        if (!session.title && !session.prompt && typeof input.prompt === 'string' && input.prompt.trim()) {
          session.prompt = clip(input.prompt.split('\n').find(line => line.trim()) ?? input.prompt, TITLE_LIMIT)
        }
        // Typing in the conversation is reading it.
        this.markSeen(session.id, at, false)
        this.releaseSession(session.id)
        if (fresh) {
          session.stateAt = at
          session.busy = true
          session.lastTurn = undefined
        }
        break
      }
      case 'PostToolUse':
      case 'PostToolUseFailure': {
        // The dialog was answered elsewhere (terminal, Desktop); stop holding it.
        this.releaseMatching(session.id, stableKey(input.tool_name, input.tool_input))
        // Tool activity implies a live turn, e.g. when the plugin was enabled mid-turn.
        if (fresh && !session.busy) {
          session.stateAt = at
          session.busy = true
          session.lastTurn = undefined
        }
        break
      }
      case 'Stop': {
        this.releaseSession(session.id)
        if (!fresh) break
        session.stateAt = at
        session.busy = hasOwnedBackground(input.background_tasks)
        if (!session.busy) {
          session.lastTurn = { at, kind: 'end_turn', failed: false }
          session.unread = (this.seen[session.id] ?? -Infinity) < at
        }
        break
      }
      case 'StopFailure': {
        this.releaseSession(session.id)
        if (!fresh) break
        session.stateAt = at
        session.busy = false
        session.lastTurn = { at, kind: String(input.error_type || 'error'), failed: true }
        session.unread = (this.seen[session.id] ?? -Infinity) < at
        break
      }
      default:
        break
    }
    this.onChange()
    return true
  }

  end(sessionId) {
    this.releaseSession(sessionId)
    const removed = this.sessions.delete(sessionId)
    if (removed) this.onChange()
    return removed
  }

  /** Drop sessions whose Claude Code process is gone; they can no longer be answered or opened. */
  prune(isAlive, staleMs = 12 * 60 * 60 * 1000) {
    let changed = false
    for (const session of [...this.sessions.values()]) {
      const dead = session.pid > 1 ? isAlive(session.pid) === false : this.now() - session.touchedAt > staleMs
      if (!dead) continue
      this.releaseSession(session.id)
      this.sessions.delete(session.id)
      changed = true
    }
    if (changed) this.onChange()
    return changed
  }

  /** Keep a PermissionRequest open until Notch answers, it is released, or the caller cancels. */
  hold(input) {
    const session = this.upsert(input)
    const toolName = String(input.tool_name ?? '')
    const toolInput = input.tool_input && typeof input.tool_input === 'object' ? input.tool_input : {}
    const id = randomUUID()
    let resolve
    const decision = new Promise(done => { resolve = done })
    const held = { id, sessionId: session.id, toolName, toolInput, key: stableKey(toolName, toolInput), at: this.now(), resolve }
    if (toolName === 'AskUserQuestion') {
      held.kind = 'ask'
      held.questions = toQuestions(toolInput)
      if (!held.questions.length) return { id, decision: Promise.resolve(null), cancel() {} }
    } else {
      held.kind = 'approval'
      held.reason = describeTool(toolName, toolInput)
    }
    this.holds.set(id, held)
    this.onChange()
    return { id, decision, cancel: () => this.release(id) }
  }

  release(id, decision = null) {
    const held = this.holds.get(id)
    if (!held) return false
    this.holds.delete(id)
    held.resolve(decision)
    this.onChange()
    return true
  }

  releaseSession(sessionId) {
    for (const held of [...this.holds.values()]) if (held.sessionId === sessionId) this.release(held.id)
  }

  releaseMatching(sessionId, key) {
    for (const held of [...this.holds.values()]) {
      if (held.sessionId === sessionId && held.key === key) this.release(held.id)
    }
  }

  decideApproval(id, outcome) {
    const held = this.holds.get(id)
    if (!held || held.kind !== 'approval') return false
    if (outcome !== 'allowed-once' && outcome !== 'rejected') return false
    this.markSeen(held.sessionId, this.now(), false)
    return this.release(id, outcome === 'allowed-once'
      ? { behavior: 'allow' }
      : { behavior: 'deny', message: 'The user rejected this tool call from Bot Notch.' })
  }

  answerAsk(id, answers) {
    const held = this.holds.get(id)
    if (!held || held.kind !== 'ask') return false
    this.markSeen(held.sessionId, this.now(), false)
    return this.release(id, {
      behavior: 'allow',
      updatedInput: { ...held.toolInput, answers: toAskAnswers(held.questions, answers) },
    })
  }

  markSeen(sessionId, at = this.now(), notify = true) {
    const session = this.sessions.get(sessionId)
    this.seen[sessionId] = Math.max(this.seen[sessionId] ?? 0, at)
    if (session && (!session.lastTurn || session.lastTurn.at <= at)) session.unread = false
    if (notify) this.onChange()
    return Boolean(session)
  }

  markAllSeen() {
    const at = this.now()
    for (const id of this.sessions.keys()) this.markSeen(id, at, false)
    this.onChange()
  }

  requestFocus(sessionId) {
    const session = this.sessions.get(sessionId)
    if (!session) return undefined
    this.focus = { sessionId, at: this.now() }
    return session
  }

  titleOf(session) {
    const title = session.title || session.prompt || session.id.slice(0, 8)
    return session.project ? `${session.project} · ${title}` : title
  }

  snapshot(origin) {
    const rows = []
    for (const session of this.sessions.values()) {
      const holds = [...this.holds.values()].filter(held => held.sessionId === session.id)
      // Oldest first: further questions queue behind the one being answered.
      const approval = holds.find(held => held.kind === 'approval')
      const ask = holds.find(held => held.kind === 'ask')
      const unread = session.unread && !session.busy
      if (!session.busy && !unread && !approval && !ask) continue
      const row = { id: session.id, title: this.titleOf(session), child: false, busy: session.busy, unread }
      if (session.lastTurn && !session.busy) row.lastTurn = session.lastTurn
      if (approval) row.approval = { id: approval.id, toolName: approval.toolName, reason: approval.reason }
      if (ask) row.ask = { id: ask.id, questions: ask.questions }
      rows.push(row)
    }
    rows.sort((a, b) => Number(Boolean(b.approval || b.ask)) - Number(Boolean(a.approval || a.ask))
      || Number(b.busy) - Number(a.busy)
      || Number(b.unread) - Number(a.unread)
      || (b.lastTurn?.at ?? 0) - (a.lastTurn?.at ?? 0))
    return { ok: true, stateRevision: 4, generatedAt: this.now(), origin, rows }
  }

  diagnostics() {
    return {
      sessions: [...this.sessions.values()].map(({ id, pid, bundleId, busy, unread, lastTurn, stateAt }) =>
        ({ id, pid, bundleId, busy, unread, lastTurn, stateAt })),
      holds: [...this.holds.values()].map(({ id, sessionId, kind, toolName, at }) => ({ id, sessionId, kind, toolName, at })),
    }
  }
}
