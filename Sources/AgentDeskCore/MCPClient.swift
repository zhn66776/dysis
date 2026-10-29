import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A deliberately user-mediated MCP client. It can inspect tools and invoke a
/// selected tool, but it never discovers or invokes tools on behalf of a model.
public final class MCPClient: @unchecked Sendable {
    public let configuration: MCPServerConfiguration
    public let limits: MCPLimits
    public let workingDirectory: URL

    private let lock = NSLock()
    private var activeCancel: (() -> Void)?

    public init(configuration: MCPServerConfiguration, workingDirectory: URL? = nil, limits: MCPLimits = MCPLimits()) {
        self.configuration = configuration
        self.workingDirectory = workingDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        self.limits = limits
    }

    public func cancel() {
        lock.lock(); let cancel = activeCancel; lock.unlock()
        cancel?()
    }

    public func testConnection() async throws -> MCPConnectionInfo {
        try await withConnection { connection in
            try await connection.initialize()
        }
    }

    public func listTools() async throws -> [MCPTool] {
        try await withConnection { connection in
            _ = try await connection.initialize()
            var tools: [MCPTool] = []
            var cursor: String?
            var seenCursors = Set<String>()
            for page in 0..<self.limits.maxPages {
                try Task.checkCancellation()
                var params: [String: Any] = [:]
                if let cursor { params["cursor"] = cursor }
                let result = try await connection.request(method: "tools/list", params: params)
                guard let array = result["tools"] as? [[String: Any]] else {
                    throw AgentError.protocolFailure("MCP tools/list 返回格式无效。")
                }
                for object in array {
                    if tools.count >= self.limits.maxTools { throw AgentError.protocolFailure("MCP 工具数量超过安全上限。") }
                    guard let name = object["name"] as? String, !name.isEmpty else { continue }
                    tools.append(MCPTool(name: name,
                                         title: object["title"] as? String,
                                         description: object["description"] as? String,
                                         inputSchema: try Self.jsonValue(object["inputSchema"]),
                                         annotations: try Self.jsonValue(object["annotations"])))
                }
                guard let next = result["nextCursor"] as? String, !next.isEmpty else { return tools }
                if page + 1 >= self.limits.maxPages || seenCursors.contains(next) {
                    throw AgentError.protocolFailure("MCP tools/list 分页超过安全上限。")
                }
                seenCursors.insert(next)
                cursor = next
            }
            throw AgentError.protocolFailure("MCP tools/list 分页超过安全上限。")
        }
    }

    /// `argumentsJSON` must be a JSON object. This is only called after the
    /// user explicitly chooses a tool and presses the Run button in the UI.
    public func callTool(name: String, argumentsJSON: String = "{}") async throws -> MCPToolResult {
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
            throw AgentError.protocolFailure("MCP 工具参数必须是 JSON 对象。")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentError.protocolFailure("MCP 工具名称不能为空。")
        }
        return try await withConnection { connection in
            _ = try await connection.initialize()
            let object = try await connection.request(method: "tools/call", params: ["name": name, "arguments": arguments])
            let output = try Self.result(from: object, limits: self.limits)
            return output
        }
    }

    private func withConnection<T>(_ operation: @escaping (MCPConnection) async throws -> T) async throws -> T {
        guard configuration.enabled else { throw AgentError.unavailable("MCP 服务器已停用。请先启用它。") }
        let connection = try MCPConnection(configuration: configuration, workingDirectory: workingDirectory, limits: limits)
        installCancel { connection.close() }
        defer {
            connection.close()
            installCancel(nil)
        }
        return try await operation(connection)
    }

    private func installCancel(_ value: (() -> Void)?) {
        lock.lock(); activeCancel = value; lock.unlock()
    }

    private static func jsonValue(_ value: Any?) throws -> MCPJSONValue? {
        guard let value else { return nil }
        return try MCPJSONValue(any: value)
    }

    private static func result(from object: [String: Any], limits: MCPLimits) throws -> MCPToolResult {
        let rawData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard rawData.count <= limits.maxOutputBytes else { throw AgentError.protocolFailure("MCP 工具输出超过安全上限。") }
        let raw = Self.redactMCPText(String(decoding: rawData, as: UTF8.self))
        var content: [MCPContent] = []
        if let values = object["content"] as? [[String: Any]] {
            for value in values {
                content.append(MCPContent(type: value["type"] as? String ?? "unknown",
                                           text: value["text"] as? String,
                                           data: value["data"] as? String,
                                           mimeType: value["mimeType"] as? String,
                                           raw: try jsonValue(value)))
            }
        }
        return MCPToolResult(content: content,
                             structuredContent: try jsonValue(object["structuredContent"]),
                             isError: object["isError"] as? Bool ?? false,
                             rawJSON: raw)
    }

    private static func redactMCPText(_ input: String) -> String {
        // Preserve the complete bounded result for later inspection while
        // still removing common credential forms. SafeText.redact is intended
        // for short UI errors and truncates at 4,000 characters, which would
        // make a valid tool result incomplete.
        var value = input
        for pattern in [#"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+"#, #"\b(?:sk-[A-Za-z0-9_-]+|xai-[A-Za-z0-9_-]+|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)\b"#, #"(?i)(access_token|refresh_token|api_key|authorization)([\s\"':=]+)[^\s,\"}]+"#] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                value = regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "[已隐藏凭据]")
            }
        }
        return value
    }
}

