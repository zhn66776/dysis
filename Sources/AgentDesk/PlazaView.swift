import SwiftUI
import AppKit
import AgentDeskCore
import UniformTypeIdentifiers

struct PlazaDetail: View {
    @ObservedObject var model: PlazaModel
    @ObservedObject var appModel: AppModel
    @ObservedObject var attachments: AttachmentDrafts
    let roomID: UUID
    @Binding var draft: String
    @State private var mode: MeetingMode = .manual
    @State private var rounds = 3
    @State private var recipients: Set<UUID> = []
    @State private var showMembers = true
    @State private var selectionInitialized = false
    @State private var dropTargeted = false
    @StateObject private var speech = SpeechRecognitionController(localeIdentifier: "zh-CN")
    private var record: PlazaRecord? { model.records.first { $0.id == roomID } }
    private var isRunning: Bool { model.running.contains(roomID) }

    var body: some View {
        if let record {
            VStack(spacing: 0) {
                header(record)
                Divider()
                HStack(spacing: 0) {
                    transcript(record)
                    if showMembers { Divider(); members(record).frame(width: 225) }
                }
                Divider()
                composer(record)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .onAppear { if !selectionInitialized { recipients = Set(record.room.members.map(\.id)); selectionInitialized = true } }
            .onDisappear { speech.stop() }
            .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 14).stroke(.tint, lineWidth: 3).padding(5).allowsHitTesting(false) } }
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted) { providers in
                guard !isRunning else { return false }
                return attachments.drop(providers, into: roomID)
            }
        }
    }

    private func header(_ record: PlazaRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.3.sequence.fill").font(.title2).foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.room.title).font(.headline)
                Text(model.status[roomID] ?? "点名回答，或召开最多三轮的会议")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if isRunning { ProgressView().controlSize(.small) }
            Button { copyTranscript(record) } label: { Image(systemName: "doc.on.doc") }.help("复制讨论记录")
            ReplyExportMenu(text: transcriptText(record), title: record.room.title).disabled(record.runs.isEmpty || isRunning)
            Button { showMembers.toggle() } label: { Image(systemName: "sidebar.right") }.help("成员与共享资料")
        }.padding(.horizontal, 22).padding(.vertical, 15)
    }

    private func transcript(_ record: PlazaRecord) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                if record.runs.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 42)).foregroundStyle(.indigo.opacity(0.7))
                        Text("让不同观点进入同一场讨论").font(.title3.weight(.semibold))
                        Text("成员各有独立会话。第一轮各自分析，后续交换意见，最后一轮形成结论并保留分歧。")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 430)
                        Text("每次由你发起 · 最多 3 轮 · 随时停止").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.top, 90).padding(.horizontal, 24)
                } else {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(record.runs, id: \.runID) { run in
                            HStack(alignment: .top, spacing: 10) {
                                Spacer(minLength: 44)
                                VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Label(run.mode == .meeting ? "你 · 召开会议" : "你 · 点名发言", systemImage: "person.crop.circle")
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text("\(run.callsStarted)/\(run.reservedCalls) 次发言").font(.caption).foregroundStyle(.secondary)
                                }
                                Text(run.prompt).textSelection(.enabled)
                                    if let files = run.attachments, !files.isEmpty { AttachmentStrip(attachments: files, root: model.root) }
                                }.padding(14).background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 16))
                                Image(systemName: "person.fill").font(.caption).foregroundStyle(.secondary).frame(width: 24, height: 24)
                            }.frame(maxWidth: .infinity, alignment: .trailing)
                            ForEach(record.messages.filter { $0.runID == run.runID }) { message in
                                messageRow(message, record: record).id(message.id)
                            }
                            if run.state != .running {
                                Label(run.stopReason ?? "本次已结束，等待你的下一条指令。", systemImage: run.state == .completed ? "checkmark.circle" : "pause.circle")
                                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(24).frame(maxWidth: 880).frame(maxWidth: .infinity)
                }
            }
            .onChange(of: record.messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            .defaultScrollAnchor(.bottom)
        }
    }

    private func messageRow(_ message: MeetingMessage, record: PlazaRecord) -> some View {
        let member = record.room.members.first { $0.id == message.memberID }
        return HStack(alignment: .top, spacing: 10) {
            if let member { ProviderIcon(provider: member.provider, size: 24) }
            else { Image(systemName: "person.fill").foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(message.memberName).fontWeight(.semibold)
                Text("第 \(message.round) 轮").foregroundStyle(.secondary)
                if message.state == .running { ProgressView().controlSize(.mini) }
                if message.state != .running && message.state != .completed { Text("已中断").foregroundStyle(.orange) }
                Spacer()
            }.font(.caption)
            Text(message.text == MeetingScheduler.passSentinel ? "暂无补充，交还发言。" : (message.text.isEmpty ? (message.state == .running ? "正在思考…" : "本次发言已停止。") : message.text))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if !message.text.isEmpty { ReplyExportMenu(text: message.text, title: "\(message.memberName) · 第 \(message.round) 轮").disabled(message.state == .running) }
            }.padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.06), lineWidth: 1))
            Spacer(minLength: 36)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2)
    }

    private func members(_ record: PlazaRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("成员分工").font(.headline)
                ForEach(record.room.members) { member in
                    VStack(alignment: .leading, spacing: 5) {
                        Label { Text(member.name) } icon: { ProviderIcon(provider: member.provider, size: 20) }
                            .font(.subheadline.weight(.semibold))
                        Text(member.role.isEmpty ? "参与讨论" : member.role).font(.caption)
                        Text(member.modelID.isEmpty ? "\(member.provider.name) · 官方默认模型" : member.modelID).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        EffortControl(model: appModel, provider: member.provider,
                                      modelID: Binding(get: { member.modelID }, set: { model.setMemberEffortVariant(roomID: roomID, memberID: member.id, modelID: $0) }),
                                      effort: Binding(get: { member.reasoningEffort }, set: { model.setMemberEffort(roomID: roomID, memberID: member.id, effort: $0) }), compact: true)
                            .font(.caption2).disabled(isRunning)
                        if member.id == record.room.summarizerMemberID { Text("最后一轮负责汇总").font(.caption2).foregroundStyle(.indigo) }
                    }
                }
                Divider()
                Text("共享资料").font(.subheadline.weight(.semibold))
                Text(record.sharedContext.isEmpty ? "在消息里补充资料，或从 MCP 工具带入结果。私聊记录不会自动进入广场。" : record.sharedContext)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Divider()
                Text("运行上限").font(.subheadline.weight(.semibold))
                Text("单次发言 2 分钟，整场 15 分钟。最多 3 轮，无自动重试。成员的 @ 请求仅作为讨论内容。").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
        }.background(.quaternary.opacity(0.18))
    }

    private func composer(_ record: PlazaRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !attachments.files[roomID, default: []].isEmpty {
                AttachmentStrip(attachments: attachments.files[roomID, default: []], root: model.root, onRemove: { attachments.remove($0, from: roomID) })
                AttachmentNotice(attachments: attachments.files[roomID, default: []],
                                 supportsImages: record.room.members.filter { mode == .meeting || effectiveRecipients(record).contains($0.id) }.allSatisfy { $0.provider == .claude || $0.provider == .codex })
            }
            if attachments.importing.contains(roomID) { HStack { ProgressView().controlSize(.mini); Text("正在读取附件…").font(.caption).foregroundStyle(.secondary) } }
            HStack(spacing: 14) {
                Picker("发送方式", selection: $mode) {
                    Text("点名群聊").tag(MeetingMode.manual)
                    Text("召开会议").tag(MeetingMode.meeting)
                }.pickerStyle(.segmented).frame(width: 230).disabled(isRunning)
                if mode == .meeting {
                    Picker("轮数", selection: $rounds) { ForEach(1...3, id: \.self) { Text("\($0) 轮").tag($0) } }.frame(width: 120).disabled(isRunning)
                }
                Spacer()
                Text("最多 \(mode == .meeting ? record.room.members.count * rounds : effectiveRecipients(record).count) 次发言")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if mode == .manual {
                HStack(spacing: 8) {
                    ForEach(record.room.members) { member in
                        Toggle("@\(member.name)", isOn: Binding(get: { recipients.contains(member.id) }, set: { if $0 { recipients.insert(member.id) } else { recipients.remove(member.id) } }))
                            .toggleStyle(.button).controlSize(.small).disabled(isRunning)
                    }
                    Spacer()
                }
            }
            TextEditor(text: $draft).font(.body).scrollContentBackground(.hidden).frame(minHeight: 62, maxHeight: 120)
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty { Text("输入议题或补充资料；可用 @成员名 或 @everyone…").foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false) }
                }
            HStack {
                Button { attachments.choose(for: roomID) } label: { Label("附件", systemImage: "paperclip") }
                    .disabled(isRunning || attachments.importing.contains(roomID))
                DictationButton(text: $draft, controller: speech, isEnabled: !isRunning && !attachments.importing.contains(roomID))
                SpeechLocalePicker(controller: speech).labelsHidden().frame(width: 108)
                Spacer()
                if isRunning {
                    Button { model.stop(roomID) } label: { Label("停止全部", systemImage: "stop.fill") }.tint(.orange)
                } else {
                    Button(mode == .manual ? "发送" : "开始会议") { speech.stop(); send(record) }.buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(attachments.importing.contains(roomID) || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.files[roomID, default: []].isEmpty))
                }
            }
            HStack {
                Text(mode == .manual ? "所选成员各回复一次，然后等待你继续。" : (rounds == 1 ? "一轮独立分析；两轮以上在最后一轮汇总。" : "所有成员参与；汇总计入最后一轮，不增加调用。"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }.padding(.horizontal, 22).padding(.vertical, 14).background(.bar)
    }

    private func effectiveRecipients(_ record: PlazaRecord) -> Set<UUID> {
        MeetingRecipients.resolve(prompt: draft, members: record.room.members, selected: recipients)
    }

    private func send(_ record: PlazaRecord) {
        guard !attachments.importing.contains(roomID) else { return }
        if model.start(roomID: roomID, prompt: draft, mode: mode, selectedIDs: effectiveRecipients(record), rounds: rounds,
                       attachments: attachments.files[roomID, default: []]) { draft = ""; attachments.clear(roomID) }
    }

    private func copyTranscript(_ record: PlazaRecord) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(transcriptText(record), forType: .string)
    }

    private func transcriptText(_ record: PlazaRecord) -> String {
        var text = "# \(record.room.title)\n"
        for run in record.runs {
            text += "\n你：\(run.prompt)\n"
            for m in record.messages where m.runID == run.runID { text += "\n\(m.memberName) · 第 \(m.round) 轮\n\(m.text)\n" }
        }
        return text
    }
}

