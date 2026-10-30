import Foundation
import CoreFoundation

/// A JSON value used for MCP schemas and arguments without retaining a
/// dictionary typed as `Any` in persisted state.
public enum MCPJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([MCPJSONValue])
    case object([String: MCPJSONValue])

    public init(any: Any) throws {
        switch any {
        case is NSNull: self = .null
        case let value as NSNumber:
            // JSONSerialization bridges both Boolean and numeric JSON values
            // to NSNumber. ObjC type `c` identifies the Boolean bridge; using
            // `as Bool` would incorrectly turn JSON number 1 into true.
            if CFGetTypeID(value) == CFBooleanGetTypeID() { self = .bool(value.boolValue) }
            else { self = .number(value.doubleValue) }
        case let value as Bool: self = .bool(value)
        case let value as String: self = .string(value)
        case let value as [Any]: self = .array(try value.map { try MCPJSONValue(any: $0) })
        case let value as [String: Any]:
            var result: [String: MCPJSONValue] = [:]
            for (key, item) in value { result[key] = try MCPJSONValue(any: item) }
            self = .object(result)
        default:
            throw AgentError.protocolFailure("MCP 返回了无法表示的 JSON 值。")
        }
    }

    public init(jsonData: Data) throws {
        let value = try JSONSerialization.jsonObject(with: jsonData, options: [.fragmentsAllowed])
        try self.init(any: value)
    }

    public var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let value): return value.map(\.any)
        case .object(let value): return value.mapValues(\.any)
        }
    }

    public func jsonData(pretty: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: any, options: pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys])
    }

    public var prettyJSONString: String {
        guard let data = try? jsonData(pretty: true) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}

public enum MCPTransport: Codable, Equatable, Sendable {
    case stdio(command: String, arguments: [String])
    case streamableHTTP(url: String)

    private enum CodingKeys: String, CodingKey { case type, command, arguments, url }
    private enum Kind: String, Codable { case stdio, streamableHTTP }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .stdio:
            self = .stdio(command: try container.decode(String.self, forKey: .command), arguments: try container.decodeIfPresent([String].self, forKey: .arguments) ?? [])
        case .streamableHTTP:
            self = .streamableHTTP(url: try container.decode(String.self, forKey: .url))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stdio(let command, let arguments):
            try container.encode(Kind.stdio, forKey: .type)
            try container.encode(command, forKey: .command)
            try container.encode(arguments, forKey: .arguments)
        case .streamableHTTP(let url):
            try container.encode(Kind.streamableHTTP, forKey: .type)
            try container.encode(url, forKey: .url)
        }
    }
}

public struct MCPServerConfiguration: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var transport: MCPTransport
    public var enabled: Bool
    /// Names are copied from the current process environment only when a
    /// child server starts. Values are never persisted in this configuration.
    public var environmentVariableNames: [String]
    /// Hand this server to the model CLIs of private and canvas chats, so the
    /// model picks and calls its tools itself. Off until the user turns it on.
    public var modelAccess: Bool

    public init(id: UUID = UUID(), name: String = "新 MCP 服务器", transport: MCPTransport = .stdio(command: "", arguments: []), enabled: Bool = true, environmentVariableNames: [String] = [], modelAccess: Bool = false) {
        self.id = id
        self.name = String(name.prefix(100))
        self.transport = transport
        self.enabled = enabled
        self.environmentVariableNames = environmentVariableNames.filter { Self.validEnvironmentName($0) }
        self.modelAccess = modelAccess
    }

    private enum CodingKeys: String, CodingKey { case id, name, transport, enabled, environmentVariableNames, modelAccess }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  transport: try c.decode(MCPTransport.self, forKey: .transport), enabled: try c.decode(Bool.self, forKey: .enabled),
                  environmentVariableNames: try c.decodeIfPresent([String].self, forKey: .environmentVariableNames) ?? [],
                  modelAccess: try c.decodeIfPresent(Bool.self, forKey: .modelAccess) ?? false)
    }

    public static func validEnvironmentName(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
    }
}

/// An MCP server handed to a model CLI for one turn. `name` is safe as a
/// tool-name prefix and as a dotted Codex config key; the environment values
/// are copied from the app process when the CLI starts, never persisted.
public struct AgentMCPServer: Equatable, Sendable {
    public var name: String
    public var transport: MCPTransport
    public var environment: [String: String]

    public init(name: String, transport: MCPTransport, environment: [String: String] = [:]) {
        self.name = name; self.transport = transport; self.environment = environment
    }

