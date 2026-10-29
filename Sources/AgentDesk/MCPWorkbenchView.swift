import SwiftUI
import AgentDeskCore

/// A small, user-mediated MCP workbench. It is intentionally independent of
/// AppModel so the same view can be used from a private chat or from a group
/// room. Tool calls happen only from the Run button.
public struct MCPWorkbenchView: View {
    private let storageRoot: URL
    private let canAttach: Bool
    private let targetLabel: String
    private let onAttach: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var servers: [MCPServerConfiguration]
    @State private var selectedServerID: UUID?
    @State private var tools: [MCPTool] = []
    @State private var selectedToolName: String?
    @State private var argumentsJSON = "{}"
    @State private var resultText = ""
    @State private var statusText = ""
    @State private var running = false
    @State private var client: MCPClient?
    @State private var operationTask: Task<Void, Never>?
    @State private var configurationLoadError: String?

    public init(root: URL, canAttach: Bool = true, targetLabel: String = "当前对话", onAttach: @escaping (String) -> Void = { _ in }) {
        self.storageRoot = root
        self.canAttach = canAttach
        self.targetLabel = targetLabel
        self.onAttach = onAttach
        let url = root.appendingPathComponent("mcp-servers.json")
        var loaded: [MCPServerConfiguration] = []
        var loadError: String?
        if FileManager.default.fileExists(atPath: url.path) {
            do { loaded = try JSONDecoder().decode([MCPServerConfiguration].self, from: Data(contentsOf: url)) }
            catch { loadError = "MCP 配置无法读取，原文件已保留：\(SafeText.redact(error.localizedDescription))" }
        }
        _servers = State(initialValue: loaded)
        _selectedServerID = State(initialValue: loaded.first?.id)
        _configurationLoadError = State(initialValue: loadError)
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $selectedServerID) {
                Section("MCP 服务器") {
                    ForEach(servers) { server in
                        HStack(spacing: 8) {
                            Image(systemName: server.enabled ? "network" : "pause.circle")
                                .foregroundStyle(server.enabled ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name.isEmpty ? "未命名服务器" : server.name)
                                Text(Self.transportLabel(server.transport))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(server.id)
                    }
                    .onDelete(perform: deleteServers)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: addServer) { Label("添加", systemImage: "plus") }
                }
            }
            .frame(minWidth: 230)
        } detail: {
            if let index = selectedIndex {
                serverDetail(index: index)
            } else {
                VStack(spacing: 14) {
                    ContentUnavailableView("选择一个 MCP 服务器", systemImage: "network", description: Text("添加服务器后，在这里检查工具并手动调用。"))
                    Button("添加服务器", action: addServer).buttonStyle(.borderedProminent).disabled(configurationLoadError != nil)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { operationTask?.cancel(); client?.cancel(); dismiss() }
            }
        }
        .overlay(alignment: .top) {
            if let configurationLoadError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(configurationLoadError).font(.callout)
                    Spacer()
                    Button("重置配置…") { resetCorruptConfiguration() }.buttonStyle(.borderless)
                }
                .padding(10)
                .background(.regularMaterial)
            }
        }
        .onChange(of: selectedServerID) { _, _ in clearInspection() }
        .onDisappear { operationTask?.cancel(); client?.cancel(); client = nil }
        .frame(minWidth: 850, minHeight: 650)
    }

    private var selectedIndex: Int? {
        guard let selectedServerID else { return nil }
        return servers.firstIndex { $0.id == selectedServerID }
    }

    @ViewBuilder
    private func serverDetail(index: Int) -> some View {
        let server = servers[index]
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    TextField("服务器名称", text: binding(index, keyPath: \.name))
                        .textFieldStyle(.roundedBorder)
                        .font(.title2.weight(.semibold))
                    Toggle("启用", isOn: binding(index, keyPath: \.enabled))
                        .toggleStyle(.switch)
                        .fixedSize()
                }
                GroupBox("连接") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("传输", selection: transportBinding(index)) {
                            Text("本地 stdio").tag(MCPTransportChoice.stdio)
                            Text("Streamable HTTP").tag(MCPTransportChoice.http)
                        }
                        .pickerStyle(.segmented)
                        switch server.transport {
                        case .stdio:
                            TextField("可执行文件（不经过 shell）", text: stdioCommandBinding(index))
                                .textFieldStyle(.roundedBorder)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("参数（每行一个）").font(.caption).foregroundStyle(.secondary)
                                TextEditor(text: stdioArgumentsBinding(index))
                                    .font(.system(.body, design: .monospaced))
                                    .frame(minHeight: 58, maxHeight: 120)
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                            }
                        case .streamableHTTP:
                            TextField("https://example.com/mcp", text: httpURLBinding(index))
                                .textFieldStyle(.roundedBorder)
                        }
                        TextField("允许传给 stdio 子进程的环境变量名（逗号分隔）", text: envBinding(index))
                            .textFieldStyle(.roundedBorder)
                        Text("不会保存环境变量值、OAuth Token 或 API Key。远程 OAuth 登录尚未实现，官方客户端的登录状态不会自动认证这个 URL；请使用已配置认证的远程地址，或使用本地 stdio 桥接。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(5)
                }
                HStack(spacing: 10) {
                    Button(action: { test(index: index) }) { Label("测试连接", systemImage: "checkmark.shield") }.disabled(running)
                    Button(action: { discover(index: index) }) { Label("发现工具", systemImage: "list.bullet.rectangle") }.disabled(running)
                    if running { Button(action: stop) { Label("停止", systemImage: "stop.fill") }.tint(.orange) }
                    Spacer()
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
                if !tools.isEmpty {
                    GroupBox("工具（手动调用）") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("工具", selection: Binding(get: { selectedToolName ?? "" }, set: { name in selectedToolName = name; argumentsJSON = "{}" })) {
                                Text("选择工具").tag("")
                                ForEach(tools) { tool in Text(tool.title ?? tool.name).tag(tool.name) }
                            }
                            if let name = selectedToolName, let tool = tools.first(where: { $0.name == name }) {
                                Text(tool.description ?? tool.name).font(.callout).foregroundStyle(.secondary)
                                if let schema = tool.inputSchema {
                                    DisclosureGroup("输入 Schema") { Text(schema.prettyJSONString).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                                }
                                TextEditor(text: $argumentsJSON)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(minHeight: 90)
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                                Button(action: { call(index: index, name: name) }) { Label("运行工具", systemImage: "play.fill") }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(running)
                            }
                        }
                        .padding(5)
                    }
                }
                if !resultText.isEmpty {
                    GroupBox("最近结果") {
                        VStack(alignment: .leading, spacing: 8) {
                            ScrollView { Text(resultText).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                                .frame(minHeight: 100, maxHeight: 260)
                            HStack {
                                Button("附加到\(targetLabel)") { onAttach(resultText) }
                                    .disabled(!canAttach)
                                Spacer()
                            }
                        }
                        .padding(5)
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .navigationTitle("MCP 工作台")
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
        Binding(get: { if case .stdio(let command, _) = servers[index].transport { return command }; return "" }, set: { value in if case .stdio(_, let arguments) = servers[index].transport { servers[index].transport = .stdio(command: value, arguments: arguments); clearInspection(); persist() } })
    }
    private func stdioArgumentsBinding(_ index: Int) -> Binding<String> {
        Binding(get: { if case .stdio(_, let arguments) = servers[index].transport { return arguments.joined(separator: "\n") }; return "" }, set: { value in if case .stdio(let command, _) = servers[index].transport { servers[index].transport = .stdio(command: command, arguments: value.split(whereSeparator: \.isNewline).map(String.init)); clearInspection(); persist() } })
    }
    private func httpURLBinding(_ index: Int) -> Binding<String> {
        Binding(get: { if case .streamableHTTP(let url) = servers[index].transport { return url }; return "" }, set: { value in servers[index].transport = .streamableHTTP(url: value); clearInspection(); persist() })
    }
    private func envBinding(_ index: Int) -> Binding<String> {
        Binding(get: { servers[index].environmentVariableNames.joined(separator: ", ") }, set: { value in servers[index].environmentVariableNames = value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter(MCPServerConfiguration.validEnvironmentName); clearInspection(); persist() })
    }
    private func binding<Value>(_ index: Int, keyPath: WritableKeyPath<MCPServerConfiguration, Value>) -> Binding<Value> { Binding(get: { servers[index][keyPath: keyPath] }, set: { servers[index][keyPath: keyPath] = $0; clearInspection(); persist() }) }

    private func addServer() { guard configurationLoadError == nil else { return }; let server = MCPServerConfiguration(); servers.append(server); selectedServerID = server.id; persist() }
    private func deleteServers(_ offsets: IndexSet) { servers.remove(atOffsets: offsets); if !servers.contains(where: { $0.id == selectedServerID }) { selectedServerID = servers.first?.id }; clearInspection(); persist() }
    private func resetCorruptConfiguration() { configurationLoadError = nil; servers = []; selectedServerID = nil; clearInspection(); persist() }
    private func clearInspection() { tools = []; selectedToolName = nil; argumentsJSON = "{}"; resultText = ""; statusText = "" }
    private func persist() {
        guard configurationLoadError == nil else { return }
        do {
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
            try JSONEncoder().encode(servers).write(to: storageRoot.appendingPathComponent("mcp-servers.json"), options: .atomic)
        } catch { statusText = "MCP 配置未能保存：\(error.localizedDescription)" }
    }

    private func test(index: Int) { run(index: index) { client in let info = try await client.testConnection(); return info.serverName.map { "已连接 · \($0)" } ?? "已连接" } }
    private func discover(index: Int) { run(index: index) { client in let values = try await client.listTools(); await MainActor.run { self.tools = values; self.selectedToolName = values.first?.name }; return "已发现 \(values.count) 个工具" } }
    private func call(index: Int, name: String) {
        let arguments = argumentsJSON
        let serverName = servers[index].name
        run(index: index) { client in
            let result = try await client.callTool(name: name, argumentsJSON: arguments)
            await MainActor.run {
                let stamp = ISO8601DateFormatter().string(from: Date())
                let cap = 12_000
                let shown = String(result.rawJSON.prefix(cap))
                let suffix = result.rawJSON.count > cap ? "\n…结果已截断，仅显示前 \(cap) 个字符。" : ""
                self.resultText = "[MCP · \(serverName) · \(name) · \(stamp)]\n\(shown)\(suffix)"
            }
            return result.isError ? "工具返回错误" : "调用完成"
        }
    }
    private func run(index: Int, operation: @escaping (MCPClient) async throws -> String) {
        guard !running else { return }
        running = true; statusText = "处理中…"; resultText = ""
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
