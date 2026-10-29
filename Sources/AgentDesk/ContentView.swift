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
        NavigationSplitView {
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
                onMCP: { showingMCP = true }
            )
            .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 360)
        } detail: {
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
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    showingSettings = true
                } label: {
                    Label("设置", systemImage: "slider.horizontal.3")
                }
                .help("配置各官方 CLI 与模型")
            }
        }
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
        .safeAreaInset(edge: .top, spacing: 0) {
            if let error = model.errorMessage ?? plaza.errorMessage ?? attachments.errorMessage {
                ErrorBanner(message: error) {
                    model.errorMessage = nil
                    plaza.errorMessage = nil
                    attachments.errorMessage = nil
                }
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
    @State private var pendingDelete: ChatSession?
    @State private var pendingPlazaDelete: UUID?

    private var selection: Binding<SidebarSelection?> {
        Binding(get: {
            if let id = selectedPlazaID { return .plaza(id) }
            return model.selectedSessionID.map { .chat($0) }
        }, set: { value in
            switch value {
            case .chat(let id): selectedPlazaID = nil; model.selectedSessionID = id
            case .plaza(let id): selectedPlazaID = id
            case nil: break
            }
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("AgentDesk")
                        .font(.headline)
                    Text("独立会话 · 有界协作")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索会话", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

            HStack {
                Text("会话")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(ProviderID.allCases) { provider in
                        Button {
                            selectedPlazaID = nil; onNewSession(provider)
                        } label: {
                            Label { Text(provider.name) } icon: { ProviderIcon(provider: provider, size: 16) }
                        }
                    }
                } label: {
                    Label("新建", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            Button(action: onNewPlaza) {
                Label("新建讨论", systemImage: "plus.bubble")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            List(selection: selection) {
                Section("广场") {
                    ForEach(plaza.records.filter { searchText.isEmpty || $0.room.title.localizedCaseInsensitiveContains(searchText) }) { record in
                        HStack(spacing: 10) {
                            Image(systemName: "person.3.fill").foregroundStyle(.indigo)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.room.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                Text(record.room.members.map(\.name).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if plaza.running.contains(record.id) { ProgressView().controlSize(.mini) }
                        }.padding(.vertical, 5).tag(SidebarSelection.plaza(record.id))
                            .contextMenu {
                                Button("删除讨论记录", role: .destructive) { pendingPlazaDelete = record.id }.disabled(plaza.running.contains(record.id))
                            }
                    }
                }
                Section("私聊") {
                    ForEach(sessions) { session in
                        SessionRow(session: session, isRunning: model.runningSessionIDs.contains(session.id))
                            .tag(SidebarSelection.chat(session.id))
                            .contextMenu {
                                Button { onRename(session) } label: {
                                    Label("重命名", systemImage: "pencil")
                                }
                                Divider()
                                Button(role: .destructive) { pendingDelete = session } label: {
                                    Label("删除会话", systemImage: "trash")
                                }
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            Button(action: onMCP) { Label("MCP 工具", systemImage: "puzzlepiece.extension") }.buttonStyle(.bordered).frame(maxWidth: .infinity).padding(12)
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Circle()
                    .fill(.green)
                    .frame(width: 7, height: 7)
                Text("本地运行")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(sessions.count) 个会话")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .confirmationDialog(
            "删除这个会话？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { session in
            Button("删除本地记录", role: .destructive) {
                onDelete(session.id)
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("只移除 AgentDesk 的会话记录，不会删除官方 CLI 的 Session 或工作目录文件。")
        }
        .confirmationDialog("删除讨论记录？", isPresented: Binding(get: { pendingPlazaDelete != nil }, set: { if !$0 { pendingPlazaDelete = nil } })) {
            Button("删除本地讨论记录", role: .destructive) {
                if let id = pendingPlazaDelete { plaza.delete(id); if selectedPlazaID == id { selectedPlazaID = nil } }
                pendingPlazaDelete = nil
            }
        } message: { Text("成员工作目录和官方会话仍保留。") }
    }
}

private struct SessionRow: View {
    let session: ChatSession
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 10) {
            ProviderBadge(provider: session.provider, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(session.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if isRunning {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                HStack(spacing: 5) {
                    Text(session.provider.name)
                    Text("·")
                    Text(session.modelID.isEmpty ? session.provider.runtimeName : session.modelID)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 2)
            Text(session.updatedAt, format: .relative(presentation: .named))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
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
            Divider()
            if session.messages.isEmpty {
                ChatEmptyState(provider: session.provider)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            ForEach(session.messages) { message in
                                MessageRow(message: message, provider: session.provider, root: model.dataRoot)
                                    .id(message.id)
                            }
                        }
                        .frame(maxWidth: 860, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 26)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: session.messages.count) { _, _ in
                        if let last = session.messages.last?.id {
                            withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                }
            }
            Divider()
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
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 14).stroke(.tint, lineWidth: 3).padding(5).allowsHitTesting(false) } }
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
        HStack(spacing: 12) {
            ProviderBadge(provider: session.provider, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.headline)
                HStack(spacing: 6) {
                    Text(session.provider.name)
                    Text("·")
                    Text(session.modelID.isEmpty ? session.provider.runtimeName : session.modelID)
                    if isRunning {
                        Text("·")
                        ProgressView().controlSize(.mini)
                        Text(status ?? "正在思考")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            EffortControl(model: model, provider: session.provider,
                          modelID: Binding(get: { session.modelID }, set: { model.setSessionEffortVariant(session.id, modelID: $0) }),
                          effort: Binding(get: { session.reasoningEffort }, set: { model.setSessionEffort(session.id, effort: $0) }), compact: true)
                .font(.caption).disabled(isRunning)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let provider: ProviderID
    let root: URL

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if isUser { Spacer(minLength: 64) }
            else {
                ProviderBadge(provider: provider, size: 28)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(message.role == .assistant ? provider.name : "你")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                MarkdownMessageText(message: message)
                    .textSelection(.enabled)
                    .font(.body)
                    .foregroundStyle(message.state == .failed ? .red : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(message.text.isEmpty && message.state == .streaming ? 0.65 : 1)
                if let files = message.attachments, !files.isEmpty { AttachmentStrip(attachments: files, root: root) }
                if message.state == .streaming {
                    ProgressView().controlSize(.small)
                }
                if let ids = message.actualModelIDs, !ids.isEmpty {
                    Text("实际模型：" + ids.map { ModelCatalog.claudeName(for: $0) }.joined(separator: "、"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(ids.joined(separator: ", "))
                }
                if !isUser && !message.text.isEmpty {
                    ReplyExportMenu(text: message.text, title: "\(provider.name) 回复")
                        .disabled(message.state == .streaming)
                }
            }
            .padding(14)
            .background(isUser ? Color.accentColor.opacity(0.13) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.06), lineWidth: 1))
            if isUser {
                Image(systemName: "person.fill").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary).frame(width: 28, height: 28).background(.quaternary, in: Circle())
            } else { Spacer(minLength: 56) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .contextMenu {
            Button { copy(message.text) } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
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
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                AttachmentStrip(attachments: attachments, root: root, onRemove: onRemove)
                AttachmentNotice(attachments: attachments, supportsImages: supportsImages)
            }
            if isImporting { HStack { ProgressView().controlSize(.mini); Text("正在读取附件…").font(.caption).foregroundStyle(.secondary) } }
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 54, maxHeight: 150)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("发送消息，或拖入图片、PDF、Word…")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            HStack {
                Button(action: onAttach) { Label("附件", systemImage: "paperclip") }.disabled(isRunning || isImporting)
                DictationButton(text: $text, controller: speech, isEnabled: !isRunning && !isImporting)
                SpeechLocalePicker(controller: speech).labelsHidden().frame(width: 108)
                Text("Cmd + Return 发送")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                if isRunning {
                    Button(action: onStop) {
                        Label("停止", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                } else {
                    Button { speech.stop(); onSend() } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(isImporting || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty))
                    .help("发送消息")
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.bar)
        .onDisappear { speech.stop() }
    }
}

private struct ChatEmptyState: View {
    let provider: ProviderID
    var body: some View {
        VStack(spacing: 14) {
            ProviderBadge(provider: provider, size: 54)
            Text("开始与 \(provider.name) 对话")
                .font(.title3.weight(.semibold))
            Text("这是一个独立会话。消息和 Session ID 会单独保存。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct WelcomeView: View {
    let onNewSession: (ProviderID) -> Void
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.tint)
            VStack(spacing: 7) {
                Text("欢迎使用 AgentDesk")
                    .font(.largeTitle.weight(.semibold))
                Text("为每个模型保留独立会话。选择一个模型开始。")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                ForEach(ProviderID.allCases) { provider in
                    Button {
                        onNewSession(provider)
                    } label: {
                        Label { Text(provider.name) } icon: { ProviderIcon(provider: provider, size: 18) }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("关闭", action: onDismiss)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(.orange.opacity(0.11))
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct ProviderBadge: View {
    let provider: ProviderID
    let size: CGFloat
    var body: some View {
        ProviderIcon(provider: provider, size: size)
    }
}

private struct RenameSessionView: View {
    @Binding var title: String
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("重命名会话")
                .font(.headline)
            TextField("会话名称", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(onSave)
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button("保存", action: onSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 360)
        .onAppear { focused = true }
    }
}

extension ProviderID {
    var tint: Color {
        switch self {
        case .claude: return .orange
        case .codex: return .mint
        case .grok: return .purple
        case .gemini: return .blue
        }
    }
}
