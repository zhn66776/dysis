import Foundation
import XCTest
@testable import AgentDeskCore

/// Opt-in: one real send per provider with a local stdio MCP fixture opened to
/// the model. The fixture's tool returns a code word the model cannot guess
/// and logs each call, so a pass means the model called the tool itself.
/// Skipped unless `AGENTDESK_LIVE_MCP=1`; exactly one send per test, no retry.
///
///     AGENTDESK_LIVE_MCP=1 swift test --filter LiveMCPToolTests/testClaude
///
/// Optional: `AGENTDESK_LIVE_CLAUDE_MODEL` (default `sonnet`),
/// `AGENTDESK_LIVE_CODEX_MODEL` (default: Codex's own),
/// `AGENTDESK_LIVE_CURSOR_MODEL` (default `grok-4.7-medium`).
final class LiveMCPToolTests: XCTestCase {
    private static let code = "LIVE-MCP-5307"
    private var root: URL!
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        try XCTSkipUnless(environment["AGENTDESK_LIVE_MCP"] == "1", "Live MCP tests run only with AGENTDESK_LIVE_MCP=1.")
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentdesk-live-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("work"), withIntermediateDirectories: true)
        try fixture.write(to: root.appendingPathComponent("fixture.py"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testClaude() async throws {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude")
        try await run(ClaudeBackend(), executable: url, model: environment["AGENTDESK_LIVE_CLAUDE_MODEL"] ?? "sonnet")
    }

    func testCodex() async throws {
        try await run(CodexBackend(), executable: CodexBackend.defaultExecutableURL, model: environment["AGENTDESK_LIVE_CODEX_MODEL"] ?? "")
    }

    func testCursor() async throws {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/agent")
        try await run(CursorBackend(), executable: url, model: environment["AGENTDESK_LIVE_CURSOR_MODEL"] ?? "grok-4.7-medium")
    }

    /// Cursor reaching for a built-in tool first: it is denied and the turn goes on.
    func testCursorDeniedReadThenMCP() async throws {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/agent")
        try "secret note\n".write(to: root.appendingPathComponent("work/notes.txt"), atomically: true, encoding: .utf8)
        try await run(CursorBackend(), executable: url, model: environment["AGENTDESK_LIVE_CURSOR_MODEL"] ?? "grok-4.7-medium",
                      prompt: "First read notes.txt in the workspace. Then use the livecheck MCP server's get_code tool and reply with the code it returns.")
    }

    /// A question that does not name the server, as a user would ask it.
    func testCursorUnnamedServer() async throws {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/agent")
        try await run(CursorBackend(), executable: url, model: environment["AGENTDESK_LIVE_CURSOR_MODEL"] ?? "grok-4.7-medium",
                      prompt: "今天的验证码是多少？")
    }

    private func run(_ backend: AgentBackend, executable: URL, model: String,
                     prompt: String = "Use the livecheck MCP server's get_code tool, then reply with only the code it returns.") async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: executable.path), "\(executable.lastPathComponent) is not installed.")
        let log = root.appendingPathComponent("calls.log")
        let server = AgentMCPServer(name: "livecheck", transport: .stdio(command: "/usr/bin/python3", arguments: ["-I", root.appendingPathComponent("fixture.py").path, log.path]))
        let request = AgentRequest(localSessionID: UUID(), remoteSessionID: nil,
                                   prompt: prompt,
                                   workingDirectory: root.appendingPathComponent("work"), modelID: model, executableURL: executable, mcpServers: [server])
        var text = "", statuses: [String] = [], completed = false
        let stream = backend.stream(request)
        let collect = Task {
            for try await event in stream {
                switch event {
                case .textDelta(let d): text += d
                case .replaceText(let t): text = t
                case .status(let s): statuses.append(s)
                case .completed: completed = true
                default: break
                }
            }
        }
        let timeout = Task { try await Task.sleep(nanoseconds: 240_000_000_000); collect.cancel() }
        defer { timeout.cancel() }
        do { try await collect.value } catch { print("LIVE-MCP statuses:", statuses); throw error }
        let calls = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        print("LIVE-MCP statuses:", statuses)
        print("LIVE-MCP tool calls logged:", calls.split(separator: "\n").count, "reply:", text.prefix(200))
        XCTAssertTrue(completed)
        XCTAssertTrue(calls.contains("get_code"), "the fixture tool was not called")
        XCTAssertTrue(text.contains(Self.code))
    }

    private var fixture: String { """
    # Local stdio MCP fixture: no network. Logs tool calls to argv[1].
    import sys, json
    log = sys.argv[1]
    for line in sys.stdin:
        req = json.loads(line)
        if "id" not in req: continue
        m = req.get("method")
        if m == "initialize":
            out = {"protocolVersion": req.get("params", {}).get("protocolVersion", "2025-06-18"), "capabilities": {"tools": {}}, "serverInfo": {"name": "livecheck", "version": "1"}}
        elif m == "tools/list":
            out = {"tools": [{"name": "get_code", "description": "Returns today's verification code.", "inputSchema": {"type": "object", "properties": {}},
                              "annotations": {"readOnlyHint": True}}]}
        elif m == "tools/call":
            open(log, "a").write(req["params"]["name"] + "\\n")
            out = {"content": [{"type": "text", "text": "\(Self.code)"}], "isError": False}
        else:
            out = {}
        print(json.dumps({"jsonrpc": "2.0", "id": req["id"], "result": out}), flush=True)
    """ }
}
