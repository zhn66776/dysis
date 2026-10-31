import Foundation
import XCTest
@testable import AgentDeskCore

/// Structured steps, turn diffs, checkpoints and undo (HARNESS.md H3).
final class StepEventTests: XCTestCase {
    private func fixture(_ name: String) throws -> [[String: Any]] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "jsonl"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    private func steps(_ events: [StepEvent]) -> [MessageStep] {
        var steps: [MessageStep] = []
        for event in events { steps.apply(event) }
        return steps
    }

    // MARK: Parsers on recorded-shape fixtures

    func testCodexItemsBecomeSteps() throws {
        var events: [AgentEvent] = []
        for line in try fixture("codex-steps") {
            events += CodexStepParser.events(method: line["method"] as? String ?? "", params: line["params"] as? [String: Any] ?? [:])
        }
        let result = steps(events.compactMap { if case .step(let s) = $0 { return s }; return nil })
        XCTAssertEqual(result.map(\.id), ["call-ls", "call-patch", "call-test", "call-mcp", "call-rm"])
        XCTAssertEqual(result.map(\.kind), [.read, .fileChange, .command, .mcp, .command])
        XCTAssertEqual(result.map(\.state), [.done, .done, .failed, .done, .declined])
        XCTAssertEqual(result[0].exitCode, 0)
        XCTAssertEqual(result[0].output, "# Demo\nhello\n", "the completed item's full output replaces the streamed deltas")
        XCTAssertEqual(result[1].title, "/wt/a/README.md")
        XCTAssertTrue(result[1].diff?.contains("+world") ?? false)
        XCTAssertEqual(result[2].exitCode, 1)
        XCTAssertEqual(result[2].output, "Building...\nerror: 1 test failed\n")
        XCTAssertEqual(result[3].title, "agentdesk_files · list_folder")
        XCTAssertEqual(result[3].output, "README.md")
        let diffs = events.compactMap { if case .turnDiff(let d) = $0 { return d }; return nil }
        XCTAssertEqual(diffs.count, 1)
        XCTAssertEqual(DiffStat.parse(unified: diffs[0]), DiffStat(files: 1, added: 1, removed: 0))
    }

