import type { Session } from '@deepseek-ai/dsh-session'
import type { NotchLastTurn } from './types.ts'

export interface FoldedSession {
  busy: boolean
  lastTurn?: NotchLastTurn
}

const FAILED = new Set(['error', 'blocked', 'max-tokens'])

export function foldSession(session: Session): FoldedSession {
  let busy = false
  let lastTurn: NotchLastTurn | undefined
  for (const event of session.snapshotEvents()) {
    if (event.type === 'turn/start') {
      busy = true
      lastTurn = undefined
      continue
    }
    if (event.type === 'turn/end') {
      busy = false
      const kind = event.data.reason.kind
      lastTurn = { at: event.time, kind, failed: FAILED.has(kind) }
    }
  }
  return { busy, lastTurn }
}

export function isChildSession(session: Session): boolean {
  // parentSession is also seed lineage for an independent user fork.
  // Use the same presentation discriminator as Harness's workspace sidebar.
  return session.header.origin === 'subagent'
}

/** Follow only delegation edges; user forks remain separate conversations. */
export function conversationOwner(session: Session, sessions: ReadonlyMap<string, Session>): Session | undefined {
  let current: Session | undefined = session
  const visited = new Set<string>()
  while (current && isChildSession(current)) {
    if (visited.has(current.id)) return undefined
    visited.add(current.id)
    current = current.header.parentSession === undefined ? undefined : sessions.get(current.header.parentSession)
  }
  return current
}
