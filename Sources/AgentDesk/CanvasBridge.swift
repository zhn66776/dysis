import AppKit
import Combine
import Foundation
import WebKit
import AgentDeskCore

// Bridge protocol v1 (design/CANVAS.md §4.2). The page only displays state
// and sends typed commands; every decision about sessions, files and model
// turns stays on this side.

struct BridgeBoardSummary: Encodable, Equatable { let id: UUID; let title: String; let nodeCount: Int }

struct BridgeNode: Encodable, Equatable {
    struct Inherited: Encodable, Equatable {
        let fromNodeID: UUID, messageCount: Int
        /// "native" or "replay" while the node has not started; nil afterwards.
        let mode: String?, reason: String?
    }
    let id: UUID, sessionID: UUID, x: Double, y: Double
    let inherited: Inherited?
    /// Merge template title for merge nodes.
    let merge: String?
    /// Answered before, but an upstream node has newer output.
    let stale: Bool
    /// Nodes a downstream re-run from here would call.
    let downstream: Int
}

struct BridgeChain: Encodable, Equatable {
    let boardID: UUID?, total: Int, index: Int, currentNodeID: UUID?
    static let idle = BridgeChain(boardID: nil, total: 0, index: 0, currentNodeID: nil)
}

struct BridgeEdge: Encodable, Equatable { let id: UUID; let kind: CanvasEdgeKind; let source: UUID; let target: UUID; let pending: Bool?; let sourceMessageID: UUID? }

struct BridgeBoard: Encodable, Equatable {
    let id: UUID, title: String, nodes: [BridgeNode], edges: [BridgeEdge], viewport: CanvasViewport?
}

struct BridgeSummary: Encodable, Equatable {
    let id: UUID, title: String, provider: ProviderID, modelID: String
    /// Matches BridgeModelOption.key; for Cursor the model family.
    let modelKey: String
    let effort: String?, remoteShort: String?
    /// Selectable efforts for the current model; empty means none discovered.
    let effortChoices: [String]
    let state: String, status: String?, preview: String
    let messageCount: Int, updatedAt: Double
    let contextUsed: Int?, contextWindow: Int?
    let latestReplyID: UUID?
}

struct BridgeModelOption: Encodable, Equatable { let id: String; let key: String; let label: String }

struct BridgeQuotaWindow: Encodable, Equatable { let label: String; let usedPercent: Double; let resetsAt: Double? }
struct BridgeQuota: Encodable, Equatable { let windows: [BridgeQuotaWindow]; let status: String?; let updatedAt: Double }

struct BridgeDraft: Encodable, Equatable {
    struct File: Encodable, Equatable { let id: UUID; let name: String; let kind: String; let bytes: Int64 }
    let sessionID: UUID, files: [File], importing: Bool
}

struct BridgeMessage: Encodable, Equatable {
    let id: UUID, role: MessageRole, text: String, state: MessageState, createdAt: Double
    let actualModels: [String]?, attachments: [String]?, contextSources: [String]?
}

struct BridgeDetail: Encodable, Equatable { let id: UUID; let messages: [BridgeMessage] }
struct BridgeAppend: Encodable { let sessionID: UUID; let messageID: UUID; let text: String }

struct BridgeState: Encodable {
    let type = "state"
    var reset: Bool?
    var boards: [BridgeBoardSummary]?
    var board: BridgeBoard?
    var summaries: [BridgeSummary]?
    var removedSessions: [UUID]?
    var details: [BridgeDetail]?
    var appends: [BridgeAppend]?
    var models: [String: [BridgeModelOption]]?
    var quotas: [String: BridgeQuota]?
    var drafts: [BridgeDraft]?
    var chain: BridgeChain = .idle
    var running: [UUID]
    var error: String
    var focusNodeID: UUID?
}

