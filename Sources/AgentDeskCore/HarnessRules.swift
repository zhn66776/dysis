import CryptoKit
import Foundation

/// The three rule layers of design/HARNESS.md §3 H4, lowest priority first:
/// AgentDesk's global rules, the project's `AGENTS.md`, and the node's own
/// rules. Each CLI reads what it can natively; the rest is injected through
/// one channel per CLI (Claude `--append-system-prompt`, Codex
/// `developerInstructions`, a leading block for Cursor).
public enum RuleLayer: String, Codable, Sendable { case global, project, memory, node }

/// How one layer reaches the model this turn.
public enum RuleDelivery: String, Codable, Sendable {
    /// AgentDesk puts the text into the CLI's instruction channel.
    case injected
    /// The CLI reads the file itself from the project folder.
    case native
}

public struct RuleSource: Equatable, Sendable {
    public var layer: RuleLayer
    public var title: String
    /// The file it comes from, if any.
    public var path: String?
    public var characters: Int
    public var delivery: RuleDelivery
    /// Why it is delivered this way, for the context preview.
    public var note: String?
    public init(layer: RuleLayer, title: String, path: String? = nil, characters: Int, delivery: RuleDelivery, note: String? = nil) {
        self.layer = layer; self.title = title; self.path = path; self.characters = characters; self.delivery = delivery; self.note = note
    }
}

/// What a turn carries: the text to inject (nil when nothing is) and every
/// active source, injected or read natively.
public struct ComposedRules: Equatable, Sendable {
    public var text: String?
    public var sources: [RuleSource]
    public init(text: String?, sources: [RuleSource]) { self.text = text; self.sources = sources }
}

