import Foundation
import XCTest
@testable import AgentDeskCore

/// H5 project memory: the file, the drafts the model proposes, and how each CLI reads it.
final class ProjectMemoryTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var data: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("project-memory-\(UUID().uuidString)")
        project = root.appendingPathComponent("project", isDirectory: true)
        data = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: The file

    func testEntriesCarrySourceDateAndAuthor() throws {
        let memory = ProjectMemory(folder: project)
        let session = UUID(uuidString: "5E2C1F0A-55B0-4B8B-9B7B-5E2C1F0A9D11")!
        try memory.append(MemoryEntry(id: "AAAA0001", date: "2026-10-30", author: .user, source: MemoryEntry.source(title: "重构 · API", sessionID: session), text: "用 pnpm，不用 npm。"))
        try memory.append(MemoryEntry(id: "AAAA0002", date: "2026-10-31", author: .model("Claude Code，sonnet"), source: nil, text: "测试用 `swift test`。\n不要跑 Live 测试。"))
        let text = memory.text()
        XCTAssertTrue(text.hasPrefix("# 项目记忆"))
        XCTAssertTrue(text.contains("### 2026-10-30 · 用户 · 来自「重构 API」(5E2C1F0A)\n<!-- agentdesk-memory: AAAA0001 -->\n用 pnpm，不用 npm。\n"))
        XCTAssertEqual(memory.url.path, project.appendingPathComponent(".agentdesk/memory.md").path)
        let entries = memory.entries()
        XCTAssertEqual(entries.map(\.id), ["AAAA0001", "AAAA0002"])
        XCTAssertEqual(entries[0].author, .user)
        XCTAssertEqual(entries[0].source, "「重构 API」(5E2C1F0A)")
        XCTAssertEqual(entries[1].author, .model("Claude Code，sonnet"))
        XCTAssertNil(entries[1].source)
        XCTAssertEqual(entries[1].text, "测试用 `swift test`。\n不要跑 Live 测试。")
    }

    func testRemovingAnEntryKeepsTheUsersOwnText() throws {
        let memory = ProjectMemory(folder: project)
        let mine = "# 项目记忆\n\n我自己的说明，别动。\n\n### 2026-10-01 · 用户\n手写的一条，没有标记。\n"
        try FileManager.default.createDirectory(at: memory.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try mine.write(to: memory.url, atomically: true, encoding: .utf8)
        try memory.append(MemoryEntry(id: "BBBB0001", date: "2026-10-30", author: .user, source: nil, text: "要删的一条"))
        XCTAssertEqual(memory.entries().count, 2)
        XCTAssertEqual(memory.entries()[0].text, "手写的一条，没有标记。")
        try memory.remove(id: "BBBB0001")
        XCTAssertEqual(memory.text(), mine)
        let handwritten = try XCTUnwrap(memory.entries().first)
        try memory.remove(id: handwritten.id)
        XCTAssertFalse(memory.text().contains("手写的一条"))
        XCTAssertTrue(memory.text().contains("我自己的说明，别动。"))
    }

    func testBudgetOnlyWarns() throws {
        let memory = ProjectMemory(folder: project)
        for i in 0..<5 { try memory.append(MemoryEntry(date: "2026-10-30", author: .user, source: nil, text: String(repeating: "长", count: 900) + "\(i)")) }
        XCTAssertTrue(ProjectMemory.isOverBudget(memory.text()))
        XCTAssertEqual(memory.entries().count, 5, "nothing is deleted automatically")
        XCTAssertFalse(ProjectMemory.isOverBudget(String(repeating: "a", count: ProjectMemory.budget)))
    }

    // MARK: AGENTS.md reference

    func testAgentsGetsTheMemoryReferenceOnce() throws {
        XCTAssertTrue(try ProjectRules.addMemoryReference(in: project), "AGENTS.md is created when missing")
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("AGENTS.md"), encoding: .utf8), "<!-- AgentDesk 项目记忆，确认过的条目在这个文件里 -->\n@.agentdesk/memory.md\n")
        try "# 规则\n用 pnpm。".write(to: project.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        XCTAssertTrue(try ProjectRules.addMemoryReference(in: project))
        let text = try String(contentsOf: project.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# 规则\n用 pnpm。\n\n<!--"))
        XCTAssertFalse(try ProjectRules.addMemoryReference(in: project))
        XCTAssertTrue(ProjectRules.read(project).agentsReferenceMemory)
    }

    func testClaudeExpandsTheReferenceOthersGetAnAppendix() throws {
        try "用 pnpm。\n\n@.agentdesk/memory.md\n".write(to: project.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let rules = ProjectRules.read(project)
        let memory = "# 项目记忆\n\n### 2026-10-30 · 用户\n测试用 swift test。"
        let claude = RuleLayers.compose(provider: .claude, projectAccess: true, global: "", project: rules, memory: memory, node: "")
        XCTAssertNil(claude.text, "Claude Code expands @.agentdesk/memory.md itself")
        XCTAssertEqual(claude.sources.map(\.delivery), [.native, .native])
        for provider in [ProviderID.codex, .grok, .gemini] {
            let composed = RuleLayers.compose(provider: provider, projectAccess: true, global: "", project: rules, memory: memory, node: "")
            XCTAssertTrue(composed.text?.contains("## 项目记忆（.agentdesk/memory.md）\n\n# 项目记忆") == true, "\(provider)")
            XCTAssertEqual(composed.sources.map(\.layer), [.project, .memory])
            XCTAssertEqual(composed.sources.map(\.delivery), [.native, .injected])
        }
        let chat = RuleLayers.compose(provider: .claude, projectAccess: false, global: "", project: rules, memory: memory, node: "")
        XCTAssertTrue(chat.text?.contains("测试用 swift test。") == true, "--safe-mode reads no project files")
        try "用 pnpm。".write(to: project.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let unreferenced = RuleLayers.compose(provider: .claude, projectAccess: true, global: "", project: ProjectRules.read(project), memory: memory, node: "")
        XCTAssertEqual(unreferenced.sources.last?.delivery, .injected)
        let big = RuleLayers.compose(provider: .codex, projectAccess: true, global: "", project: rules, memory: String(repeating: "长", count: 4_001), node: "")
        XCTAssertTrue(big.sources.last?.note?.contains("建议整理") == true)
    }

    // MARK: Own memories stay off

    func testClaudeAutoMemoryIsOffAndCodexMemoriesStayOff() throws {
        for project in [false, true] {
            let args = try ClaudeBackend.commonArguments(modelID: "m", effort: nil, project: project)
            let settings = try XCTUnwrap(args.firstIndex(of: "--settings").map { args[$0 + 1] })
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any])
            XCTAssertEqual(object["autoMemoryEnabled"] as? Bool, false)
            XCTAssertEqual(object["instructionFiles"] as? String, project ? "claude-md-and-agents-md" : nil)
        }
        for project in [false, true] {
            XCTAssertTrue(try CodexBackend.appServerArguments(project: project).contains("features.memories=false"))
        }
    }

    // MARK: memory_propose

    func testHelperOffersMemoryProposeOnlyForAProject() throws {
        let exchange = FolderAccessExchange(root: data)
        XCTAssertFalse(FolderAccessServer(exchange: exchange, sessionID: UUID(), token: "t").tools.contains { $0["name"] as? String == "memory_propose" })
        let both = FolderAccessServer(exchange: exchange, sessionID: UUID(), token: "t", project: project)
        XCTAssertEqual(both.tools.compactMap { $0["name"] as? String }, ["list_directory", "read_file", "search_files", "memory_propose"])
        let memoryOnly = FolderAccessServer(exchange: exchange, sessionID: UUID(), token: "t", files: false, project: project)
        XCTAssertEqual(memoryOnly.tools.compactMap { $0["name"] as? String }, ["memory_propose"])
        XCTAssertEqual(memoryOnly.call("read_file", ["path": "~/x"])["isError"] as? Bool, true)
        let initialize = try XCTUnwrap(memoryOnly.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#))
        XCTAssertTrue(initialize.contains("memory_propose"))
    }

    func testProposalIsOnlyADraft() throws {
        let session = UUID()
        let server = FolderAccessServer(exchange: FolderAccessExchange(root: data), sessionID: session, token: "tok", project: project)
        let result = server.call("memory_propose", ["text": "  用 pnpm。 ", "reason": "用户纠正过两次"])
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProjectMemory(folder: project).url.path), "nothing is written before the user confirms")
        let proposals = MemoryProposalExchange(root: data).take()
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals.first?.text, "用 pnpm。")
        XCTAssertEqual(proposals.first?.reason, "用户纠正过两次")
        XCTAssertEqual(proposals.first?.sessionID, session)
        XCTAssertEqual(proposals.first?.token, "tok")
        XCTAssertTrue(MemoryProposalExchange(root: data).take().isEmpty, "taken once")
        XCTAssertEqual(server.call("memory_propose", ["text": " "])["isError"] as? Bool, true)
        XCTAssertEqual(server.call("memory_propose", ["text": String(repeating: "长", count: 1_001)])["isError"] as? Bool, true)
        XCTAssertEqual(FolderAccessServer(exchange: FolderAccessExchange(root: data), sessionID: session, token: "t").call("memory_propose", ["text": "x"])["isError"] as? Bool, true)
    }

    func testServerArgumentsNameTheProject() throws {
        let helper = root.appendingPathComponent("agentdesk-files")
        try "#!/bin/sh\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let id = UUID()
        guard case .stdio(_, let both)? = FolderAccessPolicy.server(helper: helper, dataRoot: data, sessionID: id, token: "t", project: project)?.transport else { return XCTFail() }
        XCTAssertEqual(Array(both.suffix(2)), ["--project", project.path])
        XCTAssertFalse(both.contains("--no-files"))
        guard case .stdio(_, let memoryOnly)? = FolderAccessPolicy.server(helper: helper, dataRoot: data, sessionID: id, token: "t", files: false, project: project)?.transport else { return XCTFail() }
        XCTAssertTrue(memoryOnly.contains("--no-files"))
        XCTAssertNil(FolderAccessPolicy.server(helper: helper, dataRoot: data, sessionID: id, token: "t", files: false), "no files and no project: no server")
    }
}
