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
                    Text("设置")
                        .titleText(20)
                    Text("选择模型、推理强度和账号连接。")
                        .font(Theme.sans(12))
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                if model.developerModeEnabled {
                    ThemedChip(text: "开发者模式", tint: Theme.badBackground, ink: Theme.warn)
                }
                Button("完成") { model.saveConfiguration(); dismiss() }
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
                        Text(model.developerModeEnabled ? "⌘⇧D 退出开发者模式" : "⌘⇧D 开发者模式")
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
                StatusPill(text: model.statusByProvider[provider] ?? "未检查")
            }
            .foregroundStyle(Theme.providerInk(provider))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Theme.providerTint(provider))

            VStack(alignment: .leading, spacing: 12) {
                if model.developerModeEnabled {
                    ThemedRow(label: "可执行文件") {
                        TextField(defaultPath, text: config.executablePath)
                            .themedField(mono: true)
                    }
                }
                ThemedRow(label: "默认模型（新会话）") {
                    HStack(spacing: 8) {
                        TextField(defaultModel, text: config.modelID)
                            .themedField(mono: true)
                        if let models = model.availableModels[provider], !models.isEmpty {
                            ThemedMenu(title: provider == .claude ? "选择版本" : "选择模型") {
                                if provider == .claude {
                                    Section("指定版本") {
                                        ForEach(ModelCatalog.claudeVersions, id: \.id) { option in
                                            Button(option.name) { config.modelID.wrappedValue = option.id }
                                        }
                                    }
                                    Section("跟随官方更新的别名") {
                                        ForEach(ModelCatalog.claudeAliases, id: \.id) { option in
                                            Button(option.name) { config.modelID.wrappedValue = option.id }
                                        }
                                    }
                                } else {
                                    ForEach(models, id: \.self) { value in
                                        Button(value) { config.modelID.wrappedValue = value }
                                    }
                                }
                            }
                            .help(provider == .claude ? "官方支持的版本；账号可用性由 Claude 决定" : "从已发现的模型中选择")
                        }
                    }
                }
                ThemedRow(label: "默认推理强度") {
                    EffortControl(model: model, provider: provider, modelID: config.modelID, effort: config.reasoningEffort)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: config.wrappedValue.modelID) { _, _ in config.reasoningEffort.wrappedValue = nil }
                HStack(spacing: 8) {
                    Button("检查连接") {
                        Task { await model.checkProvider(provider) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.isChecking.contains(provider))
                    if provider != .claude {
                        Button("发现模型") {
                            Task { await model.loadModels(provider) }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(model.isChecking.contains(provider))
                    }
                    Spacer()
                }
                if model.developerModeEnabled {
                    HStack(spacing: 8) {
                        Text("登录命令")
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
        "请填写官方可执行文件路径"
    }

    private var defaultModel: String {
        "请选择发现的模型"
    }

    private var loginCommand: String {
        let configuredPath = config.wrappedValue.executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configuredPath.isEmpty else { return "请先填写可执行文件路径" }
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
            case .claude: return "默认设置用于新建会话；已有会话保留各自的模型和推理强度。"
            case .codex: return "使用你的 ChatGPT 账号；可选模型与推理档位来自账号的当前列表。"
            case .grok: return "使用你的 Cursor 账号和对应模型额度。"
            case .gemini: return "使用 Cursor 账号中的 Gemini 模型及额度。"
            }
        }
        switch provider {
        case .claude:
            return "指定版本使用完整模型 ID；opus / sonnet / haiku 会随官方更新。列表来自官方文档，不代表已验证本账号的全部权限。更改只影响新建会话，已有会话保持原模型。"
        case .codex:
            return "使用 Codex app-server 的 ChatGPT 登录。不要在这里填写 API Key。"
        case .grok:
            return "通过 Cursor CLI 使用你的 Legacy Cursor Pro 额度；Grok 用量来自 Cursor Models 池。"
        case .gemini:
            return "通过 Cursor CLI 使用可用的 Gemini 模型；这消耗 Cursor 额度，不是 Google AI Pro 额度。"
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
            Text(copied ? "已复制" : "复制")
        }
        .buttonStyle(GhostButtonStyle())
        .help("复制登录命令")
        .disabled(command.hasPrefix("请先"))
    }
}

private struct SecurityNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("认证安全")
                .font(Theme.sans(12, weight: .medium))
            Text("AgentDesk 只启动官方 CLI 或官方 app-server，并让它们自己完成登录。不要把 API Key、OAuth Token 或 Keychain 内容填入设置。")
                .font(Theme.sans(11))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 8))
    }
}
