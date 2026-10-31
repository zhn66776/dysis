import Foundation

/// The narrow, text-only Claude Code adapter used by the first UI.
///
/// Claude Code remains the owner of authentication and session storage.  This
/// adapter only starts the signed binary, consumes its documented JSONL
/// stream, and never reads the credential store.
public struct ClaudeBackend: AgentBackend, Sendable {
    public init() {}

    public func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Task.checkCancellation()
                    guard !request.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw AgentError.unavailable("Claude 模型未配置，已停止请求。")
                    }
                    var environment = RuntimeEnvironment.subscriptionOnly()
                    environment["DISABLE_AUTOUPDATER"] = "1"
                    try await ClaudeBackend.requireSubscription(request: request, environment: environment)
                    // stdio MCP servers inherit the CLI's environment.
                    for server in request.mcpServers { environment.merge(server.environment) { $1 } }
                    // A files call can wait for the user's answer (FolderAccessServer.timeout).
                    if !request.mcpServers.isEmpty { environment["MCP_TOOL_TIMEOUT"] = String(FolderAccessPolicy.toolTimeoutSeconds * 1000) }

                    var arguments = try ClaudeBackend.commonArguments(modelID: request.modelID, effort: request.reasoningEffort, mcpServers: request.mcpServers, project: request.projectAccess,
                                                                      level: request.permissionLevel, approvalTool: FolderAccessPolicy.approvalTool(in: request.mcpServers),
                                                                      instructions: request.instructions)
                    arguments += try ClaudeBackend.sessionArguments(for: request)
                    let fork = request.remoteSessionID?.isEmpty == false ? nil : request.forkFrom
                    let imageContent = try MultimodalInputSupport.claudeContent(prompt: request.prompt, images: request.images)
                    if request.images.isEmpty {
                        arguments += ["-p", request.prompt]
                    } else {
                        // Claude Code's documented realtime JSONL input accepts
                        // Anthropic user content blocks, including base64 image
                        // blocks. Keep this path explicit: a text-only CLI run
                        // must never silently discard an attachment.
                        arguments += ["-p", "--input-format", "stream-json"]
                    }

                    let process = CLIProcess(
                        executable: request.executableURL,
                        arguments: arguments,
                        directory: request.workingDirectory,
                        environment: environment
                    )
                    defer { process.terminate() }
                    try process.start()
                    if request.images.isEmpty {
                        process.finishInput()
                    } else {
                        // This is the same streaming-input message shape used
                        // by Anthropic's Claude Agent SDK image example:
                        // user.message.content contains a base64 image block.
                        // The CLI's single-message -p mode cannot carry image
                        // attachments, so images deliberately use this stream
                        // path and include the stable session binding fields.
                        let sessionID = request.remoteSessionID ?? fork?.remoteSessionID ?? request.localSessionID.uuidString
                        try process.writeJSON([
                            "type": "user",
                            "message": ["role": "user", "content": imageContent],
                            "parent_tool_use_id": NSNull(),
                            "session_id": sessionID
                        ])
                        process.finishInput()
                    }
                    var accumulatedText = ""
                    var sawResult = false
                    var sawSessionID = false
                    // A fork's new session ID is reported only after a successful
                    // result. A failed resume still prints a fresh, empty session
                    // ID, and keeping it would detach the node from its history.
                    var forkedSessionID: String?
                    // Every stream line carries `session_id`; report it once,
                    // since the app persists the session on each report.
                    var reportedSessionID: String?
                    var replyModels = Set<String>()
                    var exitCode: Int32?

                    for await event in process.events {
                        try Task.checkCancellation()
                        switch event {
                        case .stdoutLine(let line):
                            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                            guard let data = line.data(using: .utf8) else { continue }
                            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                                // A diagnostic line should not be rendered as a model answer.
                                continue
                            }
                            let parsed = ClaudeJSONEventParser.parse(object)
                            if let sessionID = parsed.sessionID {
                                sawSessionID = true
                                if let fork {
                                    guard sessionID != fork.remoteSessionID else {
                                        throw AgentError.protocolFailure("Claude Code 没有创建新的分叉会话，已停止，避免改动父节点的会话。")
                                    }
                                    forkedSessionID = sessionID
                                } else if sessionID != reportedSessionID {
                                    reportedSessionID = sessionID
                                    continuation.yield(.sessionID(sessionID))
                                }
                            }
                            if let delta = parsed.textDelta, !delta.isEmpty {
                                accumulatedText += delta
                                continuation.yield(.textDelta(delta))
                            }
                            if let finalText = parsed.finalText {
                                sawResult = true
                                if !finalText.isEmpty, finalText != accumulatedText {
                                    continuation.yield(.replaceText(finalText))
                                }
                            }
                            if let status = parsed.status, !status.isEmpty {
                                continuation.yield(.status(status))
                            }
                            for step in ClaudeStepParser.steps(object) { continuation.yield(.step(step)) }
                            if let models = parsed.actualModelIDs, !models.isEmpty {
                                if object["type"] as? String == "assistant" {
                                    replyModels.formUnion(models)
                                    continuation.yield(.actualModels(replyModels.sorted()))
                                } else if replyModels.isEmpty {
                                    continuation.yield(.actualModels(models))
                                }
                            }
                            if let usage = parsed.contextUsage { continuation.yield(.contextUsage(usage)) }
                            if let quota = parsed.quota { continuation.yield(.quota(quota)) }
                            if parsed.isFailure {
                                throw AgentError.protocolFailure(SafeText.redact(parsed.failureMessage ?? "Claude Code 返回失败结果。"))
                            }
                        case .stderrLine(let line):
                            // Stderr may contain paths or account details.  Do not
                            // surface it verbatim in the chat transcript.
                            if line.localizedCaseInsensitiveContains("login") || line.localizedCaseInsensitiveContains("auth") {
                                continuation.yield(.status("Claude Code 认证状态需要检查。"))
                            }
                        case .exited(let code):
                            exitCode = code
                        }
                    }
                    try Task.checkCancellation()
                    guard let exitCode else {
                        throw AgentError.processFailure("Claude Code 未返回进程退出状态。")
                    }
                    if exitCode != 0 {
                        throw AgentError.processFailure("Claude Code 退出码为 \(exitCode)。")
                    }
                    if !sawSessionID {
                        throw AgentError.protocolFailure("Claude Code 没有返回 Session ID。")
                    }
                    if !sawResult {
                        throw AgentError.protocolFailure("Claude Code 没有返回最终结果。")
                    }
                    if let forkedSessionID { continuation.yield(.sessionID(forkedSessionID)) }
                    continuation.yield(.completed)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Resume, native fork (`--fork-session`, latest state only) or a new session.
    static func sessionArguments(for request: AgentRequest) throws -> [String] {
        if let remoteID = request.remoteSessionID, !remoteID.isEmpty { return ["--resume", remoteID] }
        if let fork = request.forkFrom {
            guard fork.throughTurnID == nil else {
                throw AgentError.unavailable("Claude Code 只能从会话的最新一轮分叉。")
            }
            return ["--resume", fork.remoteSessionID, "--fork-session"]
        }
        return ["--session-id", request.localSessionID.uuidString]
    }

    /// Built-in tools stay off. With MCP servers the model may call only their
    /// tools (allowed per server), over a bounded number of turns. In a
    /// trusted project folder (`project`) Claude Code works as it does in a
    /// terminal there: all built-in tools, no permission prompts, the
    /// project's and the user's settings loaded; MCP is still only ours.
    /// Below the automatic level (`level`) the permission mode is `default`:
    /// what the level allows is pre-allowed with --allowedTools, and every
    /// other prompt goes to `approvalTool` (AgentDesk's approval card), or is
    /// denied when there is none.
    static let maxProjectTurns = 100

    static func commonArguments(modelID: String, effort: String?, mcpServers: [AgentMCPServer] = [], project: Bool = false,
                                level: PermissionLevel = .auto, approvalTool: String? = nil, instructions: String? = nil) throws -> [String] {
        try commonToolArguments(modelID: modelID, effort: effort, mcpServers: mcpServers, project: project, level: level, approvalTool: approvalTool)
            + ruleArguments(instructions: instructions, project: project)
    }

    /// AgentDesk's rule layers ride on `--append-system-prompt`. The system
    /// prompt snapshot is off so an edited rule applies from the next turn
    /// rather than after the next compaction. In a project, `AGENTS.md`
    /// loads beside `CLAUDE.md` (once when `CLAUDE.md` already imports it).
    /// Auto memory is off in both modes (`settingsJSON`).
    static func ruleArguments(instructions: String?, project: Bool) throws -> [String] {
        var arguments = ["--system-prompt-snapshot", "off", "--settings", try settingsJSON(project: project)]
        if let instructions, !instructions.isEmpty { arguments += ["--append-system-prompt", instructions] }
        return arguments
    }

    /// Claude's own auto memory stays off: the project memory is
    /// AgentDesk's `.agentdesk/memory.md`, the same for every CLI.
    static func settingsJSON(project: Bool) throws -> String {
        var settings: [String: Any] = ["autoMemoryEnabled": false]
        if project { settings["instructionFiles"] = "claude-md-and-agents-md" }
        return String(decoding: try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]), as: UTF8.self)
    }

    private static func commonToolArguments(modelID: String, effort: String?, mcpServers: [AgentMCPServer], project: Bool,
                                            level: PermissionLevel, approvalTool: String?) throws -> [String] {
        if project {
            let permissions = level == .auto ? ["--permission-mode", "bypassPermissions"]
                : ["--permission-mode", "default", "--permission-prompts", approvalTool == nil ? "none" : "host"]
                    + (approvalTool.map { ["--permission-prompt-tool", $0] } ?? [])
                    + ["--allowedTools", preallowedTools(level: level, mcpServers: mcpServers).joined(separator: ",")]
            var arguments = ["--strict-mcp-config", "--mcp-config", try mcpConfigJSON(mcpServers)] + permissions + [
                             "--max-turns", String(maxProjectTurns), "--model", modelID,
                             "--output-format", "stream-json", "--verbose", "--include-partial-messages"]
            if let effort = try normalizedEffort(effort) { arguments += ["--effort", effort] }
            return arguments
        }
        let toolArguments = mcpServers.isEmpty
            ? ["--mcp-config", "{\"mcpServers\":{}}", "--tools", "", "--disallowedTools", "mcp__*"]
            : ["--mcp-config", try mcpConfigJSON(mcpServers), "--tools", "",
               "--allowedTools", mcpServers.map { "mcp__\($0.name)" }.joined(separator: ",")]
        // --safe-mode also drops servers passed with --mcp-config (checked
        // live with Claude Code 2.1.308), so a turn with MCP relies on
        // --restricted, --strict-mcp-config and --tools "" alone.
        var arguments = (mcpServers.isEmpty ? ["--safe-mode"] : []) + ["--restricted", "--strict-mcp-config"] + toolArguments + [
            "--permission-mode", "dontAsk", "--permission-prompts", "none",
            "--max-turns", mcpServers.isEmpty ? "1" : String(maxToolTurns), "--model", modelID,
            "--output-format", "stream-json", "--verbose",
            "--include-partial-messages"
        ]
        if let effort = try normalizedEffort(effort) { arguments += ["--effort", effort] }
        return arguments
    }

    /// What a level runs without asking: reading the folder, and at 询问
    /// editing inside it (`./**` is relative to the working directory). The
    /// MCP servers the user opened stay callable.
    static func preallowedTools(level: PermissionLevel, mcpServers: [AgentMCPServer]) -> [String] {
        let read = ["Read(./**)", "Glob", "Grep", "LS", "TodoWrite"]
        let write = level >= .ask ? ["Edit(./**)"] : []
        return read + write + mcpServers.map { "mcp__\($0.name)" }
    }

    private static func normalizedEffort(_ raw: String?) throws -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let normalized = ReasoningEffortCatalog.normalized(raw, choices: ReasoningEffortCatalog.claudeChoices) else {
            throw AgentError.unavailable("Claude 推理深度无效。可选：\(ReasoningEffortCatalog.claudeChoices.joined(separator: ", "))。")
        }
        return normalized
    }

    /// Model turns one send may take when it calls MCP tools.
    static let maxToolTurns = 12

    static func mcpConfigJSON(_ servers: [AgentMCPServer]) throws -> String {
        var map: [String: Any] = [:]
        for server in servers {
            switch server.transport {
            case .stdio(let command, let arguments): map[server.name] = ["type": "stdio", "command": command, "args": arguments]
            case .streamableHTTP(let url): map[server.name] = ["type": "http", "url": url]
            }
        }
        let data = try JSONSerialization.data(withJSONObject: ["mcpServers": map], options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func requireSubscription(request: AgentRequest, environment: [String: String]) async throws {
        let process = CLIProcess(
            executable: request.executableURL,
            arguments: ["--safe-mode", "--restricted", "auth", "status"],
            directory: request.workingDirectory,
            environment: environment
        )
        defer { process.terminate() }
        try process.start()
        process.finishInput()
        var output = Data()
        var exitCode: Int32?
        for await event in process.events {
            try Task.checkCancellation()
            switch event {
            case .stdoutLine(let line): output.append(contentsOf: (line + "\n").utf8)
            case .stderrLine: break
            case .exited(let code): exitCode = code
            }
        }
        guard exitCode == 0, let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any] else {
            throw AgentError.authentication("Claude Code 尚未完成订阅登录。请先运行 claude auth login。")
        }
        let method = object["authMethod"] as? String
        let provider = object["apiProvider"] as? String
        let plan = (object["subscriptionType"] as? String)?.lowercased()
        guard method == "claude.ai", provider == "firstParty", ["pro", "max", "team", "enterprise"].contains(plan ?? "") else {
            throw AgentError.authentication("当前 Claude 认证不是可用的 Claude 订阅登录。")
        }
    }
}

