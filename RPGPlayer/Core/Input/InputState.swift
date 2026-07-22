// RPGPlayer/Core/Input/InputState.swift
//
// Shared input state snapshot for a single game frame.
// Used by both EngineWeb (via GamepadBridge.js) and EngineRGSS (via rgss_input_bridge).
//
// Design rationale:
//   - Value type (struct) for safe, zero-copy snapshots across thread boundaries.
//   - D-pad is digital-only (4 Bool flags); dpadX/dpadY are derived floats for
//     engines that want axis-style values (Gamepad API, analog-style bridge).
//   - L2/R2 stored as Float (0.0–1.0) for faithful Gamepad API mapping; a
//     l2Pressed/r2Pressed helper applies a 0.5 threshold for RGSS digital mapping.

import Foundation

// MARK: - InputState

/// Complete controller/touch input state for one game frame.
struct InputState: Equatable {

    // MARK: D-pad (digital cross — landscape layout)
    var dpadUp:    Bool = false
    var dpadDown:  Bool = false
    var dpadLeft:  Bool = false
    var dpadRight: Bool = false

    /// Horizontal axis derived from digital D-pad: left = -1.0, right = +1.0.
    var dpadX: Float { (dpadRight ? 1.0 : 0.0) - (dpadLeft ? 1.0 : 0.0) }

    /// Vertical axis derived from digital D-pad: up = -1.0, down = +1.0.
    /// (Down is positive to match RGSS coordinate convention.)
    var dpadY: Float { (dpadDown ? 1.0 : 0.0) - (dpadUp ? 1.0 : 0.0) }

    // MARK: Face buttons
    /// South button (GCController buttonA) — maps to RGSS C (confirm).
    var buttonA: Bool = false

    /// East button (GCController buttonB) — maps to RGSS B (cancel).
    var buttonB: Bool = false

    /// West button (GCController buttonX) — maps to RGSS A (shift-like).
    var buttonC: Bool = false

    /// North button (GCController buttonY) — maps to RGSS X.
    var buttonD: Bool = false

    // MARK: Shoulder / Trigger
    var l1: Bool  = false   // Left bumper  — maps to RGSS L
    var r1: Bool  = false   // Right bumper — maps to RGSS R

    /// Left trigger analog value 0.0–1.0.
    var l2: Float = 0.0

    /// Right trigger analog value 0.0–1.0.
    var r2: Float = 0.0

    /// Digital threshold (0.5) applied to l2 for RGSS mapping.
    var l2Pressed: Bool { l2 > 0.5 }

    /// Digital threshold (0.5) applied to r2 for RGSS mapping.
    var r2Pressed: Bool { r2 > 0.5 }

    // MARK: Menu
    var start:  Bool = false   // Maps to RGSS F9 (often used as menu/fast-forward)
    var select: Bool = false   // Maps to RGSS F6

    // MARK: Convenience
    /// Fully neutral (no buttons pressed) state.
    static let neutral = InputState()
}