struct BridgeCommand: Decodable {
    struct Position: Decodable { let nodeID: UUID; let x: Double; let y: Double }
    struct Rect: Decodable { let x: Double; let y: Double; let w: Double; let h: Double }
    let type: String
    var boardID: UUID?, nodeID: UUID?, sessionID: UUID?, messageID: UUID?
    var source: UUID?, target: UUID?, connectFrom: UUID?, panelSessionID: UUID?
    var nodeIDs: [UUID]?, edgeIDs: [UUID]?, sessionIDs: [UUID]?
    var positions: [Position]?
    var provider: ProviderID?
    var x: Double?, y: Double?, zoom: Double?
    var title: String?, text: String?, window: String?
    var modelID: String?, effort: String?, attachmentID: UUID?, template: String?
    /// `confirm.answer`: the dialog ID Swift issued and whether the user clicked the action.
    var id: UUID?, ok: Bool?
    /// `chrome.regions`: page areas (CSS px from the top-left) that move the window, and controls inside them that do not.
    var drag: [Rect]?, noDrag: [Rect]?
}

enum BridgeEncoding {
    @MainActor
    static func models(_ app: AppModel) -> [String: [BridgeModelOption]] {
        var result: [String: [BridgeModelOption]] = [:]
        result[ProviderID.claude.rawValue] = (ModelCatalog.claudeVersions + ModelCatalog.claudeAliases).map { .init(id: $0.id, key: $0.id, label: $0.name) }
        result[ProviderID.codex.rawValue] = (app.availableModels[.codex] ?? []).map { .init(id: $0, key: $0, label: $0) }
        for p in [ProviderID.grok, .gemini] {
            result[p.rawValue] = ReasoningEffortCatalog.cursorFamilies(availableModelIDs: app.availableModels[p] ?? []).map { .init(id: $0.id, key: $0.label, label: $0.label) }
        }
        return result
    }

    @MainActor
    static func effortChoices(_ s: ChatSession, app: AppModel) -> [String] {
        switch s.provider {
        case .claude: return ReasoningEffortCatalog.claudeChoices
        case .codex: return app.codexEfforts[s.modelID.isEmpty ? app.configuration[.codex].modelID : s.modelID] ?? []
        case .grok, .gemini:
            let order = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
            return ReasoningEffortCatalog.cursorVariants(modelID: s.modelID, availableModelIDs: app.availableModels[s.provider] ?? [])
                .keys.sorted { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }
        }
    }

    static func quota(_ q: ProviderQuota) -> BridgeQuota {
        BridgeQuota(windows: q.windows.map { .init(label: $0.label, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt.map { $0.timeIntervalSince1970 * 1000 }) },
                    status: q.status, updatedAt: q.updatedAt.timeIntervalSince1970 * 1000)
    }

    static func summary(_ s: ChatSession, running: Bool, status: String?, effortChoices: [String]) -> BridgeSummary {
        let lastReply = s.messages.last { $0.role == .assistant }
        let state: String
        if running { state = "running" }
        else if let lastReply { state = lastReply.state == .streaming ? "cancelled" : lastReply.state.rawValue }
        else { state = "empty" }
        let previewSource = lastReply?.text.isEmpty == false ? lastReply!.text : (s.messages.last?.text ?? "")
        let cursor = s.provider == .grok || s.provider == .gemini
        return BridgeSummary(
            id: s.id, title: s.title, provider: s.provider, modelID: s.modelID,
            modelKey: cursor ? ReasoningEffortCatalog.cursorFamily(of: s.modelID) : s.modelID,
            effort: cursor ? ReasoningEffortCatalog.cursorVariantEffort(modelID: s.modelID) : s.reasoningEffort,
            remoteShort: s.remoteSessionID.map { String($0.prefix(8)) }, effortChoices: effortChoices,
            state: state, status: running ? status : nil, preview: String(previewSource.prefix(160)),
            messageCount: s.messages.count, updatedAt: s.updatedAt.timeIntervalSince1970 * 1000,
            contextUsed: s.contextUsage?.usedTokens, contextWindow: s.contextUsage?.windowTokens,
            latestReplyID: s.messages.last { $0.role == .assistant && $0.state == .complete && !$0.text.isEmpty }?.id)
    }

