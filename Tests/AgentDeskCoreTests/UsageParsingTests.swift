import Foundation
import XCTest
@testable import AgentDeskCore

/// Context and quota parsing from recorded event shapes; no CLI runs.
final class UsageParsingTests: XCTestCase {
    func testClaudeResultReportsContextAgainstTheModelWindow() {
        let result: [String: Any] = [
            "type": "result", "subtype": "success", "result": "ok", "session_id": "s",
            "usage": ["input_tokens": 12, "cache_creation_input_tokens": 3_000, "cache_read_input_tokens": 15_000, "output_tokens": 400],
            "modelUsage": ["claude-sonnet-5-5": ["inputTokens": 12, "contextWindow": 200_000]]
        ]
        XCTAssertEqual(ClaudeJSONEventParser.parse(result).contextUsage, ContextUsage(usedTokens: 18_412, windowTokens: 200_000))
    }

    func testClaudeRateLimitEventPrefersPerWindowUtilization() {
        let event: [String: Any] = ["type": "rate_limit_event", "session_id": "s", "rate_limit_info": [
            "status": "allowed", "rateLimitType": "five_hour", "utilization": 0.3, "resetsAt": 1_793_300_000,
            "unifiedWindows": ["five_hour": ["utilization": 0.3, "resetsAt": 1_793_300_000], "seven_day": ["utilization": 0.62, "resetsAt": 1_793_800_000]]
        ]]
        let quota = ClaudeJSONEventParser.parse(event).quota
        XCTAssertEqual(quota?.windows.map(\.label), ["5 小时", "每周"])
        XCTAssertEqual(quota?.windows.map { Int($0.usedPercent.rounded()) }, [30, 62])
        XCTAssertEqual(quota?.status, "allowed")
    }

    func testClaudeRateLimitEventWithOnlyStatusKeepsTheStatus() {
        let quota = ClaudeJSONEventParser.parse(["type": "rate_limit_event", "rate_limit_info": ["status": "allowed_warning"]]).quota
        XCTAssertEqual(quota?.windows, [])
        XCTAssertEqual(quota?.status, "allowed_warning")
    }

    func testWindowLabels() {
        XCTAssertEqual(ProviderQuota.windowLabel(minutes: 300), "5 小时")
        XCTAssertEqual(ProviderQuota.windowLabel(minutes: 10080), "每周")
        XCTAssertEqual(ProviderQuota.windowLabel(minutes: 2880), "2 天")
        XCTAssertEqual(ProviderQuota.windowLabel(minutes: nil), "用量")
    }

    func testCursorFamiliesFoldEffortVariants() {
        let ids = ["grok-4.7-low", "grok-4.7-medium", "grok-4.7-high", "grok-4.7-medium-fast", "grok-4.7-high-fast", "grok-code"]
        let families = ReasoningEffortCatalog.cursorFamilies(availableModelIDs: ids)
        XCTAssertEqual(families.map(\.label), ["grok-4.7", "grok-4.7-fast", "grok-code"])
        XCTAssertEqual(families.map(\.id), ["grok-4.7-medium", "grok-4.7-medium-fast", "grok-code"])
        XCTAssertEqual(ReasoningEffortCatalog.cursorFamily(of: "grok-4.7-high"), "grok-4.7")
    }

    func testSessionWithoutContextUsageStillLoads() throws {
        let old = Data(#"{"id":"00000000-0000-0000-0000-000000000001","title":"t","provider":"claude","modelID":"sonnet","workingDirectory":"/tmp","messages":[],"createdAt":0,"updatedAt":0}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ChatSession.self, from: old).contextUsage)
    }
}