    /// Enabled servers the user opened to the model, with unique, safe names.
    /// Servers without a command or URL are skipped.
    public static func forModel(_ configurations: [MCPServerConfiguration], processEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> [AgentMCPServer] {
        var used = Set<String>()
        return configurations.compactMap { config in
            guard config.enabled, config.modelAccess else { return nil }
            switch config.transport {
            case .stdio(let command, _) where command.trimmingCharacters(in: .whitespaces).isEmpty: return nil
            case .streamableHTTP(let url) where url.trimmingCharacters(in: .whitespaces).isEmpty: return nil
            default: break
            }
            let base = safeName(config.name)
            var name = base
            var n = 2
            while used.contains(name) { name = "\(base)_\(n)"; n += 1 }
            used.insert(name)
            var environment: [String: String] = [:]
            for key in config.environmentVariableNames { if let value = processEnvironment[key] { environment[key] = value } }
            return AgentMCPServer(name: name, transport: config.transport, environment: environment)
        }
    }

    /// Lowercase ASCII letters, digits, `_` and `-`; anything else becomes `_`.
    public static func safeName(_ raw: String) -> String {
        let mapped = raw.lowercased().unicodeScalars.map { s -> Character in
            (("a"..."z").contains(s) || ("0"..."9").contains(s) || s == "_" || s == "-") ? Character(s) : "_"
        }
        var name = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        while name.contains("__") { name = name.replacingOccurrences(of: "__", with: "_") }
        return name.isEmpty ? "mcp" : String(name.prefix(40))
    }
}

public enum MCPToolName {
    /// "mcp__portfolio__list_holdings" → "portfolio · list_holdings".
    public static func display(_ raw: String) -> String {
        let parts = raw.components(separatedBy: "__")
        guard parts.count >= 3, parts[0] == "mcp" else { return raw }
        return "\(parts[1]) · \(parts[2...].joined(separator: "__"))"
    }
}

public struct MCPTool: Identifiable, Codable, Equatable, Sendable {
    public var name: String
    public var title: String?
    public var description: String?
    public var inputSchema: MCPJSONValue?
    public var annotations: MCPJSONValue?
    public var id: String { name }

    public init(name: String, title: String? = nil, description: String? = nil, inputSchema: MCPJSONValue? = nil, annotations: MCPJSONValue? = nil) {
        self.name = name; self.title = title; self.description = description; self.inputSchema = inputSchema; self.annotations = annotations
    }
}

public struct MCPContent: Codable, Equatable, Sendable {
    public var type: String
    public var text: String?
    public var data: String?
    public var mimeType: String?
    public var raw: MCPJSONValue?

    public init(type: String, text: String? = nil, data: String? = nil, mimeType: String? = nil, raw: MCPJSONValue? = nil) {
        self.type = type; self.text = text; self.data = data; self.mimeType = mimeType; self.raw = raw
    }
}

public struct MCPToolResult: Codable, Equatable, Sendable {
    public var content: [MCPContent]
    public var structuredContent: MCPJSONValue?
    public var isError: Bool
    public var rawJSON: String

    public init(content: [MCPContent] = [], structuredContent: MCPJSONValue? = nil, isError: Bool = false, rawJSON: String = "{}") {
        self.content = content; self.structuredContent = structuredContent; self.isError = isError; self.rawJSON = rawJSON
    }

    public var displayText: String {
        let text = content.compactMap(\.text).joined(separator: "\n")
        return text.isEmpty ? rawJSON : text
    }
}

public struct MCPConnectionInfo: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var serverName: String?
    public var serverVersion: String?
    public var capabilities: MCPJSONValue?

    public init(protocolVersion: String, serverName: String? = nil, serverVersion: String? = nil, capabilities: MCPJSONValue? = nil) {
        self.protocolVersion = protocolVersion; self.serverName = serverName; self.serverVersion = serverVersion; self.capabilities = capabilities
    }
}

public struct MCPLimits: Sendable, Equatable {
    public var timeout: TimeInterval
    public var maxOutputBytes: Int
    public var maxPages: Int
    public var maxTools: Int

    public init(timeout: TimeInterval = 20, maxOutputBytes: Int = 2_000_000, maxPages: Int = 8, maxTools: Int = 256) {
        self.timeout = max(1, min(timeout, 300))
        self.maxOutputBytes = max(16_384, min(maxOutputBytes, 16_000_000))
        self.maxPages = max(1, min(maxPages, 32))
        self.maxTools = max(1, min(maxTools, 1_000))
    }
}
