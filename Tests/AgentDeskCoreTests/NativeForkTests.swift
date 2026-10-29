import Foundation
import XCTest
@testable import AgentDeskCore

/// Native fork paths, all against local fixtures. No official CLI is run.
final class NativeForkTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentdesk-fork-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: Choosing native fork or replay

    private func session(_ provider: ProviderID, remote: String?, messages: [ChatMessage] = []) -> ChatSession {
        ChatSession(title: "\(provider.rawValue)-\(remote ?? "new")", provider: provider, modelID: "m", remoteSessionID: remote, workingDirectory: "/tmp/x", messages: messages)
    }

    private func branch(parent: ChatSession, child: ChatSession, at messageID: UUID?) throws -> (CanvasBoard, UUID, [UUID: ChatSession]) {
        var board = CanvasBoard(title: "b")
        let p = CanvasNode(sessionID: parent.id, position: .init(x: 0, y: 0))
        let c = CanvasNode(sessionID: child.id, position: .init(x: 300, y: 0))
        board.nodes = [p, c]
        try board.connect(source: p.id, target: c.id, kind: .inherit, sourceMessageID: messageID)
        return (board, c.id, [parent.id: parent, child.id: child])
    }

    func testClaudeForksNativelyOnlyFromTheLatestReply() throws {
        let q = ChatMessage(role: .user, text: "q"), a = ChatMessage(role: .assistant, text: "a")
        let parent = session(.claude, remote: "claude-parent", messages: [q, a])
        let (board, child, sessions) = try branch(parent: parent, child: session(.claude, remote: nil), at: a.id)
        XCTAssertEqual(CanvasContextBuilder.inheritMode(board: board, nodeID: child, sessions: sessions), .native(AgentFork(remoteSessionID: "claude-parent")))
        let context = CanvasContextBuilder.context(board: board, nodeID: child, sessions: sessions)
        XCTAssertEqual(context.fork, AgentFork(remoteSessionID: "claude-parent"))
        XCTAssertTrue(context.inherited.isEmpty)
        XCTAssertEqual(CanvasContextBuilder.compose(userText: "child", context: context), "child")
        XCTAssertEqual(context.sourceLabels, ["继承：claude-claude-parent（原生分叉）"])

        var moved = parent
        moved.messages += [.init(role: .user, text: "later"), .init(role: .assistant, text: "later answer")]
        let (board2, child2, sessions2) = try branch(parent: moved, child: session(.claude, remote: nil), at: a.id)
        guard case .replay(let reason)? = CanvasContextBuilder.inheritMode(board: board2, nodeID: child2, sessions: sessions2) else { return XCTFail("expected replay") }
        XCTAssertTrue(reason.contains("最新一轮"))
        let replay = CanvasContextBuilder.context(board: board2, nodeID: child2, sessions: sessions2)
        XCTAssertNil(replay.fork)
        XCTAssertEqual(replay.inherited.first?.messages.map(\.text), ["q", "a"])
    }

    func testCodexForksThroughTheRecordedTurn() throws {
        var a1 = ChatMessage(role: .assistant, text: "a1"); a1.providerTurnID = "turn-1"
        let a2 = ChatMessage(role: .assistant, text: "a2 without turn id")
        let parent = session(.codex, remote: "thr-parent", messages: [.init(role: .user, text: "q1"), a1, .init(role: .user, text: "q2"), a2])
        let (board, child, sessions) = try branch(parent: parent, child: session(.codex, remote: nil), at: a1.id)
        XCTAssertEqual(CanvasContextBuilder.inheritMode(board: board, nodeID: child, sessions: sessions), .native(AgentFork(remoteSessionID: "thr-parent", throughTurnID: "turn-1")))

        // Latest reply without a recorded turn: fork the whole thread.
        let (board2, child2, sessions2) = try branch(parent: parent, child: session(.codex, remote: nil), at: a2.id)
        XCTAssertEqual(CanvasContextBuilder.inheritMode(board: board2, nodeID: child2, sessions: sessions2), .native(AgentFork(remoteSessionID: "thr-parent")))

        // Older reply without a turn id (records from before 0.4.1): replay.
        let old = ChatMessage(role: .assistant, text: "old")
        let legacy = session(.codex, remote: "thr-old", messages: [old, .init(role: .user, text: "q"), .init(role: .assistant, text: "new")])
        let (board3, child3, sessions3) = try branch(parent: legacy, child: session(.codex, remote: nil), at: old.id)
        guard case .replay? = CanvasContextBuilder.inheritMode(board: board3, nodeID: child3, sessions: sessions3) else { return XCTFail("expected replay") }
    }

    func testReplayWhenProvidersDifferCursorOrForkFailedBefore() throws {
        let a = ChatMessage(role: .assistant, text: "a")
        let claude = session(.claude, remote: "c", messages: [a])
        var (board, child, sessions) = try branch(parent: claude, child: session(.codex, remote: nil), at: a.id)
        XCTAssertEqual(CanvasContextBuilder.inheritMode(board: board, nodeID: child, sessions: sessions), .replay(reason: "跨 provider 分支"))

        let gemini = session(.gemini, remote: "g", messages: [a])
        (board, child, sessions) = try branch(parent: gemini, child: session(.gemini, remote: nil), at: a.id)
        XCTAssertEqual(CanvasContextBuilder.inheritMode(board: board, nodeID: child, sessions: sessions), .replay(reason: "Cursor 不支持原生分叉"))

        (board, child, sessions) = try branch(parent: claude, child: session(.claude, remote: nil), at: a.id)
        board.edges[0].nativeForkFailed = true
        XCTAssertEqual(CanvasContextBuilder.inheritMode(board: board, nodeID: child, sessions: sessions), .replay(reason: "上次原生分叉没有成功"))

        let streaming = session(.claude, remote: "c", messages: [a, .init(role: .assistant, text: "…", state: .streaming)])
        (board, child, sessions) = try branch(parent: streaming, child: session(.claude, remote: nil), at: a.id)
        XCTAssertEqual(CanvasContextBuilder.inheritMode(board: board, nodeID: child, sessions: sessions), .replay(reason: "父节点正在回复"))
    }

    func testStartedChildInheritsNothingMore() throws {
        let a = ChatMessage(role: .assistant, text: "a")
        let (board, child, sessions) = try branch(parent: session(.claude, remote: "c", messages: [a]), child: session(.claude, remote: "child-own"), at: a.id)
        XCTAssertNil(CanvasContextBuilder.inheritMode(board: board, nodeID: child, sessions: sessions))
        XCTAssertNil(CanvasContextBuilder.context(board: board, nodeID: child, sessions: sessions).fork)
    }

    // MARK: Claude Code arguments and session IDs

    private func request(remote: String?, fork: AgentFork?, executable: URL? = nil) -> AgentRequest {
        AgentRequest(localSessionID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, remoteSessionID: remote, prompt: "hi",
                     workingDirectory: directory, modelID: "sonnet", executableURL: executable ?? directory.appendingPathComponent("none"), forkFrom: fork)
    }

    func testClaudeSessionArguments() throws {
        XCTAssertEqual(try ClaudeBackend.sessionArguments(for: request(remote: nil, fork: AgentFork(remoteSessionID: "parent"))), ["--resume", "parent", "--fork-session"])
        XCTAssertEqual(try ClaudeBackend.sessionArguments(for: request(remote: "own", fork: AgentFork(remoteSessionID: "parent"))), ["--resume", "own"])
        XCTAssertEqual(try ClaudeBackend.sessionArguments(for: request(remote: nil, fork: nil)), ["--session-id", "11111111-1111-4111-8111-111111111111"])
        XCTAssertThrowsError(try ClaudeBackend.sessionArguments(for: request(remote: nil, fork: AgentFork(remoteSessionID: "parent", throughTurnID: "t"))))
    }

    private func claudeFixture(mode: String) throws -> URL {
        let url = directory.appendingPathComponent("claude-fixture")
        try Self.claudeSource.replacingOccurrences(of: "MODE", with: mode).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func collect(_ stream: AsyncThrowingStream<AgentEvent, Error>) async -> ([AgentEvent], Error?) {
        var events: [AgentEvent] = []
        do { for try await e in stream { events.append(e) }; return (events, nil) } catch { return (events, error) }
    }

    func testClaudeForkReportsTheNewSessionOnlyAfterSuccess() async throws {
        let ok = try claudeFixture(mode: "ok")
        let (events, error) = await collect(ClaudeBackend().stream(request(remote: nil, fork: AgentFork(remoteSessionID: "parent-id"), executable: ok)))
        XCTAssertNil(error)
        XCTAssertEqual(events.compactMap { if case .sessionID(let id) = $0 { return id }; return nil }, ["forked-id"])
        XCTAssertTrue(events.contains(.textDelta("ARGS --resume parent-id --fork-session")))
        XCTAssertEqual(events.last, .completed)
    }

    func testClaudeReportsTheSessionIDOnceAlthoughEveryLineCarriesIt() async throws {
        let ok = try claudeFixture(mode: "ok")
        let (events, error) = await collect(ClaudeBackend().stream(request(remote: nil, fork: nil, executable: ok)))
        XCTAssertNil(error)
        XCTAssertEqual(events.compactMap { if case .sessionID(let id) = $0 { return id }; return nil }, ["forked-id"])
        XCTAssertEqual(events.last, .completed)
    }

    func testFailedClaudeForkKeepsNoSessionID() async throws {
        let fail = try claudeFixture(mode: "missing")
        let (events, error) = await collect(ClaudeBackend().stream(request(remote: nil, fork: AgentFork(remoteSessionID: "gone"), executable: fail)))
        XCTAssertNotNil(error)
        XCTAssertFalse(events.contains { if case .sessionID = $0 { return true }; return false })
    }

    func testClaudeForkThatReusesTheParentIDIsRejected() async throws {
        let same = try claudeFixture(mode: "same")
        let (events, error) = await collect(ClaudeBackend().stream(request(remote: nil, fork: AgentFork(remoteSessionID: "parent-id"), executable: same)))
        XCTAssertTrue(error?.localizedDescription.contains("分叉") == true)
        XCTAssertFalse(events.contains { if case .sessionID = $0 { return true }; return false })
    }

    private static let claudeSource = #"""
#!/usr/bin/python3
import json, sys
args = sys.argv[1:]
if "auth" in args:
    print(json.dumps({"loggedIn": True, "authMethod": "claude.ai", "apiProvider": "firstParty", "subscriptionType": "max"}))
    sys.exit(0)
mode = "MODE"
def out(o): print(json.dumps(o), flush=True)
r = args.index("--resume") if "--resume" in args else -1
shown = " ".join(args[r:r + 3]) if r >= 0 else ""
if mode == "missing":
    print("No conversation found with session ID: gone", flush=True)
    out({"type": "result", "subtype": "error_during_execution", "is_error": True, "session_id": "fresh-empty-id"})
    sys.exit(1)
sid = "parent-id" if mode == "same" else "forked-id"
out({"type": "system", "subtype": "init", "session_id": sid})
out({"type": "stream_event", "session_id": sid, "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "ARGS " + shown}}})
out({"type": "result", "subtype": "success", "is_error": False, "result": "ARGS " + shown, "session_id": sid})
"""#

    // MARK: Codex app-server thread/fork

    private func codexFixture(mode: String) throws -> URL {
        let url = directory.appendingPathComponent("codex-fixture")
        try Self.codexSource.replacingOccurrences(of: "MODE", with: mode).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testCodexForkSendsThreadForkWithLastTurnAndReportsTurnID() async throws {
        let codex = try codexFixture(mode: "ok")
        let fork = AgentFork(remoteSessionID: "thr-parent", throughTurnID: "turn-1")
        let (events, error) = await collect(CodexBackend(executableURL: codex).stream(request(remote: nil, fork: fork, executable: codex)))
        XCTAssertNil(error)
        XCTAssertTrue(events.contains(.sessionID("thr-forked")))
        XCTAssertTrue(events.contains(.textDelta("FORK thr-parent turn-1 excludeTurns=True sandbox=read-only")))
        XCTAssertTrue(events.contains(.turnID("turn-new")))
        XCTAssertTrue(events.contains(.completed))
    }

    func testCodexResumeIgnoresForkOnceTheNodeHasItsOwnThread() async throws {
        let codex = try codexFixture(mode: "ok")
        let (events, error) = await collect(CodexBackend(executableURL: codex).stream(request(remote: "thr-own", fork: AgentFork(remoteSessionID: "thr-parent"), executable: codex)))
        XCTAssertNil(error)
        XCTAssertTrue(events.contains(.sessionID("thr-own")))
        XCTAssertTrue(events.contains(.textDelta("NO_FORK")))
    }

    func testCodexForkReturningTheParentThreadIsRejected() async throws {
        let codex = try codexFixture(mode: "same")
        let (_, error) = await collect(CodexBackend(executableURL: codex).stream(request(remote: nil, fork: AgentFork(remoteSessionID: "thr-parent"), executable: codex)))
        XCTAssertTrue(error?.localizedDescription.contains("分叉") == true)
    }

    private static let codexSource = #"""
#!/usr/bin/python3
import json, sys
mode = "MODE"
fork = None
def send(o):
    sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
for line in sys.stdin:
    try: msg = json.loads(line)
    except Exception: continue
    m, i, p = msg.get("method"), msg.get("id"), msg.get("params", {})
    if m == "initialize": send({"id": i, "result": {}})
    elif m == "config/read": send({"id": i, "result": {"config": {}}})
    elif m == "account/read": send({"id": i, "result": {"account": {"type": "chatgpt"}}})
    elif m == "model/list": send({"id": i, "result": {"data": [{"id": "sonnet", "isDefault": True}], "nextCursor": None}})
    elif m == "thread/resume": send({"id": i, "result": {"thread": {"id": p["threadId"]}}})
    elif m == "thread/start": send({"id": i, "result": {"thread": {"id": "thr-new"}}})
    elif m == "thread/fork":
        fork = "FORK %s %s excludeTurns=%s sandbox=%s" % (p.get("threadId"), p.get("lastTurnId"), p.get("excludeTurns"), p.get("sandbox"))
        send({"id": i, "result": {"thread": {"id": p["threadId"] if mode == "same" else "thr-forked"}}})
    elif m == "turn/start":
        send({"id": i, "result": {"turn": {"id": "turn-new"}}})
        send({"method": "item/agentMessage/delta", "params": {"delta": fork or "NO_FORK"}})
        send({"method": "turn/completed", "params": {"turn": {"id": "turn-new", "status": "completed"}}})
"""#
}
