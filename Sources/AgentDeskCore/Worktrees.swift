import Foundation

// Per-node git worktrees (design/HARNESS.md H2). AgentDesk runs git itself so
// the three CLIs behave the same; models never create, merge or push branches.

/// A git worktree AgentDesk made for one writing node.
public struct NodeWorktree: Codable, Equatable, Sendable {
    /// The repository's main checkout (its top level).
    public var repository: String
    /// The worktree folder.
    public var path: String
    /// The project folder relative to the repository top level; "" when the
    /// project is the top level. The session works in the same place inside
    /// the worktree.
    public var subdirectory: String
    public var branch: String
    /// Branch the project was on when the node was cut; "合并到" targets it.
    public var baseBranch: String?
    /// Commit the branch was cut from: the project HEAD, or a parent snapshot.
    public var baseCommit: String
    public init(repository: String, path: String, subdirectory: String = "", branch: String, baseBranch: String?, baseCommit: String) {
        self.repository = repository; self.path = path; self.subdirectory = subdirectory
        self.branch = branch; self.baseBranch = baseBranch; self.baseCommit = baseCommit
    }

    public var workingDirectory: String { subdirectory.isEmpty ? path : (path as NSString).appendingPathComponent(subdirectory) }
    public var exists: Bool { FileManager.default.fileExists(atPath: path) }

    /// `~/AgentDesk Worktrees`, outside every project so no CLI scans it as project files.
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AgentDesk Worktrees", isDirectory: true)
    }

    public static func shortID(_ id: UUID) -> String { String(id.uuidString.lowercased().prefix(8)) }
    public static func branchName(board: UUID, node: UUID) -> String { "agentdesk/\(shortID(board))/\(shortID(node))" }
    public static func location(root: URL, projectName: String, node: UUID) -> URL {
        let name = projectName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return root.appendingPathComponent(name.isEmpty || name.hasPrefix(".") ? "project" : name, isDirectory: true)
            .appendingPathComponent(shortID(node), isDirectory: true)
    }
}

/// Files changed and lines added/removed, as `git diff --numstat` counts them.
public struct DiffStat: Codable, Equatable, Sendable {
    public var files: Int
    public var added: Int
    public var removed: Int
    public init(files: Int, added: Int, removed: Int) { self.files = files; self.added = added; self.removed = removed }
    public var isEmpty: Bool { files == 0 }
    /// "改了 N 个文件 +a −b".
    public var label: String { "改了 \(files) 个文件 +\(added) −\(removed)" }

    /// Parses `git diff --numstat` output; binary files count as files only.
    public static func parse(numstat: String) -> DiffStat {
        var stat = DiffStat(files: 0, added: 0, removed: 0)
        for line in numstat.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3 else { continue }
            stat.files += 1
            stat.added += Int(parts[0]) ?? 0
            stat.removed += Int(parts[1]) ?? 0
        }
        return stat
    }
}

public enum WorktreeError: LocalizedError, Equatable {
    case notRepository(String)
    case noCommits
    case git(String)
    case projectNotClean([String])
    case wrongBranch(current: String?, base: String)
    case conflicts([String])
    case missingBranch(String)

    public var errorDescription: String? {
        switch self {
        case .notRepository(let path): return "\(path) 不是 git 仓库。"
        case .noCommits: return "仓库还没有任何提交，无法创建 worktree。"
        case .git(let message): return "git 操作失败：\(message)"
        case .projectNotClean(let files):
            return "项目目录有未提交的改动，先提交或清理后再合并：\(Self.list(files))"
        case .wrongBranch(let current, let base):
            return "项目当前在 \(current ?? "游离的 HEAD") 上，不是 \(base)。请先在项目里切换到 \(base) 再合并。"
        case .conflicts(let files):
            return "合并有冲突，已放弃这次合并，项目没有改动。冲突文件：\(Self.list(files))。可以新建一个合流节点，让它在自己的 worktree 里解决冲突。"
        case .missingBranch(let branch): return "分支 \(branch) 已不存在，无法恢复这个节点的 worktree。"
        }
    }

    static func list(_ files: [String]) -> String {
        files.count > 8 ? files.prefix(8).joined(separator: "、") + " 等 \(files.count) 个" : files.joined(separator: "、")
    }
}

