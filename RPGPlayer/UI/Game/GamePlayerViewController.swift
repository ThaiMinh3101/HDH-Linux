import UIKit
import WebKit

// MARK: - GamePlayerViewController
// UIViewController that hosts a full-screen WKWebView for playing
// RPG Maker MV / MZ games via the custom rpggame:// scheme.

final class GamePlayerViewController: UIViewController {

    // MARK: - Properties

    let entry: GameEntry

    private var webView: WKWebView!
    private let schemeHandler: RPGGameSchemeHandler
    private let savesURL: URL

    // MARK: - Init

    init(entry: GameEntry) {
        self.entry = entry
        let sandboxURL = StorageManager.shared.sandboxURL(for: entry.id)
        self.schemeHandler = RPGGameSchemeHandler(
            gameID: entry.id,
            sandboxRoot: sandboxURL
        )
        self.savesURL = StorageManager.shared.savesURL(for: entry.id)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        buildWebView()
        loadGame()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Hide navigation bar for full-screen immersion
        navigationController?.setNavigationBarHidden(true, animated: animated)
        lockLandscape()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        unlockOrientation()
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    // MARK: - WebView Setup

    private func buildWebView() {
        // ── Configuration ──────────────────────────────────────────────────
        let config = WKWebViewConfiguration()

        // Register custom URL scheme BEFORE creating the webView
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "rpggame")

        // Allow JavaScript (required for game engine)
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        // Allow inline media playback (required for RPG Maker audio)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // User content controller for JS ↔ Swift message passing
        let ucc = WKUserContentController()
        ucc.add(WeakMessageHandler(delegate: self), name: "rpgSave")
        ucc.add(WeakMessageHandler(delegate: self), name: "rpgLoad")
        ucc.add(WeakMessageHandler(delegate: self), name: "rpgSaveRemove")
        ucc.add(WeakMessageHandler(delegate: self), name: "rpgQuit")
        ucc.add(WeakMessageHandler(delegate: self), name: "rpgConsole")
        config.userContentController = ucc

        // ── Inject polyfill + save bridge BEFORE any game script runs ──────
        injectUserScript(named: "NWJSPolyfill",  into: ucc, at: .atDocumentStart)
        injectUserScript(named: "SaveBridge",    into: ucc, at: .atDocumentStart)

        // ── Create WebView ─────────────────────────────────────────────────
        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = true
        webView.backgroundColor = .black
        webView.navigationDelegate = self
        view.addSubview(webView)
    }

    private func injectUserScript(
        named name: String,
        into ucc: WKUserContentController,
        at injectionTime: WKUserScriptInjectionTime
    ) {
        guard let url  = Bundle.main.url(forResource: name, withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            print("[GamePlayer] ⚠️ Could not load \(name).js from bundle")
            return
        }
        let script = WKUserScript(
            source: source,
            injectionTime: injectionTime,
            forMainFrameOnly: false
        )
        ucc.addUserScript(script)
    }

    // MARK: - Load Game

    private func loadGame() {
        // Build the rpggame:// URL for the game's index.html
        // URL format: rpggame://<uuidString>/index.html
        var components        = URLComponents()
        components.scheme     = "rpggame"
        components.host       = entry.id.uuidString
        components.path       = "/index.html"

        guard let url = components.url else {
            print("[GamePlayer] ❌ Could not construct rpggame:// URL for \(entry.id)")
            return
        }
        print("[GamePlayer] Loading: \(url)")
        webView.load(URLRequest(url: url))
    }

    // MARK: - Orientation Lock

    private func lockLandscape() {
        AppDelegate.orientationMask = .landscape
        if #available(iOS 16.0, *) {
            let windowScene = view.window?.windowScene
            windowScene?.requestGeometryUpdate(
                .iOS(interfaceOrientations: .landscape)
            ) { error in
                print("[GamePlayer] Orientation update error: \(error)")
            }
            setNeedsUpdateOfSupportedInterfaceOrientations()
        } else {
            UIDevice.current.setValue(
                UIInterfaceOrientation.landscapeRight.rawValue,
                forKey: "orientation"
            )
        }
    }

    private func unlockOrientation() {
        AppDelegate.orientationMask = .portrait
        if #available(iOS 16.0, *) {
            let windowScene = view.window?.windowScene
            windowScene?.requestGeometryUpdate(
                .iOS(interfaceOrientations: .portrait)
            ) { _ in }
            setNeedsUpdateOfSupportedInterfaceOrientations()
        } else {
            UIDevice.current.setValue(
                UIInterfaceOrientation.portrait.rawValue,
                forKey: "orientation"
            )
        }
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .landscape
    }
}

// MARK: - WKNavigationDelegate

