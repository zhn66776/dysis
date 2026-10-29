import AppKit
import SwiftUI
import WebKit
import AgentDeskCore

/// Serves the bundled canvas page at agentdesk://app/ and provider marks at
/// agentdesk://app/icons/. Nothing outside those two folders is reachable.
final class CanvasSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "agentdesk"
    static let pageURL = URL(string: "agentdesk://app/index.html")!
    // The page has no network access and runs only its own bundled scripts.
    static let contentSecurityPolicy = "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

    let pageRoot: URL?
    let iconRoot: URL?

    override init() {
        let resources = Bundle.main.resourceURL
        var page = resources?.appendingPathComponent("Canvas", isDirectory: true)
        var icons = resources?.appendingPathComponent("ProviderIcons", isDirectory: true)
#if DEBUG
        // `swift run` has no app bundle; use the source checkout. Release
        // builds must find the packaged copy so packaging mistakes stay visible.
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if page.map({ !FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) }) ?? true {
            page = source.appendingPathComponent("canvas-web/dist", isDirectory: true)
        }
        if icons.map({ !FileManager.default.fileExists(atPath: $0.path) }) ?? true {
            icons = source.appendingPathComponent("Resources/ProviderIcons", isDirectory: true)
        }
#endif
        pageRoot = page
        iconRoot = icons
    }

    var hasPage: Bool { pageRoot.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) } ?? false }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "app" else { return fail(task, 400) }
        let path = url.path.isEmpty || url.path == "/" ? "/index.html" : url.path
        let isIcon = path.hasPrefix("/icons/")
        guard let root = (isIcon ? iconRoot : pageRoot)?.standardizedFileURL else { return fail(task, 404) }
        let relative = String(path.dropFirst(isIcon ? "/icons/".count : 1))
        let file = root.appendingPathComponent(relative).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else { return fail(task, 404) }
        var headers = ["Content-Type": Self.mimeType(file.pathExtension), "Content-Length": String(data.count), "Cache-Control": "no-cache"]
        if file.pathExtension == "html" { headers["Content-Security-Policy"] = Self.contentSecurityPolicy }
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else { return fail(task, 500) }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    private func fail(_ task: any WKURLSchemeTask, _ status: Int) {
        if let url = task.request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"]) {
            task.didReceive(response)
            task.didReceive(Data())
            task.didFinish()
        } else {
            task.didFailWithError(URLError(.badURL))
        }
    }

    static func mimeType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "json": return "application/json"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }
}

/// Files dragged onto the window become attachments of the open conversation,
/// read natively so the page never sees file paths.
final class CanvasWKWebView: WKWebView {
    weak var bridge: CanvasBridge?

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingEntered(sender) : (bridge?.panelSessionID == nil ? [] : .copy)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingUpdated(sender) : (bridge?.panelSessionID == nil ? [] : .copy)
    }

    /// The page's top strip acts as the title bar: drag to move the window,
    /// double-click for the system title-bar action. Controls in it still click.
    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y)
        guard let window, bridge?.isWindowDragPoint(point) == true else { return super.mouseDown(with: event) }
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.miniaturize(nil)
            case "None": break
            default: window.zoom(nil)
            }
        } else {
            window.performDrag(with: event)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(chromeChanged), name: name, object: window)
        }
        bridge?.pushChrome()
    }

    @objc private func chromeChanged() { bridge?.pushChrome() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        return bridge?.dropFiles(urls) ?? false
    }
}

struct CanvasWebView: NSViewRepresentable {
    let bridge: CanvasBridge

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let handler = CanvasSchemeHandler()
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: CanvasSchemeHandler.scheme)
        config.userContentController.add(bridge, name: "agentDesk")
        config.websiteDataStore = .nonPersistent()
        let web = CanvasWKWebView(frame: .zero, configuration: config)
        web.bridge = bridge
        web.setValue(false, forKey: "drawsBackground")
        // The window's title bar is transparent and the page draws its own top
        // strip; stop WebKit from pushing the page below the title bar.
        if web.responds(to: NSSelectorFromString("_setAutomaticallyAdjustsContentInsets:")) {
            web.setValue(false, forKey: "automaticallyAdjustsContentInsets")
        }
        web.allowsBackForwardNavigationGestures = false
        web.allowsMagnification = false
#if DEBUG
        web.isInspectable = true
#endif
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        bridge.webView = web
        if handler.hasPage {
            web.load(URLRequest(url: CanvasSchemeHandler.pageURL))
        } else {
            web.loadHTMLString("<body style=\"font:14px -apple-system;padding:40px;color:#a33\">缺少画布资源（Contents/Resources/Canvas）。请用 scripts/build-app.sh 重新打包。</body>", baseURL: nil)
        }
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "agentDesk")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.cancel) }
            if url.scheme == CanvasSchemeHandler.scheme || url.absoluteString == "about:blank" { return decisionHandler(.allow) }
            // Links in replies open in the default browser, never inside the app.
            if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? ""), action.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
            return nil
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // The page asks for a fresh snapshot with `ready` after reloading.
            webView.load(URLRequest(url: CanvasSchemeHandler.pageURL))
        }
    }
}

/// Main window: the canvas page plus the native windows it can open.
struct CanvasRootView: View {
    @ObservedObject var model: AppModel
    @StateObject private var bridge: CanvasBridge
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var mcpTarget: MCPTarget?

    private struct MCPTarget: Identifiable { let id = UUID(); let sessionID: UUID? }

    init(model: AppModel, canvas: CanvasModel) {
        self.model = model
        _bridge = StateObject(wrappedValue: CanvasBridge(app: model, canvas: canvas))
    }

    var body: some View {
        CanvasWebView(bridge: bridge)
            .ignoresSafeArea()
            .onAppear {
                bridge.openWindow = { window, sessionID in
                    switch window {
                    case "settings": openSettings()
                    case "classic": openWindow(id: "classic")
                    default: mcpTarget = MCPTarget(sessionID: sessionID)
                    }
                }
            }
            .sheet(item: $mcpTarget) { target in
                let title = target.sessionID.flatMap { id in model.sessions.first { $0.id == id }?.title }
                MCPWorkbenchView(root: model.dataRoot, canAttach: title != nil, targetLabel: title ?? "请先在画布上打开一个节点") { result in
                    if let id = target.sessionID { bridge.insertIntoComposer(sessionID: id, text: result) }
                    mcpTarget = nil
                }
            }
    }
}
