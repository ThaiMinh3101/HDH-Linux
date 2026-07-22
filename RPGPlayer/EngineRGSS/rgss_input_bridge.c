// RPGPlayer/EngineRGSS/rgss_input_bridge.c
//
// Clean-room RGSS Input module implementation — Milestone 2
//
// Behavior specification source:
//   RGSS Reference Manual (offline help bundled with RPG Maker XP / VX / VX Ace).
//   Describes: Input.trigger?, Input.press?, Input.repeat?, Input.dir4, Input.dir8,
//   Input.update, and the numeric button constants.
//   NO source code from mkxp, mkxp-z, or any GPL/LGPL RGSS engine was
//   read or referenced when writing this implementation.
//
// Repeat timing constants are independent estimates based on macOS / Windows
// default system key-repeat settings.  The RGSS Reference Manual does not
// publish exact values.  These numbers are NOT taken from any RGSS engine source.

#include "rgss_input_bridge.h"
#include <mruby/class.h>
#include <mruby/value.h>
#include <mruby/variable.h>
#include <string.h>
#include <stdbool.h>

// ---------------------------------------------------------------------------
// RGSS Input button constants
// Source: RGSS Reference Manual ("Input" module section), public documentation.
// ---------------------------------------------------------------------------

#define RGSS_DOWN    2
#define RGSS_LEFT    4
#define RGSS_RIGHT   6
#define RGSS_UP      8
#define RGSS_A      11   // Shift-like (RGSS maps Shift key)
#define RGSS_B      12   // Cancel / Esc
#define RGSS_C      13   // Confirm / Enter / Z
#define RGSS_X      14
#define RGSS_Y      15
#define RGSS_Z      16
#define RGSS_L      17
#define RGSS_R      18
#define RGSS_SHIFT  21
#define RGSS_CTRL   22
#define RGSS_ALT    23
#define RGSS_F5     25
#define RGSS_F6     26
#define RGSS_F7     27
#define RGSS_F8     28
#define RGSS_F9     29

#define BUTTON_COUNT 30   // max constant index + 1

// ---------------------------------------------------------------------------
// Repeat timing — INDEPENDENT ESTIMATES, not from any RGSS implementation.
//
// Rationale: macOS System Preferences "Key Repeat" default ≈ 500 ms delay,
// ~100 ms interval.  Windows default is similar.  At 60 fps:
//   REPEAT_DELAY    = 30 frames ≈ 500 ms  (matches both OS defaults)
//   REPEAT_INTERVAL =  8 frames ≈ 133 ms  (mid-range, comfortable for RPG menus)
//
// These values have NOT been verified against the closed-source RPG Maker engine
// and may differ from the original.  Adjust if playtesting reveals discrepancy.
// ---------------------------------------------------------------------------

#define REPEAT_DELAY     30
#define REPEAT_INTERVAL   8

// ---------------------------------------------------------------------------
// Per-frame state
// ---------------------------------------------------------------------------

static bool current_frame[BUTTON_COUNT];    // pressed this frame
static bool previous_frame[BUTTON_COUNT];   // pressed last frame
static int  held_frames[BUTTON_COUNT];      // consecutive frames held

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Map a gamepad-derived input snapshot into the current_frame[] array.
/// Called at the start of rgss_input_update() before rolling previous/current.
static void map_input_to_buttons(const RGSSInputState *s, bool out[BUTTON_COUNT])
{
    memset(out, 0, sizeof(bool) * BUTTON_COUNT);

    if (s->dpad_down)  out[RGSS_DOWN]  = true;
    if (s->dpad_left)  out[RGSS_LEFT]  = true;
    if (s->dpad_right) out[RGSS_RIGHT] = true;
    if (s->dpad_up)    out[RGSS_UP]    = true;

    // Face buttons → RGSS action constants.
    // Mapping: A(South)=C(confirm), B(East)=B(cancel), C(West)=A(shift), D(North)=X.
    if (s->button_a)   out[RGSS_C]  = true;
    if (s->button_b)   out[RGSS_B]  = true;
    if (s->button_c)   out[RGSS_A]  = true;
    if (s->button_d)   out[RGSS_X]  = true;

    // Shoulders / triggers
    if (s->l1)         out[RGSS_L]  = true;
    if (s->r1)         out[RGSS_R]  = true;
    if (s->l2 > 0.5f)  out[RGSS_Y]  = true;   // L2 analog → RGSS Y
    if (s->r2 > 0.5f)  out[RGSS_Z]  = true;   // R2 analog → RGSS Z

    // Menu buttons
    if (s->start)      out[RGSS_F9] = true;
    if (s->select)     out[RGSS_F6] = true;
}

