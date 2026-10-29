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
                Hairline()
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        transcript(record)
                        composer(record)
                    }
                    if showMembers { Hairline(vertical: true); members(record).frame(width: 240) }
                }
            }
            .background(Theme.bg)
            .onAppear { if !selectionInitialized { recipients = Set(record.room.members.map(\.id)); selectionInitialized = true } }
            .onDisappear { speech.stop() }
            .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.muted, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).padding(6).allowsHitTesting(false) } }
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted) { providers in
                guard !isRunning else { return false }
                return attachments.drop(providers, into: roomID)
            }
        }
    }

    private func header(_ record: PlazaRecord) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: -4) {
                ForEach(record.room.members.prefix(4)) { member in
                    ProviderIcon(provider: member.provider, size: 18).background(Theme.panel, in: Circle())
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(record.room.title).font(Theme.sans(14, weight: .medium))
                Text(model.status[roomID] ?? "点名回答，或召开最多三轮的会议")
                    .metaText().foregroundStyle(isRunning ? Theme.run : Theme.muted).lineLimit(2)
            }
            Spacer()
            if isRunning { RunningDot() }
            Button("复制记录") { copyTranscript(record) }.buttonStyle(GhostButtonStyle()).help("复制讨论记录")
            ReplyExportMenu(text: transcriptText(record), title: record.room.title).disabled(record.runs.isEmpty || isRunning)
            Button("成员") { showMembers.toggle() }.buttonStyle(GhostButtonStyle(selected: showMembers)).help("成员与共享资料")
        }.padding(.horizontal, 20).padding(.vertical, 12).background(Theme.panel)
    }

    private func transcript(_ record: PlazaRecord) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                if record.runs.isEmpty {
                    VStack(spacing: 10) {
                        Text("让不同观点进入同一场讨论").titleText(18)
                        Text("成员各有独立会话。第一轮各自分析，后续交换意见，最后一轮形成结论并保留分歧。")
                            .font(Theme.sans(12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: 430)
                        Text("每次由你发起 · 最多 3 轮 · 随时停止").metaText()
                    }.frame(maxWidth: .infinity).padding(.top, 90).padding(.horizontal, 24)
                } else {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(record.runs, id: \.runID) { run in
                            VStack(alignment: .trailing, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(run.mode == .meeting ? "你 · 召开会议" : "你 · 点名发言")
                                    Text("\(run.callsStarted)/\(run.reservedCalls) 次发言")
                                }.metaText()
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(run.prompt).font(Theme.sans(13)).textSelection(.enabled)
                                    if let files = run.attachments, !files.isEmpty { AttachmentStrip(attachments: files, root: model.root) }
                                }.padding(.horizontal, 12).padding(.vertical, 8).background(Theme.bubble, in: RoundedRectangle(cornerRadius: 14))
                            }.padding(.leading, 80).frame(maxWidth: .infinity, alignment: .trailing)
                            ForEach(record.messages.filter { $0.runID == run.runID }) { message in
                                messageRow(message, record: record).id(message.id)
                            }
                            if run.state != .running {
                                Text((run.state == .completed ? "✓ " : "") + (run.stopReason ?? "本次已结束，等待你的下一条指令。"))
                                    .metaText().foregroundStyle(run.state == .completed ? Theme.ok : Theme.muted).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .center)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(24).frame(maxWidth: 800).frame(maxWidth: .infinity)
                }
            }
            .onChange(of: record.messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            .defaultScrollAnchor(.bottom)
        }
    }

    private func messageRow(_ message: MeetingMessage, record: PlazaRecord) -> some View {
        let member = record.room.members.first { $0.id == message.memberID }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let member { ProviderIcon(provider: member.provider, size: 14) }
                Text(message.memberName).font(Theme.sans(12, weight: .medium)).foregroundStyle(member.map { Theme.providerInk($0.provider) } ?? Theme.text)
                Text("第 \(message.round) 轮").metaText()
                if message.state == .running { RunningDot() }
                if message.state != .running && message.state != .completed { Text("已中断").metaText().foregroundStyle(Theme.warn) }
                Spacer()
            }
            Text(message.text == MeetingScheduler.passSentinel ? "暂无补充，交还发言。" : (message.text.isEmpty ? (message.state == .running ? "正在思考…" : "本次发言已停止。") : message.text))
                .font(Theme.serif(14)).lineSpacing(5).foregroundStyle(Theme.text)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if !message.text.isEmpty { ReplyExportMenu(text: message.text, title: "\(message.memberName) · 第 \(message.round) 轮").disabled(message.state == .running) }
        }.padding(.trailing, 40).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2)
    }

    private func members(_ record: PlazaRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("成员分工").sectionLabel()
                ForEach(record.room.members) { member in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            ProviderIcon(provider: member.provider, size: 14)
                            Text(member.name).font(Theme.sans(12, weight: .medium)).lineLimit(1)
                            Spacer()
                            if member.id == record.room.summarizerMemberID { Text("汇总").font(Theme.sans(10)).padding(.horizontal, 6).padding(.vertical, 1).background(Theme.card, in: RoundedRectangle(cornerRadius: 5)) }
                        }
                        .foregroundStyle(Theme.providerInk(member.provider))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Theme.providerTint(member.provider))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(member.role.isEmpty ? "参与讨论" : member.role).font(Theme.sans(11)).foregroundStyle(Theme.text)
                            Text(member.modelID.isEmpty ? "\(member.provider.name) · 官方默认模型" : member.modelID).metaText(10).textSelection(.enabled)
                            EffortControl(model: appModel, provider: member.provider,
                                          modelID: Binding(get: { member.modelID }, set: { model.setMemberEffortVariant(roomID: roomID, memberID: member.id, modelID: $0) }),
                                          effort: Binding(get: { member.reasoningEffort }, set: { model.setMemberEffort(roomID: roomID, memberID: member.id, effort: $0) }), compact: true)
                                .disabled(isRunning)
                            if member.id == record.room.summarizerMemberID { Text("最后一轮负责汇总").metaText(10) }
                        }.padding(10)
                    }
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border2, lineWidth: 0.5))
                }
                Text("共享资料").sectionLabel().padding(.top, 6)
                Text(record.sharedContext.isEmpty ? "在消息里补充资料，或从 MCP 工具带入结果。私聊记录不会自动进入广场。" : record.sharedContext)
                    .font(Theme.sans(11)).foregroundStyle(Theme.muted).textSelection(.enabled)
                Text("运行上限").sectionLabel().padding(.top, 6)
                Text("单次发言 2 分钟，整场 15 分钟。最多 3 轮，无自动重试。成员的 @ 请求仅作为讨论内容。").font(Theme.sans(11)).foregroundStyle(Theme.muted)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
        }.background(Theme.panel)
    }

    private func composer(_ record: PlazaRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.files[roomID, default: []].isEmpty {
                AttachmentStrip(attachments: attachments.files[roomID, default: []], root: model.root, onRemove: { attachments.remove($0, from: roomID) })
                AttachmentNotice(attachments: attachments.files[roomID, default: []],
                                 supportsImages: record.room.members.filter { mode == .meeting || effectiveRecipients(record).contains($0.id) }.allSatisfy { $0.provider == .claude || $0.provider == .codex })
            }
            if attachments.importing.contains(roomID) { Text("正在读取附件…").metaText() }
            HStack(spacing: 10) {
                SegmentedChoice(selection: $mode, options: [(MeetingMode.manual, "点名群聊"), (MeetingMode.meeting, "召开会议")]).disabled(isRunning)
                if mode == .meeting {
                    ThemedPicker(selection: $rounds, options: (1...3).map { ($0, "\($0) 轮") }).disabled(isRunning).help("轮数")
                }
                if mode == .manual {
                    ForEach(record.room.members) { member in
                        Toggle("@\(member.name)", isOn: Binding(get: { recipients.contains(member.id) }, set: { if $0 { recipients.insert(member.id) } else { recipients.remove(member.id) } }))
                            .toggleStyle(ChipToggleStyle()).disabled(isRunning)
                    }
                }
                Spacer()
                Text("最多 \(mode == .meeting ? record.room.members.count * rounds : effectiveRecipients(record).count) 次发言")
                    .metaText()
            }
            TextEditor(text: $draft).font(Theme.sans(13)).foregroundStyle(Theme.text).scrollContentBackground(.hidden).frame(height: 62)
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty { Text("输入议题或补充资料；可用 @成员名 或 @everyone…").font(Theme.sans(13)).foregroundStyle(Theme.muted2).padding(.leading, 5).allowsHitTesting(false) }
                }
            HStack(spacing: 6) {
                Button("附件") { attachments.choose(for: roomID) }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(isRunning || attachments.importing.contains(roomID))
                DictationButton(text: $draft, controller: speech, isEnabled: !isRunning && !attachments.importing.contains(roomID))
                SpeechLocalePicker(controller: speech)
                Text(mode == .manual ? "所选成员各回复一次，然后等待你继续。" : (rounds == 1 ? "一轮独立分析；两轮以上在最后一轮汇总。" : "所有成员参与；汇总计入最后一轮，不增加调用。"))
                    .metaText().foregroundStyle(Theme.muted2).lineLimit(1)
                Spacer()
                if isRunning {
                    Button("停止全部") { model.stop(roomID) }.buttonStyle(SecondaryButtonStyle())
                } else {
                    Button(mode == .manual ? "发送" : "开始会议") { speech.stop(); send(record) }.buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(attachments.importing.contains(roomID) || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.files[roomID, default: []].isEmpty))
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border2, lineWidth: 0.5))
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 14)
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
        VStack(alignment: .leading, spacing: 12) {
            Text("新建广场讨论").titleText(20)
            Text("2–4 位成员，各自保留模型、角色与独立会话。").font(Theme.sans(12)).foregroundStyle(Theme.muted)
            TextField("讨论名称，例如 SSS 实验评审", text: $title).themedField()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach($members) { $member in
                        VStack(spacing: 8) {
                            HStack(spacing: 8) {
                                ProviderIcon(provider: member.provider, size: 18)
                                TextField("成员名（用于 @点名）", text: $member.name).themedField()
                                ThemedMenu(title: member.provider.name) {
                                    ForEach(ProviderID.allCases) { provider in
                                        Button { member.provider = provider } label: {
                                            Label { Text(provider.name) } icon: { ProviderIcon(provider: provider, size: 16) }
                                        }
                                    }
                                }
                                .help("模型来源")
                                .onChange(of: member.provider) { _, value in member.modelID = model.configuration[value].modelID; member.executablePath = model.configuration[value].executablePath; member.reasoningEffort = model.configuration[value].reasoningEffort }
                                Button("移除") { members.removeAll { $0.id == member.id }; if summarizer == member.id { summarizer = members.last?.id } }
                                    .buttonStyle(GhostButtonStyle()).disabled(members.count <= 2)
                            }
                            TextField("职责，例如检查数据划分、质疑评估证据", text: $member.role).themedField()
                            HStack(spacing: 8) {
                                TextField("模型 ID（Codex 留空可用官方默认值）", text: Binding(get: { member.modelID }, set: { member.modelID = $0; member.reasoningEffort = nil })).themedField(mono: true)
                                ThemedMenu(title: "选择模型") {
                                    ForEach(model.availableModels[member.provider] ?? [], id: \.self) { id in
                                        Button(member.provider == .claude ? ModelCatalog.claudeName(for: id) : id) { member.modelID = id; member.reasoningEffort = nil }
                                    }
                                }
                            }
                            EffortControl(model: model, provider: member.provider, modelID: $member.modelID, effort: $member.reasoningEffort)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .themedCard(padding: 12)
                    }
                    Button("+ 添加成员") { addMember(.grok, name: "成员\(members.count + 1)", role: "独立审阅与补充证据") }
                        .buttonStyle(GhostButtonStyle()).disabled(members.count >= 4)
                    ThemedRow(label: "最后一轮汇总") {
                        ThemedPicker(selection: $summarizer, options: members.map { (Optional($0.id), $0.name) })
                    }
                    Text("共享资料与讨论目标").sectionLabel().padding(.top, 4)
                    TextEditor(text: $context).themedEditor().frame(height: 90)
                    Text("仅把你在这里提供的资料及群消息带入讨论；已有私聊不会被复制。创建讨论不会发送模型请求。").font(Theme.sans(11)).foregroundStyle(Theme.muted)
                }
            }
            if let error = plaza.errorMessage { Text(error).font(Theme.sans(11)).foregroundStyle(Theme.bad) }
            HStack(spacing: 8) {
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("创建讨论") {
                    if let id = plaza.create(title: title.trimmingCharacters(in: .whitespacesAndNewlines), context: context, members: members, summarizer: summarizer) { onCreated(id); dismiss() }
                }.buttonStyle(PrimaryButtonStyle()).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || members.count < 2)
            }
        }.padding(24).frame(width: 690, height: 650)
            .themedSurface()
            .presentationBackground(Theme.bg)
            .onAppear {
                if members.isEmpty { addMember(.claude, name: "分析员", role: "独立分析方案、依据与风险"); addMember(.codex, name: "审查员", role: "检查假设与证据，提出反例，汇总结论和分歧"); summarizer = members.last?.id }
            }
    }

    private func addMember(_ provider: ProviderID, name: String, role: String) {
        members.append(MeetingMember(name: name, role: role, provider: provider, modelID: model.configuration[provider].modelID, workingDirectory: "", executablePath: model.configuration[provider].executablePath, reasoningEffort: model.configuration[provider].reasoningEffort))
    }
}
