import UIKit
import WebKit
import SwiftUI
import Combine
import Translation

// MARK: - GamePlayerViewController
// UIViewController that hosts a full-screen WKWebView for playing
// RPG Maker MV / MZ games via the custom rpggame:// scheme.

final class GamePlayerViewController: UIViewController {

    // MARK: - Properties

    let entry: GameEntry

    private var webView: WKWebView!
    private let savesURL: URL

    // M4: Record when the VC first appears so we can compute end-to-end launch time
    // when LaunchTimingBridge.js reports firstPaint from JS performance.now().
    private var launchWallTime: Date = Date()

    // M2: Input bridge
    /// CADisplayLink that pushes InputState → GamepadBridge.js every frame.
    private var displayLink: CADisplayLink?
    /// Previous merged input — only send JS update when state changes.
    private var previousMergedInput = InputState.neutral
    /// c2 fix: throttle JS pushes to ~30 Hz. RPG games don't need 60 Hz input
    /// updates — evaluateJavaScript has ~0.5-2ms overhead per call, so pushing
    /// every frame when an analog stick is held costs ~30-120ms/s of main-thread
    /// time. 30 Hz is imperceptible for menu/d-pad navigation.
    private var lastJSPushTime: CFTimeInterval = 0
    private let jsPushInterval: CFTimeInterval = 1.0 / 30.0
    /// Hosting controller for the SwiftUI VirtualDpadView overlay.
    private var dpadHostingController: UIHostingController<VirtualDpadView>?
    private var gamepadCancellable: AnyCancellable?
    /// Exit button overlay (always visible, not gated by gamepad)
    private var exitHostVC: UIHostingController<ExitButtonView>?

    // M5: Translation overlay
    private var translationOverlay: TranslationOverlayHostingController?

    // M8.1: Missing asset handler — ngăn hiện alert nhiều lần.
    private var hasShownMissingAssetAlert = false

    // MARK: - Init

    init(entry: GameEntry) {
        self.entry    = entry
        self.savesURL = StorageManager.shared.savesURL(for: entry.id)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        launchWallTime = Date()
        buildWebView()
        loadGame()
        setupDpadOverlay()        // M2: virtual D-pad on top of WKWebView
        startDisplayLink()        // M2: 60fps input push to GamepadBridge.js
        setupTranslationOverlay() // M5: subtitle translation overlay
        setupExitButton()         // Exit button — top-left, always visible
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Hide navigation bar for full-screen immersion
        navigationController?.setNavigationBarHidden(true, animated: animated)
        lockLandscape()
        displayLink?.isPaused = false
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        unlockOrientation()
        displayLink?.isPaused = true
    }

    deinit {
        displayLink?.invalidate()
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    // MARK: - WebView Setup

    /// M4: Static factory so WebViewPool can pre-allocate a WKWebView
    /// with the exact same configuration before the user taps play.
    /// Called by both buildWebView() and WebViewPool.warmUp(for:).
    static func makeWebViewConfig(
        gameID: UUID,
        sandboxRoot: URL
    ) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()

        // Register custom URL scheme BEFORE creating the webView
        config.setURLSchemeHandler(
            RPGGameSchemeHandler(gameID: gameID, sandboxRoot: sandboxRoot),
            forURLScheme: "rpggame"
        )

        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        return config
    }

    private func buildWebView() {
        // M4: WebViewPool provides pre-computed sandbox URL (avoiding FileManager lookup).
        // WKWebView instances cannot be reused due to iOS 14+ WKUserContentController
        // mutation restriction — always build a fresh WKWebView.
        let wasWarmed  = WebViewPool.shared.wasWarmed(for: entry.id)
        let sandboxURL = WebViewPool.shared.sandboxURL(for: entry.id)  // consumes the warm entry
        let config     = Self.makeWebViewConfig(gameID: entry.id, sandboxRoot: sandboxURL)

        let ucc = WKUserContentController()
        attachMessageHandlers(to: ucc)
        config.userContentController = ucc

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = true
        webView.backgroundColor = .black
        webView.navigationDelegate = self
        view.addSubview(webView)
        print("[GamePlayer] 🆕 WKWebView created (\(wasWarmed ? "sandbox warm" : "sandbox cold"))")
    }

