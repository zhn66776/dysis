import AppKit
import Combine
import Foundation
import AgentDeskCore

@MainActor
final class AppModel: ObservableObject {
    @Published var sessions: [ChatSession] = []
    @Published var selectedSessionID: UUID?
    @Published var configuration = AppConfiguration()
    @Published var runningSessionIDs: Set<UUID> = []
    @Published var statusByProvider: [ProviderID: String] = [:]
    @Published var availableModels: [ProviderID: [String]] = [.claude: ModelCatalog.claudeIDs]
    @Published var codexEfforts: [String: [String]] = [:]
    @Published var codexDefaultEfforts: [String: String] = [:]
    @Published var isChecking: Set<ProviderID> = []
    @Published var activeStatus: [UUID: String] = [:]
    @Published var errorMessage: String?
    /// Latest subscription usage per provider, kept for this launch only.
    @Published var quotas: [ProviderID: ProviderQuota] = [:]
    private var quotaReadAt: [ProviderID: Date] = [:]
    // A presentation mode for this app launch, not an execution permission.
    @Published var developerModeEnabled = false

    private var store: LocalStore?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var storageReadable = true
    private var lastStreamSave: [UUID: Date] = [:]
    let plaza: PlazaModel
    let attachmentDrafts: AttachmentDrafts
    let folderAccess: FolderAccessCenter
    let approvals: ApprovalCenter
    var dataRoot: URL { plaza.root }

    var selectedSession: ChatSession? { sessions.first { $0.id == selectedSessionID } }

