import Foundation

public struct CodexInspection: Sendable, Equatable {
    public let isChatGPT: Bool
    public let modelIDs: [String]
    public let defaultModelID: String?
    public let supportedReasoningEfforts: [String: [String]]
    public let defaultReasoningEfforts: [String: String]
    /// Subscription windows from `account/rateLimits/read`; nil if unavailable.
    public let quota: ProviderQuota?

    public init(
        isChatGPT: Bool,
        modelIDs: [String],
        defaultModelID: String?,
        supportedReasoningEfforts: [String: [String]] = [:],
        defaultReasoningEfforts: [String: String] = [:],
        quota: ProviderQuota? = nil
    ) {
        self.isChatGPT = isChatGPT
        self.modelIDs = modelIDs
        self.defaultModelID = defaultModelID
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEfforts = defaultReasoningEfforts
        self.quota = quota
    }
}

/// A small adapter around the official Codex app-server JSON-RPC protocol.
///
/// Authentication is deliberately owned by Codex. This adapter never accepts
/// an API key, reads an auth file, or starts a login flow. It only reuses the
/// existing managed ChatGPT account configured for the local Codex install.
public final class CodexBackend: AgentBackend, @unchecked Sendable {
    public static let defaultExecutableURL = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")

    private let executableURL: URL
    private let clientVersion: String
    private let processFactory: @Sendable (URL, [String], URL, [String: String]) -> CLIProcess

    public init(
        executableURL: URL = CodexBackend.defaultExecutableURL,
        clientVersion: String = "0.1.0",
        processFactory: @escaping @Sendable (URL, [String], URL, [String: String]) -> CLIProcess = { executable, arguments, directory, environment in
            CLIProcess(executable: executable, arguments: arguments, directory: directory, environment: environment)
        }
    ) {
        self.executableURL = executableURL
        self.clientVersion = clientVersion
        self.processFactory = processFactory
    }

    /// Read the local Codex account type and model catalog without starting a
    /// thread or a model turn. This is suitable for the app's provider setup
    /// screen and never returns account identifiers or credential material.
    public static func inspect(
        executableURL: URL = CodexBackend.defaultExecutableURL,
        directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) async throws -> CodexInspection {
        guard executableURL.isFileURL, FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw AgentError.unavailable("找不到可执行的 Codex：\(executableURL.path)")
        }
        let disabledMCPNames = try await discoverConfiguredMCPNames(executableURL: executableURL, directory: directory)
        try ensureMCPNamesCanBeDisabled(disabledMCPNames)
        let process = CLIProcess(
            executable: executableURL,
            arguments: try appServerArguments(disabling: disabledMCPNames),
            directory: directory,
            environment: RuntimeEnvironment.subscriptionOnly()
        )
        try process.start()
        defer { process.terminate() }

        var requestID = 0
        var nextStep = InspectionStep.initialize
        var isChatGPT = false
        var modelIDs: [String] = []
        var defaultModelID: String?
        var supportedReasoningEfforts: [String: [String]] = [:]
        var defaultReasoningEfforts: [String: String] = [:]
        var catalogPages = 0

        func send(_ method: String, params: [String: Any]) throws {
            requestID += 1
            try process.writeJSON(["method": method, "id": requestID, "params": params])
        }
        func requestMatches(_ object: [String: Any]) -> Bool {
            guard let id = object["id"] else { return false }
            return Self.rpcID(id) == String(requestID)
        }

        try send("initialize", params: [
            "clientInfo": ["name": "agentdesk", "title": "AgentDesk", "version": "0.1.0"],
            "capabilities": ["experimentalApi": false]
        ])

