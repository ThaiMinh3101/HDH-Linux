// RPGPlayer/EngineRGSS/mruby_bridge.h
//
// Clean-room RGSS C bridge — M1b "Hello Sprite"
//
// Behavior specification source:
//   - RGSS Reference Manual (offline help bundled with RPG Maker XP/VX/VX Ace)
//   - Public RGSS class documentation (Sprite, Bitmap behavior)
//   NO source code from mkxp, mkxp-z, or any GPL/LGPL RGSS implementation was
//   referenced when writing this file.
//
// License for mruby: MIT (https://github.com/mruby/mruby/blob/master/LICENSE)

#ifndef MRUBY_BRIDGE_H
#define MRUBY_BRIDGE_H

#include <mruby.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Callback types
// ---------------------------------------------------------------------------

/// Called when Ruby code executes `sprite.bitmap = "path/to/image.png"`.
/// `path` is a valid UTF-8 C string owned by the mruby heap.
/// The callback is invoked on whichever thread called mrb_bridge_run_script().
/// The Swift implementation must copy `path` before returning if it needs it.
typedef void (*SpriteSetBitmapCallback)(const char *path);

// ---------------------------------------------------------------------------
// VM setup
// ---------------------------------------------------------------------------

/// Register the RGSS Sprite class in the mruby VM.
/// Must be called once, after mrb_open() and before running any RGSS script.
///
/// Defines (M1b scope):
///   Sprite.new             — creates a Sprite object
///   Sprite#bitmap=(path)   — invokes bitmap_callback with the image path
///   Sprite#bitmap          — returns the last path set (as String)
///
/// Future milestones will add: x, y, z, opacity, visible, viewport, etc.
void mrb_define_sprite_class(mrb_state *mrb,
                              SpriteSetBitmapCallback bitmap_callback);

// ---------------------------------------------------------------------------
// Script execution
// ---------------------------------------------------------------------------

/// Execute a Ruby script string in the given mrb_state.
///
/// Returns 0 on success, -1 if a Ruby exception was raised.
/// On error, call mrb_bridge_last_error() immediately to retrieve the
/// exception message (the buffer is overwritten on the next call).
int mrb_bridge_run_script(mrb_state *mrb, const char *script);

/// Return a C string describing the last error from mrb_bridge_run_script().
/// Valid until the next call to mrb_bridge_run_script() or mrb_bridge_last_error().
/// Never returns NULL (returns "" if no error).
const char *mrb_bridge_last_error(mrb_state *mrb);

#ifdef __cplusplus
}
#endif

#endif // MRUBY_BRIDGE_H
