import SwiftUI
import AgentDeskCore
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

private enum SidebarSelection: Hashable { case chat(UUID), plaza(UUID) }

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var plaza: PlazaModel
    @ObservedObject var attachments: AttachmentDrafts
    @State private var searchText = ""
    @State private var draftBySession: [UUID: String] = [:]
    @State private var renamingSession: ChatSession?
    @State private var renameText = ""
    @State private var showingSettings = false
    @State private var showingNewPlaza = false
    @State private var showingMCP = false
    @State private var selectedPlazaID: UUID?
    @State private var draftByPlaza: [UUID: String] = [:]

    init(model: AppModel) { self.model = model; self.plaza = model.plaza; self.attachments = model.attachmentDrafts }

    private var visibleSessions: [ChatSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.sessions }
        return model.sessions.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.provider.name.localizedCaseInsensitiveContains(query) ||
            $0.modelID.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            SessionSidebar(
                model: model,
                sessions: visibleSessions,
                searchText: $searchText,
                onNewSession: { model.newSession(provider: $0) },
                onRename: beginRename,
                onDelete: model.deleteSession,
                plaza: plaza,
                selectedPlazaID: $selectedPlazaID,
                onNewPlaza: { showingNewPlaza = true },
                onMCP: { showingMCP = true },
                onSettings: { showingSettings = true }
            )
            .frame(width: 270)
            Hairline(vertical: true).ignoresSafeArea(edges: .top)
            Group {
                if let id = selectedPlazaID {
                    PlazaDetail(model: plaza, appModel: model, attachments: attachments, roomID: id, draft: Binding(get: { draftByPlaza[id, default: ""] }, set: { draftByPlaza[id] = $0 })).id(id)
                } else if let session = model.selectedSession {
                    ChatDetail(
                        model: model,
                        attachments: attachments,
                        session: session,
                        draft: Binding(
                            get: { draftBySession[session.id, default: ""] },
                            set: { draftBySession[session.id] = $0 }
                        )
                    ).id(session.id)
                } else {
                    WelcomeView(onNewSession: { model.newSession(provider: $0) })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .themedSurface()
        .sheet(isPresented: $showingSettings) {
            SettingsView(model: model)
                .frame(width: 720, height: 650)
        }
        .onChange(of: model.selectedSessionID) { _, _ in selectedPlazaID = nil }
        .sheet(isPresented: $showingNewPlaza) {
            NewPlazaView(model: model, plaza: plaza) { selectedPlazaID = $0 }
        }
        .sheet(isPresented: $showingMCP) {
            MCPWorkbenchView(root: model.dataRoot, canAttach: selectedPlazaID != nil || model.selectedSessionID != nil,
                             targetLabel: selectedPlazaID.flatMap { id in plaza.records.first { $0.id == id }?.room.title } ?? model.selectedSession?.title ?? "请先创建对话") { result in
                if let id = selectedPlazaID { draftByPlaza[id, default: ""] += "\n\n" + result }
                else if let id = model.selectedSessionID { draftBySession[id, default: ""] += "\n\n" + result }
                showingMCP = false
            }
        }
        .sheet(item: $renamingSession) { session in
            RenameSessionView(title: $renameText) {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { model.renameSession(session.id, title: trimmed) }
                renamingSession = nil
            } onCancel: {
                renamingSession = nil
            }
        }
        .overlay(alignment: .top) {
            if let error = model.errorMessage ?? plaza.errorMessage ?? attachments.errorMessage {
                ThemedErrorBanner(message: error) {
                    model.errorMessage = nil
                    plaza.errorMessage = nil
                    attachments.errorMessage = nil
                }
                .frame(maxWidth: 640)
                .padding(.top, 10)
            }
        }
    }

    private func beginRename(_ session: ChatSession) {
        renameText = session.title
        renamingSession = session
    }
}

private struct SessionSidebar: View {
    @ObservedObject var model: AppModel
    let sessions: [ChatSession]
    @Binding var searchText: String
    let onNewSession: (ProviderID) -> Void
    let onRename: (ChatSession) -> Void
    let onDelete: (UUID) -> Void
    @ObservedObject var plaza: PlazaModel
    @Binding var selectedPlazaID: UUID?
    let onNewPlaza: () -> Void
    let onMCP: () -> Void
    let onSettings: () -> Void
    @State private var pendingDelete: ChatSession?
    @State private var pendingPlazaDelete: UUID?

    private var selection: SidebarSelection? {
        if let id = selectedPlazaID { return .plaza(id) }
        return model.selectedSessionID.map { .chat($0) }
    }

