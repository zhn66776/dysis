import Foundation

// Structured tool steps (design/HARNESS.md H3): what the model ran, read and
// changed in a turn, in place of the one-line `.status`.

/// One step as a provider reports it. Events for the same `id` update the
/// step: fields that are set replace the stored ones, and `output` is
/// appended (a delta), so a streamed command shows its output as it comes.
/// The first event of a step carries kind, title and state; later ones may
/// carry only what changed.
public struct StepEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case command, fileChange, mcp, read, search, web, other }
    public enum State: String, Codable, Sendable { case running, done, failed, declined }

    public var id: String
    public var kind: Kind?
    public var title: String?
    public var detail: String?
    public var state: State?
    /// Appended to the step's output.
    public var output: String?
    /// Replaces the step's output (a provider that sends it whole at the end).
    public var fullOutput: String?
    public var exitCode: Int?
    public var diff: String?

    public init(id: String, kind: Kind? = nil, title: String? = nil, detail: String? = nil, state: State? = nil, output: String? = nil, fullOutput: String? = nil, exitCode: Int? = nil, diff: String? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.detail = detail; self.state = state
        self.output = output; self.fullOutput = fullOutput; self.exitCode = exitCode; self.diff = diff
    }

    /// An output delta for a step already started (Codex `outputDelta`).
    public static func delta(id: String, _ text: String) -> StepEvent { StepEvent(id: id, output: text) }
}

/// A step as stored on a `ChatMessage`: output keeps its first and last
/// `StepOutput.keep` characters, and a step's diff is capped the same way;
/// a turn's full diff lives in its own file (`TurnDiffStore`).
public struct MessageStep: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: StepEvent.Kind
    public var title: String
    public var detail: String?
    public var state: StepEvent.State
    /// The first part of the output (all of it while short).
    public var output: String?
    /// The latest part of a long output, after `omitted` characters were dropped.
    public var outputTail: String?
    public var omitted: Int?
    public var exitCode: Int?
    public var diff: String?

    public init(id: String, kind: StepEvent.Kind, title: String, detail: String? = nil, state: StepEvent.State) {
        self.id = id; self.kind = kind; self.title = title; self.detail = detail; self.state = state
    }

    /// Output as shown: head, an omission note, tail.
    public var displayOutput: String? {
        guard let output else { return nil }
        guard let tail = outputTail else { return output }
        return output + "\n…（省略 \(omitted ?? 0) 个字符）…\n" + tail
    }

    mutating func append(_ text: String) {
        let keep = StepOutput.keep
        if outputTail == nil {
            let joined = (output ?? "") + text
            guard joined.count > keep * 2 else { output = joined; return }
            output = String(joined.prefix(keep))
            let rest = joined.dropFirst(keep)
            outputTail = String(rest.suffix(keep))
            omitted = rest.count - outputTail!.count
        } else {
            let joined = outputTail! + text
            outputTail = String(joined.suffix(keep))
            omitted = (omitted ?? 0) + joined.count - outputTail!.count
        }
    }

    public mutating func apply(_ event: StepEvent) {
        if let kind = event.kind { self.kind = kind }
        if let title = event.title, !title.isEmpty { self.title = title }
        if let detail = event.detail { self.detail = detail }
        if let state = event.state { self.state = state }
        if let full = event.fullOutput { output = nil; outputTail = nil; omitted = nil; append(full) }
        if let delta = event.output, !delta.isEmpty { append(delta) }
        if let code = event.exitCode { exitCode = code }
        if let diff = event.diff { self.diff = StepOutput.cap(diff) }
    }
}

public enum StepOutput {
    /// Characters kept at each end of a step's output (HARNESS.md: 4 KB).
    public static let keep = 4_096
    public static func cap(_ text: String, limit: Int = keep * 4) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\n…（diff 已截断，完整内容见本回合改动）" : text
    }
}

public extension Array where Element == MessageStep {
    /// Adds or updates the step the event belongs to. An update for an unknown step is dropped.
    mutating func apply(_ event: StepEvent) {
        if let i = firstIndex(where: { $0.id == event.id }) {
            var event = event
            // A repeated start (Claude can resend an assistant message) never reopens a finished step.
            if event.state == .running && self[i].state != .running { event.state = nil }
            self[i].apply(event)
            return
        }
        guard let kind = event.kind, let state = event.state else { return }
        var step = MessageStep(id: event.id, kind: kind, title: event.title ?? "", detail: event.detail, state: state)
        step.apply(event)
        append(step)
    }

