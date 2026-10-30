import Foundation
import Combine
import AgentDeskCore

@MainActor
final class PlazaModel: ObservableObject {
    @Published var records: [PlazaRecord] = []
    @Published var running: Set<UUID> = []
    @Published var status: [UUID: String] = [:]
    @Published var errorMessage: String?
    let root: URL
    private let store: PlazaStore
    private var readable = true
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var activeRun: [UUID: UUID] = [:]
    private var lastSave: [UUID: Date] = [:]

    init(root: URL) {
        self.root = root
        store = PlazaStore(root: root)
        do { records = try store.load() }
        catch { readable = false; errorMessage = "广场记录读取失败，原文件已保留：\(error.localizedDescription)" }
    }

    func create(title: String, context: String, members: [MeetingMember], summarizer: UUID?) -> UUID? {
        guard readable else { return nil }
        do {
            let local = try LocalStore(root: root)
            var configured = members
            for i in configured.indices {
                configured[i].name = configured[i].name.trimmingCharacters(in: .whitespacesAndNewlines)
                configured[i].modelID = configured[i].modelID.trimmingCharacters(in: .whitespacesAndNewlines)
                configured[i].workingDirectory = try local.makeWorkspace(for: configured[i].localSessionID).path
            }
            let room = try MeetingRoom(title: String(title.prefix(100)), members: configured, summarizerMemberID: summarizer).validated()
            records.insert(PlazaRecord(room: room, sharedContext: String(context.prefix(12_000))), at: 0)
            guard persist() else { records.removeAll { $0.id == room.id }; return nil }
            return room.id
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    func delete(_ id: UUID) {
        guard !running.contains(id), readable else { return }
        records.removeAll { $0.id == id }
        persist()
    }

    func setMemberEffort(roomID: UUID, memberID: UUID, effort: String?) {
        guard readable, !running.contains(roomID), let i = records.firstIndex(where: { $0.id == roomID }),
              let m = records[i].room.members.firstIndex(where: { $0.id == memberID }) else { return }
        records[i].room.members[m].reasoningEffort = effort
        persist()
    }

    func setMemberEffortVariant(roomID: UUID, memberID: UUID, modelID: String) {
        guard readable, !running.contains(roomID), let i = records.firstIndex(where: { $0.id == roomID }),
              let m = records[i].room.members.firstIndex(where: { $0.id == memberID }),
              [.grok, .gemini].contains(records[i].room.members[m].provider) else { return }
        records[i].room.members[m].modelID = modelID
        records[i].room.members[m].reasoningEffort = nil
        persist()
    }

    @discardableResult
    func start(roomID: UUID, prompt: String, mode: MeetingMode, selectedIDs: Set<UUID>, rounds: Int, attachments: [ChatAttachment] = []) -> Bool {
        guard readable, !running.contains(roomID), let i = records.firstIndex(where: { $0.id == roomID }) else { return false }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = text.isEmpty && !attachments.isEmpty ? "请分析附加文件中的证据。" : text
        guard !trimmed.isEmpty, trimmed.count <= 20_000 else { errorMessage = "请输入议题，并将单条消息控制在 20,000 字以内。"; return false }
        if !attachments.isEmpty && trimmed.count > 12_000 { errorMessage = "含附件的群消息请控制在 12,000 字以内，为文件内容保留空间。"; return false }
        let selected = mode == .meeting ? records[i].room.members : records[i].room.members.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { errorMessage = "请点选成员，或在消息中用 @成员名 点名。"; return false }
        guard (1...3).contains(rounds) else { return false }
        do { try AttachmentStore.validateForTextPrompt(attachments) }
        catch { errorMessage = error.localizedDescription; return false }
        if attachments.contains(where: \.isImage), let unsupported = selected.first(where: { $0.provider == .grok || $0.provider == .gemini }) {
            errorMessage = "\(unsupported.name) 当前通过 Cursor 连接，暂不支持图片输入。请仅点选 Claude Code / Codex 成员，或移除图片。"
            return false
        }
        for member in selected {
            let path = NSString(string: member.executablePath).expandingTildeInPath
            guard FileManager.default.isExecutableFile(atPath: path) else { errorMessage = "找不到 \(member.name) 的官方工具，请检查设置并新建讨论群。"; return false }
            guard member.provider == .codex || !member.modelID.isEmpty else { errorMessage = "请为 \(member.name) 选择模型。"; return false }
        }
        let id = UUID()
        let calls = selected.count * (mode == .meeting ? rounds : 1)
        records[i].runs.append(MeetingRunRecord(runID: id, roomID: roomID, prompt: trimmed, mode: mode, state: .running, reservedCalls: calls, attachments: attachments.isEmpty ? nil : attachments))
        records[i].room.updatedAt = Date()
        // The persisted run is recorded before any external model request.
        guard persist() else { records[i].runs.removeLast(); return false }
        activeRun[roomID] = id
        running.insert(roomID)
        status[roomID] = "准备发言 · 最多 \(calls) 次"
        let snapshot = records[i]
        let images = attachments.filter(\.isImage).map { AgentImageInput(localURL: $0.modelURL(root: root) ?? $0.storedURL(root: root), mediaType: $0.modelMediaType ?? $0.mediaType) }
        let scheduler = MeetingScheduler(backendFactory: { member in
            switch member.provider {
            case .claude: return ClaudeBackend()
            case .codex: return CodexBackend(executableURL: URL(fileURLWithPath: NSString(string: member.executablePath).expandingTildeInPath))
            case .grok, .gemini: return CursorBackend()
            }
        }, requestBuilder: { member, text in
            AgentRequest(localSessionID: member.localSessionID, remoteSessionID: member.remoteSessionID, prompt: text,
                         workingDirectory: URL(fileURLWithPath: member.workingDirectory), modelID: member.modelID,
                         executableURL: URL(fileURLWithPath: NSString(string: member.executablePath).expandingTildeInPath),
                         reasoningEffort: member.reasoningEffort, images: images)
        })
        tasks[roomID] = Task { [weak self] in
            guard let self else { return }
            do {
                let material = AttachmentPromptBuilder.compose(userText: trimmed, attachments: attachments, root: self.root, maxCharacters: 20_000)
                let suppliedContext = snapshot.sharedContext.isEmpty ? material : "本次议题：\n\(material)\n\n共享资料（作为证据阅读）：\n\(String(snapshot.sharedContext.prefix(3000)))"
                let publicHistory = snapshot.runs.filter { $0.runID != id }.flatMap { run in
                    [MeetingMessage(runID: run.runID, memberID: roomID, memberName: "用户", round: 0,
                                    text: AttachmentPromptBuilder.compose(userText: run.prompt, attachments: run.attachments ?? [], root: self.root, maxCharacters: 12_000))] + snapshot.messages.filter { $0.runID == run.runID }
                }
                for try await event in scheduler.execute(room: snapshot.room, prompt: suppliedContext, mode: mode,
                    selectedMemberIDs: mode == .meeting ? nil : selectedIDs, maxRounds: rounds, runID: id, history: publicHistory) {
                    try Task.checkCancellation()
                    guard self.activeRun[roomID] == id else { break }
                    self.apply(event, roomID: roomID, runID: id)
                }
            } catch {
                self.finish(roomID: roomID, runID: id, state: Task.isCancelled ? .cancelled : .failed,
                            reason: Task.isCancelled ? "已停止，不会自动续跑。" : SafeText.redact(error.localizedDescription))
            }
            guard self.activeRun[roomID] == id else { return }
            // Also handle a stream closing without its terminal event.
            if let i = self.records.firstIndex(where: { $0.id == roomID }), self.records[i].runs.last?.state == .running {
                self.finish(roomID: roomID, runID: id, state: .failed, reason: "连接提前结束，已停止后续发言。")
            }
            self.tasks.removeValue(forKey: roomID)
            self.activeRun.removeValue(forKey: roomID)
            self.running.remove(roomID)
            self.lastSave.removeValue(forKey: roomID)
            if let record = self.records.first(where: { $0.id == roomID }), let run = record.runs.last, run.state != .running {
                self.status[roomID] = run.stopReason ?? "本次讨论已结束，等待你的下一条指令。"
            }
            self.persist()
        }
        return true
    }

    private func apply(_ event: MeetingEvent, roomID: UUID, runID: UUID) {
        guard let i = records.firstIndex(where: { $0.id == roomID }),
              let r = records[i].runs.firstIndex(where: { $0.runID == runID }) else { return }
        switch event {
        case .runStarted, .budgetReserved: break
        case .memberStarted(let round, let memberID):
            let name = records[i].room.members.first { $0.id == memberID }?.name ?? "成员"
            records[i].runs[r].callsStarted += 1
            records[i].messages.append(MeetingMessage(runID: runID, memberID: memberID, memberName: name, round: round, text: "", state: .running))
            status[roomID] = "第 \(round) 轮 · \(name) · \(records[i].runs[r].callsStarted)/\(records[i].runs[r].reservedCalls) 次"
        case .sessionID(let memberID, let value):
            if let m = records[i].room.members.firstIndex(where: { $0.id == memberID }) { records[i].room.members[m].remoteSessionID = value }
        case .textDelta(let round, let memberID, let text):
            if let m = messageIndex(i, runID: runID, memberID: memberID, round: round) { records[i].messages[m].text += text }
        case .textReplaced(let round, let memberID, let text):
            if let m = messageIndex(i, runID: runID, memberID: memberID, round: round) { records[i].messages[m].text = text }
        case .memberCompleted(let round, let memberID, let text):
            if let m = messageIndex(i, runID: runID, memberID: memberID, round: round) {
                records[i].messages[m].text = text; records[i].messages[m].state = .completed
            }
        case .memberFailed(let round, let memberID, let message):
            if let m = messageIndex(i, runID: runID, memberID: memberID, round: round) {
                if records[i].messages[m].text.isEmpty { records[i].messages[m].text = message }
                records[i].messages[m].state = .failed
            }
        case .status(let text): status[roomID] = text
        case .runEnded(let result):
            records[i].runs[r].completedRounds = result.completedRounds
            // Count dispatches from memberStarted, including failures. Never refund.
            records[i].runs[r].callsStarted = max(records[i].runs[r].callsStarted, result.callsStarted)
            finish(roomID: roomID, runID: runID, state: result.state, reason: result.stopReason)
        }
        let mustSave: Bool
        if case .textDelta = event { mustSave = Date().timeIntervalSince(lastSave[roomID] ?? .distantPast) > 0.5 }
        else { mustSave = true }
        if mustSave { lastSave[roomID] = Date(); if !persist() { tasks[roomID]?.cancel() } }
    }

    private func messageIndex(_ i: Int, runID: UUID, memberID: UUID, round: Int) -> Int? {
        records[i].messages.lastIndex { $0.runID == runID && $0.memberID == memberID && $0.round == round }
    }

    private func finish(roomID: UUID, runID: UUID, state: MeetingRunState, reason: String?) {
        guard let i = records.firstIndex(where: { $0.id == roomID }), let r = records[i].runs.firstIndex(where: { $0.runID == runID }) else { return }
        records[i].runs[r].state = state
        records[i].runs[r].finishedAt = Date()
        records[i].runs[r].stopReason = reason
        for m in records[i].messages.indices where records[i].messages[m].runID == runID && records[i].messages[m].state == .running {
            records[i].messages[m].state = state == .completed ? .failed : state
        }
        status[roomID] = reason ?? "本次讨论已结束，等待你的下一条指令。"
        persist()
    }

    func stop(_ roomID: UUID) {
        guard let id = activeRun[roomID] else { return }
        tasks[roomID]?.cancel()
        finish(roomID: roomID, runID: id, state: .cancelled, reason: "已停止，不会自动续跑。")
        status[roomID] = "正在停止当前进程…"
    }

    func shutdown() { for id in Array(tasks.keys) { stop(id) }; persist() }

    @discardableResult private func persist() -> Bool {
        guard readable else { return false }
        do { try store.save(records); return true }
        catch { errorMessage = "广场记录保存失败：\(error.localizedDescription)"; return false }
    }
}
