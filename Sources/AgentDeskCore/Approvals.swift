import Foundation

/// Asks the user about one action and waits for the answer (design/HARNESS.md H1).
/// It must answer `.deny` when the wait times out or the turn stops.
public typealias AgentApprover = @Sendable (ApprovalRequest) async -> FolderAccessDecision

public enum ApprovalPolicy {
    /// How long an approval waits; no answer is a no. Claude's MCP tool
    /// timeout (`FolderAccessPolicy.toolTimeoutSeconds`) is longer.
    public static let timeout: TimeInterval = FolderAccessPolicy.approvalTimeout
    static let maxDiffCharacters = 12_000
}

/// One action a CLI wants to take that its permission level does not allow
/// on its own: shown as a card in the node's panel.
public struct ApprovalRequest: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case command, fileChange, network, tool }
    public var id: UUID
    /// Set by AgentDesk's approval tool, as for folder requests: requests
    /// from another launch's helper are declined.
    public var token: String?
    public var sessionID: UUID
    public var kind: Kind
    /// What the model wants to do, e.g. "运行命令".
    public var title: String
    public var command: String?
    public var cwd: String?
    public var files: [String]
    public var diff: String?
    public var reason: String?
    /// What "本会话内都允许" covers, e.g. "同一条命令".
    public var sessionScope: String?
    /// The key the approval tool remembers for a session answer.
    public var grantKey: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), token: String? = nil, sessionID: UUID, kind: Kind, title: String, command: String? = nil, cwd: String? = nil, files: [String] = [], diff: String? = nil, reason: String? = nil, sessionScope: String? = nil, grantKey: String? = nil, createdAt: Date = Date()) {
        self.id = id; self.token = token; self.sessionID = sessionID; self.kind = kind; self.title = title; self.command = command; self.cwd = cwd
        self.files = files; self.diff = diff; self.reason = reason; self.sessionScope = sessionScope; self.grantKey = grantKey; self.createdAt = createdAt
    }

    static func clipped(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text.count > ApprovalPolicy.maxDiffCharacters ? String(text.prefix(ApprovalPolicy.maxDiffCharacters)) + "\n… 已截断" : text
    }
}

/// Approval requests travel like folder requests: the approval tool runs in a
/// process the CLI started, so small JSON files in the data folder are its
/// only channel back to the app.
extension FolderAccessExchange {
    var approvalsDirectory: URL { root.appendingPathComponent("approval-requests", isDirectory: true) }
    var approvalGrantsDirectory: URL { root.appendingPathComponent("approval-grants", isDirectory: true) }
    private func approvalURL(_ id: UUID) -> URL { approvalsDirectory.appendingPathComponent("\(id.uuidString).request.json") }
    private func approvalAnswerURL(_ id: UUID) -> URL { approvalsDirectory.appendingPathComponent("\(id.uuidString).response.json") }
    private func approvalGrantsURL(_ session: UUID) -> URL { approvalGrantsDirectory.appendingPathComponent("\(session.uuidString).json") }

