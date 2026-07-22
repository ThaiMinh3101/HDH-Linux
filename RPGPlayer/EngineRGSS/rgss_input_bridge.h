// RPGPlayer/EngineRGSS/rgss_input_bridge.h
//
// Clean-room RGSS Input module — Milestone 2
//
// Behavior specification source:
//   RGSS Reference Manual (offline help bundled with RPG Maker XP / VX / VX Ace).
//   Describes: Input module, trigger?, press?, repeat?, dir4, dir8, button constants.
//   NO source code from mkxp, mkxp-z, or any GPL/LGPL RGSS implementation was
//   read or referenced when writing this file.
//
// Gamepad → RGSS button mapping is an independent design choice by this project.

#ifndef RGSS_INPUT_BRIDGE_H
#define RGSS_INPUT_BRIDGE_H

#include <mruby.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// RGSSInputState — mirrors Swift InputState layout for cross-language passing.
// Passed by pointer; fields must stay in sync with InputState.swift.
// ---------------------------------------------------------------------------

typedef struct {
    bool  dpad_up;
    bool  dpad_down;
    bool  dpad_left;
    bool  dpad_right;
    bool  button_a;   // South  — RGSS C (confirm)
    bool  button_b;   // East   — RGSS B (cancel)
    bool  button_c;   // West   — RGSS A (shift-like)
    bool  button_d;   // North  — RGSS X
    bool  l1;         // Left bumper  — RGSS L
    bool  r1;         // Right bumper — RGSS R
    float l2;         // Left trigger  0.0–1.0
    float r2;         // Right trigger 0.0–1.0
    bool  start;      // Menu   — RGSS F9
    bool  select;     // Select — RGSS F6
} RGSSInputState;

// ---------------------------------------------------------------------------
// Frame update
// ---------------------------------------------------------------------------

/// Feed the current frame's input into the RGSS Input module.
/// Must be called ONCE per frame, before Ruby scripts call Input.trigger?/press?/repeat?.
/// Typically invoked from a CADisplayLink callback on the main thread.
void rgss_input_update(const RGSSInputState *state);

// ---------------------------------------------------------------------------
// mruby module registration
// ---------------------------------------------------------------------------

/// Define the RGSS Input module (constants + methods) in the given mruby VM.
/// Call once after mrb_open(), before running any RGSS script.
void mrb_define_input_module(mrb_state *mrb);

#ifdef __cplusplus
}
#endif

#endif // RGSS_INPUT_BRIDGE_H
