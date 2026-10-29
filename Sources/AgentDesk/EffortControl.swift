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
    /// Settings is in English; the classic window keeps Chinese.
    var english = false

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
        guard let value = selectedEffort else { return english ? "Official default" : "官方默认" }
        return choiceLabel(value)
    }
    private func choiceLabel(_ value: String) -> String { english ? value : "\(ReasoningEffortCatalog.label(value)) · \(value)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                ThemedMenu(title: (english ? "Reasoning: " : "推理：") + display) {
                    if !usesVariants {
                        Button(english ? "Official default" : "官方默认") { effort = nil }
                        Divider()
                    }
                    ForEach(choices, id: \.self) { value in
                        Button {
                            if usesVariants, let id = variants[value] { modelID = id; effort = nil }
                            else { effort = value }
                        } label: {
                            if value == selectedEffort { Label(choiceLabel(value), systemImage: "checkmark") }
                            else { Text(choiceLabel(value)) }
                        }
                    }
                    if provider != .claude {
                        Divider()
                        Button(english ? "Refresh available levels" : "刷新可用档位") { discover() }
                    }
                }
                if choices.isEmpty && provider != .claude {
                    Button(model.isChecking.contains(provider) ? (english ? "Loading…" : "读取中…") : (english ? "Load levels" : "读取档位")) { discover() }
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
        if english { return englishGuidance }
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

    private var englishGuidance: String {
        if !model.developerModeEnabled {
            switch provider {
            case .claude: return "How much the model thinks; higher levels usually take longer. Availability depends on the selected model."
            case .codex: return "Levels depend on the model. Official default uses the model's current default level."
            case .grok, .gemini: return "Changes the reasoning level of the current model and keeps its family and speed mode."
            }
        }
        switch provider {
        case .claude: return "Passed to Claude Code as --effort. The official CLI checks model support; higher levels usually take longer."
        case .codex: return "Levels come from the model's official list. Official default re-reads the model's default on the next reply."
        case .grok, .gemini: return "Picks a reasoning level of the same model from Cursor's current list and keeps modes such as Fast; never switches to another model family."
        }
    }

    private func discover() { Task { await model.loadModels(provider) } }
    private func ordered(_ values: [String]) -> [String] {
        let order = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        return values.sorted { (order.firstIndex(of: $0) ?? 100) < (order.firstIndex(of: $1) ?? 100) }
    }
}
