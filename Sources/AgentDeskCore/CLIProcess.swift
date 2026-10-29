import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum ProcessEvent: Sendable {
    case stdoutLine(String), stderrLine(String), exited(Int32)
}

/// A pipe transport with separate output readers. No shell interpolation and
/// no log files: provider authentication output stays in memory.
public final class CLIProcess: @unchecked Sendable {
    public let events: AsyncStream<ProcessEvent>
    private let continuation: AsyncStream<ProcessEvent>.Continuation
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    /// Serializes complete JSONL messages without holding the lifecycle lock.
    /// A provider that stops reading stdin must not block terminate() behind a
    /// multi-megabyte image write.
    private let inputWriteLock = NSLock()
    private let readers = DispatchGroup()
    private var started = false
    private var cancelled = false
    private var inputClosed = false
    private var didFinish = false
    private var reaped = false
    private var terminationRequested = false
    private var terminationDeadline: Date?
    private var processID: pid_t = 0
    private var processGroupID: pid_t = 0
    private var timeoutTask: DispatchWorkItem?
    private let timeout: TimeInterval
    private static let ignoreBrokenPipe: Void = { signal(SIGPIPE, SIG_IGN) }()

    private final class WeakBox {
        weak var value: CLIProcess?
        init(_ value: CLIProcess) { self.value = value }
    }
    private static let registryLock = NSLock()
    private static var registry: [ObjectIdentifier: WeakBox] = [:]

    public init(executable: URL, arguments: [String], directory: URL, environment: [String: String], timeout: TimeInterval = 300) {
        let pair = AsyncStream<ProcessEvent>.makeStream()
        events = pair.stream; continuation = pair.continuation
        self.timeout = timeout
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
        self.environment = environment
        continuation.onTermination = { [weak self] _ in self?.terminate() }
        Self.register(self)
    }

    private let executable: URL
    private let arguments: [String]
    private let directory: URL
    private let environment: [String: String]

    private static func register(_ process: CLIProcess) {
        registryLock.lock(); defer { registryLock.unlock() }
        registry[ObjectIdentifier(process)] = WeakBox(process)
    }

    private func unregister() {
        Self.registryLock.lock(); defer { Self.registryLock.unlock() }
        Self.registry.removeValue(forKey: ObjectIdentifier(self))
    }

    /// Stop every process group owned by this AgentDesk instance. This is used
    /// during app shutdown because cancelling Swift tasks alone is not enough
    /// to guarantee that a subprocess has received its cancellation signal.
    public static func terminateAllOwned() {
        registryLock.lock()
        let processes = registry.values.compactMap(\.value)
        registry = registry.filter { $0.value.value != nil }
        registryLock.unlock()
        for process in processes { process.terminate() }
        // applicationShouldTerminate returns immediately after this call.
        // Complete the bounded escalation here; a queued dispatch block would
        // disappear with the app before it could stop a SIGTERM-ignoring child.
        for process in processes { process.beginTerminationAndWait() }
    }

    public func start() throws {
        _ = Self.ignoreBrokenPipe
        lock.lock()
        guard !started, !cancelled else { lock.unlock(); throw CancellationError() }
        started = true
        lock.unlock()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            finishWithoutProcess()
            throw AgentError.unavailable("找不到官方工具。请在设置中检查可执行文件路径。")
        }
        guard FileManager.default.fileExists(atPath: directory.path) else {
            finishWithoutProcess()
            throw AgentError.unavailable("工作目录不存在：\(directory.path)")
        }

        // Register readers before spawn so an immediately exiting child still
        // drains all final stdout/stderr bytes before `.exited` is published.
        readers.enter(); readers.enter()
        do {
            try spawnInOwnedProcessGroup()
        } catch {
            readers.leave(); readers.leave()
            finishWithoutProcess()
            throw error
        }
        closeChildPipeEndsInParent()
        read(output.fileHandleForReading, isError: false)
        read(errors.fileHandleForReading, isError: true)

