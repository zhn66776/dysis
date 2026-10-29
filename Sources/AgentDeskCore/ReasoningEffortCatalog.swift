import Foundation

/// Provider-facing effort values used by the small adapter layer. Claude's
/// values come from the installed `claude --help` (`2.1.308` on the checked
/// machine). Cursor's parameterized model syntax is documented at
/// https://cursor.com/docs/subagents and its model/account catalog remains
/// authoritative for which values a particular model accepts. The value
/// is kept as a string in requests and persisted records so a provider can add
/// a new documented value without changing old session files.
public enum ReasoningEffortCatalog {
    public static let commonChoices = ["low", "medium", "high", "xhigh", "max"]
    public static let claudeChoices = commonChoices
    /// Cursor's documented first-party Grok levels currently stop at xhigh;
    /// model/account catalogs remain the source of truth for other providers.
    public static let cursorChoices = ["low", "medium", "high", "xhigh"]
    private static let variantEfforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    public static func choices(for provider: ProviderID) -> [String] {
        switch provider {
        case .claude: return claudeChoices
        case .grok, .gemini: return [] // Use discovered variants for the exact model.
        case .codex: return [] // Codex is discovered from model/list.
        }
    }

    public static func label(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "默认" }
        switch value.lowercased() {
        case "none": return "关闭"
        case "minimal": return "最少"
        case "ultra": return "超高"
        case "low": return "低"
        case "medium": return "中"
        case "high": return "高"
        case "xhigh": return "极高"
        case "max": return "最大"
        default: return value
        }
    }

    public static func normalized(_ value: String?, choices: [String] = commonChoices) -> String? {
        guard let value else { return nil }
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !candidate.isEmpty else { return nil }
        return choices.contains(candidate) ? candidate : nil
    }

    /// Reads an effort parameter from a Cursor model variant returned by
    /// `--list-models`. Bare models have no selected effort and return nil.
    public static func cursorVariantEffort(modelID: String) -> String? {
        let value = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = value.lastIndex(of: "["), value.last == "]" {
            let start = value.index(after: open)
            let end = value.index(before: value.endIndex)
            for item in value[start..<end].split(separator: ",") {
                let pair = item.split(separator: "=", maxSplits: 1)
                if pair.count == 2, pair[0].trimmingCharacters(in: .whitespacesAndNewlines) == "effort" {
                    return String(pair[1]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }
            }
        }
        let token = value.split(separator: "[").first.map(String.init) ?? value
        for effort in variantEfforts.reversed() {
            if token.hasSuffix("-\(effort)-fast") { return effort }
            if token.hasSuffix("-\(effort)") { return effort }
        }
        return nil
    }

    /// Returns discovered Cursor variants for the same base model, keyed by
    /// their actual effort value. This never invents a model ID; an empty
    /// result means the account did not advertise parameterized variants.
    public static func cursorVariants(modelID: String, availableModelIDs: [String]) -> [String: String] {
        guard !modelID.contains("[") else { return [:] }
        let base = cursorVariantBase(modelID)
        var result: [String: String] = [:]
        for candidate in availableModelIDs {
            guard !candidate.contains("[") else { continue }
            let candidateBase = cursorVariantBase(candidate)
            guard candidateBase == base, let effort = cursorVariantEffort(modelID: candidate), variantEfforts.contains(effort) else { continue }
            result[effort] = candidate
        }
        return result
    }

    /// One entry per Cursor model family (effort variants folded together),
    /// represented by its medium or bare variant. `label` is the family name.
    public static func cursorFamilies(availableModelIDs: [String]) -> [(id: String, label: String)] {
        var order: [String] = [], chosen: [String: String] = [:]
        func rank(_ id: String) -> Int {
            switch cursorVariantEffort(modelID: id) { case "medium"?: return 0; case nil: return 1; default: return 2 }
        }
        for id in availableModelIDs where !id.contains("[") {
            let base = cursorVariantBase(id)
            if let current = chosen[base] {
                if rank(id) < rank(current) { chosen[base] = id }
            } else {
                order.append(base); chosen[base] = id
            }
        }
        return order.map { (chosen[$0]!, $0) }
    }

    public static func cursorFamily(of modelID: String) -> String { cursorVariantBase(modelID) }

    private static func cursorVariantBase(_ modelID: String) -> String {
        var value = modelID.split(separator: "[", maxSplits: 1).first.map(String.init) ?? modelID
        for effort in variantEfforts.reversed() {
            if value.hasSuffix("-\(effort)-fast") {
                value.removeLast("-\(effort)-fast".count)
                return value + "-fast"
            }
            if value.hasSuffix("-\(effort)") {
                value.removeLast("-\(effort)".count)
                return value
            }
        }
        return value
    }
}