public struct GitResult: Sendable {
    public var code: Int32
    public var stdout: String
    public var stderr: String
    public var output: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Runs git synchronously; callers on the main actor go through a detached task.
public enum Git {
    public static var executable = URL(fileURLWithPath: "/usr/bin/git")

    /// Name and address for commits nobody sees on a branch: snapshots and checkpoints.
    static let internalIdentity = ["GIT_AUTHOR_NAME": "AgentDesk", "GIT_AUTHOR_EMAIL": "agentdesk@localhost",
                                   "GIT_COMMITTER_NAME": "AgentDesk", "GIT_COMMITTER_EMAIL": "agentdesk@localhost"]

    @discardableResult
    public static func run(_ arguments: [String], in directory: URL, environment extra: [String: String] = [:], check: Bool = true) throws -> GitResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-c", "core.quotepath=false", "-c", "color.ui=false"] + arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX", "GIT_COMMON_DIR"] { environment.removeValue(forKey: key) }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_EDITOR"] = "true"
        environment["LC_ALL"] = "C"
        environment.merge(extra) { $1 }
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw WorktreeError.git("无法启动 git：\(error.localizedDescription)") }
        // Read both pipes while git runs so a large diff cannot fill one and stall it.
        var stdoutData = Data()
        let reader = DispatchQueue(label: "agentdesk.git.stdout")
        let group = DispatchGroup()
        group.enter()
        reader.async { stdoutData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let stderrData = err.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        let result = GitResult(code: process.terminationStatus, stdout: String(decoding: stdoutData, as: UTF8.self), stderr: String(decoding: stderrData, as: UTF8.self))
        if check && result.code != 0 {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorktreeError.git(SafeText.redact(message.isEmpty ? "git \(arguments.first ?? "") 退出码 \(result.code)" : message))
        }
        return result
    }
}

public enum ProjectGit {
    // MARK: Repository

    /// The repository top level and the folder's path inside it, or nil when
    /// the folder is not in a git work tree.
    public static func repository(of folder: URL) -> (top: URL, prefix: String)? {
        guard let result = try? Git.run(["rev-parse", "--show-toplevel", "--show-prefix"], in: folder, check: false), result.code == 0 else { return nil }
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let top = lines.first, !top.isEmpty else { return nil }
        var prefix = lines.count > 1 ? lines[1] : ""
        while prefix.hasSuffix("/") { prefix.removeLast() }
        return (URL(fileURLWithPath: top, isDirectory: true), prefix)
    }

    public static func isRepository(_ folder: URL) -> Bool { repository(of: folder) != nil }

    /// `git init` plus a first commit of what the folder already holds, so
    /// worktrees start with the project's files.
    public static func initialize(_ folder: URL) throws {
        try Git.run(["init"], in: folder)
        try Git.run(["add", "-A"], in: folder)
        try Git.run(["commit", "--allow-empty", "-q", "-m", "初始提交（AgentDesk）"], in: folder, environment: identity(in: folder))
    }

    public static func head(_ directory: URL) throws -> String {
        let result = try Git.run(["rev-parse", "--verify", "-q", "HEAD"], in: directory, check: false)
        guard result.code == 0, !result.output.isEmpty else { throw WorktreeError.noCommits }
        return result.output
    }

    public static func currentBranch(_ directory: URL) -> String? {
        guard let result = try? Git.run(["symbolic-ref", "--short", "-q", "HEAD"], in: directory, check: false), result.code == 0 else { return nil }
        return result.output.isEmpty ? nil : result.output
    }

    public static func branchExists(_ branch: String, in directory: URL) -> Bool {
        (try? Git.run(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: directory, check: false))?.code == 0
    }

    /// The user's own name for commits they will see on a branch, or
    /// AgentDesk's when git has none configured.
    static func identity(in directory: URL) -> [String: String] {
        let email = (try? Git.run(["config", "user.email"], in: directory, check: false))?.output ?? ""
        let name = (try? Git.run(["config", "user.name"], in: directory, check: false))?.output ?? ""
        return email.isEmpty || name.isEmpty ? Git.internalIdentity : [:]
    }

    // MARK: Worktrees

