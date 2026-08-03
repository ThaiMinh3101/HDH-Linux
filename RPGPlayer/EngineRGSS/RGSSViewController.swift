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

    // MARK: - Private properties

    private var mtkView: MTKView!
    private var renderer: SpriteRenderer!
    private var rubyBridge: RubyBridge!

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

        // TODO (future milestone): advance the mruby scene loop one frame here
        // (Graphics.update, scene switching, etc.).
    }

    // MARK: - Ruby engine

    private func startRubyEngine() {
        guard renderer != nil else { return }

        rubyBridge = RubyBridge()

        // M1b test script — behaviour matches RGSS3 "class Sprite" documentation:
        //   Sprite.new        → creates a sprite (no viewport needed for proof)
        //   sprite.bitmap =   → triggers Metal texture load via C callback
        //
        // In later milestones this block is replaced by loading Game.rb / Scripts.rxdata.
        let testScript = """
        # M1b — Hello Sprite: proves Ruby → C bridge → Metal pipeline
        sprite = Sprite.new
        sprite.bitmap = "test.png"

        # M2 — Input sanity check (runs once at load time, not per-frame)
        # In a real game these would be called inside a loop driven by Graphics.update.
        puts "Input::DOWN = #{Input::DOWN}"
        puts "Input::C    = #{Input::C}"
        """

        let capturedBridge   = rubyBridge!
        let capturedRenderer = renderer!

        DispatchQueue.global(qos: .userInitiated).async {
            capturedBridge.start(script: testScript, renderer: capturedRenderer)
        }
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
