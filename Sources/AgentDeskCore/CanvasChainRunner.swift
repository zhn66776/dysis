import Foundation

/// Sequencing for a downstream re-run: nodes run one at a time in the given
/// order, each waits for its reply, and the run stops at the first node that
/// does not start or does not complete. Sending, waiting and stopping are
/// injected so the order and stop rules can be tested without a provider.
@MainActor
public struct CanvasChainRunner {
    /// Same ceiling as a Plaza meeting.
    public static let maxCalls = 12

    public enum Start: Equatable, Sendable {
        case started
        /// The node has nothing to re-run (no prompt, or gone); the chain moves on.
        case skipped
        case failed
    }

    public enum Finish: Equatable, Sendable {
        case complete
        case incomplete
        /// The surrounding task was cancelled while the node was still running.
        case cancelled
    }

    public enum Outcome: Equatable, Sendable {
        case finished
        case empty
        case overCap
        case notStarted(index: Int)
        case incomplete(index: Int)
        case cancelled(index: Int)
    }

    /// Called with each index before its node is started.
    public var step: @MainActor (Int) -> Void
    public var start: @MainActor (UUID) -> Start
    /// Returns once the node's turn has ended, or `.cancelled` if the task is
    /// cancelled first.
    public var wait: @MainActor (UUID) async -> Finish
    /// Stops a node whose wait was cancelled.
    public var stop: @MainActor (UUID) -> Void

    public init(step: @escaping @MainActor (Int) -> Void = { _ in },
                start: @escaping @MainActor (UUID) -> Start,
                wait: @escaping @MainActor (UUID) async -> Finish,
                stop: @escaping @MainActor (UUID) -> Void) {
        self.step = step
        self.start = start
        self.wait = wait
        self.stop = stop
    }

    /// Why `order` would be refused before anything starts, if at all.
    public static func refusal(count: Int) -> Outcome? {
        if count == 0 { return .empty }
        if count > maxCalls { return .overCap }
        return nil
    }

    public func run(_ order: [UUID]) async -> Outcome {
        if let refused = Self.refusal(count: order.count) { return refused }
        for (index, nodeID) in order.enumerated() {
            guard !Task.isCancelled else { return .cancelled(index: index) }
            step(index)
            switch start(nodeID) {
            case .skipped: continue
            case .failed: return .notStarted(index: index)
            case .started: break
            }
            switch await wait(nodeID) {
            case .complete: continue
            case .incomplete: return .incomplete(index: index)
            case .cancelled:
                stop(nodeID)
                return .cancelled(index: index)
            }
        }
        return .finished
    }
}
