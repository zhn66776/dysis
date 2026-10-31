import Foundation
import XCTest
@testable import AgentDeskCore

/// Opt-in checks against the real Claude Code and Codex CLIs on the user's
/// subscriptions. Skipped unless `AGENTDESK_LIVE=1`; every model turn counts
/// against a hard budget of five per provider and nothing is retried.
///
///     AGENTDESK_LIVE=1 swift test --filter LiveProviderTests
///
/// Optional: `AGENTDESK_LIVE_CLAUDE_MODEL` (default `sonnet`),
/// `AGENTDESK_LIVE_CODEX_MODEL` (default: Codex's own default),
/// `AGENTDESK_LIVE_TURN_BUDGET` to lower the per-provider limit (never above 5),
/// `AGENTDESK_LIVE_REPORT_DIR` to write a per-provider JSON summary
/// (booleans, counts and token numbers only; no IDs or reply text).
final class LiveProviderTests: XCTestCase {
    private var turnBudget: Int { min(5, Int(environment["AGENTDESK_LIVE_TURN_BUDGET"] ?? "") ?? 5) }
    private static let claudeURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude")

    private var root: URL!
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        try XCTSkipUnless(environment["AGENTDESK_LIVE"] == "1", "Live provider tests run only with AGENTDESK_LIVE=1.")
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentdesk-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: Claude Code

