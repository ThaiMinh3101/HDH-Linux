// RPGPlayer/EngineRGSS/RGSSViewController.swift
//
// UIViewController that hosts the RGSS Metal renderer and mruby VM.
// M1b: runs the "Hello Sprite" test script to prove the full pipeline.
// M2:  adds CADisplayLink frame loop for per-frame input update,
//      and VirtualDpadView overlay (hidden when physical gamepad is connected).
// M5:  adds TranslationOverlayHostingController subtitle overlay.
//      Translation text hook for RGSS Window_Message is a TODO —
//      will be wired up when Window_Message mruby binding is implemented.

import UIKit
import MetalKit
import Combine
import SwiftUI
import Translation

final class RGSSViewController: UIViewController {

    // MARK: - Input properties

    /// Root folder of the RGSS game (used in future milestones to load Scripts).
    var gamePath: URL?

    /// M5: GameEntry for translation overlay.
    /// Set by the presenter (LibraryView / GameDetailView) before pushing this VC.
    var gameEntryForTranslation: GameEntry?

    /// M8.1: Đánh dấu game đã dừng vì lỗi ENOENT (thiếu file RTP).
    /// Ngăn hiện alert nhiều lần + ngăn advanceFrame tiếp tục sau khi đã báo lỗi.
    private var hasShownENOENTAlert = false

    // MARK: - Private properties

     private var mtkView: MTKView!
     private var renderer: SpriteRenderer!
     private var rubyBridge: RubyBridge!
     /// M6.3: Tilemap renderer — vẽ map RGSS3 thành MTLTexture.
     private var tilemapRenderer: TilemapRenderer?
     /// M6.3: Đã render tilemap chưa (tránh render lại mỗi frame).
     private var tilemapRendered = false
     /// Nếu game thiếu file .rvdata2 hoặc tileset image → lỗi vĩnh viễn,
     /// không retry vô hạn (decode 16MB arena mỗi frame = tốn CPU).
     private var tilemapRenderFailed = false
     /// M6.4: Window renderer — vẽ Window RGSS3 (windowskin 9-slice + text).
     private var windowRenderer: WindowRenderer?

    /// CADisplayLink drives the per-frame input pump.
    /// Full RGSS scene loop (Graphics.update, scene switching) is a future milestone.
    private var displayLink: CADisplayLink?

    /// Hosting controller for the SwiftUI VirtualDpadView overlay.
    private var dpadHostingController: UIHostingController<VirtualDpadView>?

    /// Observation token for gamepad connection changes.
    private var gamepadCancellable: AnyCancellable?

    /// Exit button overlay (always visible, not gated by gamepad)
    private var exitHostVC: UIHostingController<ExitButtonView>?

    /// M5: Translation overlay — same subtitle-strip UI as GamePlayerViewController.
    private var translationOverlay: TranslationOverlayHostingController?