    static func message(_ m: ChatMessage) -> BridgeMessage {
        BridgeMessage(id: m.id, role: m.role, text: m.text, state: m.state, createdAt: m.createdAt.timeIntervalSince1970 * 1000,
                      actualModels: m.actualModelIDs, attachments: m.attachments?.map(\.displayName), contextSources: m.contextSources)
    }

    static func board(_ b: CanvasBoard, sessions: [UUID: ChatSession], running: Set<UUID>) -> BridgeBoard {
        let stale = CanvasContextBuilder.staleNodes(board: b, sessions: sessions, running: running)
        let ran = { (n: CanvasNode) in CanvasContextBuilder.hasRun(sessions[n.sessionID]) }
        let nodes = b.nodes.map { n -> BridgeNode in
            var inherited: BridgeNode.Inherited?
            if let edge = b.inheritEdge(into: n.id), let parent = b.node(edge.source), let ps = sessions[parent.sessionID] {
                let count = edge.sourceMessageID.flatMap { cut in ps.messages.firstIndex { $0.id == cut } }.map { $0 + 1 } ?? ps.messages.count
                let mode = CanvasContextBuilder.inheritMode(board: b, nodeID: n.id, sessions: sessions)
                switch mode {
                case .native?: inherited = .init(fromNodeID: parent.id, messageCount: count, mode: "native", reason: nil)
                case .replay(let reason)?: inherited = .init(fromNodeID: parent.id, messageCount: count, mode: "replay", reason: reason)
                case nil: inherited = .init(fromNodeID: parent.id, messageCount: count, mode: nil, reason: nil)
                }
            }
            return BridgeNode(id: n.id, sessionID: n.sessionID, x: n.position.x, y: n.position.y, inherited: inherited,
                              merge: n.merge?.title, stale: stale.contains(n.id),
                              // Offer a re-run only when a direct downstream node is behind this one.
                              downstream: b.edges.contains { $0.kind == .data && $0.source == n.id && stale.contains($0.target) } ? b.downstreamOrder(from: n.id, include: ran).count : 0)
        }
        let pending = Set(b.nodes.flatMap { CanvasContextBuilder.pendingUpstream(board: b, nodeID: $0.id, sessions: sessions).map(\.edgeID) })
        let edges = b.edges.map { BridgeEdge(id: $0.id, kind: $0.kind, source: $0.source, target: $0.target, pending: $0.kind == .data ? pending.contains($0.id) : nil, sourceMessageID: $0.sourceMessageID) }
        return BridgeBoard(id: b.id, title: b.title, nodes: nodes, edges: edges, viewport: b.viewport)
    }
}

@MainActor
final class CanvasBridge: NSObject, ObservableObject, WKScriptMessageHandler {
    let app: AppModel
    let canvas: CanvasModel
    weak var webView: WKWebView?
    var openWindow: (String, UUID?) -> Void = { _, _ in }

    private var ready = false
    private var scheduled = false
    private var watched: Set<UUID> = []
    private var sentBoards: [BridgeBoardSummary]?
    private var sentBoard: BridgeBoard?
    private var sentSummaries: [UUID: BridgeSummary] = [:]
    private var sentDetails: [UUID: [BridgeMessage]] = [:]
    private var sentError = ""
    private var sentRunning: Set<UUID> = []
    private var sentModels: [String: [BridgeModelOption]]?
    private var sentChain: BridgeChain = .idle
    private var sentQuotas: [String: BridgeQuota]?
    private var sentDrafts: [UUID: BridgeDraft] = [:]
    /// Open confirmations; each runs at most once, and only on `confirm.answer` with ok.
    private var pendingConfirms: [UUID: () -> Void] = [:]
    /// Where a mouse-down moves the window, as the page last reported it.
    private var dragRects: [CGRect] = [], noDragRects: [CGRect] = []
    /// The session whose panel is open (first watched ID); file drops go here.
    private(set) var panelSessionID: UUID?
    private var observers: Set<AnyCancellable> = []

