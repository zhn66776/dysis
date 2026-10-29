import XCTest
@testable import AgentDeskCore

final class StreamBackendTests: XCTestCase {
    func testActualClaudeModelComesFromResponseNotRequestedAlias() {
        let assistant = ClaudeJSONEventParser.parse([
            "type": "assistant", "message": ["model": "claude-opus-5-5", "content": [["type": "text", "text": "hello"]]]
        ])
        XCTAssertEqual(assistant.actualModelIDs, ["claude-opus-5-5"])
        let result = ClaudeJSONEventParser.parse([
            "type": "result", "subtype": "success", "result": "hello",
            "modelUsage": ["claude-opus-5": ["inputTokens": 2], "claude-opus-5-5": ["inputTokens": 3]]
        ])
        XCTAssertEqual(result.actualModelIDs, ["claude-opus-5", "claude-opus-5-5"])
        XCTAssertNil(ClaudeJSONEventParser.parse(["type": "system", "subtype": "init", "model": "opus"]).actualModelIDs)
    }

    func testClaudeInitAndDelta() {
        let object: [String: Any] = [
            "type": "stream_event", "session_id": "claude-session",
            "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "hello"]]
        ]
        let event = ClaudeJSONEventParser.parse(object)
        XCTAssertEqual(event.sessionID, "claude-session")
        XCTAssertEqual(event.textDelta, "hello")
        XCTAssertFalse(event.isFailure)
    }

    func testClaudeSuccessResult() {
        let event = ClaudeJSONEventParser.parse(["type": "result", "subtype": "success", "session_id": "s", "result": "done"])
        XCTAssertEqual(event.finalText, "done")
        XCTAssertFalse(event.isFailure)
    }

    func testClaudeErrorResultIsFailure() {
        let event = ClaudeJSONEventParser.parse(["type": "result", "subtype": "success", "is_error": true, "session_id": "s", "result": "failed"])
        XCTAssertTrue(event.isFailure)
    }

    func testCursorResultAndDelta() {
        let delta = CursorJSONEventParser.parse(["type": "assistant", "session_id": "cursor-session", "timestamp_ms": 1, "message": ["content": [["type": "text", "text": "hi"]]]])
        XCTAssertEqual(delta.sessionID, "cursor-session")
        XCTAssertEqual(delta.textDelta, "hi")
        let result = CursorJSONEventParser.parse(["type": "result", "session_id": "cursor-session", "result": "done"])
        XCTAssertEqual(result.finalText, "done")
    }

    func testCursorErrorResultIsFailure() {
        let event = CursorJSONEventParser.parse(["type": "result", "subtype": "success", "is_error": true, "session_id": "s", "result": "failed"])
        XCTAssertTrue(event.isFailure)
    }

    func testMissingSessionIDIsObservable() {
        XCTAssertNil(ClaudeJSONEventParser.parse(["type": "result", "subtype": "success", "result": "done"]).sessionID)
        XCTAssertNil(CursorJSONEventParser.parse(["type": "result", "subtype": "success", "result": "done"]).sessionID)
    }

    func testCursorDuplicateFlushesAreIgnored() {
        let beforeTool = CursorJSONEventParser.parse(["type": "assistant", "timestamp_ms": 1, "model_call_id": "call", "message": ["content": [["type": "text", "text": "duplicate"]]]])
        let finalFlush = CursorJSONEventParser.parse(["type": "assistant", "message": ["content": [["type": "text", "text": "duplicate"]]]])
        XCTAssertNil(beforeTool.textDelta)
        XCTAssertNil(finalFlush.textDelta)
    }

    func testErrorsAreRecognized() {
        XCTAssertTrue(ClaudeJSONEventParser.parse(["type": "error", "error": "bad"]).isFailure)
        XCTAssertTrue(CursorJSONEventParser.parse(["type": "error", "message": "bad"]).isFailure)
    }
}