    /// A new worktree for `node` on branch `agentdesk/<board>/<node>`, cut from
    /// `start` (default: the project's HEAD).
    public static func createWorktree(project: URL, board: UUID, node: UUID, root: URL = NodeWorktree.defaultRoot, start: String? = nil) throws -> NodeWorktree {
        guard let repo = repository(of: project) else { throw WorktreeError.notRepository(project.path) }
        let startCommit = try start ?? head(repo.top)
        let branch = NodeWorktree.branchName(board: board, node: node)
        let path = NodeWorktree.location(root: root, projectName: project.lastPathComponent, node: node)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Git.run(["worktree", "add", "-q", "-b", branch, path.path, startCommit], in: repo.top)
        return NodeWorktree(repository: repo.top.path, path: path.path, subdirectory: repo.prefix, branch: branch,
                            baseBranch: currentBranch(repo.top), baseCommit: startCommit)
    }

    /// Recreates a worktree that was cleaned up, from its branch.
    public static func ensure(_ worktree: NodeWorktree) throws {
        guard !worktree.exists else { return }
        let repo = URL(fileURLWithPath: worktree.repository, isDirectory: true)
        try Git.run(["worktree", "prune"], in: repo)
        guard branchExists(worktree.branch, in: repo) else { throw WorktreeError.missingBranch(worktree.branch) }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: worktree.path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Git.run(["worktree", "add", "-q", worktree.path, worktree.branch], in: repo)
    }

    /// Paths AgentDesk wrote into the working directory for Cursor
    /// (`.cursor/.agentdesk-managed`), kept out of snapshots and commits.
    static func managedExcludes(_ worktree: NodeWorktree) -> [String] {
        let cursor = (worktree.subdirectory.isEmpty ? "" : worktree.subdirectory + "/") + ".cursor/"
        let marker = URL(fileURLWithPath: worktree.workingDirectory).appendingPathComponent(".cursor/.agentdesk-managed")
        guard let names = (try? Data(contentsOf: marker)).flatMap({ try? JSONDecoder().decode([String].self, from: $0) }) else { return [] }
        return (names + [".agentdesk-managed"]).map { ":(exclude)\(cursor)\($0)" }
    }

