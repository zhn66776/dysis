import Foundation

/// The two ways a plaza can send work. A manual run is one bounded turn for
/// the members the user mentions. A meeting is a fixed, centrally scheduled
/// number of rounds.
public enum MeetingMode: String, Codable, Sendable {
    case manual
    case meeting
}

public enum MeetingRunState: String, Codable, Sendable {
    case planned
    case running
    case completed
    case stopped
    case cancelled
    case timedOut
    case failed
}

public struct MeetingMember: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var role: String
    public var provider: ProviderID
    public var modelID: String
    public var localSessionID: UUID
    public var remoteSessionID: String?
    public var workingDirectory: String
    public var executablePath: String
    public var reasoningEffort: String?

    public init(
        id: UUID = UUID(),
        name: String,
        role: String,
        provider: ProviderID,
        modelID: String,
        localSessionID: UUID = UUID(),
        remoteSessionID: String? = nil,
        workingDirectory: String,
        executablePath: String,
        reasoningEffort: String? = nil
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.provider = provider
        self.modelID = modelID
        self.localSessionID = localSessionID
        self.remoteSessionID = remoteSessionID
        self.workingDirectory = workingDirectory
        self.executablePath = executablePath
        self.reasoningEffort = reasoningEffort
    }
}

public struct MeetingRoom: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var members: [MeetingMember]
    public var summarizerMemberID: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        members: [MeetingMember],
        summarizerMemberID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.members = members
        self.summarizerMemberID = summarizerMemberID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func validated() throws -> MeetingRoom {
        guard (2...4).contains(members.count) else {
            throw MeetingValidationError.memberCount
        }
        let names = members.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard names.allSatisfy({ !$0.isEmpty && !$0.contains("@") && $0.rangeOfCharacter(from: .whitespacesAndNewlines) == nil }), Set(names).count == names.count else {
            throw MeetingValidationError.memberNames
        }
        guard Set(members.map(\.id)).count == members.count else {
            throw MeetingValidationError.memberIDs
        }
        guard Set(members.map(\.localSessionID)).count == members.count else {
            throw MeetingValidationError.memberSessionIDs
        }
        let directories = members.map { $0.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard directories.allSatisfy({ !$0.isEmpty }), Set(directories).count == directories.count else {
            throw MeetingValidationError.memberDirectories
        }
        if let summarizerMemberID, !members.contains(where: { $0.id == summarizerMemberID }) {
            throw MeetingValidationError.summarizer
        }
        return self
    }
}

public enum MeetingValidationError: LocalizedError, Equatable, Sendable {
    case memberCount
    case memberNames
    case memberIDs
    case memberSessionIDs
    case memberDirectories
    case summarizer
    case noSelectedMembers
    case selectedMemberNotInRoom
    case meetingNeedsTwoMembers
    case invalidRounds
    case emptyPrompt

    public var errorDescription: String? {
        switch self {
        case .memberCount: return "广场需要 2–4 位成员。"
        case .memberNames: return "成员名称必须非空且不能重复。"
        case .memberIDs: return "成员 ID 必须唯一。"
        case .memberSessionIDs: return "每位成员必须使用独立的本地 Session。"
        case .memberDirectories: return "每位成员必须使用独立的工作目录。"
        case .summarizer: return "汇总成员必须属于这个广场。"
        case .noSelectedMembers: return "至少选择一位成员。"
        case .selectedMemberNotInRoom: return "选择的成员不属于这个广场。"
        case .meetingNeedsTwoMembers: return "会议模式至少需要两位成员。"
        case .invalidRounds: return "会议轮数必须在 1–3 轮之间。"
        case .emptyPrompt: return "议题不能为空。"
        }
    }
}

public struct MeetingLimits: Codable, Equatable, Sendable {
    public var perTurnTimeoutNanoseconds: UInt64
    public var totalTimeoutNanoseconds: UInt64
    public var maxOutputCharacters: Int
    public var maxContextCharacters: Int

