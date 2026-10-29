import Foundation

public struct PlazaRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID { room.id }
    public var room: MeetingRoom
    public var sharedContext: String
    public var runs: [MeetingRunRecord]
    public var messages: [MeetingMessage]

    public init(room: MeetingRoom, sharedContext: String = "", runs: [MeetingRunRecord] = [], messages: [MeetingMessage] = []) {
        self.room = room; self.sharedContext = sharedContext; self.runs = runs; self.messages = messages
    }
}

public final class PlazaStore {
    public let url: URL
    public init(root: URL) { url = root.appendingPathComponent("plazas.json") }

    public func load() throws -> [PlazaRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        var records = try JSONDecoder().decode([PlazaRecord].self, from: Data(contentsOf: url))
        for i in records.indices {
            records[i].runs = records[i].runs.map { $0.recoveredAfterRestart() }
            for j in records[i].messages.indices where records[i].messages[j].state == .running {
                records[i].messages[j].state = .stopped
            }
        }
        return records.sorted { $0.room.updatedAt > $1.room.updatedAt }
    }

    public func save(_ records: [PlazaRecord]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: url, options: .atomic)
    }
}