extension GamePlayerViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("[GamePlayer] ❌ didFailProvisionalNavigation: \(error)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("[GamePlayer] ❌ didFail: \(error)")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("[GamePlayer] ✅ didFinish — game page loaded")
        // Inject a WebGL renderer check after page load
        let checkWebGL = """
        (function() {
            try {
                var canvas = document.createElement('canvas');
                var gl = canvas.getContext('webgl2') || canvas.getContext('webgl');
                var renderer = gl ? (gl.getExtension('WEBGL_debug_renderer_info')
                    ? gl.getParameter(gl.getExtension('WEBGL_debug_renderer_info').UNMASKED_RENDERER_WEBGL)
                    : 'WebGL (renderer info unavailable)') : 'Canvas 2D (WebGL unavailable)';
                webkit.messageHandlers.rpgConsole.postMessage({ type: 'webgl', renderer: renderer });
            } catch(e) {
                webkit.messageHandlers.rpgConsole.postMessage({ type: 'webgl', renderer: 'error: ' + e });
            }
        })();
        """
        webView.evaluateJavaScript(checkWebGL, completionHandler: nil)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Allow rpggame:// scheme and about:blank (initial load)
        let scheme = navigationAction.request.url?.scheme ?? ""
        if scheme == "rpggame" || scheme == "about" || scheme == "blob" {
            decisionHandler(.allow)
        } else {
            // Block external navigation (http/https/etc.)
            print("[GamePlayer] Blocked external navigation to: \(navigationAction.request.url?.absoluteString ?? "?")")
            decisionHandler(.cancel)
        }
    }
}

// MARK: - WKScriptMessageHandler

extension GamePlayerViewController: WKScriptMessageHandler {

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        switch message.name {

        case "rpgSave":
            handleSave(message.body)

        case "rpgLoad":
            handleLoad(message.body)

        case "rpgSaveRemove":
            handleRemove(message.body)

        case "rpgQuit":
            DispatchQueue.main.async { [weak self] in
                self?.navigationController?.popViewController(animated: true)
            }

        case "rpgConsole":
            if let dict = message.body as? [String: Any] {
                let type = dict["type"] as? String ?? "log"
                switch type {
                case "fps":
                    let fps = dict["value"] as? Double ?? 0
                    print("[GamePlayer][FPS] \(fps) fps")
                case "webgl":
                    let renderer = dict["renderer"] as? String ?? "unknown"
                    print("[GamePlayer][WebGL] Renderer: \(renderer)")
                case "error":
                    let msg  = dict["message"]  as? String ?? ""
                    let file = dict["filename"] as? String ?? ""
                    let line = dict["lineno"]   as? Int    ?? 0
                    print("[GamePlayer][JS ERROR] \(msg) @ \(file):\(line)")
                default:
                    print("[GamePlayer][JS] \(dict)")
                }
            }

        default:
            break
        }
    }

    // MARK: Save Handlers

    private func handleSave(_ body: Any) {
        guard let dict  = body as? [String: Any],
              let key   = dict["key"]   as? String,
              let value = dict["value"] as? String else {
            print("[GamePlayer] ⚠️ rpgSave: invalid message body")
            return
        }
        let fileURL = savesURL.appendingPathComponent(sanitiseKey(key) + ".json")
        DispatchQueue.global(qos: .utility).async {
            do {
                try value.write(to: fileURL, atomically: true, encoding: .utf8)
                print("[GamePlayer] 💾 Saved: \(key)")
            } catch {
                print("[GamePlayer] ❌ Save failed for \(key): \(error)")
            }
        }
    }

    private func handleLoad(_ body: Any) {
        guard let dict = body as? [String: Any],
              let key  = dict["key"] as? String else {
            print("[GamePlayer] ⚠️ rpgLoad: invalid message body")
            return
        }
        let fileURL = savesURL.appendingPathComponent(sanitiseKey(key) + ".json")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let json: String?
            if FileManager.default.fileExists(atPath: fileURL.path),
               let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                json = content
            } else {
                json = nil
            }
            // Escape the JSON string for safe embedding in JS
            let escaped = json.map { $0
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'",  with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            }
            let jsArg: String
            if let e = escaped {
                jsArg = "'\(e)'"
            } else {
                jsArg = "null"
            }
            let jsKey     = key
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'",  with: "\\'")
            let js = "window.__rpgLoadCallback('\(jsKey)', \(jsArg));"
            DispatchQueue.main.async { [weak self] in
                self?.webView.evaluateJavaScript(js, completionHandler: { _, error in
                    if let error { print("[GamePlayer] ❌ Load callback JS error: \(error)") }
                })
            }
        }
    }

    private func handleRemove(_ body: Any) {
        guard let dict = body as? [String: Any],
              let key  = dict["key"] as? String else { return }
        let fileURL = savesURL.appendingPathComponent(sanitiseKey(key) + ".json")
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: fileURL)
            print("[GamePlayer] 🗑 Removed save: \(key)")
        }
    }

    /// Sanitise a save key so it is safe as a filename component.
    private func sanitiseKey(_ key: String) -> String {
        key.components(separatedBy: .init(charactersIn: "/\\:*?\"<>|"))
           .joined(separator: "_")
    }
}

// MARK: - WeakMessageHandler
// Breaks the retain cycle: WKUserContentController → handler → ViewController.

private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    init(delegate: WKScriptMessageHandler) { self.delegate = delegate }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}
