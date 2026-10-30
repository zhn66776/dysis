import Foundation

/// Cursor CLI adapter.  Grok and Gemini are selected explicitly through the
/// user's Cursor account; this adapter never silently falls back to another
/// model or switches to a provider API key.
public struct CursorBackend: AgentBackend, Sendable {
    public init() {}

    public func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Task.checkCancellation()
                    guard !request.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw AgentError.unavailable("Cursor 模型未配置，已停止请求。")
                    }
                    if !request.images.isEmpty {
                        throw AgentError.unavailable("Cursor CLI 当前没有公开的图片输入参数；请选择 Claude/Codex，或先把图片内容转成文字后再发送。")
                    }
                    var environment = RuntimeEnvironment.subscriptionOnly()
                    environment["NO_AUTO_UPDATE"] = "1"
                    try await CursorBackend.requireLogin(request: request, environment: environment)
                    if let selectedEffort = request.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines), !selectedEffort.isEmpty {
                        throw AgentError.unavailable("Cursor 的 effort 必须使用“发现模型”返回的具体模型档位；请重新发现模型并选择对应的 low / medium / high / xhigh 变体。")
                    }
                    // Cursor's CLI has no independent --effort flag. The UI
                    // stores the exact discovered model ID (for example
                    // grok-4.7-high or gemini-4-argon-high).
                    let cursorModelID = request.modelID
                    try CursorBackend.writeMCPConfig(request.mcpServers, workspace: request.workingDirectory)
                    for server in request.mcpServers { environment.merge(server.environment) { $1 } }
                    var arguments = [
                        "--print", "--model", cursorModelID,
                        "--mode", "ask", "--sandbox", "enabled", "--trust",
                        "--workspace", request.workingDirectory.path,
                        "--output-format", "stream-json", "--stream-partial-output"
                    ]
                    if !request.mcpServers.isEmpty { arguments.append("--approve-mcps") }
                    let allowedMCP = request.mcpServers.map(\.name)
                    if let remoteID = request.remoteSessionID, !remoteID.isEmpty {
                        arguments += ["--resume", remoteID]
                    }
                    arguments += [CursorBackend.prompt(request.prompt, mcpServers: allowedMCP)]
                    let process = CLIProcess(
                        executable: request.executableURL,
                        arguments: arguments,
                        directory: request.workingDirectory,
                        environment: environment
                    )
                    defer { process.terminate() }
                    try process.start()
                    process.finishInput()
                    var sawResult = false
                    var sawSessionID = false
                    var accumulated = ""
                    var exitCode: Int32?
                    for await event in process.events {
                        try Task.checkCancellation()
                        switch event {
                        case .stdoutLine(let line):
                            guard let data = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                            let parsed = CursorJSONEventParser.parse(object)
                            if let sessionID = parsed.sessionID {
                                sawSessionID = true
                                continuation.yield(.sessionID(sessionID))
                            }
                            if let delta = parsed.textDelta, !delta.isEmpty {
                                accumulated += delta
                                continuation.yield(.textDelta(delta))
                            }
                            if let final = parsed.finalText {
                                sawResult = true
                                if !final.isEmpty, final != accumulated { continuation.yield(.replaceText(final)) }
                            }
                            if let status = parsed.status, !status.isEmpty { continuation.yield(.status(status)) }
                            if parsed.isFailure { throw AgentError.protocolFailure(SafeText.redact(parsed.failureMessage ?? "Cursor CLI 返回失败结果。")) }
                            if let call = parsed.mcpToolCall, CursorBackend.allows(call.server, among: allowedMCP) {
                                if parsed.isToolCallStart, let tool = call.tool { continuation.yield(.status("正在调用 MCP 工具 \(call.server ?? "MCP") · \(tool)…")) }
                            } else if parsed.hasToolCall, !allowedMCP.isEmpty, !parsed.builtInToolSucceeded {
                                // Denied by the workspace permissions; the model gets the error and goes on.
                                if parsed.isToolCallStart { continuation.yield(.status("Cursor 想用内置工具 \(parsed.builtInTool ?? "")，已拒绝；你的 MCP 仍可用，继续回答…")) }
                            } else if parsed.hasToolCall {
                                throw AgentError.protocolFailure(allowedMCP.isEmpty
                                    ? "Cursor 想调用工具，但 AgentDesk 不给 Cursor 内置工具；本轮已停止。要让模型自己查 MCP，请在 MCP 工具里打开“让模型自己调用”。"
                                    : "Cursor 的内置工具（读文件、运行命令等）没有被权限拦住，AgentDesk 已停止本轮。")
                            }
                        case .stderrLine(let line):
                            if line.localizedCaseInsensitiveContains("login") {
                                continuation.yield(.status("Cursor 登录状态需要检查。"))
                            }
                        case .exited(let code): exitCode = code
                        }
                    }
                    try Task.checkCancellation()
                    guard let exitCode else { throw AgentError.processFailure("Cursor CLI 未返回进程退出状态。") }
                    if exitCode != 0 { throw AgentError.processFailure("Cursor CLI 退出码为 \(exitCode)。") }
                    if !sawSessionID { throw AgentError.protocolFailure("Cursor CLI 没有返回 Session ID。") }
                    if !sawResult { throw AgentError.protocolFailure("Cursor CLI 没有返回最终结果。") }
                    continuation.yield(.completed)
                    continuation.finish()
                } catch is CancellationError { continuation.finish(throwing: CancellationError()) }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Cursor reads MCP servers from the workspace's `.cursor/mcp.json`; the
    /// workspace is this chat's own folder, so the file is rewritten (or
    /// removed) on every send to match what the user opened to the model.
    ///
    /// Ask mode blocks every MCP call unless the permissions config allows it
    /// explicitly, so `.cursor/cli.json` allows exactly these servers' tools
    /// (`Mcp(<name>:*)`) and denies the built-in file and shell tools, so a
    /// model that reaches for them gets "Permission denied" and carries on.
    static func writeMCPConfig(_ servers: [AgentMCPServer], workspace: URL) throws {
        let url = workspace.appendingPathComponent(".cursor/mcp.json")
        let permissions = workspace.appendingPathComponent(".cursor/cli.json")
        guard !servers.isEmpty else {
            for file in [url, permissions] where FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return
        }
        var map: [String: Any] = [:]
        for server in servers {
            switch server.transport {
            case .stdio(let command, let arguments): map[server.name] = ["command": command, "args": arguments]
            case .streamableHTTP(let address): map[server.name] = ["url": address]
            }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["mcpServers": map], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: url, options: .atomic)
        let allow = servers.map { "Mcp(\($0.name):*)" }
        try JSONSerialization.data(withJSONObject: ["permissions": ["allow": allow, "deny": deniedBuiltInTools]], options: [.prettyPrinted, .sortedKeys]).write(to: permissions, options: .atomic)
    }

    /// Cursor has no system prompt flag; a short note ahead of the user's
    /// message names the opened servers, so the model goes to them rather
    /// than searching the disk.
    static func prompt(_ text: String, mcpServers: [String]) -> String {
        guard !mcpServers.isEmpty else { return text }
        return "[AgentDesk：本轮可以用这些 MCP 服务器的工具：\(mcpServers.joined(separator: "、"))。本地文件、文件搜索和命令都不可用，需要数据时调用这些 MCP 工具。]\n\n" + text
    }

    static let deniedBuiltInTools = ["Read(**)", "Write(**)", "Shell(*)"]

    /// Cursor may prefix the configured name (for example with the project);
    /// an unnamed call is still one of ours, since only ours are configured.
    static func allows(_ server: String?, among names: [String]) -> Bool {
        guard !names.isEmpty else { return false }
        guard let server, !server.isEmpty else { return true }
        return names.contains { server == $0 || server.hasSuffix("-\($0)") || server.hasSuffix("_\($0)") }
    }

    private static func requireLogin(request: AgentRequest, environment: [String: String]) async throws {
        let process = CLIProcess(executable: request.executableURL, arguments: ["status"], directory: request.workingDirectory, environment: environment)
        defer { process.terminate() }
        try process.start()
        process.finishInput()
        var exitCode: Int32?
        var statusOutput = ""
        for await event in process.events {
            try Task.checkCancellation()
            switch event {
            case .stdoutLine(let line), .stderrLine(let line):
                statusOutput += line
                statusOutput += "\n"
            case .exited(let code):
                exitCode = code
            }
        }
        guard exitCode == 0,
              !statusOutput.localizedCaseInsensitiveContains("not logged in") else {
            throw AgentError.authentication("Cursor 尚未登录。请先运行 agent login。")
        }
    }
}

