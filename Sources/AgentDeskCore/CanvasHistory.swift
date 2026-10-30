import Foundation

public struct CanvasHistoryStatus: Encodable, Equatable, Sendable {
    public var undoLabel: String?
    public var redoLabel: String?
    public init(undoLabel: String? = nil, redoLabel: String? = nil) { self.undoLabel = undoLabel; self.redoLabel = redoLabel }
}

/// Canvas edits contain no transcript, provider session, or viewport state.
/// Creating/deleting conversations starts a new editing history in the owner.
public struct CanvasEditHistory {
    private struct Arrangement: Equatable {
        let positions: [UUID: CanvasPoint]
        let groups: [CanvasGroup]
        let edges: [CanvasEdge]
        init(_ board: CanvasBoard) {
            positions = Dictionary(uniqueKeysWithValues: board.nodes.map { ($0.id, $0.position) })
            groups = board.groups; edges = board.edges
        }
    }
    private struct Entry { let label: String; let before: Arrangement; let after: Arrangement }
    private var past: [Entry] = []
    private var future: [Entry] = []
    // Keep delivery/fork state when an edge is removed, so redo never replays an old input.
    private var edgeStates: [UUID: CanvasEdge] = [:]
    public init() {}
    public var status: CanvasHistoryStatus { .init(undoLabel: past.last?.label, redoLabel: future.last?.label) }

    public mutating func record(before: CanvasBoard, after: CanvasBoard, label: String) {
        let a = Arrangement(before), b = Arrangement(after)
        guard a != b else { return }
        for edge in before.edges + after.edges { edgeStates[edge.id] = edge }
        past.append(.init(label: label, before: a, after: b))
        if past.count > 100 { past.removeFirst() }
        future.removeAll()
        pruneEdgeStates()
    }

    @discardableResult
    public mutating func undo(_ board: inout CanvasBoard) -> Bool {
        guard let entry = past.popLast() else { return false }
        restore(entry.before, to: &board)
        future.append(entry)
        return true
    }

    @discardableResult
    public mutating func redo(_ board: inout CanvasBoard) -> Bool {
        guard let entry = future.popLast() else { return false }
        restore(entry.after, to: &board)
        past.append(entry)
        return true
    }

    private mutating func restore(_ arrangement: Arrangement, to board: inout CanvasBoard) {
        for edge in board.edges { edgeStates[edge.id] = edge }
        for i in board.nodes.indices {
            if let p = arrangement.positions[board.nodes[i].id] { board.nodes[i].position = p }
        }
        board.groups = arrangement.groups
        board.normalizeGroups()
        let valid = Set(board.nodes.map(\.id))
        board.edges = arrangement.edges.filter { valid.contains($0.source) && valid.contains($0.target) }.map { saved in
            var edge = saved
            if let state = edgeStates[edge.id] {
                edge.lastDeliveredMessageID = state.lastDeliveredMessageID
                edge.nativeForkFailed = state.nativeForkFailed
            }
            return edge
        }
    }

    private mutating func pruneEdgeStates() {
        let ids = Set((past + future).flatMap { $0.before.edges.map(\.id) + $0.after.edges.map(\.id) })
        edgeStates = edgeStates.filter { ids.contains($0.key) }
    }
}
