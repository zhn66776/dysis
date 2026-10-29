import Foundation
import XCTest
@testable import AgentDeskCore

final class ReasoningPersistenceTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentDesk-effort-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func withoutReasoningEffort<T: Encodable>(_ value: T) throws -> Data {
        let encoded = try JSONEncoder().encode(value)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var mutable = object
        mutable.removeValue(forKey: "reasoningEffort")
        return try JSONSerialization.data(withJSONObject: mutable)
    }

    func testOlderRecordsWithoutReasoningEffortDecodeAsDefault() throws {
        let session = ChatSession(provider: .claude, modelID: "sonnet", workingDirectory: "/tmp/session")
        let configuration = ProviderConfiguration(executablePath: "/bin/true", modelID: "sonnet")
        let member = MeetingMember(name: "分析员", role: "分析", provider: .claude, modelID: "sonnet", workingDirectory: "/tmp/member", executablePath: "/bin/true")

        XCTAssertNil(try JSONDecoder().decode(ChatSession.self, from: withoutReasoningEffort(session)).reasoningEffort)
        XCTAssertNil(try JSONDecoder().decode(ProviderConfiguration.self, from: withoutReasoningEffort(configuration)).reasoningEffort)
        XCTAssertNil(try JSONDecoder().decode(MeetingMember.self, from: withoutReasoningEffort(member)).reasoningEffort)
    }

    func testEffortRoundTripsAcrossPrivateAndPlazaStorage() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(root: root)
        let firstID = UUID()
        let secondID = UUID()
        let first = ChatSession(id: firstID, provider: .claude, modelID: "opus", remoteSessionID: "claude-session", workingDirectory: "/tmp/one", reasoningEffort: "high")
        let second = ChatSession(id: secondID, provider: .codex, modelID: "gpt-test", remoteSessionID: "codex-session", workingDirectory: "/tmp/two", reasoningEffort: "low")
        try store.saveSessions([first, second])
        let restored = try store.loadSessions()
        XCTAssertEqual(restored.first(where: { $0.id == firstID })?.reasoningEffort, "high")
        XCTAssertEqual(restored.first(where: { $0.id == secondID })?.reasoningEffort, "low")
        XCTAssertEqual(restored.first(where: { $0.id == firstID })?.remoteSessionID, "claude-session")
        XCTAssertEqual(restored.first(where: { $0.id == secondID })?.remoteSessionID, "codex-session")

        var configuration = AppConfiguration()
        configuration[.claude] = ProviderConfiguration(executablePath: "/bin/true", modelID: "opus", reasoningEffort: "medium")
        try store.saveConfiguration(configuration)
        XCTAssertEqual(try store.loadConfiguration()?[.claude].reasoningEffort, "medium")

        let memberOne = MeetingMember(name: "分析员", role: "分析", provider: .claude, modelID: "opus", localSessionID: UUID(), remoteSessionID: "group-claude", workingDirectory: "/tmp/group-one", executablePath: "/bin/true", reasoningEffort: "max")
        let memberTwo = MeetingMember(name: "审查员", role: "审查", provider: .codex, modelID: "gpt-test", localSessionID: UUID(), remoteSessionID: "group-codex", workingDirectory: "/tmp/group-two", executablePath: "/bin/true", reasoningEffort: "minimal")
        let room = MeetingRoom(title: "推理深度测试", members: [memberOne, memberTwo])
        let plazaStore = PlazaStore(root: root)
        try plazaStore.save([PlazaRecord(room: room)])
        let plaza = try XCTUnwrap(try plazaStore.load().first)
        XCTAssertEqual(plaza.room.members.map(\.reasoningEffort), ["max", "minimal"])
        XCTAssertEqual(plaza.room.members.map(\.remoteSessionID), ["group-claude", "group-codex"])
        XCTAssertNotEqual(plaza.room.members[0].localSessionID, plaza.room.members[1].localSessionID)
    }

    func testChangingProviderDefaultDoesNotMutateExistingSessionEffort() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(root: root)
        let id = UUID()
        try store.saveSessions([ChatSession(id: id, provider: .claude, modelID: "sonnet", workingDirectory: "/tmp/session", reasoningEffort: "high")])
        var configuration = AppConfiguration()
        configuration[.claude] = ProviderConfiguration(executablePath: "/bin/true", modelID: "sonnet", reasoningEffort: "low")
        try store.saveConfiguration(configuration)

        let persistedSession = try XCTUnwrap(try store.loadSessions().first(where: { $0.id == id }))
        XCTAssertEqual(persistedSession.reasoningEffort, "high")
        XCTAssertEqual(try store.loadConfiguration()?[.claude].reasoningEffort, "low")
    }

    func testMeetingSchedulerCarriesEachMembersEffortAcrossRoundsAndResumedSessions() async throws {
        let requests = RequestRecorder()
        let memberOne = MeetingMember(name: "分析员", role: "分析", provider: .claude, modelID: "sonnet", localSessionID: UUID(), remoteSessionID: "resume-claude", workingDirectory: "/tmp/one", executablePath: "/bin/true", reasoningEffort: "high")
        let memberTwo = MeetingMember(name: "审查员", role: "审查", provider: .codex, modelID: "gpt-test", localSessionID: UUID(), remoteSessionID: "resume-codex", workingDirectory: "/tmp/two", executablePath: "/bin/true", reasoningEffort: "low")
        let room = MeetingRoom(title: "Effort 会议", members: [memberOne, memberTwo])
        let scheduler = MeetingScheduler { member in
            EffortRecordingBackend(memberID: member.id, recorder: requests)
        }

        var events: [MeetingEvent] = []
        for try await event in scheduler.execute(room: room, prompt: "测试推理深度", mode: .meeting, maxRounds: 2) {
            events.append(event)
        }
        let observed = await requests.all()
        XCTAssertEqual(observed.count, 4)
        XCTAssertEqual(observed.map(\.reasoningEffort), ["high", "low", "high", "low"])
        XCTAssertEqual(observed.map(\.remoteSessionID), ["resume-claude", "resume-codex", "resume-claude", "resume-codex"])
        XCTAssertTrue(events.contains { if case .runEnded = $0 { return true }; return false })
    }

    private actor RequestRecorder {
        private var values: [AgentRequest] = []
        func append(_ value: AgentRequest) { values.append(value) }
        func all() -> [AgentRequest] { values }
    }

    private struct EffortRecordingBackend: AgentBackend {
        let memberID: UUID
        let recorder: RequestRecorder

        func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentEvent, Error> {
            AsyncThrowingStream { continuation in
                Task {
                    await recorder.append(request)
                    continuation.yield(.sessionID(request.remoteSessionID ?? "session-\(memberID.uuidString)"))
                    continuation.yield(.textDelta("ok"))
                    continuation.yield(.completed)
                    continuation.finish()
                }
            }
        }
    }
}
