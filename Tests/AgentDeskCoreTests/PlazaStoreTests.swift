import Foundation
import XCTest
@testable import AgentDeskCore

final class PlazaStoreTests: XCTestCase {
    private func members() -> [MeetingMember] {
        [MeetingMember(name: "分析员", role: "分析", provider: .claude, modelID: "sonnet", workingDirectory: "/tmp/a", executablePath: "/usr/bin/true"),
         MeetingMember(name: "审查员", role: "评估", provider: .codex, modelID: "test", workingDirectory: "/tmp/b", executablePath: "/usr/bin/true")]
    }

    func testMentionOnlySelectsExactHumanRequestedMembers() {
        let team = members()
        let all = Set(team.map(\.id))
        XCTAssertEqual(MeetingRecipients.resolve(prompt: "@分析员 检查一下", members: team, selected: all), [team[0].id])
        XCTAssertEqual(MeetingRecipients.resolve(prompt: "@everyone，开始", members: team, selected: []), all)
        XCTAssertEqual(MeetingRecipients.resolve(prompt: "@不存在 检查一下", members: team, selected: all), [])
        XCTAssertEqual(MeetingRecipients.resolve(prompt: "普通问题", members: team, selected: [team[1].id]), [team[1].id])
        XCTAssertEqual(MeetingRecipients.resolve(prompt: "@分析员补充", members: team, selected: all), [])
    }

    func testPlazaRestartKeepsSessionsAndPartialOutputWithoutRunning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlazaStore(root: root)
        var team = members(); team[0].remoteSessionID = "dedicated-group-session"
        let room = MeetingRoom(title: "SSS", members: team)
        let run = MeetingRunRecord(runID: UUID(), roomID: room.id, prompt: "检查证据", mode: .meeting, state: .running, reservedCalls: 6, callsStarted: 2)
        let message = MeetingMessage(runID: run.runID, memberID: team[0].id, memberName: team[0].name, round: 1, text: "已生成内容", state: .running)
        try store.save([PlazaRecord(room: room, sharedContext: "公共资料", runs: [run], messages: [message])])
        let restored = try XCTUnwrap(store.load().first)
        XCTAssertEqual(restored.runs.first?.state, .stopped)
        XCTAssertEqual(restored.runs.first?.callsStarted, 2)
        XCTAssertEqual(restored.messages.first?.state, .stopped)
        XCTAssertEqual(restored.messages.first?.text, "已生成内容")
        XCTAssertEqual(restored.room.members.first?.remoteSessionID, "dedicated-group-session")
        XCTAssertNotEqual(restored.room.members[0].localSessionID, restored.room.members[1].localSessionID)
        XCTAssertEqual(restored.sharedContext, "公共资料")
    }

    func testCorruptPlazaFileRemainsUntouched() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlazaStore(root: root)
        let corrupt = Data("broken JSON".utf8)
        try corrupt.write(to: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.url), corrupt)
    }
}
