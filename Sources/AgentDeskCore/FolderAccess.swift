import Foundation
import PDFKit

/// Reading the user's folders through AgentDesk's own files MCP server
/// (`agentdesk-files`). The providers' built-in file tools stay off; every
/// provider that can call MCP tools reads through this server instead, and a
/// folder the conversation has not been granted is asked about first.
public enum FolderAccessPolicy {
    public static let serverName = "agentdesk_files"
    /// How long one approval waits for the user; the CLIs' MCP tool timeout is set above it.
    public static let approvalTimeout: TimeInterval = 120
    public static let toolTimeoutSeconds = 180
    public static let modelNote = "To read the user's local files, use the agentdesk_files tools; AgentDesk asks the user before each new folder. If the user declines, do not retry another path for the same data."

    /// The server for one conversation, or nil when the helper is not
    /// installed. `files` offers the folder tools; `approvals` adds Claude
    /// Code's permission prompt tool (`ClaudeApprovalTool`) for a project
    /// folder at `cwd`; `project` adds `memory_propose` for that project's memory.
    public static func server(helper: URL, dataRoot: URL, sessionID: UUID, token: String, files: Bool = true, approvals cwd: String? = nil, project: URL? = nil) -> AgentMCPServer? {
        guard FileManager.default.isExecutableFile(atPath: helper.path), files || cwd != nil || project != nil else { return nil }
        var arguments = ["--data", dataRoot.path, "--session", sessionID.uuidString, "--token", token]
        if !files { arguments.append("--no-files") }
        if let cwd { arguments += ["--approvals", cwd] }
        if let project { arguments += ["--project", project.path] }
        return AgentMCPServer(name: serverName, transport: .stdio(command: helper.path, arguments: arguments))
    }

    /// `--permission-prompt-tool` for these servers, when one of them serves it.
    public static func approvalTool(in servers: [AgentMCPServer]) -> String? {
        servers.contains { server in
            guard server.name == serverName, case .stdio(_, let arguments) = server.transport else { return false }
            return arguments.contains("--approvals")
        } ? ClaudeApprovalTool.qualifiedName : nil
    }

    public static func resolve(_ raw: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path == "~" { path = "" } else if path.hasPrefix("~/") { path.removeFirst(2) }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : home.appendingPathComponent(path)
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Why a path is never read, even with the user's yes; nil when it may be asked about.
    public static func refusal(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let path = url.path, homePath = home.standardizedFileURL.resolvingSymlinksInPath().path
        let inHome = path == homePath || path.hasPrefix(homePath + "/")
        guard inHome || path.hasPrefix("/Volumes/") else { return "只能读取个人目录或外接磁盘里的文件。" }
        let parts = (inHome ? String(path.dropFirst(homePath.count)) : String(path.dropFirst("/Volumes".count))).split(separator: "/")
        if parts.contains(where: { $0.hasPrefix(".") }) { return "隐藏文件和隐藏文件夹（例如 .ssh、.env）不能读取。" }
        if inHome, parts.first == "Library", !(parts.count >= 2 && parts[1] == "Mobile Documents") {
            return "~/Library 里是应用数据和登录信息，不能读取（iCloud 云盘除外）。"
        }
        return nil
    }

    /// The folder a yes grants: the path itself when it is a folder, else the folder it is in.
    public static func scope(of url: URL) -> URL {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue ? url : url.deletingLastPathComponent()
    }

    public static func covers(_ folders: [String], _ url: URL) -> Bool {
        folders.contains { url.path == $0 || url.path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }
}

public struct FolderAccessRequest: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var token: String
    public var sessionID: UUID
    public var tool: String
    public var path: String
    /// The folder a "this conversation" answer grants.
    public var folder: String
    public var reason: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), token: String, sessionID: UUID, tool: String, path: String, folder: String, reason: String?, createdAt: Date = Date()) {
        self.id = id; self.token = token; self.sessionID = sessionID; self.tool = tool; self.path = path; self.folder = folder; self.reason = reason; self.createdAt = createdAt
    }
}