    func testClaudeFirstTurnForkAndParentFollowUp() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: Self.claudeURL.path), "Claude Code is not installed.")
        let model = environment["AGENTDESK_LIVE_CLAUDE_MODEL"] ?? "sonnet"
        var budget = TurnBudget(limit: turnBudget)
        var report = LiveReport(provider: "claude", model: model)
        defer { report.turnsUsed = budget.used; report.write(to: environment["AGENTDESK_LIVE_REPORT_DIR"]) }
        let backend = ClaudeBackend()

        // 1. Plain first turn in its own directory.
        let parentDir = try workspace()
        let parentRequest = request(parentDir, model: model, executable: Self.claudeURL,
                                    prompt: "Remember the code word TEAL-42. Reply with OK.")
        let parent = try await budget.run(backend, parentRequest)
        // Reported once, and it is the ID the adapter asked Claude Code to use.
        report.record("first_turn_session_id", parent.sessionIDs.map { $0.lowercased() } == [parentRequest.localSessionID.uuidString.lowercased()])
        report.record("first_turn_completed", parent.completed)
        report.record("first_turn_context_usage", parent.contextUsage != nil)
        report.observe("first_turn_context_window_reported", parent.contextUsage?.windowTokens != nil)
        report.observe("first_turn_quota_events", parent.quotaEvents)
        report.observe("first_turn_quota_windows", parent.quota?.windows.count ?? 0)
        report.observe("first_turn_quota_status_reported", parent.quota?.status != nil)
        XCTAssertEqual(parent.sessionIDs.count, 1)
        XCTAssertTrue(parent.completed)
        XCTAssertNotNil(parent.contextUsage)
        let parentID = try XCTUnwrap(parent.sessionIDs.last)

        // 2. Native fork into a different directory, as a canvas child node is.
        let forkDir = try workspace()
        let fork = try await budget.run(backend, request(forkDir, model: model, executable: Self.claudeURL,
                                                         prompt: "What was the code word? Reply with only the code word.",
                                                         fork: AgentFork(remoteSessionID: parentID)))
        let forkID = fork.sessionIDs.last
        report.record("fork_completed", fork.completed)
        report.record("fork_session_id_differs", forkID != nil && forkID != parentID)
        report.record("fork_session_id_reported_once", fork.sessionIDs.count == 1)
        report.record("fork_recalls_code_word", fork.text.localizedCaseInsensitiveContains("TEAL-42"))
        report.record("fork_context_usage", fork.contextUsage != nil)
        XCTAssertTrue(fork.completed)
        XCTAssertNotEqual(forkID, parentID)
        XCTAssertTrue(fork.text.localizedCaseInsensitiveContains("TEAL-42"))

        // 3. The parent still resumes after the fork.
        let followUp = try await budget.run(backend, request(parentDir, model: model, executable: Self.claudeURL,
                                                             prompt: "What was the code word? Reply with only the code word.",
                                                             remote: parentID))
        report.record("parent_follow_up_completed", followUp.completed)
        report.record("parent_follow_up_same_session", followUp.sessionIDs.allSatisfy { $0 == parentID })
        report.record("parent_follow_up_recalls_code_word", followUp.text.localizedCaseInsensitiveContains("TEAL-42"))
        XCTAssertTrue(followUp.completed)
        XCTAssertEqual(Set(followUp.sessionIDs), [parentID])
    }

    // MARK: Codex

    func testCodexInspectReportsQuota() async throws {
        let executable = CodexBackend.defaultExecutableURL
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: executable.path), "Codex is not installed.")
        var report = LiveReport(provider: "codex-inspect", model: nil)
        defer { report.write(to: environment["AGENTDESK_LIVE_REPORT_DIR"]) }
        let inspection = try await CodexBackend.inspect(executableURL: executable, directory: try workspace())
        report.record("inspect_chatgpt_account", inspection.isChatGPT)
        report.record("inspect_quota_non_nil", inspection.quota != nil)
        report.observe("inspect_quota_windows", inspection.quota?.windows.count ?? 0)
        report.observe("inspect_default_model", inspection.defaultModelID ?? "")
        report.observe("inspect_models", inspection.modelIDs)
        XCTAssertTrue(inspection.isChatGPT)
        XCTAssertNotNil(inspection.quota)
    }

    func testCodexFirstTurnForkThroughEarlierTurnAndWholeFork() async throws {
        let executable = CodexBackend.defaultExecutableURL
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: executable.path), "Codex is not installed.")
        let model = environment["AGENTDESK_LIVE_CODEX_MODEL"] ?? ""
        var budget = TurnBudget(limit: turnBudget)
        var report = LiveReport(provider: "codex", model: model.isEmpty ? "default" : model)
        defer { report.turnsUsed = budget.used; report.write(to: environment["AGENTDESK_LIVE_REPORT_DIR"]) }
        let backend = CodexBackend(executableURL: executable)

        // 1. Plain first turn.
        let parentDir = try workspace()
        let first = try await budget.run(backend, request(parentDir, model: model, executable: executable,
                                                          prompt: "Remember the code word TEAL-42. Reply with OK."))
        report.record("first_turn_session_id", !first.sessionIDs.isEmpty && Set(first.sessionIDs).count == 1)
        report.record("first_turn_completed", first.completed)
        report.record("first_turn_context_usage", first.contextUsage != nil)
        report.record("first_turn_turn_id", first.turnIDs.count == 1)
        report.observe("first_turn_context_window_reported", first.contextUsage?.windowTokens != nil)
        report.observe("first_turn_quota_events", first.quotaEvents)
        XCTAssertTrue(first.completed)
        XCTAssertNotNil(first.contextUsage)
        let parentID = try XCTUnwrap(first.sessionIDs.last)
        let firstTurnID = try XCTUnwrap(first.turnIDs.last)

        // 2. A second parent turn adds a fact the earlier-turn fork must not see.
        let second = try await budget.run(backend, request(parentDir, model: model, executable: executable,
                                                           prompt: "Also remember a second code word PLUM-7. Reply with OK.",
                                                           remote: parentID))
        report.record("parent_second_turn_completed", second.completed)
        report.record("parent_second_turn_same_session", !second.sessionIDs.isEmpty && second.sessionIDs.allSatisfy { $0 == parentID })
        report.record("parent_second_turn_new_turn_id", second.turnIDs.count == 1 && second.turnIDs.last != firstTurnID)
        XCTAssertTrue(second.completed)
        XCTAssertEqual(Set(second.sessionIDs), [parentID])

        // 3. Native fork through the first turn only: carries TEAL-42, not PLUM-7.
        let partial = try await budget.run(backend, request(try workspace(), model: model, executable: executable,
                                                            prompt: "List every code word I asked you to remember. Reply with only the code words.",
                                                            fork: AgentFork(remoteSessionID: parentID, throughTurnID: firstTurnID)))
        report.record("fork_through_turn_completed", partial.completed)
        report.record("fork_through_turn_session_id_differs", !partial.sessionIDs.isEmpty && !partial.sessionIDs.contains(parentID))
        report.record("fork_through_turn_recalls_first", partial.text.localizedCaseInsensitiveContains("TEAL-42"))
        report.record("fork_through_turn_omits_later", !partial.text.localizedCaseInsensitiveContains("PLUM-7"))
        report.record("fork_through_turn_turn_id", partial.turnIDs.count == 1)
        XCTAssertTrue(partial.completed)
        XCTAssertFalse(partial.sessionIDs.contains(parentID))
        XCTAssertTrue(partial.text.localizedCaseInsensitiveContains("TEAL-42"))
        XCTAssertFalse(partial.text.localizedCaseInsensitiveContains("PLUM-7"))

        // 4. Native fork of the whole thread, if the budget allows: carries both.
        guard budget.used < budget.limit else { return report.observe("whole_thread_fork", "skipped: budget") }
        let fork = try await budget.run(backend, request(try workspace(), model: model, executable: executable,
                                                         prompt: "List every code word I asked you to remember. Reply with only the code words.",
                                                         fork: AgentFork(remoteSessionID: parentID)))
        report.record("fork_completed", fork.completed)
        report.record("fork_session_id_differs", !fork.sessionIDs.isEmpty && !fork.sessionIDs.contains(parentID))
        report.record("fork_recalls_both_code_words", fork.text.localizedCaseInsensitiveContains("TEAL-42") && fork.text.localizedCaseInsensitiveContains("PLUM-7"))
        XCTAssertTrue(fork.completed)
        XCTAssertFalse(fork.sessionIDs.contains(parentID))
        XCTAssertTrue(fork.text.localizedCaseInsensitiveContains("PLUM-7"))
    }

    // MARK: Helpers

    private func workspace() throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func request(_ directory: URL, model: String, executable: URL, prompt: String, remote: String? = nil, fork: AgentFork? = nil) -> AgentRequest {
        AgentRequest(localSessionID: UUID(), remoteSessionID: remote, prompt: prompt, workingDirectory: directory,
                     modelID: model, executableURL: executable, forkFrom: fork)
    }
}