private final class MCPConnection: @unchecked Sendable {
    private let configuration: MCPServerConfiguration
    private let workingDirectory: URL
    private let limits: MCPLimits
    private var requestID = 0
    private var sessionID: String?
    private var transport: MCPTransportConnection

    init(configuration: MCPServerConfiguration, workingDirectory: URL, limits: MCPLimits) throws {
        self.configuration = configuration; self.workingDirectory = workingDirectory; self.limits = limits
        switch configuration.transport {
        case .stdio(let command, let arguments):
            let expanded = NSString(string: command).expandingTildeInPath
            guard !expanded.isEmpty else { throw AgentError.unavailable("MCP stdio 命令不能为空。") }
            self.transport = .stdio(try MCPStdioTransport(executable: URL(fileURLWithPath: expanded), arguments: arguments, directory: workingDirectory, environment: MCPConnection.environment(for: configuration), timeout: limits.timeout))
        case .streamableHTTP(let value):
            guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw AgentError.unavailable("MCP Streamable HTTP 地址必须是 http 或 https。")
            }
            self.transport = .http(MCPHTTPTransport(url: url, timeout: limits.timeout))
        }
    }

    func initialize() async throws -> MCPConnectionInfo {
        let object = try await request(method: "initialize", params: [
            "protocolVersion": "2025-03-26",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "AgentDesk", "version": "0.2.0"]
        ])
        guard let protocolVersion = object["protocolVersion"] as? String,
              Self.isSupportedProtocolVersion(protocolVersion) else {
            throw AgentError.protocolFailure("MCP 服务器返回了不受支持的协议版本。AgentDesk 需要 2025-03-26 或更新版本。")
        }
        transport.setProtocolVersion(protocolVersion)
        let server = object["serverInfo"] as? [String: Any]
        let info = MCPConnectionInfo(protocolVersion: protocolVersion,
                                     serverName: server?["name"] as? String,
                                     serverVersion: server?["version"] as? String,
                                     capabilities: try MCPJSONValue(any: object["capabilities"] ?? NSNull()))
        try await transport.notify(method: "notifications/initialized", params: [:], sessionID: sessionID)
        return info
    }

    private static func isSupportedProtocolVersion(_ value: String) -> Bool {
        // Only versions whose wire behavior has been reviewed are accepted;
        // an arbitrary future date may change the handshake or streaming
        // contract and must not be silently treated as compatible.
        ["2025-03-26", "2025-06-18", "2025-11-25"].contains(value)
    }

    func request(method: String, params: [String: Any]) async throws -> [String: Any] {
        try Task.checkCancellation()
        requestID += 1
        let id = requestID
        let response = try await transport.request(id: id, method: method, params: params, sessionID: sessionID, limits: limits)
        if let value = response.sessionID { sessionID = value }
        if let error = response.error {
            let message = SafeText.redact(error["message"] as? String ?? "MCP 请求失败。")
            if error["code"] as? Int == -32001 { throw AgentError.processFailure("MCP 服务繁忙：\(message)") }
            throw AgentError.protocolFailure(message)
        }
        guard let result = response.result else { throw AgentError.protocolFailure("MCP 请求没有返回 result。") }
        return result
    }

    func close() { transport.close() }

    private static func environment(for configuration: MCPServerConfiguration) -> [String: String] {
        let current = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var environment: [String: String] = [
            "PATH": [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":"),
            "HOME": home,
            "TMPDIR": current["TMPDIR"] ?? FileManager.default.temporaryDirectory.path,
            "LANG": current["LANG"] ?? "en_US.UTF-8",
            "LC_ALL": current["LC_ALL"] ?? current["LANG"] ?? "en_US.UTF-8",
            "NO_COLOR": "1"
        ]
        for key in configuration.environmentVariableNames where MCPServerConfiguration.validEnvironmentName(key) {
            if let value = current[key] { environment[key] = value }
        }
        return environment
    }
}

private struct MCPRPCResponse {
    var result: [String: Any]?
    var error: [String: Any]?
    var sessionID: String?
}

private enum MCPTransportConnection: @unchecked Sendable {
    case stdio(MCPStdioTransport)
    case http(MCPHTTPTransport)

