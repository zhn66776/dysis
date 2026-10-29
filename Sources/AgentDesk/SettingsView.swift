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
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("设置")
                        .font(.title2.weight(.semibold))
                    Text("选择模型、推理强度和账号连接。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.developerModeEnabled {
                    Label("开发者模式", systemImage: "hammer")
                        .font(.caption).foregroundStyle(.orange)
                }
                Button("完成") { model.saveConfiguration(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(ProviderID.allCases) { provider in
                        ProviderSettingsSection(model: model, provider: provider)
                    }
                    if model.developerModeEnabled { SecurityNote() }
                    HStack {
                        Text(model.developerModeEnabled ? "⌘⇧D 退出开发者模式" : "⌘⇧D 开发者模式")
                            .font(.caption).foregroundStyle(.tertiary)
                        Spacer()
                    }
                }
                .padding(24)
            }
        }
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
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    ProviderBadgeForSettings(provider: provider)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.name)
                            .font(.headline)
                        if model.developerModeEnabled {
                            Text(provider.runtimeName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    StatusPill(text: model.statusByProvider[provider] ?? "未检查")
                }

                if model.developerModeEnabled {
                    LabeledContent("可执行文件") {
                        TextField(defaultPath, text: config.executablePath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                }
                LabeledContent("默认模型（新会话）") {
                    HStack(spacing: 8) {
                        TextField(defaultModel, text: config.modelID)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        if let models = model.availableModels[provider], !models.isEmpty {
                            Menu {
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
                            } label: {
                                Label(provider == .claude ? "选择版本" : "选择模型", systemImage: "list.bullet.rectangle")
                            }
                            .fixedSize()
                            .help(provider == .claude ? "官方支持的版本；账号可用性由 Claude 决定" : "从已发现的模型中选择")
                        }
                    }
                }
                LabeledContent("默认推理强度") {
                    EffortControl(model: model, provider: provider, modelID: config.modelID, effort: config.reasoningEffort)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: config.wrappedValue.modelID) { _, _ in config.reasoningEffort.wrappedValue = nil }
                HStack(spacing: 10) {
                    Button {
                        Task { await model.checkProvider(provider) }
                    } label: {
                        Label("检查连接", systemImage: "checkmark.shield")
                    }
                    .disabled(model.isChecking.contains(provider))
                    if provider != .claude {
                        Button {
                            Task { await model.loadModels(provider) }
                        } label: {
                            Label("发现模型", systemImage: "wand.and.stars")
                        }
                        .disabled(model.isChecking.contains(provider))
                    }
                    Spacer()
                }
                if model.developerModeEnabled {
                    HStack(spacing: 8) {
                        Text("登录命令")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(loginCommand)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        CopyCommandButton(command: loginCommand)
                    }
                }
                Text(helperText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(5)
        } label: {
            EmptyView()
        }
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
        ProviderIcon(provider: provider, size: 30)
    }
}

private struct StatusPill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
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
            Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .help("复制登录命令")
        .disabled(command.hasPrefix("请先"))
    }
}

private struct SecurityNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 5) {
                Text("认证安全")
                    .font(.subheadline.weight(.semibold))
                Text("AgentDesk 只启动官方 CLI 或官方 app-server，并让它们自己完成登录。不要把 API Key、OAuth Token 或 Keychain 内容填入设置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(13)
        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
