import Foundation
import XCTest
@testable import AgentDeskCore

final class CLIProcessInputTests: XCTestCase {
    func testLargeBlockedWriteIsInterruptible() async throws {
        let process = CLIProcess(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-u", "-c", "import time; time.sleep(30)"],
            directory: FileManager.default.temporaryDirectory,
            environment: RuntimeEnvironment.subscriptionOnly(),
            timeout: 10
        )
        try process.start()
        let writer = Task {
            try process.writeJSON(["payload": String(repeating: "x", count: 16 * 1024 * 1024)])
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let started = Date()
        process.terminate()
        do {
            try await writer.value
            XCTFail("blocked input write should be cancelled")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        }
        for await _ in process.events {}
    }

    func testSequentialJSONWritesRemainSeparateAndOrdered() async throws {
        let process = CLIProcess(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-u", "-c", "import sys,json\nfor line in sys.stdin:\n print(line.strip(), flush=True)"],
            directory: FileManager.default.temporaryDirectory,
            environment: RuntimeEnvironment.subscriptionOnly(),
            timeout: 10
        )
        try process.start()
        try process.writeJSON(["sequence": 1])
        try process.writeJSON(["sequence": 2])
        process.finishInput()
        var lines: [[String: Any]] = []
        for await event in process.events {
            if case .stdoutLine(let line) = event,
               let data = line.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                lines.append(object)
            }
        }
        XCTAssertEqual(lines.compactMap { ($0["sequence"] as? NSNumber)?.intValue }, [1, 2])
    }
}