public enum FolderAccessDecision: String, Codable, Sendable {
    case once, conversation, deny
}

/// Requests and answers pass as small JSON files in the data folder: the
/// server process is started by the provider's CLI, not by AgentDesk, so it
/// has no other channel back to the app.
public struct FolderAccessExchange: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    var requestsDirectory: URL { root.appendingPathComponent("access-requests", isDirectory: true) }
    var grantsDirectory: URL { root.appendingPathComponent("access-grants", isDirectory: true) }
    private func requestURL(_ id: UUID) -> URL { requestsDirectory.appendingPathComponent("\(id.uuidString).request.json") }
    private func responseURL(_ id: UUID) -> URL { requestsDirectory.appendingPathComponent("\(id.uuidString).response.json") }
    private func grantsURL(_ session: UUID) -> URL { grantsDirectory.appendingPathComponent("\(session.uuidString).json") }

    public func grantedFolders(session: UUID) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(contentsOf: grantsURL(session)))) ?? []
    }

    public func setGrantedFolders(_ folders: [String], session: UUID) throws {
        if folders.isEmpty {
            try? FileManager.default.removeItem(at: grantsURL(session))
            return
        }
        try FileManager.default.createDirectory(at: grantsDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(Array(Set(folders)).sorted()).write(to: grantsURL(session), options: .atomic)
    }

    /// Every conversation with at least one granted folder.
    public func allGrants() -> [UUID: [String]] {
        let files = (try? FileManager.default.contentsOfDirectory(at: grantsDirectory, includingPropertiesForKeys: nil)) ?? []
        var result: [UUID: [String]] = [:]
        for file in files where file.pathExtension == "json" {
            if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) {
                let folders = grantedFolders(session: id)
                if !folders.isEmpty { result[id] = folders }
            }
        }
        return result
    }

    public func post(_ request: FolderAccessRequest) throws {
        try FileManager.default.createDirectory(at: requestsDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(request).write(to: requestURL(request.id), options: .atomic)
    }

    /// Requests not answered yet, oldest first.
    public func pending() -> [FolderAccessRequest] {
        let files = (try? FileManager.default.contentsOfDirectory(at: requestsDirectory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return files.filter { $0.lastPathComponent.hasSuffix(".request.json") }
            .compactMap { try? decoder.decode(FolderAccessRequest.self, from: Data(contentsOf: $0)) }
            .filter { !FileManager.default.fileExists(atPath: responseURL($0.id).path) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// The app's answer. A "this conversation" answer adds the folder first,
    /// so the server sees the grant when it reads the answer.
    public func respond(_ request: FolderAccessRequest, decision: FolderAccessDecision) throws {
        if decision == .conversation {
            try setGrantedFolders(grantedFolders(session: request.sessionID) + [request.folder], session: request.sessionID)
        }
        try JSONEncoder().encode(decision).write(to: responseURL(request.id), options: .atomic)
    }

    /// Waits for the app's answer; no answer in time is a no. Both files are removed.
    public func waitForDecision(_ id: UUID, timeout: TimeInterval, poll: TimeInterval = 0.2) -> FolderAccessDecision {
        let deadline = Date().addingTimeInterval(timeout)
        defer {
            try? FileManager.default.removeItem(at: requestURL(id))
            try? FileManager.default.removeItem(at: responseURL(id))
        }
        while Date() < deadline {
            if let data = try? Data(contentsOf: responseURL(id)), let decision = try? JSONDecoder().decode(FolderAccessDecision.self, from: data) { return decision }
            Thread.sleep(forTimeInterval: poll)
        }
        return .deny
    }

    /// Removes a request the app will not answer (for example from an earlier launch).
    public func discard(_ id: UUID) {
        try? FileManager.default.removeItem(at: requestURL(id))
        try? JSONEncoder().encode(FolderAccessDecision.deny).write(to: responseURL(id), options: .atomic)
    }
}

/// The read-only tools. Paths are checked by the caller (`FolderAccessServer`).
public enum FolderReader {
    public static let maxReadCharacters = 60_000
    static let maxFileBytes = 25_000_000

    public static func list(_ folder: URL, home: URL) throws -> String {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let items = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            .filter { FolderAccessPolicy.refusal($0.standardizedFileURL, home: home) == nil }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !items.isEmpty else { return "\(folder.path) 是空文件夹。" }
        var lines = ["\(folder.path)（\(items.count) 项）"]
        for item in items.prefix(300) {
            let values = try? item.resourceValues(forKeys: Set(keys))
            lines.append(values?.isDirectory == true ? "\(item.lastPathComponent)/" : "\(item.lastPathComponent)  \(ByteCountFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file))")
        }
        if items.count > 300 { lines.append("……另外 \(items.count - 300) 项没有列出。") }
        return lines.joined(separator: "\n")
    }

    /// Text of a text or PDF file from `offset` characters, at most `maxReadCharacters`.
    public static func read(_ file: URL, offset: Int = 0) throws -> String {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxFileBytes else { throw FolderAccessError.unreadable("文件太大（超过 25 MB）。") }
        let text: String
        if file.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: file) else { throw FolderAccessError.unreadable("PDF 打不开。") }
            text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n\n")
        } else {
            let data = try Data(contentsOf: file)
            guard !data.prefix(8_192).contains(0), let decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
                throw FolderAccessError.unreadable("这不是文本或 PDF 文件，不能直接读取。")
            }
            text = decoded
        }
        let start = min(max(0, offset), text.count)
        let slice = text.dropFirst(start).prefix(maxReadCharacters)
        let end = start + slice.count
        let note = end < text.count ? "\n\n[第 \(start)–\(end) 个字符，共 \(text.count) 个。继续读请用 offset=\(end)。]" : ""
        return String(slice) + note
    }

    /// Files and folders under `folder` whose name contains `query`.
    public static func search(_ folder: URL, query: String, home: URL) -> String {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return "无法搜索 \(folder.path)。"
        }
        var matches: [String] = [], visited = 0
        while let item = enumerator.nextObject() as? URL, visited < 20_000, matches.count < 100 {
            visited += 1
            if FolderAccessPolicy.refusal(item.standardizedFileURL, home: home) != nil { enumerator.skipDescendants(); continue }
            if needle.isEmpty || item.lastPathComponent.localizedCaseInsensitiveContains(needle) {
                let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                matches.append(item.path + (isDirectory ? "/" : ""))
            }
        }
        if matches.isEmpty { return "在 \(folder.path) 里没有找到名字包含「\(needle)」的文件。" }
        return matches.joined(separator: "\n") + (matches.count == 100 ? "\n[只列出前 100 个结果。]" : "")
    }
}

