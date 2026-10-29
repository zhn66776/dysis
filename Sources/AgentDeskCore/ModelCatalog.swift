import Foundation

public enum ModelCatalog {
    /// Documented Claude Code choices, not an account-entitlement discovery.
    /// Source (checked 2026-10-29):
    /// https://support.claude.com/en/articles/11940350-claude-code-model-configuration
    public static let claudeVersions: [(id: String, name: String)] = [
        ("claude-opus-5-5", "Opus 5.5"),
        ("claude-opus-5", "Opus 5"),
        ("claude-sonnet-5-5", "Sonnet 5.5"),
        ("claude-sonnet-5", "Sonnet 5"),
        ("claude-haiku-5-5", "Haiku 5.5")
    ]
    public static let claudeAliases: [(id: String, name: String)] = [
        ("opus", "Opus · 跟随官方更新"),
        ("sonnet", "Sonnet · 跟随官方更新"),
        ("haiku", "Haiku · 跟随官方更新")
    ]
    public static var claudeIDs: [String] { (claudeVersions + claudeAliases).map(\.id) }
    public static func claudeName(for id: String) -> String {
        (claudeVersions + claudeAliases).first(where: { $0.id == id })?.name ?? id
    }

    /// Parse model identifiers, never display the unfiltered command output.
    public static func cursorIDs(from output: String, family: String) -> [String] {
        let pattern = #"(?m)^\s*((?:cursor-)?"# + NSRegularExpression.escapedPattern(for: family) + #"[A-Za-z0-9._:/-]*)\s*(?:[-–—]|\s|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(output.startIndex..., in: output)
        var seen = Set<String>()
        return regex.matches(in: output, range: range).compactMap {
            guard let r = Range($0.range(at: 1), in: output) else { return nil }
            let id = String(output[r]); return seen.insert(id).inserted ? id : nil
        }
    }
}
