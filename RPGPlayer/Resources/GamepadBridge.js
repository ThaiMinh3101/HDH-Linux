/**
 * GamepadBridge.js — RPGPlayer M2
 *
 * Injects a W3C-compatible Gamepad API shim into RPG Maker MV / MZ WebViews.
 *
 * How it works:
 *   1. Overrides navigator.getGamepads() to return a single fake Gamepad object.
 *   2. Exposes window.__rpgUpdateGamepad(stateJSON) which Swift calls each frame
 *      (via WKWebView.evaluateJavaScript) whenever the merged InputState changes.
 *   3. Dispatches a synthetic "gamepadconnected" event the first time an update
 *      arrives, so MV/MZ game engines detect the controller automatically.
 *
 * Standard Gamepad button layout (W3C "standard" mapping):
 *   Index  Label        InputState field
 *   ─────────────────────────────────────
 *     0    A (South)    buttonA  (RGSS confirm / MV: OK)
 *     1    B (East)     buttonB  (RGSS cancel  / MV: Cancel)
 *     2    X (West)     buttonC  (RGSS A-shift / MV: Shift)
 *     3    Y (North)    buttonD  (RGSS X)
 *     4    LB           l1
 *     5    RB           r1
 *     6    LT           l2  (analog value)
 *     7    RT           r2  (analog value)
 *     8    Select       select
 *     9    Start        start
 *    10    L3           — (always 0, not mapped)
 *    11    R3           — (always 0, not mapped)
 *    12    D-Up         dpadUp
 *    13    D-Down       dpadDown
 *    14    D-Left       dpadLeft
 *    15    D-Right      dpadRight
 *
 * Axes (4 axes, standard mapping):
 *   0  Left stick X  (dpadX: -1=left, +1=right)
 *   1  Left stick Y  (dpadY: -1=up,   +1=down)
 *   2  Right stick X (always 0 — not mapped in M2)
 *   3  Right stick Y (always 0 — not mapped in M2)
 */

