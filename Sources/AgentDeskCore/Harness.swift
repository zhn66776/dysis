import Foundation

/// How much a trusted project lets the CLI do without asking (design/HARNESS.md H1).
/// A board sets it; a node can only go lower.
public enum PermissionLevel: String, Codable, CaseIterable, Comparable, Sendable {
    /// Reads; writes, commands and network ask.
    case readOnly
    /// Reads and writes in the folder; commands, network and writes elsewhere ask.
    case ask
    /// Everything runs without asking (the behaviour before H1).
    case auto

    public var label: String {
        switch self { case .readOnly: return "只读"; case .ask: return "询问"; case .auto: return "自动" }
    }

    private var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

/// What a conversation runs with this turn.
public enum HarnessMode: Equatable, Sendable {
    /// Not in a trusted project folder: tool-free chat.
    case chat
    case project(PermissionLevel)

    /// "chat", or the level's raw value; the page maps it to a label.
    public var key: String {
        switch self { case .chat: return "chat"; case .project(let level): return level.rawValue }
    }

    public var label: String {
        switch self { case .chat: return "聊天"; case .project(let level): return "项目 · \(level.label)" }
    }

    public var level: PermissionLevel? {
        if case .project(let level) = self { return level }
        return nil
    }

    /// The single place that decides the mode: a trusted project whose
    /// folder is the conversation's working directory, at the board's level
    /// or the node's lower one.
    /// `writable`, when the canvas gives it, replaces the folder check: a node
    /// writes in its own worktree, and a node that may not write this turn chats.
    public static func resolve(project: CanvasProject?, nodeLevel: PermissionLevel?, workingDirectory: String, writable: Bool? = nil) -> HarnessMode {
        guard let project, let level = project.level, writable ?? (project.path == workingDirectory) else { return .chat }
        return .project(min(level, nodeLevel ?? level))
    }
}

extension HarnessMode {
    /// A canvas node's mode between turns: its own worktree counts as the
    /// project folder, and a merge node without one only reads (as `CanvasWriteAccess`).
    public static func resolve(board: CanvasBoard, node: CanvasNode, session: ChatSession) -> HarnessMode {
        let writable: Bool? = node.worktree.map { $0.workingDirectory == session.workingDirectory } ?? (node.merge != nil ? false : nil)
        return resolve(project: board.project, nodeLevel: node.permissionLevel, workingDirectory: session.workingDirectory, writable: writable)
    }
}

extension CanvasProject {
    /// The board's level once trusted. Projects trusted before levels existed
    /// stay automatic, so their behaviour does not change silently.
    public var level: PermissionLevel? {
        guard isTrusted else { return nil }
        return permissionLevel ?? .auto
    }
}

/// The read-only "本轮的 harness 设置" lines in the context preview.
public enum HarnessSummary {
    public static func lines(provider: ProviderID, mode: HarnessMode, workingDirectory: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let folder = workingDirectory.path.hasPrefix(home.path + "/") ? "~" + workingDirectory.path.dropFirst(home.path.count) : workingDirectory.path
        var lines = ["Harness：\(provider.subtitle)（\(command(provider))）", "模式：\(mode.label)", "权限：\(permissions(provider, mode))", "工作目录：\(folder)"]
        let rules = ruleFiles(provider: provider, mode: mode, in: workingDirectory)
        lines.append(rules.isEmpty ? "规则文件：没有加载项目规则文件" : "规则文件：\(rules.joined(separator: "、"))")
        return lines
    }

    static func command(_ provider: ProviderID) -> String {
        switch provider { case .claude: return "claude -p"; case .codex: return "codex app-server"; case .grok, .gemini: return "agent --print" }
    }

    public static func permissions(_ provider: ProviderID, _ mode: HarnessMode) -> String {
        switch (provider, mode) {
        case (.claude, .chat): return "内置工具关闭，只回答文字"
        case (.claude, .project(.readOnly)): return "permission-mode default：读项目文件不问；改文件、运行命令、联网前先问你"
        case (.claude, .project(.ask)): return "permission-mode default：读、改项目里的文件不问；运行命令、联网、改项目外的文件前先问你"
        case (.claude, .project(.auto)): return "permission-mode bypassPermissions：所有工具都不询问"
        case (.codex, .chat): return "沙箱 read-only，shell 关闭，只回答文字"
        case (.codex, .project(.readOnly)): return "沙箱 read-only，不联网；approval untrusted：除只读命令外，运行命令和改文件前先问你"
        case (.codex, .project(.ask)): return "沙箱 workspace-write，不联网；approval untrusted：除只读命令外，运行命令和改文件前先问你"
        case (.codex, .project(.auto)): return "沙箱 workspace-write，可以联网；approval never：不询问"
        case (_, .chat): return "--mode ask，读文件和命令都被拒绝，只回答文字"
        case (_, .project(.readOnly)): return "--mode ask：只读，不能改文件或运行命令"
        case (_, .project(.ask)): return "Cursor 的 --print 不能逐条确认：只允许读写项目文件，不能运行命令（.cursor/cli.json）"
        case (_, .project(.auto)): return "--force，沙箱关闭：所有工具都不询问"
        }
    }

    /// Instruction files the CLI reads from the folder itself, as found on disk.
    static func ruleFiles(provider: ProviderID, mode: HarnessMode, in folder: URL) -> [String] {
        guard mode != .chat else { return [] }
        let candidates: [String]
        switch provider {
        case .claude: candidates = ["CLAUDE.md", "CLAUDE.local.md", ".claude/CLAUDE.md", ".claude/settings.json"]
        case .codex: candidates = ["AGENTS.md", "AGENTS.override.md"]
        case .grok, .gemini: candidates = ["AGENTS.md", ".cursorrules", ".cursor/rules"]
        }
        return candidates.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }
}
