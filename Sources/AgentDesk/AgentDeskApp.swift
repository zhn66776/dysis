import SwiftUI
import AppKit
import AgentDeskCore

@main
struct AgentDeskApp: App {
    @StateObject private var model: AppModel
    @StateObject private var canvas: CanvasModel
    @NSApplicationDelegateAdaptor(AgentDeskDelegate.self) private var delegate

    init() {
        let args = ProcessInfo.processInfo.arguments
        var root: URL?
        if let i = args.firstIndex(of: "--data-dir"), args.indices.contains(i + 1) {
            root = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        }
        // Test runs put node worktrees elsewhere too, next to their --data-dir.
        var worktrees = NodeWorktree.defaultRoot
        if let i = args.firstIndex(of: "--worktrees-dir"), args.indices.contains(i + 1) {
            worktrees = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        }
        let app = AppModel(root: root)
        _model = StateObject(wrappedValue: app)
        _canvas = StateObject(wrappedValue: CanvasModel(app: app, worktreeRoot: worktrees))
    }

    var body: some Scene {
        WindowGroup {
            CanvasRootView(model: model, canvas: canvas)
                .frame(minWidth: 900, minHeight: 620)
                .transparentTitleBar()
                .onAppear { delegate.model = model }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        // The previous SwiftUI interface: Plaza, attachments, dictation and
        // export live here until they move onto the canvas.
        Window("经典界面", id: "classic") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 620)
                .transparentTitleBar()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(after: .appSettings) {
                Toggle("开发者模式", isOn: $model.developerModeEnabled)
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .newItem) {
                Menu("新建会话") {
                    ForEach(AgentDeskCore.ProviderID.allCases) { provider in
                        Button { model.newSession(provider: provider) } label: {
                            Label { Text(provider.name) } icon: { ProviderIcon(provider: provider, size: 16) }
                        }
                    }
                }
            }
        }
        Settings { SettingsView(model: model, canvas: canvas).frame(width: 720, height: 650).transparentTitleBar() }
    }
}

import AgentDeskCore

@MainActor
final class AgentDeskDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.shutdown()
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
