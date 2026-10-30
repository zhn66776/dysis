import Foundation

public struct CanvasNodeSize: Codable, Equatable, Sendable {
    public let nodeID: UUID
    public let width: Double
    public let height: Double
    public init(nodeID: UUID, width: Double, height: Double) { self.nodeID = nodeID; self.width = width; self.height = height }
}

/// Lay out members inside each group, then lay out groups and standalone nodes.
/// Only positions change; content, group membership and dependencies stay intact.
public enum CanvasLayout {
    public static func positions(board: CanvasBoard, sizes: [CanvasNodeSize]) -> [UUID: CanvasPoint] {
        let measured = Dictionary(sizes.filter { $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 }
            .map { ($0.nodeID, CanvasPoint(x: $0.width, y: $0.height)) }, uniquingKeysWith: { _, last in last })
        let dimensions = Dictionary(uniqueKeysWithValues: board.nodes.map { ($0.id, measured[$0.id] ?? .init(x: 240, y: 160)) })
        var units: [UUID] = [], members: [UUID: [UUID]] = [:], owner: [UUID: UUID] = [:]
        for group in board.groups {
            let ids = group.nodeIDs.filter { dimensions[$0] != nil && owner[$0] == nil }
            guard !ids.isEmpty else { continue }
            units.append(group.id); members[group.id] = ids
            for id in ids { owner[id] = group.id }
        }
        for node in board.nodes where owner[node.id] == nil {
            units.append(node.id); members[node.id] = [node.id]; owner[node.id] = node.id
        }
        var local: [UUID: CanvasPoint] = [:], unitSizes: [UUID: CanvasPoint] = [:]
        let groupIDs = Set(board.groups.map(\.id))
        for unit in units {
            let ids = members[unit] ?? []
            if groupIDs.contains(unit) {
                let layout = place(ids: ids, edges: board.edges.map { ($0.source, $0.target) }, sizes: dimensions)
                for (id, point) in layout { local[id] = .init(x: point.x + 24, y: point.y + 48) }
                unitSizes[unit] = .init(x: ids.map { (local[$0]?.x ?? 0) + (dimensions[$0]?.x ?? 0) }.max()! + 24,
                                        y: ids.map { (local[$0]?.y ?? 0) + (dimensions[$0]?.y ?? 0) }.max()! + 24)
            } else if let id = ids.first { local[id] = .init(x: 0, y: 0); unitSizes[unit] = dimensions[id] }
        }
        let links = board.edges.compactMap { edge -> (UUID, UUID)? in
            guard let a = owner[edge.source], let b = owner[edge.target], a != b else { return nil }
            return (a, b)
        }
        let origins = place(ids: units, edges: links, sizes: unitSizes)
        var result: [UUID: CanvasPoint] = [:]
        for node in board.nodes {
            guard let unit = owner[node.id], let origin = origins[unit], let offset = local[node.id] else { continue }
            result[node.id] = .init(x: 80 + origin.x + offset.x, y: 80 + origin.y + offset.y)
        }
        return result
    }

    private static func place(ids: [UUID], edges: [(UUID, UUID)], sizes: [UUID: CanvasPoint]) -> [UUID: CanvasPoint] {
        guard !ids.isEmpty else { return [:] }
        let valid = Set(ids)
        let links = edges.filter { valid.contains($0.0) && valid.contains($0.1) && $0.0 != $0.1 }
        if links.isEmpty {
            let columns = min(CanvasBoard.gridColumns, Int(ceil(sqrt(Double(ids.count)))))
            let rows = (ids.count + columns - 1) / columns
            var widths = Array(repeating: 0.0, count: columns), heights = Array(repeating: 0.0, count: rows)
            for (i, id) in ids.enumerated() {
                let size = sizes[id] ?? .init(x: 240, y: 160)
                widths[i % columns] = max(widths[i % columns], size.x)
                heights[i / columns] = max(heights[i / columns], size.y)
            }
            return Dictionary(uniqueKeysWithValues: ids.enumerated().map { i, id in
                (id, CanvasPoint(x: widths.prefix(i % columns).reduce(0, +) + Double(i % columns) * 100,
                                 y: heights.prefix(i / columns).reduce(0, +) + Double(i / columns) * 64))
            })
        }
        var remaining = Set(ids), rank = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0) })
        var ordered: [UUID] = []
        while !remaining.isEmpty {
            // Grouping an acyclic graph can create a cycle between groups. Break ties
            // in stored order so those groups still get a stable, non-overlapping layout.
            guard let next = ids.first(where: { id in remaining.contains(id) && !links.contains { $0.1 == id && remaining.contains($0.0) } })
                    ?? ids.first(where: { remaining.contains($0) }) else { break }
            remaining.remove(next); ordered.append(next)
            for (source, target) in links where source == next && remaining.contains(target) {
                rank[target] = max(rank[target] ?? 0, (rank[next] ?? 0) + 1)
            }
        }
        var x = 0.0, positions: [UUID: CanvasPoint] = [:]
        for layer in Set(rank.values).sorted() {
            var y = 0.0, width = 0.0
            for id in ordered where rank[id] == layer {
                let size = sizes[id] ?? .init(x: 240, y: 160)
                positions[id] = .init(x: x, y: y)
                y += size.y + 64; width = max(width, size.x)
            }
            x += width + 100
        }
        return positions
    }
}