    // MARK: - View lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard let device = MTLCreateSystemDefaultDevice() else {
            showError("Metal はこのデバイスではサポートされていません\nThis device does not support Metal.")
            return
        }

        guard setupMetal(device: device) else { return }
        setupDpadOverlay()
        startDisplayLink()
        startRubyEngine()
        setupExitButton()         // Exit button — top-left, always visible
        // M5: Translation overlay setup
        // gamePath is set by the presenter before viewDidLoad if launching via LibraryStore.
        if let entry = gameEntryForTranslation {
            setupTranslationOverlay(entry: entry)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        displayLink?.isPaused = false
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        displayLink?.isPaused = true
    }

    deinit {
        displayLink?.invalidate()
    }

    override var prefersStatusBarHidden: Bool { true }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        // RGSS games default to landscape; fullscreen view hides the status bar.
        return [.landscapeLeft, .landscapeRight]
    }

    // MARK: - Metal setup

    /// Configures the MTKView and SpriteRenderer.
    /// Returns false and shows an error label if setup fails.
    @discardableResult
    private func setupMetal(device: MTLDevice) -> Bool {
        mtkView = MTKView(frame: view.bounds, device: device)
        mtkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mtkView.clearColor               = MTLClearColorMake(0.05, 0.05, 0.08, 1.0)
        mtkView.preferredFramesPerSecond = 60
        mtkView.enableSetNeedsDisplay    = false   // Continuous render loop
        view.addSubview(mtkView)

         guard let r = SpriteRenderer(device: device) else {
             showError("Metal renderer could not be initialised.")
             return false
         }
         renderer = r
         mtkView.delegate = renderer

         // M6.3: Tilemap renderer dùng chung device.
         tilemapRenderer = TilemapRenderer(device: device)
         windowRenderer = WindowRenderer(device: device)
         return true
     }

    // MARK: - Virtual D-pad overlay (M2)

    private func setupDpadOverlay() {
        let dpadView = VirtualDpadView()
        let hostVC   = UIHostingController(rootView: dpadView)
        hostVC.view.backgroundColor = .clear
        hostVC.view.isUserInteractionEnabled = true

        addChild(hostVC)
        hostVC.view.frame = view.bounds
        hostVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hostVC.view)   // On top of MTKView
        hostVC.didMove(toParent: self)
        dpadHostingController = hostVC

        // Observe gamepad connection to show/hide overlay.
        // VirtualDpadView itself reads isGamepadConnected, but we also log here.
        gamepadCancellable = GamepadManager.shared.$isGamepadConnected
            .receive(on: DispatchQueue.main)
            .sink { connected in
                print("[RGSSViewController] Gamepad connected: \(connected) → D-pad overlay \(connected ? "hidden" : "visible")")
            }
    }

    // MARK: - Exit button

    private func setupExitButton() {
        let exitView = ExitButtonView {
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
        view.addSubview(hostVC.view)
        hostVC.didMove(toParent: self)
        exitHostVC = hostVC
    }

    // MARK: - Translation overlay (M5)

    private func setupTranslationOverlay(entry: GameEntry) {
        let hostVC = TranslationOverlayHostingController(entry: entry)
        addChild(hostVC)
        hostVC.view.frame = view.bounds
        hostVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hostVC.view.backgroundColor = .clear
        hostVC.view.isUserInteractionEnabled = true
        view.addSubview(hostVC.view)  // On top of D-pad overlay
        hostVC.didMove(toParent: self)
        translationOverlay = hostVC
    }

    /// Gọi từ Window_Message mruby binding khi có text hiển thị.
    /// TODO: wire up khi Window_Message binding được implement.
    @MainActor
    func receiveTranslationText(_ text: String) {
        translationOverlay?.receiveText(text)
    }

    // MARK: - CADisplayLink (M2: input pump)

    private func startDisplayLink() {
        let link = CADisplayLink(target: self, selector: #selector(frameTick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Called once per display refresh (~60 fps).
    /// Feeds the current merged InputState into the C-level RGSS Input module.
    @objc private func frameTick(_ link: CADisplayLink) {
        // Snapshot the current merged input on the main thread.
        let state = GamepadManager.shared.mergedInput

        // Convert Swift InputState → C RGSSInputState and pump into the module.
        var cState = RGSSInputState(
            dpad_up:    state.dpadUp,
            dpad_down:  state.dpadDown,
            dpad_left:  state.dpadLeft,
            dpad_right: state.dpadRight,
            button_a:   state.buttonA,
            button_b:   state.buttonB,
            button_c:   state.buttonC,
            button_d:   state.buttonD,
            l1:         state.l1,
            r1:         state.r1,
            l2:         state.l2,
            r2:         state.r2,
            start:      state.start,
            select:     state.select
        )
        rgss_input_update(&cState)

         // M6.2: Advance the mruby scene loop one frame.
         // Calls `advance_frame` (niladic method on top-level Object) if defined.
         // Game script / test defines it to update Game_Player/Game_Map per frame.
         // M6.3 will replace this with a full Graphics.update + scene switching loop.
         rubyBridge?.advanceFrame()

         // M6.3: Render tilemap một lần sau khi VM đã load xong scripts.
         // Tilemap render cần gamePath + renderer — chạy trên main thread.
         if !tilemapRendered, let gamePath = gamePath {
             renderTilemapIfNeeded(gameRoot: gamePath)
         }
     }

     // MARK: - M6.3: Tilemap rendering

     /// Load map + tileset + system từ game sandbox, render tilemap qua
     /// TilemapRenderer, rồi set texture vào SpriteRenderer.
     /// Chạy trên main thread (sau khi VM đã load xong scripts).
     private func renderTilemapIfNeeded(gameRoot: URL) {
         guard !tilemapRendered, !tilemapRenderFailed,
               let tilemapRenderer = tilemapRenderer else { return }

         do {
             // Đọc System.rvdata2 → vị trí khởi đầu
             let system = try DataFileLoader.loadSystem(fromGameRoot: gameRoot)
             print("[RGSSViewController] ✅ System: start_map=\(system.startMapID) (\(system.startX),\(system.startY))")

             // Đọc MapXXX.rvdata2
             let map = try DataFileLoader.loadMap(fromGameRoot: gameRoot, mapID: system.startMapID)
             print("[RGSSViewController] ✅ Map \(system.startMapID): \(map.width)×\(map.height) tiles, tileset=\(map.tilesetID)")

             // Đọc Tilesets.rvdata2 → tìm tileset theo ID
             let tilesets = try DataFileLoader.loadTilesets(fromGameRoot: gameRoot)
             guard let tileset = tilesets.first(where: { $0.id == map.tilesetID }) else {
                 print("[RGSSViewController] ⚠️  Không tìm thấy tileset ID \(map.tilesetID)")
                 // Thiếu tileset = lỗi vĩnh viễn (game data thiếu) — không retry
                 tilemapRenderFailed = true
                 return
             }
             print("[RGSSViewController] ✅ Tileset \(tileset.id): \(tileset.tilesetNames.filter { !$0.isEmpty }.count) images")

             // Render tilemap
             if tilemapRenderer.render(map: map, tileset: tileset, gameRoot: gameRoot) {
                 renderer.setTilemapTexture(
                     tilemapRenderer.tilemapTexture,
                     mapWidth: map.width,
                     mapHeight: map.height,
                     viewSize: mtkView.bounds.size
                 )
                 tilemapRendered = true
             } else {
                 // Render thất bại (thiếu tileset image, texture decode lỗi) —
                 // lỗi vĩnh viễn, không retry mỗi frame
                 tilemapRenderFailed = true
             }
         } catch {
             print("[RGSSViewController] ⚠️  Không render được tilemap: \(error.localizedDescription)")
             // Không set tilemapRenderFailed = true — cho phép retry lần sau
             // (có thể game đang được import/không đầy đủ tại thời điểm này).
             // Lưu ý: retry chỉ chạy mỗi CADisplayLink tick cho tới khi thành
             // công — decode 16MB arena mỗi frame có thể gây frame drop.
             // TODO M6.4: đưa renderTilemap lên background thread.
         }
     }

     // MARK: - Ruby engine

    private func startRubyEngine() {
        guard renderer != nil else { return }

        rubyBridge = RubyBridge()

        // M8.1: ENOENT crash handler — khi game loop gặp lỗi thiếu file (RTP):
        // dừng displayLink + hiện alert "Game Error" + quay về Library.
        rubyBridge?.onENOENTError = { [weak self] fileName in
            guard let self, !self.hasShownENOENTAlert else { return }
            self.hasShownENOENTAlert = true

            DispatchQueue.main.async {
                self.displayLink?.isPaused = true
                self.presentMissingFileAlert(missingFile: fileName)
            }
        }

        let capturedBridge   = rubyBridge!
        let capturedRenderer = renderer!
        let capturedGamePath = gamePath

        DispatchQueue.global(qos: .userInitiated).async {
            // M6.0: Nếu có gamePath chứa Data/Scripts.rvdata2 → load script thật.
            // Ngược lại → fallback test script M1b (chứng minh pipeline).
            guard let gameRoot = capturedGamePath else {
                self.runHelloSpriteTest(bridge: capturedBridge, renderer: capturedRenderer)
                return
            }

            do {
                let scripts = try ScriptLoader.loadScripts(fromGameRoot: gameRoot)
                print("[RGSSViewController] ✅ Đã giải nén \(scripts.count) scripts từ Scripts.rvdata2")
                capturedBridge.start(renderer: capturedRenderer, scripts: scripts, gameRoot: capturedGamePath, windowRenderer: self.windowRenderer)
            } catch {
                print("[RGSSViewController] ❌ Không đọc được Scripts.rvdata2: \(error.localizedDescription)")
                print("[RGSSViewController] ⚠️  Fallback về Hello Sprite test script")
                self.runHelloSpriteTest(bridge: capturedBridge, renderer: capturedRenderer)
            }
        }
    }

    /// M1b test script — behaviour matches RGSS3 "class Sprite" documentation:
    ///   Sprite.new        → creates a sprite (no viewport needed for proof)
    ///   sprite.bitmap =   → triggers Metal texture load via C callback
    private func runHelloSpriteTest(bridge: RubyBridge, renderer: SpriteRenderer) {
        let testScript = """
        # M1b — Hello Sprite: proves Ruby → C bridge → Metal pipeline
        sprite = Sprite.new
        sprite.bitmap = "test.png"

        # M6.4 — Test Window_Message: hiển thị 1 message box text tĩnh.
        # Window_Base/Window_Message được load từ WindowClasses.rb (bundle).
        msg = Window_Message.new(40, 200, 400, 100)
        msg.start_message("Hello from RPG Player!\\nThis is a test message box.")

        # M2 — Input sanity check (runs once at load time, not per-frame)
        # In a real game these would be called inside a loop driven by Graphics.update.
        puts "Input::DOWN = #{Input::DOWN}"
        puts "Input::C    = #{Input::C}"
        """
        // M6.4: Truyền windowRenderer để test path vẽ window 9-slice + text
        // qua Metal (gameRoot nil → WindowRenderer dùng Bundle.main làm nguồn
        // assets, hiển thị placeholder texture nếu thiếu windowskin).
        bridge.start(script: testScript, renderer: renderer,
                     gameRoot: nil, windowRenderer: windowRenderer)
    }

    // MARK: - M8.1: ENOENT error alert

    /// Hiện alert "Game Error" khi game thiếu file (Errno::ENOENT — thường là
    /// asset RTP chưa được merge). User tap "Back to Library" → quay về Library
    /// mà không cần restart app.
    /// English message (giống tone Empo requirement).
    ///
    /// PHẢI gọi trên main thread — closure onENOENTError luôn được trigger từ
    /// advanceFrame (main thread) và ta bọc thêm DispatchQueue.main.async.
    private func presentMissingFileAlert(missingFile: String) {
        let alert = UIAlertController(
            title: "Game Error",
            message: """
            Missing file: \(missingFile)

            This game requires Run-Time Package assets.
            Merge Audio, Fonts and Graphics from the RPG Maker RTP into the game folder and re-import.
            """,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Back to Library", style: .default) { [weak self] _ in
            guard let self else { return }
            // Phần B.yêu cầu: pop hoặc dismiss tuỳ theo presentation.
            if let nav = self.navigationController {
                nav.popViewController(animated: true)
            } else {
                self.dismiss(animated: true)
            }
        })

        // Present trên VC đang hiển thị (tránh warning nếu có VC khác present).
        // `presentedViewController ?? self` luôn non-optional (self là UIViewController)
        // nên không dùng `if let` được — gán thẳng rồi present.
        let presenter = presentedViewController ?? self
        presenter.present(alert, animated: true)
    }

    // MARK: - Error display

    private func showError(_ message: String) {
        let label = UILabel()
        label.text                = "⚠️  \(message)"
        label.textColor           = .systemRed
        label.font                = .systemFont(ofSize: 15, weight: .medium)
        label.textAlignment       = .center
        label.numberOfLines       = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)
        ])
    }
}
