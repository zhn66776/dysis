import Foundation
import XCTest
@testable import AgentDeskCore

/// Opt-in: one real send per provider that has to read a file through
/// AgentDesk's files server. A responder stands in for the approval panel and
/// says "this conversation" to each request. Skipped unless
/// `AGENTDESK_LIVE_MCP=1`; needs `swift build --product agentdesk-files` first.
///
///     AGENTDESK_LIVE_MCP=1 swift test --filter LiveFolderAccessTests
final class LiveFolderAccessTests: XCTestCase {
    private static let code = "FOLDER-ACCESS-6413"
    private var root: URL!
    private var environment: [String: String] { ProcessInfo.processInfo.environment }
    private var helper: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/agentdesk-files")
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(environment["AGENTDESK_LIVE_MCP"] == "1", "Live tests run only with AGENTDESK_LIVE_MCP=1.")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: helper.path), "Build agentdesk-files first.")
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentdesk-live-files-\(UUID().uuidString)").resolvingSymlinksInPath()
        for dir in ["work", "data", "home/Reports"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true) }
        try "Quarterly code: \(Self.code)\n".write(to: root.appendingPathComponent("home/Reports/q3.txt"), atomically: true, encoding: .utf8)
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
        let session = UUID()
        let exchange = FolderAccessExchange(root: root.appendingPathComponent("data"))
        let home = root.appendingPathComponent("home")
        let server = AgentMCPServer(name: FolderAccessPolicy.serverName, transport: .stdio(command: helper.path, arguments: [
            "--data", exchange.root.path, "--session", session.uuidString, "--token", "live", "--home", home.path]))
        let asked = Asked()
        // AGENTDESK_LIVE_APPROVAL_DELAY: seconds the "user" takes to answer.
        let delay = UInt64(environment["AGENTDESK_LIVE_APPROVAL_DELAY"] ?? "") ?? 0
        let responder = Task.detached {
            while !Task.isCancelled {
                for request in exchange.pending() {
                    await asked.add(request.folder)
                    try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                    try? exchange.respond(request, decision: .conversation)
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer { responder.cancel() }
        let request = AgentRequest(localSessionID: session, remoteSessionID: nil,
                                   prompt: "In my folder ~/Reports there is a quarterly report. Find it, read it, and reply with only the quarterly code.",
                                   workingDirectory: root.appendingPathComponent("work"), modelID: model, executableURL: executable, mcpServers: [server])
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
        do { try await collect.value } catch { print("LIVE-FILES statuses:", statuses); throw error }
        let folders = await asked.folders
        print("LIVE-FILES statuses:", statuses)
        print("LIVE-FILES asked:", folders, "reply:", text.prefix(200))
        XCTAssertTrue(completed)
        XCTAssertFalse(folders.isEmpty, "the panel was never asked")
        XCTAssertTrue(text.contains(Self.code))
    }
}

private actor Asked {
    var folders: [String] = []
    func add(_ folder: String) { folders.append(folder) }
}