    public init(
        perTurnTimeoutNanoseconds: UInt64 = 120_000_000_000,
        totalTimeoutNanoseconds: UInt64 = 900_000_000_000,
        maxOutputCharacters: Int = 8_000,
        maxContextCharacters: Int = 12_000
    ) {
        self.perTurnTimeoutNanoseconds = max(1, perTurnTimeoutNanoseconds)
        self.totalTimeoutNanoseconds = max(1, totalTimeoutNanoseconds)
        self.maxOutputCharacters = max(1, maxOutputCharacters)
        self.maxContextCharacters = max(1, maxContextCharacters)
    }

    public static let `default` = MeetingLimits()
}

public struct MeetingMessage: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var runID: UUID
    public var memberID: UUID
    public var memberName: String
    /// Optional for backwards compatibility with transcripts written before
    /// role labels were added.
    public var memberRole: String?
    public var round: Int
    public var text: String
    public var state: MeetingRunState
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        runID: UUID,
        memberID: UUID,
        memberName: String,
        memberRole: String? = nil,
        round: Int,
        text: String,
        state: MeetingRunState = .completed,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.runID = runID
        self.memberID = memberID
        self.memberName = memberName
        self.memberRole = memberRole
        self.round = round
        self.text = text
        self.state = state
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, runID, memberID, memberName, memberRole, round, text, state, createdAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        runID = try values.decode(UUID.self, forKey: .runID)
        memberID = try values.decode(UUID.self, forKey: .memberID)
        memberName = try values.decode(String.self, forKey: .memberName)
        memberRole = try values.decodeIfPresent(String.self, forKey: .memberRole)
        round = try values.decode(Int.self, forKey: .round)
        text = try values.decode(String.self, forKey: .text)
        state = try values.decode(MeetingRunState.self, forKey: .state)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
    }
}

public struct MeetingRunResult: Codable, Equatable, Sendable {
    public var runID: UUID
    public var roomID: UUID
    public var state: MeetingRunState
    public var reservedCalls: Int
    public var callsStarted: Int
    public var callsCompleted: Int
    public var completedRounds: Int
    public var messages: [MeetingMessage]
    public var stopReason: String?
    public var summarizerMemberID: UUID?

    public init(
        runID: UUID,
        roomID: UUID,
        state: MeetingRunState,
        reservedCalls: Int,
        callsStarted: Int,
        callsCompleted: Int,
        completedRounds: Int,
        messages: [MeetingMessage],
        stopReason: String? = nil,
        summarizerMemberID: UUID? = nil
    ) {
        self.runID = runID
        self.roomID = roomID
        self.state = state
        self.reservedCalls = reservedCalls
        self.callsStarted = callsStarted
        self.callsCompleted = callsCompleted
        self.completedRounds = completedRounds
        self.messages = messages
        self.stopReason = stopReason
        self.summarizerMemberID = summarizerMemberID
    }
}

/// A persisted run record is deliberately small. It is safe to write before
/// the first provider call and to mark as stopped on the next app launch.
public struct MeetingRunRecord: Codable, Equatable, Sendable {
    public var runID: UUID
    public var roomID: UUID
    public var prompt: String
    public var mode: MeetingMode
    public var state: MeetingRunState
    public var reservedCalls: Int
    public var callsStarted: Int
    public var completedRounds: Int
    public var startedAt: Date
    public var finishedAt: Date?
    public var stopReason: String?
    public var attachments: [ChatAttachment]?

    public init(
        runID: UUID,
        roomID: UUID,
        prompt: String,
        mode: MeetingMode,
        state: MeetingRunState = .planned,
        reservedCalls: Int,
        callsStarted: Int = 0,
        completedRounds: Int = 0,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        stopReason: String? = nil,
        attachments: [ChatAttachment]? = nil
    ) {
        self.runID = runID
        self.roomID = roomID
        self.prompt = prompt
        self.mode = mode
        self.state = state
        self.reservedCalls = reservedCalls
        self.callsStarted = callsStarted
        self.completedRounds = completedRounds
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.stopReason = stopReason
        self.attachments = attachments
    }

    public func recoveredAfterRestart() -> MeetingRunRecord {
        guard state == .running else { return self }
        var copy = self
        copy.state = .stopped
        copy.finishedAt = Date()
        copy.stopReason = "应用关闭时运行未完成，已停止；不会自动恢复或重发。"
        return copy
    }
}