/// AgentDesk's global rules: one Markdown file in the app data folder.
public struct GlobalRulesStore: Sendable {
    public let url: URL
    public init(root: URL) { url = root.appendingPathComponent("rules.md") }
    public func load() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    public func save(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { try? FileManager.default.removeItem(at: url); return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (trimmed + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

/// The project's rule files as they are on disk now.
public struct ProjectRules: Equatable, Sendable {
    public enum ClaudeFile: Equatable, Sendable {
        case missing
        /// `CLAUDE.md` imports `@AGENTS.md`.
        case importsAgents
        /// `CLAUDE.md` exists without the import; AgentDesk only suggests the line.
        case withoutImport
    }

    public static let agentsFile = "AGENTS.md"
    public static let claudeFile = "CLAUDE.md"
    public static let claudeImportLine = "@AGENTS.md"
    public static let memoryImportLine = "@" + ProjectMemory.relativePath

    public let folder: URL
    /// nil when the project has no `AGENTS.md`.
    public var agents: String?
    public var claude: ClaudeFile

    public init(folder: URL, agents: String?, claude: ClaudeFile) { self.folder = folder; self.agents = agents; self.claude = claude }

    public static func read(_ folder: URL) -> ProjectRules {
        let agents = try? String(contentsOf: folder.appendingPathComponent(agentsFile), encoding: .utf8)
        let claude: ClaudeFile
        if let text = try? String(contentsOf: folder.appendingPathComponent(claudeFile), encoding: .utf8) {
            claude = imports(text, file: agentsFile) ? .importsAgents : .withoutImport
        } else { claude = .missing }
        return ProjectRules(folder: folder, agents: agents, claude: claude)
    }

    public var agentsURL: URL { folder.appendingPathComponent(Self.agentsFile) }
    public var claudeURL: URL { folder.appendingPathComponent(Self.claudeFile) }

    /// `AGENTS.md` imports the project memory (`@.agentdesk/memory.md`).
    public var agentsReferenceMemory: Bool { agents.map { Self.imports($0, file: ProjectMemory.relativePath) } ?? false }

    /// Claude Code's `@path` import: `@file` or `@./file` as its own word.
    static func imports(_ text: String, file: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: file)
        return text.range(of: "(^|\\s)@(\\./)?\(escaped)(\\s|$)", options: .regularExpression) != nil
    }

    /// Writes `AGENTS.md` (the project settings' editor).
    public static func saveAgents(_ text: String, in folder: URL) throws {
        try text.write(to: folder.appendingPathComponent(agentsFile), atomically: true, encoding: .utf8)
    }

    /// Creates `CLAUDE.md` containing only `@AGENTS.md`, after the user agreed.
    /// An existing `CLAUDE.md` is never touched.
    public static func createClaudeImport(in folder: URL) throws {
        let url = folder.appendingPathComponent(claudeFile)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw HarnessRulesError.claudeFileExists }
        // withoutOverwriting: a file that appeared in the meantime is kept.
        try Data((claudeImportLine + "\n").utf8).write(to: url, options: .withoutOverwriting)
    }

    /// Adds `@.agentdesk/memory.md` at the end of `AGENTS.md` (creating it
    /// when missing) so a CLI that expands imports reads the memory.
    /// Returns whether the file changed.
    @discardableResult
    public static func addMemoryReference(in folder: URL) throws -> Bool {
        let url = folder.appendingPathComponent(agentsFile)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard !imports(existing, file: ProjectMemory.relativePath) else { return false }
        var text = existing
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        if !text.isEmpty { text += "\n" }
        text += "<!-- AgentDesk 项目记忆，确认过的条目在这个文件里 -->\n\(memoryImportLine)\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        return true
    }
}

public enum HarnessRulesError: LocalizedError, Equatable {
    case claudeFileExists
    public var errorDescription: String? {
        switch self {
        case .claudeFileExists: return "项目里已经有 CLAUDE.md，AgentDesk 不会改它。需要时请自己在里面加一行 @AGENTS.md。"
        }
    }
}

public enum RuleLayers {
    /// What each CLI reads from the project folder on its own.
    /// - Claude Code: only in project mode (chat mode runs with `--safe-mode`),
    ///   with `instructionFiles: claude-md-and-agents-md` so `AGENTS.md` loads
    ///   beside any `CLAUDE.md` (once, when `CLAUDE.md` already imports it),
    ///   and its `@` imports expanded.
    /// - Codex: `AGENTS.md` as its project doc; `@` lines stay literal.
    /// - Cursor: `AGENTS.md` as a rule; `@` lines stay literal (unverified).
    public static func readsAgentsNatively(_ provider: ProviderID, projectAccess: Bool) -> Bool {
        provider == .claude ? projectAccess : true
    }

    /// Only Claude Code expands `@file` lines; Codex and Cursor get the
    /// memory as an appendix to the project rules.
    public static func expandsImports(_ provider: ProviderID) -> Bool { provider == .claude }

    /// Builds this turn's rules. `project` is nil outside a project board.
    public static func compose(provider: ProviderID, projectAccess: Bool, global: String, project: ProjectRules?, memory: String? = nil, node: String) -> ComposedRules {
        var blocks: [(String, String)] = []
        var sources: [RuleSource] = []
        let global = global.trimmingCharacters(in: .whitespacesAndNewlines)
        if !global.isEmpty {
            blocks.append(("AgentDesk 全局规则", global))
            sources.append(RuleSource(layer: .global, title: "AgentDesk 全局规则", characters: global.count, delivery: .injected))
        }
        if let project {
            let agents = project.agents?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let native = readsAgentsNatively(provider, projectAccess: projectAccess)
            if !agents.isEmpty {
                if native {
                    let how = provider == .claude
                        ? (project.claude == .importsAgents ? "Claude Code 通过 CLAUDE.md 的 @AGENTS.md 读取" : "Claude Code 按 instructionFiles 设置读取")
                        : "\(provider.runtimeName) 自己读取"
                    sources.append(RuleSource(layer: .project, title: "项目规则", path: project.agentsURL.path, characters: agents.count, delivery: .native, note: how))
                } else {
                    blocks.append(("项目规则（AGENTS.md）", agents))
                    sources.append(RuleSource(layer: .project, title: "项目规则", path: project.agentsURL.path, characters: agents.count, delivery: .injected,
                                              note: "聊天模式下 Claude Code 不读项目文件，由 AgentDesk 注入"))
                }
            }
            let memory = memory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !memory.isEmpty {
                let path = project.folder.appendingPathComponent(ProjectMemory.relativePath).path
                let over = ProjectMemory.isOverBudget(memory) ? "；超过 \(ProjectMemory.budget.formatted()) 字，建议整理" : ""
                if native && expandsImports(provider) && project.agentsReferenceMemory {
                    sources.append(RuleSource(layer: .memory, title: "项目记忆", path: path, characters: memory.count, delivery: .native, note: "AGENTS.md 的 \(ProjectRules.memoryImportLine) 引用" + over))
                } else {
                    blocks.append(("项目记忆（\(ProjectMemory.relativePath)）", memory))
                    let why = expandsImports(provider) ? (native ? "AGENTS.md 没有引用记忆，由 AgentDesk 注入" : "聊天模式下由 AgentDesk 注入") : "\(provider.runtimeName) 不展开 @ 引用，作为项目规则的附录注入"
                    sources.append(RuleSource(layer: .memory, title: "项目记忆", path: path, characters: memory.count, delivery: .injected, note: why + over))
                }
            }
        }
        let node = node.trimmingCharacters(in: .whitespacesAndNewlines)
        if !node.isEmpty {
            blocks.append(("本节点规则", node))
            sources.append(RuleSource(layer: .node, title: "本节点规则", characters: node.count, delivery: .injected))
        }
        guard !blocks.isEmpty else { return ComposedRules(text: nil, sources: sources) }
        let text = "以下规则由 AgentDesk 提供，越靠后的优先级越高。\n\n" + blocks.map { "## \($0.0)\n\n\($0.1)" }.joined(separator: "\n\n")
        return ComposedRules(text: text, sources: sources)
    }

    /// Cursor has no system prompt flag: the rules go ahead of the message as
    /// a separate, marked block.
    public static func cursorPrompt(_ prompt: String, rules: String?) -> String {
        guard let rules, !rules.isEmpty else { return prompt }
        return "<agentdesk-rules>\n\(rules)\n</agentdesk-rules>\n\n" + prompt
    }
}

// MARK: Command policy

/// "Always allow this kind of command" answers, kept per project in the app
/// data folder (not in the project, where an agent could edit its own
/// permissions). Shown and removable in the project settings. Format and
/// the approval side: design/HARNESS.md §3 H4 "命令许可".
public struct CommandPolicyRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// The provider whose approval produced it; the rule applies to all.
    public var provider: ProviderID
    /// argv prefix, e.g. ["git", "status"]; a command matches when its argv starts with it.
    public var prefix: [String]
    public var createdAt: Date
    /// The node whose approval added it.
    public var sourceSessionID: UUID?
    public var sourceTitle: String?
    public init(id: UUID = UUID(), provider: ProviderID, prefix: [String], createdAt: Date = Date(), sourceSessionID: UUID? = nil, sourceTitle: String? = nil) {
        self.id = id; self.provider = provider; self.prefix = prefix; self.createdAt = createdAt; self.sourceSessionID = sourceSessionID; self.sourceTitle = sourceTitle
    }

    public var display: String { prefix.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ") }

    public func matches(_ argv: [String]) -> Bool { !prefix.isEmpty && argv.count >= prefix.count && Array(argv.prefix(prefix.count)) == prefix }

    /// Claude Code `--allowedTools` form: `Bash(git status:*)`.
    public var claudeAllowedTool: String { "Bash(\(prefix.joined(separator: " ")):*)" }
}

public struct ProjectCommandPolicy: Codable, Equatable, Sendable {
    public var version = 1
    public var projectPath: String
    public var commands: [CommandPolicyRule]
    public init(projectPath: String, commands: [CommandPolicyRule] = []) { self.projectPath = projectPath; self.commands = commands }
    public func allows(_ argv: [String]) -> Bool { commands.contains { $0.matches(argv) } }
}

/// `<data>/project-policies/<sha256(path) prefix>.json`, one file per project folder.
public struct CommandPolicyStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root.appendingPathComponent("project-policies", isDirectory: true) }

