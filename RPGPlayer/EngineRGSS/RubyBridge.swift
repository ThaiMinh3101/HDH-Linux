// RPGPlayer/EngineRGSS/RubyBridge.swift
//
// Swift wrapper around the mruby VM.
// Manages VM lifecycle and routes RGSS Ruby API callbacks to the Metal renderer.

import Foundation

// ---------------------------------------------------------------------------
// MARK: - Global renderer reference (C-callback boundary)
//
// @convention(c) closures cannot capture variables from their enclosing scope.
// We store the renderer in a module-level global so the C callback can reach it.
// Lifecycle: assigned in start(), cleared in deinit.
// ---------------------------------------------------------------------------
private var _rgssRenderer: SpriteRenderer?

// ---------------------------------------------------------------------------
// MARK: - RubyBridge
// ---------------------------------------------------------------------------

/// Initialises the mruby VM, registers RGSS classes, and executes Ruby scripts.
///
/// Thread safety: `start()` is designed to be called from a background thread.
/// The C callback dispatches renderer calls back to the main thread.
final class RubyBridge {

    // Opaque pointer to mrb_state (mruby VM)
    private var mrb: OpaquePointer?

    // MARK: - Lifecycle

    init() {}

    deinit {
        _rgssRenderer = nil
        if let mrb = mrb {
            mrb_close(mrb)
        }
    }

    // MARK: - Start

    /// Boot the mruby VM and run `script`, routing any `Sprite#bitmap=` calls
    /// to `renderer` via a Metal texture load.
    ///
    /// - Parameters:
    ///   - script: Ruby source code (RGSS-compatible).
    ///   - renderer: The Metal renderer that RGSS Sprite calls will drive.
    func start(script: String, renderer: SpriteRenderer) {
        guard mrb == nil else {
            print("[RubyBridge] ⚠️  VM already running — ignoring duplicate start()")
            return
        }

        // Store globally for C callback (no captures allowed in @convention(c))
        _rgssRenderer = renderer

        // Open mruby VM
        guard let mrbPtr = mrb_open() else {
            print("[RubyBridge] ❌ mrb_open() failed — cannot allocate mruby VM")
            return
        }
        mrb = mrbPtr
        print("[RubyBridge] ✅ mruby VM opened")

        // ---------------------------------------------------------------------------
        // Register RGSS Sprite class.
        // The callback is a @convention(c) closure: no local variable captures.
        // It accesses _rgssRenderer via the module global defined above.
        // ---------------------------------------------------------------------------
        let bitmapCallback: SpriteSetBitmapCallback = { pathPtr in
            guard let pathPtr = pathPtr else { return }
            // Copy path before any GC could move mruby heap objects
            let path = String(cString: pathPtr)
            DispatchQueue.main.async {
                _rgssRenderer?.loadTexture(named: path)
            }
        }
        mrb_define_sprite_class(mrbPtr, bitmapCallback)
        print("[RubyBridge] ✅ RGSS classes registered: Sprite")

        // ---------------------------------------------------------------------------
        // Execute script
        // ---------------------------------------------------------------------------
        let rc = script.withCString { cStr in
            mrb_bridge_run_script(mrbPtr, cStr)
        }

        if rc == 0 {
            print("[RubyBridge] ✅ Script executed successfully")
        } else {
            let errMsg = String(cString: mrb_bridge_last_error(mrbPtr))
            print("[RubyBridge] ❌ Ruby exception: \(errMsg)")
            // Non-fatal for M1b — renderer may still have loaded a fallback texture
        }
    }
}