    func request(id: Int, method: String, params: [String: Any], sessionID: String?, limits: MCPLimits) async throws -> MCPRPCResponse {
        switch self {
        case .stdio(let transport): return try await transport.request(id: id, method: method, params: params, sessionID: sessionID, limits: limits)
        case .http(let transport): return try await transport.request(id: id, method: method, params: params, sessionID: sessionID, limits: limits)
        }
    }
    func notify(method: String, params: [String: Any], sessionID: String?) async throws {
        switch self {
        case .stdio(let transport): try await transport.notify(method: method, params: params, sessionID: sessionID)
        case .http(let transport): try await transport.notify(method: method, params: params, sessionID: sessionID)
        }
    }
    func setProtocolVersion(_ value: String) {
        switch self { case .stdio: break; case .http(let transport): transport.protocolVersion = value }
    }
    func close() {
        switch self { case .stdio(let t): t.close(); case .http(let t): t.close() }
    }
}

private final class MCPStdioTransport: @unchecked Sendable {
    private let process: CLIProcess
    private var iterator: AsyncStream<ProcessEvent>.Iterator
    private let lock = NSLock()
    private var closed = false

    init(executable: URL, arguments: [String], directory: URL, environment: [String: String], timeout: TimeInterval) throws {
        process = CLIProcess(executable: executable, arguments: arguments, directory: directory, environment: environment, timeout: timeout)
        iterator = process.events.makeAsyncIterator()
        try process.start()
    }

    func request(id: Int, method: String, params: [String: Any], sessionID: String?, limits: MCPLimits) async throws -> MCPRPCResponse {
        try process.writeJSON(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        return try await nextResponse(id: id, limits: limits)
    }

    func notify(method: String, params: [String: Any], sessionID: String?) async throws {
        try process.writeJSON(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func nextResponse(id: Int, limits: MCPLimits) async throws -> MCPRPCResponse {
        var bytes = 0
        while let event = await iterator.next() {
            try Task.checkCancellation()
            switch event {
            case .stdoutLine(let line):
                bytes += line.utf8.count
                if bytes > limits.maxOutputBytes { throw AgentError.protocolFailure("MCP stdio 输出超过安全上限。") }
                guard let data = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let method = object["method"] as? String, let serverRequestID = object["id"] {
                    // A stdio server cannot require an interactive callback
                    // from this workbench. Explicitly reject such requests so
                    // the server cannot wait indefinitely for a capability we
                    // do not implement.
                    try process.writeJSON(["jsonrpc": "2.0", "id": serverRequestID, "error": ["code": -32601, "message": "AgentDesk does not support server-initiated requests (\(method))."]])
                    continue
                }
                if let responseID = object["id"] as? Int, responseID == id { return MCPRPCResponse(result: object["result"] as? [String: Any], error: object["error"] as? [String: Any], sessionID: nil) }
                if let responseID = object["id"] as? NSNumber, responseID.intValue == id { return MCPRPCResponse(result: object["result"] as? [String: Any], error: object["error"] as? [String: Any], sessionID: nil) }
            case .stderrLine:
                continue
            case .exited(let code):
                throw AgentError.processFailure("MCP stdio 服务已退出（状态码 \(code)）。")
            }
        }
        throw AgentError.processFailure("MCP stdio 服务在响应前关闭。")
    }

    func close() {
        lock.lock(); if closed { lock.unlock(); return }; closed = true; lock.unlock()
        process.terminate()
    }
}

private final class MCPHTTPTransport: @unchecked Sendable {
    private let url: URL
    private let timeout: TimeInterval
    private let session: URLSession
    private let lock = NSLock()
    private var closed = false
    var protocolVersion = "2025-03-26"

    init(url: URL, timeout: TimeInterval) { self.url = url; self.timeout = timeout; session = URLSession(configuration: .ephemeral) }

    func request(id: Int, method: String, params: [String: Any], sessionID: String?, limits: MCPLimits) async throws -> MCPRPCResponse {
        try Task.checkCancellation()
        if isClosedValue() { throw CancellationError() }
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params], options: [])
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        let (bytes, response) = try await Self.withTimeout(seconds: timeout) { [session, request] in
            try await session.bytes(for: request)
        }
        guard let http = response as? HTTPURLResponse else { throw AgentError.processFailure("MCP HTTP 返回了无效响应。") }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw AgentError.authentication("远程 MCP OAuth 认证尚未实现。官方客户端的登录状态不会自动认证这个 URL；请使用已配置认证的远程地址，或使用本地 stdio 桥接。AgentDesk 不读取或保存 OAuth/API 凭据。")
        }
        guard (200..<300).contains(http.statusCode) else { throw AgentError.processFailure("MCP HTTP 返回状态码 \(http.statusCode)。") }
        let responseObject = try await Self.readResponse(id: id, bytes: bytes, timeout: timeout, maxOutputBytes: limits.maxOutputBytes)
        let remoteSession = http.value(forHTTPHeaderField: "Mcp-Session-Id")
        return MCPRPCResponse(result: responseObject["result"] as? [String: Any], error: responseObject["error"] as? [String: Any], sessionID: remoteSession)
    }