    /// Register WKScriptMessageHandlers and inject all user scripts.
    private func attachMessageHandlers(to ucc: WKUserContentController) {
        ucc.add(WeakMessageHandler(delegate: self), name: "rpgSave")
        ucc.add(WeakMessageHandler(delegate: self), name: "rpgLoad")
        ucc.add(WeakMessageHandler(delegate: self), name: "rpgSaveRemove")
        ucc.add(WeakMessageHandler(delegate: self), name: "rpgQuit")
        ucc.add(WeakMessageHandler(delegate: self), name: "rpgConsole")
        ucc.add(WeakMessageHandler(delegate: self), name: "rpgTranslate")  // M5

        // Inject scripts in order — all at document start so they're ready
        // before any game script executes.
        injectUserScript(named: "ImageErrorGuard",    into: ucc, at: .atDocumentStart)  // M4
        injectUserScript(named: "LaunchTimingBridge", into: ucc, at: .atDocumentStart)  // M4
        injectUserScript(named: "NWJSPolyfill",       into: ucc, at: .atDocumentStart)
        injectUserScript(named: "SaveBridge",         into: ucc, at: .atDocumentStart)
        injectUserScript(named: "GamepadBridge",      into: ucc, at: .atDocumentStart)
        injectUserScript(named: "FPSMonitor",         into: ucc, at: .atDocumentStart)  // M5

        // M5: TranslationBridge — inject với enabled flag từ entry.translationEnabled.
        // Inject flag trước script để TranslationBridge đọc được ngay khi chạy.
        let translationFlag = entry.translationEnabled ? "true" : "false"
        let flagScript = WKUserScript(
            source: "window.__rpgTranslationEnabled = \(translationFlag);",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        ucc.addUserScript(flagScript)
        injectUserScript(named: "TranslationBridge", into: ucc, at: .atDocumentStart)  // M5
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

    // MARK: - M2: Virtual D-pad overlay

    private func setupDpadOverlay() {
        let dpadView = VirtualDpadView()
        let hostVC   = UIHostingController(rootView: dpadView)
        hostVC.view.backgroundColor = .clear
        hostVC.view.isUserInteractionEnabled = true

        addChild(hostVC)
        hostVC.view.frame = view.bounds
        hostVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hostVC.view)
        hostVC.didMove(toParent: self)
        dpadHostingController = hostVC

        gamepadCancellable = GamepadManager.shared.$isGamepadConnected
            .receive(on: DispatchQueue.main)
            .sink { connected in
                print("[GamePlayer] Gamepad \(connected ? "connected" : "disconnected") — D-pad overlay \(connected ? "hidden" : "visible")")
            }
    }

    // MARK: - Exit button

    private func setupExitButton() {
        let exitView = ExitButtonView {
            // Dismiss back to LibraryView (pop or dismiss depending on presentation)
            if let nav = self.navigationController {
                nav.popViewController(animated: true)
            } else {
                self.dismiss(animated: true)
            }
        }
        let hostVC = UIHostingController(rootView: exitView)
        hostVC.view.backgroundColor = .clear
        hostVC.view.isUserInteractionEnabled = true
        addChild(hostVC)
        hostVC.view.frame = view.bounds
        hostVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Add above everything else so the button is always tappable
        view.addSubview(hostVC.view)
        hostVC.didMove(toParent: self)
        exitHostVC = hostVC
    }

    // MARK: - M5: Translation overlay

    private func setupTranslationOverlay() {
        let hostVC = TranslationOverlayHostingController(entry: entry)
        addChild(hostVC)
        hostVC.view.frame = view.bounds
        hostVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hostVC.view.backgroundColor = .clear
        hostVC.view.isUserInteractionEnabled = true
        // Add on top of D-pad (translation button must be tappable)
        view.addSubview(hostVC.view)
        hostVC.didMove(toParent: self)
        translationOverlay = hostVC
    }

    /// Cập nhật enabled flag trong JS khi user toggle từ overlay button.
    /// Gọi khi TranslationOverlayView thay đổi translationEnabled (observe via LibraryStore).
    private func pushTranslationEnabledToJS(_ enabled: Bool) {
        let js = "if(window.__rpgSetTranslationEnabled) window.__rpgSetTranslationEnabled(\(enabled ? "true" : "false"));"
        webView?.evaluateJavaScript(js) { _, error in
            if let error { print("[GamePlayer][Translation] JS toggle error: \(error)") }
        }
    }

    // MARK: - M2: CADisplayLink — push InputState → GamepadBridge.js

    private func startDisplayLink() {
        let link = CADisplayLink(target: self, selector: #selector(frameTick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Fires every display refresh (~60 fps).
    /// Converts the current merged InputState to JSON and pushes it to the
    /// GamepadBridge.js shim via evaluateJavaScript.
    /// Skips the JS call when state has not changed since last frame.
    @objc private func frameTick(_ link: CADisplayLink) {
        let current = GamepadManager.shared.mergedInput
        guard current != previousMergedInput else { return }
        previousMergedInput = current

        // c2 fix: throttle to ~30 Hz. When an analog stick is held, the input
        // state changes every frame (float values) — pushing JS 60×/s is
        // wasteful. 30 Hz is smooth enough for RPG input.
        let now = CACurrentMediaTime()
        guard now - lastJSPushTime >= jsPushInterval else { return }
        lastJSPushTime = now

        // Build a compact JSON object matching the fields GamepadBridge.js expects.
        let json = stateToJSON(current)
        let js = "(function(){ var s=\(json); window.__rpgUpdateGamepad(s); window.__rpgUpdateGamepadKeys(s); })();"
        webView?.evaluateJavaScript(js) { _, error in
            if let error { print("[GamePlayer] GamepadBridge JS error: \(error)") }
        }
    }

    /// Serialise an InputState as a compact JSON literal (no Foundation JSONEncoder needed).
    private func stateToJSON(_ s: InputState) -> String {
        func b(_ v: Bool) -> String { v ? "true" : "false" }
        func f(_ v: Float) -> String { String(format: "%.3f", v) }
        return """
        {"dpadUp":\(b(s.dpadUp)),"dpadDown":\(b(s.dpadDown)),\
        "dpadLeft":\(b(s.dpadLeft)),"dpadRight":\(b(s.dpadRight)),\
        "buttonA":\(b(s.buttonA)),"buttonB":\(b(s.buttonB)),\
        "buttonC":\(b(s.buttonC)),"buttonD":\(b(s.buttonD)),\
        "l1":\(b(s.l1)),"r1":\(b(s.r1)),"l2":\(f(s.l2)),"r2":\(f(s.r2)),\
        "start":\(b(s.start)),"select":\(b(s.select))}
        """.trimmingCharacters(in: .whitespacesAndNewlines)
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
        handleNavigationFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("[GamePlayer] ❌ didFail: \(error)")
        handleNavigationFailure(error)
    }

    // MARK: - M8.1: Missing asset handler (MV/MZ)

    /// Hiện alert "Missing Game Asset" khi WKWebView không tải được resource.
    /// Auto-dismiss về Library khi user tap "Back to Library".
    /// English message (giống tone Empo requirement).
    private func handleNavigationFailure(_ error: Error) {
        guard !hasShownMissingAssetAlert else { return }
        hasShownMissingAssetAlert = true

        // Extract tên file bị lỗi từ URL trong NSError (nếu có).
        let fileName: String
        if let nsError = error as NSError?,
           let url = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String {
            fileName = url
        } else {
            fileName = error.localizedDescription
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.displayLink?.isPaused = true

            let alert = UIAlertController(
                title: "Missing Game Asset",
                message: """
                Could not load: \(fileName)

                The game may be missing assets.
                """,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Back to Library", style: .default) { [weak self] _ in
                guard let self else { return }
                if let nav = self.navigationController {
                    nav.popViewController(animated: true)
                } else {
                    self.dismiss(animated: true)
                }
            })

            self.present(alert, animated: true)
        }
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
                    // M5: FPSMonitor.js báo FPS thực của WKWebView render loop.
                    let fps      = dict["value"]    as? Double ?? 0
                    let budget   = dict["budgetMs"] as? Double ?? 0
                    let budgetStr = budget > 0 ? String(format: " (%.1fms/frame)", budget) : ""
                    print("[GamePlayer][FPS] \(Int(fps)) fps\(budgetStr)")

                case "webgl":
                    let renderer = dict["renderer"] as? String ?? "unknown"
                    print("[GamePlayer][WebGL] Renderer: \(renderer)")

                case "imageError":
                    // M4: Crash guard — log broken asset, do NOT propagate further.
                    let src = dict["src"] as? String ?? "(unknown)"
                    print("[GamePlayer][ImageError] ⚠️  Failed to load: \(src)")

                case "launchTiming":
                    // M4: Fast Launch — report timing checkpoint.
                    let checkpoint = dict["checkpoint"] as? String ?? "?"
                    let ms         = dict["ms"]         as? Int    ?? -1
                    let wallMs     = Int(Date().timeIntervalSince(launchWallTime) * 1000)
                    print("[LaunchTiming] JS '\(checkpoint)': \(ms)ms (wall: ~\(wallMs)ms from viewDidLoad)")

                case "error":
                    let msg  = dict["message"]  as? String ?? ""
                    let file = dict["filename"] as? String ?? ""
                    let line = dict["lineno"]   as? Int    ?? 0
                    print("[GamePlayer][JS ERROR] \(msg) @ \(file):\(line)")

                default:
                    print("[GamePlayer][JS] \(dict)")
                }
            }

        case "rpgTranslate":
            // M5: TranslationBridge.js gửi text cần dịch.
            if let dict = message.body as? [String: Any],
               let text = dict["text"] as? String,
               !text.isEmpty {
                print("[GamePlayer][Translation] Received text (\(text.count) chars)")
                DispatchQueue.main.async { [weak self] in
                    self?.translationOverlay?.receiveText(text)
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
        let gameID  = entry.id
        DispatchQueue.global(qos: .utility).async {
            do {
                try value.write(to: fileURL, atomically: true, encoding: .utf8)
                print("[GamePlayer] 💾 Saved: \(key)")
                // M3: Trigger iCloud sync after save (no-op if iCloud unavailable)
                Task { @MainActor in
                    await CloudSaveManager.shared.syncGameSaves(for: gameID)
                }
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
