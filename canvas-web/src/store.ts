import type { AppState, StatePayload } from './types'

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
    models: p.models ?? (p.reset ? {} : prev.models),
    quotas: p.quotas ?? (p.reset ? {} : prev.quotas),
    drafts,
    chain: p.chain ?? prev.chain,
  }
}
