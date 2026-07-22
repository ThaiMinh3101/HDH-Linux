// RPGPlayer/Core/Input/GamepadManager.swift
//
// Singleton that bridges GCController (GameController framework) into InputState.
//
// Architecture:
//   - All @Published mutation happens on @MainActor (main thread).
//   - GCController valueChangedHandler fires on an internal GCController queue;
//     we dispatch back to main before writing state.
//   - VirtualDpadHostView writes to touchInput directly on the main thread.
//   - mergedInput = gamepadInput if a controller is connected, touchInput otherwise.

import GameController
import Combine

// MARK: - GamepadManager

@MainActor
final class GamepadManager: ObservableObject {

    // MARK: Singleton
    static let shared = GamepadManager()

    // MARK: Published state (consumed by SwiftUI and engine layers)

    /// True when at least one GCExtendedGamepad controller is connected.
    @Published private(set) var isGamepadConnected = false

    /// Most recent state polled from the physical controller.
    @Published private(set) var gamepadInput = InputState.neutral

    // MARK: Touch input (written by VirtualDpadHostView on main thread)

    /// State injected by the on-screen virtual D-pad.
    var touchInput = InputState.neutral

    // MARK: Merged input

    /// The authoritative input state for the current frame.
    /// Gamepad takes priority when a physical controller is connected.
    var mergedInput: InputState {
        isGamepadConnected ? gamepadInput : touchInput
    }

    // MARK: Private
    private var connectedController: GCController?
    private var cancellables = Set<AnyCancellable>()

    // MARK: Init
    private init() {
        setupNotifications()
        // Adopt any controller that is already connected when the app launches.
        if let existing = GCController.controllers().first(where: { $0.extendedGamepad != nil }) {
            connect(existing)
        }
    }

    // MARK: - Notification setup

    private func setupNotifications() {
        NotificationCenter.default
            .publisher(for: .GCControllerDidConnect)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let ctrl = note.object as? GCController else { return }
                self?.connect(ctrl)
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .GCControllerDidDisconnect)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let ctrl = note.object as? GCController else { return }
                self?.disconnect(ctrl)
            }
            .store(in: &cancellables)
    }

    // MARK: - Connect / Disconnect

    private func connect(_ controller: GCController) {
        guard controller.extendedGamepad != nil else {
            print("[GamepadManager] ℹ️ Ignoring non-extended controller: \(controller.vendorName ?? "?")")
            return
        }
        connectedController = controller
        isGamepadConnected  = true
        print("[GamepadManager] ✅ Controller connected: \(controller.vendorName ?? "Unknown")")
        bindValueChangedHandler(to: controller)
    }

    private func disconnect(_ controller: GCController) {
        guard connectedController === controller else { return }
        connectedController = nil
        isGamepadConnected  = false
        gamepadInput        = .neutral
        print("[GamepadManager] ⚡ Controller disconnected")
        // Fall back to another connected extended gamepad, if any.
        if let fallback = GCController.controllers().first(where: { $0.extendedGamepad != nil }) {
            connect(fallback)
        }
    }

    // MARK: - Value changed handler

    private func bindValueChangedHandler(to controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }

        // Axis dead-zone: values with absolute value below this are treated as 0.
        let deadZone: Float = 0.15

        gamepad.valueChangedHandler = { [weak self] _, _ in
            // valueChangedHandler may fire on any thread; snapshot and dispatch to main.
            let snapshot = Self.buildState(from: gamepad, deadZone: deadZone)
            DispatchQueue.main.async {
                self?.gamepadInput = snapshot
            }
        }
    }

    // MARK: - State builder (nonisolated — called from GCController callback thread)

    private static func buildState(from gamepad: GCExtendedGamepad, deadZone: Float) -> InputState {
        var s = InputState()

        // ── D-pad ──────────────────────────────────────────────────────────────
        s.dpadUp    = gamepad.dpad.up.isPressed
        s.dpadDown  = gamepad.dpad.down.isPressed
        s.dpadLeft  = gamepad.dpad.left.isPressed
        s.dpadRight = gamepad.dpad.right.isPressed

        // Left analog stick also acts as D-pad (common RPG game expectation).
        let lx = gamepad.leftThumbstick.xAxis.value
        let ly = gamepad.leftThumbstick.yAxis.value
        // GCController: +Y = up (opposite of UIKit), so ly > deadZone means UP.
        if lx < -deadZone { s.dpadLeft  = true }
        if lx >  deadZone { s.dpadRight = true }
        if ly >  deadZone { s.dpadUp    = true }
        if ly < -deadZone { s.dpadDown  = true }

        // ── Face buttons ──────────────────────────────────────────────────────
        // GCController naming: buttonA=South, buttonB=East, buttonX=West, buttonY=North.
        s.buttonA = gamepad.buttonA.isPressed   // South / RGSS C (confirm)
        s.buttonB = gamepad.buttonB.isPressed   // East  / RGSS B (cancel)
        s.buttonC = gamepad.buttonX.isPressed   // West  / RGSS A (shift-like)
        s.buttonD = gamepad.buttonY.isPressed   // North / RGSS X

        // ── Shoulders / Triggers ──────────────────────────────────────────────
        s.l1 = gamepad.leftShoulder.isPressed
        s.r1 = gamepad.rightShoulder.isPressed
        s.l2 = gamepad.leftTrigger.value
        s.r2 = gamepad.rightTrigger.value

        // ── Menu buttons ──────────────────────────────────────────────────────
        s.start  = gamepad.buttonMenu.isPressed
        // buttonOptions is available on most modern controllers (PS: Options/Select).
        s.select = gamepad.buttonOptions?.isPressed ?? false

        return s
    }
}
