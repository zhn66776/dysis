import Foundation
import XCTest
@testable import AgentDeskCore

final class CanvasOrganizationTests: XCTestCase {
    private func board(_ count: Int = 5) -> CanvasBoard {
        CanvasBoard(title: "board", nodes: (0..<count).map { i in CanvasNode(sessionID: UUID(), position: .init(x: Double(i * 20), y: 0)) })
    }

    func testGroupsRoundTripAndLegacyBoardsLoadWithoutGroups() throws {
        var b = board()
        let ids = b.nodes.map(\.id)
        let groupID = try XCTUnwrap(b.group(nodeIDs: Set(ids.prefix(2))))
        let data = try JSONEncoder().encode(b)
        XCTAssertEqual(try JSONDecoder().decode(CanvasBoard.self, from: data), b)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "groups")
        let legacy = try JSONDecoder().decode(CanvasBoard.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertTrue(legacy.groups.isEmpty)
        XCTAssertEqual(legacy.nodes, b.nodes)
        let second = try XCTUnwrap(b.group(nodeIDs: Set([ids[1], ids[2]])))
        XCTAssertEqual(b.groups.first { $0.id == groupID }?.nodeIDs, [ids[0]])
        b.group(nodeIDs: Set([ids[0], ids[3]]), into: second)
        XCTAssertFalse(b.groups.contains { $0.id == groupID })
        XCTAssertEqual(Set(b.groups[0].nodeIDs), Set(ids.prefix(4)))
        b.removeNodes(Set(ids.prefix(4)))
        XCTAssertTrue(b.groups.isEmpty)
    }

    func testLayoutRespectsDependenciesAndMeasuredCardsInsideDisjointGroups() throws {
        var b = board()
        let ids = b.nodes.map(\.id)
        try b.connect(source: ids[0], target: ids[1])
        try b.connect(source: ids[1], target: ids[2])
        try b.connect(source: ids[2], target: ids[3])
        b.group(nodeIDs: Set(ids.prefix(2)))
        b.group(nodeIDs: Set(ids[2...3]))
        let sizes = b.nodes.map { CanvasNodeSize(nodeID: $0.id, width: $0.id == ids[0] ? 320 : 240, height: $0.id == ids[0] ? 520 : 160) }
        let originalEdges = b.edges, originalGroups = b.groups
        let positions = CanvasLayout.positions(board: b, sizes: sizes)
        XCTAssertEqual(positions.count, b.nodes.count)
        XCTAssertEqual(positions, CanvasLayout.positions(board: b, sizes: sizes))
        for edge in b.edges { XCTAssertLessThan(positions[edge.source]!.x, positions[edge.target]!.x) }
        for i in sizes.indices {
            for j in sizes.indices where i < j {
                let a = positions[sizes[i].nodeID]!, c = positions[sizes[j].nodeID]!
                let overlaps = a.x < c.x + sizes[j].width && a.x + sizes[i].width > c.x && a.y < c.y + sizes[j].height && a.y + sizes[i].height > c.y
                XCTAssertFalse(overlaps, "Cards must not overlap, including an expanded card")
            }
        }
        XCTAssertEqual(b.edges, originalEdges); XCTAssertEqual(b.groups, originalGroups)
    }

    func testLayoutHandlesCyclesBetweenGroupsAndInvalidMeasurements() throws {
        var b = board(3)
        let ids = b.nodes.map(\.id)
        try b.connect(source: ids[0], target: ids[1])
        try b.connect(source: ids[1], target: ids[2])
        b.group(nodeIDs: Set([ids[0], ids[2]]))
        b.group(nodeIDs: Set([ids[1]]))
        let p = CanvasLayout.positions(board: b, sizes: [.init(nodeID: ids[0], width: .nan, height: -1)])
        XCTAssertEqual(p.count, 3)
        XCTAssertTrue(p.values.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        XCTAssertEqual(p, CanvasLayout.positions(board: b, sizes: []))
        XCTAssertTrue(CanvasLayout.positions(board: board(0), sizes: []).isEmpty)
    }

    func testUndoRedoPreservesLiveDeliveryStateAndViewportAcrossLayoutEdits() throws {
        var b = board(2), history = CanvasEditHistory()
        let ids = b.nodes.map(\.id), empty = b
        let edge = try b.connect(source: ids[0], target: ids[1])
        history.record(before: empty, after: b, label: "连线")
        let delivered = UUID()
        b.edges[0].lastDeliveredMessageID = delivered
        b.edges[0].nativeForkFailed = true
        let beforeMove = b
        b.nodes[0].position.x = 700
        history.record(before: beforeMove, after: b, label: "移动")
        b.viewport = .init(x: 100, y: 200, zoom: 0.5)
        XCTAssertTrue(history.undo(&b))
        XCTAssertEqual(b.nodes[0].position, empty.nodes[0].position)
        XCTAssertEqual(b.edges[0].lastDeliveredMessageID, delivered)
        XCTAssertTrue(history.undo(&b)); XCTAssertTrue(b.edges.isEmpty)
        XCTAssertTrue(history.redo(&b)); XCTAssertEqual(b.edges[0].id, edge.id)
        XCTAssertEqual(b.edges[0].lastDeliveredMessageID, delivered)
        XCTAssertEqual(b.edges[0].nativeForkFailed, true)
        XCTAssertTrue(history.redo(&b)); XCTAssertEqual(b.nodes[0].position.x, 700)
        XCTAssertEqual(b.viewport?.zoom, 0.5)
        XCTAssertNil(history.status.redoLabel)
    }

    func testNewEditsClearRedoAndNoOpsDoNotConsumeHistory() {
        var b = board(2), history = CanvasEditHistory()
        history.record(before: b, after: b, label: "no-op")
        XCTAssertNil(history.status.undoLabel)
        let before = b
        b.group(nodeIDs: Set(b.nodes.map(\.id)))
        history.record(before: before, after: b, label: "分组")
        XCTAssertTrue(history.undo(&b)); XCTAssertTrue(b.groups.isEmpty)
        XCTAssertTrue(history.redo(&b)); XCTAssertEqual(b.groups.count, 1)
        XCTAssertTrue(history.undo(&b))
        let beforeMove = b
        b.nodes[0].position.y += 100
        history.record(before: beforeMove, after: b, label: "移动")
        XCTAssertNil(history.status.redoLabel)
        XCTAssertFalse(history.redo(&b))
        XCTAssertEqual(b.nodes.map(\.sessionID), before.nodes.map(\.sessionID))
    }
}
