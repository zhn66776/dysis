import Foundation

public enum ProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex, grok, gemini
    public var id: String { rawValue }
    public var name: String {
        switch self { case .claude: return "Claude"; case .codex: return "ChatGPT"; case .grok: return "Grok"; case .gemini: return "Gemini" }
    }
    public var runtimeName: String {
        switch self { case .claude: return "Claude Code"; case .codex: return "Codex"; case .grok, .gemini: return "Cursor" }
    }
    public var symbol: String {
        switch self { case .claude: return "sun.max"; case .codex: return "sparkle"; case .grok: return "bolt"; case .gemini: return "sparkles" }
    }
    /// The Cursor connection takes text only.
    public var acceptsImages: Bool { self == .claude || self == .codex }
}

public enum MessageRole: String, Codable, Sendable { case user, assistant }
public enum MessageState: String, Codable, Sendable { case complete, streaming, failed, cancelled }

public struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var role: MessageRole
    public var text: String
    public var state: MessageState
    public var createdAt: Date
    public var actualModelIDs: [String]?
    public var attachments: [ChatAttachment]?
    /// Canvas sources (inherited branch, upstream nodes) that were placed
    /// before the typed text when this message was sent. Display only.
    public var contextSources: [String]?
    /// The provider's own turn ID for this reply (Codex), used as a fork point.
    public var providerTurnID: String?
    public init(id: UUID = UUID(), role: MessageRole, text: String, state: MessageState = .complete, createdAt: Date = Date(), attachments: [ChatAttachment]? = nil, contextSources: [String]? = nil) {
        self.id = id; self.role = role; self.text = text; self.state = state; self.createdAt = createdAt
        self.attachments = attachments; self.contextSources = contextSources
    }
}

public struct ChatSession: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var provider: ProviderID
    public var modelID: String
    public var remoteSessionID: String?
    public var workingDirectory: String
    public var messages: [ChatMessage]
    public var createdAt: Date
    public var updatedAt: Date
    public var reasoningEffort: String?
    /// Context occupancy reported with the latest reply, if the provider reports it.
    public var contextUsage: ContextUsage?
    public init(id: UUID = UUID(), title: String = "新对话", provider: ProviderID, modelID: String, remoteSessionID: String? = nil, workingDirectory: String, messages: [ChatMessage] = [], createdAt: Date = Date(), updatedAt: Date = Date(), reasoningEffort: String? = nil) {
        self.id = id; self.title = title; self.provider = provider; self.modelID = modelID; self.remoteSessionID = remoteSessionID; self.workingDirectory = workingDirectory; self.messages = messages; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.reasoningEffort = reasoningEffort
    }
}

public struct ProviderConfiguration: Codable, Equatable, Sendable {
    public var executablePath: String
    public var modelID: String
    public var reasoningEffort: String?
    public init(executablePath: String = "", modelID: String = "", reasoningEffort: String? = nil) { self.executablePath = executablePath; self.modelID = modelID; self.reasoningEffort = reasoningEffort }
}

public struct AppConfiguration: Codable, Equatable, Sendable {
    public var providers: [ProviderID: ProviderConfiguration]
    /// Private and canvas chats get AgentDesk's files MCP server, which asks
    /// before reading each new folder.
    public var folderAccess: Bool
    public init(providers: [ProviderID: ProviderConfiguration] = [:], folderAccess: Bool = true) { self.providers = providers; self.folderAccess = folderAccess }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providers = try container.decode([ProviderID: ProviderConfiguration].self, forKey: .providers)
        folderAccess = try container.decodeIfPresent(Bool.self, forKey: .folderAccess) ?? true
    }
    public subscript(_ provider: ProviderID) -> ProviderConfiguration {
        get { providers[provider] ?? ProviderConfiguration() }
        set { providers[provider] = newValue }
    }
}

public struct AgentImageInput: Sendable, Equatable {
    public let localURL: URL
    public let mediaType: String
    public init(localURL: URL, mediaType: String) { self.localURL = localURL; self.mediaType = mediaType }
}

/// Tokens in the conversation's context after the latest reply.
public struct ContextUsage: Codable, Equatable, Sendable {
    public var usedTokens: Int
    public var windowTokens: Int?
    public init(usedTokens: Int, windowTokens: Int?) { self.usedTokens = usedTokens; self.windowTokens = windowTokens }
}

