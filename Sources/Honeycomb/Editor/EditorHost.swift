import AppKit
import HoneycombCore
import SwiftUI
import WebKit

/// The one shared editor web view. Created at launch and reused by every meeting, so opening a
/// meeting is instant and only one web process runs. SQLite is the source of truth; the page
/// only shows a document and reports edits.
@MainActor
final class EditorHost: NSObject {
    static let shared = EditorHost()
    static let scheme = "honeycomb-editor"
    static let schemaVersion = 1

    let webView: WKWebView
    private(set) var isReady = false
    private var pending: [(String, [String: Any])] = []
    /// The latest of each message that sets what the page shows, sent again to a new page.
    private var shown: [String: [String: Any]] = [:]
    private static let replayed = ["load", "setSources", "setTheme"]
    private var loadID = 0
    /// Save closures by load ID. The page tags every edit with the ID of the load it was made in,
    /// so an edit that arrives after the next note loaded still saves to its own note.
    private var saves: [Int: (PMNode) -> Void] = [:]
    private var onSourceClicked: ((String, CGRect) -> Void)?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(EditorSchemeHandler(), forURLScheme: Self.scheme)
        configuration.websiteDataStore = .nonPersistent()
        let controller = WKUserContentController()
        configuration.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        controller.addScriptMessageHandler(self, contentWorld: .page, name: "bridge")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        #if DEBUG
        webView.isInspectable = true
        #endif
        reload()
    }

    private func reload() {
        isReady = false
        webView.load(URLRequest(url: URL(string: "\(Self.scheme)://app/index.html")!))
    }

    /// Shows a document. `onChange` gets the user's edits, debounced by the page.
    func load(_ doc: PMNode?, editable: Bool, placeholder: String, onChange: ((PMNode) -> Void)?,
              onSource: ((String, CGRect) -> Void)? = nil) {
        loadID += 1
        saves[loadID] = onChange
        onSourceClicked = onSource
        var payload: [String: Any] = ["loadId": loadID, "mode": editable ? "edit" : "readonly", "placeholder": placeholder]
        payload["doc"] = doc.flatMap(Self.object) ?? NSNull()
        send("load", payload)
    }

    /// Streaming AI notes: read-only, replaced as text arrives.
    func streamUpdate(_ doc: PMNode) {
        send("streamUpdate", ["doc": Self.object(doc) ?? NSNull()])
    }

    func streamDone(_ doc: PMNode) {
        let object = Self.object(doc) ?? NSNull()
        shown["load"]?["mode"] = "edit"
        shown["load"]?["doc"] = object
        send("streamDone", ["doc": object])
    }

    func setSources(_ blockIDs: [String]) {
        send("setSources", ["blockIds": blockIDs])
    }

    func setTheme(dark: Bool, fontSize: Int = 16, underlineAI: Bool = false) {
        send("setTheme", ["appearance": dark ? "dark" : "light", "fontSize": fontSize, "underlineAI": underlineAI])
    }

    var isFocused: Bool {
        (webView.window?.firstResponder as? NSView)?.isDescendant(of: webView) == true
    }

    func focus() {
        send("focus", [:])
    }

    /// Saves an edit the page has not reported yet. Call before quitting.
    func flush() async {
        guard isReady else { return }
        _ = try? await webView.callAsyncJavaScript(Self.receive, arguments: ["envelope": Self.envelope("flush", [:])],
                                                   contentWorld: .page)
    }

    private static let receive = "return window.honeycomb.receive(envelope)"

    private static func envelope(_ type: String, _ payload: [String: Any]) -> [String: Any] {
        ["v": 1, "type": type, "payload": payload]
    }

    private func send(_ type: String, _ payload: [String: Any]) {
        if Self.replayed.contains(type) { shown[type] = payload }
        guard isReady else {
            pending.removeAll { $0.0 == type }
            pending.append((type, payload))
            return
        }
        webView.callAsyncJavaScript(Self.receive, arguments: ["envelope": Self.envelope(type, payload)],
                                    in: nil, in: .page) { [weak self] result in
            guard case .success(let reply) = result else { return Log.error("editor.message_failed") }
            let ok = (reply as? [String: Any])?["ok"] as? Bool == true
            if type == "load", let id = payload["loadId"] as? Int {
                self?.loadReplied(id, ok: ok)
            } else if !ok {
                Log.error("editor.message_rejected")
            }
        }
    }

    /// Once the page shows a load, it reports no more edits for older ones, so their closures go.
    /// A rejected load must not leave the previous note on screen, so a read-only notice replaces it.
    private func loadReplied(_ id: Int, ok: Bool) {
        if ok {
            saves = saves.filter { $0.key >= id }
            return
        }
        Log.error("editor.load_rejected")
        saves[id] = nil
        if id == loadID {
            load(Markdown.document("These notes can't be shown."), editable: false, placeholder: "", onChange: nil)
        }
    }

    static func object(_ doc: PMNode) -> Any? {
        guard let data = try? JSONEncoder().encode(doc) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func node(_ object: Any?) -> PMNode? {
        guard let object, JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(PMNode.self, from: data)
    }
}

