import Foundation
import XCTest
@testable import AgentDeskCore

/// Opt-in: one real send per provider in a trusted project folder. The model
/// has to write a file there and run a command that uses the network.
/// Skipped unless `AGENTDESK_LIVE_MCP=1`.
///
///     AGENTDESK_LIVE_MCP=1 swift test --filter LiveProjectTests
final class LiveProjectTests: XCTestCase {
    private var root: URL!
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        try XCTSkipUnless(environment["AGENTDESK_LIVE_MCP"] == "1", "Live tests run only with AGENTDESK_LIVE_MCP=1.")
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentdesk-live-project-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    func testClaude() async throws {
        try await run(ClaudeBackend(), executable: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude"), model: environment["AGENTDESK_LIVE_CLAUDE_MODEL"] ?? "sonnet")
    }

    func testCodex() async throws {
        try await run(CodexBackend(), executable: CodexBackend.defaultExecutableURL, model: environment["AGENTDESK_LIVE_CODEX_MODEL"] ?? "")
    }

    func testCursor() async throws {
        try await run(CursorBackend(), executable: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/agent"), model: environment["AGENTDESK_LIVE_CURSOR_MODEL"] ?? "grok-4.7-medium")
    }

    private func run(_ backend: AgentBackend, executable: URL, model: String) async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: executable.path), "\(executable.lastPathComponent) is not installed.")
        let request = AgentRequest(localSessionID: UUID(), remoteSessionID: nil,
                                   prompt: "In this project folder, create a file named status.txt whose content is the first line printed by running: curl -sI https://example.com . Then reply with that line.",
                                   workingDirectory: root, modelID: model, executableURL: executable, projectAccess: true)
        var text = "", statuses: [String] = [], completed = false
        let collect = Task {
            for try await event in backend.stream(request) {
                switch event {
                case .textDelta(let d): text += d
                case .replaceText(let t): text = t
                case .status(let s): statuses.append(s)
                case .completed: completed = true
                default: break
                }
            }
        }
        let timeout = Task { try await Task.sleep(nanoseconds: 300_000_000_000); collect.cancel() }
        defer { timeout.cancel() }
        do { try await collect.value } catch { print("LIVE-PROJECT statuses:", statuses); throw error }
        let written = (try? String(contentsOf: root.appendingPathComponent("status.txt"), encoding: .utf8)) ?? ""
        print("LIVE-PROJECT statuses:", statuses)
        print("LIVE-PROJECT file:", written.prefix(80), "reply:", text.prefix(200))
        XCTAssertTrue(completed)
        XCTAssertTrue(written.contains("HTTP"), "the file holds the command's output")
    }
}
