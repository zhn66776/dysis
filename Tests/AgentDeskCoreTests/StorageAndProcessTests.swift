import Foundation
import XCTest
@testable import AgentDeskCore

final class StorageAndProcessTests: XCTestCase {
    func testOlderMessageWithoutActualModelFieldStillLoads() throws {
        let old = Data(#"{"id":"00000000-0000-0000-0000-000000000001","role":"assistant","text":"existing reply","state":"complete","createdAt":0}"#.utf8)
        let message = try JSONDecoder().decode(ChatMessage.self, from: old)
        XCTAssertEqual(message.text, "existing reply")
        XCTAssertNil(message.actualModelIDs)
    }

    func testIndependentSessionsSurviveRestartWithoutResendingInterruptedMessage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(root: root)
        let a = UUID(), b = UUID()
        let first = ChatSession(id: a, provider: .claude, modelID: "sonnet", remoteSessionID: "official-a", workingDirectory: try store.makeWorkspace(for: a).path, messages: [.init(role: .assistant, text: "partial", state: .streaming)])
        let second = ChatSession(id: b, provider: .gemini, modelID: "gemini-test", remoteSessionID: "official-b", workingDirectory: try store.makeWorkspace(for: b).path, messages: [.init(role: .user, text: "different context")])
        try store.saveSessions([first, second])
        let restored = try LocalStore(root: root).loadSessions()
        let ra = try XCTUnwrap(restored.first { $0.id == a })
        let rb = try XCTUnwrap(restored.first { $0.id == b })
        XCTAssertEqual(ra.remoteSessionID, "official-a")
        XCTAssertEqual(ra.messages.first?.text, "partial")
        XCTAssertEqual(ra.messages.first?.state, .cancelled)
        XCTAssertEqual(rb.messages.first?.text, "different context")
        XCTAssertNotEqual(ra.workingDirectory, rb.workingDirectory)
    }

    func testCorruptHistoryIsNotReplacedWithEmptyHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(root: root)
        let bytes = Data("not valid JSON".utf8)
        try bytes.write(to: store.sessionsURL)
        XCTAssertThrowsError(try store.loadSessions())
        XCTAssertEqual(try Data(contentsOf: store.sessionsURL), bytes)
    }

    func testFinalOutputIsDrainedBeforeExitAndUnicodeSurvivesChunking() async throws {
        let result = try await CommandCapture.run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", "import sys; b='你好\\nfinal'.encode(); sys.stdout.buffer.write(b[:2]); sys.stdout.flush(); sys.stdout.buffer.write(b[2:]); sys.stdout.flush(); sys.stderr.write('diagnostic\\n')"], directory: FileManager.default.temporaryDirectory)
        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(result.stdout, "你好\nfinal\n")
        XCTAssertEqual(result.stderr, "diagnostic\n")
    }

    func testHungProcessIsTerminatedByDeadline() async throws {
        let process = CLIProcess(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", "import time; time.sleep(30)"], directory: FileManager.default.temporaryDirectory, environment: RuntimeEnvironment.subscriptionOnly(), timeout: 0.15)
        let start = Date()
        try process.start(); process.finishInput()
        var status: Int32?
        for await event in process.events { if case .exited(let code) = event { status = code } }
        XCTAssertNotEqual(status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testCatalogKeepsProviderModelIDsIncludingCursorPrefixes() {
        let catalog = "Available models\nauto - Auto\ncursor-grok-4.6-medium - Grok 4.6\ngrok-4.7-medium - Grok 4.7\ngemini-4-argon-medium - Gemini\n"
        XCTAssertEqual(ModelCatalog.cursorIDs(from: catalog, family: "grok"), ["cursor-grok-4.6-medium", "grok-4.7-medium"])
        XCTAssertEqual(ModelCatalog.cursorIDs(from: catalog, family: "gemini"), ["gemini-4-argon-medium"])
    }
}
