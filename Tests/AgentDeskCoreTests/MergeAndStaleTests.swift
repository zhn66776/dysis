import Foundation
import XCTest
@testable import AgentDeskCore

final class MergeAndStaleTests: XCTestCase {
    private func session(_ title: String, replies: [String] = []) -> ChatSession {
        var messages: [ChatMessage] = []
        for r in replies { messages += [.init(role: .user, text: "q \(r)"), .init(role: .assistant, text: r)] }
        return ChatSession(title: title, provider: .claude, modelID: "m", remoteSessionID: replies.isEmpty ? nil : "r-\(title)", workingDirectory: "/tmp", messages: messages)
    }

    /// a → b → d, a → c → d (diamond), plus e unconnected.
    private func diamond() throws -> (CanvasBoard, [String: CanvasNode]) {
        var board = CanvasBoard(title: "b")
        let names = ["a", "b", "c", "d", "e"]
        var nodes: [String: CanvasNode] = [:]
        for (i, n) in names.enumerated() { nodes[n] = CanvasNode(sessionID: UUID(), position: .init(x: Double(i) * 100, y: n == "c" ? 200 : 0)) }
        board.nodes = names.map { nodes[$0]! }
        for (s, t) in [("a", "b"), ("a", "c"), ("b", "d"), ("c", "d")] { try board.connect(source: nodes[s]!.id, target: nodes[t]!.id) }
        return (board, nodes)
    }

    func testDownstreamOrderRespectsDependencies() throws {
        let (board, n) = try diamond()
        let order = board.downstreamOrder(from: n["a"]!.id)
        XCTAssertEqual(order.count, 3)
        XCTAssertEqual(order.last, n["d"]!.id)
        XCTAssertFalse(order.contains(n["e"]!.id))
        XCTAssertFalse(order.contains(n["a"]!.id))
        XCTAssertEqual(board.downstreamOrder(from: n["d"]!.id), [])
    }

    func testDownstreamOrderSkipsExcludedNodesButKeepsTheirChildren() throws {
        let (board, n) = try diamond()
        let order = board.downstreamOrder(from: n["a"]!.id) { $0.id != n["b"]!.id }
        XCTAssertEqual(order, [n["c"]!.id, n["d"]!.id])
    }

    func testInheritEdgesDoNotMakeDownstream() throws {
        var board = CanvasBoard(title: "b")
        let p = CanvasNode(sessionID: UUID(), position: .init(x: 0, y: 0)), c = CanvasNode(sessionID: UUID(), position: .init(x: 1, y: 0))
        board.nodes = [p, c]
        try board.connect(source: p.id, target: c.id, kind: .inherit)
        XCTAssertEqual(board.downstreamOrder(from: p.id), [])
    }

    func testStaleMeansAnsweredWithUndeliveredUpstream() throws {
        let source = session("src", replies: ["v1"])
        let target = session("dst", replies: ["answer"])
        let fresh = session("never-ran")
        var board = CanvasBoard(title: "b")
        let sn = CanvasNode(sessionID: source.id, position: .init(x: 0, y: 0))
        let tn = CanvasNode(sessionID: target.id, position: .init(x: 1, y: 0))
        let fn = CanvasNode(sessionID: fresh.id, position: .init(x: 1, y: 1))
        board.nodes = [sn, tn, fn]
        try board.connect(source: sn.id, target: tn.id)
        try board.connect(source: sn.id, target: fn.id)
        var sessions = [source.id: source, target.id: target, fresh.id: fresh]

        // Target answered without ever receiving v1; a node that never ran is not stale.
        XCTAssertEqual(CanvasContextBuilder.staleNodes(board: board, sessions: sessions), [tn.id])
        XCTAssertEqual(CanvasContextBuilder.staleNodes(board: board, sessions: sessions, running: [target.id]), [])

        board.edges[0].lastDeliveredMessageID = source.messages.last!.id
        XCTAssertEqual(CanvasContextBuilder.staleNodes(board: board, sessions: sessions), [])

        var updated = source
        updated.messages += [.init(role: .user, text: "again"), .init(role: .assistant, text: "v2")]
        sessions[source.id] = updated
        XCTAssertEqual(CanvasContextBuilder.staleNodes(board: board, sessions: sessions), [tn.id])
    }

    func testRerunPromptRepeatsTheLastQuestionOnce() {
        let s = session("x", replies: ["a"])
        let first = CanvasContextBuilder.rerunPrompt(for: s)!
        XCTAssertTrue(first.hasSuffix("q a"))
        var again = s
        again.messages.append(.init(role: .user, text: first))
        XCTAssertEqual(CanvasContextBuilder.rerunPrompt(for: again), first)
        XCTAssertNil(CanvasContextBuilder.rerunPrompt(for: session("empty")))
    }

    func testMergeTemplatesNameTheSourceCount() {
        for template in CanvasMergeTemplate.allCases {
            XCTAssertTrue(template.prompt(sourceCount: 3).contains("3"))
            XCTAssertFalse(template.title.isEmpty)
        }
        XCTAssertEqual(CanvasMergeTemplate.compare.title, "对比")
    }

    func testNodeWithoutMergeFieldStillLoads() throws {
        let old = Data(#"{"id":"00000000-0000-0000-0000-000000000001","sessionID":"00000000-0000-0000-0000-000000000002","position":{"x":1,"y":2}}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(CanvasNode.self, from: old).merge)
        let merged = CanvasNode(sessionID: UUID(), position: .init(x: 0, y: 0), merge: .critique)
        XCTAssertEqual(try JSONDecoder().decode(CanvasNode.self, from: JSONEncoder().encode(merged)).merge, .critique)
    }
}
