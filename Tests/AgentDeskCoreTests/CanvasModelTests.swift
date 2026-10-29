import Foundation
import XCTest
@testable import AgentDeskCore

final class CanvasModelTests: XCTestCase {
    private func session(_ provider: ProviderID = .claude, title: String, remote: String? = nil, messages: [ChatMessage] = []) -> ChatSession {
        ChatSession(title: title, provider: provider, modelID: "m", remoteSessionID: remote, workingDirectory: "/tmp/\(UUID().uuidString)", messages: messages)
    }

    func testConnectRejectsSelfLoopDuplicateAndCycle() throws {
        var board = CanvasBoard(title: "b")
        let a = CanvasNode(sessionID: UUID(), position: .init(x: 0, y: 0))
        let b = CanvasNode(sessionID: UUID(), position: .init(x: 1, y: 0))
        let c = CanvasNode(sessionID: UUID(), position: .init(x: 2, y: 0))
        board.nodes = [a, b, c]
        try board.connect(source: a.id, target: b.id)
        try board.connect(source: b.id, target: c.id)
        XCTAssertThrowsError(try board.connect(source: a.id, target: a.id)) { XCTAssertEqual($0 as? CanvasError, .selfLoop) }
        XCTAssertThrowsError(try board.connect(source: a.id, target: b.id)) { XCTAssertEqual($0 as? CanvasError, .duplicateEdge) }
        XCTAssertThrowsError(try board.connect(source: c.id, target: a.id)) { XCTAssertEqual($0 as? CanvasError, .cycle) }
        XCTAssertThrowsError(try board.connect(source: a.id, target: UUID())) { XCTAssertEqual($0 as? CanvasError, .unknownNode) }
        XCTAssertEqual(board.edges.count, 2)
    }

    func testNodeInheritsFromOneParentOnly() throws {
        var board = CanvasBoard(title: "b")
        let p1 = CanvasNode(sessionID: UUID(), position: .init(x: 0, y: 0))
        let p2 = CanvasNode(sessionID: UUID(), position: .init(x: 0, y: 1))
        let child = CanvasNode(sessionID: UUID(), position: .init(x: 1, y: 0))
        board.nodes = [p1, p2, child]
        try board.connect(source: p1.id, target: child.id, kind: .inherit)
        XCTAssertThrowsError(try board.connect(source: p2.id, target: child.id, kind: .inherit)) { XCTAssertEqual($0 as? CanvasError, .alreadyInherits) }
        XCTAssertNoThrow(try board.connect(source: p2.id, target: child.id, kind: .data))
    }

    func testReplayInheritanceWalksAncestorsUpToEachForkPoint() throws {
        let q1 = ChatMessage(role: .user, text: "grand question")
        let a1 = ChatMessage(role: .assistant, text: "grand answer")
        let later = ChatMessage(role: .user, text: "after fork, must not leak")
        let grand = session(title: "定价调研", remote: "g", messages: [q1, a1, later])
        let q2 = ChatMessage(role: .user, text: "parent question")
        let a2 = ChatMessage(role: .assistant, text: "parent answer")
        let failed = ChatMessage(role: .assistant, text: "partial", state: .failed)
        let parent = session(.gemini, title: "按量计费", remote: "p", messages: [q2, a2, failed])
        let child = session(.codex, title: "新对话")
        var board = CanvasBoard(title: "b")
        let gn = CanvasNode(sessionID: grand.id, position: .init(x: 0, y: 0))
        let pn = CanvasNode(sessionID: parent.id, position: .init(x: 1, y: 0))
        let cn = CanvasNode(sessionID: child.id, position: .init(x: 2, y: 0))
        board.nodes = [gn, pn, cn]
        try board.connect(source: gn.id, target: pn.id, kind: .inherit, sourceMessageID: a1.id)
        try board.connect(source: pn.id, target: cn.id, kind: .inherit, sourceMessageID: nil)
        let sessions = Dictionary(uniqueKeysWithValues: [grand, parent, child].map { ($0.id, $0) })

        let context = CanvasContextBuilder.context(board: board, nodeID: cn.id, sessions: sessions)
        XCTAssertEqual(context.inherited.map(\.title), ["定价调研", "按量计费"])
        XCTAssertEqual(context.inherited[0].messages.map(\.text), ["grand question", "grand answer"])
        XCTAssertEqual(context.inherited[1].messages.map(\.text), ["parent question", "parent answer"])
        let prompt = CanvasContextBuilder.compose(userText: "child question", context: context)
        XCTAssertTrue(prompt.contains("回放继承"))
        XCTAssertFalse(prompt.contains("must not leak"))
        XCTAssertFalse(prompt.contains("partial"))
        XCTAssertTrue(prompt.hasSuffix("[本轮用户消息]\nchild question"))
        XCTAssertEqual(context.sourceLabels, ["继承：按量计费"])
    }