    /// Tree of everything in the worktree now, untracked files included
    /// (minus ignored and AgentDesk-managed ones), built in a private index so
    /// neither the worktree nor its index changes.
    static func workingTree(_ worktree: NodeWorktree) throws -> String {
        let top = URL(fileURLWithPath: worktree.path, isDirectory: true)
        let index = FileManager.default.temporaryDirectory.appendingPathComponent("agentdesk-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        let env = ["GIT_INDEX_FILE": index.path]
        try Git.run(["read-tree", "HEAD"], in: top, environment: env)
        try Git.run(["add", "-A", "--", "."] + managedExcludes(worktree), in: top, environment: env)
        return try Git.run(["write-tree"], in: top, environment: env).output
    }

    /// A commit of the worktree's current state on top of its HEAD, kept
    /// alive by `ref` (for example `refs/agentdesk/snapshots/<node>/<child>`).
    /// The worktree's branch, index and files are not touched. A clean
    /// worktree gives its HEAD.
    @discardableResult
    public static func snapshot(_ worktree: NodeWorktree, ref: String, message: String = "AgentDesk 快照") throws -> String {
        let top = URL(fileURLWithPath: worktree.path, isDirectory: true)
        let head = try head(top)
        let tree = try workingTree(worktree)
        let headTree = try Git.run(["rev-parse", "HEAD^{tree}"], in: top).output
        let commit = tree == headTree ? head : try Git.run(["commit-tree", tree, "-p", head, "-m", message], in: top, environment: Git.internalIdentity).output
        try Git.run(["update-ref", ref, commit], in: top)
        return commit
    }

    /// Changed paths in the worktree (tracked and untracked).
    public static func changedFiles(_ worktree: NodeWorktree) throws -> [String] {
        let top = URL(fileURLWithPath: worktree.path, isDirectory: true)
        return try Git.run(["status", "--porcelain", "--untracked-files=all", "--", "."] + managedExcludes(worktree), in: top).stdout
            .split(separator: "\n").map { String($0.dropFirst(3)) }
    }

    /// Commits whatever the node changed onto its own branch. Returns false
    /// when there was nothing to commit. A merge the node was resolving is
    /// concluded by this commit once no file is left in conflict.
    @discardableResult
    public static func commitPending(_ worktree: NodeWorktree, message: String) throws -> Bool {
        let top = URL(fileURLWithPath: worktree.path, isDirectory: true)
        // A conflicted file counts as resolved once its markers are gone.
        let unresolved = try unmergedFiles(top).filter { file in
            let text = (try? String(contentsOf: top.appendingPathComponent(file), encoding: .utf8)) ?? ""
            return text.split(separator: "\n").contains { $0.hasPrefix("<<<<<<< ") || $0.hasPrefix(">>>>>>> ") }
        }
        guard unresolved.isEmpty else { throw WorktreeError.conflicts(unresolved) }
        try Git.run(["add", "-A", "--", "."] + managedExcludes(worktree), in: top)
        let merging = (try? Git.run(["rev-parse", "-q", "--verify", "MERGE_HEAD"], in: top, check: false))?.code == 0
        let staged = try Git.run(["diff", "--cached", "--quiet"], in: top, check: false).code != 0
        guard staged || merging else { return false }
        try Git.run(["commit", "-q", "--no-verify", "-m", message], in: top, environment: identity(in: top))
        return true
    }

    static func unmergedFiles(_ directory: URL) throws -> [String] {
        try Git.run(["diff", "--name-only", "--diff-filter=U"], in: directory).stdout.split(separator: "\n").map(String.init)
    }

    public enum MergeOutcome: Equatable, Sendable { case merged(commit: String), upToDate }

    /// "合并到 <base>": commits the node's pending work on its branch, then
    /// `git merge --no-ff` into the project's checkout, which must be clean and
    /// on the base branch. Conflicts are reported and the merge aborted; the
    /// project is never left half merged and nothing is pushed.
    public static func mergeToBase(_ worktree: NodeWorktree, title: String) throws -> MergeOutcome {
        let repo = URL(fileURLWithPath: worktree.repository, isDirectory: true)
        guard let base = worktree.baseBranch else { throw WorktreeError.wrongBranch(current: currentBranch(repo), base: "原来的分支") }
        if worktree.exists { try commitPending(worktree, message: "AgentDesk：\(title)") }
        let current = currentBranch(repo)
        guard current == base else { throw WorktreeError.wrongBranch(current: current, base: base) }
        let dirty = try Git.run(["status", "--porcelain", "--untracked-files=no"], in: repo).stdout.split(separator: "\n").map { String($0.dropFirst(3)) }
        guard dirty.isEmpty else { throw WorktreeError.projectNotClean(dirty) }
        if try Git.run(["merge-base", "--is-ancestor", worktree.branch, "HEAD"], in: repo, check: false).code == 0 { return .upToDate }
        let result = try Git.run(["merge", "--no-ff", "--no-edit", "-m", "合并 AgentDesk 节点「\(title)」（\(worktree.branch)）", worktree.branch],
                                 in: repo, environment: identity(in: repo), check: false)
        guard result.code == 0 else {
            let unmerged = try unmergedFiles(repo)
            _ = try? Git.run(["merge", "--abort"], in: repo, check: false)
            if unmerged.isEmpty { throw WorktreeError.git(SafeText.redact((result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines))) }
            throw WorktreeError.conflicts(unmerged)
        }
        return .merged(commit: try head(repo))
    }

    public struct Upstream: Sendable {
        public var title: String
        public var worktree: NodeWorktree
        public init(title: String, worktree: NodeWorktree) { self.title = title; self.worktree = worktree }
    }

    public enum CombineOutcome: Equatable, Sendable {
        case merged([String])
        /// Stopped at `title` with conflict markers left in `files` for the
        /// merge node's agent; `remaining` were not merged yet.
        case conflicts(title: String, files: [String], remaining: [String])
    }

    /// A merge node's "把这几个分支的改动合起来": each upstream's pending work is
    /// committed on its own branch, then merged into `target` one by one.
    /// Unlike `mergeToBase`, a conflict is left in place for the agent.
    public static func combine(_ upstream: [Upstream], into target: NodeWorktree) throws -> CombineOutcome {
        let top = URL(fileURLWithPath: target.path, isDirectory: true)
        // A merge the agent finished resolving is concluded first.
        try commitPending(target, message: "AgentDesk：完成合流")
        var merged: [String] = []
        for (i, item) in upstream.enumerated() {
            if item.worktree.exists { try commitPending(item.worktree, message: "AgentDesk：\(item.title)") }
            let result = try Git.run(["merge", "--no-ff", "--no-edit", "-m", "合流「\(item.title)」（\(item.worktree.branch)）", item.worktree.branch],
                                     in: top, environment: identity(in: top), check: false)
            if result.code != 0 {
                let unmerged = try unmergedFiles(top)
                guard !unmerged.isEmpty else { throw WorktreeError.git(SafeText.redact(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))) }
                return .conflicts(title: item.title, files: unmerged, remaining: upstream.dropFirst(i + 1).map(\.title))
            }
            merged.append(item.title)
        }
        return .merged(merged)
    }

