import Foundation

public struct CanvasSearchHit: Encodable, Equatable, Sendable {
    public let nodeID: UUID
    public let messageID: UUID?
    public let excerpt: String
}

/// Search the owning sessions, including messages outside the card preview.
public enum CanvasSearch {
    public static func find(_ query: String, board: CanvasBoard, sessions: [UUID: ChatSession]) -> [CanvasSearchHit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return board.nodes.compactMap { node in
            guard let session = sessions[node.sessionID] else { return nil }
            if session.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil {
                return .init(nodeID: node.id, messageID: nil, excerpt: session.title)
            }
            guard let message = session.messages.reversed().first(where: { $0.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil }),
                  let range = message.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) else { return nil }
            let start = message.text.index(range.lowerBound, offsetBy: -45, limitedBy: message.text.startIndex) ?? message.text.startIndex
            let end = message.text.index(range.upperBound, offsetBy: 100, limitedBy: message.text.endIndex) ?? message.text.endIndex
            let excerpt = (start == message.text.startIndex ? "" : "…") + String(message.text[start..<end]).replacingOccurrences(of: "\n", with: " ") + (end == message.text.endIndex ? "" : "…")
            return .init(nodeID: node.id, messageID: message.id, excerpt: excerpt)
        }
    }
}