    init(app: AppModel, canvas: CanvasModel) {
        self.app = app
        self.canvas = canvas
        super.init()
        // objectWillChange fires before the value changes; the push is
        // deferred and coalesced so it reads the new state, at most ~30/s.
        app.objectWillChange.sink { [weak self] in self?.schedulePush() }.store(in: &observers)
        canvas.objectWillChange.sink { [weak self] in self?.schedulePush() }.store(in: &observers)
        app.attachmentDrafts.objectWillChange.sink { [weak self] in self?.schedulePush() }.store(in: &observers)
    }

    /// Files dropped on the window go to the open panel's conversation.
    func dropFiles(_ urls: [URL]) -> Bool {
        guard let id = panelSessionID, app.sessions.contains(where: { $0.id == id }), !urls.isEmpty else { return false }
        app.attachmentDrafts.add(urls, to: id)
        return true
    }

    /// Sends `composer.insert` for an MCP result chosen in the native workbench.
    func insertIntoComposer(sessionID: UUID, text: String) {
        evaluate(["type": "composer.insert", "sessionID": sessionID.uuidString, "text": text])
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // Only the bundled page is ever loaded; still decode strictly and drop anything malformed.
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.scheme == CanvasSchemeHandler.scheme,
              JSONSerialization.isValidJSONObject(message.body),
              let data = try? JSONSerialization.data(withJSONObject: message.body),
              let command = try? JSONDecoder().decode(BridgeCommand.self, from: data) else { return }
        handle(command)
    }