    func notify(method: String, params: [String: Any], sessionID: String?) async throws {
        // Streamable HTTP notifications use the same POST transport. A 202 or
        // empty response is valid; errors still reach the user.
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": method, "params": params])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        let notificationRequest = request
        let notificationSession = session
        let (_, response) = try await Self.withTimeout(seconds: timeout) { try await notificationSession.data(for: notificationRequest) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw AgentError.processFailure("MCP HTTP 通知发送失败。") }
    }

    func close() { lock.lock(); closed = true; lock.unlock(); session.invalidateAndCancel() }

    private func isClosedValue() -> Bool { lock.lock(); defer { lock.unlock() }; return closed }

    private static func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw AgentError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw AgentError.processFailure("MCP HTTP 没有返回响应。") }
            return result
        }
    }

    private static func readResponse(id: Int, bytes: URLSession.AsyncBytes, timeout: TimeInterval, maxOutputBytes: Int) async throws -> [String: Any] {
        try await withThrowingTaskGroup(of: [String: Any].self) { group in
            group.addTask {
                var parser = MCPHTTPResponseParser(id: id, maxOutputBytes: maxOutputBytes)
                var lineBuffer = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    lineBuffer.append(byte)
                    if lineBuffer.count > maxOutputBytes { throw AgentError.protocolFailure("MCP HTTP 输出超过安全上限。") }
                    guard byte == 10 else { continue }
                    if let response = try parser.consume(line: String(decoding: lineBuffer.dropLast(), as: UTF8.self)) { return response }
                    lineBuffer.removeAll(keepingCapacity: true)
                }
                if !lineBuffer.isEmpty, let response = try parser.consume(line: String(decoding: lineBuffer, as: UTF8.self)) { return response }
                if let response = try parser.finish() { return response }
                throw AgentError.processFailure("MCP HTTP 在响应前关闭。")
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw AgentError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw AgentError.processFailure("MCP HTTP 没有返回响应。") }
            return result
        }
    }

}

/// Incremental parser used by Streamable HTTP and exposed internally for
/// deterministic tests without binding a socket. It returns as soon as a
/// matching JSON-RPC response is seen; an open SSE stream therefore cannot
/// hold a completed call open.
struct MCPHTTPResponseParser {
    private let id: Int
    private let maxOutputBytes: Int
    private var total = 0
    private var eventData: [String] = []
    private var plainJSON = Data()

    init(id: Int, maxOutputBytes: Int) { self.id = id; self.maxOutputBytes = maxOutputBytes }

    mutating func consume(line: String) throws -> [String: Any]? {
        total += line.utf8.count + 1
        if total > maxOutputBytes { throw AgentError.protocolFailure("MCP HTTP 输出超过安全上限。") }
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            defer { eventData.removeAll(keepingCapacity: true) }
            if let response = try parseEventData() { return response }
            return try parsePlainJSON()
        }
        if value.hasPrefix(":") { return nil }
        if value.hasPrefix("data:") {
            eventData.append(String(value.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            let payload = eventData.joined(separator: "\n")
            if let data = payload.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                eventData.removeAll(keepingCapacity: true)
                return try validate(object)
            }
            return nil
        }
        plainJSON.append(contentsOf: value.utf8)
        plainJSON.append(10)
        return try parsePlainJSON()
    }

    mutating func finish() throws -> [String: Any]? {
        defer { eventData.removeAll(keepingCapacity: true) }
        if let response = try parseEventData() { return response }
        return try parsePlainJSON()
    }

    private func parseEventData() throws -> [String: Any]? {
        guard !eventData.isEmpty else { return nil }
        let payload = eventData.joined(separator: "\n")
        guard let data = payload.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return try validate(object)
    }

    private mutating func parsePlainJSON() throws -> [String: Any]? {
        guard !plainJSON.isEmpty else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: plainJSON) as? [String: Any] else { return nil }
        plainJSON.removeAll(keepingCapacity: true)
        return try validate(object)
    }

    private func validate(_ object: [String: Any]) throws -> [String: Any]? {
        if let method = object["method"] as? String, object["id"] != nil {
            throw AgentError.protocolFailure("MCP 服务器发送了 AgentDesk 不支持的服务端请求（\(method)）。")
        }
        guard let responseID = object["id"] else { return nil }
        let matches: Bool
        if let value = responseID as? Int { matches = value == id }
        else if let value = responseID as? NSNumber { matches = value.intValue == id }
        else { matches = false }
        return matches ? object : nil
    }
}