    private func select(_ value: SidebarSelection) {
        switch value {
        case .chat(let id): selectedPlazaID = nil; model.selectedSessionID = id
        case .plaza(let id): selectedPlazaID = id
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AgentDesk")
                        .titleText(16)
                    Text("独立会话 · 有界协作")
                        .metaText()
                }
                Spacer()
                Button("设置", action: onSettings)
                    .buttonStyle(GhostButtonStyle())
                    .help("配置各官方 CLI 与模型")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            HStack(spacing: 4) {
                TextField("搜索会话", text: $searchText)
                    .themedField()
                if !searchText.isEmpty {
                    Button("✕") { searchText = "" }
                        .buttonStyle(GhostButtonStyle())
                        .help("清除搜索")
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            Button(action: onNewPlaza) { Text("+  新建讨论") }
                .buttonStyle(GhostButtonStyle(fullWidth: true))
                .padding(.horizontal, 8)
            Menu {
                ForEach(ProviderID.allCases) { provider in
                    Button {
                        selectedPlazaID = nil; onNewSession(provider)
                    } label: {
                        Label { Text(provider.name) } icon: { ProviderIcon(provider: provider, size: 16) }
                    }
                }
            } label: {
                Text("+  新建会话")
            }
            .menuStyle(.button)
            .buttonStyle(GhostButtonStyle(fullWidth: true))
            .menuIndicator(.hidden)
            .padding(.horizontal, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    Text("广场").sectionLabel().padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 4)
                    ForEach(plaza.records.filter { searchText.isEmpty || $0.room.title.localizedCaseInsensitiveContains(searchText) }) { record in
                        SidebarRow(selected: selection == .plaza(record.id), action: { select(.plaza(record.id)) }) {
                            HStack(spacing: -4) {
                                ForEach(record.room.members.prefix(3)) { member in
                                    ProviderIcon(provider: member.provider, size: 16)
                                        .background(Theme.side, in: Circle())
                                }
                            }
                            .frame(width: 32, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.room.title).font(Theme.sans(13)).lineLimit(1)
                                Text(record.room.members.map(\.name).joined(separator: " · ")).metaText().lineLimit(1)
                            }
                            Spacer()
                            if plaza.running.contains(record.id) { RunningDot() }
                        }
                        .contextMenu {
                            Button("删除讨论记录", role: .destructive) { pendingPlazaDelete = record.id }.disabled(plaza.running.contains(record.id))
                        }
                    }
                    Text("私聊").sectionLabel().padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 4)
                    ForEach(sessions) { session in
                        SidebarRow(selected: selection == .chat(session.id), action: { select(.chat(session.id)) }) {
                            SessionRow(session: session, isRunning: model.runningSessionIDs.contains(session.id))
                        }
                        .contextMenu {
                            Button("重命名") { onRename(session) }
                            Divider()
                            Button("删除会话", role: .destructive) { pendingDelete = session }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }

            Hairline()
            VStack(alignment: .leading, spacing: 8) {
                Button(action: onMCP) { Text("MCP 工具").frame(maxWidth: .infinity) }
                    .buttonStyle(SecondaryButtonStyle())
                HStack(spacing: 6) {
                    Circle()
                        .fill(Theme.ok)
                        .frame(width: 6, height: 6)
                    Text("本地运行")
                        .metaText()
                    Spacer()
                    Text("\(sessions.count) 个会话")
                        .metaText()
                }
            }
            .padding(12)
        }
        .background(Theme.side.ignoresSafeArea())
        .sheet(item: $pendingDelete) { session in
            ThemedDialog(title: "删除这个会话？",
                         detail: "只移除 AgentDesk 的会话记录，不会删除官方 CLI 的 Session 或工作目录文件。",
                         action: "删除本地记录") {
                onDelete(session.id)
                pendingDelete = nil
            } onCancel: { pendingDelete = nil }
        }
        .sheet(isPresented: Binding(get: { pendingPlazaDelete != nil }, set: { if !$0 { pendingPlazaDelete = nil } })) {
            ThemedDialog(title: "删除讨论记录？", detail: "成员工作目录和官方会话仍保留。", action: "删除本地讨论记录") {
                if let id = pendingPlazaDelete { plaza.delete(id); if selectedPlazaID == id { selectedPlazaID = nil } }
                pendingPlazaDelete = nil
            } onCancel: { pendingPlazaDelete = nil }
        }
    }
}

/// A sidebar row like the canvas `.side-item`: muted until hovered or selected.
private struct SidebarRow<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8, content: content)
            .foregroundStyle(selected || hovering ? Theme.text : Theme.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected || hovering ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onTapGesture(perform: action)
            .onHover { hovering = $0 }
            .accessibilityAddTraits(.isButton)
    }
}