    private func handle(_ c: BridgeCommand) {
        switch c.type {
        case "ready":
            ready = true
            // A reloaded page no longer shows earlier dialogs; treat them as declined.
            pendingConfirms = [:]
            push(reset: true)
            pushChrome()
            return
        case "chrome.regions":
            let rect = { (r: BridgeCommand.Rect) in CGRect(x: r.x, y: r.y, width: r.w, height: r.h) }
            dragRects = (c.drag ?? []).prefix(32).map(rect)
            noDragRects = (c.noDrag ?? []).prefix(64).map(rect)
            return
        case "confirm.answer":
            guard let id = c.id, let perform = pendingConfirms.removeValue(forKey: id) else { return }
            if c.ok == true { perform() }
        case "board.create": canvas.createBoard()
        case "board.select": if let id = c.boardID { canvas.selectBoard(id) }
        case "board.rename": if let id = c.boardID, let title = c.title { canvas.renameBoard(id, title: title) }
        case "board.delete":
            guard let id = c.boardID, let board = canvas.library.boards.first(where: { $0.id == id }) else { return }
            confirm(title: "删除画布「\(board.title)」？", detail: "画布上的 \(board.nodes.count) 个对话的本地记录也会删除。官方 CLI 中的历史和工作目录文件不受影响。", action: "删除画布") { [canvas] in
                canvas.deleteBoard(id)
            }
        case "node.create":
            guard let id = c.boardID, let provider = c.provider, let x = c.x, let y = c.y else { return }
            canvas.createNode(boardID: id, provider: provider, at: CanvasPoint(x: x, y: y), connectFrom: c.connectFrom)
        case "node.move":
            guard let id = c.boardID, let positions = c.positions else { return }
            canvas.moveNodes(boardID: id, positions: Dictionary(positions.map { ($0.nodeID, CanvasPoint(x: $0.x, y: $0.y)) }, uniquingKeysWith: { $1 }))
        case "node.delete":
            guard let id = c.boardID, let ids = c.nodeIDs, !ids.isEmpty else { return }
            let titles = canvas.library.boards.first { $0.id == id }?.nodes.filter { ids.contains($0.id) }
                .compactMap { node in app.sessions.first { $0.id == node.sessionID }?.title } ?? []
            let name = titles.count == 1 ? "「\(titles[0])」" : "\(ids.count) 个节点"
            confirm(title: "删除\(name)？", detail: "只删除本地记录和画布上的节点，官方 CLI 中的历史和工作目录文件不受影响。", action: "删除") { [canvas] in
                canvas.deleteNodes(boardID: id, nodeIDs: Set(ids))
            }
        case "node.rename":
            guard let id = c.sessionID, let title = c.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return }
            app.renameSession(id, title: title)
        case "node.branch":
            guard let b = c.boardID, let n = c.nodeID, let m = c.messageID else { return }
            canvas.branch(boardID: b, nodeID: n, messageID: m)
        case "node.quote":
            guard let b = c.boardID, let n = c.nodeID, let m = c.messageID else { return }
            canvas.quote(boardID: b, nodeID: n, messageID: m)
        case "board.search":
            guard let id = c.id, let b = c.boardID, let query = c.text,
                  let board = canvas.library.boards.first(where: { $0.id == b }) else { return }
            struct Results: Encodable {
                let type = "search.results"
                let id: UUID, boardID: UUID, query: String
                let hits: [CanvasSearchHit]
            }
            evaluatePayload(Results(id: id, boardID: b, query: query, hits: CanvasSearch.find(query, board: board, sessions: canvas.sessionsByID)))
            return
        case "context.preview":
            guard let id = c.id, let b = c.boardID, let n = c.nodeID,
                  let board = canvas.library.boards.first(where: { $0.id == b }),
                  let node = board.node(n), let session = canvas.sessionsByID[node.sessionID] else { return }
            let context = CanvasContextBuilder.context(board: board, nodeID: n, sessions: canvas.sessionsByID)
            let typed = (c.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let hasFiles = !app.attachmentDrafts.files[node.sessionID, default: []].isEmpty
            let prompt = typed.isEmpty ? (hasFiles ? "请分析我附加的文件。" : "（在输入框中填写本轮问题）") : typed
            var notes = ["这是当前时刻的预览。发送时会重新读取最新输入；文中保留实际的省略与截断标记。"]
            for edge in board.dataEdges(into: n) {
                guard let sourceNode = board.node(edge.source), let source = canvas.sessionsByID[sourceNode.sessionID] else { continue }
                let mode = edge.sourceMessageID == nil ? "跟随最新" : "指定回复"
                if let reply = CanvasContextBuilder.dataReply(edge: edge, session: source) {
                    let number = source.messages.filter { $0.role == .assistant }.firstIndex { $0.id == reply.id }.map { $0 + 1 } ?? 1
                    let delivery = context.upstream.contains { $0.edgeID == edge.id } ? "本轮传入" : "此前已送达，本轮不重复传入"
                    notes.append("「\(source.title)」· 第 \(number) 条回复 · \(mode) · \(delivery)")
                } else { notes.append("「\(source.title)」· \(mode) · 暂无可传入的完整回复") }
            }
            if session.remoteSessionID != nil { notes.append("当前官方会话还保留此前的历史；以下显示本轮新增的文字输入。断开连线只停止后续传入，已送达内容仍在会话历史中。") }
            if context.fork != nil { notes.append("首次发送还会通过官方 CLI 原生分叉父会话；其内部历史、工具记录不在此文字预览中展开。") }
            if !context.inherited.isEmpty { notes.append("回放继承只包含文字；父会话的图片和工具记录不随之传入。") }
            if app.attachmentDrafts.importing.contains(node.sessionID) { notes.append("附件仍在读取；完成后请刷新预览。") }
            if app.attachmentDrafts.files[node.sessionID, default: []].contains(where: \.isImage) { notes.append("图片通过独立的图片输入传入；此处显示附件名称及文字输入。") }
            evaluate(["type": "context.preview", "id": id.uuidString, "nodeID": n.uuidString,
                      "text": app.canvasInput(prompt: prompt, sessionID: node.sessionID, context: context), "notes": notes])
            return
        case "edge.create":
            guard let id = c.boardID, let s = c.source, let t = c.target else { return }
            canvas.connect(boardID: id, source: s, target: t)
        case "edge.delete":
            guard let id = c.boardID, let ids = c.edgeIDs else { return }
            canvas.deleteEdges(boardID: id, edgeIDs: Set(ids))
        case "session.watch":
            let previousPanel = panelSessionID
            watched = Set((c.sessionIDs ?? []).filter { id in app.sessions.contains { $0.id == id } }.prefix(8))
            panelSessionID = c.panelSessionID.flatMap { watched.contains($0) ? $0 : nil }
            sentDetails = sentDetails.filter { watched.contains($0.key) }
            sentDrafts = sentDrafts.filter { watched.contains($0.key) }
            // Opening a panel refreshes what can be read without a model turn.
            if panelSessionID != previousPanel, let id = panelSessionID, let provider = app.sessions.first(where: { $0.id == id })?.provider {
                app.refreshQuota(provider)
                if (provider == .grok || provider == .gemini), app.availableModels[provider]?.isEmpty ?? true, !app.isChecking.contains(provider) {
                    Task { await app.loadModels(provider) }
                }
            }
        case "session.setModel":
            guard let id = c.sessionID, let modelID = c.modelID else { return }
            app.setSessionModel(id, modelID: modelID)
        case "session.setEffort":
            guard let id = c.sessionID, let session = app.sessions.first(where: { $0.id == id }) else { return }
            if session.provider == .grok || session.provider == .gemini {
                // Cursor effort is a model variant of the same family.
                guard let value = c.effort, let variant = ReasoningEffortCatalog.cursorVariants(modelID: session.modelID, availableModelIDs: app.availableModels[session.provider] ?? [])[value] else { return }
                app.setSessionEffortVariant(id, modelID: variant)
            } else {
                let value = c.effort.flatMap { $0.isEmpty ? nil : $0 }
                if let value, !BridgeEncoding.effortChoices(session, app: app).contains(value) { return }
                app.setSessionEffort(id, effort: value)
            }
        case "node.merge":
            guard let b = c.boardID, let ids = c.nodeIDs, let provider = c.provider,
                  let template = c.template.flatMap(CanvasMergeTemplate.init(rawValue:)) else { return }
            canvas.merge(boardID: b, nodeIDs: ids, provider: provider, template: template)
        case "node.rerun":
            // One stale node answers again with its new upstream input: one call.
            guard let b = c.boardID, let n = c.nodeID else { return }
            canvas.runChain(boardID: b, order: [n])
        case "chain.downstream":
            guard let b = c.boardID, let n = c.nodeID else { return }
            let order = canvas.downstreamOrder(boardID: b, from: n)
            guard !order.isEmpty else { return }
            let board = canvas.library.boards.first { $0.id == b }
            let names = order.compactMap { id in board?.node(id).flatMap { node in app.sessions.first { $0.id == node.sessionID }?.title } }
            confirm(title: "重跑下游：调用 \(order.count) 次？", detail: "按顺序重新回答：\(names.map { "「\($0)」" }.joined(separator: " → "))。每个节点会带上上游的新输出重新回答上一个问题；某个节点没有完成时，后面的节点不会运行。", action: "重跑 \(order.count) 个节点") { [canvas] in
                canvas.runChain(boardID: b, order: order)
            }
        case "chain.stop":
            canvas.stopChain()
        case "provider.refresh":
            guard let provider = c.provider, !app.isChecking.contains(provider) else { return }
            Task { await app.loadModels(provider) }
        case "attachment.choose":
            if let id = c.sessionID { app.attachmentDrafts.choose(for: id) }
        case "attachment.remove":
            if let id = c.sessionID, let file = c.attachmentID { app.attachmentDrafts.remove(file, from: id) }
        case "chat.send":
            guard let b = c.boardID, let n = c.nodeID, let text = c.text else { return }
            canvas.send(boardID: b, nodeID: n, text: text)
        case "chat.stop": if let id = c.sessionID { app.stop(sessionID: id) }
        case "viewport.save":
            guard let id = c.boardID, let x = c.x, let y = c.y, let zoom = c.zoom, zoom.isFinite, zoom > 0 else { return }
            canvas.saveViewport(boardID: id, viewport: CanvasViewport(x: x, y: y, zoom: zoom))
            return
        case "clipboard.copy":
            guard let text = c.text else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return
        case "app.open":
            if let window = c.window, ["settings", "classic", "mcp"].contains(window) { openWindow(window, c.sessionID) }
            return
        case "error.dismiss":
            app.errorMessage = nil
            app.plaza.errorMessage = nil
            app.attachmentDrafts.errorMessage = nil
        default: return
        }
        schedulePush()
    }

