import Foundation
import XCTest
@testable import AgentDeskCore

/// design/HARNESS.md H0 and H1: names, modes, permission levels, what each
/// CLI gets per level, and the approval round trips (Codex: CodexBackendTests).
final class HarnessApprovalTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("harness-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: H0

    func testProvidersAreNamedByTheirHarness() {
        XCTAssertEqual(ProviderID.allCases.map(\.name), ["Claude Code", "Codex", "Cursor · Grok", "Cursor · Gemini"])
        XCTAssertEqual(ProviderID.codex.subtitle, "Codex · ChatGPT 账号")
        XCTAssertFalse(ProviderID.allCases.contains { $0.name.contains("ChatGPT") })
    }

    func testHarnessSummaryListsModePermissionsFolderAndRuleFiles() throws {
        try "rules".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let codex = HarnessSummary.lines(provider: .codex, mode: .project(.ask), workingDirectory: root, home: root.deletingLastPathComponent())
        XCTAssertEqual(codex[0], "Harness：Codex · ChatGPT 账号（codex app-server）")
        XCTAssertEqual(codex[1], "模式：项目 · 询问")
        XCTAssertTrue(codex[2].contains("untrusted"))
        XCTAssertEqual(codex[3], "工作目录：~/\(root.lastPathComponent)")
        XCTAssertEqual(codex[4], "规则文件：AGENTS.md")
        let claude = HarnessSummary.lines(provider: .claude, mode: .project(.ask), workingDirectory: root)
        XCTAssertEqual(claude.last, "规则文件：没有加载项目规则文件", "Claude reads CLAUDE.md, not AGENTS.md")
        XCTAssertEqual(HarnessSummary.lines(provider: .grok, mode: .chat, workingDirectory: root)[1], "模式：聊天")
    }

    // MARK: Levels

    func testLevelsMigrationAndNodeCap() throws {
        let old = try JSONDecoder().decode(CanvasProject.self, from: Data(#"{"path":"/p","trusted":true}"#.utf8))
        XCTAssertEqual(old.level, .auto, "projects trusted before levels keep running automatically")
        XCTAssertNil(CanvasProject(path: "/p", trusted: false, permissionLevel: .ask).level, "untrusted is chat")
        XCTAssertNil(CanvasProject(path: "/p").level)
        let ask = CanvasProject(path: "/p", trusted: true, permissionLevel: .ask)
        XCTAssertEqual(try JSONDecoder().decode(CanvasProject.self, from: JSONEncoder().encode(ask)), ask)

        XCTAssertEqual(HarnessMode.resolve(project: ask, nodeLevel: nil, workingDirectory: "/p"), .project(.ask))
        XCTAssertEqual(HarnessMode.resolve(project: ask, nodeLevel: .readOnly, workingDirectory: "/p"), .project(.readOnly))
        XCTAssertEqual(HarnessMode.resolve(project: ask, nodeLevel: .auto, workingDirectory: "/p"), .project(.ask), "a node never goes above its board")
        XCTAssertEqual(HarnessMode.resolve(project: ask, nodeLevel: nil, workingDirectory: "/elsewhere"), .chat)
        XCTAssertEqual(HarnessMode.resolve(project: nil, nodeLevel: nil, workingDirectory: "/p"), .chat)
        // Worktrees (H2) and levels (H1) together: the canvas's write decision replaces the folder check.
        XCTAssertEqual(HarnessMode.resolve(project: ask, nodeLevel: nil, workingDirectory: "/wt/1", writable: true), .project(.ask))
        XCTAssertEqual(HarnessMode.resolve(project: ask, nodeLevel: nil, workingDirectory: "/p", writable: false), .chat)
        let worktree = NodeWorktree(repository: "/p", path: "/wt/1", branch: "agentdesk/b/n", baseBranch: "main", baseCommit: "abc")
        var writer = CanvasNode(sessionID: UUID(), position: CanvasPoint(x: 0, y: 0))
        writer.worktree = worktree
        let board = CanvasBoard(title: "b", project: ask, nodes: [writer])
        let session = ChatSession(provider: .claude, modelID: "m", workingDirectory: worktree.workingDirectory)
        XCTAssertEqual(HarnessMode.resolve(board: board, node: writer, session: session), .project(.ask), "a worktree node runs at its board's level")
        var merger = CanvasNode(sessionID: UUID(), position: CanvasPoint(x: 0, y: 0), merge: .compare)
        merger.permissionLevel = nil
        XCTAssertEqual(HarnessMode.resolve(board: board, node: merger, session: ChatSession(provider: .claude, modelID: "m", workingDirectory: "/p")), .chat, "a merge node without a worktree only reads")
        XCTAssertEqual(HarnessMode.project(.readOnly).label, "项目 · 只读")
        XCTAssertEqual(HarnessMode.chat.key, "chat")

        var node = CanvasNode(sessionID: UUID(), position: CanvasPoint(x: 0, y: 0))
        node.permissionLevel = .readOnly
        XCTAssertEqual(try JSONDecoder().decode(CanvasNode.self, from: JSONEncoder().encode(node)).permissionLevel, .readOnly)
        XCTAssertTrue(PermissionLevel.readOnly < .ask && PermissionLevel.ask < .auto)
    }

    // MARK: Claude Code

    func testClaudeArgumentsPerLevel() throws {
        let files = try XCTUnwrap(FolderAccessPolicy.server(helper: URL(fileURLWithPath: "/bin/cat"), dataRoot: root, sessionID: UUID(), token: "t", approvals: "/p"))
        let tool = FolderAccessPolicy.approvalTool(in: [files])
        XCTAssertEqual(tool, "mcp__agentdesk_files__approve")
        XCTAssertNil(FolderAccessPolicy.approvalTool(in: [FolderAccessPolicy.server(helper: URL(fileURLWithPath: "/bin/cat"), dataRoot: root, sessionID: UUID(), token: "t")!]))

        let ask = try ClaudeBackend.commonArguments(modelID: "m", effort: nil, mcpServers: [files], project: true, level: .ask, approvalTool: tool)
        XCTAssertEqual(value(after: "--permission-mode", in: ask), "default")
        XCTAssertEqual(value(after: "--permission-prompts", in: ask), "host")
        XCTAssertEqual(value(after: "--permission-prompt-tool", in: ask), "mcp__agentdesk_files__approve")
        let allowed = try XCTUnwrap(value(after: "--allowedTools", in: ask)).split(separator: ",").map(String.init)
        XCTAssertTrue(allowed.contains("Edit(./**)"))
        XCTAssertTrue(allowed.contains("Read(./**)"))
        XCTAssertTrue(allowed.contains("mcp__agentdesk_files"))
        XCTAssertFalse(allowed.contains { $0.hasPrefix("Bash") || $0.hasPrefix("WebFetch") }, "commands and network ask")

        let readOnly = try ClaudeBackend.commonArguments(modelID: "m", effort: nil, mcpServers: [files], project: true, level: .readOnly, approvalTool: tool)
        XCTAssertFalse(try XCTUnwrap(value(after: "--allowedTools", in: readOnly)).contains("Edit"), "只读 asks before every edit")

        let noTool = try ClaudeBackend.commonArguments(modelID: "m", effort: nil, project: true, level: .ask)
        XCTAssertEqual(value(after: "--permission-prompts", in: noTool), "none", "without the approval tool every prompt is a no")
        XCTAssertFalse(noTool.contains("--permission-prompt-tool"))

        let auto = try ClaudeBackend.commonArguments(modelID: "m", effort: nil, project: true)
        XCTAssertEqual(value(after: "--permission-mode", in: auto), "bypassPermissions")
        XCTAssertFalse(auto.contains("--allowedTools"))
    }

    func testApprovalToolIsListedOnlyWhenAsked() throws {
        let exchange = FolderAccessExchange(root: root)
        func names(_ server: FolderAccessServer) throws -> [String] {
            let list = try XCTUnwrap(server.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
            let result = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(list.utf8)) as? [String: Any])?["result"] as? [String: Any])
            return (result["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        }
        XCTAssertFalse(try names(FolderAccessServer(exchange: exchange, sessionID: UUID(), token: "t")).contains("approve"))
        XCTAssertEqual(try names(FolderAccessServer(exchange: exchange, sessionID: UUID(), token: "t", files: false, approvals: "/p")), ["approve"])
        let both = FolderAccessServer(exchange: exchange, sessionID: UUID(), token: "t", approvals: "/p")
        XCTAssertEqual(try names(both), ["list_directory", "read_file", "search_files", "approve"])
        XCTAssertTrue(text(FolderAccessServer(exchange: exchange, sessionID: UUID(), token: "t", files: false).call("read_file", ["path": "/p"])).contains("没有这个工具"))
    }

    /// The tool posts a request file, waits for the app's answer, and answers
    /// Claude Code; a session answer covers the same command afterwards.
    func testApprovalToolRoundTripWithRequestFiles() throws {
        let exchange = FolderAccessExchange(root: root)
        let session = UUID()
        let server = FolderAccessServer(exchange: exchange, sessionID: session, token: "tok", timeout: 5, approvals: "/p")
        let answers: [String: FolderAccessDecision] = ["git push": .conversation, "rm -rf build": .deny]
        let asked = Locked<[ApprovalRequest]>([])
        let responder = Thread {
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline, !Thread.current.isCancelled {
                for request in exchange.pendingApprovals() where !asked.value.contains(where: { $0.id == request.id }) {
                    asked.mutate { $0.append(request) }
                    try? exchange.respondApproval(request, decision: answers[request.command ?? ""] ?? .once)
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        responder.start()
        defer { responder.cancel() }

        let push = ["command": "git push", "description": "推送分支"]
        let first = try answer(server.call("approve", ["tool_name": "Bash", "input": push, "tool_use_id": "t1"]))
        XCTAssertEqual(first["behavior"] as? String, "allow")
        XCTAssertEqual(first["updatedInput"] as? [String: String], push)
        let again = try answer(server.call("approve", ["tool_name": "Bash", "input": push]))
        XCTAssertEqual(again["behavior"] as? String, "allow", "the session answer covers the same command")
        XCTAssertEqual(exchange.approvalGrants(session: session), ["Bash:git push"])

        let rm = try answer(server.call("approve", ["tool_name": "Bash", "input": ["command": "rm -rf build"]]))
        XCTAssertEqual(rm["behavior"] as? String, "deny")
        XCTAssertTrue((rm["message"] as? String)?.contains("拒绝") == true)

        let edit = try answer(server.call("approve", ["tool_name": "Edit", "input": ["file_path": "/outside/a.txt", "old_string": "a", "new_string": "b"]]))
        XCTAssertEqual(edit["behavior"] as? String, "allow")

        XCTAssertEqual(asked.value.count, 3, "asked once per new action")
        let card = try XCTUnwrap(asked.value.first)
        XCTAssertEqual(card.kind, .command)
        XCTAssertEqual(card.title, "运行命令")
        XCTAssertEqual(card.cwd, "/p")
        XCTAssertEqual(card.reason, "推送分支")
        XCTAssertEqual(card.token, "tok")
        XCTAssertEqual(card.sessionID, session)
        XCTAssertEqual(card.sessionScope, "同一条命令")
        let editCard = try XCTUnwrap(asked.value.last)
        XCTAssertEqual(editCard.kind, .fileChange)
        XCTAssertEqual(editCard.files, ["/outside/a.txt"])
        XCTAssertEqual(editCard.diff, "-a\n+b")
        XCTAssertTrue(exchange.pendingApprovals().isEmpty, "answered requests are cleaned up")
    }

    func testApprovalToolTimesOutAsADenial() throws {
        let exchange = FolderAccessExchange(root: root)
        let server = FolderAccessServer(exchange: exchange, sessionID: UUID(), token: "t", timeout: 0.3, approvals: "/p")
        let result = try answer(server.call("approve", ["tool_name": "WebFetch", "input": ["url": "https://example.com/x", "prompt": "读文档"]]))
        XCTAssertEqual(result["behavior"] as? String, "deny")
        XCTAssertTrue((result["message"] as? String)?.contains("秒内") == true)
        XCTAssertTrue(exchange.pendingApprovals().isEmpty, "the unanswered request is removed")
        XCTAssertEqual(ClaudeApprovalTool.grantKey(toolName: "WebFetch", input: ["url": "https://example.com/x"]), "WebFetch:example.com")
        XCTAssertEqual(ClaudeApprovalTool.request(toolName: "WebFetch", input: ["url": "https://example.com/x"], sessionID: UUID(), token: nil, cwd: nil).kind, .network)
    }

    func testDiscardedApprovalIsADenial() throws {
        let exchange = FolderAccessExchange(root: root)
        let request = ApprovalRequest(sessionID: UUID(), kind: .command, title: "运行命令", command: "ls")
        try exchange.postApproval(request)
        XCTAssertEqual(exchange.pendingApprovals().map(\.id), [request.id])
        exchange.discardApproval(request.id)
        XCTAssertTrue(exchange.pendingApprovals().isEmpty)
        XCTAssertEqual(exchange.waitForApproval(request.id, timeout: 1), .deny)
    }

    // MARK: Codex

    func testCodexPolicyPerLevel() throws {
        let overrides = { (args: [String]) in stride(from: 0, to: args.count, by: 1).compactMap { args[$0] == "-c" ? args[$0 + 1] : nil } }
        let ask = overrides(try CodexBackend.appServerArguments(project: true, level: .ask))
        XCTAssertTrue(ask.contains(#"approval_policy="untrusted""#))
        XCTAssertTrue(ask.contains(#"sandbox_mode="workspace-write""#))
        XCTAssertTrue(ask.contains("sandbox_workspace_write.network_access=false"))
        XCTAssertFalse(ask.contains("features.shell_tool=false"), "the shell stays on; commands ask")
        let readOnly = overrides(try CodexBackend.appServerArguments(project: true, level: .readOnly))
        XCTAssertTrue(readOnly.contains(#"sandbox_mode="read-only""#))
        XCTAssertTrue(readOnly.contains(#"approval_policy="untrusted""#))
        let auto = overrides(try CodexBackend.appServerArguments(project: true))
        XCTAssertTrue(auto.contains(#"approval_policy="never""#))
        XCTAssertTrue(auto.contains("sandbox_workspace_write.network_access=true"))

        let policy = CodexBackend.policy(project: true, level: .ask, cwd: "/p")
        XCTAssertEqual(policy.thread["approvalPolicy"] as? String, "untrusted")
        XCTAssertEqual(policy.thread["approvalsReviewer"] as? String, "user", "never an automatic reviewer")
        XCTAssertEqual(policy.sandboxPolicy["networkAccess"] as? Bool, false)
        XCTAssertEqual(policy.sandboxPolicy["writableRoots"] as? [String], ["/p"])
        XCTAssertNil(CodexBackend.policy(project: true, level: .auto, cwd: "/p").thread["approvalsReviewer"])
        XCTAssertEqual(CodexBackend.policy(project: false, level: .ask, cwd: "/p").sandboxMode, "read-only", "chat ignores the level")
    }

    func testCodexRequestAndAnswerMapping() throws {
        let session = UUID()
        let network = try XCTUnwrap(CodexBackend.approvalRequest(method: "item/commandExecution/requestApproval",
                                                                params: ["command": "curl x", "cwd": "/p", "networkApprovalContext": ["host": "pypi.org", "protocol": "https"]],
                                                                fileChanges: [:], sessionID: session))
        XCTAssertEqual(network.kind, .network)
        XCTAssertEqual(network.title, "联网：pypi.org")
        var changes: [String: [[String: Any]]] = [:]
        CodexBackend.recordFileChanges(method: "item/started", params: ["item": ["type": "fileChange", "id": "f", "changes": [
            ["path": "/p/new.txt", "kind": ["type": "add"], "diff": "+hi"], ["path": "/p/old.txt", "kind": ["type": "delete"], "diff": "-bye"]]]], into: &changes)
        let files = try XCTUnwrap(CodexBackend.approvalRequest(method: "item/fileChange/requestApproval", params: ["itemId": "f", "reason": "整理"], fileChanges: changes, sessionID: session))
        XCTAssertEqual(files.title, "修改 2 个文件")
        XCTAssertEqual(files.files, ["/p/new.txt", "/p/old.txt"])
        XCTAssertEqual(files.diff, "--- 新建 /p/new.txt\n+hi\n--- 删除 /p/old.txt\n-bye")
        CodexBackend.recordFileChanges(method: "item/completed", params: ["item": ["type": "fileChange", "id": "f"]], into: &changes)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertNil(CodexBackend.approvalRequest(method: "item/permissions/requestApproval", params: [:], fileChanges: [:], sessionID: session))

        let decisions = [FolderAccessDecision.once, .conversation, .deny].map {
            (CodexBackend.approvalResponse(id: 7, decision: $0)["result"] as? [String: String])?["decision"]
        }
        XCTAssertEqual(decisions, ["accept", "acceptForSession", "decline"])
        XCTAssertEqual(CodexBackend.approvalResponse(id: "x", decision: .once)["id"] as? String, "x")
    }

    // MARK: Cursor

    func testCursorRulesAndModePerLevel() throws {
        let rules = { (level: PermissionLevel) in CursorBackend.permissionRules(servers: [], project: true, level: level) }
        XCTAssertEqual(rules(.ask)?.allow, ["Read(**)", "Write(**)"])
        XCTAssertEqual(rules(.ask)?.deny, ["Shell(*)"])
        XCTAssertEqual(rules(.readOnly)?.deny, ["Write(**)", "Shell(*)"])
        XCTAssertNil(rules(.auto))
        XCTAssertNil(CursorBackend.permissionRules(servers: [], project: false, level: .auto))

        XCTAssertEqual(CursorBackend.modeArguments(level: .auto), ["--force", "--sandbox", "disabled"])
        XCTAssertEqual(CursorBackend.modeArguments(level: .ask), ["--sandbox", "enabled"])
        XCTAssertEqual(CursorBackend.modeArguments(level: .ask, rulesWritten: false), ["--mode", "ask", "--sandbox", "enabled"], "no rules of ours: read only")
        XCTAssertEqual(CursorBackend.modeArguments(level: .readOnly), ["--mode", "ask", "--sandbox", "enabled"])
        XCTAssertEqual(CursorBackend.modeArguments(level: nil), ["--mode", "ask", "--sandbox", "enabled"])

        // Written even without MCP servers, and removed again at 自动.
        try CursorBackend.writeMCPConfig([], workspace: root, userFolder: true, project: true, level: .ask)
        let cli = root.appendingPathComponent(".cursor/cli.json")
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cli)) as? [String: [String: [String]]])
        XCTAssertEqual(written["permissions"]?["deny"], ["Shell(*)"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".cursor/mcp.json").path))
        try CursorBackend.writeMCPConfig([], workspace: root, userFolder: true, project: true, level: .auto)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cli.path))
    }

    func testCursorLeavesTheUsersOwnRulesAloneAndReportsIt() throws {
        let cursor = root.appendingPathComponent(".cursor")
        try FileManager.default.createDirectory(at: cursor, withIntermediateDirectories: true)
        try #"{"permissions":{"allow":["Shell(*)"]}}"#.write(to: cursor.appendingPathComponent("cli.json"), atomically: true, encoding: .utf8)
        let skipped = try CursorBackend.writeMCPConfig([], workspace: root, userFolder: true, project: true, level: .ask)
        XCTAssertEqual(skipped, ["cli.json"])
        XCTAssertTrue(try String(contentsOf: cursor.appendingPathComponent("cli.json"), encoding: .utf8).contains("Shell(*)"), "not replaced")
    }

    // MARK: Helpers

    private func value(after flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }

    private func text(_ result: [String: Any]) -> String {
        (result["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
    }

    private func answer(_ result: [String: Any]) throws -> [String: Any] {
        XCTAssertNil(result["isError"], "a permission answer is never a tool error")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text(result).utf8)) as? [String: Any])
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private var stored: Value
    private let lock = NSLock()
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ change: (inout Value) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}
