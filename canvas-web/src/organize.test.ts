import { describe, expect, it } from 'vitest'
import { canvasHistoryAction, groupBounds, previewLayout, stableSelection } from './organize'
import { createMockHost } from './mock'
import type { Incoming, StatePayload } from './types'

describe('canvas organization', () => {
  it('wraps expanded cards in a frame with header and padding', () => {
    const g = { id: 'g', title: 'g', nodeIDs: ['a', 'b'] }
    expect(groupBounds(g, [
      { id: 'a', position: { x: 100, y: 120 }, data: {}, measured: { width: 320, height: 500 } },
      { id: 'b', position: { x: 500, y: 300 }, data: {}, measured: { width: 240, height: 160 } },
    ])).toEqual({ x: 76, y: 72, width: 688, height: 572 })
    expect(groupBounds(g, [])).toBeNull()
  })

  it('keeps repeated multi-selection reports stable after node measurements', () => {
    const previous = ['a', 'b']
    expect(stableSelection(previous, ['a', 'b'])).toBe(previous)
    expect(stableSelection(previous, ['b', 'a'])).toBe(previous)
    expect(stableSelection(previous, ['a', 'c'])).toEqual(['a', 'c'])
  })

  it('routes undo shortcuts to the canvas only when an editor or modal does not own them', () => {
    expect(canvasHistoryAction('z', true, false, false, false)).toBe('board.undo')
    expect(canvasHistoryAction('Z', true, true, false, false)).toBe('board.redo')
    expect(canvasHistoryAction('z', true, false, true, false)).toBeNull()
    expect(canvasHistoryAction('z', true, false, false, true)).toBeNull()
    expect(canvasHistoryAction('z', false, false, false, false)).toBeNull()
  })

  it('groups, renames, lays out, undoes and redoes without creating model turns', () => {
    const events: Incoming[] = [], handle = createMockHost(p => events.push(p))
    const state = () => events.at(-1) as StatePayload
    handle({ type: 'ready' })
    const b = state().board!, ids = b.nodes.map(n => n.id)
    handle({ type: 'group.create', boardID: b.id, nodeIDs: ids })
    const group = state().board!.groups![0]
    handle({ type: 'group.rename', boardID: b.id, groupID: group.id, title: '调研' })
    expect(state().board!.groups![0].title).toBe('调研')
    handle({ type: 'board.layout', boardID: b.id, sizes: [] })
    const arranged = state().board!.nodes
    expect(arranged[1].x).toBeGreaterThan(arranged[0].x)
    expect(state().fitBoardID).toBe(b.id)
    handle({ type: 'board.undo', boardID: b.id })
    expect(state().board!.nodes.map(n => [n.x, n.y])).toEqual(b.nodes.map(n => [n.x, n.y]))
    handle({ type: 'board.redo', boardID: b.id })
    expect(state().board!.nodes).toEqual(arranged)
    handle({ type: 'group.dissolve', boardID: b.id, groupID: group.id })
    expect(state().board!.groups).toEqual([])
    handle({ type: 'board.undo', boardID: b.id })
    expect(state().board!.groups![0].title).toBe('调研')
    expect(state().running).toEqual([])
    expect(state().board!.nodes.map(n => n.sessionID)).toEqual(b.nodes.map(n => n.sessionID))
  })

  it('keeps group frames apart when measurements include a tall expanded card', () => {
    const node = (id: string) => ({ id, sessionID: id, x: 0, y: 0, stale: false, downstream: 0 })
    const positions = previewLayout({ id: 'b', title: 'b', nodes: ['a', 'b', 'c'].map(node), edges: [{ id: 'e', kind: 'data', source: 'a', target: 'b' }], groups: [{ id: 'g', title: 'g', nodeIDs: ['a', 'b'] }] }, [{ nodeID: 'a', width: 320, height: 500 }])
    expect(positions).toHaveLength(3)
    expect(positions.find(n => n.nodeID === 'b')!.x).toBeGreaterThan(positions.find(n => n.nodeID === 'a')!.x + 320)
    expect(positions.find(n => n.nodeID === 'c')!.x).toBeGreaterThan(positions.find(n => n.nodeID === 'b')!.x + 240)
  })
})