/// One subscription usage window, as the provider reports it.
public struct QuotaWindow: Codable, Equatable, Sendable {
    public var label: String
    /// 0–100. Can exceed 100 when the provider allows overage.
    public var usedPercent: Double
    public var resetsAt: Date?
    public init(label: String, usedPercent: Double, resetsAt: Date?) { self.label = label; self.usedPercent = usedPercent; self.resetsAt = resetsAt }
}

public struct ProviderQuota: Codable, Equatable, Sendable {
    public var windows: [QuotaWindow]
    /// Provider status when no percentage is given (e.g. "allowed_warning").
    public var status: String?
    public var updatedAt: Date
    public init(windows: [QuotaWindow], status: String? = nil, updatedAt: Date = Date()) { self.windows = windows; self.status = status; self.updatedAt = updatedAt }

    public static func windowLabel(minutes: Int?) -> String {
        switch minutes {
        case 300?: return "5 小时"
        case 10080?: return "每周"
        case let m? where m % 1440 == 0: return "\(m / 1440) 天"
        case let m? where m >= 60: return "\(m / 60) 小时"
        default: return "用量"
        }
    }
}

/// Where a new session forks from, using the provider's own fork.
public struct AgentFork: Sendable, Equatable {
    public let remoteSessionID: String
    /// Last provider turn to include (Codex `lastTurnId`). nil forks the
    /// whole session; Claude Code supports only that.
    public let throughTurnID: String?
    public init(remoteSessionID: String, throughTurnID: String? = nil) { self.remoteSessionID = remoteSessionID; self.throughTurnID = throughTurnID }
}

public struct AgentRequest: Sendable {
    public let localSessionID: UUID
    public let remoteSessionID: String?
    public let prompt: String
    public let workingDirectory: URL
    public let modelID: String
    public let executableURL: URL
    public let reasoningEffort: String?
    public let images: [AgentImageInput]
    /// Used only when `remoteSessionID` is nil: the first turn forks this session.
    public let forkFrom: AgentFork?
    /// MCP servers the model may call itself this turn. Empty keeps the
    /// provider tool-free.
    public let mcpServers: [AgentMCPServer]
    /// The working directory is a project folder the user trusted: the
    /// provider may write files and run commands (with network) there.
    public let projectAccess: Bool
    /// The working directory is the user's own folder (a project), not a
    /// workspace AgentDesk made: files there that AgentDesk did not write are left alone.
    public let userFolder: Bool
    public init(localSessionID: UUID, remoteSessionID: String?, prompt: String, workingDirectory: URL, modelID: String, executableURL: URL, reasoningEffort: String? = nil, images: [AgentImageInput] = [], forkFrom: AgentFork? = nil, mcpServers: [AgentMCPServer] = [], projectAccess: Bool = false, userFolder: Bool = false) {
        self.mcpServers = mcpServers
        self.projectAccess = projectAccess
        self.userFolder = userFolder || projectAccess
        self.localSessionID = localSessionID; self.remoteSessionID = remoteSessionID; self.prompt = prompt; self.workingDirectory = workingDirectory; self.modelID = modelID; self.executableURL = executableURL
        self.reasoningEffort = reasoningEffort
        self.images = images
        self.forkFrom = forkFrom
    }
}

public enum AgentEvent: Sendable, Equatable {
    case sessionID(String)
    case textDelta(String)
    case replaceText(String)
    case status(String)
    case actualModels([String])
    /// Provider turn ID of the reply being streamed (Codex).
    case turnID(String)
    case contextUsage(ContextUsage)
    case quota(ProviderQuota)
    case completed
}

public protocol AgentBackend: Sendable {
    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentEvent, Error>
}

public enum AgentError: LocalizedError {
    case unavailable(String)
    case authentication(String)
    case protocolFailure(String)
    case processFailure(String)
    case timeout
    public var errorDescription: String? {
        switch self {
        case .unavailable(let s), .authentication(let s), .protocolFailure(let s), .processFailure(let s): return s
        case .timeout: return "等待模型响应超时。对话已保留，可以稍后继续。"
        }
    }
}
