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
    /// Where node worktrees go (HARNESS.md H2); `--worktrees-dir` moves it for test runs.
    let worktreeRoot: URL
    /// Sessions whose running turn may write in the project.
    private var writingSessions: Set<UUID> = []
    /// Nodes with a git operation in progress (merge, combine).
    @Published private(set) var gitBusy: Set<UUID> = []
    /// Project folder → whether it is in a git work tree; read again when a board is selected.
    private var gitFolders: [String: Bool] = [:]
    /// Writing turns with a checkpoint: session → where, which reply, which commit (H3).
    private var checkpointedTurns: [UUID: (board: UUID, node: UUID, message: UUID, checkpoint: String)] = [:]

    init(app: AppModel, worktreeRoot: URL = NodeWorktree.defaultRoot) {
        self.app = app
        self.worktreeRoot = worktreeRoot
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
            .sink { [weak self] running in
                self?.settleForks(running: running)
                self?.settleTurns(running: running)
                self?.writingSessions.formIntersection(running)
            }
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

    /// A finished writing turn gets AgentDesk's own diff (worktree against
    /// its checkpoint), for every provider; the node's branch total follows.
    private func settleTurns(running: Set<UUID>) {
        for (sessionID, turn) in checkpointedTurns where !running.contains(sessionID) {
            checkpointedTurns[sessionID] = nil
            guard let worktree = board(turn.board)?.node(turn.node)?.worktree else { continue }
            Task {
                guard let diff = try? await git({ try ProjectGit.diff(worktree, since: turn.checkpoint) }) else { return }
                app.setTurnDiff(sessionID: sessionID, messageID: turn.message, diff: diff)
                await refreshChanges(boardID: turn.board, nodeID: turn.node)
            }
        }
    }

    /// "改了 N 个文件 +a −b" on the node card: its branch since the cut point.
    func refreshChanges(boardID: UUID, nodeID: UUID) async {
        guard let worktree = board(boardID)?.node(nodeID)?.worktree, worktree.exists else { return }
        let stat = try? await git { try ProjectGit.diffStat(worktree) }
        update(boardID) { board in
            if let i = board.nodes.firstIndex(where: { $0.id == nodeID }) { board.nodes[i].changes = stat.flatMap { $0.isEmpty ? nil : $0 } }
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

    func setTrust(_ boardID: UUID, trusted: Bool) {
        update(boardID) { $0.project?.trusted = trusted }
    }

    /// The trust question comes once per project, before its first
    /// conversation; a trusted folder without git is offered `git init` once.
    private func askTrustIfNeeded(_ boardID: UUID, then work: @escaping () -> Void) {
        guard let project = library.boards.first(where: { $0.id == boardID })?.project,
              project.trusted == nil || needsGitOffer(project) else { work(); return }
        Task { @MainActor in
            if project.trusted == nil {
                let trusted = await ProjectDialogs.askTrust(project)
                self.setTrust(boardID, trusted: trusted)
            }
            if let current = self.board(boardID)?.project, self.needsGitOffer(current) {
                if await ProjectDialogs.askGitInit(current, root: self.worktreeRoot) { await self.initializeGit(boardID) }
                else { self.update(boardID) { $0.project?.gitDeclined = true } }
            }
            work()
        }
    }

    private func board(_ id: UUID) -> CanvasBoard? { library.boards.first { $0.id == id } }

    private func needsGitOffer(_ project: CanvasProject) -> Bool {
        project.isTrusted && project.gitDeclined == nil && FileManager.default.fileExists(atPath: project.path) && !isGit(project.path)
    }

    func isGit(_ path: String) -> Bool {
        if let known = gitFolders[path] { return known }
        let known = ProjectGit.isRepository(URL(fileURLWithPath: path, isDirectory: true))
        gitFolders[path] = known
        return known
    }

    /// `git init` and a first commit, so each node can get a worktree.
    func initializeGit(_ boardID: UUID) async {
        guard let project = board(boardID)?.project, !isGit(project.path) else { return }
        let folder = URL(fileURLWithPath: project.path, isDirectory: true)
        do {
            try await git { try ProjectGit.initialize(folder) }
            gitFolders[project.path] = true
            update(boardID) { $0.project?.gitDeclined = nil }
            app.noticeMessage = "已在「\(project.name)」初始化 git，并把现有文件做了一次初始提交。之后新建的节点各有自己的 worktree。"
        } catch { app.errorMessage = "git 初始化失败：\(error.localizedDescription)" }
    }

    /// Runs git work off the main actor.
    private func git<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }

    /// A conversation for this board, working in its worktree, else in the
    /// project folder when it has one.
    private func newSession(on boardID: UUID, provider: ProviderID, copying source: ChatSession? = nil, worktree: NodeWorktree? = nil) -> UUID? {
        if let worktree {
            return app.newSession(provider: provider, copyingSettingsFrom: source, workingDirectory: URL(fileURLWithPath: worktree.workingDirectory, isDirectory: true))
        }
        let folder = library.boards.first(where: { $0.id == boardID })?.project.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
        if let folder, !FileManager.default.fileExists(atPath: folder.path) {
            app.errorMessage = "项目文件夹不存在：\(folder.path)。请在侧栏重新选择文件夹。"
            return nil
        }
        return app.newSession(provider: provider, copyingSettingsFrom: source, workingDirectory: folder)
    }

    func selectBoard(_ id: UUID) {
        guard library.boards.contains(where: { $0.id == id }) else { return }
        gitFolders = [:]
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
        removeWorktrees(of: board.nodes, deleteBranches: false)
    }

    /// Worktrees of deleted nodes go; uncommitted work is kept as a snapshot
    /// ref, and branches stay unless the user asked to delete them.
    private func removeWorktrees(of nodes: [CanvasNode], deleteBranches: Bool) {
        let worktrees = nodes.compactMap(\.worktree)
        guard !worktrees.isEmpty else { return }
        Task {
            do {
                let kept = try await git { try worktrees.compactMap { try ProjectGit.remove($0, deleteBranch: deleteBranches) } }
                if !kept.isEmpty { app.noticeMessage = "已删除 worktree。未提交的改动存成了快照：\(kept.joined(separator: "、"))" }
            } catch { app.errorMessage = "删除 worktree 失败：\(error.localizedDescription)" }
        }
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
        guard currentBoard?.id == boardID else { return }
        let nodeID = UUID()
        withWorktree(boardID: boardID, nodeID: nodeID) { [weak self] worktree in
            guard let self, let sessionID = self.newSession(on: boardID, provider: provider, worktree: worktree) else { return false }
            var node = CanvasNode(id: nodeID, sessionID: sessionID, position: point)
            node.worktree = worktree
            self.update(boardID) { board in
                board.nodes.append(node)
                if let source = connectFrom { _ = try? board.connect(source: source, target: node.id) }
            }
            self.focusNodeID = node.id
            return true
        }
    }

    /// In a trusted git project the new node gets its own worktree, cut from
    /// `start()` (default: the project HEAD) off the main actor, before
    /// `place` runs; elsewhere `place` runs at once with nil. A worktree whose
    /// node could not be placed is removed again.
    private func withWorktree(boardID: UUID, nodeID: UUID, start: (@Sendable () throws -> String)? = nil, place: @escaping (NodeWorktree?) -> Bool) {
        guard let project = board(boardID)?.project, project.isTrusted, isGit(project.path) else { _ = place(nil); return }
        let folder = URL(fileURLWithPath: project.path, isDirectory: true), root = worktreeRoot
        Task {
            do {
                let worktree = try await git { try ProjectGit.createWorktree(project: folder, board: boardID, node: nodeID, root: root, start: try start?()) }
                if !place(worktree) { _ = try? await git { try ProjectGit.remove(worktree, deleteBranch: true) } }
            } catch { app.errorMessage = "无法为新节点创建 worktree：\(error.localizedDescription)" }
        }
    }

    func moveNodes(boardID: UUID, positions: [UUID: CanvasPoint]) {
        update(boardID, undoLabel: "移动节点") { board in
            for i in board.nodes.indices { if let p = positions[board.nodes[i].id], p.x.isFinite, p.y.isFinite { board.nodes[i].position = p } }
        }
    }

    func deleteNodes(boardID: UUID, nodeIDs: Set<UUID>, deleteBranches: Bool = false) {
        guard let board = library.boards.first(where: { $0.id == boardID }) else { return }
        let removed = board.nodes.filter { nodeIDs.contains($0.id) }
        update(boardID) { $0.removeNodes(nodeIDs) }
        removeLocalRecords(of: removed)
        removeWorktrees(of: removed, deleteBranches: deleteBranches)
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
    /// With worktrees the branch is cut from a snapshot of the parent's
    /// worktree as it is now (`refs/agentdesk/snapshots/<parent>/<child>`);
    /// the parent's branch and files are not touched.
    func branch(boardID: UUID, nodeID: UUID, messageID: UUID) {
        guard let parent = board(boardID)?.node(nodeID), let parentSession = sessionsByID[parent.sessionID],
              parentSession.messages.contains(where: { $0.id == messageID }) else { return }
        let childID = UUID()
        let start: (@Sendable () throws -> String)? = parent.worktree.map { worktree in {
            try ProjectGit.ensure(worktree)
            return try ProjectGit.snapshot(worktree, ref: "refs/agentdesk/snapshots/\(NodeWorktree.shortID(nodeID))/\(NodeWorktree.shortID(childID))",
                                           message: "AgentDesk：分支快照")
        } }
        placeBranch(boardID: boardID, parentID: nodeID, childID: childID, inheritThrough: messageID, title: "分支 · \(parentSession.title)", start: start)
    }

    /// A child of the parent node: same provider and settings, an inherit
    /// edge through `inheritThrough` (none when nil), and a worktree cut from
    /// `start()` when the board uses worktrees.
    private func placeBranch(boardID: UUID, parentID: UUID, childID: UUID, inheritThrough messageID: UUID?, title: String, start: (@Sendable () throws -> String)?) {
        guard let parentSession = board(boardID)?.node(parentID).flatMap({ sessionsByID[$0.sessionID] }) else { return }
        withWorktree(boardID: boardID, nodeID: childID, start: start) { [weak self] worktree in
            guard let self, let board = self.board(boardID), let parent = board.node(parentID),
                  let sessionID = self.newSession(on: boardID, provider: parentSession.provider, copying: parentSession, worktree: worktree) else { return false }
            self.app.renameSession(sessionID, title: title)
            var node = CanvasNode(id: childID, sessionID: sessionID, position: board.freePosition(near: CanvasPoint(x: parent.position.x + 440, y: parent.position.y)))
            node.worktree = worktree
            self.update(boardID) { board in
                board.nodes.append(node)
                if let messageID { _ = try? board.connect(source: parentID, target: node.id, kind: .inherit, sourceMessageID: messageID) }
            }
            self.focusNodeID = node.id
            return true
        }
    }

    // MARK: Undo a turn (H3)

    enum UndoPlan: Equatable {
        /// Codex: files back to the checkpoint and `thread/revert` drops the turn.
        case inPlace
        /// Claude Code and Cursor cannot drop a turn from their session: a new
        /// branch node starts from the checkpoint, inheriting through the reply before.
        case branch(previousReply: UUID?)
    }

    /// How "撤销这一回合" would work for this reply; nil when it cannot.
    func undoPlan(boardID: UUID, nodeID: UUID, messageID: UUID) -> UndoPlan? {
        guard let node = board(boardID)?.node(nodeID), node.worktree != nil, let session = sessionsByID[node.sessionID],
              let index = session.messages.firstIndex(where: { $0.id == messageID }),
              session.messages[index].role == .assistant, session.messages[index].checkpoint != nil else { return nil }
        if session.provider == .codex, session.messages[index].providerTurnID != nil, session.remoteSessionID != nil { return .inPlace }
        let previous = session.messages[..<index].last { $0.role == .assistant && $0.state == .complete }
        return .branch(previousReply: previous?.id)
    }

    func undoTurn(boardID: UUID, nodeID: UUID, messageID: UUID) {
        guard let plan = undoPlan(boardID: boardID, nodeID: nodeID, messageID: messageID), let node = board(boardID)?.node(nodeID),
              let worktree = node.worktree, let session = sessionsByID[node.sessionID],
              let message = session.messages.first(where: { $0.id == messageID }), let checkpoint = message.checkpoint else { return }
        guard !app.runningSessionIDs.contains(session.id), !gitBusy.contains(nodeID) else { app.errorMessage = "这个节点还在回复，等它结束再撤销。"; return }
        switch plan {
        case .inPlace:
            guard let thread = session.remoteSessionID, let turn = message.providerTurnID else { return }
            let executable = URL(fileURLWithPath: NSString(string: app.configuration[.codex].executablePath).expandingTildeInPath)
            gitBusy.insert(nodeID)
            Task {
                defer { gitBusy.remove(nodeID) }
                do {
                    try await git { try ProjectGit.ensure(worktree) }
                    // History first: if Codex refuses, the files stay as they are.
                    try await CodexBackend.revert(executableURL: executable, directory: URL(fileURLWithPath: worktree.workingDirectory), threadID: thread, beforeTurnID: turn)
                    try await git { try ProjectGit.restore(worktree, to: checkpoint) }
                    app.dropMessages(sessionID: session.id, from: messageID)
                    await refreshChanges(boardID: boardID, nodeID: nodeID)
                    app.noticeMessage = "已撤销这一回合：worktree 回到回合开始前，Codex 会话也删掉了这一回合及之后的回合。"
                } catch { app.errorMessage = "撤销失败：\(SafeText.redact(error.localizedDescription))" }
            }
        case .branch(let previous):
            let childID = UUID()
            placeBranch(boardID: boardID, parentID: nodeID, childID: childID, inheritThrough: previous,
                        title: "撤销后 · \(session.title)", start: { checkpoint })
        }
    }

    /// A new conversation with one fixed reply as input; no ancestor history and no send.
    func quote(boardID: UUID, nodeID: UUID, messageID: UUID) {
        guard let board = library.boards.first(where: { $0.id == boardID }), board.node(nodeID) != nil,
              let source = board.node(nodeID).flatMap({ sessionsByID[$0.sessionID] }),
              source.messages.contains(where: { $0.id == messageID && $0.role == .assistant && $0.state == .complete && !$0.text.isEmpty }) else { return }
        let quoteID = UUID()
        withWorktree(boardID: boardID, nodeID: quoteID) { [weak self] worktree in
            guard let self, let board = self.board(boardID), let parent = board.node(nodeID),
                  let sessionID = self.newSession(on: boardID, provider: source.provider, copying: source, worktree: worktree) else { return false }
            self.app.renameSession(sessionID, title: "引用 · \(source.title)")
            var node = CanvasNode(id: quoteID, sessionID: sessionID, position: board.freePosition(near: .init(x: parent.position.x + 440, y: parent.position.y)))
            node.worktree = worktree
            self.update(boardID) { board in
                board.nodes.append(node)
                _ = try? board.connect(source: parent.id, target: node.id, kind: .data, sourceMessageID: messageID)
            }
            self.focusNodeID = node.id
            return true
        }
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
        // A worktree cleaned up in Settings comes back from its branch.
        if let worktree = node.worktree, !worktree.exists, board.project?.isTrusted == true {
            do { try ProjectGit.ensure(worktree) }
            catch { app.errorMessage = "无法恢复这个节点的 worktree：\(error.localizedDescription)"; return false }
        }
        // Images already in the composer count against the per-turn image cap.
        let draftImages = app.attachmentDrafts.files[node.sessionID, default: []].filter(\.isImage).count
        let context = CanvasContextBuilder.context(board: board, nodeID: nodeID, sessions: sessionsByID,
                                                   imageBudget: CanvasContextBuilder.maxImagesPerTurn - draftImages,
                                                   diffs: diffSummaries(board: board, into: nodeID))
        let access = CanvasWriteAccess.decide(board: board, nodeID: nodeID, sessions: sessionsByID, writers: writingSessions)
        // A writing turn in a worktree starts from a checkpoint it can be undone to.
        let replyID = UUID()
        var checkpoint: String?
        if access.writable, let worktree = node.worktree, !app.runningSessionIDs.contains(node.sessionID) {
            do { checkpoint = try ProjectGit.checkpoint(worktree, message: replyID) }
            catch { app.errorMessage = "无法记录检查点，这一回合不能撤销：\(error.localizedDescription)" }
        }
        guard app.send(text, to: node.sessionID, context: context, project: board.project, writable: access.writable,
                       assistantID: replyID, checkpoint: checkpoint) else { return false }
        if access.writable { writingSessions.insert(node.sessionID) }
        if let checkpoint { checkpointedTurns[node.sessionID] = (boardID, nodeID, replyID, checkpoint) }
        if let reason = access.reason { app.noticeMessage = reason }
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

    /// Diff summaries for data edges that ask for one, from source nodes with a worktree.
    func diffSummaries(board: CanvasBoard, into nodeID: UUID) -> [UUID: String] {
        var result: [UUID: String] = [:]
        for edge in board.dataEdges(into: nodeID) where edge.includeDiff == true {
            guard let worktree = board.node(edge.source)?.worktree, worktree.exists,
                  let summary = try? ProjectGit.diffSummary(worktree) else { continue }
            result[edge.id] = summary
        }
        return result
    }

    // MARK: Worktrees

    func setEdgeDiff(boardID: UUID, edgeID: UUID, on: Bool) {
        update(boardID) { board in
            if let i = board.edges.firstIndex(where: { $0.id == edgeID && $0.kind == .data }) { board.edges[i].includeDiff = on ? true : nil }
        }
    }

    private func title(of node: CanvasNode) -> String { sessionsByID[node.sessionID]?.title ?? "节点" }

    /// "合并到 <base>": the node's work as a `--no-ff` merge in the project
    /// checkout. Conflicts are reported and the merge abandoned; nothing is pushed.
    func mergeToBase(boardID: UUID, nodeID: UUID) {
        guard let node = board(boardID)?.node(nodeID), let worktree = node.worktree, !gitBusy.contains(nodeID) else { return }
        guard !app.runningSessionIDs.contains(node.sessionID) else { app.errorMessage = "这个节点还在回复，等它结束再合并。"; return }
        let title = title(of: node)
        gitBusy.insert(nodeID)
        Task {
            defer { gitBusy.remove(nodeID) }
            do {
                switch try await git({ try ProjectGit.mergeToBase(worktree, title: title) }) {
                case .merged(let commit):
                    await refreshChanges(boardID: boardID, nodeID: nodeID)
                    app.noticeMessage = "已把「\(title)」合并到 \(worktree.baseBranch ?? "基础分支")（\(commit.prefix(8))）。没有推送。"
                case .upToDate:
                    app.noticeMessage = "「\(title)」没有需要合并的新改动。"
                }
            } catch { app.errorMessage = error.localizedDescription }
        }
    }

    /// A merge node's "把这几个分支的改动合起来": it gets a worktree from the
    /// project HEAD (once), and the upstream nodes' branches are merged into
    /// it one by one. A conflict stays in its worktree and its composer asks
    /// the agent to resolve it; running this again finishes the merge and goes on.
    func combineBranches(boardID: UUID, nodeID: UUID) {
        guard let board = board(boardID), let node = board.node(nodeID), node.merge != nil, !gitBusy.contains(nodeID) else { return }
        guard board.project?.isTrusted == true, let path = board.project?.path, isGit(path) else {
            app.errorMessage = "只有信任的 git 项目才能合并分支。"; return
        }
        guard !app.runningSessionIDs.contains(node.sessionID) else { app.errorMessage = "合流节点还在回复，等它结束再合并。"; return }
        let upstream = board.dataEdges(into: nodeID).compactMap { edge -> ProjectGit.Upstream? in
            guard let source = board.node(edge.source), let worktree = source.worktree else { return nil }
            return .init(title: title(of: source), worktree: worktree)
        }
        guard !upstream.isEmpty else { app.errorMessage = "上游节点都没有自己的 worktree，没有可以合并的分支。"; return }
        if upstream.contains(where: { item in board.nodes.contains { $0.worktree == item.worktree && app.runningSessionIDs.contains($0.sessionID) } }) {
            app.errorMessage = "有上游节点还在回复，等它们结束再合并。"; return
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true), root = worktreeRoot, existing = node.worktree
        gitBusy.insert(nodeID)
        Task {
            defer { gitBusy.remove(nodeID) }
            do {
                let worktree: NodeWorktree
                if let existing {
                    try await git { try ProjectGit.ensure(existing) }
                    worktree = existing
                } else {
                    worktree = try await git { try ProjectGit.createWorktree(project: folder, board: boardID, node: nodeID, root: root) }
                    update(boardID) { board in
                        if let i = board.nodes.firstIndex(where: { $0.id == nodeID }) { board.nodes[i].worktree = worktree }
                    }
                    app.setWorkingDirectory(node.sessionID, path: worktree.workingDirectory)
                }
                switch try await git({ try ProjectGit.combine(upstream, into: worktree) }) {
                case .merged(let titles):
                    app.noticeMessage = "已把 \(titles.count) 个上游分支合并到「\(title(of: node))」的 worktree（\(worktree.branch)）。确认无误后可以再把它合并到 \(worktree.baseBranch ?? "基础分支")。"
                case .conflicts(let source, let files, let remaining):
                    let rest = remaining.isEmpty ? "" : "解决后再点一次“合并上游分支到这里”，会继续合并：\(remaining.map { "「\($0)」" }.joined(separator: "、"))。"
                    app.noticeMessage = "合并「\(source)」时有冲突，冲突留在这个节点的 worktree 里。\(rest)"
                    composerFill = (node.sessionID, "合并「\(source)」的分支时有冲突，冲突文件：\(files.joined(separator: "、"))。请在当前目录里解决这些文件中的冲突标记，保留两边都需要的改动，不要运行 git commit；改完告诉我结果。")
                    focusNodeID = nodeID
                }
            } catch { app.errorMessage = error.localizedDescription }
        }
    }

    func revealWorktree(boardID: UUID, nodeID: UUID) -> URL? {
        guard let worktree = board(boardID)?.node(nodeID)?.worktree, worktree.exists else { return nil }
        return URL(fileURLWithPath: worktree.workingDirectory, isDirectory: true)
    }

    var allWorktrees: [NodeWorktree] { library.boards.flatMap { $0.nodes.compactMap(\.worktree) } }

    /// Removes the worktrees of nodes whose branch is already in its base
    /// branch and that have nothing uncommitted. Branches stay, so a node's
    /// next send brings its worktree back. Returns how many were removed.
    func cleanupMergedWorktrees() async -> Int {
        let candidates = allWorktrees.filter { $0.exists }
        let busy = Set(library.boards.flatMap { b in b.nodes.filter { app.runningSessionIDs.contains($0.sessionID) }.compactMap(\.worktree?.path) })
        do {
            return try await git {
                var removed = 0
                for worktree in candidates where !busy.contains(worktree.path) && ProjectGit.isMergedAndClean(worktree) {
                    try ProjectGit.remove(worktree)
                    removed += 1
                }
                return removed
            }
        } catch { app.errorMessage = "清理 worktree 失败：\(error.localizedDescription)"; return 0 }
    }

    private func persist() {
        guard writable else { return }
        do { try store.save(library) }
        catch { app.errorMessage = "画布布局保存失败：\(error.localizedDescription)" }
    }
}
