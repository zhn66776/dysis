import type { AppState, ConfirmShow, StatePayload } from './types'

export const initialState: AppState = {
  ready: false,
  boards: [],
  board: null,
  summaries: {},
  details: {},
  running: new Set(),
  error: '',
  models: {},
  quotas: {},
  drafts: {},
  chain: { total: 0, index: 0 },
}

/** Applies one Swift state payload. Pure, so it can be tested offline. */
export function applyState(prev: AppState, p: StatePayload): AppState {
  const summaries = p.reset ? {} : { ...prev.summaries }
  const details = p.reset ? {} : { ...prev.details }
  for (const s of p.summaries ?? []) summaries[s.id] = s
  for (const id of p.removedSessions ?? []) { delete summaries[id]; delete details[id] }
  for (const d of p.details ?? []) details[d.id] = d
  const drafts = p.reset ? {} : { ...prev.drafts }
  for (const d of p.drafts ?? []) drafts[d.sessionID] = d
  for (const a of p.appends ?? []) {
    const detail = details[a.sessionID]
    if (!detail) continue
    details[a.sessionID] = {
      ...detail,
      messages: detail.messages.map(m => (m.id === a.messageID ? { ...m, text: m.text + a.text } : m)),
    }
  }
  return {
    ready: true,
    boards: p.boards ?? prev.boards,
    board: p.board ?? (p.reset ? null : prev.board),
    summaries,
    details,
    running: new Set(p.running),
    error: p.error,
    focusNodeID: p.focusNodeID,
    fitBoardID: p.fitBoardID,
    models: p.models ?? (p.reset ? {} : prev.models),
    quotas: p.quotas ?? (p.reset ? {} : prev.quotas),
    drafts,
    memory: p.memory ?? (p.reset ? undefined : prev.memory),
    chain: p.chain ?? prev.chain,
  }
}

/** Confirmations waiting for an answer, oldest first; only the first is shown. */
export function enqueueConfirm(queue: ConfirmShow[], request: ConfirmShow): ConfirmShow[] {
  return queue.some(c => c.id === request.id) ? queue : [...queue, request]
}

/** Drops an answered (or declined) confirmation. */
export function resolveConfirm(queue: ConfirmShow[], id: string): ConfirmShow[] {
  return queue.filter(c => c.id !== id)
}