    /// A turn that ended (or stopped) leaves no step running.
    mutating func settle(failed: Bool) {
        for i in indices where self[i].state == .running { self[i].state = failed ? .failed : .done }
    }
}

public extension DiffStat {
    /// Counts a unified diff (`git diff`, Codex `turn/diff/updated`).
    static func parse(unified diff: String) -> DiffStat {
        var stat = DiffStat(files: 0, added: 0, removed: 0)
        var inHeader = false
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") { stat.files += 1; inHeader = true; continue }
            if line.hasPrefix("@@") { inHeader = false; continue }
            if inHeader { continue }
            if line.hasPrefix("+") { stat.added += 1 } else if line.hasPrefix("-") { stat.removed += 1 }
        }
        return stat
    }
}

/// A turn's full diff, kept out of `sessions.json`:
/// `<data>/Diffs/<session>/<message>.diff`.
public struct TurnDiffStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root.appendingPathComponent("Diffs", isDirectory: true) }
    public func url(session: UUID, message: UUID) -> URL {
        root.appendingPathComponent(session.uuidString, isDirectory: true).appendingPathComponent(message.uuidString + ".diff")
    }
    public func save(_ diff: String, session: UUID, message: UUID) throws {
        let url = url(session: session, message: message)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(diff.utf8).write(to: url, options: .atomic)
    }
    public func load(session: UUID, message: UUID) -> String? {
        (try? Data(contentsOf: url(session: session, message: message))).map { String(decoding: $0, as: UTF8.self) }
    }
    public func remove(session: UUID) { try? FileManager.default.removeItem(at: root.appendingPathComponent(session.uuidString, isDirectory: true)) }
}

// MARK: Provider parsers

/// Codex app-server: `item/started` / `item/completed` for commandExecution,
/// fileChange, mcpToolCall and webSearch items, `item/commandExecution/outputDelta`
/// (and the legacy fileChange one), and `turn/diff/updated`.
public enum CodexStepParser {
    public static func events(method: String, params: [String: Any]) -> [AgentEvent] {
        switch method {
        case "item/started", "item/completed":
            guard let item = params["item"] as? [String: Any], let step = step(item, completed: method == "item/completed") else { return [] }
            return [.step(step)]
        case "item/commandExecution/outputDelta", "item/fileChange/outputDelta":
            guard let id = params["itemId"] as? String, let delta = params["delta"] as? String, !delta.isEmpty else { return [] }
            return [.step(.delta(id: id, delta))]
        case "turn/diff/updated":
            guard let diff = params["diff"] as? String else { return [] }
            return [.turnDiff(diff)]
        default:
            return []
        }
    }

    static func state(_ status: String?, completed: Bool) -> StepEvent.State {
        switch status {
        case "failed"?: return .failed
        case "declined"?: return .declined
        case "completed"?: return .done
        default: return completed ? .done : .running
        }
    }

    static func step(_ item: [String: Any], completed: Bool) -> StepEvent? {
        guard let id = item["id"] as? String else { return nil }
        let status = item["status"] as? String
        switch item["type"] as? String {
        case "commandExecution":
            let command = item["command"] as? String ?? ""
            let actions = (item["commandActions"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String }
            let kind: StepEvent.Kind = !actions.isEmpty && actions.allSatisfy({ $0 == "read" }) ? .read
                : !actions.isEmpty && actions.allSatisfy({ $0 == "search" || $0 == "listFiles" }) ? .search : .command
            var event = StepEvent(id: id, kind: kind, title: command, detail: item["cwd"] as? String, state: state(status, completed: completed))
            if completed {
                event.exitCode = (item["exitCode"] as? NSNumber)?.intValue
                if let output = item["aggregatedOutput"] as? String { event.fullOutput = output }
                if event.state == .done, let code = event.exitCode, code != 0 { event.state = .failed }
            }
            return event
        case "fileChange":
            let changes = item["changes"] as? [[String: Any]] ?? []
            let paths = changes.compactMap { $0["path"] as? String }
            let title = paths.count <= 1 ? (paths.first ?? "修改文件") : "\(paths[0]) 等 \(paths.count) 个文件"
            let diff = changes.compactMap { change -> String? in
                guard let path = change["path"] as? String, let body = change["diff"] as? String else { return nil }
                let kind = (change["kind"] as? [String: Any])?["type"] as? String ?? "update"
                return "--- \(kind) \(path)\n" + body
            }.joined(separator: "\n")
            return StepEvent(id: id, kind: .fileChange, title: title, detail: paths.count > 1 ? paths.joined(separator: "\n") : nil,
                             state: state(status, completed: completed), diff: diff.isEmpty ? nil : diff)
        case "mcpToolCall":
            let server = item["server"] as? String ?? "MCP", tool = item["tool"] as? String ?? ""
            var event = StepEvent(id: id, kind: .mcp, title: "\(server) · \(tool)", detail: arguments(item["arguments"]), state: state(status, completed: completed))
            if completed {
                if let message = (item["error"] as? [String: Any])?["message"] as? String { event.fullOutput = message; event.state = .failed }
                else if let content = (item["result"] as? [String: Any])?["content"] as? [[String: Any]] {
                    event.fullOutput = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                }
            }
            return event
        case "webSearch":
            return StepEvent(id: id, kind: .web, title: item["query"] as? String ?? "网页搜索", state: completed ? .done : .running)
        default:
            return nil
        }
    }

    static func arguments(_ value: Any?) -> String? {
        guard let value, !(value is NSNull), JSONSerialization.isValidJSONObject(value) || value is String else { return nil }
        if let string = value as? String { return string }
        return (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) }
    }
}

