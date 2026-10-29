import Foundation
import XCTest
@testable import AgentDeskCore

final class CLIProcessLifecycleTests: XCTestCase {
    func testExitStatusIsDecodedToTheChildExitCode() async throws {
        let result = try await CommandCapture.run(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", "import sys; print('before-exit', flush=True); sys.exit(7)"],
            directory: FileManager.default.temporaryDirectory
        )
        XCTAssertEqual(result.code, 7)
        XCTAssertEqual(result.stdout, "before-exit\n")
    }

    func testCancellationKillsIgnoredTermProcessQuickly() async throws {
        let process = CLIProcess(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print('ready', flush=True); time.sleep(30)"],
            directory: FileManager.default.temporaryDirectory,
            environment: RuntimeEnvironment.subscriptionOnly(),
            timeout: 30
        )
        try process.start()
        process.finishInput()
        var sawReady = false
        let reader = Task {
            for await event in process.events {
                if case .stdoutLine(let line) = event, line == "ready" { sawReady = true }
            }
        }
        // Do not wait for the provider's long deadline; this exercises the
        // explicit cancellation path used by Stop and meeting cancellation.
        try await Task.sleep(nanoseconds: 100_000_000)
        process.terminate()
        await reader.value
        XCTAssertTrue(sawReady)
    }

    func testCancellationKillsDescendantsInTheOwnedProcessGroup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentdesk-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("survived")
        let script = ##"""
import os,signal,subprocess,sys,time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
child = subprocess.Popen([sys.executable, "-c", "import signal,sys,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(.45); open(sys.argv[1], 'w').write('survived')", sys.argv[1]])
print(f"{os.getpid()} {child.pid} {os.getpgrp()}", flush=True)
time.sleep(30)
"""##
        let process = CLIProcess(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", script, marker.path],
            directory: root,
            environment: RuntimeEnvironment.subscriptionOnly(),
            timeout: 30
        )
        try process.start()
        process.finishInput()
        var firstLine: String?
        let reader = Task {
            for await event in process.events {
                if case .stdoutLine(let line) = event, firstLine == nil { firstLine = line }
            }
        }
        // The first line proves that the child has created its own group and
        // gives it enough time to start the descendant before cancellation.
        while firstLine == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        process.terminate()
        await reader.value
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "a descendant escaped the owned process group")
    }

    func testRootExitCleansAChildThatKeepsThePipesOpen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentdesk-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("survived")
        let script = ##"""
import signal,subprocess,sys,time
child = subprocess.Popen([sys.executable, "-c", "import signal,sys,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(1.4); open(sys.argv[1], 'w').write('survived')", sys.argv[1]])
print(child.pid, flush=True)
"""##
        let process = CLIProcess(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", script, marker.path],
            directory: root,
            environment: RuntimeEnvironment.subscriptionOnly(),
            timeout: 30
        )
        try process.start()
        process.finishInput()
        var sawExit = false
        for await event in process.events {
            if case .exited = event { sawExit = true }
        }
        XCTAssertTrue(sawExit)
        try await Task.sleep(nanoseconds: 1_700_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "a child survived after its root exited")
    }

    func testTerminateAllOwnedDoesNotKillAnUnrelatedProcess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentdesk-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("unrelated-finished")

        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        unrelated.arguments = ["-c", "import sys,time; time.sleep(.35); open(sys.argv[1], 'w').write('done')", marker.path]
        unrelated.currentDirectoryURL = root
        unrelated.environment = RuntimeEnvironment.subscriptionOnly()
        try unrelated.run()

        let owned = CLIProcess(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", "import time; print('owned', flush=True); time.sleep(30)"],
            directory: root,
            environment: RuntimeEnvironment.subscriptionOnly(),
            timeout: 30
        )
        try owned.start()
        owned.finishInput()
        let reader = Task { for await _ in owned.events {} }
        CLIProcess.terminateAllOwned()
        await reader.value
        unrelated.waitUntilExit()
        XCTAssertEqual(unrelated.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }
}
