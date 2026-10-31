import Foundation
import AgentDeskCore

/// Actions a CLI wants to take that the conversation's permission level does
/// not allow on its own (design/HARNESS.md H1). Codex asks in process
/// (`ask`); Claude Code asks through AgentDesk's approval tool, whose request
/// files are polled here. The canvas shows them as cards in the node's panel,
/// in order; no answer within `ApprovalPolicy.timeout` is a no.
@MainActor
final class ApprovalCenter: ObservableObject {
    struct Pending: Identifiable, Equatable {
        let request: ApprovalRequest
        let expiresAt: Date
        /// Answered through the request files rather than in process.
        let viaFile: Bool
        var id: UUID { request.id }
    }

    let exchange: FolderAccessExchange
    /// The files server's launch token: older helpers' requests are declined.
    let token: String
    @Published private(set) var pending: [Pending] = []
    private var waiting: [UUID: CheckedContinuation<FolderAccessDecision, Never>] = [:]
    private var timer: Timer?

    init(exchange: FolderAccessExchange, token: String) {
        self.exchange = exchange
        self.token = token
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    /// For `AgentRequest.approver`: waits for the answer, a timeout, or the
    /// turn being stopped (all but an answer are a no).
    nonisolated var approver: AgentApprover {
        { [weak self] request in
            guard let self else { return .deny }
            return await self.ask(request)
        }
    }

    func ask(_ request: ApprovalRequest) async -> FolderAccessDecision {
        let id = request.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: .deny); return }
                waiting[id] = continuation
                pending.append(Pending(request: request, expiresAt: Date().addingTimeInterval(ApprovalPolicy.timeout), viaFile: false))
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(ApprovalPolicy.timeout * 1_000_000_000))
                    self?.resolve(id, .deny)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(id, .deny) }
        }
    }

    func answer(_ id: UUID, decision: FolderAccessDecision) {
        resolve(id, decision)
        poll()
    }

    func waiting(session: UUID) -> Bool { pending.contains { $0.request.sessionID == session } }

    /// A stopped turn's questions are declined.
    func cancel(session: UUID) {
        for item in pending where item.request.sessionID == session { resolve(item.id, .deny) }
    }

    /// A deleted conversation forgets what it allowed for the session.
    func forget(session: UUID) {
        cancel(session: session)
        try? exchange.setApprovalGrants([], session: session)
    }

    private func resolve(_ id: UUID, _ decision: FolderAccessDecision) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let item = pending.remove(at: index)
        if item.viaFile {
            if decision == .deny { exchange.discardApproval(id) } else { try? exchange.respondApproval(item.request, decision: decision) }
        }
        waiting.removeValue(forKey: id)?.resume(returning: decision)
    }

    /// New requests from the approval tool; drops ones its tool stopped waiting for.
    func poll() {
        let files = exchange.pendingApprovals()
        let live = Set(files.map(\.id))
        var next = pending.filter { !$0.viaFile || live.contains($0.id) }
        for request in files where !next.contains(where: { $0.id == request.id }) {
            let expires = request.createdAt.addingTimeInterval(ApprovalPolicy.timeout)
            guard request.token == token, expires > Date() else { exchange.discardApproval(request.id); continue }
            next.append(Pending(request: request, expiresAt: expires, viaFile: true))
        }
        // Publishing only on a change keeps the canvas from re-rendering every poll.
        if next != pending { pending = next }
    }
}
