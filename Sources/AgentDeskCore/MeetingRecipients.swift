import Foundation

/// Only call this on the human's composer. Model output is never routed.
public enum MeetingRecipients {
    public static func resolve(prompt: String, members: [MeetingMember], selected: Set<UUID>) -> Set<UUID> {
        let words = prompt.split(whereSeparator: { $0.isWhitespace || "，。,:：;；!?！？".contains($0) }).map(String.init)
        if words.contains("@everyone") { return Set(members.map(\.id)) }
        let mentions = words.filter { $0.hasPrefix("@") }
        if !mentions.isEmpty { return Set(members.filter { mentions.contains("@" + $0.name) }.map(\.id)) }
        return selected.intersection(Set(members.map(\.id)))
    }
}
