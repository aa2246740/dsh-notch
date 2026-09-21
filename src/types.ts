/** JSON contract between the Host plugin and the native helper. */

export type ApprovalOutcomeWire = 'allowed-once' | 'rejected'

export interface NotchOption {
  label: string
  description?: string
}

export interface NotchQuestion {
  id: string
  question: string
  detail?: string
  header?: string
  options?: NotchOption[]
  multiSelect?: boolean
  intent?: { kind: 'plan-review'; approve: string }
}

export interface NotchApproval {
  id: string
  toolName: string
  reason?: string
}

export interface NotchAsk {
  id: string
  questions: NotchQuestion[]
}

export interface NotchLastTurn {
  at: number
  kind: string
  failed: boolean
}

export interface NotchRow {
  id: string
  title: string
  child: boolean
  busy: boolean
  unread: boolean
  lastTurn?: NotchLastTurn
  approval?: NotchApproval
  ask?: NotchAsk
}

export interface NotchSnapshot {
  ok: true
  stateRevision?: number
  generatedAt: number
  sidebarSyncedAt?: number
  /** Browser mirror generation observed in a recent heartbeat; absent for legacy clients. */
  sidebarProjectionVersion?: number
  origin: string
  rows: NotchRow[]
}

export interface NotchAnswerItem {
  id: string
  selected: string[]
  custom?: string
}

export interface NotchFocus {
  sessionId: string
  at: number
}