    init(root: URL? = nil) {
        let resolvedRoot = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AgentDesk", isDirectory: true)
        plaza = PlazaModel(root: resolvedRoot)
        attachmentDrafts = AttachmentDrafts(root: resolvedRoot)
        folderAccess = FolderAccessCenter(root: resolvedRoot)
        approvals = ApprovalCenter(exchange: folderAccess.exchange, token: folderAccess.token)
        configuration = Self.defaults()
        do {
            let store = try LocalStore(root: root)
            self.store = store
            sessions = try store.loadSessions()
            if var saved = try store.loadConfiguration() {
                let defaults = Self.defaults()
                for provider in ProviderID.allCases where saved[provider].executablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    saved[provider].executablePath = defaults[provider].executablePath
                }
                configuration = saved
            }
            selectedSessionID = sessions.first?.id
        } catch {
            storageReadable = false
            errorMessage = "无法读取本地记录，原文件已保留。\(error.localizedDescription)"
        }
        folderAccess.describe = { [weak self] id in
            self?.sessions.first { $0.id == id }.map { ($0.title, $0.provider) }
        }
    }

    static func defaults() -> AppConfiguration {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return AppConfiguration(providers: [
            .claude: .init(executablePath: home + "/.local/bin/claude", modelID: "sonnet"),
            .codex: .init(executablePath: CodexBackend.defaultExecutableURL.path),
            .grok: .init(executablePath: home + "/.local/bin/agent", modelID: "grok-4.7-medium"),
            .gemini: .init(executablePath: home + "/.local/bin/agent", modelID: "gemini-4-argon-medium")
        ])
    }

    @discardableResult
    func newSession(provider: ProviderID, copyingSettingsFrom source: ChatSession? = nil, workingDirectory: URL? = nil) -> UUID? {
        guard storageReadable, let store else { return nil }
        do {
            let id = UUID()
            let directory = try workingDirectory ?? store.makeWorkspace(for: id)
            let session = ChatSession(id: id, provider: provider, modelID: source?.modelID ?? configuration[provider].modelID, workingDirectory: directory.path, reasoningEffort: source == nil ? configuration[provider].reasoningEffort : source?.reasoningEffort)
            sessions.insert(session, at: 0)
            selectedSessionID = id
            persist()
            return id
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    func renameSession(_ id: UUID, title: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].title = String(title.prefix(100))
        persist()
    }

    func setSessionEffort(_ id: UUID, effort: String?) {
        guard storageReadable, !runningSessionIDs.contains(id), let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].reasoningEffort = effort
        persist()
    }

    func setSessionEffortVariant(_ id: UUID, modelID: String) {
        guard storageReadable, !runningSessionIDs.contains(id), let i = sessions.firstIndex(where: { $0.id == id }), [.grok, .gemini].contains(sessions[i].provider) else { return }
        sessions[i].modelID = modelID
        sessions[i].reasoningEffort = nil
        persist()
    }

    /// Next message uses this model. Cursor model IDs carry their effort, so
    /// the separate effort is cleared there; Codex drops an effort the new
    /// model does not list.
    func setSessionModel(_ id: UUID, modelID: String) {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard storageReadable, !trimmed.isEmpty, !runningSessionIDs.contains(id), let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].modelID = trimmed
        switch sessions[i].provider {
        case .grok, .gemini: sessions[i].reasoningEffort = nil
        case .codex:
            if let effort = sessions[i].reasoningEffort, let supported = codexEfforts[trimmed], !supported.contains(effort) { sessions[i].reasoningEffort = nil }
        case .claude: break
        }
        persist()
    }

    /// Codex usage windows via an account query (no model turn), at most once a minute.
    func refreshQuota(_ provider: ProviderID) {
        guard provider == .codex, let store, Date().timeIntervalSince(quotaReadAt[provider] ?? .distantPast) > 60 else { return }
        quotaReadAt[provider] = Date()
        let executable = URL(fileURLWithPath: NSString(string: configuration[.codex].executablePath).expandingTildeInPath)
        Task {
            guard let info = try? await CodexBackend.inspect(executableURL: executable, directory: store.root) else { return }
            if let quota = info.quota { quotas[.codex] = quota }
            if !info.modelIDs.isEmpty { availableModels[.codex] = info.modelIDs }
            if !info.supportedReasoningEfforts.isEmpty { codexEfforts = info.supportedReasoningEfforts; codexDefaultEfforts = info.defaultReasoningEfforts }
        }
    }

    func deleteSession(_ id: UUID) {
        stop(sessionID: id)
        sessions.removeAll { $0.id == id }
        folderAccess.forget(session: id)
        approvals.forget(session: id)
        if selectedSessionID == id { selectedSessionID = sessions.first?.id }
        persist()
    }

    func saveConfiguration() {
        guard storageReadable else { return }
        do { try store?.saveConfiguration(configuration) }
        catch { errorMessage = "设置未能保存：\(error.localizedDescription)" }
    }

    /// MCP servers the user opened to the model (MCP 工具 → 让模型自己调用),
    /// read on every send so a change applies to the next message.
    /// AgentDesk's files server joins them when folder access is on, or to
    /// serve Claude Code's approval tool for a project folder (`approvals`).
    private func modelMCPServers(sessionID: UUID, approvals folder: String? = nil) -> [AgentMCPServer] {
        let url = dataRoot.appendingPathComponent("mcp-servers.json")
        let configs = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([MCPServerConfiguration].self, from: $0) } ?? []
        var servers = AgentMCPServer.forModel(configs)
        if configuration.folderAccess || folder != nil,
           let files = folderAccess.server(for: sessionID, dataRoot: dataRoot, files: configuration.folderAccess, approvals: folder) { servers.append(files) }
        return servers
    }

    func send(_ text: String) {
        guard let id = selectedSessionID else { return }
        send(text, to: id)
    }

    /// Shared by sending and the read-only canvas preview, including document text.
    func canvasInput(prompt: String, sessionID: UUID, context: CanvasPromptContext) -> String {
        let withContext = CanvasContextBuilder.compose(userText: prompt, context: context)
        return AttachmentPromptBuilder.compose(userText: withContext, attachments: attachmentDrafts.files[sessionID, default: []], root: dataRoot, maxCharacters: context.isEmpty ? 48_000 : 56_000)
    }

    /// Starts one provider turn. `context` is the canvas material (replayed
    /// branch history, upstream outputs, source nodes) placed before the typed text, and its
    /// `fork` makes a not-yet-started session fork natively from its parent.
    /// Returns whether the turn started.
    @discardableResult
    /// `project` is the board's folder: once trusted, the provider works there
    /// at the board's permission level, or the node's lower `nodeLevel`.
    func send(_ text: String, to id: UUID, context: CanvasPromptContext = .init(), project: CanvasProject? = nil, nodeLevel: PermissionLevel? = nil) -> Bool {
        guard storageReadable,
              let index = sessions.firstIndex(where: { $0.id == id }), !runningSessionIDs.contains(id) else { return false }
        guard !attachmentDrafts.importing.contains(id) else { return false }
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = attachmentDrafts.files[id, default: []]
        guard !typed.isEmpty || !attachments.isEmpty else { return false }
        guard typed.count <= 24_000 else { errorMessage = "单条消息请控制在 24,000 字以内。"; return false }
        let prompt = typed.isEmpty ? "请分析我附加的文件。" : typed
        let provider = sessions[index].provider
        let config = configuration[provider]
        let executable = URL(fileURLWithPath: NSString(string: config.executablePath).expandingTildeInPath)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            errorMessage = "找不到 \(provider.runtimeName)。请在设置中检查安装路径。"
            return false
        }
        // Model selection belongs to the conversation created in newSession.
        // Changing the default must not silently change an existing chat.
        if provider != .codex && sessions[index].modelID.isEmpty {
            errorMessage = "请先在设置中为 \(provider.name) 发现并选择模型。"
            return false
        }
        do { try AttachmentStore.validateForTextPrompt(attachments) }
        catch { errorMessage = error.localizedDescription; return false }
        if attachments.contains(where: \.isImage), provider == .grok || provider == .gemini {
            errorMessage = "当前 Cursor 连接暂不支持图片输入。请选择 Claude Code 或 Codex，或移除图片后发送文档文字。"
            return false
        }
        // Source-node images were already routed and capped by CanvasContextBuilder (none for Cursor).
        let images = (attachments.filter(\.isImage) + context.images).map { AgentImageInput(localURL: $0.modelURL(root: dataRoot) ?? $0.storedURL(root: dataRoot), mediaType: $0.modelMediaType ?? $0.mediaType) }
        let input = canvasInput(prompt: prompt, sessionID: id, context: context)
        if sessions[index].messages.isEmpty {
            sessions[index].title = String(prompt.replacingOccurrences(of: "\n", with: " ").prefix(32))
        }
        let assistantID = UUID()
        sessions[index].messages.append(ChatMessage(role: .user, text: prompt, attachments: attachments.isEmpty ? nil : attachments, contextSources: context.isEmpty && context.fork == nil ? nil : context.sourceLabels))
        sessions[index].messages.append(ChatMessage(id: assistantID, role: .assistant, text: "", state: .streaming))
        sessions[index].updatedAt = Date()
        let session = sessions[index]
        let mode = HarnessMode.resolve(project: project, nodeLevel: nodeLevel, workingDirectory: session.workingDirectory)
        let level = mode.level ?? .auto
        // Claude Code asks through the files helper; Codex asks in process.
        let approvalFolder = provider == .claude && mode != .chat && level != .auto ? session.workingDirectory : nil
        let request = AgentRequest(localSessionID: id, remoteSessionID: session.remoteSessionID, prompt: input, workingDirectory: URL(fileURLWithPath: session.workingDirectory), modelID: session.modelID, executableURL: executable, reasoningEffort: session.reasoningEffort, images: images, forkFrom: session.remoteSessionID == nil ? context.fork : nil, mcpServers: modelMCPServers(sessionID: id, approvals: approvalFolder),
                                   projectAccess: mode != .chat,
                                   userFolder: !URL(fileURLWithPath: session.workingDirectory).path.hasPrefix(dataRoot.path + "/"),
                                   permissionLevel: level, approver: approvals.approver)
        let backend: any AgentBackend
        switch provider {
        case .claude: backend = ClaudeBackend()
        case .codex: backend = CodexBackend(executableURL: executable)
        case .grok, .gemini: backend = CursorBackend()
        }
        runningSessionIDs.insert(id)
        attachmentDrafts.clear(id)
        activeStatus[id] = "正在连接 \(provider.runtimeName)…"
        persist()
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            var completed = false
            do {
                for try await event in backend.stream(request) {
                    try Task.checkCancellation()
                    guard let i = self.sessions.firstIndex(where: { $0.id == id }),
                          let m = self.sessions[i].messages.firstIndex(where: { $0.id == assistantID }) else { break }
                    switch event {
                    case .sessionID(let remoteID):
                        self.sessions[i].remoteSessionID = remoteID
                        self.persist()
                    case .textDelta(let text): self.sessions[i].messages[m].text += text
                    case .replaceText(let text): self.sessions[i].messages[m].text = text
                    case .status(let text): self.activeStatus[id] = text
                    case .actualModels(let ids): self.sessions[i].messages[m].actualModelIDs = ids
                    case .turnID(let turn): self.sessions[i].messages[m].providerTurnID = turn
                    case .contextUsage(let usage): self.sessions[i].contextUsage = usage
                    case .quota(let quota): self.quotas[provider] = quota
                    case .completed:
                        completed = true
                        self.sessions[i].messages[m].state = .complete
                    }
                    if Date().timeIntervalSince(self.lastStreamSave[id] ?? .distantPast) > 0.5 {
                        self.lastStreamSave[id] = Date(); self.persist()
                    }
                }
                if !completed && !Task.isCancelled { throw AgentError.protocolFailure("连接提前结束，尚未收到完整回复。") }
            } catch {
                if let i = self.sessions.firstIndex(where: { $0.id == id }), let m = self.sessions[i].messages.firstIndex(where: { $0.id == assistantID }) {
                    let stopped = Task.isCancelled || error is CancellationError
                    self.sessions[i].messages[m].state = stopped ? .cancelled : .failed
                    if !stopped {
                        let message = SafeText.redact(error.localizedDescription)
                        self.errorMessage = message
                        if self.sessions[i].messages[m].text.isEmpty { self.sessions[i].messages[m].text = message }
                    }
                }
            }
            self.approvals.cancel(session: id)
            self.runningSessionIDs.remove(id)
            self.activeStatus.removeValue(forKey: id)
            self.tasks.removeValue(forKey: id)
            self.lastStreamSave.removeValue(forKey: id)
            self.persist()
        }
        return true
    }

    func stop(sessionID: UUID) {
        tasks[sessionID]?.cancel()
        approvals.cancel(session: sessionID)
        if let i = sessions.firstIndex(where: { $0.id == sessionID }) {
            for j in sessions[i].messages.indices where sessions[i].messages[j].state == .streaming {
                sessions[i].messages[j].state = .cancelled
            }
        }
        activeStatus[sessionID] = "正在停止…"
        persist()
    }

    func shutdown() {
        attachmentDrafts.shutdown()
        SpeechRecognitionController.stopAll()
        plaza.shutdown()
        for id in Array(tasks.keys) { stop(sessionID: id) }
        CLIProcess.terminateAllOwned()
        persist()
        saveConfiguration()
    }

    func checkProvider(_ provider: ProviderID) async {
        guard !isChecking.contains(provider), let store else { return }
        isChecking.insert(provider); statusByProvider[provider] = "Checking…"
        defer { isChecking.remove(provider) }
        do {
            let executable = URL(fileURLWithPath: NSString(string: configuration[provider].executablePath).expandingTildeInPath)
            switch provider {
            case .claude:
                let result = try await CommandCapture.run(executable: executable, arguments: ["--safe-mode", "--restricted", "auth", "status"], directory: store.root)
                let object = (try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8))) as? [String: Any]
                guard result.code == 0, object?["authMethod"] as? String == "claude.ai" else { throw AgentError.authentication("请先使用 Claude 订阅登录。") }
                statusByProvider[provider] = "Connected · \((object?["subscriptionType"] as? String ?? "Subscription").capitalized)"
                availableModels[.claude] = ModelCatalog.claudeIDs
            case .codex:
                let info = try await CodexBackend.inspect(executableURL: executable, directory: store.root)
                guard info.isChatGPT else { throw AgentError.authentication("请先在 Codex 中使用 ChatGPT 登录。") }
                statusByProvider[provider] = "Connected · ChatGPT"
                availableModels[provider] = info.modelIDs
                codexEfforts = info.supportedReasoningEfforts
                codexDefaultEfforts = info.defaultReasoningEfforts
                if let quota = info.quota { quotas[.codex] = quota; quotaReadAt[.codex] = Date() }
                if configuration[provider].modelID.isEmpty, let model = info.defaultModelID { configuration[provider].modelID = model }
            case .grok, .gemini:
                let result = try await CommandCapture.run(executable: executable, arguments: ["status"], directory: store.root)
                let output = result.stdout + result.stderr
                guard result.code == 0, output.localizedCaseInsensitiveContains("logged in"), !output.localizedCaseInsensitiveContains("not logged in") else { throw AgentError.authentication("请先运行 Cursor 官方登录命令。") }
                statusByProvider[.grok] = "Connected · Cursor"
                statusByProvider[.gemini] = "Connected · Cursor"
            }
            saveConfiguration()
        } catch {
            statusByProvider[provider] = "Not connected"
            errorMessage = SafeText.redact(error.localizedDescription)
        }
    }

    func loadModels(_ provider: ProviderID) async {
        if provider == .codex || provider == .claude { await checkProvider(provider); return }
        guard !isChecking.contains(provider), let store else { return }
        isChecking.insert(provider)
        defer { isChecking.remove(provider) }
        do {
            let executable = URL(fileURLWithPath: NSString(string: configuration[provider].executablePath).expandingTildeInPath)
            let result = try await CommandCapture.run(executable: executable, arguments: ["--list-models"], directory: store.root, timeout: 45)
            guard result.code == 0 else { throw AgentError.unavailable("无法获取 Cursor 模型列表，请先检查官方登录。") }
            for family in [ProviderID.grok, .gemini] {
                let ids = ModelCatalog.cursorIDs(from: result.stdout, family: family.rawValue)
                availableModels[family] = ids
                if configuration[family].modelID.isEmpty, let first = ids.first { configuration[family].modelID = first }
            }
            if availableModels[provider, default: []].isEmpty { throw AgentError.unavailable("当前 Cursor 列表没有提供 \(provider.name)，请检查套餐或稍后重试。") }
            saveConfiguration()
        } catch { errorMessage = SafeText.redact(error.localizedDescription) }
    }

    private func persist() {
        guard storageReadable else { return }
        do { try store?.saveSessions(sessions) }
        catch { errorMessage = "本地记录保存失败：\(error.localizedDescription)" }
    }
}
