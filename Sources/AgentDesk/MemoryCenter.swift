import Foundation
import AgentDeskCore

/// One entry waiting for the user: from "记住这个" on a reply, or proposed
/// by the model through `memory_propose`. Nothing is written before
/// `confirm`. Drafts last for this launch.
struct MemoryDraft: Identifiable, Equatable {
    let id: UUID
    let sessionID: UUID
    var text: String
    let author: MemoryAuthor
    let reason: String?
    let createdAt: Date
}

/// Project memory drafts and writes (design/HARNESS.md §3 H5).
@MainActor
final class MemoryCenter: ObservableObject {
    @Published private(set) var drafts: [MemoryDraft] = []
    /// Bumped on every write, so views re-read the files.
    @Published private(set) var revision = 0
    private let exchange: MemoryProposalExchange
    private let token: String
    private var timer: Timer?
    /// The proposing model's name for a session ("Claude Code，sonnet"), nil for an unknown session.
    var describe: (UUID) -> String? = { _ in nil }

    init(root: URL, token: String) {
        exchange = MemoryProposalExchange(root: root)
        self.token = token
        // Proposals from an earlier launch carry another token and are dropped.
        _ = exchange.take()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func poll() {
        for proposal in exchange.take() where proposal.token == token {
            guard let name = describe(proposal.sessionID), drafts.count < 50 else { continue }
            drafts.append(MemoryDraft(id: proposal.id, sessionID: proposal.sessionID, text: String(proposal.text.prefix(ProjectMemory.maxEntryCharacters)),
                                      author: .model(name), reason: proposal.reason, createdAt: proposal.createdAt))
        }
    }

    /// "记住这个" on a reply: a draft the user edits down before saving.
    func remember(sessionID: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        drafts.append(MemoryDraft(id: UUID(), sessionID: sessionID, text: String(trimmed.prefix(ProjectMemory.maxEntryCharacters)), author: .user, reason: nil, createdAt: Date()))
    }

    func drafts(for sessionID: UUID) -> [MemoryDraft] { drafts.filter { $0.sessionID == sessionID } }

    /// Writes the confirmed entry and makes sure `AGENTS.md` references the memory file.
    func confirm(_ id: UUID, text: String, folder: URL, sourceTitle: String) throws {
        guard let draft = drafts.first(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return discard(id) }
        let entry = MemoryEntry(date: MemoryEntry.day(), author: draft.author, source: MemoryEntry.source(title: sourceTitle, sessionID: draft.sessionID),
                                text: String(trimmed.prefix(ProjectMemory.maxEntryCharacters)))
        try ProjectMemory(folder: folder).append(entry)
        try ProjectRules.addMemoryReference(in: folder)
        drafts.removeAll { $0.id == id }
        revision += 1
    }

    func discard(_ id: UUID) { drafts.removeAll { $0.id == id } }

    func discard(session: UUID) { drafts.removeAll { $0.sessionID == session } }

    /// The user deleted an entry in the project settings.
    func remove(entry id: String, folder: URL) throws {
        try ProjectMemory(folder: folder).remove(id: id)
        revision += 1
    }
}
