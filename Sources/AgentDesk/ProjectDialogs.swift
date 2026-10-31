import AppKit
import AgentDeskCore

/// Native dialogs for project boards, shown as sheets on the front window.
@MainActor
enum ProjectDialogs {
    enum NewBoard { case plain, newFolder(String), existing(URL) }

    /// How a new board starts; nil when cancelled.
    static func newBoard() async -> NewBoard? {
        let alert = NSAlert()
        alert.messageText = "新建画布"
        alert.informativeText = "项目画布对应你电脑上的一个文件夹，画布里的对话都在这个文件夹里工作。新文件夹建在 \(abbreviated(CanvasProject.defaultRoot.path)) 里。"
        let field = NSTextField(string: "新项目")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.placeholderString = "项目名"
        alert.accessoryView = field
        alert.addButton(withTitle: "新建项目文件夹")
        alert.addButton(withTitle: "打开已有文件夹…")
        alert.addButton(withTitle: "只建画布")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        switch await present(alert) {
        case .alertFirstButtonReturn: return .newFolder(field.stringValue)
        case .alertSecondButtonReturn: return chooseFolder().map(NewBoard.existing)
        case .alertThirdButtonReturn: return .plain
        default: return nil
        }
    }

    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择项目文件夹"
        panel.prompt = "打开"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Asked once per project, before its first conversation.
    static func askTrust(_ project: CanvasProject) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "信任「\(project.name)」这个文件夹吗？"
        alert.informativeText = """
        \(abbreviated(project.path))

        信任后，这个画布里的对话（Claude Code、Codex、Cursor）都在这个文件夹里工作，默认是「询问」档：读文件不问；运行命令、联网和改文件前会先在面板里问你（Claude Code 在项目里改文件不问；Cursor 不能逐条确认，这一档不能运行命令）。只信任你自己的项目。

        以后可以在侧栏里改成「只读」或「自动」（自动：改文件、运行命令、联网都不再询问）。不信任时只能聊天。
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "信任这个文件夹")
        alert.addButton(withTitle: "只聊天")
        return await present(alert) == .alertFirstButtonReturn
    }

    /// Asked once per trusted folder that is not a git repository.
    static func askGitInit(_ project: CanvasProject, root: URL) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "初始化 git 以并行工作？"
        alert.informativeText = """
        「\(project.name)」还不是 git 仓库。

        初始化后，每个节点在自己的 worktree（\(abbreviated(root.path)) 里）和分支上改代码，互不干扰；改好后用节点菜单“合并到”回主线。AgentDesk 会运行 git init，并把文件夹里现有的文件做一次初始提交。

        不初始化的话，所有节点共用这个文件夹，同一时间只有一个节点能写入，其他节点这一轮只读。以后可以在侧栏里再初始化。
        """
        alert.addButton(withTitle: "初始化 git")
        alert.addButton(withTitle: "暂不")
        return await present(alert) == .alertFirstButtonReturn
    }

    private static func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    static func abbreviated(_ path: String) -> String { NSString(string: path).abbreviatingWithTildeInPath }
}
