import AppKit
import SwiftUI
import AgentDeskCore

/// Answers AgentDesk's files server: each folder a conversation has not been
/// granted is shown in a floating panel, one request at a time, whichever
/// window is in front. No answer within the server's wait is a no.
@MainActor
final class FolderAccessCenter: ObservableObject {
    let exchange: FolderAccessExchange
    /// Only servers started for this launch carry it; older requests are
    /// declined. `--folder-access-token` fixes it for UI checks.
    let token: String = {
        let args = ProcessInfo.processInfo.arguments
        return args.firstIndex(of: "--folder-access-token").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? UUID().uuidString
    }()
    @Published private(set) var current: FolderAccessRequest?
    @Published private(set) var grants: [UUID: [String]] = [:]
    var describe: (UUID) -> (title: String, provider: ProviderID)? = { _ in nil }
    private var timer: Timer?
    private var panel: NSPanel?

    init(root: URL) {
        exchange = FolderAccessExchange(root: root)
        grants = exchange.allGrants()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    static var helperURL: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("agentdesk-files")
    }

    /// `approvals`: the project folder, when the server also answers Claude Code's permission prompts.
    /// `project`: the project whose memory the model may propose entries for.
    func server(for sessionID: UUID, dataRoot: URL, files: Bool = true, approvals: String? = nil, project: URL? = nil) -> AgentMCPServer? {
        Self.helperURL.flatMap { FolderAccessPolicy.server(helper: $0, dataRoot: dataRoot, sessionID: sessionID, token: token, files: files, approvals: approvals, project: project) }
    }

    func poll() {
        let pending = exchange.pending()
        if let shown = current {
            // The server stopped waiting (timeout, or the turn was stopped).
            if !pending.contains(where: { $0.id == shown.id }) { close() }
            return
        }
        for request in pending {
            guard request.token == token, Date().timeIntervalSince(request.createdAt) < FolderAccessPolicy.approvalTimeout else {
                exchange.discard(request.id); continue
            }
            current = request
            show()
            return
        }
    }

    func answer(_ decision: FolderAccessDecision) {
        guard let request = current else { return }
        try? exchange.respond(request, decision: decision)
        grants = exchange.allGrants()
        close()
        poll()
    }

    func revoke(_ folder: String, session: UUID) {
        try? exchange.setGrantedFolders(exchange.grantedFolders(session: session).filter { $0 != folder }, session: session)
        grants = exchange.allGrants()
    }

    func forget(session: UUID) {
        try? exchange.setGrantedFolders([], session: session)
        grants = exchange.allGrants()
    }

    private func show() {
        let panel = self.panel ?? {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 280), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            panel.title = "读取文件夹"
            panel.titlebarAppearsTransparent = true
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            self.panel = panel
            return panel
        }()
        let host = NSHostingView(rootView: FolderAccessPrompt(center: self))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func close() {
        current = nil
        panel?.orderOut(nil)
    }

    static func toolName(_ tool: String) -> String {
        switch tool {
        case "list_directory": return "列出文件夹"
        case "read_file": return "读取文件"
        case "search_files": return "搜索文件名"
        default: return tool
        }
    }
}

private struct FolderAccessPrompt: View {
    @ObservedObject var center: FolderAccessCenter

    var body: some View {
        if let request = center.current {
            let who = center.describe(request.sessionID)
            VStack(alignment: .leading, spacing: 12) {
                Text("允许读取这个文件夹吗？").titleText(17)
                Text("「\(who?.title ?? "对话")」里的 \(who?.provider.name ?? "模型") 想\(FolderAccessCenter.toolName(request.tool))。")
                    .font(Theme.sans(12)).foregroundStyle(Theme.muted)
                VStack(alignment: .leading, spacing: 6) {
                    Text(request.folder).font(Theme.mono(12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if request.path != request.folder {
                        Text("这次要读：\(URL(fileURLWithPath: request.path).lastPathComponent)").metaText()
                    }
                    if let reason = request.reason, !reason.isEmpty {
                        Text("理由：\(reason)").font(Theme.sans(12)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .themedCard()
                Text("只读，不会修改或删除文件。允许后，这个对话可以读这个文件夹和它的子文件夹；隐藏文件和 ~/Library 始终不读。")
                    .font(Theme.sans(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("拒绝") { center.answer(.deny) }
                        .buttonStyle(SecondaryButtonStyle(destructive: true))
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("只允许这一次") { center.answer(.once) }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("这个对话里允许") { center.answer(.conversation) }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .padding(.top, 8)
            .frame(width: 480)
            .themedSurface()
        }
    }
}

/// Settings: the switch and every folder a conversation may read.
struct FolderAccessSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var center: FolderAccessCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("允许模型请求读取文件夹").font(Theme.sans(13, weight: .medium))
                    Text("私聊和画布里的模型可以请求读取你电脑上的文件夹，每个新文件夹都会先弹窗问你。只读；隐藏文件和 ~/Library 始终不读；群聊不使用。")
                        .font(Theme.sans(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("允许模型请求读取文件夹", isOn: Binding(get: { model.configuration.folderAccess },
                                                     set: { model.configuration.folderAccess = $0; model.saveConfiguration() }))
                    .labelsHidden().toggleStyle(ThemedSwitchStyle()).fixedSize()
            }
            if !center.grants.isEmpty {
                Text("已允许的文件夹").sectionLabel()
                ForEach(center.grants.keys.sorted { $0.uuidString < $1.uuidString }, id: \.self) { session in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(center.describe(session)?.title ?? "已删除的对话").font(Theme.sans(12, weight: .medium))
                        ForEach(center.grants[session] ?? [], id: \.self) { folder in
                            HStack {
                                Text(folder).font(Theme.mono(11)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button("撤销") { center.revoke(folder, session: session) }.buttonStyle(SecondaryButtonStyle())
                            }
                        }
                    }
                }
            }
        }
        .themedCard()
    }
}
