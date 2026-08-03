// RPGPlayer/EngineRGSS/mruby_bridge.c
//
// Clean-room RGSS C bridge — M1b "Hello Sprite"
//
// Behavior specification source:
//   - RGSS Reference Manual (RPG Maker XP/VX/VX Ace offline help)
//   - Public RGSS class documentation (class Sprite section)
//   NO source code from mkxp, mkxp-z, or any GPL/LGPL project was read
//   or referenced when writing this implementation.

#include "mruby_bridge.h"
#include <mruby/class.h>
#include <mruby/compile.h>
#include <mruby/data.h>
#include <mruby/string.h>
#include <mruby/value.h>
#include <mruby/variable.h> /* mrb_iv_set, mrb_iv_get */
#include <stdio.h>
#include <string.h>

// ---------------------------------------------------------------------------
// Module-level state (one mruby VM per process in M1b)
// ---------------------------------------------------------------------------

static SpriteSetBitmapCallback g_bitmap_callback = NULL;

// Stores the last exception message. Sized to hold typical Ruby backtraces.
static char g_last_error[2048] = {0};

// ---------------------------------------------------------------------------
// Sprite method implementations
// RGSS behavior reference: "class Sprite" in RGSS Reference Manual
// ---------------------------------------------------------------------------

/// Sprite.new([viewport])
/// RGSS: Creates a new Sprite. Optional viewport argument (M1b: accepted but
/// ignored).
static mrb_value mrb_sprite_initialize(mrb_state *mrb, mrb_value self) {
  // M1b: accept optional viewport arg to match RGSS call signature,
  // but do nothing with it yet.
  mrb_value viewport;
  mrb_get_args(mrb, "|o", &viewport);
  (void)viewport;
  return self;
}

/// Sprite#bitmap=(bitmap_or_path)
/// M1b: accepts a String path (later milestones will accept a Bitmap object).
/// RGSS: Sets the bitmap used for this sprite's display.
static mrb_value mrb_sprite_set_bitmap(mrb_state *mrb, mrb_value self) {
  mrb_value arg;
  mrb_get_args(mrb, "o", &arg);

  if (mrb_string_p(arg)) {
    const char *path = mrb_str_to_cstr(mrb, arg);
    // Notify Swift renderer synchronously on caller's thread.
    // Swift side must dispatch to main thread if GPU access is needed.
    if (g_bitmap_callback && path) {
      g_bitmap_callback(path);
    }
    // Store for Sprite#bitmap getter
    mrb_iv_set(mrb, self, mrb_intern_lit(mrb, "@_bitmap"), arg);
  } else {
    // Non-string arg (future: Bitmap object). Store as-is for compatibility.
    mrb_iv_set(mrb, self, mrb_intern_lit(mrb, "@_bitmap"), arg);
  }

  return arg;
}

/// Sprite#bitmap
/// RGSS: Returns the bitmap currently set on this sprite.
static mrb_value mrb_sprite_get_bitmap(mrb_state *mrb, mrb_value self) {
  return mrb_iv_get(mrb, self, mrb_intern_lit(mrb, "@_bitmap"));
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

void mrb_define_sprite_class(mrb_state *mrb,
                             SpriteSetBitmapCallback bitmap_callback) {
  g_bitmap_callback = bitmap_callback;

  struct RClass *sprite_class =
      mrb_define_class(mrb, "Sprite", mrb->object_class);
  MRB_SET_INSTANCE_TT(sprite_class, MRB_TT_OBJECT);

  mrb_define_method(mrb, sprite_class, "initialize", mrb_sprite_initialize,
                    MRB_ARGS_OPT(1));
  mrb_define_method(mrb, sprite_class, "bitmap=", mrb_sprite_set_bitmap,
                    MRB_ARGS_REQ(1));
  mrb_define_method(mrb, sprite_class, "bitmap", mrb_sprite_get_bitmap,
                    MRB_ARGS_NONE());
}

// Capture the last exception message from mrb->exc and clear the exception.
// Shared by mrb_bridge_run_script() and mrb_bridge_load_nstring().
static int capture_and_clear_exception(mrb_state *mrb) {
  mrb_value exc = mrb_obj_value(mrb->exc);
  mrb_value msg = mrb_inspect(mrb, exc);

  if (mrb_string_p(msg)) {
    const char *msg_str = mrb_str_to_cstr(mrb, msg);
    strncpy(g_last_error, msg_str, sizeof(g_last_error) - 1);
    g_last_error[sizeof(g_last_error) - 1] = '\0';
  } else {
    strncpy(g_last_error, "Script error (unknown exception)",
            sizeof(g_last_error) - 1);
  }

  mrb->exc = NULL; // Clear so mrb_state remains usable
  return -1;
}

int mrb_bridge_run_script(mrb_state *mrb, const char *script) {
  mrbc_context *ctx = mrbc_context_new(mrb);
  mrbc_filename(mrb, ctx, "main.rb");

  mrb_value result = mrb_load_string_cxt(mrb, script, ctx);
  mrbc_context_free(mrb, ctx);
  (void)result;

  if (mrb->exc) {
    return capture_and_clear_exception(mrb);
  }

  g_last_error[0] = '\0';
  return 0;
}

int mrb_bridge_load_nstring(mrb_state *mrb, const char *script, size_t len,
                            int *is_syntax_error) {
  if (is_syntax_error)
    *is_syntax_error = 0;

  mrbc_context *ctx = mrbc_context_new(mrb);
  mrbc_filename(mrb, ctx, "rgss_script.rb");

  mrb_value result = mrb_load_nstring_cxt(mrb, script, (mrb_int)len, ctx);
  mrbc_context_free(mrb, ctx);
  (void)result;

  if (mrb->exc) {
    // Determine whether the raised exception is a SyntaxError.
    // mrb_obj_is_kind_of checks the class ancestry chain.
    if (is_syntax_error) {
      struct RClass *syn_err_cls = mrb_class_get(mrb, "SyntaxError");
      if (syn_err_cls) {
        mrb_value exc = mrb_obj_value(mrb->exc);
        *is_syntax_error = mrb_obj_is_kind_of(mrb, exc, syn_err_cls);
      }
    }
    return capture_and_clear_exception(mrb);
  }

  g_last_error[0] = '\0';
  return 0;
}

const char *mrb_bridge_last_error(mrb_state *mrb) {
  (void)mrb;
  return g_last_error;
}

void mrb_bridge_set_global_string(mrb_state *mrb, const char *name,
                                  const char *data, size_t len) {
  mrb_value str = mrb_str_new(mrb, data, (mrb_int)len);
  mrb_gv_set(mrb, mrb_intern_cstr(mrb, name), str);
}