// ---------------------------------------------------------------------------
// Public: rgss_input_update
// ---------------------------------------------------------------------------

void rgss_input_update(const RGSSInputState *state)
{
    if (!state) {
        memset(previous_frame, 0, sizeof(previous_frame));
        memset(current_frame,  0, sizeof(current_frame));
        memset(held_frames,    0, sizeof(held_frames));
        return;
    }

    // Roll: current → previous
    memcpy(previous_frame, current_frame, sizeof(previous_frame));

    // Map new snapshot → current
    map_input_to_buttons(state, current_frame);

    // Update held-frame counters
    for (int i = 0; i < BUTTON_COUNT; i++) {
        if (current_frame[i]) {
            held_frames[i]++;
        } else {
            held_frames[i] = 0;
        }
    }
}

// ---------------------------------------------------------------------------
// trigger? / press? / repeat? — mruby method implementations
// Source: RGSS Reference Manual semantics for Input module methods.
// ---------------------------------------------------------------------------

/// Input.press?(button) → bool
/// True on every frame the button is held down.
static mrb_value
mrb_input_press(mrb_state *mrb, mrb_value self)
{
    mrb_int btn;
    mrb_get_args(mrb, "i", &btn);
    (void)self;
    if (btn < 0 || btn >= BUTTON_COUNT) return mrb_false_value();
    return mrb_bool_value(current_frame[btn]);
}

/// Input.trigger?(button) → bool
/// True only on the very first frame the button is pressed.
static mrb_value
mrb_input_trigger(mrb_state *mrb, mrb_value self)
{
    mrb_int btn;
    mrb_get_args(mrb, "i", &btn);
    (void)self;
    if (btn < 0 || btn >= BUTTON_COUNT) return mrb_false_value();
    bool triggered = current_frame[btn] && !previous_frame[btn];
    return mrb_bool_value(triggered);
}

/// Input.repeat?(button) → bool
/// True on trigger frame, then again after REPEAT_DELAY frames, every REPEAT_INTERVAL frames.
/// Timing is an independent estimate; see REPEAT_DELAY / REPEAT_INTERVAL constants above.
static mrb_value
mrb_input_repeat(mrb_state *mrb, mrb_value self)
{
    mrb_int btn;
    mrb_get_args(mrb, "i", &btn);
    (void)self;
    if (btn < 0 || btn >= BUTTON_COUNT) return mrb_false_value();

    int hf = held_frames[btn];
    bool is_trigger  = current_frame[btn] && !previous_frame[btn];
    bool is_repeating = current_frame[btn]
                        && (hf >= REPEAT_DELAY)
                        && ((hf - REPEAT_DELAY) % REPEAT_INTERVAL == 0);
    return mrb_bool_value(is_trigger || is_repeating);
}

/// Input.update  — called by the RGSS game loop each frame.
/// In this architecture rgss_input_update() is called from Swift (CADisplayLink),
/// so Input.update is a no-op here; kept for RGSS API compatibility.
static mrb_value
mrb_input_update_method(mrb_state *mrb, mrb_value self)
{
    (void)mrb; (void)self;
    return mrb_nil_value();
}

// ---------------------------------------------------------------------------
// dir4 / dir8
// Source: RGSS Reference Manual — Input.dir4 / Input.dir8 description.
// dir4 returns one of: 2 (down), 4 (left), 6 (right), 8 (up), 0 (none).
// When multiple directions pressed, priority order: down > left > right > up
// (arbitrary choice — RGSS Reference Manual specifies the return values but
//  not the exact priority when multiple keys are held simultaneously).
// ---------------------------------------------------------------------------

static mrb_value
mrb_input_dir4(mrb_state *mrb, mrb_value self)
{
    (void)mrb; (void)self;
    if (current_frame[RGSS_DOWN])  return mrb_fixnum_value(2);
    if (current_frame[RGSS_LEFT])  return mrb_fixnum_value(4);
    if (current_frame[RGSS_RIGHT]) return mrb_fixnum_value(6);
    if (current_frame[RGSS_UP])    return mrb_fixnum_value(8);
    return mrb_fixnum_value(0);
}

