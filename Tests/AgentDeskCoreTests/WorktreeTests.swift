import Foundation
import XCTest
@testable import AgentDeskCore

/// Per-node worktrees (HARNESS.md H2), against throwaway repositories.
final class WorktreeTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var worktrees: URL!
    private let board = UUID()

    override func setUpWithError() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("worktrees-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        // git reports real paths (/private/var/…), so compare against those.
        root = URL(fileURLWithPath: String(cString: realpath(temp.path, nil)), isDirectory: true)
        project = root.appendingPathComponent("项目 A", isDirectory: true)
        worktrees = root.appendingPathComponent("AgentDesk Worktrees", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try git("config", "user.name", "Tester")
        try git("config", "user.email", "tester@example.com")
        try write("README.md", "hello\n")
        try git("add", "-A")
        try git("commit", "-q", "-m", "init")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func git(_ args: String..., in dir: URL? = nil) throws -> String {
        try Git.run(args, in: dir ?? project).output
    }

    private func write(_ name: String, _ text: String, in dir: URL? = nil) throws {
        let url = (dir ?? project).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ name: String, in dir: URL) -> String? { try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) }

    private func make(_ node: UUID = UUID(), start: String? = nil) throws -> NodeWorktree {
        try ProjectGit.createWorktree(project: project, board: board, node: node, root: worktrees, start: start)
    }

    func testCreatesAWorktreeOnItsOwnBranchOutsideTheProject() throws {
        let node = UUID()
        let wt = try make(node)
        XCTAssertEqual(wt.branch, "agentdesk/\(NodeWorktree.shortID(board))/\(NodeWorktree.shortID(node))")
        XCTAssertEqual(wt.path, worktrees.appendingPathComponent("项目 A/\(NodeWorktree.shortID(node))").path)
        XCTAssertFalse(wt.path.hasPrefix(project.path + "/"))
        XCTAssertEqual(wt.baseBranch, "main")
        XCTAssertEqual(wt.baseCommit, try git("rev-parse", "HEAD"))
        XCTAssertEqual(wt.workingDirectory, wt.path)
        XCTAssertEqual(read("README.md", in: URL(fileURLWithPath: wt.path)), "hello\n")
        XCTAssertEqual(ProjectGit.currentBranch(URL(fileURLWithPath: wt.path)), wt.branch)
        XCTAssertEqual(ProjectGit.currentBranch(project), "main", "the project checkout is untouched")
    }

    func testAProjectInASubfolderWorksInTheSameSubfolderOfTheWorktree() throws {
        let sub = project.appendingPathComponent("app", isDirectory: true)
        try write("app/main.swift", "print(1)\n")
        try git("add", "-A"); try git("commit", "-q", "-m", "app")
        let wt = try ProjectGit.createWorktree(project: sub, board: board, node: UUID(), root: worktrees)
        XCTAssertEqual(wt.subdirectory, "app")
        XCTAssertEqual(wt.repository, project.path)
        XCTAssertEqual(read("main.swift", in: URL(fileURLWithPath: wt.workingDirectory)), "print(1)\n")
    }

    func testNotARepositoryAndInitialize() throws {
        let plain = root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try write("notes.txt", "n\n", in: plain)
        XCTAssertFalse(ProjectGit.isRepository(plain))
        XCTAssertThrowsError(try ProjectGit.createWorktree(project: plain, board: board, node: UUID(), root: worktrees))
        try ProjectGit.initialize(plain)
        XCTAssertTrue(ProjectGit.isRepository(plain))
        let wt = try ProjectGit.createWorktree(project: plain, board: board, node: UUID(), root: worktrees)
        XCTAssertEqual(read("notes.txt", in: URL(fileURLWithPath: wt.path)), "n\n", "the first commit carries the folder's files")
    }

    func testBranchIsCutFromASnapshotOfTheParentWithoutTouchingIt() throws {
        let parent = try make()
        let parentDir = URL(fileURLWithPath: parent.path)
        try write("README.md", "changed by parent\n", in: parentDir)
        try write("new.txt", "untracked\n", in: parentDir)
        let parentHead = try git("rev-parse", "HEAD", in: parentDir)

        let child = UUID()
        let ref = "refs/agentdesk/snapshots/p/\(NodeWorktree.shortID(child))"
        let snap = try ProjectGit.snapshot(parent, ref: ref)
        XCTAssertNotEqual(snap, parentHead)
        let childWT = try make(child, start: snap)
        let childDir = URL(fileURLWithPath: childWT.path)
        XCTAssertEqual(read("README.md", in: childDir), "changed by parent\n")
        XCTAssertEqual(read("new.txt", in: childDir), "untracked\n", "untracked files are in the snapshot")
        XCTAssertEqual(childWT.baseCommit, snap)
        // The parent keeps its branch, HEAD, index and uncommitted files.
        XCTAssertEqual(try git("rev-parse", "HEAD", in: parentDir), parentHead)
        XCTAssertEqual(Set(try ProjectGit.changedFiles(parent)), ["README.md", "new.txt"])
        XCTAssertEqual(try git("diff", "--cached", "--name-only", in: parentDir), "")
        XCTAssertEqual(try git("rev-parse", ref), snap)
        // A clean parent snapshots to its HEAD.
        let clean = try make()
        XCTAssertEqual(try ProjectGit.snapshot(clean, ref: "refs/agentdesk/snapshots/c/x"), clean.baseCommit)
    }

    func testMergeToBaseUsesNoFastForwardAndNeverTouchesConflicts() throws {
        let a = try make(), b = try make()
        try write("a.txt", "from a\n", in: URL(fileURLWithPath: a.path))
        XCTAssertEqual(try ProjectGit.mergeToBase(a, title: "节点 A"), .merged(commit: try git("rev-parse", "HEAD")))
        XCTAssertEqual(read("a.txt", in: project), "from a\n")
        XCTAssertEqual(try git("rev-list", "--count", "--merges", "HEAD"), "1", "a merge commit, not a fast-forward")
        XCTAssertEqual(try ProjectGit.mergeToBase(a, title: "节点 A"), .upToDate)
        XCTAssertTrue(ProjectGit.isMergedAndClean(a))
        XCTAssertTrue(ProjectGit.isMergedAndClean(b), "an untouched node has nothing to lose")

        // Conflict: both edit README.
        try write("README.md", "b says\n", in: URL(fileURLWithPath: b.path))
        try write("README.md", "main says\n"); try git("commit", "-qam", "main edit")
        let before = try git("rev-parse", "HEAD")
        XCTAssertThrowsError(try ProjectGit.mergeToBase(b, title: "节点 B")) { error in
            XCTAssertEqual(error as? WorktreeError, .conflicts(["README.md"]))
        }
        XCTAssertEqual(try git("rev-parse", "HEAD"), before, "merge aborted")
        XCTAssertEqual(try git("status", "--porcelain"), "", "project left clean")
        XCTAssertEqual(read("README.md", in: project), "main says\n")
    }

    func testMergeToBaseRefusesADirtyProjectOrAnotherBranch() throws {
        let a = try make()
        try write("a.txt", "a\n", in: URL(fileURLWithPath: a.path))
        try write("README.md", "uncommitted\n")
        XCTAssertThrowsError(try ProjectGit.mergeToBase(a, title: "A")) { XCTAssertEqual($0 as? WorktreeError, .projectNotClean(["README.md"])) }
        try git("checkout", "-q", "--", "README.md")
        try git("checkout", "-q", "-b", "other")
        XCTAssertThrowsError(try ProjectGit.mergeToBase(a, title: "A")) { XCTAssertEqual($0 as? WorktreeError, .wrongBranch(current: "other", base: "main")) }
    }

    func testCombineLeavesConflictsForTheMergeNode() throws {
        let a = try make(), b = try make(), c = try make()
        try write("README.md", "a\n", in: URL(fileURLWithPath: a.path))
        try write("README.md", "b\n", in: URL(fileURLWithPath: b.path))
        try write("c.txt", "c\n", in: URL(fileURLWithPath: c.path))
        let target = try make()
        let outcome = try ProjectGit.combine([.init(title: "A", worktree: a), .init(title: "B", worktree: b), .init(title: "C", worktree: c)], into: target)
        XCTAssertEqual(outcome, .conflicts(title: "B", files: ["README.md"], remaining: ["C"]))
        let dir = URL(fileURLWithPath: target.path)
        XCTAssertTrue(read("README.md", in: dir)?.contains("<<<<<<<") ?? false, "markers stay for the agent")
        // Still conflicted: nothing more is merged.
        XCTAssertThrowsError(try ProjectGit.combine([.init(title: "C", worktree: c)], into: target))
        // The agent resolves; the next combine concludes the merge and goes on.
        try write("README.md", "a and b\n", in: dir)
        XCTAssertEqual(try ProjectGit.combine([.init(title: "C", worktree: c)], into: target), .merged(["C"]))
        XCTAssertEqual(read("c.txt", in: dir), "c\n")
        XCTAssertEqual(try git("status", "--porcelain", in: dir), "")
    }

    func testRemoveKeepsTheBranchAndASnapshotOfUncommittedWork() throws {
        let a = try make()
        try write("wip.txt", "wip\n", in: URL(fileURLWithPath: a.path))
        let kept = try XCTUnwrap(try ProjectGit.remove(a))
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(ProjectGit.branchExists(a.branch, in: project))
        XCTAssertEqual(try git("show", "\(kept):wip.txt"), "wip")
        // Recreated on demand from the branch.
        try ProjectGit.ensure(a)
        XCTAssertTrue(a.exists)
        XCTAssertNil(try ProjectGit.remove(a, deleteBranch: true))
        XCTAssertFalse(ProjectGit.branchExists(a.branch, in: project))
        XCTAssertThrowsError(try ProjectGit.ensure(a)) { XCTAssertEqual($0 as? WorktreeError, .missingBranch(a.branch)) }
    }

    func testDiffStatAndSummaryCoverUntrackedFilesAndSkipCursorFiles() throws {
        let a = try make()
        let dir = URL(fileURLWithPath: a.path)
        try write("README.md", "hello\nworld\n", in: dir)
        try write("src/new.swift", "let x = 1\nlet y = 2\n", in: dir)
        // Files AgentDesk wrote for Cursor are not the node's work.
        try write(".cursor/mcp.json", "{}", in: dir)
        try write(".cursor/.agentdesk-managed", #"["mcp.json"]"#, in: dir)
        XCTAssertEqual(try ProjectGit.diffStat(a), DiffStat(files: 2, added: 3, removed: 0))
        XCTAssertEqual(DiffStat(files: 2, added: 3, removed: 0).label, "改了 2 个文件 +3 −0")
        let summary = try XCTUnwrap(try ProjectGit.diffSummary(a))
        XCTAssertTrue(summary.contains("src/new.swift"))
        XCTAssertFalse(summary.contains("mcp.json"))
        XCTAssertNil(try ProjectGit.diffSummary(try make()))
        try ProjectGit.commitPending(a, message: "work")
        XCTAssertEqual(try git("show", "--name-only", "--format=", "HEAD", in: dir), "README.md\nsrc/new.swift")
        XCTAssertGreaterThan(ProjectGit.diskUsage(worktrees), 0)
    }

    func testDiffStatParsesNumstat() {
        XCTAssertEqual(DiffStat.parse(numstat: "3\t1\ta.txt\n-\t-\timg.png\n10\t0\tdir/b.swift\n"), DiffStat(files: 3, added: 13, removed: 1))
        XCTAssertTrue(DiffStat.parse(numstat: "").isEmpty)
    }

    // MARK: Write access

    func testWriteAccessPerWorktreeMergeNodeAndSharedFolder() {
        let p = "/p/x"
        let s1 = ChatSession(provider: .codex, modelID: "", workingDirectory: "/wt/1")
        let s2 = ChatSession(provider: .claude, modelID: "m", workingDirectory: p)
        let s3 = ChatSession(provider: .claude, modelID: "m", workingDirectory: p)
        let s4 = ChatSession(provider: .claude, modelID: "m", workingDirectory: p)
        var n1 = CanvasNode(sessionID: s1.id, position: .init(x: 0, y: 0))
        n1.worktree = NodeWorktree(repository: p, path: "/wt/1", branch: "agentdesk/a/b", baseBranch: "main", baseCommit: "c")
        let n2 = CanvasNode(sessionID: s2.id, position: .init(x: 0, y: 0))
        let n3 = CanvasNode(sessionID: s3.id, position: .init(x: 0, y: 0))
        let n4 = CanvasNode(sessionID: s4.id, position: .init(x: 0, y: 0), merge: .compare)
        var board = CanvasBoard(title: "b", project: CanvasProject(path: p, trusted: true), nodes: [n1, n2, n3, n4])
        let sessions = Dictionary(uniqueKeysWithValues: [s1, s2, s3, s4].map { ($0.id, $0) })
        XCTAssertTrue(CanvasWriteAccess.decide(board: board, nodeID: n1.id, sessions: sessions, writers: [s2.id]).writable)
        XCTAssertTrue(CanvasWriteAccess.decide(board: board, nodeID: n2.id, sessions: sessions, writers: []).writable)
        let blocked = CanvasWriteAccess.decide(board: board, nodeID: n3.id, sessions: sessions, writers: [s2.id])
        XCTAssertFalse(blocked.writable)
        XCTAssertNotNil(blocked.reason)
        XCTAssertFalse(CanvasWriteAccess.decide(board: board, nodeID: n4.id, sessions: sessions, writers: []).writable)
        board.project?.trusted = false
        XCTAssertFalse(CanvasWriteAccess.decide(board: board, nodeID: n1.id, sessions: sessions, writers: []).writable)
    }

    func testDataEdgeCarriesTheDiffSummaryOnlyWhenAsked() throws {
        let a = ChatSession(provider: .codex, modelID: "", workingDirectory: "/a", messages: [ChatMessage(role: .user, text: "q"), ChatMessage(role: .assistant, text: "改好了")])
        let b = ChatSession(provider: .codex, modelID: "", workingDirectory: "/b")
        let na = CanvasNode(sessionID: a.id, position: .init(x: 0, y: 0)), nb = CanvasNode(sessionID: b.id, position: .init(x: 300, y: 0))
        var board = CanvasBoard(title: "b", nodes: [na, nb])
        let edge = try board.connect(source: na.id, target: nb.id)
        let sessions = [a.id: a, b.id: b]
        let diffs = [edge.id: "README.md | 2 +-"]
        XCTAssertNil(CanvasContextBuilder.context(board: board, nodeID: nb.id, sessions: sessions, diffs: diffs).upstream.first?.diff)
        board.edges[0].includeDiff = true
        let context = CanvasContextBuilder.context(board: board, nodeID: nb.id, sessions: sessions, diffs: diffs)
        XCTAssertEqual(context.upstream.first?.diff, "README.md | 2 +-")
        XCTAssertTrue(CanvasContextBuilder.compose(userText: "看看", context: context).contains("[上游分支的改动摘要]\nREADME.md | 2 +-"))
    }

    func testOlderBoardsDecodeWithoutWorktreeFields() throws {
        let old = #"{"id":"7C1A0C4E-55B0-4B8B-9B7B-5E2C1F0A9D11","sessionID":"7C1A0C4E-55B0-4B8B-9B7B-5E2C1F0A9D12","position":{"x":1,"y":2}}"#
        XCTAssertNil(try JSONDecoder().decode(CanvasNode.self, from: Data(old.utf8)).worktree)
        var node = CanvasNode(sessionID: UUID(), position: .init(x: 0, y: 0))
        node.worktree = NodeWorktree(repository: "/r", path: "/w", subdirectory: "s", branch: "agentdesk/a/b", baseBranch: nil, baseCommit: "abc")
        XCTAssertEqual(try JSONDecoder().decode(CanvasNode.self, from: JSONEncoder().encode(node)), node)
        XCTAssertEqual(node.worktree?.workingDirectory, "/w/s")
    }
}