    /// Asks the page to show its confirmation dialog (`confirm.show`). The
    /// action runs only when the page answers this ID with ok after a click;
    /// cancel, Esc or a reload decline it.
    private func confirm(title: String, detail: String, action: String, perform: @escaping () -> Void) {
        guard ready, webView != nil else { return }
        let id = UUID()
        pendingConfirms[id] = perform
        evaluate(["type": "confirm.show", "id": id.uuidString, "title": title, "detail": detail, "action": action])
    }

    // MARK: Window chrome

    /// The title bar is transparent and the page runs under it; tell the page
    /// how tall it is and where the traffic lights end so it can keep clear.
    func pushChrome() {
        guard ready, let window = webView?.window else { return }
        let fullScreen = window.styleMask.contains(.fullScreen)
        let top = fullScreen ? 0 : max(0, window.frame.height - window.contentLayoutRect.height)
        let left = fullScreen ? 0 : (window.standardWindowButton(.zoomButton)?.frame.maxX ?? 0)
        evaluate(["type": "chrome", "top": top, "left": left])
    }

    /// True when a mouse-down at this page point (CSS px from the top-left)
    /// should move the window, as a title bar would.
    func isWindowDragPoint(_ point: CGPoint) -> Bool {
        dragRects.contains { $0.contains(point) } && !noDragRects.contains { $0.contains(point) }
    }