public struct ClaudeJSONEvent: Equatable, Sendable {
    public var sessionID: String?
    public var textDelta: String?
    public var finalText: String?
    public var status: String?
    public var isFailure: Bool
    public var failureMessage: String?
    public var actualModelIDs: [String]?
    public var contextUsage: ContextUsage?
    public var quota: ProviderQuota?
}

public enum ClaudeJSONEventParser {
    public static func parse(_ object: [String: Any]) -> ClaudeJSONEvent {
        let type = object["type"] as? String
        var event = ClaudeJSONEvent(sessionID: object["session_id"] as? String, textDelta: nil, finalText: nil, status: nil, isFailure: false, failureMessage: nil)
        if type == "assistant", let message = object["message"] as? [String: Any],
           let model = message["model"] as? String, !model.isEmpty {
            event.actualModelIDs = [model]
        }
        if type == "system", let subtype = object["subtype"] as? String, subtype == "init" {
            event.status = "Claude 已连接。"
            let failed = (object["mcp_servers"] as? [[String: Any]] ?? [])
                .filter { ($0["status"] as? String).map { $0 != "connected" } ?? false }
                .compactMap { $0["name"] as? String }
            if !failed.isEmpty { event.status = "MCP 服务器没有连上：\(failed.joined(separator: "、"))。" }
        }
        if type == "assistant", let message = object["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] {
            let tools = content.filter { $0["type"] as? String == "tool_use" }.compactMap { $0["name"] as? String }
            if let name = tools.last { event.status = name.hasPrefix("mcp__") ? "正在调用 MCP 工具 \(MCPToolName.display(name))…" : "正在使用 \(name)…" }
        }
        if type == "stream_event", let nested = object["event"] as? [String: Any], let nestedType = nested["type"] as? String {
            if nestedType == "content_block_delta", let delta = nested["delta"] as? [String: Any], delta["type"] as? String == "text_delta" {
                event.textDelta = delta["text"] as? String
            }
        }
        if type == "result" {
            if let usage = object["modelUsage"] as? [String: Any], !usage.isEmpty {
                event.actualModelIDs = usage.keys.sorted()
            }
            // Context after this turn: everything the model read plus what it wrote.
            if let usage = object["usage"] as? [String: Any] {
                let used = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]
                    .reduce(0) { $0 + ((usage[$1] as? NSNumber)?.intValue ?? 0) }
                let windows = (object["modelUsage"] as? [String: Any])?.values
                    .compactMap { (($0 as? [String: Any])?["contextWindow"] as? NSNumber)?.intValue }.filter { $0 > 0 } ?? []
                if used > 0 { event.contextUsage = ContextUsage(usedTokens: used, windowTokens: windows.max()) }
            }
            event.finalText = object["result"] as? String
            if let subtype = object["subtype"] as? String, subtype != "success" || object["is_error"] as? Bool == true {
                event.isFailure = true
                event.failureMessage = (object["result"] as? String) ?? "Claude Code 返回失败结果。"
            }
        }
        if type == "rate_limit_event", let info = object["rate_limit_info"] as? [String: Any] {
            event.quota = quota(from: info)
        }
        if type == "error" || (object["is_error"] as? Bool == true && type != "result") {
            event.isFailure = true
            event.failureMessage = (object["error"] as? String) ?? "Claude Code 返回错误。"
        }
        return event
    }

    /// Subscription windows from `rate_limit_event.rate_limit_info`.
    /// `utilization` is a 0–1 fraction of the window.
    static func quota(from info: [String: Any]) -> ProviderQuota {
        let labels = ["five_hour": "5 小时", "seven_day": "每周", "seven_day_opus": "每周 · Opus", "seven_day_sonnet": "每周 · Sonnet",
                      "seven_day_overage_included": "每周（含额外用量）", "overage": "额外用量"]
        func date(_ v: Any?) -> Date? { (v as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } }
        var windows: [QuotaWindow] = []
        if let unified = info["unifiedWindows"] as? [String: Any] {
            for key in ["five_hour", "seven_day", "seven_day_overage_included"] {
                guard let w = unified[key] as? [String: Any], let u = (w["utilization"] as? NSNumber)?.doubleValue else { continue }
                windows.append(QuotaWindow(label: labels[key] ?? key, usedPercent: u * 100, resetsAt: date(w["resetsAt"])))
            }
        }
        if windows.isEmpty, let u = (info["utilization"] as? NSNumber)?.doubleValue {
            let type = info["rateLimitType"] as? String ?? ""
            windows.append(QuotaWindow(label: labels[type] ?? "用量", usedPercent: u * 100, resetsAt: date(info["resetsAt"])))
        }
        return ProviderQuota(windows: windows, status: info["status"] as? String)
    }
}