public enum FolderAccessError: LocalizedError, Equatable {
    case refused(String), denied(String), unreadable(String)
    public var errorDescription: String? {
        switch self {
        case .refused(let text), .unreadable(let text): return text
        case .denied(let path): return "用户没有允许读取 \(path)。不要换别的路径重复请求同一份资料；请直接告诉用户你需要读什么、为什么。"
        }
    }
}

/// A stdio MCP server (one JSON-RPC message per line) for one conversation.
public final class FolderAccessServer {
    let exchange: FolderAccessExchange
    let sessionID: UUID
    let token: String
    let home: URL
    let timeout: TimeInterval
    let files: Bool
    /// The project folder when this server also answers Claude Code's permission prompts.
    let approvalsFolder: String?
    /// The project whose memory `memory_propose` drafts for; nil offers no memory tool.
    let project: URL?

    public init(exchange: FolderAccessExchange, sessionID: UUID, token: String, home: URL = FileManager.default.homeDirectoryForCurrentUser, timeout: TimeInterval = FolderAccessPolicy.approvalTimeout,
                files: Bool = true, approvals approvalsFolder: String? = nil, project: URL? = nil) {
        self.exchange = exchange; self.sessionID = sessionID; self.token = token; self.home = home; self.timeout = timeout
        self.files = files; self.approvalsFolder = approvalsFolder; self.project = project
    }

