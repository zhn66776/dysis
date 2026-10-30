import Foundation
import XCTest
@testable import AgentDeskCore

/// MCP servers the user opens to the model: config, and what each CLI is given.
final class ModelMCPAccessTests: XCTestCase {
    private let python = MCPTransport.stdio(command: "/Users/me/My-Portfolio/.venv/bin/python", arguments: ["-m", "portfolio_analytics.mcp_server"])

    func testOldConfigurationDecodesWithModelAccessOff() throws {
        let old = #"[{"id":"7C1A0C4E-55B0-4B8B-9B7B-5E2C1F0A9D11","name":"portfolio","transport":{"type":"stdio","command":"/bin/x","arguments":[]},"enabled":true,"environmentVariableNames":[]}]"#
        let decoded = try JSONDecoder().decode([MCPServerConfiguration].self, from: Data(old.utf8))
        XCTAssertEqual(decoded.first?.modelAccess, false)
        let again = try JSONDecoder().decode([MCPServerConfiguration].self, from: JSONEncoder().encode(decoded.map { var c = $0; c.modelAccess = true; return c }))
        XCTAssertEqual(again.first?.modelAccess, true)
    }

    func testOnlyEnabledOpenedServersGoToTheModelWithSafeUniqueNames() {
        let configs = [
            MCPServerConfiguration(name: "Portfolio MCP (local)", transport: python, environmentVariableNames: ["PORTFOLIO_TOKEN", "MISSING"], modelAccess: true),
            MCPServerConfiguration(name: "portfolio-mcp-local", transport: python, modelAccess: true),
            MCPServerConfiguration(name: "closed", transport: python),
            MCPServerConfiguration(name: "off", transport: python, enabled: false, modelAccess: true),
            MCPServerConfiguration(name: "empty", transport: .stdio(command: " ", arguments: []), modelAccess: true),
            MCPServerConfiguration(name: "持仓", transport: .streamableHTTP(url: "http://127.0.0.1:8765/mcp"), modelAccess: true),
        ]
        let servers = AgentMCPServer.forModel(configs, processEnvironment: ["PORTFOLIO_TOKEN": "t", "OTHER": "x"])
        XCTAssertEqual(servers.map(\.name), ["portfolio_mcp_local", "portfolio-mcp-local", "mcp"])
        XCTAssertEqual(servers[0].environment, ["PORTFOLIO_TOKEN": "t"])
        XCTAssertEqual(servers[1].environment, [:])
        XCTAssertEqual(AgentMCPServer.safeName("a__b"), "a_b")
    }

