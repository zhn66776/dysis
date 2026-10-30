import type { AppState, MessagePayload } from './types'

/** Panel identity is separate from expanded cards so file drops keep their destination. */
export function watchedSessions(state: AppState, selected: string | null, expanded: string[]) {
  const board = state.board
  const node = board?.nodes.find(n => n.id === selected)
  const parent = node?.inherited && board?.nodes.find(n => n.id === node.inherited!.fromNodeID)
  return [...new Set([node?.sessionID, parent ? parent.sessionID : undefined,
    ...board?.nodes.filter(n => expanded.includes(n.id)).map(n => n.sessionID) ?? [],
  ].filter((id): id is string => Boolean(id)))].slice(0, 8)
}

export function latestReadable(messages?: MessagePayload[]) {
  return (messages && [...messages].reverse().find(m => m.role === 'assistant')) ?? messages?.at(-1)
}

export function searchExcerpt(text: string, query: string) {
  const index = text.toLocaleLowerCase().indexOf(query.toLocaleLowerCase())
  if (index < 0) return null
  const start = Math.max(0, index - 45), end = Math.min(text.length, index + query.length + 100)
  return `${start ? '…' : ''}${text.slice(start, end).replace(/\n/g, ' ')}${end < text.length ? '…' : ''}`
}

/** Keep the bridge's eight-transcript bound; reserve two slots for panel + parent. */
export function toggleExpanded(ids: string[], id: string, boardNodeIDs: string[]) {
  const current = ids.filter(n => boardNodeIDs.includes(n))
  return current.includes(id) ? current.filter(n => n !== id) : [...current.slice(-5), id]
}