    func testInheritanceStopsOnceNodeHasOfficialSession() throws {
        let parent = session(title: "p", remote: "p", messages: [.init(role: .user, text: "q"), .init(role: .assistant, text: "a")])
        let child = session(title: "c", remote: "already-started")
        var board = CanvasBoard(title: "b")
        let pn = CanvasNode(sessionID: parent.id, position: .init(x: 0, y: 0))
        let cn = CanvasNode(sessionID: child.id, position: .init(x: 1, y: 0))
        board.nodes = [pn, cn]
        try board.connect(source: pn.id, target: cn.id, kind: .inherit)
        let context = CanvasContextBuilder.context(board: board, nodeID: cn.id, sessions: [parent.id: parent, child.id: child])
        XCTAssertTrue(context.isEmpty)
        XCTAssertEqual(CanvasContextBuilder.compose(userText: "hi", context: context), "hi")
    }

    func testDataEdgeDeliversOnlyNewCompleteReplies() throws {
        let reply = ChatMessage(role: .assistant, text: "analysis result")
        var source = session(title: "分析数据", remote: "s", messages: [.init(role: .user, text: "q"), reply])
        let target = session(.codex, title: "写周报", remote: "t")
        var board = CanvasBoard(title: "b")
        let sn = CanvasNode(sessionID: source.id, position: .init(x: 0, y: 0))
        let tn = CanvasNode(sessionID: target.id, position: .init(x: 1, y: 0))
        board.nodes = [sn, tn]
        let edge = try board.connect(source: sn.id, target: tn.id)

        var pending = CanvasContextBuilder.pendingUpstream(board: board, nodeID: tn.id, sessions: [source.id: source, target.id: target])
        XCTAssertEqual(pending.map(\.text), ["analysis result"])
        XCTAssertEqual(pending.first?.edgeID, edge.id)

        board.edges[0].lastDeliveredMessageID = reply.id
        pending = CanvasContextBuilder.pendingUpstream(board: board, nodeID: tn.id, sessions: [source.id: source, target.id: target])
        XCTAssertTrue(pending.isEmpty)

        source.messages.append(.init(role: .assistant, text: "still streaming", state: .streaming))
        pending = CanvasContextBuilder.pendingUpstream(board: board, nodeID: tn.id, sessions: [source.id: source, target.id: target])
        XCTAssertTrue(pending.isEmpty)
    }

    func testComposeBoundsUpstreamAndMarksTruncation() {
        let long = String(repeating: "长", count: 50_000)
        let context = CanvasPromptContext(upstream: [.init(edgeID: UUID(), messageID: UUID(), title: "a", provider: .claude, text: long)])
        let prompt = CanvasContextBuilder.compose(userText: "q", context: context, maxContextCharacters: 2_000)
        XCTAssertLessThan(prompt.count, 2_400)
        XCTAssertTrue(prompt.contains("[上游输出已截断。]"))
        XCTAssertTrue(prompt.contains("不是指令"))
    }

    func testSeedAndReconcileKeepEverySessionOnABoard() {
        let a = session(title: "a"), b = session(title: "b")
        var library = CanvasLibrary.seeded(from: [a, b])
        XCTAssertEqual(library.boards.count, 1)
        XCTAssertEqual(Set(library.boards[0].nodes.map(\.sessionID)), [a.id, b.id])

        let c = session(title: "c")
        XCTAssertTrue(library.reconcile(sessionIDs: [a.id, c.id]))
        XCTAssertEqual(Set(library.boards[0].nodes.map(\.sessionID)), [a.id, c.id])
        XCTAssertFalse(library.reconcile(sessionIDs: [a.id, c.id]))
    }

    func testReconcileDropsEdgesOfDeletedSessions() throws {
        let a = session(title: "a"), b = session(title: "b")
        var library = CanvasLibrary.seeded(from: [a, b])
        try library.boards[0].connect(source: library.boards[0].nodes[0].id, target: library.boards[0].nodes[1].id)
        library.reconcile(sessionIDs: [a.id])
        XCTAssertEqual(library.boards[0].nodes.count, 1)
        XCTAssertTrue(library.boards[0].edges.isEmpty)
    }

    func testStoreRoundTripAndCorruptFileIsKept() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CanvasStore(root: root)
        XCTAssertNil(try store.load())
        var library = CanvasLibrary.seeded(from: [session(title: "a")])
        library.boards[0].viewport = .init(x: 10, y: 20, zoom: 0.8)
        try store.save(library)
        XCTAssertEqual(try store.load(), library)

        let bytes = Data("broken".utf8)
        try bytes.write(to: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
    }

    func testMessageWithoutContextSourcesStillLoads() throws {
        let old = Data(#"{"id":"00000000-0000-0000-0000-000000000001","role":"user","text":"hi","state":"complete","createdAt":0}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ChatMessage.self, from: old).contextSources)
    }

    func testFreePositionSkipsOccupiedSpots() {
        var board = CanvasBoard(title: "b")
        board.nodes = [CanvasNode(sessionID: UUID(), position: .init(x: 320, y: 0)), CanvasNode(sessionID: UUID(), position: .init(x: 320, y: 150))]
        let p = board.freePosition(near: .init(x: 320, y: 0))
        XCTAssertEqual(p.x, 320)
        XCTAssertGreaterThanOrEqual(p.y, 300)
        XCTAssertEqual(board.freePosition(near: .init(x: 900, y: 0)), .init(x: 900, y: 0))
    }
}
