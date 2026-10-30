import AppKit
import SwiftUI
import AgentDeskCore

/// A project board's settings: its rules (`AGENTS.md`, edited in place),
/// how Claude Code reaches them, and the commands always allowed there.
struct ProjectSettingsView: View {
    @ObservedObject var model: AppModel
    let project: CanvasProject
    let onDone: () -> Void

    @State private var rules = ProjectRules(folder: URL(fileURLWithPath: "/"), agents: nil, claude: .missing)
    @State private var agentsText = ""
    @State private var policy = ProjectCommandPolicy(projectPath: "")
    @State private var message: String?

    private var folder: URL { URL(fileURLWithPath: project.path, isDirectory: true) }
    private var policyStore: CommandPolicyStore { CommandPolicyStore(root: model.dataRoot) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("项目设置 · \(project.name)").titleText(18)
                    Text(NSString(string: project.path).abbreviatingWithTildeInPath).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("完成", action: onDone).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    agentsSection
                    claudeSection
                    policySection
                    if let message { Text(message).font(Theme.sans(12)).foregroundStyle(Theme.warn) }
                }
                .padding(22)
            }
        }
        .frame(width: 640, height: 640)
        .themedSurface()
        .onAppear(perform: reload)
    }

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("项目规则 · AGENTS.md").font(Theme.sans(13, weight: .medium))
            Text("直接编辑项目根目录的 AGENTS.md。Codex 和 Cursor 自己读取它；Claude Code 在信任的项目里通过 CLAUDE.md 或 instructionFiles 设置读取，在聊天模式下由 AgentDesk 注入。")
                .font(Theme.sans(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $agentsText).themedEditor(mono: true).frame(height: 200)
            HStack {
                Text(rules.agents == nil ? "还没有 AGENTS.md，保存后创建" : "\(agentsText.count) 字").metaText()
                Spacer()
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([rules.agents == nil ? folder : rules.agentsURL]) }
                    .buttonStyle(SecondaryButtonStyle())
                Button("保存") {
                    do { try ProjectRules.saveAgents(agentsText, in: folder); message = nil } catch { message = "AGENTS.md 未能保存：\(error.localizedDescription)" }
                    reload()
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(agentsText == (rules.agents ?? ""))
            }
        }
        .themedCard()
    }

    private var claudeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude Code · CLAUDE.md").font(Theme.sans(13, weight: .medium))
            switch rules.claude {
            case .importsAgents:
                Text("CLAUDE.md 已经引用 \(ProjectRules.claudeImportLine)，Claude Code 会读到项目规则。").font(Theme.sans(12))
            case .withoutImport:
                Text("项目已有自己的 CLAUDE.md，但没有引用 AGENTS.md。AgentDesk 不会改它；AgentDesk 启动 Claude Code 时会让它在 CLAUDE.md 旁边加载 AGENTS.md。想在终端里用 Claude Code 也读到，请自己在 CLAUDE.md 里加一行：")
                    .font(Theme.sans(12)).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(ProjectRules.claudeImportLine).font(Theme.mono(12)).textSelection(.enabled)
                    Spacer()
                    Button("复制这一行") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ProjectRules.claudeImportLine, forType: .string)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            case .missing:
                Text("项目还没有 CLAUDE.md。可以新建一个只含 \(ProjectRules.claudeImportLine) 的 CLAUDE.md，让 Claude Code（包括在终端里）读同一份项目规则。")
                    .font(Theme.sans(12)).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("新建 CLAUDE.md") {
                        do { try ProjectRules.createClaudeImport(in: folder); message = nil } catch { message = error.localizedDescription }
                        reload()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .themedCard()
    }

    private var policySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("始终允许的命令").font(Theme.sans(13, weight: .medium))
            Text("审批时选“以后这类命令都允许”会记在这里，只对这个项目有效。以这些词开头的命令不再询问。删除后恢复询问。")
                .font(Theme.sans(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if policy.commands.isEmpty {
                Text("还没有。").metaText()
            }
            ForEach(policy.commands) { rule in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.display).font(Theme.mono(12)).textSelection(.enabled)
                        Text("\(rule.provider.runtimeName) · \(rule.sourceTitle.map { "「\($0)」 · " } ?? "")\(rule.createdAt.formatted(date: .abbreviated, time: .shortened))").metaText()
                    }
                    Spacer()
                    Button("删除") {
                        do { policy = try policyStore.remove(rule.id, projectPath: project.path) } catch { message = error.localizedDescription }
                    }
                    .buttonStyle(SecondaryButtonStyle(destructive: true))
                }
            }
        }
        .themedCard()
    }

    private func reload() {
        rules = ProjectRules.read(folder)
        agentsText = rules.agents ?? ""
        policy = policyStore.load(projectPath: project.path)
    }
}
