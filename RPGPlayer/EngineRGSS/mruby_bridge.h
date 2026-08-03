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
#include <stddef.h>

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

/// Execute a Ruby script of explicit length (binary-safe: script may contain
/// NUL bytes). This is the M6.0 entry point used when loading decompressed
/// RGSS scripts from Scripts.rvdata2.
///
/// Returns 0 on success, -1 if a Ruby exception was raised.
/// `is_syntax_error` (optional, may be NULL) is set to 1 when the raised
/// exception is kind_of? SyntaxError, 0 otherwise. This lets Swift distinguish
/// a parse failure (game script is corrupt — hard error) from a runtime failure
/// (binding not yet implemented — expected warning during M6).
int mrb_bridge_load_nstring(mrb_state *mrb, const char *script, size_t len,
                            int *is_syntax_error);

/// Return a C string describing the last error from mrb_bridge_run_script()
/// or mrb_bridge_load_nstring().
/// Valid until the next call to either function or mrb_bridge_last_error().
/// Never returns NULL (returns "" if no error).
const char *mrb_bridge_last_error(mrb_state *mrb);

/// Set a Ruby global variable to a binary string (may contain NUL bytes).
/// Used by unit tests to pass synthetic Marshal bytes into a test script:
///   mrb_bridge_set_global_string(mrb, "__test_data", bytes, len);
///   # in Ruby:  data = $__test_data
void mrb_bridge_set_global_string(mrb_state *mrb, const char *name,
                                  const char *data, size_t len);

/// Call a niladic method on the top-level Object (e.g. "advance_frame").
/// M6.2: used as the per-frame hook from CADisplayLink — avoids re-parsing
/// a Ruby script every frame. The method must be defined on Object (or be a
/// global function) and take no arguments.
///
/// Returns 0 on success, -1 if a Ruby exception was raised (message available
/// via mrb_bridge_last_error()). Safe to call when the method is undefined —
/// returns -1 and logs a warning, does not crash.
int mrb_bridge_call_global(mrb_state *mrb, const char *method_name);

#ifdef __cplusplus
}
#endif

#endif // MRUBY_BRIDGE_H
