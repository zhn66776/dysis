import Foundation
import XCTest
@testable import AgentDeskCore

@MainActor
final class CanvasChainRunnerTests: XCTestCase {
    /// Records every call; each node's start and finish can be scripted.
    @MainActor
    private final class Fake {
        var events: [String] = []
        var starts: [UUID: CanvasChainRunner.Start] = [:]
        var finishes: [UUID: CanvasChainRunner.Finish] = [:]
        var running: UUID?
        /// Runs while a node is waiting, before its finish is returned.
        var whileWaiting: ((UUID) -> Void)?
        let names: [UUID: String]

        init(_ names: [String]) {
            var map: [UUID: String] = [:]
            for n in names { map[UUID()] = n }
            self.names = map
        }

        func id(_ name: String) -> UUID { names.first { $0.value == name }!.key }

        func runner() -> CanvasChainRunner {
            CanvasChainRunner(
                step: { self.events.append("step \($0)") },
                start: { id in
                    XCTAssertNil(self.running, "a node started while another was still running")
                    let start = self.starts[id] ?? .started
                    self.events.append("start \(self.names[id]!)")
                    if start == .started { self.running = id }
                    return start
                },
                wait: { id in
                    self.events.append("wait \(self.names[id]!)")
                    await Task.yield()
                    self.whileWaiting?(id)
                    self.running = nil
                    if Task.isCancelled { return .cancelled }
                    return self.finishes[id] ?? .complete
                },
                stop: { id in self.events.append("stop \(self.names[id]!)") })
        }
    }

    func testRunsEveryNodeInOrderOneAtATime() async {
        let fake = Fake(["a", "b", "c"])
        let order = ["a", "b", "c"].map(fake.id)
        let outcome = await fake.runner().run(order)
        XCTAssertEqual(outcome, .finished)
        XCTAssertEqual(fake.events, ["step 0", "start a", "wait a", "step 1", "start b", "wait b", "step 2", "start c", "wait c"])
    }

    func testStopsAfterANodeThatDoesNotComplete() async {
        let fake = Fake(["a", "b", "c"])
        fake.finishes[fake.id("b")] = .incomplete
        let outcome = await fake.runner().run(["a", "b", "c"].map(fake.id))
        XCTAssertEqual(outcome, .incomplete(index: 1))
        XCTAssertFalse(fake.events.contains("start c"))
        XCTAssertFalse(fake.events.contains { $0.hasPrefix("stop") })
    }

    func testStopsWhenANodeFailsToStart() async {
        let fake = Fake(["a", "b", "c"])
        fake.starts[fake.id("b")] = .failed
        let outcome = await fake.runner().run(["a", "b", "c"].map(fake.id))
        XCTAssertEqual(outcome, .notStarted(index: 1))
        XCTAssertFalse(fake.events.contains("wait b"))
        XCTAssertFalse(fake.events.contains("start c"))
    }

    func testSkippedNodeIsNotWaitedOnAndTheChainContinues() async {
        let fake = Fake(["a", "b", "c"])
        fake.starts[fake.id("b")] = .skipped
        let outcome = await fake.runner().run(["a", "b", "c"].map(fake.id))
        XCTAssertEqual(outcome, .finished)
        XCTAssertFalse(fake.events.contains("wait b"))
        XCTAssertTrue(fake.events.contains("wait c"))
    }

    func testRefusesOverTheCapWithoutStartingAnything() async {
        let names = (0...CanvasChainRunner.maxCalls).map { "n\($0)" }
        let fake = Fake(names)
        let outcome = await fake.runner().run(names.map(fake.id))
        XCTAssertEqual(outcome, .overCap)
        XCTAssertEqual(fake.events, [])
        XCTAssertEqual(CanvasChainRunner.refusal(count: CanvasChainRunner.maxCalls), nil)
        XCTAssertEqual(CanvasChainRunner.refusal(count: 0), .empty)
    }

    func testRunsExactlyTheCap() async {
        let names = (0..<CanvasChainRunner.maxCalls).map { "n\($0)" }
        let fake = Fake(names)
        let outcome = await fake.runner().run(names.map(fake.id))
        XCTAssertEqual(outcome, .finished)
        XCTAssertEqual(fake.events.filter { $0.hasPrefix("start") }.count, CanvasChainRunner.maxCalls)
    }

    func testCancelWhileANodeRunsStopsThatNodeAndStartsNoMore() async {
        let fake = Fake(["a", "b", "c"])
        var task: Task<CanvasChainRunner.Outcome, Never>?
        fake.whileWaiting = { id in if fake.names[id] == "b" { task?.cancel() } }
        let runner = fake.runner()
        task = Task { await runner.run(["a", "b", "c"].map(fake.id)) }
        let outcome = await task!.value
        XCTAssertEqual(outcome, .cancelled(index: 1))
        XCTAssertEqual(fake.events.suffix(2), ["wait b", "stop b"])
        XCTAssertFalse(fake.events.contains("start c"))
    }

    func testCancelAfterANodeCompletedStopsBeforeTheNextOne() async {
        let fake = Fake(["a", "b"])
        var task: Task<CanvasChainRunner.Outcome, Never>?
        let runner = CanvasChainRunner(
            start: { _ in fake.events.append("start"); return .started },
            wait: { _ in task?.cancel(); return .complete },
            stop: { _ in fake.events.append("stop") })
        task = Task { await runner.run(["a", "b"].map(fake.id)) }
        let outcome = await task!.value
        XCTAssertEqual(outcome, .cancelled(index: 1))
        XCTAssertEqual(fake.events, ["start"])
    }
}