    func testClaudeStaysToolFreeWithoutServers() throws {
        let args = try ClaudeBackend.commonArguments(modelID: "m", effort: nil)
        XCTAssertEqual(value(after: "--disallowedTools", in: args), "mcp__*")
        XCTAssertEqual(value(after: "--mcp-config", in: args), #"{"mcpServers":{}}"#)
        XCTAssertEqual(value(after: "--max-turns", in: args), "1")
        XCTAssertFalse(args.contains("--allowedTools"))
    }

    func testClaudeGetsOnlyTheOpenedServersTools() throws {
        let servers = [AgentMCPServer(name: "portfolio", transport: python), AgentMCPServer(name: "remote", transport: .streamableHTTP(url: "https://x.test/mcp"))]
        let args = try ClaudeBackend.commonArguments(modelID: "m", effort: nil, mcpServers: servers)
        XCTAssertFalse(args.contains("--disallowedTools"))
        XCTAssertEqual(value(after: "--tools", in: args), "", "built-in tools stay off")
        XCTAssertEqual(value(after: "--allowedTools", in: args), "mcp__portfolio,mcp__remote")
        XCTAssertEqual(value(after: "--max-turns", in: args), String(ClaudeBackend.maxToolTurns))
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        let config = try XCTUnwrap(value(after: "--mcp-config", in: args))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: [String: [String: Any]]])
        XCTAssertEqual(object["mcpServers"]?["portfolio"]?["command"] as? String, "/Users/me/My-Portfolio/.venv/bin/python")
        XCTAssertEqual(object["mcpServers"]?["portfolio"]?["args"] as? [String], ["-m", "portfolio_analytics.mcp_server"])
        XCTAssertEqual(object["mcpServers"]?["remote"]?["type"] as? String, "http")
    }

    func testClaudeReportsToolCallsAndUnconnectedServers() {
        let call = ClaudeJSONEventParser.parse(["type": "assistant", "message": ["model": "m", "content": [["type": "tool_use", "name": "mcp__portfolio__list_holdings", "input": [:]]]]])
        XCTAssertEqual(call.status, "正在调用 MCP 工具 portfolio · list_holdings…")
        let initEvent = ClaudeJSONEventParser.parse(["type": "system", "subtype": "init", "mcp_servers": [["name": "portfolio", "status": "failed"], ["name": "ok", "status": "connected"]]])
        XCTAssertEqual(initEvent.status, "MCP 服务器没有连上：portfolio。")
    }

    func testCodexKeepsUserServersDisabledAndAddsOurs() throws {
        let ours = CodexBackend.codexMCPServers([AgentMCPServer(name: "portfolio", transport: python, environment: ["B": "2", "A": "1"]),
                                                 AgentMCPServer(name: "robinhood-trading", transport: .streamableHTTP(url: "http://127.0.0.1:9/mcp"))],
                                                avoiding: ["robinhood-trading"])
        XCTAssertEqual(ours.map(\.name), ["portfolio", "agentdesk_robinhood-trading"])
        let args = try CodexBackend.appServerArguments(disabling: ["robinhood-trading"], providing: ours)
        let overrides = stride(from: 0, to: args.count, by: 1).compactMap { args[$0] == "-c" ? args[$0 + 1] : nil }
        XCTAssertTrue(overrides.contains("mcp_servers.robinhood-trading.enabled=false"))
        XCTAssertTrue(overrides.contains(#"mcp_servers.portfolio.command="/Users/me/My-Portfolio/.venv/bin/python""#))
        XCTAssertTrue(overrides.contains(#"mcp_servers.portfolio.args=["-m","portfolio_analytics.mcp_server"]"#))
        XCTAssertTrue(overrides.contains(#"mcp_servers.portfolio.env_vars=["A","B"]"#))
        XCTAssertTrue(overrides.contains("mcp_servers.portfolio.enabled=true"))
        XCTAssertTrue(overrides.contains(#"mcp_servers.agentdesk_robinhood-trading.url="http://127.0.0.1:9/mcp""#))
        XCTAssertTrue(overrides.contains("features.shell_tool=false"))
        XCTAssertTrue(overrides.contains(#"sandbox_mode="read-only""#))
    }

    func testCodexApprovesToolCallsOnlyForOurServers() {
        let meta: [String: Any] = ["codex_approval_kind": "mcp_tool_call"]
        XCTAssertTrue(CodexBackend.isToolCallApproval(["serverName": "portfolio", "_meta": meta], allowed: ["portfolio"]))
        XCTAssertFalse(CodexBackend.isToolCallApproval(["serverName": "robinhood-trading", "_meta": meta], allowed: ["portfolio"]))
        XCTAssertFalse(CodexBackend.isToolCallApproval(["serverName": "portfolio", "_meta": NSNull()], allowed: ["portfolio"]), "a real form elicitation is still declined")
    }

    func testCursorTellsMCPCallsFromOtherTools() {
        let mcp = CursorJSONEventParser.parse(["type": "tool_call", "subtype": "started",
                                               "tool_call": ["mcpToolCall": ["args": ["providerIdentifier": "portfolio", "toolName": "list_holdings", "args": [:]]]]])
        XCTAssertTrue(mcp.hasToolCall)
        XCTAssertEqual(mcp.mcpToolCall, CursorMCPCall(server: "portfolio", tool: "list_holdings"))
        let read = CursorJSONEventParser.parse(["type": "tool_call", "subtype": "started", "tool_call": ["readToolCall": ["args": ["path": "a.json"]]]])
        XCTAssertTrue(read.hasToolCall)
        XCTAssertNil(read.mcpToolCall)
        XCTAssertTrue(CursorBackend.allows("portfolio", among: ["portfolio"]))
        XCTAssertTrue(CursorBackend.allows("project-0-portfolio", among: ["portfolio"]))
        XCTAssertTrue(CursorBackend.allows(nil, among: ["portfolio"]))
        XCTAssertFalse(CursorBackend.allows("robinhood", among: ["portfolio"]))
        XCTAssertFalse(CursorBackend.allows("portfolio", among: []))
    }

    func testCursorWorkspaceConfigFollowsTheOpenedServers() throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try CursorBackend.writeMCPConfig([AgentMCPServer(name: "portfolio", transport: python)], workspace: workspace)
        let url = workspace.appendingPathComponent(".cursor/mcp.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: [String: [String: Any]]])
        XCTAssertEqual(object["mcpServers"]?["portfolio"]?["args"] as? [String], ["-m", "portfolio_analytics.mcp_server"])
        try CursorBackend.writeMCPConfig([], workspace: workspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    private func value(after flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }
}