/// Claude Code stream-json: `tool_use` blocks in `assistant` messages start
/// steps; `tool_result` blocks in the following `user` message finish them.
public enum ClaudeStepParser {
    public static func steps(_ object: [String: Any]) -> [StepEvent] {
        guard let message = object["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] else { return [] }
        switch object["type"] as? String {
        case "assistant":
            return content.filter { $0["type"] as? String == "tool_use" }.compactMap { block in
                guard let id = block["id"] as? String, let name = block["name"] as? String else { return nil }
                return started(id: id, name: name, input: block["input"] as? [String: Any] ?? [:])
            }
        case "user":
            return content.filter { $0["type"] as? String == "tool_result" }.compactMap { block in
                guard let id = block["tool_use_id"] as? String else { return nil }
                return finished(id: id, content: block["content"], isError: block["is_error"] as? Bool == true)
            }
        default:
            return []
        }
    }

    static func started(id: String, name: String, input: [String: Any]) -> StepEvent {
        let path = input["file_path"] as? String ?? input["notebook_path"] as? String ?? input["path"] as? String
        switch name {
        case "Bash":
            return StepEvent(id: id, kind: .command, title: input["command"] as? String ?? "命令", detail: input["description"] as? String, state: .running)
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            return StepEvent(id: id, kind: .fileChange, title: path ?? name, detail: name, state: .running, diff: editDiff(name: name, path: path, input: input))
        case "Read":
            return StepEvent(id: id, kind: .read, title: path ?? "读取文件", state: .running)
        case "Grep", "Glob", "LS":
            let pattern = input["pattern"] as? String ?? path ?? ""
            return StepEvent(id: id, kind: .search, title: pattern, detail: name, state: .running)
        case "WebFetch", "WebSearch":
            return StepEvent(id: id, kind: .web, title: input["url"] as? String ?? input["query"] as? String ?? name, state: .running)
        case _ where name.hasPrefix("mcp__"):
            return StepEvent(id: id, kind: .mcp, title: MCPToolName.display(name), detail: CodexStepParser.arguments(input), state: .running)
        default:
            return StepEvent(id: id, kind: .other, title: name, detail: input["description"] as? String, state: .running)
        }
    }

    /// Before/after text an edit tool call carries, as a small diff.
    static func editDiff(name: String, path: String?, input: [String: Any]) -> String? {
        func lines(_ text: String, _ mark: String) -> String { text.split(separator: "\n", omittingEmptySubsequences: false).map { mark + $0 }.joined(separator: "\n") }
        let header = "--- \(path ?? name)\n"
        switch name {
        case "Write":
            return (input["content"] as? String).map { header + lines($0, "+") }
        case "Edit":
            guard let old = input["old_string"] as? String, let new = input["new_string"] as? String else { return nil }
            return header + lines(old, "-") + "\n" + lines(new, "+")
        case "MultiEdit":
            let edits = (input["edits"] as? [[String: Any]] ?? []).compactMap { edit -> String? in
                guard let old = edit["old_string"] as? String, let new = edit["new_string"] as? String else { return nil }
                return lines(old, "-") + "\n" + lines(new, "+")
            }
            return edits.isEmpty ? nil : header + edits.joined(separator: "\n@@\n")
        default:
            return nil
        }
    }

    static func finished(id: String, content: Any?, isError: Bool) -> StepEvent {
        let text: String
        if let string = content as? String { text = string }
        else { text = (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n") }
        // Kind and title stay from tool_use; only the outcome is new.
        var event = StepEvent(id: id, state: isError ? .failed : .done, fullOutput: text)
        if isError, let range = text.range(of: #"^Exit code (\d+)"#, options: .regularExpression) {
            event.exitCode = Int(text[range].split(separator: " ").last ?? "")
        }
        if isError, text.localizedCaseInsensitiveContains("permission") && (text.localizedCaseInsensitiveContains("denied") || text.localizedCaseInsensitiveContains("rejected")) {
            event.state = .declined
        }
        return event
    }
}

/// Cursor agent stream-json `tool_call` events (`started` / `completed`),
/// keyed by `call_id`, with the tool in `tool_call.<name>ToolCall`.
public enum CursorStepParser {
    public static func step(_ object: [String: Any]) -> StepEvent? {
        guard object["type"] as? String == "tool_call",
              let id = object["call_id"] as? String ?? object["tool_call_id"] as? String ?? object["id"] as? String,
              let call = object["tool_call"] as? [String: Any],
              let (key, body) = call.first(where: { $0.key.hasSuffix("ToolCall") }).map({ ($0.key, $0.value as? [String: Any] ?? [:]) }) else { return nil }
        let completed = object["subtype"] as? String == "completed"
        let args = body["args"] as? [String: Any] ?? [:]
        let name = String(key.dropLast("ToolCall".count))
        let path = args["path"] as? String ?? args["filePath"] as? String ?? args["file_path"] as? String
        var event: StepEvent
        switch name {
        case "shell":
            event = StepEvent(id: id, kind: .command, title: args["command"] as? String ?? "命令", detail: args["workingDirectory"] as? String, state: .running)
        case "edit", "write", "delete", "applyPatch":
            event = StepEvent(id: id, kind: .fileChange, title: path ?? name, detail: name, state: .running)
        case "read":
            event = StepEvent(id: id, kind: .read, title: path ?? "读取文件", state: .running)
        case "glob", "grep", "ls", "search", "semSearch":
            event = StepEvent(id: id, kind: .search, title: args["pattern"] as? String ?? args["globPattern"] as? String ?? args["query"] as? String ?? path ?? name, detail: name, state: .running)
        case "webSearch", "webFetch", "fetch":
            event = StepEvent(id: id, kind: .web, title: args["query"] as? String ?? args["url"] as? String ?? name, state: .running)
        case _ where name.lowercased().contains("mcp"):
            let server = args["providerIdentifier"] as? String ?? args["server"] as? String ?? "MCP"
            event = StepEvent(id: id, kind: .mcp, title: "\(server) · \(args["toolName"] as? String ?? args["name"] as? String ?? "")", state: .running)
        default:
            event = StepEvent(id: id, kind: .other, title: name, state: .running)
        }
        guard completed else { return event }
        let result = body["result"] as? [String: Any] ?? [:]
        if let success = result["success"] as? [String: Any] {
            event.state = .done
            event.exitCode = (success["exitCode"] as? NSNumber)?.intValue
            let out = [success["stdout"] as? String, success["stderr"] as? String, success["content"] as? String].compactMap { $0 }.filter { !$0.isEmpty }
            if !out.isEmpty { event.fullOutput = out.joined(separator: "\n") }
            if let diff = success["diffString"] as? String ?? success["diff"] as? String { event.diff = diff }
            if let code = event.exitCode, code != 0 { event.state = .failed }
        } else if let rejected = result["rejected"] as? [String: Any] ?? result["permissionDenied"] as? [String: Any] {
            event.state = .declined
            event.fullOutput = rejected["reason"] as? String ?? rejected["message"] as? String
        } else if let failure = result["failure"] as? [String: Any] ?? result["error"] as? [String: Any] {
            event.state = .failed
            event.exitCode = (failure["exitCode"] as? NSNumber)?.intValue
            event.fullOutput = [failure["stdout"] as? String, failure["stderr"] as? String, failure["message"] as? String, failure["error"] as? String]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        } else {
            event.state = .done
        }
        return event
    }
}
