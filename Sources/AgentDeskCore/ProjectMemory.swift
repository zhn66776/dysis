import Foundation

/// Project memory (design/HARNESS.md §3 H5): `.agentdesk/memory.md` in the
/// project folder, visible and editable, written only after the user
/// confirms an entry. Each entry is a `### ` heading with its date, author
/// and source node, then its text:
///
///     ### 2026-10-30 · 用户 · 来自「重构 API」(5E2C1F0A)
///     <!-- agentdesk-memory: 1A2B3C4D -->
///     用 pnpm，不用 npm。
///
/// Anything else in the file (the user's own notes) is kept as it is.
public struct ProjectMemory: Sendable {
    public static let relativePath = ".agentdesk/memory.md"
    /// Above this many characters AgentDesk asks the user to tidy up; nothing is deleted automatically.
    public static let budget = 4_000
    /// One entry's text at most.
    public static let maxEntryCharacters = 1_000

    public let folder: URL
    public init(folder: URL) { self.folder = folder }
    public var url: URL { folder.appendingPathComponent(Self.relativePath) }

    public static let header = """
    # 项目记忆

    AgentDesk 维护的项目记忆，用户确认过的条目才会写进来。每条以「### 日期 · 作者 · 来源」开头；可以直接编辑或删除。超过 \(budget.formatted()) 字时 AgentDesk 会提醒整理，不会自动删除。

    """

    /// The file's text, or "" when there is none.
    public func text() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    public func entries() -> [MemoryEntry] { Self.parse(text()) }

    public static func isOverBudget(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).count > budget }

    /// Appends one entry, creating the file (and `.agentdesk/`) when needed.
    @discardableResult
    public func append(_ entry: MemoryEntry) throws -> String {
        var text = self.text()
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = Self.header }
        if !text.hasSuffix("\n") { text += "\n" }
        if !text.hasSuffix("\n\n") { text += "\n" }
        text += Self.render(entry)
        try write(text)
        return text
    }

    /// Removes the entry the user deleted; the rest of the file is unchanged.
    public func remove(id: String) throws {
        let text = self.text()
        let lines = text.components(separatedBy: "\n")
        guard let block = Self.blocks(lines).first(where: { Self.entry(lines[$0])?.id == id }) else { return }
        var kept = Array(lines[..<block.lowerBound]) + Array(lines[block.upperBound...])
        while kept.count >= 2, kept[kept.count - 1].isEmpty, kept[kept.count - 2].isEmpty { kept.removeLast() }
        try write(kept.joined(separator: "\n"))
    }

    private func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func render(_ entry: MemoryEntry) -> String {
        var heading = "### \(entry.date) · \(entry.author.label)"
        if let source = entry.source, !source.isEmpty { heading += " · 来自\(source)" }
        return heading + "\n<!-- agentdesk-memory: \(entry.id) -->\n" + entry.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    public static func parse(_ text: String) -> [MemoryEntry] {
        let lines = text.components(separatedBy: "\n")
        return blocks(lines).compactMap { range in
            guard var entry = entry(lines[range]) else { return nil }
            entry.text = lines[range].dropFirst().filter { !$0.hasPrefix("<!-- agentdesk-memory:") }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return entry
        }
    }

    /// Line ranges of the entries: a `### ` line up to the next heading.
    private static func blocks(_ lines: [String]) -> [Range<Int>] {
        let isHeading = { (line: String) in ["# ", "## ", "### "].contains { line.hasPrefix($0) } }
        return lines.indices.filter { lines[$0].hasPrefix("### ") }.map { start in
            start..<((start + 1..<lines.count).first { isHeading(lines[$0]) } ?? lines.count)
        }
    }

    /// Heading and id of one block; the id is the marker's, or derived from the heading when the user wrote the entry by hand.
    private static func entry(_ block: ArraySlice<String>) -> MemoryEntry? {
        guard let heading = block.first, heading.hasPrefix("### ") else { return nil }
        let parts = heading.dropFirst(4).components(separatedBy: " · ")
        let marker = block.dropFirst().first { $0.hasPrefix("<!-- agentdesk-memory:") }
        let id = marker.map { $0.replacingOccurrences(of: "<!-- agentdesk-memory:", with: "").replacingOccurrences(of: "-->", with: "").trimmingCharacters(in: .whitespaces) }
            ?? String(format: "%08X", heading.utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 })
        let source = parts.count > 2 ? parts[2...].joined(separator: " · ") : nil
        return MemoryEntry(id: id, date: parts.first ?? "", author: MemoryAuthor(label: parts.count > 1 ? parts[1] : ""), source: source.map { $0.hasPrefix("来自") ? String($0.dropFirst(2)) : $0 }, text: "")
    }
}

public enum MemoryAuthor: Equatable, Sendable {
    case user
    /// The model that proposed it, e.g. "Claude Code，sonnet".
    case model(String)

    public var label: String {
        switch self {
        case .user: return "用户"
        case .model(let name): return name.isEmpty ? "模型" : "模型（\(name)）"
        }
    }

    init(label: String) {
        if label.hasPrefix("模型") {
            self = .model(label.dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: "（）() ")))
        } else { self = .user }
    }
}

public struct MemoryEntry: Equatable, Identifiable, Sendable {
    public var id: String
    /// yyyy-MM-dd
    public var date: String
    public var author: MemoryAuthor
    /// The source node, e.g. "「重构 API」(5E2C1F0A)".
    public var source: String?
    public var text: String

    public init(id: String = String(UUID().uuidString.prefix(8)), date: String, author: MemoryAuthor, source: String?, text: String) {
        self.id = id; self.date = date; self.author = author; self.source = source; self.text = text
    }

    public static func day(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    public static func source(title: String, sessionID: UUID) -> String {
        "「\(title.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: " · ", with: " "))」(\(sessionID.uuidString.prefix(8)))"
    }
}

/// An entry the model proposed through `memory_propose`. Like folder
/// requests, it passes as a file in the data folder: the files helper is
/// started by the CLI, not by AgentDesk. The app shows it as a draft and
/// writes it only when the user confirms.
public struct MemoryProposal: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var token: String
    public var sessionID: UUID
    public var text: String
    public var reason: String?
    public var createdAt: Date
    public init(id: UUID = UUID(), token: String, sessionID: UUID, text: String, reason: String?, createdAt: Date = Date()) {
        self.id = id; self.token = token; self.sessionID = sessionID; self.text = text; self.reason = reason; self.createdAt = createdAt
    }
}

public struct MemoryProposalExchange: Sendable {
    public let directory: URL
    public init(root: URL) { directory = root.appendingPathComponent("memory-proposals", isDirectory: true) }

    public func post(_ proposal: MemoryProposal) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(proposal).write(to: directory.appendingPathComponent("\(proposal.id.uuidString).json"), options: .atomic)
    }

    /// Takes every waiting proposal, oldest first; their files are removed.
    public func take() -> [MemoryProposal] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var proposals: [MemoryProposal] = []
        for file in files where file.pathExtension == "json" {
            if let proposal = try? decoder.decode(MemoryProposal.self, from: Data(contentsOf: file)) { proposals.append(proposal) }
            try? FileManager.default.removeItem(at: file)
        }
        return proposals.sorted { $0.createdAt < $1.createdAt }
    }
}
