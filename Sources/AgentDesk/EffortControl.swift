import SwiftUI
import AgentDeskCore

/// A provider-specific selector. Cursor changes only a discovered effort
/// variant of the same model, including the same fast-mode setting.
struct EffortControl: View {
    @ObservedObject var model: AppModel
    let provider: ProviderID
    @Binding var modelID: String
    @Binding var effort: String?
    var compact = false

    private var usesVariants: Bool { provider == .grok || provider == .gemini }
    private var variants: [String: String] {
        ReasoningEffortCatalog.cursorVariants(modelID: modelID, availableModelIDs: model.availableModels[provider] ?? [])
    }
    private var choices: [String] {
        if usesVariants { return ordered(Array(variants.keys)) }
        if provider == .codex {
            let selected = modelID.isEmpty ? model.configuration[.codex].modelID : modelID
            return model.codexEfforts[selected] ?? []
        }
        return ReasoningEffortCatalog.choices(for: provider)
    }
    private var selectedEffort: String? { usesVariants ? ReasoningEffortCatalog.cursorVariantEffort(modelID: modelID) : effort }
    private var display: String {
        guard let value = selectedEffort else { return "官方默认" }
        return "\(ReasoningEffortCatalog.label(value)) · \(value)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                ThemedMenu(title: "推理：\(display)") {
                    if !usesVariants {
                        Button("官方默认") { effort = nil }
                        Divider()
                    }
                    ForEach(choices, id: \.self) { value in
                        Button {
                            if usesVariants, let id = variants[value] { modelID = id; effort = nil }
                            else { effort = value }
                        } label: {
                            if value == selectedEffort { Label("\(ReasoningEffortCatalog.label(value)) · \(value)", systemImage: "checkmark") }
                            else { Text("\(ReasoningEffortCatalog.label(value)) · \(value)") }
                        }
                    }
                    if provider != .claude {
                        Divider()
                        Button("刷新可用档位") { discover() }
                    }
                }
                if choices.isEmpty && provider != .claude {
                    Button(model.isChecking.contains(provider) ? "读取中…" : "读取档位") { discover() }
                        .buttonStyle(GhostButtonStyle()).disabled(model.isChecking.contains(provider))
                }
            }
            if !compact {
                Text(guidance).font(Theme.sans(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(guidance)
    }

    private var guidance: String {
        if !model.developerModeEnabled {
            switch provider {
            case .claude: return "选择思考投入程度；较高档位通常需要更长时间。具体可用性取决于所选模型。"
            case .codex: return "可用档位随模型变化。选择“官方默认”会使用该模型当前的默认强度。"
            case .grok, .gemini: return "调整当前模型的推理强度，保留原有的模型系列和速度模式。"
            }
        }
        switch provider {
        case .claude: return "通过 Claude Code 的 --effort 传入。具体模型支持情况由官方 CLI 校验；更高档位通常需要更长时间。"
        case .codex: return "档位来自当前模型的官方列表。官方默认会在下一次回复时重新读取模型默认值。"
        case .grok, .gemini: return "从 Cursor 当前列表选择同一模型的推理档位，保留 Fast 等模式；不会切换到其他模型系列。"
        }
    }

    private func discover() { Task { await model.loadModels(provider) } }
    private func ordered(_ values: [String]) -> [String] {
        let order = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        return values.sorted { (order.firstIndex(of: $0) ?? 100) < (order.firstIndex(of: $1) ?? 100) }
    }
}