extension EditorHost: WKScriptMessageHandlerWithReply {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let envelope = message.body as? [String: Any], envelope["v"] as? Int == 1,
              let type = envelope["type"] as? String else {
            replyHandler(nil, "bad_envelope")
            return
        }
        let payload = envelope["payload"] as? [String: Any] ?? [:]
        switch type {
        case "ready":
            let major = (payload["schemaVersion"] as? Int) ?? 0
            guard major == Self.schemaVersion else {
                Log.error("editor.schema_mismatch", ["page": .int(major)])
                replyHandler(nil, "schema_mismatch")
                return
            }
            isReady = true
            let queued = pending.filter { !Self.replayed.contains($0.0) }
            pending = []
            for type in Self.replayed { if let payload = shown[type] { send(type, payload) } }
            for (type, payload) in queued { send(type, payload) }
        case "docChanged":
            if let id = payload["loadId"] as? Int, let doc = Self.node(payload["doc"]) {
                if id == loadID { shown["load"]?["doc"] = payload["doc"] }
                saves[id]?(doc)
            }
        case "linkClicked":
            if let href = payload["href"] as? String, Markdown.isSafeLink(href), let url = URL(string: href) {
                NSWorkspace.shared.open(url)
            }
        case "sourceClicked":
            if let block = payload["blockId"] as? String, let rect = payload["rect"] as? [String: Double] {
                onSourceClicked?(block, CGRect(x: rect["x"] ?? 0, y: rect["y"] ?? 0, width: rect["width"] ?? 0, height: rect["height"] ?? 0))
            }
        default:
            replyHandler(nil, "unknown_type")
            return
        }
        replyHandler(["ok": true], nil)
    }
}

extension EditorHost: WKNavigationDelegate {
    /// Only the editor bundle may load. Links open in the default browser instead.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        if action.request.url?.scheme == Self.scheme { return .allow }
        if let url = action.request.url, Markdown.isSafeLink(url.absoluteString) { NSWorkspace.shared.open(url) }
        return .cancel
    }

    /// If the web process dies, reload. The new page gets the last document, sources, and theme again.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.error("editor.process_terminated")
        reload()
    }
}

/// Serves the editor bundle from the app's Resources/Editor folder.
final class EditorSchemeHandler: NSObject, WKURLSchemeHandler {
    private let root = Bundle.main.resourceURL?.appendingPathComponent("Editor")

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let root else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let path = url.path.isEmpty || url.path == "/" ? "index.html" : String(url.path.dropFirst())
        let file = root.appendingPathComponent(path).standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path), let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let types = ["html": "text/html", "js": "text/javascript", "css": "text/css", "svg": "image/svg+xml",
                     "woff2": "font/woff2", "json": "application/json"]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": types[file.pathExtension] ?? "application/octet-stream",
            "Content-Security-Policy": "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'none'",
        ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// Puts the shared editor web view into a SwiftUI layout.
struct EditorView: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    /// Never re-attaches here. When the selected meeting changes, SwiftUI can update the outgoing
    /// editor after it made the incoming one, and taking the web view back would carry it out of
    /// the window with the outgoing view.
    func updateNSView(_ view: NSView, context: Context) {
        EditorHost.shared.setTheme(dark: colorScheme == .dark)
    }

    private func attach(to container: NSView) {
        let webView = EditorHost.shared.webView
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