    func testCodexOutputStreamsBeforeTheItemCompletes() {
        var steps: [MessageStep] = []
        for (method, params) in [
            ("item/started", ["item": ["type": "commandExecution", "id": "c", "command": "make", "status": "inProgress"]] as [String: Any]),
            ("item/commandExecution/outputDelta", ["itemId": "c", "delta": "one\n"]),
            ("item/commandExecution/outputDelta", ["itemId": "c", "delta": "two\n"]),
            ("item/commandExecution/outputDelta", ["itemId": "unknown", "delta": "dropped"]),
        ] {
            for case .step(let s) in CodexStepParser.events(method: method, params: params) { steps.apply(s) }
        }
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps[0].state, .running)
        XCTAssertEqual(steps[0].output, "one\ntwo\n")
        steps.settle(failed: true)
        XCTAssertEqual(steps[0].state, .failed, "a stopped turn leaves no step running")
    }

    func testClaudeToolUseAndResultBecomeSteps() throws {
        let result = steps(try fixture("claude-steps").flatMap(ClaudeStepParser.steps))
        XCTAssertEqual(result.map(\.id), ["toolu_read", "toolu_edit", "toolu_test", "toolu_rm", "toolu_mcp"])
        XCTAssertEqual(result.map(\.kind), [.read, .fileChange, .command, .command, .mcp])
        XCTAssertEqual(result.map(\.state), [.done, .done, .failed, .declined, .done])
        XCTAssertEqual(result[0].title, "/wt/b/README.md")
        XCTAssertEqual(result[1].diff, "--- /wt/b/README.md\n-hello\n+hello\n+world")
        XCTAssertEqual(result[2].title, "swift test")
        XCTAssertEqual(result[2].detail, "Run the tests")
        XCTAssertEqual(result[2].exitCode, 2)
        XCTAssertEqual(result[4].title, MCPToolName.display("mcp__agentdesk-files__list_folder"))
        XCTAssertEqual(result[4].output, "README.md")
    }

    func testClaudeRepeatedToolUseDoesNotReopenAFinishedStep() {
        var steps: [MessageStep] = []
        steps.apply(StepEvent(id: "t", kind: .command, title: "ls", state: .running))
        steps.apply(StepEvent(id: "t", state: .done, fullOutput: "a"))
        steps.apply(StepEvent(id: "t", kind: .command, title: "ls", state: .running))
        XCTAssertEqual(steps.first?.state, .done)
    }

    func testCursorToolCallsBecomeSteps() throws {
        let result = steps(try fixture("cursor-steps").compactMap(CursorStepParser.step))
        XCTAssertEqual(result.map(\.id), ["tool_1", "tool_2", "tool_3", "tool_4"])
        XCTAssertEqual(result.map(\.kind), [.read, .fileChange, .command, .command])
        XCTAssertEqual(result.map(\.state), [.done, .done, .failed, .declined])
        XCTAssertEqual(result[1].diff, "@@ -2 +2,2 @@\n hello\n+world")
        XCTAssertEqual(result[2].exitCode, 1)
        XCTAssertEqual(result[2].output, "1 failing")
        XCTAssertEqual(result[3].output, "Shell is not allowed in this mode")
    }

    // MARK: Storage

    func testLongOutputKeepsItsHeadAndTail() {
        var step = MessageStep(id: "s", kind: .command, title: "yes", state: .running)
        let keep = StepOutput.keep
        step.apply(.delta(id: "s", String(repeating: "a", count: keep)))
        step.apply(.delta(id: "s", String(repeating: "b", count: keep)))
        XCTAssertNil(step.outputTail, "exactly two halves still fit")
        step.apply(.delta(id: "s", String(repeating: "c", count: 10)))
        step.apply(.delta(id: "s", "END"))
        XCTAssertEqual(step.output, String(repeating: "a", count: keep))
        XCTAssertEqual(step.outputTail?.count, keep)
        XCTAssertTrue(step.outputTail!.hasSuffix("cccEND"))
        XCTAssertEqual(step.omitted, 13)
        XCTAssertTrue(step.displayOutput!.contains("省略 13 个字符"))
        // A complete output replaces what streamed.
        step.apply(StepEvent(id: "s", state: .done, fullOutput: "short"))
        XCTAssertEqual(step.displayOutput, "short")
        XCTAssertNil(step.omitted)
    }

    func testMessagesWithStepsRoundTripAndOldOnesDecode() throws {
        var message = ChatMessage(role: .assistant, text: "ok")
        var step = MessageStep(id: "1", kind: .command, title: "ls", state: .done)
        step.exitCode = 0
        message.steps = [step]
        message.diffStat = DiffStat(files: 1, added: 2, removed: 3)
        message.checkpoint = "abc"
        XCTAssertEqual(try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message)), message)
        let old = #"{"id":"7C1A0C4E-55B0-4B8B-9B7B-5E2C1F0A9D11","role":"assistant","text":"x","state":"complete","createdAt":0}"#
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: Data(old.utf8))
        XCTAssertNil(decoded.steps)
        XCTAssertNil(decoded.diffStat)
    }

    func testTurnDiffsLiveInTheirOwnFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diffs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TurnDiffStore(root: root)
        let session = UUID(), message = UUID()
        XCTAssertNil(store.load(session: session, message: message))
        try store.save("diff --git a/x b/x\n+1\n", session: session, message: message)
        XCTAssertEqual(store.load(session: session, message: message), "diff --git a/x b/x\n+1\n")
        XCTAssertTrue(store.url(session: session, message: message).path.hasPrefix(root.appendingPathComponent("Diffs").path))
        store.remove(session: session)
        XCTAssertNil(store.load(session: session, message: message))
    }

    // MARK: Checkpoints and undo, in a throwaway repository

    func testCheckpointAndRestoreUndoATurnWithoutRewritingTheBranch() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("checkpoint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = URL(fileURLWithPath: String(cString: realpath(temp.path, nil)), isDirectory: true)
        let project = root.appendingPathComponent("p", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        func git(_ args: String..., in dir: URL = project) throws -> String { try Git.run(args, in: dir).output }
        func write(_ name: String, _ text: String, in dir: URL) throws {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        _ = try git("init", "-q", "-b", "main")
        _ = try git("config", "user.name", "T"); _ = try git("config", "user.email", "t@example.com")
        try write("README.md", "v1\n", in: project)
        try write(".gitignore", "build/\n", in: project)
        _ = try git("add", "-A"); _ = try git("commit", "-q", "-m", "init")

        let wt = try ProjectGit.createWorktree(project: project, board: UUID(), node: UUID(), root: root.appendingPathComponent("wts"))
        let dir = URL(fileURLWithPath: wt.path)
        // Work from an earlier turn, uncommitted, is part of the checkpoint.
        try write("notes.txt", "earlier turn\n", in: dir)
        let reply = UUID()
        let checkpoint = try ProjectGit.checkpoint(wt, message: reply)
        XCTAssertEqual(try git("rev-parse", ProjectGit.checkpointRef(message: reply)), checkpoint)
        let head = try git("rev-parse", "HEAD", in: dir)

        // The turn: edits, a new file, a deletion, an ignored build file.
        try write("README.md", "v2\n", in: dir)
        try write("src/new.swift", "let x = 1\n", in: dir)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("notes.txt"))
        try write("build/out.o", "bin", in: dir)
        let turn = try ProjectGit.diff(wt, since: checkpoint)
        XCTAssertEqual(DiffStat.parse(unified: turn), DiffStat(files: 3, added: 2, removed: 2))

        try ProjectGit.restore(wt, to: checkpoint)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("README.md"), encoding: .utf8), "v1\n")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("notes.txt"), encoding: .utf8), "earlier turn\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("src/new.swift").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("build/out.o").path), "ignored files stay")
        XCTAssertEqual(try git("rev-parse", "HEAD", in: dir), head, "the branch is not rewritten")
        XCTAssertEqual(try git("status", "--porcelain", in: dir), "?? notes.txt", "earlier uncommitted work is uncommitted again")
        XCTAssertEqual(try ProjectGit.diff(wt, since: checkpoint), "")
    }

    // MARK: Codex end to end, against a fake app-server

    func testCodexBackendStreamsStepsAndRevertsATurn() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-steps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixtureURL = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/codex-steps", withExtension: "jsonl"))
        try FileManager.default.copyItem(at: fixtureURL, to: dir.appendingPathComponent("notifications.jsonl"))
        let fake = dir.appendingPathComponent("codex")
        try Self.fakeServer.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let request = AgentRequest(localSessionID: UUID(), remoteSessionID: nil, prompt: "改 README", workingDirectory: dir, modelID: "gpt-6.1-sol", executableURL: fake, projectAccess: true)
        var events: [AgentEvent] = []
        for try await event in CodexBackend(executableURL: fake).stream(request) { events.append(event) }
        let stepEvents = events.compactMap { if case .step(let s) = $0 { return s }; return nil }
        XCTAssertEqual(steps(stepEvents).map(\.state), [.done, .done, .failed, .done, .declined])
        XCTAssertTrue(events.contains { if case .turnDiff = $0 { return true }; return false })
        XCTAssertTrue(events.contains(.status("正在修改文件…")), "the node card still gets a one-line status")
        XCTAssertTrue(events.contains(.completed))

        try await CodexBackend.revert(executableURL: fake, directory: dir, threadID: "thr-fixture", beforeTurnID: "turn-fixture")
        let log = try String(contentsOf: dir.appendingPathComponent("requests.log"), encoding: .utf8)
        XCTAssertTrue(log.contains(#"thread/revert {"beforeTurnId": "turn-fixture", "threadId": "thr-fixture"}"#), log)
        XCTAssertFalse(log.split(separator: "\n").suffix(4).contains { $0.hasPrefix("turn/start") }, "revert starts no turn")
    }

    func testRevertRequestsLoadTheThreadThenRevert() {
        let requests = CodexBackend.revertRequests(threadID: "t", beforeTurnID: "u", cwd: "/w")
        XCTAssertEqual(requests.map { $0["method"] as? String }, ["initialize", "thread/resume", "thread/revert"])
        XCTAssertEqual(requests[2]["params"] as? [String: String], ["threadId": "t", "beforeTurnId": "u"])
    }

    private static let fakeServer = #"""
#!/usr/bin/python3
import json, pathlib, sys

here = pathlib.Path(sys.argv[0]).parent
log = open(here / "requests.log", "a")

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

for line in sys.stdin:
    try:
        msg = json.loads(line)
    except Exception:
        continue
    method, ident = msg.get("method"), msg.get("id")
    log.write("%s %s\n" % (method, json.dumps(msg.get("params"), sort_keys=True)))
    log.flush()
    if method == "initialize":
        send({"id": ident, "result": {"userAgent": "fixture"}})
    elif method == "config/read":
        send({"id": ident, "result": {"config": {}}})
    elif method == "account/read":
        send({"id": ident, "result": {"account": {"type": "chatgpt"}}})
    elif method == "model/list":
        send({"id": ident, "result": {"data": [{"id": "gpt-6.1-sol", "isDefault": True, "defaultReasoningEffort": "medium"}], "nextCursor": None}})
    elif method in ("thread/start", "thread/resume"):
        send({"id": ident, "result": {"thread": {"id": "thr-fixture"}}})
    elif method == "thread/revert":
        send({"id": ident, "result": {"thread": {"id": "thr-fixture", "turns": []}}})
    elif method == "turn/start":
        send({"id": ident, "result": {"turn": {"id": "turn-fixture"}}})
        for note in (here / "notifications.jsonl").read_text().splitlines():
            if note.strip():
                sys.stdout.write(note + "\n")
        sys.stdout.flush()
"""#
}
