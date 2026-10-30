import type { Node } from '@xyflow/react'
import type { BoardPayload, CanvasGroup, NodeSize } from './types'

export function groupBounds(group: CanvasGroup, nodes: Node[]) {
  const members = nodes.filter(n => group.nodeIDs.includes(n.id))
  if (!members.length) return null
  const x = Math.min(...members.map(n => n.position.x)) - 24
  const y = Math.min(...members.map(n => n.position.y)) - 48
  return { x, y,
    width: Math.max(...members.map(n => n.position.x + (n.measured?.width ?? n.width ?? 240))) + 24 - x,
    height: Math.max(...members.map(n => n.position.y + (n.measured?.height ?? n.height ?? 160))) + 24 - y,
  }
}

/** React Flow can report the same selection again after node measurement. */
export function stableSelection(previous: string[], next: string[]) {
  return previous.length === next.length && next.every(id => previous.includes(id)) ? previous : next
}

/** Text editing shortcuts belong to the focused editor; canvas shortcuts act on the board. */
export function canvasHistoryAction(key: string, modifier: boolean, shift: boolean, editing: boolean, modal: boolean) {
  if (!modifier || editing || modal || key.toLowerCase() !== 'z') return null
  return shift ? 'board.redo' as const : 'board.undo' as const
}

// Browser-preview counterpart to the native layout, used without a model or server.
export function previewLayout(board: BoardPayload, sizes: NodeSize[]) {
  const measured = new Map(sizes.map(s => [s.nodeID, s]))
  const dimensions = new Map(board.nodes.map(n => [n.id, measured.get(n.id) ?? { width: 240, height: 160 }]))
  const place = (ids: string[], links: [string, string][], dims: Map<string, { width: number; height: number }>) => {
    const pending = new Set(ids), rank = new Map(ids.map(id => [id, 0])), order: string[] = []
    while (pending.size) {
      const next = ids.find(id => pending.has(id) && !links.some(([a, b]) => b === id && pending.has(a))) ?? ids.find(id => pending.has(id))!
      pending.delete(next); order.push(next)
      for (const [a, b] of links) if (a === next && pending.has(b)) rank.set(b, Math.max(rank.get(b)!, rank.get(next)! + 1))
    }
    const positions = new Map<string, { x: number; y: number }>()
    let x = 0
    for (const layer of [...new Set(rank.values())].sort((a, b) => a - b)) {
      let y = 0, width = 0
      for (const id of order.filter(id => rank.get(id) === layer)) {
        const d = dims.get(id)!
        positions.set(id, { x, y }); y += d.height + 64; width = Math.max(width, d.width)
      }
      x += width + 100
    }
    return positions
  }
  const members = new Map<string, string[]>(), owner = new Map<string, string>()
  for (const group of board.groups ?? []) {
    const ids = group.nodeIDs.filter(id => dimensions.has(id) && !owner.has(id))
    if (!ids.length) continue
    members.set(group.id, ids); ids.forEach(id => owner.set(id, group.id))
  }
  for (const node of board.nodes) if (!owner.has(node.id)) { members.set(node.id, [node.id]); owner.set(node.id, node.id) }
  const local = new Map<string, { x: number; y: number }>(), unitSizes = new Map<string, { width: number; height: number }>()
  const links: [string, string][] = board.edges.map(e => [e.source, e.target])
  for (const [id, ids] of members) {
    const grouped = board.groups?.some(g => g.id === id)
    const positions = place(ids, links, dimensions)
    ids.forEach(n => local.set(n, { x: positions.get(n)!.x + (grouped ? 24 : 0), y: positions.get(n)!.y + (grouped ? 48 : 0) }))
    unitSizes.set(id, { width: Math.max(...ids.map(n => local.get(n)!.x + dimensions.get(n)!.width)) + (grouped ? 24 : 0), height: Math.max(...ids.map(n => local.get(n)!.y + dimensions.get(n)!.height)) + (grouped ? 24 : 0) })
  }
  const origins = place([...members.keys()], links.map(([a, b]): [string, string] => [owner.get(a)!, owner.get(b)!]).filter(([a, b]) => a !== b), unitSizes)
  return board.nodes.map(n => ({ nodeID: n.id, x: 80 + origins.get(owner.get(n.id)!)!.x + local.get(n.id)!.x, y: 80 + origins.get(owner.get(n.id)!)!.y + local.get(n.id)!.y }))
}