    public func postApproval(_ request: ApprovalRequest) throws {
        try FileManager.default.createDirectory(at: approvalsDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(request).write(to: approvalURL(request.id), options: .atomic)
    }

    /// Requests not answered yet, oldest first.
    public func pendingApprovals() -> [ApprovalRequest] {
        let files = (try? FileManager.default.contentsOfDirectory(at: approvalsDirectory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return files.filter { $0.lastPathComponent.hasSuffix(".request.json") }
            .compactMap { try? decoder.decode(ApprovalRequest.self, from: Data(contentsOf: $0)) }
            .filter { !FileManager.default.fileExists(atPath: approvalAnswerURL($0.id).path) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// The app's answer. A session answer records the grant first, so the
    /// tool sees it when it reads the answer.
    public func respondApproval(_ request: ApprovalRequest, decision: FolderAccessDecision) throws {
        if decision == .conversation, let key = request.grantKey {
            try setApprovalGrants(approvalGrants(session: request.sessionID) + [key], session: request.sessionID)
        }
        try FileManager.default.createDirectory(at: approvalsDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(decision).write(to: approvalAnswerURL(request.id), options: .atomic)
    }

    /// The app's answer, or nil when none came in time. Both files are removed.
    public func waitForApproval(_ id: UUID, timeout: TimeInterval, poll: TimeInterval = 0.2) -> FolderAccessDecision? {
        let deadline = Date().addingTimeInterval(timeout)
        defer {
            try? FileManager.default.removeItem(at: approvalURL(id))
            try? FileManager.default.removeItem(at: approvalAnswerURL(id))
        }
        while Date() < deadline {
            if let data = try? Data(contentsOf: approvalAnswerURL(id)), let decision = try? JSONDecoder().decode(FolderAccessDecision.self, from: data) { return decision }
            Thread.sleep(forTimeInterval: poll)
        }
        return nil
    }

    /// Declines a request the app will not show (another launch, or a stopped turn).
    public func discardApproval(_ id: UUID) {
        try? FileManager.default.createDirectory(at: approvalsDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(FolderAccessDecision.deny).write(to: approvalAnswerURL(id), options: .atomic)
    }

    public func approvalGrants(session: UUID) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(contentsOf: approvalGrantsURL(session)))) ?? []
    }

    public func setApprovalGrants(_ keys: [String], session: UUID) throws {
        if keys.isEmpty {
            try? FileManager.default.removeItem(at: approvalGrantsURL(session))
            return
        }
        try FileManager.default.createDirectory(at: approvalGrantsDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(Array(Set(keys)).sorted()).write(to: approvalGrantsURL(session), options: .atomic)
    }
}

/// Claude Code's `--permission-prompt-tool`, served by `agentdesk-files`
/// (`mcp__agentdesk_files__approve`). Claude Code calls it with
/// `{tool_name, input}` whenever its permission mode would prompt, and
/// reads back `{"behavior":"allow","updatedInput":…}` or `{"behavior":"deny","message":…}`.
public enum ClaudeApprovalTool {
    public static let name = "approve"
    public static var qualifiedName: String { "mcp__\(FolderAccessPolicy.serverName)__\(name)" }

    static let definition: [String: Any] = [
        "name": name,
        "description": "AgentDesk 内部使用：Claude Code 在需要用户确认时调用它。模型不要自己调用这个工具。",
        "inputSchema": ["type": "object", "properties": ["tool_name": ["type": "string"], "input": ["type": "object"], "tool_use_id": ["type": "string"]], "required": ["tool_name", "input"]],
    ]

    static let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    /// What a session answer covers: the same command, the same file, the
    /// same site, or the whole tool.
    public static func grantKey(toolName: String, input: [String: Any]) -> String {
        if toolName == "Bash", let command = input["command"] as? String { return "Bash:\(command)" }
        if editTools.contains(toolName), let path = filePath(input) { return "Edit:\(path)" }
        if toolName == "WebFetch", let url = (input["url"] as? String).flatMap(URL.init(string:)), let host = url.host { return "WebFetch:\(host)" }
        return toolName
    }

    public static func request(toolName: String, input: [String: Any], sessionID: UUID, token: String?, cwd: String?) -> ApprovalRequest {
        let key = grantKey(toolName: toolName, input: input)
        let reason = input["description"] as? String
        switch toolName {
        case "Bash":
            return ApprovalRequest(token: token, sessionID: sessionID, kind: .command, title: "运行命令", command: input["command"] as? String, cwd: cwd,
                                   reason: reason, sessionScope: "同一条命令", grantKey: key)
        case _ where editTools.contains(toolName):
            let path = filePath(input)
            return ApprovalRequest(token: token, sessionID: sessionID, kind: .fileChange, title: toolName == "Write" ? "写入文件" : "修改文件", cwd: cwd,
                                   files: path.map { [$0] } ?? [], diff: ApprovalRequest.clipped(diff(toolName: toolName, input: input)),
                                   reason: reason, sessionScope: "这个文件", grantKey: key)
        case "WebFetch", "WebSearch":
            let target = input["url"] as? String ?? input["query"] as? String
            return ApprovalRequest(token: token, sessionID: sessionID, kind: .network, title: toolName == "WebFetch" ? "打开网页" : "联网搜索", command: target, cwd: cwd,
                                   reason: input["prompt"] as? String ?? reason, sessionScope: toolName == "WebFetch" ? "这个网站" : "联网搜索", grantKey: key)
        default:
            let detail = (try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) }
            return ApprovalRequest(token: token, sessionID: sessionID, kind: .tool, title: "使用 \(toolName.hasPrefix("mcp__") ? MCPToolName.display(toolName) : toolName)", cwd: cwd,
                                   diff: ApprovalRequest.clipped(detail), reason: reason, sessionScope: "\(toolName) 工具", grantKey: key)
        }
    }

    /// The text Claude Code reads back. nil is a timeout.
    public static func answer(_ decision: FolderAccessDecision?, input: [String: Any]) -> String {
        let object: [String: Any]
        switch decision {
        case .once?, .conversation?: object = ["behavior": "allow", "updatedInput": input]
        case .deny?: object = ["behavior": "deny", "message": "用户拒绝了这个操作。不要换一种方式重试同一件事；如果确实需要，请说明原因，让用户决定。"]
        case nil: object = ["behavior": "deny", "message": "用户没有在 \(Int(ApprovalPolicy.timeout)) 秒内确认，AgentDesk 已拒绝这个操作。"]
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func filePath(_ input: [String: Any]) -> String? { input["file_path"] as? String ?? input["notebook_path"] as? String }

    /// A plain -/+ view of what the edit tool would write.
    static func diff(toolName: String, input: [String: Any]) -> String? {
        func lines(_ prefix: String, _ text: String?) -> [String] { (text ?? "").split(separator: "\n", omittingEmptySubsequences: false).map { prefix + $0 } }
        switch toolName {
        case "Write": return lines("+", input["content"] as? String).joined(separator: "\n")
        case "Edit": return (lines("-", input["old_string"] as? String) + lines("+", input["new_string"] as? String)).joined(separator: "\n")
        case "MultiEdit":
            let edits = input["edits"] as? [[String: Any]] ?? []
            return edits.map { (lines("-", $0["old_string"] as? String) + lines("+", $0["new_string"] as? String)).joined(separator: "\n") }.joined(separator: "\n…\n")
        case "NotebookEdit": return lines("+", input["new_source"] as? String).joined(separator: "\n")
        default: return nil
        }
    }
}
