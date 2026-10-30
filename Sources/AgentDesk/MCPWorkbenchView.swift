import SwiftUI
import AgentDeskCore

/// Server, tool and arguments to fill in when an MCP node's tool is run again.
public struct MCPWorkbenchPreset: Equatable {
    public let serverID: UUID, toolName: String, argumentsJSON: String
    public init(serverID: UUID, toolName: String, argumentsJSON: String) { self.serverID = serverID; self.toolName = toolName; self.argumentsJSON = argumentsJSON }
}

/// A small, user-mediated MCP workbench. It is intentionally independent of
/// AppModel so the same view can be used from a private chat or from a group
/// room. Tool calls happen only from the Run button; a preset only fills in
/// the form.
public struct MCPWorkbenchView: View {
    private let storageRoot: URL
    private let canAttach: Bool
    private let targetLabel: String
    private let showsAttach: Bool
    private let preset: MCPWorkbenchPreset?
    /// Second result action (canvas: "放到画布上" or "更新「…」"); hidden when nil.
    private let placeLabel: String?
    private let onAttach: (String) -> Void
    private let onPlace: (CanvasMCPResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var servers: [MCPServerConfiguration]
    @State private var selectedServerID: UUID?
    @State private var tools: [MCPTool] = []
    @State private var selectedToolName: String?
    @State private var argumentsJSON = "{}"
    @State private var resultText = ""
    /// The latest tool result with its server, tool, arguments and time.
    @State private var lastResult: CanvasMCPResult?
    @State private var statusText = ""
    @State private var running = false
    @State private var client: MCPClient?
    @State private var operationTask: Task<Void, Never>?
    @State private var configurationLoadError: String?

    public init(root: URL, canAttach: Bool = true, targetLabel: String = "当前对话", showsAttach: Bool = true, preset: MCPWorkbenchPreset? = nil,
                placeLabel: String? = nil, onAttach: @escaping (String) -> Void = { _ in }, onPlace: @escaping (CanvasMCPResult) -> Void = { _ in }) {
        self.storageRoot = root
        self.canAttach = canAttach
        self.targetLabel = targetLabel
        self.showsAttach = showsAttach
        self.preset = preset
        self.placeLabel = placeLabel
        self.onAttach = onAttach
        self.onPlace = onPlace
        let url = root.appendingPathComponent("mcp-servers.json")
        var loaded: [MCPServerConfiguration] = []
        var loadError: String?
        if FileManager.default.fileExists(atPath: url.path) {
            do { loaded = try JSONDecoder().decode([MCPServerConfiguration].self, from: Data(contentsOf: url)) }
            catch { loadError = "MCP 配置无法读取，原文件已保留：\(SafeText.redact(error.localizedDescription))" }
        }
        _servers = State(initialValue: loaded)
        _configurationLoadError = State(initialValue: loadError)
        if let preset {
            let found = loaded.contains { $0.id == preset.serverID }
            _selectedServerID = State(initialValue: found ? preset.serverID : loaded.first?.id)
            _statusText = State(initialValue: found ? "重新运行「\(preset.toolName)」：先点“发现工具”，参数会按上次填好，再按“运行工具”。" : "这个结果来自的 MCP 服务器已删除，无法按原参数重新运行。")
        } else {
            _selectedServerID = State(initialValue: loaded.first?.id)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("MCP 工作台").titleText(16)
                Text("手动检查和调用工具；只在你按“运行工具”时调用。").metaText()
                Spacer()
                Button("完成") { operationTask?.cancel(); client?.cancel(); dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            Hairline()
            if let configurationLoadError {
                ThemedErrorBanner(message: configurationLoadError, actionTitle: "重置配置…") { resetCorruptConfiguration() }
                    .padding(.horizontal, 14).padding(.top, 10)
            }
            HStack(spacing: 0) {
                serverList.frame(width: 240)
                Hairline(vertical: true)
                Group {
                    if let index = selectedIndex {
                        serverDetail(index: index)
                    } else {
                        VStack(spacing: 8) {
                            Text("选择一个 MCP 服务器").titleText(18)
                            Text("添加服务器后，在这里检查工具并手动调用。").font(Theme.sans(12)).foregroundStyle(Theme.muted)
                            Button("添加服务器", action: addServer).buttonStyle(PrimaryButtonStyle()).disabled(configurationLoadError != nil).padding(.top, 6)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .themedSurface()
        .presentationBackground(Theme.bg)
        .onChange(of: selectedServerID) { _, _ in clearInspection() }
        .onDisappear { operationTask?.cancel(); client?.cancel(); client = nil }
        .frame(minWidth: 850, minHeight: 650)
    }

    private var serverList: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("MCP 服务器").sectionLabel()
                Spacer()
                Button("+ 添加", action: addServer).buttonStyle(GhostButtonStyle()).disabled(configurationLoadError != nil)
            }
            .padding(.leading, 8).padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(servers) { server in
                        let on = server.id == selectedServerID
                        Button { selectedServerID = server.id } label: {
                            HStack(spacing: 8) {
                                Circle().fill(server.enabled ? Theme.ok : Theme.muted2).frame(width: 6, height: 6)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(server.name.isEmpty ? "未命名服务器" : server.name).font(Theme.sans(13)).foregroundStyle(on ? Theme.text : Theme.muted).lineLimit(1)
                                    Text(Self.transportLabel(server.transport)).metaText(10).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(GhostButtonStyle(selected: on, fullWidth: true))
                        .contextMenu {
                            Button("删除服务器", role: .destructive) { if let i = servers.firstIndex(where: { $0.id == server.id }) { deleteServers(IndexSet(integer: i)) } }
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.side)
    }

    private var selectedIndex: Int? {
        guard let selectedServerID else { return nil }
        return servers.firstIndex { $0.id == selectedServerID }
    }

    @ViewBuilder
    private func serverDetail(index: Int) -> some View {
        let server = servers[index]
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    TextField("服务器名称", text: binding(index, keyPath: \.name))
                        .textFieldStyle(.plain)
                        .font(Theme.sans(17, weight: .medium))
                    Toggle("启用", isOn: binding(index, keyPath: \.enabled))
                        .toggleStyle(ThemedSwitchStyle())
                        .fixedSize()
                    Button("删除") { deleteServers(IndexSet(integer: index)) }
                        .buttonStyle(SecondaryButtonStyle(destructive: true))
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("连接").sectionLabel()
                    SegmentedChoice(selection: transportBinding(index), options: [(MCPTransportChoice.stdio, "本地 stdio"), (MCPTransportChoice.http, "Streamable HTTP")])
                    switch server.transport {
                    case .stdio:
                        TextField("可执行文件（不经过 shell）", text: stdioCommandBinding(index))
                            .themedField(mono: true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("参数（每行一个）").font(Theme.sans(11)).foregroundStyle(Theme.muted)
                            TextEditor(text: stdioArgumentsBinding(index))
                                .themedEditor(mono: true)
                                .frame(minHeight: 58, maxHeight: 120)
                        }
                    case .streamableHTTP:
                        TextField("https://example.com/mcp", text: httpURLBinding(index))
                            .themedField(mono: true)
                    }
                    TextField("允许传给 stdio 子进程的环境变量名（逗号分隔）", text: envBinding(index))
                        .themedField(mono: true)
                    Text("不会保存环境变量值、OAuth Token 或 API Key。远程 OAuth 登录尚未实现，官方客户端的登录状态不会自动认证这个 URL；请使用已配置认证的远程地址，或使用本地 stdio 桥接。")
                        .font(Theme.sans(11))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .themedCard()
                HStack(spacing: 8) {
                    Button("测试连接") { test(index: index) }.buttonStyle(SecondaryButtonStyle()).disabled(running)
                    Button("发现工具") { discover(index: index) }.buttonStyle(SecondaryButtonStyle()).disabled(running)
                    if running { Button("停止", action: stop).buttonStyle(SecondaryButtonStyle(destructive: true)) }
                    Spacer()
                    Text(statusText).metaText().foregroundStyle(running ? Theme.run : Theme.muted)
                }
                if !tools.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("工具（手动调用）").sectionLabel()
                        ThemedPicker(selection: Binding(get: { selectedToolName ?? "" }, set: { name in selectedToolName = name; argumentsJSON = "{}" }),
                                     options: [("", "选择工具")] + tools.map { ($0.name, $0.title ?? $0.name) })
                        if let name = selectedToolName, let tool = tools.first(where: { $0.name == name }) {
                            Text(tool.description ?? tool.name).font(Theme.sans(12)).foregroundStyle(Theme.muted)
                            if let schema = tool.inputSchema {
                                SchemaDisclosure(text: schema.prettyJSONString)
                            }
                            TextEditor(text: $argumentsJSON)
                                .themedEditor(mono: true)
                                .frame(minHeight: 90)
                            Button("运行工具") { call(index: index, name: name) }
                                .buttonStyle(PrimaryButtonStyle())
                                .disabled(running)
                        }
                    }
                    .themedCard()
                }
                if !resultText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("最近结果").sectionLabel()
                        ScrollView { Text(resultText).font(Theme.mono(12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(minHeight: 100, maxHeight: 260)
                            .padding(8)
                            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 8))
                        HStack {
                            if showsAttach {
                                Button("附加到\(targetLabel)") { onAttach(resultText) }
                                    .buttonStyle(SecondaryButtonStyle())
                                    .disabled(!canAttach)
                            }
                            if let placeLabel, let lastResult {
                                Button(placeLabel) { onPlace(lastResult) }
                                    .buttonStyle(SecondaryButtonStyle())
                                    .help("作为只读的 MCP 结果节点，用数据线连到多个对话；刷新时需要在这里重新运行工具")
                            }
                            Spacer()
                        }
                    }
                    .themedCard()
                }
            }
            .padding(22)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private enum MCPTransportChoice: String { case stdio, http }

    private func transportBinding(_ index: Int) -> Binding<MCPTransportChoice> {
        Binding(get: {
            if case .streamableHTTP = servers[index].transport { return .http }; return .stdio
        }, set: { choice in
            switch choice {
            case .stdio:
                if case .stdio = servers[index].transport {} else { servers[index].transport = .stdio(command: "", arguments: []) }
            case .http:
                if case .streamableHTTP = servers[index].transport {} else { servers[index].transport = .streamableHTTP(url: "") }
            }
            clearInspection(); persist()
        })
    }

    private func stdioCommandBinding(_ index: Int) -> Binding<String> {
        Binding(get: { if case .stdio(let command, _) = servers[index].transport { return command }; return "" }, set: { value in if case .stdio(let command, let arguments) = servers[index].transport, command != value { servers[index].transport = .stdio(command: value, arguments: arguments); clearInspection(); persist() } })
    }
    private func stdioArgumentsBinding(_ index: Int) -> Binding<String> {
        Binding(get: { if case .stdio(_, let arguments) = servers[index].transport { return arguments.joined(separator: "\n") }; return "" }, set: { value in let lines = value.split(whereSeparator: \.isNewline).map(String.init); if case .stdio(let command, let arguments) = servers[index].transport, arguments != lines { servers[index].transport = .stdio(command: command, arguments: lines); clearInspection(); persist() } })
    }
    private func httpURLBinding(_ index: Int) -> Binding<String> {
        Binding(get: { if case .streamableHTTP(let url) = servers[index].transport { return url }; return "" }, set: { value in guard servers[index].transport != .streamableHTTP(url: value) else { return }; servers[index].transport = .streamableHTTP(url: value); clearInspection(); persist() })
    }
    private func envBinding(_ index: Int) -> Binding<String> {
        Binding(get: { servers[index].environmentVariableNames.joined(separator: ", ") }, set: { value in let names = value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter(MCPServerConfiguration.validEnvironmentName); guard names != servers[index].environmentVariableNames else { return }; servers[index].environmentVariableNames = names; clearInspection(); persist() })
    }
    // Focusing a field writes its unchanged value back; only real edits reset the inspection.
    private func binding<Value: Equatable>(_ index: Int, keyPath: WritableKeyPath<MCPServerConfiguration, Value>) -> Binding<Value> { Binding(get: { servers[index][keyPath: keyPath] }, set: { guard servers[index][keyPath: keyPath] != $0 else { return }; servers[index][keyPath: keyPath] = $0; clearInspection(); persist() }) }

    private func addServer() { guard configurationLoadError == nil else { return }; let server = MCPServerConfiguration(); servers.append(server); selectedServerID = server.id; persist() }
    private func deleteServers(_ offsets: IndexSet) { servers.remove(atOffsets: offsets); if !servers.contains(where: { $0.id == selectedServerID }) { selectedServerID = servers.first?.id }; clearInspection(); persist() }
    private func resetCorruptConfiguration() { configurationLoadError = nil; servers = []; selectedServerID = nil; clearInspection(); persist() }
    private func clearInspection() { tools = []; selectedToolName = nil; argumentsJSON = "{}"; resultText = ""; lastResult = nil; statusText = "" }
    private func persist() {
        guard configurationLoadError == nil else { return }
        do {
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
            try JSONEncoder().encode(servers).write(to: storageRoot.appendingPathComponent("mcp-servers.json"), options: .atomic)
        } catch { statusText = "MCP 配置未能保存：\(error.localizedDescription)" }
    }

    private func test(index: Int) { run(index: index) { client in let info = try await client.testConnection(); return info.serverName.map { "已连接 · \($0)" } ?? "已连接" } }
    private func discover(index: Int) {
        // Running a node's tool again: pick its tool and arguments once discovered.
        let preset = preset.flatMap { $0.serverID == servers[index].id ? $0 : nil }
        run(index: index) { client in
            let values = try await client.listTools()
            await MainActor.run {
                self.tools = values
                if let preset, values.contains(where: { $0.name == preset.toolName }) {
                    self.selectedToolName = preset.toolName; self.argumentsJSON = preset.argumentsJSON
                } else {
                    self.selectedToolName = values.first?.name
                }
            }
            return "已发现 \(values.count) 个工具"
        }
    }
    private func call(index: Int, name: String) {
        let arguments = argumentsJSON
        let serverName = servers[index].name
        let serverID = servers[index].id
        run(index: index) { client in
            let result = try await client.callTool(name: name, argumentsJSON: arguments)
            await MainActor.run {
                let now = Date()
                let stamp = ISO8601DateFormatter().string(from: now)
                let cap = 12_000
                let shown = String(result.rawJSON.prefix(cap))
                let suffix = result.rawJSON.count > cap ? "\n…结果已截断，仅显示前 \(cap) 个字符。" : ""
                self.resultText = "[MCP · \(serverName) · \(name) · \(stamp)]\n\(shown)\(suffix)"
                // The canvas keeps the readable text blocks (raw JSON when there are none).
                let text = result.displayText
                let nodeText = text.count > cap ? String(text.prefix(cap)) + "\n…结果已截断，仅保留前 \(cap) 个字符。" : text
                self.lastResult = CanvasMCPResult(serverID: serverID, serverName: serverName.isEmpty ? "未命名服务器" : serverName, toolName: name, argumentsJSON: arguments,
                                                  text: nodeText, isError: result.isError, calledAt: now)
            }
            return result.isError ? "工具返回错误" : "调用完成"
        }
    }
    private func run(index: Int, operation: @escaping (MCPClient) async throws -> String) {
        guard !running else { return }
        running = true; statusText = "处理中…"; resultText = ""; lastResult = nil
        let configuration = servers[index]
        let newClient = MCPClient(configuration: configuration, workingDirectory: storageRoot)
        client = newClient
        let task = Task {
            do {
                let message = try await operation(newClient)
                await MainActor.run { self.statusText = message; self.running = false; self.client = nil; self.operationTask = nil }
            } catch {
                await MainActor.run { self.statusText = SafeText.redact(error.localizedDescription); self.running = false; self.client = nil; self.operationTask = nil }
            }
        }
        operationTask = task
    }
    private func stop() { operationTask?.cancel(); client?.cancel(); statusText = "正在停止…" }

    private static func transportLabel(_ transport: MCPTransport) -> String { switch transport { case .stdio(let command, _): return command.isEmpty ? "stdio" : "stdio · \(command)"; case .streamableHTTP(let url): return url.isEmpty ? "HTTP" : "HTTP · \(url)" } }
}

/// "输入 Schema" fold-out with a plain-text caret instead of a disclosure triangle.
private struct SchemaDisclosure: View {
    let text: String
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button((open ? "▾ " : "▸ ") + "输入 Schema") { open.toggle() }.buttonStyle(GhostButtonStyle())
            if open {
                Text(text).font(Theme.mono(11)).foregroundStyle(Theme.text).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8).background(Theme.chip, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
