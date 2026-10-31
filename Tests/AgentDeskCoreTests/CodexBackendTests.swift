import XCTest
@testable import AgentDeskCore

final class CodexBackendTests: XCTestCase {
    private var fixtureDirectory: URL!
    private var fixtureURL: URL!

    override func setUpWithError() throws {
        fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("agentdesk-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        fixtureURL = fixtureDirectory.appendingPathComponent("codex-fixture")
        try Self.fixtureSource.write(to: fixtureURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixtureURL.path)
    }

    override func tearDownWithError() throws {
        if let fixtureDirectory { try? FileManager.default.removeItem(at: fixtureDirectory) }
    }

    func testStreamUsesChatGPTAccountAndOmitsEmptyModel() async throws {
        let request = AgentRequest(localSessionID: UUID(), remoteSessionID: nil, prompt: "hello", workingDirectory: fixtureDirectory, modelID: "", executableURL: fixtureURL)
        let (events, error) = await collect(CodexBackend(executableURL: fixtureURL).stream(request))
        XCTAssertNil(error)
        XCTAssertTrue(events.contains(.sessionID("thr-fixture")))
        XCTAssertTrue(events.contains(.textDelta("MODEL_OMITTED")))
        XCTAssertTrue(events.contains(.textDelta("MCP_DISABLED")))
        XCTAssertTrue(events.contains(.textDelta("hello")))
        XCTAssertTrue(events.contains(.completed))
    }

    func testResumeUsesExistingThreadAndSelectedModel() async throws {
        let request = AgentRequest(localSessionID: UUID(), remoteSessionID: "thr-existing", prompt: "continue", workingDirectory: fixtureDirectory, modelID: "gpt-6-luna", executableURL: fixtureURL)
        let (events, error) = await collect(CodexBackend(executableURL: fixtureURL).stream(request))
        XCTAssertNil(error)
        XCTAssertTrue(events.contains(.sessionID("thr-resumed")))
        XCTAssertTrue(events.contains(.textDelta("MODEL_gpt-6-luna")))
        XCTAssertTrue(events.contains(.textDelta("EFFORT_low")))
        XCTAssertTrue(events.contains(.completed))
    }

    func testResumePassesSelectedReasoningEffortExactly() async throws {
        let request = AgentRequest(localSessionID: UUID(), remoteSessionID: "thr-existing", prompt: "continue", workingDirectory: fixtureDirectory, modelID: "gpt-6-luna", executableURL: fixtureURL, reasoningEffort: "medium")
        let (events, error) = await collect(CodexBackend(executableURL: fixtureURL).stream(request))
        XCTAssertNil(error)
        XCTAssertTrue(events.contains(.sessionID("thr-resumed")))
        XCTAssertTrue(events.contains(.textDelta("EFFORT_medium")))
        XCTAssertTrue(events.contains(.completed))
    }

    func testTurnPassesSelectedReasoningEffortExactly() async throws {
        let request = AgentRequest(localSessionID: UUID(), remoteSessionID: nil, prompt: "effort", workingDirectory: fixtureDirectory, modelID: "gpt-6.1-sol", executableURL: fixtureURL, reasoningEffort: "high")
        let (events, error) = await collect(CodexBackend(executableURL: fixtureURL).stream(request))
        XCTAssertNil(error)
        XCTAssertTrue(events.contains(.textDelta("EFFORT_high")))
    }

    /// Codex keeps its own base instructions; chat mode's tool note and
    /// AgentDesk's rules arrive as developer instructions, on start and resume.
    func testRulesAndChatToolNoteGoToDeveloperInstructions() async throws {
        let chat = AgentRequest(localSessionID: UUID(), remoteSessionID: nil, prompt: "hi", workingDirectory: fixtureDirectory, modelID: "", executableURL: fixtureURL, instructions: "## 本节点规则\n\n只改 src/api/")
        let (events, error) = await collect(CodexBackend(executableURL: fixtureURL).stream(chat))
        XCTAssertNil(error)
        XCTAssertTrue(events.contains(.textDelta("BASE_KEPT")))
        XCTAssertTrue(events.contains(.textDelta("DEV_Use no tools in this session. Answer with text only.\n\n## 本节点规则\n\n只改 src/api/")))

        let resumed = AgentRequest(localSessionID: UUID(), remoteSessionID: "thr-existing", prompt: "hi", workingDirectory: fixtureDirectory, modelID: "", executableURL: fixtureURL, projectAccess: true, instructions: "G")
        let (again, resumeError) = await collect(CodexBackend(executableURL: fixtureURL).stream(resumed))
        XCTAssertNil(resumeError)
        XCTAssertTrue(again.contains(.textDelta("BASE_KEPT")))
        XCTAssertTrue(again.contains(.textDelta("DEV_G")), "a trusted project carries only the rules")

        let plain = AgentRequest(localSessionID: UUID(), remoteSessionID: nil, prompt: "hi", workingDirectory: fixtureDirectory, modelID: "", executableURL: fixtureURL, projectAccess: true)
        let (none, _) = await collect(CodexBackend(executableURL: fixtureURL).stream(plain))
        XCTAssertTrue(none.contains(.textDelta("DEV_NONE")))
    }

    func testAPIAccountIsRejectedBeforeThreadCreation() async throws {
        try setFixtureMode("api")
        let request = AgentRequest(localSessionID: UUID(), remoteSessionID: nil, prompt: "hello", workingDirectory: fixtureDirectory, modelID: "gpt-6.1-sol", executableURL: fixtureURL)
        let (_, error) = await collect(CodexBackend(executableURL: fixtureURL).stream(request))
        XCTAssertTrue(error is AgentError)
        XCTAssertTrue(error?.localizedDescription.contains("ChatGPT") == true)
    }

    func testTurnErrorIsSurfaced() async throws {
        try setFixtureMode("turn-error")
        let request = AgentRequest(localSessionID: UUID(), remoteSessionID: nil, prompt: "hello", workingDirectory: fixtureDirectory, modelID: "gpt-6.1-sol", executableURL: fixtureURL)
        let (_, error) = await collect(CodexBackend(executableURL: fixtureURL).stream(request))
        XCTAssertTrue(error is AgentError)
        XCTAssertTrue(error?.localizedDescription.contains("失败") == true)
    }

    func testInspectReadsAccountAndModelCatalogWithoutStartingTurn() async throws {
        let inspection = try await CodexBackend.inspect(executableURL: fixtureURL, directory: fixtureDirectory)
        XCTAssertTrue(inspection.isChatGPT)
        XCTAssertEqual(inspection.modelIDs, ["gpt-6.1-sol", "gpt-6-luna"])
        XCTAssertEqual(inspection.defaultModelID, "gpt-6.1-sol")
        XCTAssertEqual(inspection.supportedReasoningEfforts["gpt-6.1-sol"], ["low", "medium", "high"])
        XCTAssertEqual(inspection.supportedReasoningEfforts["gpt-6-luna"], ["low", "medium"])
        XCTAssertEqual(inspection.defaultReasoningEfforts["gpt-6.1-sol"], "medium")
        XCTAssertEqual(inspection.quota?.windows, [
            QuotaWindow(label: "5 小时", usedPercent: 42, resetsAt: Date(timeIntervalSince1970: 1793300000)),
            QuotaWindow(label: "每周", usedPercent: 7, resetsAt: nil)
        ])
    }

    func testInspectStillSucceedsWhenRateLimitsAreUnavailable() async throws {
        try setFixtureMode("no-limits")
        let inspection = try await CodexBackend.inspect(executableURL: fixtureURL, directory: fixtureDirectory)
        XCTAssertTrue(inspection.isChatGPT)
        XCTAssertNil(inspection.quota)
    }

    func testTurnReportsContextUsageAndQuotaUpdates() async throws {
        try setFixtureMode("usage")
        let request = AgentRequest(localSessionID: UUID(), remoteSessionID: nil, prompt: "hello", workingDirectory: fixtureDirectory, modelID: "gpt-6.1-sol", executableURL: fixtureURL)
        let (events, error) = await collect(CodexBackend(executableURL: fixtureURL).stream(request))
        XCTAssertNil(error)
        XCTAssertTrue(events.contains(.contextUsage(ContextUsage(usedTokens: 12_345, windowTokens: 272_000))))
        XCTAssertTrue(events.contains { if case .quota(let q) = $0 { return q.windows.first?.usedPercent == 55 }; return false })
    }

    /// 询问 level: approvals go to the approver and its answers go back to Codex.
    func testApprovalsAreForwardedAndAnswered() async throws {
        try setFixtureMode("approval")
        let asked = Recorder()
        let approver: AgentApprover = { request in
            await asked.add(request)
            return request.kind == .fileChange ? .once : .conversation
        }
        let session = UUID()
        let request = AgentRequest(localSessionID: session, remoteSessionID: nil, prompt: "hello", workingDirectory: fixtureDirectory, modelID: "gpt-6.1-sol", executableURL: fixtureURL,
                                   projectAccess: true, permissionLevel: .ask, approver: approver)
        let (events, error) = await collect(CodexBackend(executableURL: fixtureURL).stream(request))
        XCTAssertNil(error)
        XCTAssertTrue(events.contains(.textDelta("POLICY_untrusted")))
        XCTAssertTrue(events.contains(.textDelta("FILE_accept")))
        XCTAssertTrue(events.contains(.textDelta("CMD_acceptForSession")))
        let requests = await asked.items
        XCTAssertEqual(requests.map(\.kind), [.fileChange, .command])
        XCTAssertEqual(requests.first?.files, ["/p/a.txt"])
        XCTAssertTrue(requests.first?.diff?.contains("+new") == true, "the patch comes from the file-change item")
        XCTAssertEqual(requests.last?.command, "git push")
        XCTAssertEqual(requests.last?.cwd, "/p")
        XCTAssertEqual(requests.last?.reason, "push the branch")
        XCTAssertTrue(requests.allSatisfy { $0.sessionID == session })
    }

    func testApprovalsWithoutAnApproverAreDeclined() async throws {
        try setFixtureMode("approval")
        let request = AgentRequest(localSessionID: UUID(), remoteSessionID: nil, prompt: "hello", workingDirectory: fixtureDirectory, modelID: "gpt-6.1-sol", executableURL: fixtureURL,
                                   projectAccess: true, permissionLevel: .readOnly)
        let (events, error) = await collect(CodexBackend(executableURL: fixtureURL).stream(request))
        XCTAssertNil(error)
        XCTAssertTrue(events.contains(.textDelta("FILE_decline")))
        XCTAssertTrue(events.contains(.textDelta("CMD_decline")))
    }

    func testAutomaticProjectsStillAcceptWithoutAsking() async throws {
        try setFixtureMode("approval")
        let approver: AgentApprover = { _ in XCTFail("自动 never asks"); return .deny }
        let request = AgentRequest(localSessionID: UUID(), remoteSessionID: nil, prompt: "hello", workingDirectory: fixtureDirectory, modelID: "gpt-6.1-sol", executableURL: fixtureURL,
                                   projectAccess: true, approver: approver)
        let (events, error) = await collect(CodexBackend(executableURL: fixtureURL).stream(request))
        XCTAssertNil(error)
        XCTAssertTrue(events.contains(.textDelta("POLICY_never")))
        XCTAssertTrue(events.contains(.textDelta("FILE_accept")))
        XCTAssertTrue(events.contains(.textDelta("CMD_accept")))
    }

    private actor Recorder {
        var items: [ApprovalRequest] = []
        func add(_ item: ApprovalRequest) { items.append(item) }
    }

    private func setFixtureMode(_ mode: String) throws {
        try mode.write(to: fixtureDirectory.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
    }

    private func collect(_ stream: AsyncThrowingStream<AgentEvent, Error>) async -> ([AgentEvent], Error?) {
        var events: [AgentEvent] = []
        do {
            for try await event in stream { events.append(event) }
            return (events, nil)
        } catch { return (events, error) }
    }

    private static let fixtureSource = #"""
#!/usr/bin/python3
import json, pathlib, sys

mode_path = pathlib.Path(sys.argv[0]).parent / "mode"
assert "features.multi_agent=false" in sys.argv
assert "features.multi_agent_v2=false" in sys.argv
assert "features.memories=false" in sys.argv
assert "features.plugins=false" in sys.argv
mode = mode_path.read_text().strip() if mode_path.exists() else "success"
thread_params = {}

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

for line in sys.stdin:
    try:
        msg = json.loads(line)
    except Exception:
        continue
    method = msg.get("method")
    ident = msg.get("id")
    if method == "initialize":
        send({"id": ident, "result": {"userAgent": "fixture", "codexHome": "/tmp"}})
    elif method == "initialized":
        pass
    elif method == "config/read":
        send({"id": ident, "result": {"config": {"mcp_servers": {"fictional_external": {"type": "streamable_http", "url": "https://example.invalid/mcp"}}}}})
    elif method == "account/read":
        account_type = "apiKey" if mode == "api" else "chatgpt"
        send({"id": ident, "result": {"account": {"type": account_type, "planType": "prolite"}, "requiresOpenaiAuth": True}})
    elif method == "model/list":
        send({"id": ident, "result": {"data": [{"id": "gpt-6.1-sol", "isDefault": True, "defaultReasoningEffort": "medium", "supportedReasoningEfforts": [{"reasoningEffort": "low"}, {"reasoningEffort": "medium"}, {"reasoningEffort": "high"}]}, {"id": "gpt-6-luna", "isDefault": False, "defaultReasoningEffort": "low", "supportedReasoningEfforts": [{"reasoningEffort": "low"}, {"reasoningEffort": "medium"}]}], "nextCursor": None}})
    elif method == "account/rateLimits/read":
        if mode == "no-limits":
            send({"id": ident, "error": {"code": -32601, "message": "unsupported"}})
        else:
            send({"id": ident, "result": {"rateLimits": {"primary": {"usedPercent": 42, "windowDurationMins": 300, "resetsAt": 1793300000}, "secondary": {"usedPercent": 7, "windowDurationMins": 10080, "resetsAt": None}}}})
    elif method == "thread/start":
        thread_params = msg.get("params", {})
        send({"id": ident, "result": {"thread": {"id": "thr-fixture"}}})
    elif method == "thread/resume":
        thread_params = msg.get("params", {})
        send({"id": ident, "result": {"thread": {"id": "thr-resumed"}}})
    elif ident == "srv-1" and "result" in msg:
        send({"method": "item/agentMessage/delta", "params": {"threadId": "thr-fixture", "turnId": "turn-fixture", "itemId": "item-fixture", "delta": "FILE_" + msg["result"]["decision"]}})
        send({"id": "srv-2", "method": "item/commandExecution/requestApproval", "params": {"threadId": "thr-fixture", "turnId": "turn-fixture", "itemId": "cmd-1", "startedAtMs": 1, "command": "git push", "cwd": "/p", "reason": "push the branch"}})
    elif ident == "srv-2" and "result" in msg:
        send({"method": "item/agentMessage/delta", "params": {"threadId": "thr-fixture", "turnId": "turn-fixture", "itemId": "item-fixture", "delta": "CMD_" + msg["result"]["decision"]}})
        send({"method": "turn/completed", "params": {"threadId": "thr-fixture", "turn": {"id": "turn-fixture", "status": "completed"}}})
    elif method == "turn/start" and mode == "approval":
        send({"id": ident, "result": {"turn": {"id": "turn-fixture"}}})
        policy = msg.get("params", {}).get("approvalPolicy", "OMITTED")
        assert ('approval_policy="%s"' % policy) in sys.argv
        send({"method": "item/agentMessage/delta", "params": {"threadId": "thr-fixture", "turnId": "turn-fixture", "itemId": "item-fixture", "delta": "POLICY_" + policy}})
        send({"method": "item/started", "params": {"threadId": "thr-fixture", "turnId": "turn-fixture", "item": {"type": "fileChange", "id": "fc-1", "status": "inProgress", "changes": [{"path": "/p/a.txt", "kind": {"type": "update"}, "diff": "-old\n+new"}]}}})
        send({"id": "srv-1", "method": "item/fileChange/requestApproval", "params": {"threadId": "thr-fixture", "turnId": "turn-fixture", "itemId": "fc-1", "startedAtMs": 1, "reason": None}})
    elif method == "turn/start":
        if mode == "turn-error":
            send({"id": ident, "error": {"code": -32000, "message": "fixture turn failure"}})
            continue
        params = msg.get("params", {})
        model = params.get("model", "OMITTED")
        effort = params.get("effort", "OMITTED")
        send({"id": ident, "result": {"turn": {"id": "turn-fixture"}}})
        if mode == "usage":
            send({"method": "thread/tokenUsage/updated", "params": {"threadId": "thr-fixture", "turnId": "turn-fixture", "tokenUsage": {"last": {"totalTokens": 12345, "inputTokens": 12000, "cachedInputTokens": 0, "outputTokens": 345, "reasoningOutputTokens": 0}, "total": {"totalTokens": 99999, "inputTokens": 1, "cachedInputTokens": 0, "outputTokens": 1, "reasoningOutputTokens": 0}, "modelContextWindow": 272000}}})
            send({"method": "account/rateLimits/updated", "params": {"rateLimits": {"primary": {"usedPercent": 55, "windowDurationMins": 300}}}})
        disabled = "MCP_DISABLED" if any("fictional_external" in arg for arg in sys.argv) else "MCP_NOT_DISABLED"
        send({"method": "item/agentMessage/delta", "params": {"threadId": "thr-fixture", "turnId": "turn-fixture", "itemId": "item-fixture", "delta": "MODEL_" + model}})
        send({"method": "item/agentMessage/delta", "params": {"threadId": "thr-fixture", "turnId": "turn-fixture", "itemId": "item-fixture", "delta": "EFFORT_" + effort}})
        send({"method": "item/agentMessage/delta", "params": {"threadId": "thr-fixture", "turnId": "turn-fixture", "itemId": "item-fixture", "delta": disabled}})
        base = "BASE_SET" if "baseInstructions" in thread_params else "BASE_KEPT"
        send({"method": "item/agentMessage/delta", "params": {"threadId": "thr-fixture", "turnId": "turn-fixture", "itemId": "item-fixture", "delta": base}})
        send({"method": "item/agentMessage/delta", "params": {"threadId": "thr-fixture", "turnId": "turn-fixture", "itemId": "item-fixture", "delta": "DEV_" + str(thread_params.get("developerInstructions", "NONE"))}})
        send({"method": "item/agentMessage/delta", "params": {"threadId": "thr-fixture", "turnId": "turn-fixture", "itemId": "item-fixture", "delta": "hello"}})
        send({"method": "turn/completed", "params": {"threadId": "thr-fixture", "turn": {"id": "turn-fixture", "status": "completed"}}})
"""#
}