        let pid = processID
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.waitAndFinish(pid: pid)
        }
        let deadline = DispatchWorkItem { [weak self] in self?.terminate() }
        timeoutTask = deadline
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        lock.lock(); let shouldStop = cancelled; lock.unlock()
        if shouldStop { terminate() }
    }

    /// Spawn with POSIX_SPAWN_SETPGROUP and pgroup=0. This makes the child its
    /// own process-group leader atomically, before it can create descendants.
    /// Group signals below therefore cannot target an unrelated process after a
    /// PID reuse race in the parent process.
    private func spawnInOwnedProcessGroup() throws {
        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        let actionStatus = posix_spawn_file_actions_init(&actions)
        guard actionStatus == 0 else {
            throw AgentError.processFailure("无法初始化子进程管道。")
        }
        defer { _ = posix_spawn_file_actions_destroy(&actions) }
        let attributeStatus = posix_spawnattr_init(&attributes)
        guard attributeStatus == 0 else {
            throw AgentError.processFailure("无法初始化子进程组。")
        }
        defer { _ = posix_spawnattr_destroy(&attributes) }

        let inputRead = input.fileHandleForReading.fileDescriptor
        let inputWrite = input.fileHandleForWriting.fileDescriptor
        let outputRead = output.fileHandleForReading.fileDescriptor
        let outputWrite = output.fileHandleForWriting.fileDescriptor
        let errorRead = errors.fileHandleForReading.fileDescriptor
        let errorWrite = errors.fileHandleForWriting.fileDescriptor

        func duplicate(_ source: Int32, _ target: Int32) throws {
            guard posix_spawn_file_actions_adddup2(&actions, source, target) == 0 else {
                throw AgentError.processFailure("无法连接官方工具的标准输入输出。")
            }
        }
        func closeInChild(_ descriptor: Int32) throws {
            // Keep standard descriptors open when a Pipe happened to reuse one
            // of 0, 1, or 2. Normal app launches have all three descriptors.
            guard descriptor > STDERR_FILENO else { return }
            guard posix_spawn_file_actions_addclose(&actions, descriptor) == 0 else {
                throw AgentError.processFailure("无法隔离官方工具的管道。")
            }
        }

        try duplicate(inputRead, STDIN_FILENO)
        try duplicate(outputWrite, STDOUT_FILENO)
        try duplicate(errorWrite, STDERR_FILENO)
        for descriptor in [inputRead, inputWrite, outputRead, outputWrite, errorRead, errorWrite] {
            try closeInChild(descriptor)
        }
#if canImport(Darwin)
        guard posix_spawn_file_actions_addchdir_np(&actions, directory.path) == 0 else {
            throw AgentError.unavailable("无法进入工作目录：\(directory.path)")
        }
#endif
        // Start the tool with every signal at its default action and none
        // blocked. posix_spawn otherwise inherits the spawning thread's mask,
        // and Swift concurrency / dispatch worker threads block signals such
        // as SIGCHLD: Codex then never learns that its own helper processes
        // (shell snapshot, hooks) exited, and its turn waits forever.
        var defaultSignals = sigset_t()
        var unblocked = sigset_t()
        guard sigfillset(&defaultSignals) == 0,
              sigemptyset(&unblocked) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0,
              posix_spawnattr_setsigmask(&attributes, &unblocked) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            throw AgentError.processFailure("无法设置官方工具的独立进程组。")
        }

        let argv = [executable.path] + arguments
        let environment = self.environment.keys.sorted().map { "\($0)=\(self.environment[$0] ?? "")" }
        var child: pid_t = 0
        let status = Self.withCStringArray(argv) { argumentPointers in
            Self.withCStringArray(environment) { environmentPointers in
                posix_spawn(&child, executable.path, &actions, &attributes, argumentPointers, environmentPointers)
            }
        }
        guard status == 0 else {
            throw AgentError.processFailure("无法启动官方工具（错误码 \(status)）。")
        }
        lock.lock()
        processID = child
        processGroupID = child
        lock.unlock()
    }

    private static func withCStringArray<T>(_ values: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> T) -> T {
        var pointers = values.map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers {
                if let pointer { free(pointer) }
            }
        }
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress) }
    }

    private func closeChildPipeEndsInParent() {
        // The parent writes only to stdin and reads only stdout/stderr. Keeping
        // the opposite ends open would prevent EOF when a child exits.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
    }

    private func waitAndFinish(pid: pid_t) {
        // Observe the leader's exit without reaping it. Keeping the zombie
        // unreaped pins its PID and process-group identity while descendants
        // are drained and, if necessary, terminated.
        var info = siginfo_t()
        var observed = false
        repeat {
            observed = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == 0
        } while !observed && errno == EINTR
        if !observed {
            // This should only be reached for an unusual platform waitid
            // failure. Retain the old waitpid fallback, but do not signal a
            // group after the fallback has reaped the leader.
            lock.lock()
            reaped = true
            processGroupID = 0
            terminationRequested = false
            lock.unlock()
            var fallbackStatus: Int32 = 0
            var result: pid_t = -1
            repeat { result = waitpid(pid, &fallbackStatus, 0) } while result == -1 && errno == EINTR
            finish(status: result == pid ? Self.decodeWaitStatus(fallbackStatus) : 1)
            return
        }

        // Give normal output a short opportunity to drain. A child that keeps
        // an inherited pipe open cannot hold this stream forever.
        let drained = readers.wait(timeout: .now() + 1.0) == .success
        if !drained {
            beginTerminationAndWait()
            closeReadHandles()
            _ = readers.wait(timeout: .now() + 0.5)
        } else if groupStillExists() {
            // The leader exited but a descendant may have detached its pipes.
            // Clean the owned group while the leader is still unreaped.
            beginTerminationAndWait()
        }

        let status = reapKnownLeader(pid: pid)
        finish(status: status)
    }

    private func reapKnownLeader(pid: pid_t) -> Int32 {
        // The leader is known to have exited from waitid(WNOWAIT). Reap it
        // while holding the lifecycle lock, so a pending hard-kill callback
        // cannot pass its ownership check and signal a reused process group.
        lock.lock()
        var rawStatus: Int32 = 0
        var result: pid_t = -1
        repeat {
            result = waitpid(pid, &rawStatus, WNOHANG)
            if result == 0 { result = waitpid(pid, &rawStatus, 0) }
        } while result == -1 && errno == EINTR
        reaped = true
        processGroupID = 0
        terminationRequested = false
        lock.unlock()
        return result == pid ? Self.decodeWaitStatus(rawStatus) : 1
    }

    private static func decodeWaitStatus(_ status: Int32) -> Int32 {
        // WIFEXITED/WEXITSTATUS are function-like C macros and are not
        // imported by Swift on Darwin. This is their POSIX encoding.
        let value = Int32(status)
        let signalBits = value & 0x7f
        if signalBits == 0 { return (value >> 8) & 0xff }
        if signalBits == 0x7f { return 128 + ((value >> 8) & 0xff) }
        return 128 + signalBits
    }

    private func groupStillExists() -> Bool {
        lock.lock(); let group = processGroupID; let finished = didFinish; let alreadyReaped = reaped; lock.unlock()
        guard group > 1, !finished, !alreadyReaped else { return false }
        return kill(-group, 0) == 0
    }

    private func beginTerminationAndWait() {
        guard let deadline = beginTermination() else { return }
        let remaining = deadline.timeIntervalSinceNow
        if remaining > 0 { usleep(useconds_t(min(remaining, 0.5) * 1_000_000)) }
        forceKillOwnedGroup()
    }

    private func beginTermination() -> Date? {
        lock.lock()
        guard started, !didFinish, !reaped, processGroupID > 1 else { lock.unlock(); return nil }
        let group = processGroupID
        let deadline = terminationDeadline ?? Date().addingTimeInterval(0.25)
        terminationRequested = true
        terminationDeadline = deadline
        _ = kill(-group, SIGTERM)
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow)) { [weak self] in
            self?.forceKillOwnedGroup()
        }
        return deadline
    }

    private func forceKillOwnedGroup() {
        lock.lock()
        guard started, !didFinish, !reaped, terminationRequested, processGroupID > 1 else { lock.unlock(); return }
        let group = processGroupID
        _ = kill(-group, SIGKILL)
        lock.unlock()
    }

    private func finishWithoutProcess() {
        lock.lock(); let alreadyFinished = didFinish; didFinish = true; lock.unlock()
        if !alreadyFinished { unregister(); continuation.finish() }
    }

    private func finish(status: Int32) {
        lock.lock()
        let alreadyFinished = didFinish
        didFinish = true
        timeoutTask?.cancel()
        lock.unlock()
        guard !alreadyFinished else { return }
        unregister()
        continuation.yield(.exited(status))
        continuation.finish()
    }

    private func read(_ handle: FileHandle, isError: Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { try? handle.close(); readers.leave() }
            var pending = Data()
            do {
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 10) {
                        let line = String(decoding: pending[..<newline], as: UTF8.self)
                        pending.removeSubrange(...newline)
                        continuation.yield(isError ? .stderrLine(line) : .stdoutLine(line))
                    }
                    if pending.count > Self.maxPendingLineBytes {
                        pending = Data(pending.prefix(Self.maxPendingLineBytes))
                        terminate(); break
                    }
                }
                if !pending.isEmpty {
                    let line = String(decoding: pending.prefix(Self.maxPendingLineBytes), as: UTF8.self)
                    continuation.yield(isError ? .stderrLine(line) : .stdoutLine(line))
                }
            }
        }
    }

    private static let maxPendingLineBytes = 8 * 1024 * 1024

    private func closeReadHandles() {
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
    }

    public func writeJSON(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        inputWriteLock.lock()
        defer { inputWriteLock.unlock() }
        lock.lock()
        guard !inputClosed, !cancelled else { lock.unlock(); throw CancellationError() }
        let descriptor = input.fileHandleForWriting.fileDescriptor

        // Never use FileHandle.write(contentsOf:) for an attachment-sized
        // message: it can block indefinitely when a child stops reading. The
        // descriptor is made nonblocking once and drained in bounded chunks.
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            lock.unlock()
            throw AgentError.processFailure("无法配置可取消的输入管道。")
        }
        lock.unlock()
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                if Task.isCancelled { throw CancellationError() }
                lock.lock()
                guard !cancelled, !inputClosed else { lock.unlock(); throw CancellationError() }
                let remaining = rawBuffer.count - offset
                let chunkSize = min(64 * 1024, remaining)
                let pointer = baseAddress.advanced(by: offset)
                let written = write(descriptor, pointer, chunkSize)
                let writeError = errno
                // The nonblocking syscall and descriptor close share this
                // short lock, preventing a cancelled fd from being reused
                // for an unrelated file between the check and the write.
                lock.unlock()
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0 && (writeError == EINTR) { continue }
                if written < 0 && (writeError == EAGAIN || writeError == EWOULDBLOCK) {
                    var descriptorState = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&descriptorState, 1, 25)
                    continue
                }
                lock.lock(); let wasCancelled = cancelled || inputClosed; lock.unlock()
                if wasCancelled { throw CancellationError() }
                throw AgentError.processFailure("无法向官方工具写入输入。")
            }
        }
    }

    public func finishInput() {
        lock.lock(); defer { lock.unlock() }
        if !inputClosed { inputClosed = true; try? input.fileHandleForWriting.close() }
    }

    public func terminate() {
        lock.lock()
        cancelled = true
        lock.unlock()
        finishInput()
        // Keep the leader unreaped while the bounded grace period runs. This
        // pins the process-group identity and prevents a delayed hard kill
        // from ever targeting a reused PID.
        _ = beginTermination()
    }
}

