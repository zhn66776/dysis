import Foundation
import XCTest
@testable import AgentDeskCore

/// H4 rule layers: what each CLI gets, the project files, and the command policy.
final class HarnessRulesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("harness-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: Injection

    func testClaudeInjectsRulesThroughAppendSystemPromptInBothModes() throws {
        for project in [false, true] {
            let args = try ClaudeBackend.commonArguments(modelID: "m", effort: nil, project: project, instructions: "R")
            XCTAssertEqual(value(after: "--append-system-prompt", in: args), "R")
            XCTAssertEqual(value(after: "--system-prompt-snapshot", in: args), "off", "an edited rule applies from the next turn")
            XCTAssertFalse(args.contains("--system-prompt"), "Claude Code keeps its own system prompt")
        }
        let none = try ClaudeBackend.commonArguments(modelID: "m", effort: nil)
        XCTAssertFalse(none.contains("--append-system-prompt"))
        XCTAssertTrue(none.contains("--safe-mode"), "chat mode is unchanged")
    }

    func testClaudeLoadsAgentsBesideClaudeFileInAProject() throws {
        let project = try ClaudeBackend.commonArguments(modelID: "m", effort: nil, project: true)
        let settings = try XCTUnwrap(value(after: "--settings", in: project))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any])
        XCTAssertEqual(object["instructionFiles"] as? String, "claude-md-and-agents-md")
        XCTAssertEqual(value(after: "--permission-mode", in: project), "bypassPermissions", "tool arguments are unchanged")
    }

    func testRequestDropsBlankInstructions() {
        let request = AgentRequest(localSessionID: UUID(), remoteSessionID: nil, prompt: "p", workingDirectory: root, modelID: "m", executableURL: root, instructions: " \n ")
        XCTAssertNil(request.instructions)
    }

    func testCodexDeveloperInstructions() {
        XCTAssertEqual(CodexBackend.developerInstructions(project: false, mcpServers: [], rules: nil), CodexBackend.chatToolInstructions(mcpServers: []))
        XCTAssertEqual(CodexBackend.developerInstructions(project: false, mcpServers: [], rules: "R"), CodexBackend.chatToolInstructions(mcpServers: []) + "\n\nR")
        XCTAssertEqual(CodexBackend.developerInstructions(project: true, mcpServers: [], rules: "R"), "R")
        XCTAssertNil(CodexBackend.developerInstructions(project: true, mcpServers: [], rules: nil))
    }

    func testCursorRulesLeadTheMessageAsTheirOwnBlock() {
        XCTAssertEqual(RuleLayers.cursorPrompt("hello", rules: nil), "hello")
        let prompt = RuleLayers.cursorPrompt(CursorBackend.prompt("hello", mcpServers: ["agentdesk_files"]), rules: "R")
        XCTAssertTrue(prompt.hasPrefix("<agentdesk-rules>\nR\n</agentdesk-rules>\n\n[AgentDesk："))
        XCTAssertTrue(prompt.hasSuffix("hello"))
    }

    // MARK: Composition

    func testLayersComposeInOrderWithNodeLast() throws {
        let composed = RuleLayers.compose(provider: .codex, projectAccess: false, global: " 全局 ", project: nil, node: "节点")
        let text = try XCTUnwrap(composed.text)
        let global = try XCTUnwrap(text.range(of: "## AgentDesk 全局规则\n\n全局"))
        let node = try XCTUnwrap(text.range(of: "## 本节点规则\n\n节点"))
        XCTAssertLessThan(global.lowerBound, node.lowerBound)
        XCTAssertEqual(composed.sources.map(\.layer), [.global, .node])
        XCTAssertEqual(composed.sources.map(\.characters), [2, 2])
        XCTAssertNil(RuleLayers.compose(provider: .claude, projectAccess: false, global: "", project: nil, node: " ").text)
    }

    func testProjectRulesAreNativeExceptForClaudeInChatMode() throws {
        try "用 pnpm。".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let rules = ProjectRules.read(root)
        for provider in [ProviderID.codex, .grok] {
            let composed = RuleLayers.compose(provider: provider, projectAccess: false, global: "", project: rules, node: "")
            XCTAssertNil(composed.text, "\(provider) reads AGENTS.md itself")
            XCTAssertEqual(composed.sources.first?.delivery, .native)
            XCTAssertEqual(composed.sources.first?.characters, 7)
        }
        let trusted = RuleLayers.compose(provider: .claude, projectAccess: true, global: "", project: rules, node: "")
        XCTAssertNil(trusted.text)
        XCTAssertEqual(trusted.sources.first?.delivery, .native)
        let chat = RuleLayers.compose(provider: .claude, projectAccess: false, global: "全局一条", project: rules, node: "节点一条")
        let text = try XCTUnwrap(chat.text)
        XCTAssertTrue(text.contains("## 项目规则（AGENTS.md）\n\n用 pnpm。"), "--safe-mode skips project files, so AgentDesk injects them")
        XCTAssertEqual(chat.sources.map(\.layer), [.global, .project, .node])
        XCTAssertLessThan(text.range(of: "全局一条")!.lowerBound, text.range(of: "用 pnpm")!.lowerBound)
        XCTAssertLessThan(text.range(of: "用 pnpm")!.lowerBound, text.range(of: "节点一条")!.lowerBound)
    }

    // MARK: CLAUDE.md

    func testClaudeFileIsDetectedAndOnlyCreatedWhenMissing() throws {
        XCTAssertEqual(ProjectRules.read(root).claude, .missing)
        try ProjectRules.createClaudeImport(in: root)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("CLAUDE.md"), encoding: .utf8), "@AGENTS.md\n")
        XCTAssertEqual(ProjectRules.read(root).claude, .importsAgents)
        XCTAssertThrowsError(try ProjectRules.createClaudeImport(in: root)) { XCTAssertEqual($0 as? HarnessRulesError, .claudeFileExists) }
    }

    func testExistingClaudeFileIsNeverChanged() throws {
        let url = root.appendingPathComponent("CLAUDE.md")
        let mine = "# 我的规则\n\n不要用 AGENTS.md 里的写法，例如 foo@AGENTS.md.bak。\n"
        try mine.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectRules.read(root).claude, .withoutImport)
        XCTAssertThrowsError(try ProjectRules.createClaudeImport(in: root))
        try ProjectRules.saveAgents("规则", in: root)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), mine)
        for imported in ["见 @AGENTS.md", "@./AGENTS.md\n其他", "前言\n  @AGENTS.md  \n"] {
            try imported.write(to: url, atomically: true, encoding: .utf8)
            XCTAssertEqual(ProjectRules.read(root).claude, .importsAgents, imported)
        }
    }

    func testGlobalRulesLiveInTheDataFolder() throws {
        let store = GlobalRulesStore(root: root)
        XCTAssertEqual(store.load(), "")
        try store.save("  回答用中文。\n")
        XCTAssertEqual(store.load(), "回答用中文。\n")
        XCTAssertEqual(store.url.lastPathComponent, "rules.md")
        try store.save("")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }

    // MARK: Command policy

    func testCommandPolicyIsPerProjectAndRemovable() throws {
        let store = CommandPolicyStore(root: root)
        let rule = CommandPolicyRule(provider: .codex, prefix: ["git", "status"], sourceTitle: "重构")
        try store.add(rule, projectPath: "/p/a")
        try store.add(CommandPolicyRule(provider: .claude, prefix: ["git", "status"]), projectPath: "/p/a")
        XCTAssertEqual(store.load(projectPath: "/p/a").commands.count, 1, "the same prefix is kept once")
        XCTAssertTrue(store.load(projectPath: "/p/a").allows(["git", "status", "--short"]))
        XCTAssertFalse(store.load(projectPath: "/p/a").allows(["git", "push"]))
        XCTAssertFalse(store.load(projectPath: "/p/b").allows(["git", "status"]), "another project asks again")
        XCTAssertEqual(rule.claudeAllowedTool, "Bash(git status:*)")
        XCTAssertFalse(store.url(projectPath: "/p/a").path.hasPrefix("/p/a"), "kept in the app data, out of the agent's reach")
        try store.remove(rule.id, projectPath: "/p/a")
        XCTAssertTrue(store.load(projectPath: "/p/a").commands.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(projectPath: "/p/a").path))
    }

    func testCommandPolicyFileFormat() throws {
        let store = CommandPolicyStore(root: root)
        try store.add(CommandPolicyRule(id: UUID(uuidString: "7C1A0C4E-55B0-4B8B-9B7B-5E2C1F0A9D11")!, provider: .codex, prefix: ["npm", "test"], createdAt: Date(timeIntervalSince1970: 0)), projectPath: "/p/a")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.url(projectPath: "/p/a"))) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["projectPath"] as? String, "/p/a")
        let first = try XCTUnwrap((object["commands"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["prefix"] as? [String], ["npm", "test"])
        XCTAssertEqual(first["provider"] as? String, "codex")
        XCTAssertEqual(first["createdAt"] as? String, "1970-01-01T00:00:00Z")
    }

    private func value(after flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }
}