/// Everything one turn reported, collected from the event stream.
private struct LiveTurn {
    var sessionIDs: [String] = []
    var turnIDs: [String] = []
    var text = ""
    var completed = false
    var contextUsage: ContextUsage?
    var quota: ProviderQuota?
    var quotaEvents = 0
}

/// Counts model turns before they start; refuses to start one past the limit.
private struct TurnBudget {
    let limit: Int
    private(set) var used = 0
    init(limit: Int) { self.limit = limit }

    mutating func run(_ backend: AgentBackend, _ request: AgentRequest, timeout: TimeInterval = 180) async throws -> LiveTurn {
        guard used < limit else { throw AgentError.unavailable("Live turn budget of \(limit) exhausted.") }
        used += 1
        return try await withThrowingTaskGroup(of: LiveTurn?.self) { group in
            group.addTask {
                var turn = LiveTurn()
                for try await event in backend.stream(request) {
                    switch event {
                    case .sessionID(let id): turn.sessionIDs.append(id)
                    case .turnID(let id): turn.turnIDs.append(id)
                    case .textDelta(let delta): turn.text += delta
                    case .replaceText(let text): turn.text = text
                    case .contextUsage(let usage): turn.contextUsage = usage
                    case .quota(let quota): turn.quota = quota; turn.quotaEvents += 1
                    case .completed: turn.completed = true
                    case .status, .actualModels, .step, .turnDiff: break
                    }
                }
                return turn
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            guard let turn = try await group.next() ?? nil else { throw AgentError.timeout }
            return turn
        }
    }
}

/// Pass/fail per check plus a few observations, written as JSON when asked.
private struct LiveReport {
    let provider: String
    let model: String?
    var turnsUsed = 0
    var checks: [String: Bool] = [:]
    var observations: [String: Any] = [:]

    init(provider: String, model: String?) { self.provider = provider; self.model = model }

    mutating func record(_ name: String, _ passed: Bool) { checks[name] = passed }
    mutating func observe(_ name: String, _ value: Any) { observations[name] = value }

    func write(to directory: String?) {
        guard let directory, !directory.isEmpty else { return }
        var object: [String: Any] = ["provider": provider, "live_model_turns": turnsUsed, "checks": checks, "observations": observations]
        if let model { object["model"] = model }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("live-\(provider).json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }
}