(function () {
    'use strict';

    // ── Internal state ───────────────────────────────────────────────────────

    var NUM_BUTTONS = 16;
    var NUM_AXES    = 4;

    function makeButton(value, pressed) {
        return { value: value, pressed: pressed, touched: pressed };
    }

    var _buttons = [];
    var _axes    = [0, 0, 0, 0];
    var _timestamp = 0;
    var _connected = false;

    for (var i = 0; i < NUM_BUTTONS; i++) {
        _buttons.push(makeButton(0, false));
    }

    // ── Gamepad object snapshot (returned by getGamepads) ───────────────────

    function makeGamepadSnapshot() {
        return {
            id:        'RPGPlayer Virtual Gamepad (Standard)',
            index:     0,
            connected: _connected,
            timestamp: _timestamp,
            mapping:   'standard',
            axes:      _axes.slice(),         // immutable snapshot
            buttons:   _buttons.map(function (b) {
                           return { value: b.value, pressed: b.pressed, touched: b.touched };
                       })
        };
    }

    // ── Override navigator.getGamepads ───────────────────────────────────────

    var _realGetGamepads = navigator.getGamepads
        ? navigator.getGamepads.bind(navigator)
        : null;

    Object.defineProperty(navigator, 'getGamepads', {
        value: function () {
            // Return our virtual gamepad in slot 0; fill remaining slots with null.
            var pads = [makeGamepadSnapshot(), null, null, null];
            return pads;
        },
        writable: true,
        configurable: true
    });

    // ── Swift → JS update bridge ─────────────────────────────────────────────

    /**
     * Called by Swift (WKWebView.evaluateJavaScript) each frame when input changes.
     *
     * @param {Object} state  Plain JSON object matching Swift InputState fields:
     *   { dpadUp, dpadDown, dpadLeft, dpadRight,
     *     buttonA, buttonB, buttonC, buttonD,
     *     l1, r1, l2, r2, start, select }
     */
    window.__rpgUpdateGamepad = function (state) {
        if (!state) return;

        var wasConnected = _connected;
        _connected  = true;
        _timestamp  = (typeof performance !== 'undefined') ? performance.now() : Date.now();

        // ── Map InputState → button array ────────────────────────────────────
        _buttons[0]  = makeButton(state.buttonA  ? 1 : 0, !!state.buttonA);   // A / confirm
        _buttons[1]  = makeButton(state.buttonB  ? 1 : 0, !!state.buttonB);   // B / cancel
        _buttons[2]  = makeButton(state.buttonC  ? 1 : 0, !!state.buttonC);   // X / shift
        _buttons[3]  = makeButton(state.buttonD  ? 1 : 0, !!state.buttonD);   // Y
        _buttons[4]  = makeButton(state.l1       ? 1 : 0, !!state.l1);        // LB
        _buttons[5]  = makeButton(state.r1       ? 1 : 0, !!state.r1);        // RB
        _buttons[6]  = makeButton(state.l2 || 0,          (state.l2 || 0) > 0.5); // LT analog
        _buttons[7]  = makeButton(state.r2 || 0,          (state.r2 || 0) > 0.5); // RT analog
        _buttons[8]  = makeButton(state.select   ? 1 : 0, !!state.select);    // Select
        _buttons[9]  = makeButton(state.start    ? 1 : 0, !!state.start);     // Start
        _buttons[10] = makeButton(0, false);   // L3 — not mapped
        _buttons[11] = makeButton(0, false);   // R3 — not mapped
        _buttons[12] = makeButton(state.dpadUp    ? 1 : 0, !!state.dpadUp);
        _buttons[13] = makeButton(state.dpadDown  ? 1 : 0, !!state.dpadDown);
        _buttons[14] = makeButton(state.dpadLeft  ? 1 : 0, !!state.dpadLeft);
        _buttons[15] = makeButton(state.dpadRight ? 1 : 0, !!state.dpadRight);

        // ── Map InputState → axes ────────────────────────────────────────────
        // Axis 0: left-stick X from D-pad (−1 = left, +1 = right)
        _axes[0] = (state.dpadRight ? 1 : 0) - (state.dpadLeft ? 1 : 0);
        // Axis 1: left-stick Y from D-pad (−1 = up, +1 = down, W3C convention)
        _axes[1] = (state.dpadDown  ? 1 : 0) - (state.dpadUp   ? 1 : 0);
        _axes[2] = 0;
        _axes[3] = 0;

        // ── Dispatch gamepadconnected on first update ─────────────────────────
        if (!wasConnected) {
            try {
                var event = new GamepadEvent('gamepadconnected', {
                    gamepad: makeGamepadSnapshot()
                });
                window.dispatchEvent(event);
                console.log('[RPGPlayer] GamepadBridge: gamepadconnected event dispatched');
            } catch (e) {
                console.warn('[RPGPlayer] GamepadBridge: could not dispatch gamepadconnected:', e);
            }
        }
    };

    // ── Map virtual D-pad → keyboard events (fallback for games with no Gamepad API) ──
    //
    // RPG Maker MV/MZ also listens to keyboard events via Input._onKeyDown/Up.
    // We synthesize Arrow Key / Enter / Escape events for games that only use keyboard.
    // This ensures compatibility with older MV games that don't check navigator.getGamepads().

    var _prevState = {};

    var KEY_MAP = {
        dpadUp:    { code: 'ArrowUp',    keyCode: 38 },
        dpadDown:  { code: 'ArrowDown',  keyCode: 40 },
        dpadLeft:  { code: 'ArrowLeft',  keyCode: 37 },
        dpadRight: { code: 'ArrowRight', keyCode: 39 },
        buttonA:   { code: 'Enter',      keyCode: 13 },   // Confirm (RGSS C)
        buttonB:   { code: 'Escape',     keyCode: 27 },   // Cancel  (RGSS B)
        buttonC:   { code: 'ShiftLeft',  keyCode: 16 },   // Shift   (RGSS A / West / X button)
        buttonD:   { code: 'KeyZ',       keyCode: 90 },   // Z key   (RGSS X / North / Y button)
        start:     { code: 'Enter',      keyCode: 13 },   // duplicate of A for safety
        select:    { code: 'Escape',     keyCode: 27 }
    };

    function fireKey(type, keyInfo) {
        try {
            var event = new KeyboardEvent(type, {
                bubbles:    true,
                cancelable: true,
                code:       keyInfo.code,
                keyCode:    keyInfo.keyCode,
                which:      keyInfo.keyCode
            });
            document.dispatchEvent(event);
        } catch (e) { /* ignore */ }
    }

    /**
     * Called by Swift alongside __rpgUpdateGamepad to synthesize keyboard events
     * for games that rely on keyboard input rather than Gamepad API.
     * Swift SHOULD call this from the same evaluateJavaScript block.
     */
    window.__rpgUpdateGamepadKeys = function (state) {
        if (!state) return;
        Object.keys(KEY_MAP).forEach(function (field) {
            var cur  = !!state[field];
            var prev = !!_prevState[field];
            var info = KEY_MAP[field];
            if (cur && !prev) { fireKey('keydown', info); }
            if (!cur && prev) { fireKey('keyup',   info); }
        });
        _prevState = state;
    };

    console.log('[RPGPlayer] GamepadBridge.js loaded — virtual Gamepad API active');

}());
