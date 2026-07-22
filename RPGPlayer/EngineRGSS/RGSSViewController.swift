// RPGPlayer/EngineRGSS/RGSSViewController.swift
//
// UIViewController that hosts the RGSS Metal renderer and mruby VM.
// M1b: runs the "Hello Sprite" test script to prove the full pipeline.

import UIKit
import MetalKit

final class RGSSViewController: UIViewController {

    // MARK: - Input properties

    /// Root folder of the RGSS game (used in future milestones to load Scripts).
    var gamePath: URL?

    // MARK: - Private properties

    private var mtkView: MTKView!
    private var renderer: SpriteRenderer!
    private var rubyBridge: RubyBridge!

    // MARK: - View lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard let device = MTLCreateSystemDefaultDevice() else {
            showError("Metal はこのデバイスではサポートされていません\nThis device does not support Metal.")
            return
        }

        guard setupMetal(device: device) else { return }
        startRubyEngine()
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