private struct SessionRow: View {
    let session: ChatSession
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 8) {
            ProviderIcon(provider: session.provider, size: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(session.title)
                        .font(Theme.sans(13))
                        .lineLimit(1)
                    if isRunning { RunningDot() }
                }
                Text("\(session.provider.name) · \(session.modelID.isEmpty ? session.provider.runtimeName : session.modelID)")
                    .metaText()
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            Text(session.updatedAt, format: .relative(presentation: .named))
                .metaText(10)
                .foregroundStyle(Theme.muted2)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

private struct ChatDetail: View {
    @ObservedObject var model: AppModel
    @ObservedObject var attachments: AttachmentDrafts
    let session: ChatSession
    @Binding var draft: String
    @State private var dropTargeted = false

    private var isRunning: Bool { model.runningSessionIDs.contains(session.id) }
    private var sessionStatus: String? { model.activeStatus[session.id] }

    var body: some View {
        VStack(spacing: 0) {
            ChatHeader(model: model, session: session, isRunning: isRunning, status: sessionStatus)
            Hairline()
            if session.messages.isEmpty {
                ChatEmptyState(provider: session.provider)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(session.messages) { message in
                                MessageRow(message: message, provider: session.provider, root: model.dataRoot)
                                    .id(message.id)
                            }
                        }
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 24)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: session.messages.count) { _, _ in
                        if let last = session.messages.last?.id {
                            withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                }
            }
            Composer(
                text: $draft,
                isRunning: isRunning,
                attachments: attachments.files[session.id, default: []],
                root: model.dataRoot,
                isImporting: attachments.importing.contains(session.id),
                supportsImages: session.provider == .claude || session.provider == .codex,
                onAttach: { attachments.choose(for: session.id) },
                onRemove: { attachments.remove($0, from: session.id) },
                onSend: send,
                onStop: { model.stop(sessionID: session.id) }
            )
        }
        .background(Theme.bg)
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.muted, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).padding(6).allowsHitTesting(false) } }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted) { providers in
            guard !isRunning else { return false }
            return attachments.drop(providers, into: session.id)
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !attachments.importing.contains(session.id), !text.isEmpty || !attachments.files[session.id, default: []].isEmpty else { return }
        model.send(text)
        // AppModel rejects missing executable/model configuration synchronously.
        // Keep the draft in that case so the user can fix Settings and retry.
        if model.runningSessionIDs.contains(session.id) {
            draft = ""
        }
    }
}

private struct ChatHeader: View {
    @ObservedObject var model: AppModel
    let session: ChatSession
    let isRunning: Bool
    let status: String?

