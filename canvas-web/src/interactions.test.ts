import { describe, expect, it } from 'vitest'
import { latestReadable, searchExcerpt, toggleExpanded, watchedSessions } from './interactions'
import { initialState } from './store'
import { createMockHost } from './mock'
import type { Incoming, StatePayload } from './types'

describe('canvas interaction state', () => {
  it('watches the panel, its parent and expanded cards without losing the panel identity', () => {
    const node = (id: string) => ({ id, sessionID: `s-${id}`, x: 0, y: 0, stale: false, downstream: 0 })
    const state = { ...initialState, board: { id: 'b', title: 'b', nodes: [node('a'), { ...node('b'), inherited: { fromNodeID: 'a', messageCount: 2 } }, node('c')], edges: [] } }
    expect(watchedSessions(state, 'b', ['c', 'b', 'deleted'])).toEqual(['s-b', 's-a', 's-c'])
    expect(watchedSessions(state, null, ['c'])).toEqual(['s-c'])
    expect(watchedSessions({ ...state, board: null }, 'b', ['c'])).toEqual([])
  })

  it('reserves watched transcript capacity for the panel when expanding many cards', () => {
    const ids = ['a', 'b', 'c', 'd', 'e', 'f', 'g']
    const expanded = toggleExpanded(ids.slice(0, 6), 'g', ids)
    expect(expanded).toEqual(ids.slice(1))
    expect(toggleExpanded(expanded, 'g', ids)).toEqual(ids.slice(1, 6))
    expect(toggleExpanded(['other-board'], 'a', ids)).toEqual(['a'])
  })

  it('keeps complete Markdown for expanded reading and returns no stale text for empty sessions', () => {
    const message = { id: 'm', role: 'assistant' as const, state: 'complete' as const, text: '```py\nprint(1)\n```', createdAt: 0 }
    expect(latestReadable([message])?.text).toBe(message.text)
    expect(latestReadable([])).toBeUndefined()
  })

  it('produces bounded search excerpts around historical matches', () => {
    const excerpt = searchExcerpt('x'.repeat(300) + 'NEEDLE\n结果' + 'x'.repeat(200), 'needle')
    expect(excerpt).toContain('NEEDLE 结果')
    expect(excerpt!.length).toBeLessThan(200)
    expect(searchExcerpt('abc', 'missing')).toBeNull()
  })

  it('creates a fixed quote without sending, then searches and previews that input', () => {
    const events: Incoming[] = []
    const handle = createMockHost(p => events.push(p))
    handle({ type: 'ready' })
    const state = events.at(-1) as StatePayload
    const board = state.board!
    const source = board.nodes[0]
    const messageID = state.summaries!.find(s => s.id === source.sessionID)!.latestReplyID!
    handle({ type: 'node.quote', boardID: board.id, nodeID: source.id, messageID })
    const quoted = events.at(-1) as StatePayload
    const edge = quoted.board!.edges.at(-1)!
    expect(edge.sourceMessageID).toBe(messageID)
    expect(quoted.running).toEqual([])
    expect(quoted.board!.nodes.at(-1)!.inherited).toBeUndefined()
    handle({ type: 'context.preview', boardID: board.id, nodeID: edge.target, text: '比较', id: 'preview' })
    expect(events.at(-1)).toMatchObject({ type: 'context.preview', id: 'preview', nodeID: edge.target })
    expect((events.at(-1) as { text: string }).text).toContain('订阅制')
    handle({ type: 'board.search', boardID: board.id, text: '年付打八折', id: 'search' })
    expect(events.at(-1)).toMatchObject({ type: 'search.results', id: 'search', hits: [{ nodeID: source.id, messageID }] })
  })
})
