import type { ISessions } from '@deepseek-ai/dsh-api-session-controller/client'
import type {} from '@deepseek-ai/dsh-client-ui-session/client'
import type {} from '@deepseek-ai/dsh-client-ui-workspace/client'
import type { SessionId } from '@deepseek-ai/dsh-session/types'
/**
 * Headless follower: polls the Host for notch focus wishes and selects the
 * session in every open DSH page (app webview or browser tab).
 *
 * First poll only arms (ignores a wish already sitting there) so a reload
 * does not yank the current session. A later click bumps `at` and opens.
 */
import type { Context as ClientContext } from '@deepseek-ai/cordis'

export const name = 'dsh-notch-focus-client'
export const inject = ['sessions', 'uiWorkspace', 'uiSession']

interface PendingFocusWire {
  ok?: boolean
  focus?: { sessionId?: string; at?: number } | null
}

const POLL_MS = 400

export function apply(ctx: ClientContext): void {
  const sessions = ctx.get('sessions') as unknown as ISessions
  const clientId = crypto.randomUUID()
  let lastAt = 0
  let armed = false
  let stopped = false

  const open = async (sessionId: string): Promise<void> => {
    try {
      ctx.uiWorkspace.openSession(sessionId as SessionId)
      return
    } catch {
      /* list may be stale; refresh once and retry */
    }
    try {
      await sessions.refresh()
      ctx.uiWorkspace.openSession(sessionId as SessionId)
    } catch {
      /* session not in this page's list */
    }
  }

  const poll = async (): Promise<void> => {
    try {
      const snapshot = sessions.list.getSnapshot()
      if (snapshot.phase === 'ready') {
        // parentId also records independent user forks; only origin classifies
        // a delegated child, matching the official workspace sidebar.
        const rows = snapshot.ids.map(id => snapshot.byId[id]).filter(row => row && row.origin !== 'subagent').map(row => ({ id: row.id, title: row.displayTitle, completed: ctx.uiSession.sessionStatus.getSnapshot().get(row.id)?.completionUnread === true, running: row.running, updatedAt: row.updatedAt }))
        const focused = document.hasFocus()
        const current = rows.find(row => row.id === Object.values(snapshot.byId).find(item => (item.retainedBy?.mainView ?? 0) > 0)?.id)
        // updatedAt is the user's prompt timestamp, not the completion time.
        // Capture this observation before sending it, so a delayed request
        // cannot acknowledge a turn that finishes after the user looked.
        const viewed = focused && current && !current.running
          ? { id: current.id, at: Date.now() } : undefined
        await fetch('/dsh-notch/sidebar', { method: 'POST', headers: { 'content-type': 'application/json', 'x-dsh-notch-client': '1' }, body: JSON.stringify({ clientId, projectionVersion: 3, focused, viewed, rows }) })
      }
      if (stopped) return
      const response = await fetch('/dsh-notch/pending-focus', { cache: 'no-store' })
      if (!response.ok) return
      const data = (await response.json()) as PendingFocusWire
      const focus = data.focus
      if (!armed) {
        armed = true
        if (focus && typeof focus.at === 'number') lastAt = focus.at
        return
      }
      if (!focus || typeof focus.at !== 'number' || focus.at <= lastAt) return
      if (typeof focus.sessionId !== 'string' || focus.sessionId === '') return
      lastAt = focus.at
      await open(focus.sessionId)
      try {
        window.focus()
      } catch {
        /* native helper already fronts DSH.app */
      }
    } catch {
      /* Host unreachable mid-poll; the next tick retries. */
    }
  }

  const tick = (): void => {
    if (stopped) return
    void poll().finally(() => {
      if (!stopped) timer = window.setTimeout(tick, POLL_MS)
    })
  }
  let timer = window.setTimeout(tick, POLL_MS)
  void poll()

  ctx.effect(() => () => {
    stopped = true
    window.clearTimeout(timer)
  }, 'dsh-notch-focus: poll')
}