    var body: some View {
        HStack(spacing: 10) {
            ProviderIcon(provider: session.provider, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(Theme.sans(14, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(session.provider.name) · \(session.modelID.isEmpty ? session.provider.runtimeName : session.modelID)")
                        .metaText()
                    if isRunning {
                        Text(status ?? "正在思考").metaText().foregroundStyle(Theme.run)
                    }
                }
                .lineLimit(1)
            }
            Spacer()
            EffortControl(model: model, provider: session.provider,
                          modelID: Binding(get: { session.modelID }, set: { model.setSessionEffortVariant(session.id, modelID: $0) }),
                          effort: Binding(get: { session.reasoningEffort }, set: { model.setSessionEffort(session.id, effort: $0) }), compact: true)
                .disabled(isRunning)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.panel.ignoresSafeArea(edges: .top))
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let provider: ProviderID
    let root: URL

    private var isUser: Bool { message.role == .user }

    var body: some View {
        Group {
            if isUser {
                VStack(alignment: .trailing, spacing: 4) {
                    MarkdownMessageText(message: message)
                        .textSelection(.enabled)
                        .font(Theme.sans(13))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Theme.bubble, in: RoundedRectangle(cornerRadius: 14))
                    if let files = message.attachments, !files.isEmpty { AttachmentStrip(attachments: files, root: root) }
                }
                .padding(.leading, 80)
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        ProviderIcon(provider: provider, size: 14)
                        Text(provider.name).metaText()
                        if message.state == .streaming { RunningDot() }
                    }
                    MarkdownMessageText(message: message)
                        .textSelection(.enabled)
                        .font(Theme.serif(14))
                        .lineSpacing(5)
                        .foregroundStyle(message.state == .failed ? Theme.bad : Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(message.text.isEmpty && message.state == .streaming ? 0.65 : 1)
                    if let files = message.attachments, !files.isEmpty { AttachmentStrip(attachments: files, root: root) }
                    HStack(spacing: 8) {
                        if let ids = message.actualModelIDs, !ids.isEmpty {
                            Text("实际模型：" + ids.map { ModelCatalog.claudeName(for: $0) }.joined(separator: "、"))
                                .metaText()
                                .help(ids.joined(separator: ", "))
                        }
                        if !message.text.isEmpty {
                            ReplyExportMenu(text: message.text, title: "\(provider.name) 回复")
                                .disabled(message.state == .streaming)
                        }
                    }
                }
                .padding(.trailing, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contextMenu {
            Button("复制") { copy(message.text) }
        }
        .copyable([message.text])
    }

    private func copy(_ value: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #endif
    }
}

private struct MarkdownMessageText: View {
    let message: ChatMessage

    var body: some View {
        if message.text.isEmpty && message.state == .streaming {
            Text("正在生成…")
        } else if let rendered = try? AttributedString(
            markdown: message.text,
            options: .init(interpretedSyntax: .full)
        ) {
            Text(rendered)
        } else {
            Text(message.text)
        }
    }
}

private struct Composer: View {
    @Binding var text: String
    let isRunning: Bool
    let attachments: [ChatAttachment]
    let root: URL
    let isImporting: Bool
    let supportsImages: Bool
    let onAttach: () -> Void
    let onRemove: (UUID) -> Void
    let onSend: () -> Void
    let onStop: () -> Void
    @StateObject private var speech = SpeechRecognitionController(localeIdentifier: "zh-CN")

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !attachments.isEmpty {
                AttachmentStrip(attachments: attachments, root: root, onRemove: onRemove)
                AttachmentNotice(attachments: attachments, supportsImages: supportsImages)
            }
            if isImporting { Text("正在读取附件…").metaText() }
            TextEditor(text: $text)
                .font(Theme.sans(13))
                .foregroundStyle(Theme.text)
                .scrollContentBackground(.hidden)
                .frame(height: 56)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("发送消息，或拖入图片、PDF、Word…")
                            .font(Theme.sans(13))
                            .foregroundStyle(Theme.muted2)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            HStack(spacing: 6) {
                Button("附件", action: onAttach)
                    .buttonStyle(GhostButtonStyle())
                    .disabled(isRunning || isImporting)
                DictationButton(text: $text, controller: speech, isEnabled: !isRunning && !isImporting)
                SpeechLocalePicker(controller: speech)
                Text("⌘↩ 发送")
                    .metaText()
                    .foregroundStyle(Theme.muted2)
                Spacer()
                if isRunning {
                    Button("■", action: onStop)
                        .buttonStyle(SendButtonStyle(stop: true))
                        .help("停止")
                } else {
                    Button { speech.stop(); onSend() } label: { Text("↑") }
                        .buttonStyle(SendButtonStyle())
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(isImporting || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty))
                        .help("发送消息")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border2, lineWidth: 0.5))
        .frame(maxWidth: 820)
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .onDisappear { speech.stop() }
    }
}

private struct ChatEmptyState: View {
    let provider: ProviderID
    var body: some View {
        VStack(spacing: 10) {
            ProviderIcon(provider: provider, size: 36)
            Text("开始与 \(provider.name) 对话")
                .titleText(18)
            Text("这是一个独立会话。消息和 Session ID 会单独保存。")
                .font(Theme.sans(12))
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct WelcomeView: View {
    let onNewSession: (ProviderID) -> Void
    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("欢迎使用 AgentDesk")
                    .titleText(24)
                Text("为每个模型保留独立会话。选择一个模型开始。")
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.muted)
            }
            HStack(spacing: 8) {
                ForEach(ProviderID.allCases) { provider in
                    Button {
                        onNewSession(provider)
                    } label: {
                        HStack(spacing: 6) { ProviderIcon(provider: provider, size: 15); Text(provider.name) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct RenameSessionView: View {
    @Binding var title: String
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("重命名会话")
                .font(Theme.sans(15, weight: .semibold))
            TextField("会话名称", text: $title)
                .themedField()
                .focused($focused)
                .onSubmit(onSave)
            HStack(spacing: 8) {
                Spacer()
                Button("取消", action: onCancel)
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: onSave)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .themedSurface(Theme.card)
        .presentationBackground(Theme.card)
        .onAppear { focused = true }
    }
}

/// The square send / stop button of the composer (canvas `.send`).
struct SendButtonStyle: ButtonStyle {
    var stop = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: stop ? 10 : 15, weight: .semibold))
            .foregroundStyle(stop ? Theme.bg : Theme.onPrimary)
            .frame(width: 28, height: 28)
            .background(stop ? Theme.text : Theme.primary, in: RoundedRectangle(cornerRadius: 8))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

extension ProviderID {
    var tint: Color { Theme.provider(self) }
}