public enum RuntimeEnvironment {
    public static func subscriptionOnly() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_PROFILE", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "OPENAI_API_KEY", "OPENAI_BASE_URL", "OPENAI_ORG_ID", "OPENAI_ORGANIZATION", "CURSOR_API_KEY", "CURSOR_API_ENDPOINT", "GEMINI_API_KEY", "GOOGLE_API_KEY", "XAI_API_KEY", "CLAUDE_CONFIG_DIR", "CURSOR_CONFIG_DIR", "CLAUDECODE"] {
            environment.removeValue(forKey: key)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let additions = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        environment["PATH"] = additions.joined(separator: ":") + ":" + (environment["PATH"] ?? "")
        environment["DISABLE_AUTOUPDATER"] = "1"
        environment["NO_COLOR"] = "1"
        return environment
    }
}

public enum SafeText {
    public static func redact(_ text: String) -> String {
        var value = String(text.prefix(4000))
        for pattern in [#"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+"#, #"\b(?:sk-[A-Za-z0-9_-]+|xai-[A-Za-z0-9_-]+|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)\b"#, #"(?i)(access_token|refresh_token|api_key|authorization)([\s\"':=]+)[^\s,\"}]+"#] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                value = regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "[已隐藏凭据]")
            }
        }
        return value
    }
}

public struct CommandResult: Sendable {
    public let code: Int32
    public let stdout: String
    public let stderr: String
}

public enum CommandCapture {
    public static func run(executable: URL, arguments: [String], directory: URL, timeout: TimeInterval = 30) async throws -> CommandResult {
        let process = CLIProcess(executable: executable, arguments: arguments, directory: directory, environment: RuntimeEnvironment.subscriptionOnly(), timeout: timeout)
        try process.start(); process.finishInput()
        defer { process.terminate() }
        var out = "", err = "", exit: Int32 = -1
        for await event in process.events {
            try Task.checkCancellation()
            switch event {
            case .stdoutLine(let s): if out.utf8.count < 2_000_000 { out += s + "\n" }
            case .stderrLine(let s): if err.utf8.count < 64_000 { err += s + "\n" }
            case .exited(let code): exit = code
            }
        }
        try Task.checkCancellation()
        return CommandResult(code: exit, stdout: out, stderr: err)
    }
}
