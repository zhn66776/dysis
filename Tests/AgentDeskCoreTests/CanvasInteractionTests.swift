import Foundation
import XCTest
@testable import AgentDeskCore

final class CanvasInteractionTests: XCTestCase {
    func testFixedQuoteKeepsItsReplyAfterSourceContinuesAndSurvivesStorage() throws {
        let original = ChatMessage(role: .assistant, text: "original result")
        let newer = ChatMessage(role: .assistant, text: "new result")
        let source = ChatSession(title: "source", provider: .claude, modelID: "m", workingDirectory: "/tmp", messages: [original, newer])
        let target = ChatSession(provider: .codex, modelID: "m", workingDirectory: "/tmp")
        var board = CanvasBoard(title: "b")
        let a = CanvasNode(sessionID: source.id, position: .init(x: 0, y: 0))
        let b = CanvasNode(sessionID: target.id, position: .init(x: 400, y: 0))
        board.nodes = [a, b]
        try board.connect(source: a.id, target: b.id, sourceMessageID: original.id)
        let restored = try JSONDecoder().decode(CanvasBoard.self, from: JSONEncoder().encode(board))
        let sessions = [source.id: source, target.id: target]
        let context = CanvasContextBuilder.context(board: restored, nodeID: b.id, sessions: sessions)
        XCTAssertEqual(context.upstream.map(\.text), ["original result"])
        XCTAssertTrue(context.inherited.isEmpty)
        XCTAssertNil(context.fork)
        board.edges[0].lastDeliveredMessageID = original.id
        XCTAssertTrue(CanvasContextBuilder.pendingUpstream(board: board, nodeID: b.id, sessions: sessions).isEmpty)
    }

    func testMissingOrInvalidFixedReplyNeverFallsBackToAnotherReply() {
        let user = ChatMessage(role: .user, text: "question")
        let partial = ChatMessage(role: .assistant, text: "partial", state: .failed)
        let good = ChatMessage(role: .assistant, text: "good")
        let session = ChatSession(provider: .claude, modelID: "m", workingDirectory: "/tmp", messages: [user, partial, good])
        for id in [UUID(), user.id, partial.id] {
            let edge = CanvasEdge(kind: .data, source: UUID(), target: UUID(), sourceMessageID: id)
            XCTAssertNil(CanvasContextBuilder.dataReply(edge: edge, session: session))
        }
        let live = CanvasEdge(kind: .data, source: UUID(), target: UUID())
        XCTAssertEqual(CanvasContextBuilder.dataReply(edge: live, session: session)?.id, good.id)
    }

    func testSearchFindsHistoricalContentOutsidePreviewAndScopesToBoard() {
        let old = ChatMessage(role: .user, text: String(repeating: "早期背景。", count: 100) + "Hidden NEEDLE 研究结论" + String(repeating: "后文。", count: 100))
        let source = ChatSession(title: "调研", provider: .claude, modelID: "m", workingDirectory: "/tmp", messages: [old, .init(role: .assistant, text: "recent reply")])
        let outside = ChatSession(title: "needle", provider: .codex, modelID: "m", workingDirectory: "/tmp")
        var board = CanvasBoard(title: "b")
        let node = CanvasNode(sessionID: source.id, position: .init(x: 0, y: 0))
        board.nodes = [node]
        let sessions = [source.id: source, outside.id: outside]
        let hits = CanvasSearch.find(" needle ", board: board, sessions: sessions)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.nodeID, node.id)
        XCTAssertEqual(hits.first?.messageID, old.id)
        XCTAssertTrue(hits.first?.excerpt.contains("NEEDLE") == true)
        XCTAssertLessThan(hits.first?.excerpt.count ?? 999, 200)
        XCTAssertTrue(CanvasSearch.find("  ", board: board, sessions: sessions).isEmpty)
        XCTAssertTrue(CanvasSearch.find("missing", board: board, sessions: sessions).isEmpty)
        XCTAssertNil(CanvasSearch.find("调研", board: board, sessions: sessions).first?.messageID)
        XCTAssertEqual(CanvasSearch.find("研究结论", board: board, sessions: sessions).first?.messageID, old.id)
    }
}
