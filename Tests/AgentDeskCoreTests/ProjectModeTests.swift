import Foundation
import XCTest
@testable import AgentDeskCore

/// Project boards: the folder, trust, and what each CLI gets in a trusted project.
final class ProjectModeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("project-mode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testBoardsDecodeWithoutAProjectAndKeepOne() throws {
        let old = #"{"id":"7C1A0C4E-55B0-4B8B-9B7B-5E2C1F0A9D11","title":"b","nodes":[],"edges":[],"createdAt":0,"updatedAt":0}"#
        XCTAssertNil(try JSONDecoder().decode(CanvasBoard.self, from: Data(old.utf8)).project)
        let board = CanvasBoard(title: "交易", project: CanvasProject(path: "/p/交易", trusted: true))
        let again = try JSONDecoder().decode(CanvasBoard.self, from: JSONEncoder().encode(board))
        XCTAssertEqual(again.project, CanvasProject(path: "/p/交易", trusted: true))
        XCTAssertTrue(again.project!.isTrusted)
        XCTAssertFalse(CanvasProject(path: "/p").isTrusted)
    }

    func testNewFoldersGetUniqueSafeNames() throws {
        let first = try CanvasProject.makeFolder(title: "模拟交易", root: root)
        let second = try CanvasProject.makeFolder(title: "模拟交易", root: root)
        XCTAssertEqual(first.lastPathComponent, "模拟交易")
        XCTAssertEqual(second.lastPathComponent, "模拟交易 2")
        XCTAssertEqual(try CanvasProject.makeFolder(title: "a/b", root: root).lastPathComponent, "a-b")
        XCTAssertEqual(try CanvasProject.makeFolder(title: ".hidden", root: root).lastPathComponent, "新项目")
    }

    func testClaudeGetsItsToolsInATrustedProject() throws {
        let args = try ClaudeBackend.commonArguments(modelID: "m", effort: "high", mcpServers: [AgentMCPServer(name: "portfolio", transport: .stdio(command: "/x", arguments: []))], project: true)
        XCTAssertEqual(value(after: "--permission-mode", in: args), "bypassPermissions")
        XCTAssertEqual(value(after: "--max-turns", in: args), String(ClaudeBackend.maxProjectTurns))
        XCTAssertEqual(value(after: "--effort", in: args), "high")
        XCTAssertTrue(args.contains("--strict-mcp-config"), "MCP is still only the opened servers")
        for flag in ["--restricted", "--safe-mode", "--tools", "--disallowedTools"] { XCTAssertFalse(args.contains(flag), flag) }
    }

    func testCodexKeepsTheShellAndWritesTheWorkspaceInATrustedProject() throws {
        let overrides = { (args: [String]) in stride(from: 0, to: args.count, by: 1).compactMap { args[$0] == "-c" ? args[$0 + 1] : nil } }
        let project = overrides(try CodexBackend.appServerArguments(project: true))
        XCTAssertTrue(project.contains(#"sandbox_mode="workspace-write""#))
        XCTAssertTrue(project.contains("sandbox_workspace_write.network_access=true"))
        XCTAssertFalse(project.contains("features.shell_tool=false"))
        XCTAssertTrue(project.contains("features.computer_use=false"), "computer use stays off")
        XCTAssertTrue(project.contains("features.plugins=false"))
        let chat = overrides(try CodexBackend.appServerArguments())
        XCTAssertTrue(chat.contains("features.shell_tool=false"))
        XCTAssertTrue(chat.contains(#"sandbox_mode="read-only""#))
    }

    func testCursorLeavesTheUsersOwnCursorFilesAlone() throws {
        let cursor = root.appendingPathComponent(".cursor")
        try FileManager.default.createDirectory(at: cursor, withIntermediateDirectories: true)
        try #"{"mcpServers":{"mine":{"command":"/mine"}}}"#.write(to: cursor.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)
        let server = AgentMCPServer(name: "portfolio", transport: .stdio(command: "/x", arguments: []))
        let skipped = try CursorBackend.writeMCPConfig([server], workspace: root, userFolder: true, project: true)
        XCTAssertEqual(skipped, ["mcp.json"])
        XCTAssertTrue(try String(contentsOf: cursor.appendingPathComponent("mcp.json"), encoding: .utf8).contains("/mine"), "not replaced")
        let permissions = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cursor.appendingPathComponent("cli.json"))) as? [String: [String: [String]]])
        XCTAssertEqual(permissions["permissions"]?["deny"], [], "a trusted project has no deny list")
        // Without servers only what AgentDesk wrote is removed.
        try CursorBackend.writeMCPConfig([], workspace: root, userFolder: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cursor.appendingPathComponent("mcp.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cursor.appendingPathComponent("cli.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cursor.appendingPathComponent(".agentdesk-managed").path))
    }

    func testCursorProjectStatuses() {
        let shell = CursorJSONEventParser.parse(["type": "tool_call", "subtype": "started", "tool_call": ["shellToolCall": ["args": ["command": "ls"]]]])
        XCTAssertEqual(shell.projectStatus, "正在运行命令…")
        let edit = CursorJSONEventParser.parse(["type": "tool_call", "subtype": "started", "tool_call": ["editToolCall": ["args": [:]]]])
        XCTAssertEqual(edit.projectStatus, "正在修改文件…")
    }

    func testRequestsInATrustedProjectCountAsTheUsersFolder() {
        let request = AgentRequest(localSessionID: UUID(), remoteSessionID: nil, prompt: "p", workingDirectory: root, modelID: "m", executableURL: root, projectAccess: true)
        XCTAssertTrue(request.userFolder)
    }

    private func value(after flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }
}