    // MARK: Pushing state

    private func schedulePush() {
        guard ready, !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.033) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.push(reset: false)
        }
    }

    private func push(reset: Bool) {
        guard ready else { return }
        let sessions = canvas.sessionsByID
        var state = BridgeState(running: Array(app.runningSessionIDs), error: app.errorMessage ?? app.plaza.errorMessage ?? app.attachmentDrafts.errorMessage ?? "")
        if reset {
            state.reset = true
            sentBoards = nil; sentBoard = nil; sentSummaries = [:]; sentDetails = [:]
            sentModels = nil; sentQuotas = nil; sentDrafts = [:]
        }

        let boards = canvas.library.boards.map { BridgeBoardSummary(id: $0.id, title: $0.title, nodeCount: $0.nodes.count) }
        if boards != sentBoards { state.boards = boards; sentBoards = boards }
        if let current = canvas.currentBoard {
            let board = BridgeEncoding.board(current, sessions: sessions, running: app.runningSessionIDs)
            if board != sentBoard { state.board = board; sentBoard = board }
        }

        var summaries: [BridgeSummary] = []
        for s in app.sessions {
            let summary = BridgeEncoding.summary(s, running: app.runningSessionIDs.contains(s.id), status: app.activeStatus[s.id], effortChoices: BridgeEncoding.effortChoices(s, app: app))
            if sentSummaries[s.id] != summary { summaries.append(summary); sentSummaries[s.id] = summary }
        }
        let removed = sentSummaries.keys.filter { sessions[$0] == nil }
        for id in removed { sentSummaries[id] = nil; sentDetails[id] = nil }
        if !summaries.isEmpty { state.summaries = summaries }
        if !removed.isEmpty { state.removedSessions = Array(removed) }

        // Watched sessions: full messages once, then only the streamed tail.
        var details: [BridgeDetail] = [], appends: [BridgeAppend] = []
        for id in watched {
            guard let s = sessions[id] else { continue }
            let messages = s.messages.map(BridgeEncoding.message)
            if let old = sentDetails[id], let tail = Self.appendOnly(old: old, new: messages) {
                if !tail.isEmpty { appends.append(BridgeAppend(sessionID: id, messageID: messages[messages.count - 1].id, text: tail)) }
            } else if sentDetails[id] != messages {
                details.append(BridgeDetail(id: id, messages: messages))
            }
            sentDetails[id] = messages
        }
        if !details.isEmpty { state.details = details }
        if !appends.isEmpty { state.appends = appends }

        let models = BridgeEncoding.models(app)
        if models != sentModels { state.models = models; sentModels = models }
        let quotas = Dictionary(uniqueKeysWithValues: app.quotas.map { ($0.key.rawValue, BridgeEncoding.quota($0.value)) })
        if quotas != sentQuotas { state.quotas = quotas; sentQuotas = quotas }
        var drafts: [BridgeDraft] = []
        for id in watched {
            let files = app.attachmentDrafts.files[id, default: []].map { BridgeDraft.File(id: $0.id, name: $0.displayName, kind: $0.kind.rawValue, bytes: $0.byteCount) }
            let draft = BridgeDraft(sessionID: id, files: files, importing: app.attachmentDrafts.importing.contains(id))
            if sentDrafts[id] != draft { drafts.append(draft); sentDrafts[id] = draft }
        }
        if !drafts.isEmpty { state.drafts = drafts }

        if let focus = canvas.focusNodeID { state.focusNodeID = focus; canvas.focusNodeID = nil }
        if let c = canvas.chain {
            state.chain = BridgeChain(boardID: c.boardID, total: c.order.count, index: c.index, currentNodeID: c.order[safe: c.index])
        }
        let fill = canvas.composerFill
        if fill != nil { canvas.composerFill = nil }

        let changed = reset || state.boards != nil || state.board != nil || state.summaries != nil || state.removedSessions != nil
            || state.details != nil || state.appends != nil || state.focusNodeID != nil
            || state.models != nil || state.quotas != nil || state.drafts != nil || state.chain != sentChain
            || state.error != sentError || app.runningSessionIDs != sentRunning
        sentError = state.error
        sentRunning = app.runningSessionIDs
        sentChain = state.chain
        if changed, let data = try? JSONEncoder().encode(state), let json = String(data: data, encoding: .utf8) {
            webView?.evaluateJavaScript("window.agentDesk.receive(\(json))")
        }
        // After the state that opens the node's panel.
        if let fill { insertIntoComposer(sessionID: fill.sessionID, text: fill.text) }
    }

    /// The streamed tail when only the last message's text grew; nil when
    /// anything else changed.
    static func appendOnly(old: [BridgeMessage], new: [BridgeMessage]) -> String? {
        guard old.count == new.count, let o = old.last, let n = new.last, old.dropLast() == new.dropLast(),
              o.id == n.id, o.state == n.state, o.actualModels == n.actualModels, n.text.hasPrefix(o.text) else { return nil }
        return String(n.text.dropFirst(o.text.count))
    }

    private func evaluatePayload<T: Encodable>(_ payload: T) {
        guard let data = try? JSONEncoder().encode(payload), let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.agentDesk.receive(\(json))")
    }

    private func evaluate(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.agentDesk.receive(\(json))")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