    public func url(projectPath: String) -> URL {
        let digest = SHA256.hash(data: Data(URL(fileURLWithPath: projectPath).standardizedFileURL.path.utf8))
        return root.appendingPathComponent(digest.prefix(12).map { String(format: "%02x", $0) }.joined() + ".json")
    }

    public func load(projectPath: String) -> ProjectCommandPolicy {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url(projectPath: projectPath)),
              let policy = try? decoder.decode(ProjectCommandPolicy.self, from: data) else { return ProjectCommandPolicy(projectPath: projectPath) }
        return policy
    }

    public func save(_ policy: ProjectCommandPolicy) throws {
        let file = url(projectPath: policy.projectPath)
        if policy.commands.isEmpty { try? FileManager.default.removeItem(at: file); return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(policy).write(to: file, options: .atomic)
    }

    /// Adds a rule unless the same prefix is already allowed.
    @discardableResult
    public func add(_ rule: CommandPolicyRule, projectPath: String) throws -> ProjectCommandPolicy {
        var policy = load(projectPath: projectPath)
        if !policy.commands.contains(where: { $0.prefix == rule.prefix }) { policy.commands.append(rule) }
        try save(policy)
        return policy
    }

    @discardableResult
    public func remove(_ id: UUID, projectPath: String) throws -> ProjectCommandPolicy {
        var policy = load(projectPath: projectPath)
        policy.commands.removeAll { $0.id == id }
        try save(policy)
        return policy
    }
}