/// dir8: numpad-style 8-directional value.
/// Diagonals (e.g. down+right = 3) take priority over cardinals.
/// Values: 1=DL, 2=D, 3=DR, 4=L, 6=R, 7=UL, 8=U, 9=UR, 0=none.
static mrb_value
mrb_input_dir8(mrb_state *mrb, mrb_value self)
{
    (void)mrb; (void)self;
    bool d = current_frame[RGSS_DOWN];
    bool u = current_frame[RGSS_UP];
    bool l = current_frame[RGSS_LEFT];
    bool r = current_frame[RGSS_RIGHT];

    if (d && l) return mrb_fixnum_value(1);
    if (d && r) return mrb_fixnum_value(3);
    if (u && l) return mrb_fixnum_value(7);
    if (u && r) return mrb_fixnum_value(9);
    if (d)      return mrb_fixnum_value(2);
    if (l)      return mrb_fixnum_value(4);
    if (r)      return mrb_fixnum_value(6);
    if (u)      return mrb_fixnum_value(8);
    return mrb_fixnum_value(0);
}

// ---------------------------------------------------------------------------
// Public: mrb_define_input_module
// ---------------------------------------------------------------------------

void mrb_define_input_module(mrb_state *mrb)
{
    struct RClass *mod = mrb_define_module(mrb, "Input");

    // ── Button constants (source: RGSS Reference Manual) ─────────────────
    mrb_define_const(mrb, mod, "DOWN",  mrb_fixnum_value(RGSS_DOWN));
    mrb_define_const(mrb, mod, "LEFT",  mrb_fixnum_value(RGSS_LEFT));
    mrb_define_const(mrb, mod, "RIGHT", mrb_fixnum_value(RGSS_RIGHT));
    mrb_define_const(mrb, mod, "UP",    mrb_fixnum_value(RGSS_UP));
    mrb_define_const(mrb, mod, "A",     mrb_fixnum_value(RGSS_A));
    mrb_define_const(mrb, mod, "B",     mrb_fixnum_value(RGSS_B));
    mrb_define_const(mrb, mod, "C",     mrb_fixnum_value(RGSS_C));
    mrb_define_const(mrb, mod, "X",     mrb_fixnum_value(RGSS_X));
    mrb_define_const(mrb, mod, "Y",     mrb_fixnum_value(RGSS_Y));
    mrb_define_const(mrb, mod, "Z",     mrb_fixnum_value(RGSS_Z));
    mrb_define_const(mrb, mod, "L",     mrb_fixnum_value(RGSS_L));
    mrb_define_const(mrb, mod, "R",     mrb_fixnum_value(RGSS_R));
    mrb_define_const(mrb, mod, "SHIFT", mrb_fixnum_value(RGSS_SHIFT));
    mrb_define_const(mrb, mod, "CTRL",  mrb_fixnum_value(RGSS_CTRL));
    mrb_define_const(mrb, mod, "ALT",   mrb_fixnum_value(RGSS_ALT));
    mrb_define_const(mrb, mod, "F5",    mrb_fixnum_value(RGSS_F5));
    mrb_define_const(mrb, mod, "F6",    mrb_fixnum_value(RGSS_F6));
    mrb_define_const(mrb, mod, "F7",    mrb_fixnum_value(RGSS_F7));
    mrb_define_const(mrb, mod, "F8",    mrb_fixnum_value(RGSS_F8));
    mrb_define_const(mrb, mod, "F9",    mrb_fixnum_value(RGSS_F9));

    // ── Methods ───────────────────────────────────────────────────────────
    mrb_define_module_function(mrb, mod, "press?",   mrb_input_press,          MRB_ARGS_REQ(1));
    mrb_define_module_function(mrb, mod, "trigger?", mrb_input_trigger,        MRB_ARGS_REQ(1));
    mrb_define_module_function(mrb, mod, "repeat?",  mrb_input_repeat,         MRB_ARGS_REQ(1));
    mrb_define_module_function(mrb, mod, "update",   mrb_input_update_method,  MRB_ARGS_NONE());
    mrb_define_module_function(mrb, mod, "dir4",     mrb_input_dir4,           MRB_ARGS_NONE());
    mrb_define_module_function(mrb, mod, "dir8",     mrb_input_dir8,           MRB_ARGS_NONE());
}
