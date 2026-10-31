import Combine
import Foundation
import AgentDeskCore

/// Owns the canvas layout (`canvases.json`). Conversations themselves stay in
/// AppModel; a node only points at a session.
@MainActor
final class CanvasModel: ObservableObject {
    @Published private(set) var library = CanvasLibrary()
    /// Set after create/branch so the page opens the new node's panel.
    @Published var focusNodeID: UUID?
    @Published var fitBoardID: UUID?
    private var histories: [UUID: CanvasEditHistory] = [:]
    /// Text to put into a session's composer once (merge templates).
    @Published var composerFill: (sessionID: UUID, text: String)?
    /// A downstream re-run in progress: nodes in order and the current index.
    @Published private(set) var chain: (boardID: UUID, order: [UUID], index: Int)?
    private var chainTask: Task<Void, Never>?
    /// Files nodes whose files are being imported.
    @Published private(set) var importingSources: Set<UUID> = []
    static let maxChainCalls = CanvasChainRunner.maxCalls

    let app: AppModel
    private let store: CanvasStore
    private var writable = true
    private var sessionsWatch: AnyCancellable?
    private var runningWatch: AnyCancellable?
    /// Sessions whose current turn is a native fork: session → (board, inherit edge).
    private var pendingForks: [UUID: (board: UUID, edge: UUID)] = [:]