struct NewPlazaView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var plaza: PlazaModel
    let onCreated: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var context = ""
    @State private var members: [MeetingMember] = []
    @State private var summarizer: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建广场讨论").font(.title2.weight(.semibold))
            Text("2–4 位成员，各自保留模型、角色与独立会话。").font(.callout).foregroundStyle(.secondary)
            TextField("讨论名称，例如 SSS 实验评审", text: $title).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach($members) { $member in
                        GroupBox {
                            VStack(spacing: 9) {
                                HStack {
                                    TextField("成员名（用于 @点名）", text: $member.name).textFieldStyle(.roundedBorder)
                                    Picker("模型来源", selection: $member.provider) {
                                        ForEach(ProviderID.allCases) { provider in
                                            Label { Text(provider.name) } icon: { ProviderIcon(provider: provider, size: 16) }.tag(provider)
                                        }
                                    }.frame(width: 210)
                                        .onChange(of: member.provider) { _, value in member.modelID = model.configuration[value].modelID; member.executablePath = model.configuration[value].executablePath; member.reasoningEffort = model.configuration[value].reasoningEffort }
                                    Button { members.removeAll { $0.id == member.id }; if summarizer == member.id { summarizer = members.last?.id } } label: { Image(systemName: "minus.circle") }.disabled(members.count <= 2)
                                }
                                TextField("职责，例如检查数据划分、质疑评估证据", text: $member.role).textFieldStyle(.roundedBorder)
                                HStack {
                                    TextField("模型 ID（Codex 留空可用官方默认值）", text: Binding(get: { member.modelID }, set: { member.modelID = $0; member.reasoningEffort = nil })).textFieldStyle(.roundedBorder)
                                    Menu("选择模型") {
                                        ForEach(model.availableModels[member.provider] ?? [], id: \.self) { id in
                                            Button(member.provider == .claude ? ModelCatalog.claudeName(for: id) : id) { member.modelID = id; member.reasoningEffort = nil }
                                        }
                                    }.fixedSize()
                                }
                                EffortControl(model: model, provider: member.provider, modelID: $member.modelID, effort: $member.reasoningEffort)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(4)
                        }
                    }
                    Button { addMember(.grok, name: "成员\(members.count + 1)", role: "独立审阅与补充证据") } label: { Label("添加成员", systemImage: "plus") }.disabled(members.count >= 4)
                    Picker("最后一轮汇总", selection: $summarizer) { ForEach(members) { Text($0.name).tag(Optional($0.id)) } }
                    Text("共享资料与讨论目标").font(.subheadline.weight(.semibold))
                    TextEditor(text: $context).font(.body).frame(height: 90).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    Text("仅把你在这里提供的资料及群消息带入讨论；已有私聊不会被复制。创建讨论不会发送模型请求。").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = plaza.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer(); Button("取消") { dismiss() }
                Button("创建讨论") {
                    if let id = plaza.create(title: title.trimmingCharacters(in: .whitespacesAndNewlines), context: context, members: members, summarizer: summarizer) { onCreated(id); dismiss() }
                }.buttonStyle(.borderedProminent).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || members.count < 2)
            }
        }.padding(24).frame(width: 690, height: 650)
            .onAppear {
                if members.isEmpty { addMember(.claude, name: "分析员", role: "独立分析方案、依据与风险"); addMember(.codex, name: "审查员", role: "检查假设与证据，提出反例，汇总结论和分歧"); summarizer = members.last?.id }
            }
    }

    private func addMember(_ provider: ProviderID, name: String, role: String) {
        members.append(MeetingMember(name: name, role: role, provider: provider, modelID: model.configuration[provider].modelID, workingDirectory: "", executablePath: model.configuration[provider].executablePath, reasoningEffort: model.configuration[provider].reasoningEffort))
    }
}