    /// Removes the worktree. Uncommitted changes are first kept as a snapshot
    /// under `refs/agentdesk/snapshots/<node>/removed-…`, so nothing is lost;
    /// the branch stays unless `deleteBranch`. Returns the snapshot ref, if any.
    @discardableResult
    public static func remove(_ worktree: NodeWorktree, deleteBranch: Bool = false) throws -> String? {
        let repo = URL(fileURLWithPath: worktree.repository, isDirectory: true)
        var kept: String?
        if worktree.exists, !(try changedFiles(worktree)).isEmpty {
            let node = worktree.branch.split(separator: "/").last.map(String.init) ?? "node"
            let ref = "refs/agentdesk/snapshots/\(node)/removed-\(Int(Date().timeIntervalSince1970))"
            try snapshot(worktree, ref: ref, message: "AgentDesk：删除节点前未提交的改动")
            kept = ref
        }
        if worktree.exists { try Git.run(["worktree", "remove", "--force", worktree.path], in: repo) }
        try Git.run(["worktree", "prune"], in: repo)
        if deleteBranch, branchExists(worktree.branch, in: repo) { try Git.run(["branch", "-D", "-q", worktree.branch], in: repo) }
        return kept
    }

    /// The branch is contained in the base branch and the worktree has nothing uncommitted.
    public static func isMergedAndClean(_ worktree: NodeWorktree) -> Bool {
        let repo = URL(fileURLWithPath: worktree.repository, isDirectory: true)
        guard let base = worktree.baseBranch, branchExists(worktree.branch, in: repo),
              (try? Git.run(["merge-base", "--is-ancestor", worktree.branch, base], in: repo, check: false))?.code == 0 else { return false }
        guard worktree.exists else { return true }
        return (try? changedFiles(worktree))?.isEmpty ?? false
    }

    // MARK: Diffs

    /// Everything the node changed since it was cut, committed or not.
    public static func diffStat(_ worktree: NodeWorktree, since base: String? = nil) throws -> DiffStat {
        let top = URL(fileURLWithPath: worktree.path, isDirectory: true)
        let tree = try workingTree(worktree)
        return DiffStat.parse(numstat: try Git.run(["diff", "--numstat", base ?? worktree.baseCommit, tree], in: top).stdout)
    }

    public static func diff(_ worktree: NodeWorktree, since base: String? = nil) throws -> String {
        let top = URL(fileURLWithPath: worktree.path, isDirectory: true)
        let tree = try workingTree(worktree)
        return try Git.run(["diff", base ?? worktree.baseCommit, tree], in: top).stdout
    }

    /// `git diff --stat` plus a truncated patch, for a data edge into another node.
    public static func diffSummary(_ worktree: NodeWorktree, maxPatchCharacters: Int = 6_000) throws -> String? {
        let top = URL(fileURLWithPath: worktree.path, isDirectory: true)
        let tree = try workingTree(worktree)
        let stat = try Git.run(["diff", "--stat", worktree.baseCommit, tree], in: top).output
        guard !stat.isEmpty else { return nil }
        var patch = try Git.run(["diff", worktree.baseCommit, tree], in: top).stdout
        if patch.count > maxPatchCharacters { patch = String(patch.prefix(maxPatchCharacters)) + "\n[patch 已截断]" }
        return "分支 \(worktree.branch) 相对基点 \(worktree.baseCommit.prefix(8)) 的改动：\n\(stat)\n\n\(patch)"
    }

    // MARK: Disk

    /// Bytes allocated under `root` (all worktrees AgentDesk made).
    public static func diskUsage(_ root: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
