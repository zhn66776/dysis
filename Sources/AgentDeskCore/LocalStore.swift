import Foundation

public final class LocalStore {
    public let root: URL
    public var sessionsURL: URL { root.appendingPathComponent("sessions.json") }
    public var configurationURL: URL { root.appendingPathComponent("settings.json") }
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public init(root: URL? = nil) throws {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AgentDesk", isDirectory: true)
        encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    public func loadSessions() throws -> [ChatSession] {
        guard FileManager.default.fileExists(atPath: sessionsURL.path) else { return [] }
        var sessions = try decoder.decode([ChatSession].self, from: Data(contentsOf: sessionsURL))
        for i in sessions.indices {
            for j in sessions[i].messages.indices where sessions[i].messages[j].state == .streaming {
                sessions[i].messages[j].state = .cancelled
            }
        }
        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }
    public func saveSessions(_ sessions: [ChatSession]) throws {
        try encoder.encode(sessions).write(to: sessionsURL, options: .atomic)
    }
    public func loadConfiguration() throws -> AppConfiguration? {
        guard FileManager.default.fileExists(atPath: configurationURL.path) else { return nil }
        return try decoder.decode(AppConfiguration.self, from: Data(contentsOf: configurationURL))
    }
    public func saveConfiguration(_ configuration: AppConfiguration) throws {
        try encoder.encode(configuration).write(to: configurationURL, options: .atomic)
    }
    public func makeWorkspace(for id: UUID) throws -> URL {
        let url = root.appendingPathComponent("Workspaces", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let cursorDirectory = url.appendingPathComponent(".cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: cursorDirectory, withIntermediateDirectories: true)
        let permissions: [String: Any] = ["permissions": ["allow": [String](), "deny": ["Shell(*)", "Read(**)", "Read(*)", "Write(**)", "Write(*)", "WebFetch(*)", "Mcp(*:*)"]]]
        let settings = cursorDirectory.appendingPathComponent("cli.json")
        if !FileManager.default.fileExists(atPath: settings.path) {
            try JSONSerialization.data(withJSONObject: permissions, options: [.prettyPrinted, .sortedKeys]).write(to: settings, options: .atomic)
        }
        return url
    }
}