    /// Drafts only: the app shows the entry and writes it when the user confirms.
    public static let memoryTool: [String: Any] = [
        "name": "memory_propose",
        "description": "建议把一条值得长期记住的项目信息（约定、决定、踩过的坑）记进项目记忆 .agentdesk/memory.md。只是草稿：AgentDesk 把它显示给用户，用户确认后才写入；之后这个项目里的所有对话都会读到。只在回合末尾、真正有长期价值时用，一次一条，简短具体，不要记临时状态或密钥。",
        "inputSchema": ["type": "object", "properties": [
            "text": ["type": "string", "description": "要记住的内容，一两句话，最多 1000 字。"],
            "reason": ["type": "string", "description": "一句话说明为什么值得记住，会显示给用户。"]
        ], "required": ["text"]],
        "annotations": ["readOnlyHint": true, "openWorldHint": false]
    ]

    public var tools: [[String: Any]] {
        (files ? Self.tools : []) + (approvalsFolder != nil ? [ClaudeApprovalTool.definition] : []) + (project != nil ? [Self.memoryTool] : [])
    }

    public static let tools: [[String: Any]] = {
        let reason: [String: Any] = ["type": "string", "description": "一句话说明为什么需要读这里，会显示给用户。"]
        func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String]) -> [String: Any] {
            ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": properties.merging(["reason": reason]) { $1 }, "required": required],
             "annotations": ["readOnlyHint": true, "openWorldHint": false]]
        }
        return [
            tool("list_directory", "列出用户电脑上一个文件夹里的文件。第一次读某个文件夹时，AgentDesk 会先问用户是否允许。", ["path": ["type": "string", "description": "绝对路径或 ~ 开头的路径"]], ["path"]),
            tool("read_file", "读取用户电脑上一个文本或 PDF 文件，每次最多 60000 个字符。第一次读某个文件夹时会先问用户。", ["path": ["type": "string"], "offset": ["type": "integer", "description": "从第几个字符开始，默认 0"]], ["path"]),
            tool("search_files", "在一个文件夹里按文件名搜索（包括子文件夹）。第一次搜某个文件夹时会先问用户。", ["folder": ["type": "string"], "query": ["type": "string", "description": "文件名里包含的文字"]], ["folder", "query"]),
        ]
    }()

    /// One incoming line; the reply line, or nil for a notification.
    public func handle(_ line: String) -> String? {
        guard let data = line.data(using: .utf8), let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch message["method"] as? String {
        case "initialize":
            result = ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18", "capabilities": ["tools": [:]],
                      "serverInfo": ["name": "agentdesk-files", "version": "1"],
                      "instructions": [files ? "用这些工具读取用户电脑上的文件。每个新文件夹都会先征求用户同意；用户拒绝后不要换路径重试。" : nil,
                                       project != nil ? "发现值得长期记住的项目信息时，在回合末尾用 memory_propose 提出一条草稿，用户确认后才会写入项目记忆。" : nil]
                        .compactMap { $0 }.joined(separator: " ")]
        case "tools/list": result = ["tools": tools]
        case "tools/call": result = call(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:])
        case "ping": result = [:]
        default:
            return Self.encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]])
        }
        return Self.encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func call(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        if name == ClaudeApprovalTool.name, let folder = approvalsFolder { return approve(arguments, cwd: folder) }
        do {
            let reason = arguments["reason"] as? String
            let text: String
            if !files, name != "memory_propose" { throw FolderAccessError.unreadable("没有这个工具：\(name)") }
            switch name {
            case "memory_propose":
                text = try propose(arguments["text"], reason: reason)
            case "list_directory":
                text = try FolderReader.list(try authorize(arguments["path"], tool: name, reason: reason), home: home)
            case "read_file":
                text = try FolderReader.read(try authorize(arguments["path"], tool: name, reason: reason), offset: arguments["offset"] as? Int ?? 0)
            case "search_files":
                text = FolderReader.search(try authorize(arguments["folder"], tool: name, reason: reason), query: arguments["query"] as? String ?? "", home: home)
            default: throw FolderAccessError.unreadable("没有这个工具：\(name)")
            }
            return ["content": [["type": "text", "text": text]], "isError": false]
        } catch {
            return ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
        }
    }

    /// Claude Code's permission prompt: allowed at once when this session
    /// already allowed the same thing, else asked in the app. Always a
    /// result, never a tool error: an error would read as a failed prompt.
    func approve(_ arguments: [String: Any], cwd: String) -> [String: Any] {
        let tool = arguments["tool_name"] as? String ?? ""
        let input = arguments["input"] as? [String: Any] ?? [:]
        let decision: FolderAccessDecision?
        if exchange.approvalGrants(session: sessionID).contains(ClaudeApprovalTool.grantKey(toolName: tool, input: input)) {
            decision = .conversation
        } else {
            let request = ClaudeApprovalTool.request(toolName: tool, input: input, sessionID: sessionID, token: token, cwd: cwd)
            if (try? exchange.postApproval(request)) != nil {
                decision = exchange.waitForApproval(request.id, timeout: timeout)
            } else { decision = .deny }
        }
        return ["content": [["type": "text", "text": ClaudeApprovalTool.answer(decision, input: input)]]]
    }

    func propose(_ raw: Any?, reason: String?) throws -> String {
        guard project != nil else { throw FolderAccessError.unreadable("没有这个工具：memory_propose") }
        let text = (raw as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw FolderAccessError.unreadable("缺少要记住的内容。") }
        guard text.count <= ProjectMemory.maxEntryCharacters else { throw FolderAccessError.unreadable("太长了：一条记忆最多 \(ProjectMemory.maxEntryCharacters) 字，请缩短后再提。") }
        try MemoryProposalExchange(root: exchange.root).post(MemoryProposal(token: token, sessionID: sessionID, text: text, reason: reason.map { String($0.prefix(300)) }))
        return "已作为草稿交给用户。用户确认后才会写入项目记忆；不用等待，也不要重复提出同一条。"
    }

    /// The resolved path when this conversation may read it, asking the app first when needed.
    func authorize(_ raw: Any?, tool: String, reason: String?) throws -> URL {
        guard let raw = raw as? String, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { throw FolderAccessError.unreadable("缺少路径。") }
        let url = FolderAccessPolicy.resolve(raw, home: home)
        if let refusal = FolderAccessPolicy.refusal(url, home: home) { throw FolderAccessError.refused(refusal) }
        guard FileManager.default.fileExists(atPath: url.path) else { throw FolderAccessError.unreadable("\(url.path) 不存在。") }
        if FolderAccessPolicy.covers(exchange.grantedFolders(session: sessionID), url) { return url }
        let request = FolderAccessRequest(token: token, sessionID: sessionID, tool: tool, path: url.path, folder: FolderAccessPolicy.scope(of: url).path, reason: reason.map { String($0.prefix(300)) })
        try exchange.post(request)
        switch exchange.waitForDecision(request.id, timeout: timeout) {
        case .once, .conversation: return url
        case .deny: throw FolderAccessError.denied(url.path)
        }
    }

    /// Serves stdin until the client closes it. Calls run one at a time, so
    /// a call waiting for the user holds the next one.
    public func run() {
        while let line = readLine(strippingNewline: true) {
            guard let reply = handle(line) else { continue }
            FileHandle.standardOutput.write(Data((reply + "\n").utf8))
        }
    }

    static func encode(_ object: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) }
    }
}
