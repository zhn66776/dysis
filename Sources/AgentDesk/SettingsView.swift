import SwiftUI
import AgentDeskCore
#if os(macOS)
import AppKit
#endif

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Settings")
                        .titleText(20)
                    Text("Choose models, reasoning levels and account connections.")
                        .font(Theme.sans(12))
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                if model.developerModeEnabled {
                    ThemedChip(text: "Developer mode", tint: Theme.badBackground, ink: Theme.warn)
                }
                Button("Done") { model.saveConfiguration(); dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 18)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(ProviderID.allCases) { provider in
                        ProviderSettingsSection(model: model, provider: provider)
                    }
                    if model.developerModeEnabled { SecurityNote() }
                    HStack {
                        Text(model.developerModeEnabled ? "⌘⇧D Leave developer mode" : "⌘⇧D Developer mode")
                            .metaText()
                        Spacer()
                    }
                }
                .padding(24)
            }
        }
        .themedSurface()
    }
}

private struct ProviderSettingsSection: View {
    @ObservedObject var model: AppModel
    let provider: ProviderID

    private var config: Binding<ProviderConfiguration> {
        Binding(
            get: { model.configuration[provider] },
            set: { model.configuration[provider] = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                ProviderBadgeForSettings(provider: provider)
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.name)
                        .font(Theme.sans(13, weight: .medium))
                    if model.developerModeEnabled {
                        Text(provider.runtimeName)
                            .metaText()
                    }
                }
                Spacer()
                StatusPill(text: model.statusByProvider[provider] ?? "Not checked")
            }
            .foregroundStyle(Theme.providerInk(provider))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Theme.providerTint(provider))

            VStack(alignment: .leading, spacing: 12) {
                if model.developerModeEnabled {
                    ThemedRow(label: "Executable") {
                        TextField(defaultPath, text: config.executablePath)
                            .themedField(mono: true)
                    }
                }
                ThemedRow(label: "Default model") {
                    DefaultModelPicker(model: model, provider: provider, modelID: config.modelID)
                }
                ThemedRow(label: "Default reasoning") {
                    EffortControl(model: model, provider: provider, modelID: config.modelID, effort: config.reasoningEffort, english: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: config.wrappedValue.modelID) { _, _ in config.reasoningEffort.wrappedValue = nil }
                HStack(spacing: 8) {
                    Button("Check connection") {
                        Task { await model.checkProvider(provider) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.isChecking.contains(provider))
                    if provider != .claude {
                        Button(model.isChecking.contains(provider) ? "Loading…" : "Discover models") {
                            Task { await model.loadModels(provider) }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(model.isChecking.contains(provider))
                    }
                    Spacer()
                }
                if model.developerModeEnabled {
                    HStack(spacing: 8) {
                        Text("Login command")
                            .font(Theme.sans(11, weight: .medium))
                            .foregroundStyle(Theme.muted)
                        Text(loginCommand)
                            .font(Theme.mono(11))
                            .textSelection(.enabled)
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                        CopyCommandButton(command: loginCommand)
                    }
                }
                Text(helperText)
                    .font(Theme.sans(11))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
        .modifier(ProviderCard())
    }

    private var defaultPath: String {
        "Path to the official executable"
    }


    private var loginCommand: String {
        let configuredPath = config.wrappedValue.executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configuredPath.isEmpty else { return "Set the executable path first" }
        let executable = shellQuote(configuredPath)
        switch provider {
        case .claude: return "\(executable) auth login"
        case .codex: return executable
        case .grok, .gemini: return "\(executable) login"
        }
    }

    private func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private var helperText: String {
        if !model.developerModeEnabled {
            switch provider {
            case .claude: return "Defaults apply to new conversations; existing ones keep their own model and reasoning level."
            case .codex: return "Uses your ChatGPT account; models and reasoning levels come from the account's current list."
            case .grok: return "Uses your Cursor account and its model quota."
            case .gemini: return "Uses the Gemini models and quota in your Cursor account."
            }
        }
        switch provider {
        case .claude:
            return "Pinned versions use the full model ID; opus / sonnet / haiku follow official updates. The list comes from the official docs and does not confirm every model is available to this account. Changes affect new conversations only."
        case .codex:
            return "Uses the ChatGPT login of the Codex app-server. Do not enter an API key here."
        case .grok:
            return "Uses your Legacy Cursor Pro quota through the Cursor CLI; Grok usage comes from the Cursor Models pool."
        case .gemini:
            return "Uses the available Gemini models through the Cursor CLI; this spends Cursor quota, not Google AI Pro quota."
        }
    }
}

/// Default model for new conversations, chosen from a list only: Claude's
/// official versions and aliases, Codex models from model/list, and Cursor
/// model families (the reasoning picker then chooses the family's variant).
private struct DefaultModelPicker: View {
    @ObservedObject var model: AppModel
    let provider: ProviderID
    @Binding var modelID: String

    private struct Option: Hashable { let id: String; let label: String }

    private static let claudeVersions = ModelCatalog.claudeVersions.map { Option(id: $0.id, label: $0.name) }
    private static let claudeAliases = ModelCatalog.claudeAliases.map { Option(id: $0.id, label: "\($0.id.capitalized) · follows latest") }

    private var discovered: [Option] {
        let ids = model.availableModels[provider] ?? []
        switch provider {
        case .claude: return []
        case .codex: return ids.map { Option(id: $0, label: $0) }
        case .grok, .gemini: return ReasoningEffortCatalog.cursorFamilies(availableModelIDs: ids).map { Option(id: $0.id, label: $0.label) }
        }
    }

    private var isCursor: Bool { provider == .grok || provider == .gemini }

    private func isSelected(_ option: Option) -> Bool {
        isCursor ? ReasoningEffortCatalog.cursorFamily(of: modelID) == option.label : modelID == option.id
    }

    private var title: String {
        if modelID.isEmpty { return provider == .codex ? "Official default" : "Choose a model" }
        let all = provider == .claude ? Self.claudeVersions + Self.claudeAliases : discovered
        // A saved ID that is not in the current list still shows as it is.
        return all.first(where: isSelected)?.label ?? (isCursor ? ReasoningEffortCatalog.cursorFamily(of: modelID) : modelID)
    }

    var body: some View {
        ThemedMenu(title: title, mono: provider != .claude) {
            switch provider {
            case .claude:
                Section("Pinned versions") { options(Self.claudeVersions) }
                Section("Aliases") { options(Self.claudeAliases) }
            case .codex:
                choice(Option(id: "", label: "Official default"))
                if !discovered.isEmpty { Divider() }
                options(discovered)
            case .grok, .gemini:
                options(discovered)
            }
            if provider != .claude {
                if !discovered.isEmpty { Divider() }
                Button(discovered.isEmpty ? "Discover models" : "Refresh model list") { Task { await model.loadModels(provider) } }
                    .disabled(model.isChecking.contains(provider))
            }
        }
        .help(provider == .claude ? "Officially supported versions; availability depends on your Claude account." : "Choose from the models discovered for this account.")
    }

    private func options(_ list: [Option]) -> some View {
        ForEach(list, id: \.self) { choice($0) }
    }

    private func choice(_ option: Option) -> some View {
        Button { modelID = option.id } label: {
            if isSelected(option) { Label(option.label, systemImage: "checkmark") } else { Text(option.label) }
        }
    }
}

private struct ProviderBadgeForSettings: View {
    let provider: ProviderID
    var body: some View {
        ProviderIcon(provider: provider, size: 22)
    }
}

/// Settings card with a provider-tinted head, like a canvas node.
private struct ProviderCard: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius(scheme)))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius(scheme)).strokeBorder(Theme.border2, lineWidth: 0.5))
    }
}

private struct StatusPill: View {
    let text: String
    var body: some View {
        Text(text)
            .metaText()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Theme.card.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct CopyCommandButton: View {
    let command: String
    @State private var copied = false

    var body: some View {
        Button {
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            #endif
            copied = true
            Task {
                try? await Task.sleep(for: .milliseconds(1200))
                copied = false
            }
        } label: {
            Text(copied ? "Copied" : "Copy")
        }
        .buttonStyle(GhostButtonStyle())
        .help("Copy the login command")
        .disabled(command.hasPrefix("Set the"))
    }
}

private struct SecurityNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Authentication")
                .font(Theme.sans(12, weight: .medium))
            Text("AgentDesk only starts the official CLIs or app-server and lets them handle sign-in. Never enter API keys, OAuth tokens or Keychain contents in Settings.")
                .font(Theme.sans(11))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 8))
    }
}