public struct CursorJSONEvent: Equatable, Sendable {
    public var sessionID: String?
    public var textDelta: String?
    public var finalText: String?
    public var status: String?
    public var isFailure: Bool
    public var failureMessage: String?
    public var hasToolCall: Bool
    /// Set for an MCP tool call (`tool_call.mcpToolCall`); server and tool when given.
    public var mcpToolCall: CursorMCPCall?
    /// `tool_call` with subtype `started`.
    public var isToolCallStart = false
    /// A non-MCP tool call that completed with a `success` result: one the
    /// permissions did not stop.
    public var builtInToolSucceeded = false
    /// The non-MCP tool's name, e.g. "read" for `readToolCall`.
    public var builtInTool: String?
}

public struct CursorMCPCall: Equatable, Sendable {
    public var server: String?
    public var tool: String?
}

public enum CursorJSONEventParser {
    public static func parse(_ object: [String: Any]) -> CursorJSONEvent {
        let type = object["type"] as? String
        let sessionID = object["session_id"] as? String ?? object["chat_id"] as? String
        var event = CursorJSONEvent(sessionID: sessionID, textDelta: nil, finalText: nil, status: nil, isFailure: false, failureMessage: nil, hasToolCall: false)
        if let delta = object["delta"] as? String { event.textDelta = delta }
        if type == "text_delta" || type == "text" { event.textDelta = object["text"] as? String ?? object["content"] as? String }
        if type == "assistant" {
            // Cursor's partial stream marks the only non-duplicate assistant
            // event with timestamp_ms and omits model_call_id.  The buffered
            // pre-tool flush and final turn flush repeat text and are ignored.
            let isPartial = object["timestamp_ms"] != nil && object["model_call_id"] == nil
            if isPartial {
                event.textDelta = object["delta"] as? String ?? object["text"] as? String ?? CursorJSONEventParser.assistantText(object)
            } else if object["timestamp_ms"] == nil && object["model_call_id"] == nil {
                // Without partial streaming, a complete assistant event is
                // still useful.  The backend always requests partial output,
                // so this branch mainly makes the parser useful in isolation.
                event.textDelta = object["delta"] as? String ?? object["text"] as? String
            }
        }
        if type == "tool_call" {
            event.hasToolCall = true
            event.isToolCallStart = object["subtype"] as? String == "started"
            let call = object["tool_call"] as? [String: Any] ?? [:]
            if let mcp = call.first(where: { $0.key.lowercased().contains("mcp") })?.value as? [String: Any] {
                let args = mcp["args"] as? [String: Any] ?? mcp
                event.mcpToolCall = CursorMCPCall(server: args["providerIdentifier"] as? String ?? args["server"] as? String ?? args["serverName"] as? String,
                                                  tool: args["toolName"] as? String ?? args["name"] as? String)
            } else {
                event.builtInTool = call.keys.first { $0.hasSuffix("ToolCall") }.map { String($0.dropLast("ToolCall".count)) }
            }
            if event.mcpToolCall == nil, object["subtype"] as? String == "completed" {
                event.builtInToolSucceeded = call.values.contains {
                    ((($0 as? [String: Any])?["result"] as? [String: Any])?["success"]).map(CursorJSONEventParser.revealsContent) ?? false
                }
            }
        }
        if type == "result" || type == "final" {
            event.finalText = object["result"] as? String ?? object["text"] as? String ?? object["content"] as? String
        }
        if type == "error" || (object["is_error"] as? Bool == true) {
            event.isFailure = true
            event.failureMessage = object["error"] as? String ?? object["message"] as? String ?? "Cursor CLI 返回错误。"
        }
        if type == "system", let subtype = object["subtype"] as? String { event.status = subtype }
        return event
    }

    /// The denied Read permission filters glob and grep instead of failing
    /// them: a success with only empty `files` / `matches` showed nothing.
    /// Any other success counts as content.
    static func revealsContent(_ success: Any) -> Bool {
        var lists: [[Any]] = []
        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                for (key, item) in dict {
                    if key == "files" || key == "matches", let list = item as? [Any] { lists.append(list) } else { walk(item) }
                }
            } else if let array = value as? [Any] { array.forEach(walk) }
        }
        walk(success)
        return lists.isEmpty || lists.contains { !$0.isEmpty }
    }

    private static func assistantText(_ object: [String: Any]) -> String? {
        guard let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return nil }
        return content.compactMap { block in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined()
    }
}
