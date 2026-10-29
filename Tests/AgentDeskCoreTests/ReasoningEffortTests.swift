import XCTest
@testable import AgentDeskCore

final class ReasoningEffortTests: XCTestCase {
    func testClaudeUsesDocumentedEffortChoices() {
        XCTAssertEqual(ReasoningEffortCatalog.claudeChoices, ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(ReasoningEffortCatalog.normalized(" HIGH "), "high")
        XCTAssertNil(ReasoningEffortCatalog.normalized("ultra"))
    }

    func testCursorVariantsPreserveFamilyAndFastMode() {
        let discovered = ["grok-4.7-low", "grok-4.7-medium", "grok-4.7-high", "grok-4.7-xhigh", "grok-4.7-high-fast", "cursor-grok-4.6-high", "gemini-4-argon-high"]
        XCTAssertEqual(ReasoningEffortCatalog.cursorVariantEffort(modelID: "grok-4.7-high-fast"), "high")
        let normal = ReasoningEffortCatalog.cursorVariants(modelID: "grok-4.7-medium", availableModelIDs: discovered)
        XCTAssertEqual(Set(normal.keys), ["low", "medium", "high", "xhigh"])
        XCTAssertEqual(normal["high"], "grok-4.7-high")
        let fast = ReasoningEffortCatalog.cursorVariants(modelID: "grok-4.7-medium-fast", availableModelIDs: discovered)
        XCTAssertEqual(fast, ["high": "grok-4.7-high-fast"])
        let gemini = ReasoningEffortCatalog.cursorVariants(modelID: "gemini-4-argon-medium", availableModelIDs: discovered)
        XCTAssertEqual(gemini, ["high": "gemini-4-argon-high"])
    }

    func testMissingCursorVariantsNeverInventModelIDs() {
        XCTAssertTrue(ReasoningEffortCatalog.cursorVariants(modelID: "grok-new", availableModelIDs: ["grok-4.7-high"]).isEmpty)
        XCTAssertTrue(ReasoningEffortCatalog.cursorVariants(modelID: "grok-4.7-medium", availableModelIDs: []).isEmpty)
        XCTAssertTrue(ReasoningEffortCatalog.cursorVariants(modelID: "grok-4.7[effort=low,fast=true]", availableModelIDs: ["grok-4.7-high"]).isEmpty)
    }

    func testCodexEffortComesFromDynamicModelCatalog() {
        XCTAssertTrue(ReasoningEffortCatalog.choices(for: .codex).isEmpty)
    }

    func testClaudeBackendPassesEffortToOfficialCLIWithoutUsingAPIEnvironment() async throws {
        let fixture = try makeFixture(script: #"""
import json,sys
a=sys.argv[1:]
if 'auth' in a and 'status' in a:
 print(json.dumps({'authMethod':'claude.ai','apiProvider':'firstParty','subscriptionType':'pro'})); raise SystemExit
assert '--effort' in a and a[a.index('--effort')+1]=='high'
sid=a[a.index('--session-id')+1]
print(json.dumps({'type':'system','subtype':'init','session_id':sid}),flush=True)
print(json.dumps({'type':'result','subtype':'success','session_id':sid,'result':'ok'}),flush=True)
"""#)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let request = AgentRequest(localSessionID: UUID(), remoteSessionID: nil, prompt: "offline", workingDirectory: FileManager.default.temporaryDirectory, modelID: "sonnet", executableURL: fixture, reasoningEffort: "high")
        var completed = false
        for try await event in ClaudeBackend().stream(request) { if case .completed = event { completed = true } }
        XCTAssertTrue(completed)
    }

    func testCursorBackendPassesExactDiscoveredEffortModelID() async throws {
        let fixture = try makeFixture(script: #"""
import json,sys
a=sys.argv[1:]
if a == ['status']:
 print('logged in'); raise SystemExit
model=a[a.index('--model')+1]
assert model == 'grok-4.7-high'
print(json.dumps({'type':'assistant','session_id':'cursor-fixture','timestamp_ms':1,'message':{'content':[{'type':'text','text':'ok'}]}}),flush=True)
print(json.dumps({'type':'result','session_id':'cursor-fixture','result':'ok'}),flush=True)
"""#)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let request = AgentRequest(localSessionID: UUID(), remoteSessionID: nil, prompt: "offline", workingDirectory: FileManager.default.temporaryDirectory, modelID: "grok-4.7-high", executableURL: fixture)
        var completed = false
        for try await event in CursorBackend().stream(request) { if case .completed = event { completed = true } }
        XCTAssertTrue(completed)
    }

    private func makeFixture(script: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agentdesk-effort-\(UUID().uuidString).py")
        try Data(("#!/usr/bin/python3\n" + script).utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