    init(app: AppModel) {
        self.app = app
        store = CanvasStore(root: app.dataRoot)
        do {
            library = try store.load() ?? CanvasLibrary.seeded(from: app.sessions)
        } catch {
            // Keep the unreadable file for recovery and do not overwrite it.
            writable = false
            library = CanvasLibrary.seeded(from: app.sessions)
            app.errorMessage = "无法读取画布布局，原文件已保留，本次改动不会保存。\(error.localizedDescription)"
        }
        if library.reconcile(sessionIDs: app.sessions.map(\.id)) || !FileManager.default.fileExists(atPath: store.url.path) { persist() }
        // Sessions created or deleted elsewhere (classic window, menu) follow
        // onto the canvas. Deferred so our own create/branch places the node first.
        sessionsWatch = app.$sessions
            .map { $0.map(\.id) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ids in
                guard let self else { return }
                let before = Dictionary(uniqueKeysWithValues: self.library.boards.map { ($0.id, $0.nodes.map(\.id)) })
                if self.library.reconcile(sessionIDs: ids) {
                    let unchanged = Set(self.library.boards.filter { before[$0.id] == $0.nodes.map(\.id) }.map(\.id))
                    self.histories = self.histories.filter { unchanged.contains($0.key) }
                    self.persist()
                }
            }
        runningWatch = app.$runningSessionIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in self?.settleForks(running: running) }
    }

    /// A fork that ended without an official session ID did not take; the
    /// edge falls back to replay so the next send is not the same failure.
    private func settleForks(running: Set<UUID>) {
        for (sessionID, pending) in pendingForks where !running.contains(sessionID) {
            pendingForks[sessionID] = nil
            guard app.sessions.first(where: { $0.id == sessionID })?.remoteSessionID == nil else { continue }
            update(pending.board) { board in
                if let i = board.edges.firstIndex(where: { $0.id == pending.edge }) { board.edges[i].nativeForkFailed = true }
            }
        }
    }

    var currentBoard: CanvasBoard? { library.boards.first { $0.id == library.selectedBoardID } }
    var sessionsByID: [UUID: ChatSession] { Dictionary(uniqueKeysWithValues: app.sessions.map { ($0.id, $0) }) }

    private func update(_ boardID: UUID, undoLabel: String? = nil, _ change: (inout CanvasBoard) throws -> Void) rethrows {
        guard let i = library.boards.firstIndex(where: { $0.id == boardID }) else { return }
        let before = library.boards[i]
        try change(&library.boards[i])
        guard before != library.boards[i] else { return }
        if before.nodes.map(\.id) != library.boards[i].nodes.map(\.id) { histories[boardID] = nil }
        else if let label = undoLabel { histories[boardID, default: CanvasEditHistory()].record(before: before, after: library.boards[i], label: label) }
        library.boards[i].updatedAt = Date()
        persist()
    }

    // MARK: Boards

    /// Asks whether the board is a project folder (new or existing) or a plain board.
    func createBoard() {
        Task { @MainActor in
            guard let choice = await ProjectDialogs.newBoard() else { return }
            let board: CanvasBoard
            do {
                switch choice {
                case .plain: board = CanvasBoard(title: "新画布")
                case .newFolder(let name):
                    let folder = try CanvasProject.makeFolder(title: name)
                    board = CanvasBoard(title: folder.lastPathComponent, project: CanvasProject(path: folder.path))
                case .existing(let folder):
                    board = CanvasBoard(title: folder.lastPathComponent, project: CanvasProject(path: folder.path))
                }
            } catch { app.errorMessage = "无法新建项目文件夹：\(error.localizedDescription)"; return }
            library.boards.insert(board, at: 0)
            library.selectedBoardID = board.id
            persist()
        }
    }

    /// Links a folder to an existing board; conversations already on it keep their own folders.
    func linkFolder(_ boardID: UUID) {
        guard let folder = ProjectDialogs.chooseFolder() else { return }
        update(boardID) { $0.project = CanvasProject(path: folder.path) }
    }

    /// A newly trusted project starts at 询问; one trusted before levels
    /// existed keeps no level and so stays automatic.
    func setTrust(_ boardID: UUID, trusted: Bool) {
        update(boardID) { board in
            if trusted, board.project?.trusted != true { board.project?.permissionLevel = .ask }
            board.project?.trusted = trusted
        }
    }

    func setPermissionLevel(_ boardID: UUID, level: PermissionLevel) {
        update(boardID) { if $0.project?.isTrusted == true { $0.project?.permissionLevel = level } }
    }

    /// A node can only go below its board's level; nil follows the board.
    func setNodePermissionLevel(boardID: UUID, nodeID: UUID, level: PermissionLevel?) {
        update(boardID) { board in
            guard let i = board.nodes.firstIndex(where: { $0.id == nodeID }), board.nodes[i].source == nil else { return }
            if let level, let boardLevel = board.project?.level, level < boardLevel { board.nodes[i].permissionLevel = level }
            else { board.nodes[i].permissionLevel = nil }
        }
    }

    /// The trust question comes once per project, before its first conversation.
    private func askTrustIfNeeded(_ boardID: UUID, then work: @escaping () -> Void) {
        guard let project = library.boards.first(where: { $0.id == boardID })?.project, project.trusted == nil else { work(); return }
        Task { @MainActor in
            let trusted = await ProjectDialogs.askTrust(project)
            self.setTrust(boardID, trusted: trusted)
            work()
        }
    }

    /// A conversation for this board, working in its project folder when it has one.
    private func newSession(on boardID: UUID, provider: ProviderID, copying source: ChatSession? = nil) -> UUID? {
        let folder = library.boards.first(where: { $0.id == boardID })?.project.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
        if let folder, !FileManager.default.fileExists(atPath: folder.path) {
            app.errorMessage = "项目文件夹不存在：\(folder.path)。请在侧栏重新选择文件夹。"
            return nil
        }
        return app.newSession(provider: provider, copyingSettingsFrom: source, workingDirectory: folder)
    }

    func selectBoard(_ id: UUID) {
        guard library.boards.contains(where: { $0.id == id }) else { return }
        library.selectedBoardID = id
        persist()
    }

    func renameBoard(_ id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.title = String(trimmed.prefix(100)) }
    }

    /// Deletes the board and its conversations' local records. Official
    /// provider history and workspace files are not touched.
    func deleteBoard(_ id: UUID) {
        guard let board = library.boards.first(where: { $0.id == id }) else { return }
        library.boards.removeAll { $0.id == id }
        histories[id] = nil
        if library.boards.isEmpty { library.boards = [CanvasBoard(title: "我的画布")] }
        if library.selectedBoardID == id { library.selectedBoardID = library.boards[0].id }
        persist()
        removeLocalRecords(of: board.nodes)
    }

    /// Conversations behind chat nodes, and the copied files of files nodes.
    private func removeLocalRecords(of nodes: [CanvasNode]) {
        for node in nodes where !node.isSource { app.deleteSession(node.sessionID) }
        let files = nodes.flatMap { $0.source?.files ?? [] }
        guard !files.isEmpty, let store = try? AttachmentStore(root: app.dataRoot) else { return }
        for file in files { try? store.remove(file) }
    }

    // MARK: Nodes and edges

    func createNode(boardID: UUID, provider: ProviderID, at point: CanvasPoint, connectFrom: UUID?) {
        askTrustIfNeeded(boardID) { [weak self] in self?.placeNode(boardID: boardID, provider: provider, at: point, connectFrom: connectFrom) }
    }

    private func placeNode(boardID: UUID, provider: ProviderID, at point: CanvasPoint, connectFrom: UUID?) {
        guard currentBoard?.id == boardID, let sessionID = newSession(on: boardID, provider: provider) else { return }
        let node = CanvasNode(sessionID: sessionID, position: point)
        update(boardID) { board in
            board.nodes.append(node)
            if let source = connectFrom { _ = try? board.connect(source: source, target: node.id) }
        }
        focusNodeID = node.id
    }

    func moveNodes(boardID: UUID, positions: [UUID: CanvasPoint]) {
        update(boardID, undoLabel: "移动节点") { board in
            for i in board.nodes.indices { if let p = positions[board.nodes[i].id], p.x.isFinite, p.y.isFinite { board.nodes[i].position = p } }
        }
    }

    func deleteNodes(boardID: UUID, nodeIDs: Set<UUID>) {
        guard let board = library.boards.first(where: { $0.id == boardID }) else { return }
        let removed = board.nodes.filter { nodeIDs.contains($0.id) }
        update(boardID) { $0.removeNodes(nodeIDs) }
        removeLocalRecords(of: removed)
    }

    func connect(boardID: UUID, source: UUID, target: UUID) {
        do { try update(boardID, undoLabel: "添加连线") { try $0.connect(source: source, target: target) } }
        catch { app.errorMessage = error.localizedDescription }
    }

    func deleteEdges(boardID: UUID, edgeIDs: Set<UUID>) {
        update(boardID, undoLabel: "移除连线") { $0.edges.removeAll { edgeIDs.contains($0.id) } }
    }

    func historyStatus(boardID: UUID) -> CanvasHistoryStatus { histories[boardID]?.status ?? .init() }

    func undo(boardID: UUID, redo: Bool = false) {
        guard let i = library.boards.firstIndex(where: { $0.id == boardID }), var history = histories[boardID] else { return }
        let changed = redo ? history.redo(&library.boards[i]) : history.undo(&library.boards[i])
        guard changed else { return }
        histories[boardID] = history
        library.boards[i].updatedAt = Date()
        persist()
    }

    func layout(boardID: UUID, sizes: [CanvasNodeSize]) {
        update(boardID, undoLabel: "自动布局") { board in
            let positions = CanvasLayout.positions(board: board, sizes: sizes)
            for i in board.nodes.indices { if let p = positions[board.nodes[i].id] { board.nodes[i].position = p } }
        }
        fitBoardID = boardID
    }

    func group(boardID: UUID, nodeIDs: Set<UUID>, into groupID: UUID?) {
        update(boardID, undoLabel: groupID == nil ? "创建分组" : "调整分组") { board in
            board.group(nodeIDs: nodeIDs, into: groupID)
        }
        if groupID == nil { fitBoardID = boardID }
    }

    func renameGroup(boardID: UUID, groupID: UUID, title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        update(boardID, undoLabel: "分组改名") { board in
            if let i = board.groups.firstIndex(where: { $0.id == groupID }) { board.groups[i].title = String(title.prefix(100)) }
        }
    }

    func dissolveGroup(boardID: UUID, groupID: UUID) {
        update(boardID, undoLabel: "解散分组") { $0.groups.removeAll { $0.id == groupID } }
    }

    /// New node of the same provider that inherits the parent's history up to
    /// `messageID`, placed in the first free spot to the right of the parent.
    func branch(boardID: UUID, nodeID: UUID, messageID: UUID) {
        guard let board = library.boards.first(where: { $0.id == boardID }), let parent = board.node(nodeID),
              let parentSession = sessionsByID[parent.sessionID],
              parentSession.messages.contains(where: { $0.id == messageID }),
              let sessionID = newSession(on: boardID, provider: parentSession.provider, copying: parentSession) else { return }
        app.renameSession(sessionID, title: "分支 · \(parentSession.title)")
        let node = CanvasNode(sessionID: sessionID, position: board.freePosition(near: CanvasPoint(x: parent.position.x + 440, y: parent.position.y)))
        update(boardID) { board in
            board.nodes.append(node)
            _ = try? board.connect(source: nodeID, target: node.id, kind: .inherit, sourceMessageID: messageID)
        }
        focusNodeID = node.id
    }

    /// A new conversation with one fixed reply as input; no ancestor history and no send.
    func quote(boardID: UUID, nodeID: UUID, messageID: UUID) {
        guard let board = library.boards.first(where: { $0.id == boardID }), let parent = board.node(nodeID),
              let source = sessionsByID[parent.sessionID],
              source.messages.contains(where: { $0.id == messageID && $0.role == .assistant && $0.state == .complete && !$0.text.isEmpty }),
              let sessionID = newSession(on: boardID, provider: source.provider, copying: source) else { return }
        app.renameSession(sessionID, title: "引用 · \(source.title)")
        let node = CanvasNode(sessionID: sessionID, position: board.freePosition(near: .init(x: parent.position.x + 440, y: parent.position.y)))
        update(boardID) { board in
            board.nodes.append(node)
            _ = try? board.connect(source: parent.id, target: node.id, kind: .data, sourceMessageID: messageID)
        }
        focusNodeID = node.id
    }

    /// A merge node to the right of the sources, fed by one data edge each,
    /// with the template's prompt in its composer. Nothing is sent.
    func merge(boardID: UUID, nodeIDs: [UUID], provider: ProviderID, template: CanvasMergeTemplate) {
        guard let board = library.boards.first(where: { $0.id == boardID }) else { return }
        // Files and MCP nodes are not conversations to compare; they stay upstream.
        let sources = nodeIDs.compactMap { board.node($0) }.filter { !$0.isSource }
        guard sources.count >= 2 else { app.errorMessage = "至少选择两个节点才能合流。"; return }
        guard sources.count <= 8 else { app.errorMessage = "一次最多合并 8 个节点。"; return }
        guard let sessionID = newSession(on: boardID, provider: provider) else { return }
        app.renameSession(sessionID, title: "合流 · \(template.title)")
        let x = (sources.map(\.position.x).max() ?? 0) + 340
        let y = sources.map(\.position.y).reduce(0, +) / Double(sources.count)
        let node = CanvasNode(sessionID: sessionID, position: board.freePosition(near: CanvasPoint(x: x, y: y)), merge: template)
        update(boardID) { board in
            board.nodes.append(node)
            for source in sources { _ = try? board.connect(source: source.id, target: node.id) }
        }
        focusNodeID = node.id
        composerFill = (sessionID, template.prompt(sourceCount: sources.count))
    }

    func hasRun(_ node: CanvasNode) -> Bool { CanvasContextBuilder.hasRun(sessionsByID[node.sessionID]) }

    /// Nodes a downstream re-run from `nodeID` would call, in order.
    func downstreamOrder(boardID: UUID, from nodeID: UUID) -> [UUID] {
        library.boards.first { $0.id == boardID }?.downstreamOrder(from: nodeID, include: hasRun) ?? []
    }

    /// Re-runs `order` one node at a time; each waits for the previous reply
    /// and the run stops at the first node that does not complete.
    func runChain(boardID: UUID, order: [UUID]) {
        guard chain == nil else { app.errorMessage = "已有一组节点在重跑。"; return }
        switch CanvasChainRunner.refusal(count: order.count) {
        case .empty?: return
        case .overCap?: app.errorMessage = "一次最多重跑 \(Self.maxChainCalls) 个节点，请从更下游的节点分段运行。"; return
        default: break
        }
        chain = (boardID, order, 0)
        // Session behind each node the runner reached, for waiting, stopping and messages.
        var sessionOf: [UUID: UUID] = [:]
        let runner = CanvasChainRunner(
            step: { [weak self] index in self?.chain?.index = index },
            start: { [weak self] nodeID in
                guard let self, let board = self.library.boards.first(where: { $0.id == boardID }), let node = board.node(nodeID),
                      let session = self.sessionsByID[node.sessionID],
                      let prompt = CanvasContextBuilder.rerunPrompt(for: session) else { return .skipped }
                sessionOf[nodeID] = session.id
                return self.send(boardID: boardID, nodeID: nodeID, text: prompt) ? .started : .failed
            },
            wait: { [weak self] nodeID in
                guard let sessionID = sessionOf[nodeID] else { return .incomplete }
                while let self, self.app.runningSessionIDs.contains(sessionID) {
                    if Task.isCancelled { return .cancelled }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                let last = self?.sessionsByID[sessionID]?.messages.last { $0.role == .assistant }
                return last?.state == .complete ? .complete : .incomplete
            },
            stop: { [weak self] nodeID in
                if let sessionID = sessionOf[nodeID] { self?.app.stop(sessionID: sessionID) }
            })
        chainTask = Task { [weak self] in
            let outcome = await runner.run(order)
            guard let self else { return }
            self.chain = nil
            self.chainTask = nil
            let title: (Int) -> String = { index in
                sessionOf[order[index]].flatMap { self.sessionsByID[$0]?.title } ?? ""
            }
            switch outcome {
            case .notStarted(let index):
                if self.app.errorMessage == nil { self.app.errorMessage = "「\(title(index))」没有开始，后面的节点已停止。" }
            case .incomplete(let index):
                if self.app.errorMessage == nil { self.app.errorMessage = "「\(title(index))」没有完成，后面的节点已停止。" }
            case .finished, .empty, .overCap, .cancelled: break
            }
        }
    }

    func stopChain() {
        chainTask?.cancel()
    }

    // MARK: Source nodes

    private func source(_ boardID: UUID, _ nodeID: UUID) -> CanvasSource? {
        library.boards.first { $0.id == boardID }?.node(nodeID)?.source
    }

    private func updateSource(_ boardID: UUID, _ nodeID: UUID, _ change: (inout CanvasSource) -> Void) {
        update(boardID) { board in
            if let i = board.nodes.firstIndex(where: { $0.id == nodeID }), board.nodes[i].source != nil { change(&board.nodes[i].source!) }
        }
    }

    /// A files node at `point` holding `urls`, or files picked in the native
    /// panel. The node appears at once and is removed again if nothing imports.
    func createFileNode(boardID: UUID, at point: CanvasPoint, urls: [URL]? = nil) {
        guard currentBoard?.id == boardID, let urls = urls ?? AttachmentDrafts.pickFiles(title: "选择放到画布上的文件") else { return }
        let node = CanvasNode.source(.files([]), position: currentBoard?.freePosition(near: point) ?? point)
        update(boardID) { $0.nodes.append(node) }
        focusNodeID = node.id
        importFiles(urls, boardID: boardID, nodeID: node.id, isNew: true)
    }

    func addFiles(boardID: UUID, nodeID: UUID, urls: [URL]? = nil) {
        guard source(boardID, nodeID)?.kind == .files, !importingSources.contains(nodeID),
              let urls = urls ?? AttachmentDrafts.pickFiles(title: "添加到文件节点") else { return }
        importFiles(urls, boardID: boardID, nodeID: nodeID, isNew: false)
    }

    /// Same import as message attachments (copy, downscale, extract text),
    /// plus the same limits for the whole node: 6 files, 4 images.
    /// A new node (`isNew`) whose import fails is removed again.
    private func importFiles(_ urls: [URL], boardID: UUID, nodeID: UUID, isNew: Bool) {
        let existing = source(boardID, nodeID)?.files ?? []
        let limits = AttachmentImportLimits.default
        if existing.count + urls.count > limits.maxFilesPerImport {
            app.errorMessage = "一个文件节点最多放 \(limits.maxFilesPerImport) 个文件。"
            if isNew { dropIfEmpty(boardID, nodeID) }
            return
        }
        importingSources.insert(nodeID)
        Task { [weak self] in
            guard let self else { return }
            do {
                let store = try AttachmentStore(root: self.app.dataRoot)
                let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
                defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
                let imported = try await store.importFiles(from: urls)
                do {
                    // Downstream prompts need text; a scanned PDF would arrive empty.
                    try AttachmentStore.validateForTextPrompt(imported)
                    guard let current = self.source(boardID, nodeID) else { throw CancellationError() }
                    try CanvasSource.checkFileLimits(existing: current.files, adding: imported, limits: limits)
                    self.updateSource(boardID, nodeID) { $0.setFiles(current.files + imported) }
                } catch {
                    for file in imported { try? store.remove(file) }
                    throw error
                }
            } catch {
                if !(error is CancellationError) { self.app.errorMessage = error.localizedDescription }
            }
            self.importingSources.remove(nodeID)
            if isNew { self.dropIfEmpty(boardID, nodeID) }
        }
    }

    private func dropIfEmpty(_ boardID: UUID, _ nodeID: UUID) {
        guard let source = source(boardID, nodeID), source.kind == .files, source.files.isEmpty else { return }
        update(boardID) { $0.removeNodes([nodeID]) }
    }

    func removeFile(boardID: UUID, nodeID: UUID, fileID: UUID) {
        guard !importingSources.contains(nodeID), let files = source(boardID, nodeID)?.files, let file = files.first(where: { $0.id == fileID }) else { return }
        updateSource(boardID, nodeID) { $0.setFiles(files.filter { $0.id != fileID }) }
        if let store = try? AttachmentStore(root: app.dataRoot) { try? store.remove(file) }
    }

    /// An empty title goes back to the automatic one.
    func renameSource(boardID: UUID, nodeID: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        updateSource(boardID, nodeID) { $0.customTitle = trimmed.isEmpty ? nil : String(trimmed.prefix(100)) }
    }

    /// An MCP result from the workbench, as a new node on the current board.
    func createMCPNode(result: CanvasMCPResult, at point: CanvasPoint) {
        guard let board = currentBoard else { return }
        let node = CanvasNode.source(.mcp(result), position: board.freePosition(near: point))
        update(board.id) { $0.nodes.append(node) }
        focusNodeID = node.id
    }

    /// The tool was run again from the workbench: a new version for downstream nodes.
    func updateMCPNode(boardID: UUID, nodeID: UUID, result: CanvasMCPResult) {
        guard source(boardID, nodeID)?.kind == .mcp else { return }
        updateSource(boardID, nodeID) { $0.setMCP(result) }
    }

    func saveViewport(boardID: UUID, viewport: CanvasViewport) {
        update(boardID) { $0.viewport = viewport }
    }

    // MARK: Sending

    @discardableResult
    func send(boardID: UUID, nodeID: UUID, text: String) -> Bool {
        guard let board = library.boards.first(where: { $0.id == boardID }), let node = board.node(nodeID) else { return false }
        // Images already in the composer count against the per-turn image cap.
        let draftImages = app.attachmentDrafts.files[node.sessionID, default: []].filter(\.isImage).count
        let context = CanvasContextBuilder.context(board: board, nodeID: nodeID, sessions: sessionsByID,
                                                   imageBudget: CanvasContextBuilder.maxImagesPerTurn - draftImages)
        guard app.send(text, to: node.sessionID, context: context, project: board.project, nodeLevel: node.permissionLevel) else { return false }
        if context.fork != nil, let edge = board.inheritEdge(into: nodeID) { pendingForks[node.sessionID] = (boardID, edge.id) }
        // Each upstream reply and source version is delivered once; a new one makes the edge pending again.
        let delivered = context.deliveries
        if !delivered.isEmpty {
            update(boardID) { board in
                for i in board.edges.indices { if let m = delivered[board.edges[i].id] { board.edges[i].lastDeliveredMessageID = m } }
            }
        }
        return true
    }

    private func persist() {
        guard writable else { return }
        do { try store.save(library) }
        catch { app.errorMessage = "画布布局保存失败：\(error.localizedDescription)" }
    }
}