        for await event in process.events {
            try Task.checkCancellation()
            guard case .stdoutLine(let line) = event, let object = Self.parseObject(line) else {
                if case .exited(let code) = event, code != 0 {
                    throw AgentError.processFailure("Codex 进程已退出（状态码 \(code)）。")
                }
                continue
            }
            if case .rateLimits = nextStep, object["error"] != nil, requestMatches(object) {
                // Usage windows are optional; the account and model check still stands.
                return CodexInspection(isChatGPT: isChatGPT, modelIDs: modelIDs, defaultModelID: defaultModelID,
                                       supportedReasoningEfforts: supportedReasoningEfforts, defaultReasoningEfforts: defaultReasoningEfforts)
            }
            if let error = object["error"] as? [String: Any] {
                throw AgentError.protocolFailure("Codex 检查失败：\(Self.redactedMessage(error))")
            }
            guard object["result"] != nil, requestMatches(object) else { continue }
            let result = object["result"] as? [String: Any] ?? [:]
            switch nextStep {
            case .initialize:
                try process.writeJSON(["method": "initialized", "params": [:]])
                requestID += 1
                try process.writeJSON(["method": "account/read", "id": requestID, "params": ["refreshToken": false]])
                nextStep = .account
            case .account:
                let account = result["account"] as? [String: Any]
                isChatGPT = (account?["type"] as? String) == "chatgpt" || Self.findString(named: "authMode", in: result) == "chatgpt"
                requestID += 1
                try process.writeJSON(["method": "model/list", "id": requestID, "params": [:]])
                nextStep = .models
            case .models:
                catalogPages += 1
                let data = result["data"] as? [[String: Any]] ?? []
                for model in data {
                    guard let rawID = model["id"] as? String else { continue }
                    let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !id.isEmpty else { continue }
                    if !modelIDs.contains(id) { modelIDs.append(id) }
                    if (model["isDefault"] as? Bool) == true { defaultModelID = id }
                    if let effort = model["defaultReasoningEffort"] as? String, !effort.isEmpty {
                        defaultReasoningEfforts[id] = effort
                    }
                    let efforts = Self.reasoningEfforts(from: model["supportedReasoningEfforts"])
                    if !efforts.isEmpty { supportedReasoningEfforts[id] = efforts }
                }
                if let cursor = result["nextCursor"] as? String, !cursor.isEmpty {
                    guard catalogPages < 4 else { throw AgentError.protocolFailure("Codex 模型目录分页超过上限。") }
                    try send("model/list", params: ["cursor": cursor, "limit": 100, "includeHidden": false])
                    continue
                }
                // Reading usage windows is an account query, not a model turn.
                try send("account/rateLimits/read", params: ["excludeResetCreditDetails": true])
                nextStep = .rateLimits
            case .rateLimits:
                return CodexInspection(
                    isChatGPT: isChatGPT,
                    modelIDs: modelIDs,
                    defaultModelID: defaultModelID,
                    supportedReasoningEfforts: supportedReasoningEfforts,
                    defaultReasoningEfforts: defaultReasoningEfforts,
                    quota: Self.quota(fromRateLimits: result["rateLimits"])
                )
            }
        }
        throw AgentError.processFailure("Codex 在完成连接检查前退出。")
    }

    private enum InspectionStep { case initialize, account, models, rateLimits }

    /// `rateLimits` snapshot → windows. `usedPercent` is already 0–100.
    static func quota(fromRateLimits value: Any?) -> ProviderQuota? {
        guard let snapshot = value as? [String: Any] else { return nil }
        let windows = ["primary", "secondary"].compactMap { key -> QuotaWindow? in
            guard let w = snapshot[key] as? [String: Any], let used = (w["usedPercent"] as? NSNumber)?.doubleValue else { return nil }
            let reset = (w["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return QuotaWindow(label: ProviderQuota.windowLabel(minutes: (w["windowDurationMins"] as? NSNumber)?.intValue), usedPercent: used, resetsAt: reset)
        }
        return windows.isEmpty ? nil : ProviderQuota(windows: windows, status: snapshot["rateLimitReachedType"] as? String)
    }

    public func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    try await self.run(request, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: AgentError.processFailure("Codex 会话已取消。"))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func run(_ request: AgentRequest, continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation) async throws {
        guard executableURL.isFileURL, FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw AgentError.unavailable("找不到可执行的 Codex：\(executableURL.path)")
        }
        guard FileManager.default.fileExists(atPath: request.workingDirectory.path) else {
            throw AgentError.unavailable("工作目录不存在：\(request.workingDirectory.path)")
        }

        var environment = RuntimeEnvironment.subscriptionOnly()
        for server in request.mcpServers { environment.merge(server.environment) { $1 } }
        let disabledMCPNames = try await Self.discoverConfiguredMCPNames(executableURL: executableURL, directory: request.workingDirectory)
        try Self.ensureMCPNamesCanBeDisabled(disabledMCPNames)
        let mcpServers = Self.codexMCPServers(request.mcpServers, avoiding: disabledMCPNames)
        let process = processFactory(executableURL, try Self.appServerArguments(disabling: disabledMCPNames, providing: mcpServers), request.workingDirectory, environment)
        try process.start()
        defer { process.terminate() }

        var requestID = 0
        var expected: [String: RPCStep] = [:]
        var threadID: String?
        var turnCompleted = false
        var modelDefaults: [String: String] = [:]
        var modelEfforts: [String: [String]] = [:]
        var modelModalities: [String: [String]] = [:]
        var catalogDefaultModelID: String?
        var selectedReasoningEffort: String?

        func nextID() -> Int { requestID += 1; return requestID }
        func send(_ method: String, params: [String: Any], step: RPCStep? = nil) throws -> String {
            let id = nextID()
            let key = String(id)
            if let step { expected[key] = step }
            try process.writeJSON(["method": method, "id": id, "params": params])
            return key
        }
        func notify(_ method: String, params: [String: Any]) throws {
            try process.writeJSON(["method": method, "params": params])
        }

        _ = try send("initialize", params: [
            "clientInfo": ["name": "agentdesk", "title": "AgentDesk", "version": clientVersion],
            "capabilities": ["experimentalApi": false]
        ], step: .initialize)

        for await event in process.events {
            try Task.checkCancellation()
            switch event {
            case .stderrLine:
                // stderr is diagnostic output. Do not surface it as assistant text.
                continue
            case .exited(let code):
                if turnCompleted { return }
                throw AgentError.processFailure("Codex 进程已退出（状态码 \(code)）。")
            case .stdoutLine(let line):
                guard let object = Self.parseObject(line) else { continue }
                if let error = object["error"] as? [String: Any] {
                    throw AgentError.protocolFailure("Codex 请求失败：\(Self.redactedMessage(error))")
                }

                if let method = object["method"] as? String, object["id"] != nil {
                    try answerServerRequest(method: method, id: object["id"]!, params: object["params"] as? [String: Any] ?? [:],
                                            allowedMCPServers: Set(mcpServers.map(\.name)), process: process)
                    continue
                }

                if let method = object["method"] as? String {
                    try handleNotification(method: method, params: object["params"] as? [String: Any] ?? [:], threadID: &threadID, turnCompleted: &turnCompleted, continuation: continuation)
                    if turnCompleted { return }
                    continue
                }

                guard let id = object["id"] else { continue }
                let key = Self.rpcID(id)
                guard let step = expected.removeValue(forKey: key) else { continue }
                let result = object["result"] as? [String: Any] ?? [:]

                switch step {
                case .initialize:
                    try notify("initialized", params: [:])
                    _ = try send("account/read", params: ["refreshToken": false], step: .account)
                case .account:
                    // Current app-server account/read returns {account:{type:"chatgpt", ...}}
                    // rather than an authMode field. Keep the old fallback for
                    // older servers, but never treat an absent value as logged in.
                    let account = result["account"] as? [String: Any]
                    let accountType = account?["type"] as? String ?? Self.findString(named: "authMode", in: result)
                    guard accountType == "chatgpt" else {
                        throw AgentError.authentication("Codex 当前不是 ChatGPT 订阅登录（accountType=\(accountType ?? "unknown")）。请在 Codex 中完成登录后重试。")
                    }
                    // Resolve the account/model-specific effort before opening
                    // or resuming the thread. This lets an explicit "official
                    // default" reset a previous thread-level override.
                    _ = try send("model/list", params: ["limit": 100, "includeHidden": false], step: .models(page: 0))
                case .models(let page):
                    let data = result["data"] as? [[String: Any]] ?? []
                    for model in data {
                        guard let rawID = model["id"] as? String else { continue }
                        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !id.isEmpty else { continue }
                        if (model["isDefault"] as? Bool) == true { catalogDefaultModelID = id }
                        if let effort = model["defaultReasoningEffort"] as? String, !effort.isEmpty { modelDefaults[id] = effort }
                        let efforts = Self.reasoningEfforts(from: model["supportedReasoningEfforts"])
                        if !efforts.isEmpty { modelEfforts[id] = efforts }
                        if let modalities = model["inputModalities"] as? [String] { modelModalities[id] = modalities }
                    }
                    if let cursor = result["nextCursor"] as? String, !cursor.isEmpty {
                        guard page < 3 else {
                            throw AgentError.protocolFailure("Codex model/list 分页超过安全上限。")
                        }
                        _ = try send("model/list", params: ["cursor": cursor, "limit": 100, "includeHidden": false], step: .models(page: page + 1))
                        continue
                    }
                    let requestedModelID = request.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
                    let selectedModelID = requestedModelID.isEmpty ? catalogDefaultModelID : requestedModelID
                    if !request.images.isEmpty, let selectedModelID, let modalities = modelModalities[selectedModelID],
                       !modalities.contains(where: { $0.caseInsensitiveCompare("image") == .orderedSame }) {
                        throw AgentError.unavailable("Codex 模型 \(selectedModelID) 不支持图片输入。请在模型列表中选择支持 image 的模型。")
                    }
                    let requestedEffort = request.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let requestedEffort, !requestedEffort.isEmpty {
                        if let selectedModelID, let supported = modelEfforts[selectedModelID], !supported.contains(requestedEffort) {
                            throw AgentError.protocolFailure("Codex 模型 \(selectedModelID) 不支持 reasoning effort \(requestedEffort)。")
                        }
                        selectedReasoningEffort = requestedEffort
                    } else if let selectedModelID, let officialDefault = modelDefaults[selectedModelID] {
                        // Sending the discovered default explicitly is
                        // intentional: app-server thread settings persist, so
                        // omitting this field on resume would retain a prior
                        // high/low override instead of resetting to default.
                        selectedReasoningEffort = officialDefault
                    }
                    if let existing = request.remoteSessionID, !existing.isEmpty {
                        var params: [String: Any] = [
                            "threadId": existing,
                            "cwd": request.workingDirectory.path,
                            "approvalPolicy": "never",
                            "sandbox": "read-only",
                            // Restated on resume: the thread keeps what it
                            // started with, and the opened servers can change.
                            "baseInstructions": Self.baseInstructions(mcpServers: mcpServers)
                        ]
                        if !request.modelID.isEmpty { params["model"] = request.modelID }
                        _ = try send("thread/resume", params: params, step: .thread)
                    } else if let fork = request.forkFrom {
                        // Native fork: the new thread carries the parent's turns
                        // through `lastTurnId` (inclusive), or all of them.
                        var params: [String: Any] = [
                            "threadId": fork.remoteSessionID,
                            "cwd": request.workingDirectory.path,
                            "approvalPolicy": "never",
                            "sandbox": "read-only",
                            "baseInstructions": Self.baseInstructions(mcpServers: mcpServers),
                            "excludeTurns": true
                        ]
                        if let turn = fork.throughTurnID { params["lastTurnId"] = turn }
                        if !request.modelID.isEmpty { params["model"] = request.modelID }
                        _ = try send("thread/fork", params: params, step: .thread)
                    } else {
                        var params: [String: Any] = [
                            "cwd": request.workingDirectory.path,
                            "approvalPolicy": "never",
                            "sandbox": "read-only",
                            "baseInstructions": Self.baseInstructions(mcpServers: mcpServers)
                        ]
                        if !request.modelID.isEmpty { params["model"] = request.modelID }
                        _ = try send("thread/start", params: params, step: .thread)
                    }
                case .thread:
                    if let thread = result["thread"] as? [String: Any] {
                        threadID = thread["id"] as? String
                    }
                    threadID = threadID ?? (result["threadId"] as? String)
                    guard let threadID else { throw AgentError.protocolFailure("Codex 没有返回 thread ID。") }
                    if request.remoteSessionID == nil, let fork = request.forkFrom, threadID == fork.remoteSessionID {
                        throw AgentError.protocolFailure("Codex 没有创建新的分叉线程，已停止，避免改动父节点的会话。")
                    }
                    continuation.yield(.sessionID(threadID))
                    let imageInput = try MultimodalInputSupport.codexInputs(prompt: request.prompt, images: request.images)
                    var params: [String: Any] = [
                        "threadId": threadID,
                        "input": imageInput,
                        "cwd": request.workingDirectory.path,
                        "approvalPolicy": "never",
                        "sandboxPolicy": ["type": "readOnly", "networkAccess": false]
                    ]
                    if !request.modelID.isEmpty { params["model"] = request.modelID }
                    // App-server documents `effort` as a per-turn override.
                    // Preserve the exact selected value so unsupported values
                    // are reported by Codex instead of silently downgraded.
                    if let effort = selectedReasoningEffort, !effort.isEmpty { params["effort"] = effort }
                    _ = try send("turn/start", params: params, step: .turn)
                    continuation.yield(.status("Codex 正在生成回复…"))
                case .turn:
                    // The acknowledgement carries the turn ID (a later fork
                    // point); streamed notifications follow.
                    if let turn = result["turn"] as? [String: Any], let id = turn["id"] as? String, !id.isEmpty {
                        continuation.yield(.turnID(id))
                    }
                    continue
                }
            }
        }
        // A clean stdout close without turn/completed is not a successful
        // response. Do not let the UI show a completed assistant message.
        if !turnCompleted {
            throw AgentError.processFailure("Codex 在完成回合前退出。")
        }
    }

    private enum RPCStep { case initialize, account, models(page: Int), thread, turn }

    /// Keep this process intentionally text-only for the first MVP. These are
    /// documented Codex feature/config overrides. MCP is disabled at the
    /// feature layer rather than by naming a user's configured servers.
    private static func discoverConfiguredMCPNames(executableURL: URL, directory: URL) async throws -> [String] {
        let process = CLIProcess(
            executable: executableURL,
            arguments: try Self.appServerArguments(),
            directory: directory,
            environment: RuntimeEnvironment.subscriptionOnly()
        )
        try process.start()
        defer { process.terminate() }

        var requestID = 1
        var waitingForConfig = false
        try process.writeJSON([
            "method": "initialize",
            "id": requestID,
            "params": [
                "clientInfo": ["name": "agentdesk", "title": "AgentDesk", "version": "0.1.0"],
                "capabilities": ["experimentalApi": false]
            ]
        ])
        for await event in process.events {
            try Task.checkCancellation()
            guard case .stdoutLine(let line) = event, let object = Self.parseObject(line) else {
                if case .exited(let code) = event, code != 0 {
                    throw AgentError.processFailure("Codex discovery 进程已退出（状态码 \(code)）。")
                }
                continue
            }
            if let error = object["error"] as? [String: Any] {
                throw AgentError.protocolFailure("Codex 配置读取失败：\(Self.redactedMessage(error))")
            }
            guard let id = object["id"], Self.rpcID(id) == String(requestID), let result = object["result"] as? [String: Any] else { continue }
            if !waitingForConfig {
                try process.writeJSON(["method": "initialized", "params": [:]])
                requestID = 2
                try process.writeJSON(["method": "config/read", "id": requestID, "params": ["includeLayers": false, "cwd": directory.path]])
                waitingForConfig = true
                continue
            }
            guard let config = result["config"] as? [String: Any], let servers = config["mcp_servers"] as? [String: Any] else { return [] }
            return servers.keys.sorted()
        }
        throw AgentError.processFailure("Codex discovery 未返回有效配置。")
    }

    /// A thread told to use no tools never calls an opened MCP server, even
    /// with it loaded (checked live with codex-cli 0.165).
    static func baseInstructions(mcpServers: [AgentMCPServer]) -> String {
        guard !mcpServers.isEmpty else { return "Use no tools in this session. Answer with text only." }
        let names = mcpServers.map(\.name).joined(separator: ", ")
        return "The only tools in this session are those of the MCP servers \(names), which the user opened to you. Call them whenever they help answer; do not try any other tool. Otherwise answer with text."
    }

    /// The user's own Codex MCP servers stay disabled; ours get a name that
    /// does not merge with one of theirs.
    static func codexMCPServers(_ servers: [AgentMCPServer], avoiding configured: [String]) -> [AgentMCPServer] {
        servers.map { server in
            var server = server
            if configured.contains(server.name) { server.name = "agentdesk_\(server.name)" }
            return server
        }
    }

    static func appServerArguments(disabling names: [String] = [], providing servers: [AgentMCPServer] = []) throws -> [String] {
        var args = ["app-server"]
        let overrides = [
            "model_provider=\"openai\"",
            "features.shell_tool=false",
            "features.unified_exec=false",
            "features.unified_exec_tty=false",
            // Even the advertised ultra effort must remain a single member
            // turn; provider-side delegation must not bypass the room budget.
            "features.multi_agent=false",
            "features.multi_agent_v2=false",
            "features.computer_use=false",
            "features.browser_use=false",
            "features.mcp_2026_07_28=false",
            "features.codex_apps_mcp_2026_07_28=false",
            "features.enable_mcp_apps=false",
            "features.apps=false",
            // Memories would carry context from the user's other Codex work
            // into an isolated conversation, and its consolidation thread
            // runs in the same app-server (it was seen stalling turns).
            "features.memories=false",
            "approval_policy=\"never\"",
            "sandbox_mode=\"read-only\""
        ]
        for override in overrides { args.append(contentsOf: ["-c", override]) }
        for name in names {
            // Codex's dotted -c parser treats quoted map keys as a new
            // incomplete server (and then reports "invalid transport").
            // Only emit names that are safe as a single dotted key; refusing
            // an otherwise unrepresentable name is safer than leaving a live
            // MCP server enabled.
            guard name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
                continue
            }
            args.append(contentsOf: ["-c", "mcp_servers.\(name).enabled=false"])
        }
        for server in servers {
            let key = "mcp_servers.\(server.name)"
            switch server.transport {
            case .stdio(let command, let arguments):
                args += ["-c", "\(key).command=\(try tomlValue(command))", "-c", "\(key).args=\(try tomlValue(arguments))"]
                if !server.environment.isEmpty { args += ["-c", "\(key).env_vars=\(try tomlValue(server.environment.keys.sorted()))"] }
            case .streamableHTTP(let url):
                args += ["-c", "\(key).url=\(try tomlValue(url))"]
            }
            args += ["-c", "\(key).enabled=true"]
        }
        return args
    }

    /// JSON strings and string arrays are valid TOML values.
    private static func tomlValue(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
    }

    private static func ensureMCPNamesCanBeDisabled(_ names: [String]) throws {
        for name in names where name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) == nil {
            throw AgentError.unavailable("Codex MCP server 名称无法安全转换为临时禁用配置：\(SafeText.redact(name))")
        }
    }

    private func handleNotification(
        method: String,
        params: [String: Any],
        threadID: inout String?,
        turnCompleted: inout Bool,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) throws {
        switch method {
        case "thread/started":
            if let thread = params["thread"] as? [String: Any], let id = Self.findString(named: "id", in: thread) {
                threadID = id
                continuation.yield(.sessionID(id))
            }
        case "item/agentMessage/delta":
            if let delta = params["delta"] as? String, !delta.isEmpty { continuation.yield(.textDelta(delta)) }
        case "turn/completed":
            let turn = params["turn"] as? [String: Any] ?? [:]
            let status = Self.findString(named: "status", in: turn) ?? "completed"
            guard status == "completed" else {
                throw AgentError.processFailure("Codex 回合结束状态：\(status)。")
            }
            turnCompleted = true
            continuation.yield(.completed)
        case "thread/tokenUsage/updated":
            // `last` is the latest request: its total is what the context now holds.
            if let usage = params["tokenUsage"] as? [String: Any], let last = usage["last"] as? [String: Any],
               let total = (last["totalTokens"] as? NSNumber)?.intValue, total > 0 {
                continuation.yield(.contextUsage(ContextUsage(usedTokens: total, windowTokens: (usage["modelContextWindow"] as? NSNumber)?.intValue)))
            }
        case "account/rateLimits/updated":
            if let quota = Self.quota(fromRateLimits: params["rateLimits"]) { continuation.yield(.quota(quota)) }
        case "item/started":
            if let item = params["item"] as? [String: Any], item["type"] as? String == "mcpToolCall",
               let server = item["server"] as? String, let tool = item["tool"] as? String {
                continuation.yield(.status("正在调用 MCP 工具 \(server) · \(tool)…"))
            }
        case "item/completed", "turn/started", "thread/status/changed":
            break
        default:
            // Ignore forward-compatible notifications. Unknown data is never rendered as model text.
            break
        }
    }

    /// Everything is declined, except the approval a server the user opened
    /// to the model asks for before one of its tool calls.
    private func answerServerRequest(method: String, id: Any, params: [String: Any], allowedMCPServers: Set<String>, process: CLIProcess) throws {
        let response: [String: Any]
        switch method {
        case "mcpServer/elicitation/request" where Self.isToolCallApproval(params, allowed: allowedMCPServers):
            response = ["id": id, "result": ["action": "accept", "content": [String: Any](), "_meta": NSNull()]]
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            response = ["id": id, "result": ["decision": "decline"]]
        case "execCommandApproval", "applyPatchApproval":
            response = ["id": id, "result": ["decision": ["denied": ["rejection": "AgentDesk 不允许执行工具或文件修改。"]]]]
        case "item/permissions/requestApproval":
            response = ["id": id, "result": ["permissions": [:], "scope": "turn"]]
        case "item/tool/requestUserInput":
            response = ["id": id, "result": ["answers": [:]]]
        case "mcpServer/elicitation/request":
            response = ["id": id, "result": ["action": "decline"]]
        case "item/tool/call":
            response = ["id": id, "result": ["success": false, "contentItems": [["type": "inputText", "text": "Tool use is disabled in AgentDesk."]]]]
        default:
            response = ["id": id, "error": ["code": -32000, "message": "AgentDesk declined unsupported server request."]]
        }
        try process.writeJSON(response)
    }

    /// Codex asks through MCP elicitation before a tool call that is not
    /// marked read-only (`_meta.codex_approval_kind` "mcp_tool_call…").
    static func isToolCallApproval(_ params: [String: Any], allowed: Set<String>) -> Bool {
        guard let server = params["serverName"] as? String, allowed.contains(server) else { return false }
        return ((params["_meta"] as? [String: Any])?["codex_approval_kind"] as? String)?.hasPrefix("mcp_tool_call") == true
    }

    private static func parseObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func rpcID(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return String(describing: value)
    }

    /// Parse the current object form returned by `model/list` and the older
    /// string form defensively. Preserve the server's order and remove dupes.
    private static func reasoningEfforts(from value: Any?) -> [String] {
        guard let value else { return [] }
        var values: [String] = []
        if let objects = value as? [[String: Any]] {
            for object in objects {
                if let effort = object["reasoningEffort"] as? String { values.append(effort) }
            }
        } else if let strings = value as? [String] {
            values = strings
        }
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }

    private static func findString(named name: String, in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            if let value = dictionary[name] as? String { return value }
            for value in dictionary.values {
                if let found = Self.findString(named: name, in: value) { return found }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = Self.findString(named: name, in: value) { return found }
            }
        }
        return nil
    }

    private static func redactedMessage(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? "unknown error"
        return SafeText.redact(text)
    }
}
