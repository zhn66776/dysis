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

    public init(id: UUID = UUID(), name: String = "新 MCP 服务器", transport: MCPTransport = .stdio(command: "", arguments: []), enabled: Bool = true, environmentVariableNames: [String] = []) {
        self.id = id
        self.name = String(name.prefix(100))
        self.transport = transport
        self.enabled = enabled
        self.environmentVariableNames = environmentVariableNames.filter { Self.validEnvironmentName($0) }
    }

    public static func validEnvironmentName(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
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
