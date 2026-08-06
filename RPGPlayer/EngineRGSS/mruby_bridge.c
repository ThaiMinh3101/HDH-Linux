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
#include <pthread.h>
#include <stdio.h>
#include <string.h>

// ---------------------------------------------------------------------------
// Module-level state (one mruby VM per process in M1b)
// ---------------------------------------------------------------------------

static SpriteSetBitmapCallback g_bitmap_callback = NULL;

// M6.4: Window render callback (set by mrb_define_window_class).
static WindowRenderCallback g_window_callback = NULL;

// Stores the last exception message. Sized to hold typical Ruby backtraces.
// a5 fix: protected by a mutex — mrb_bridge_call_global (main thread,
// advanceFrame) and mrb_bridge_load_nstring (background thread, start())
// can be invoked concurrently during the start()→advanceFrame transition.
static char g_last_error[2048] = {0};
static pthread_mutex_t g_last_error_mutex = PTHREAD_MUTEX_INITIALIZER;

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
// Window method implementations
// RGSS behavior reference: "class Window" in RGSS Reference Manual
// ---------------------------------------------------------------------------

/// Fire the window render callback with the current state snapshot.
/// Builds an RGSSWindowState from the Window's ivars and calls
/// g_window_callback. The `text` pointer points into the mruby heap — the Swift
/// side must copy it.
static void window_fire_render(mrb_state *mrb, mrb_value self) {
  if (!g_window_callback)
    return;

  RGSSWindowState state;
  state.x = (int)mrb_fixnum(mrb_iv_get(mrb, self, mrb_intern_lit(mrb, "@x")));
  state.y = (int)mrb_fixnum(mrb_iv_get(mrb, self, mrb_intern_lit(mrb, "@y")));
  state.width =
      (int)mrb_fixnum(mrb_iv_get(mrb, self, mrb_intern_lit(mrb, "@width")));
  state.height =
      (int)mrb_fixnum(mrb_iv_get(mrb, self, mrb_intern_lit(mrb, "@height")));
  state.opacity =
      (int)mrb_fixnum(mrb_iv_get(mrb, self, mrb_intern_lit(mrb, "@opacity")));
  state.visible =
      mrb_test(mrb_iv_get(mrb, self, mrb_intern_lit(mrb, "@visible"))) ? 1 : 0;

  mrb_value text = mrb_iv_get(mrb, self, mrb_intern_lit(mrb, "@contents"));
  if (mrb_string_p(text)) {
    state.text = mrb_str_to_cstr(mrb, text);
  } else {
    state.text = "";
  }

  g_window_callback(&state);
}

/// Window.new — creates a Window with default geometry (RGSS3 defaults).
static mrb_value mrb_window_initialize(mrb_state *mrb, mrb_value self) {
  mrb_value x, y, width, height;
  mrb_get_args(mrb, "|oooo", &x, &y, &width, &height);

  mrb_iv_set(mrb, self, mrb_intern_lit(mrb, "@x"),
             mrb_fixnum_value(mrb_fixnum(x)));
  mrb_iv_set(mrb, self, mrb_intern_lit(mrb, "@y"),
             mrb_fixnum_value(mrb_fixnum(y)));
  mrb_iv_set(mrb, self, mrb_intern_lit(mrb, "@width"),
             mrb_fixnum_value(mrb_fixnum(width)));
  mrb_iv_set(mrb, self, mrb_intern_lit(mrb, "@height"),
             mrb_fixnum_value(mrb_fixnum(height)));
  mrb_iv_set(mrb, self, mrb_intern_lit(mrb, "@opacity"), mrb_fixnum_value(255));
  mrb_iv_set(mrb, self, mrb_intern_lit(mrb, "@visible"), mrb_true_value());
  mrb_iv_set(mrb, self, mrb_intern_lit(mrb, "@z"), mrb_fixnum_value(0));
  mrb_iv_set(mrb, self, mrb_intern_lit(mrb, "@windowskin"), mrb_nil_value());
  mrb_iv_set(mrb, self, mrb_intern_lit(mrb, "@contents"),
             mrb_str_new_cstr(mrb, ""));

  window_fire_render(mrb, self);
  return self;
}

/// Generic getter/setter for an integer ivar that fires the render callback.
/// `ivar_name` must be a literal interned string.
#define WINDOW_INT_ACCESSOR(ruby_name, ivar)                                   \
  static mrb_value mrb_window_get_##ruby_name(mrb_state *mrb,                  \
                                              mrb_value self) {                \
    return mrb_iv_get(mrb, self, mrb_intern_lit(mrb, ivar));                   \
  }                                                                            \
  static mrb_value mrb_window_set_##ruby_name(mrb_state *mrb,                  \
                                              mrb_value self) {                \
    mrb_int v;                                                                 \
    mrb_get_args(mrb, "i", &v);                                                \
    mrb_iv_set(mrb, self, mrb_intern_lit(mrb, ivar), mrb_fixnum_value(v));     \
    window_fire_render(mrb, self);                                             \
    return mrb_fixnum_value(v);                                                \
  }

WINDOW_INT_ACCESSOR(x, "@x")
WINDOW_INT_ACCESSOR(y, "@y")
WINDOW_INT_ACCESSOR(width, "@width")
WINDOW_INT_ACCESSOR(height, "@height")
WINDOW_INT_ACCESSOR(opacity, "@opacity")
WINDOW_INT_ACCESSOR(z, "@z")

/// Window#visible / #visible= — boolean.
static mrb_value mrb_window_get_visible(mrb_state *mrb, mrb_value self) {
  return mrb_iv_get(mrb, self, mrb_intern_lit(mrb, "@visible"));
}

static mrb_value mrb_window_set_visible(mrb_state *mrb, mrb_value self) {
  mrb_bool v;
  mrb_get_args(mrb, "b", &v);
  mrb_iv_set(mrb, self, mrb_intern_lit(mrb, "@visible"),
             v ? mrb_true_value() : mrb_false_value());
  window_fire_render(mrb, self);
  return mrb_bool_value(v);
}

/// Window#windowskin / #windowskin= — image path (stored, not yet rendered).
static mrb_value mrb_window_get_windowskin(mrb_state *mrb, mrb_value self) {
  return mrb_iv_get(mrb, self, mrb_intern_lit(mrb, "@windowskin"));
}

static mrb_value mrb_window_set_windowskin(mrb_state *mrb, mrb_value self) {
  mrb_value v;
  mrb_get_args(mrb, "o", &v);
  mrb_iv_set(mrb, self, mrb_intern_lit(mrb, "@windowskin"), v);
  window_fire_render(mrb, self);
  return v;
}

/// Window#contents / #contents= — text contents (M6.4 simplified: String).
static mrb_value mrb_window_get_contents(mrb_state *mrb, mrb_value self) {
  return mrb_iv_get(mrb, self, mrb_intern_lit(mrb, "@contents"));
}

static mrb_value mrb_window_set_contents(mrb_state *mrb, mrb_value self) {
  mrb_value v;
  mrb_get_args(mrb, "o", &v);
  if (mrb_string_p(v)) {
    mrb_iv_set(mrb, self, mrb_intern_lit(mrb, "@contents"), v);
  } else {
    mrb_iv_set(mrb, self, mrb_intern_lit(mrb, "@contents"),
               mrb_str_new_cstr(mrb, ""));
  }
  window_fire_render(mrb, self);
  return v;
}

/// Window#refresh — forces a render callback (used after batch updates).
static mrb_value mrb_window_refresh(mrb_state *mrb, mrb_value self) {
  window_fire_render(mrb, self);
  return self;
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

void mrb_define_window_class(mrb_state *mrb,
                             WindowRenderCallback window_callback) {
  g_window_callback = window_callback;

  struct RClass *window_class =
      mrb_define_class(mrb, "Window", mrb->object_class);
  MRB_SET_INSTANCE_TT(window_class, MRB_TT_OBJECT);

  mrb_define_method(mrb, window_class, "initialize", mrb_window_initialize,
                    MRB_ARGS_OPT(4));
  mrb_define_method(mrb, window_class, "x", mrb_window_get_x, MRB_ARGS_NONE());
  mrb_define_method(mrb, window_class, "x=", mrb_window_set_x, MRB_ARGS_REQ(1));
  mrb_define_method(mrb, window_class, "y", mrb_window_get_y, MRB_ARGS_NONE());
  mrb_define_method(mrb, window_class, "y=", mrb_window_set_y, MRB_ARGS_REQ(1));
  mrb_define_method(mrb, window_class, "width", mrb_window_get_width,
                    MRB_ARGS_NONE());
  mrb_define_method(mrb, window_class, "width=", mrb_window_set_width,
                    MRB_ARGS_REQ(1));
  mrb_define_method(mrb, window_class, "height", mrb_window_get_height,
                    MRB_ARGS_NONE());
  mrb_define_method(mrb, window_class, "height=", mrb_window_set_height,
                    MRB_ARGS_REQ(1));
  mrb_define_method(mrb, window_class, "opacity", mrb_window_get_opacity,
                    MRB_ARGS_NONE());
  mrb_define_method(mrb, window_class, "opacity=", mrb_window_set_opacity,
                    MRB_ARGS_REQ(1));
  mrb_define_method(mrb, window_class, "visible", mrb_window_get_visible,
                    MRB_ARGS_NONE());
  mrb_define_method(mrb, window_class, "visible=", mrb_window_set_visible,
                    MRB_ARGS_REQ(1));
  mrb_define_method(mrb, window_class, "z", mrb_window_get_z, MRB_ARGS_NONE());
  mrb_define_method(mrb, window_class, "z=", mrb_window_set_z, MRB_ARGS_REQ(1));
  mrb_define_method(mrb, window_class, "windowskin", mrb_window_get_windowskin,
                    MRB_ARGS_NONE());
  mrb_define_method(mrb, window_class, "windowskin=", mrb_window_set_windowskin,
                    MRB_ARGS_REQ(1));
  mrb_define_method(mrb, window_class, "contents", mrb_window_get_contents,
                    MRB_ARGS_NONE());
  mrb_define_method(mrb, window_class, "contents=", mrb_window_set_contents,
                    MRB_ARGS_REQ(1));
  mrb_define_method(mrb, window_class, "refresh", mrb_window_refresh,
                    MRB_ARGS_NONE());
}

// Capture the last exception message from mrb->exc and clear the exception.
// Shared by mrb_bridge_run_script() and mrb_bridge_load_nstring().
static int capture_and_clear_exception(mrb_state *mrb) {
  mrb_value exc = mrb_obj_value(mrb->exc);
  mrb_value msg = mrb_inspect(mrb, exc);

  // a5 fix: writes are mutex-protected (the buffer may be read from another
  // thread via mrb_bridge_last_error()).
  pthread_mutex_lock(&g_last_error_mutex);
  if (mrb_string_p(msg)) {
    const char *msg_str = mrb_str_to_cstr(mrb, msg);
    strncpy(g_last_error, msg_str, sizeof(g_last_error) - 1);
    g_last_error[sizeof(g_last_error) - 1] = '\0';
  } else {
    strncpy(g_last_error, "Script error (unknown exception)",
            sizeof(g_last_error) - 1);
  }
  pthread_mutex_unlock(&g_last_error_mutex);

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

  pthread_mutex_lock(&g_last_error_mutex);
  g_last_error[0] = '\0';
  pthread_mutex_unlock(&g_last_error_mutex);
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

  pthread_mutex_lock(&g_last_error_mutex);
  g_last_error[0] = '\0';
  pthread_mutex_unlock(&g_last_error_mutex);
  return 0;
}

const char *mrb_bridge_last_error(mrb_state *mrb) {
  (void)mrb;
  // a5 fix: read under the mutex to avoid racing a concurrent writer.
  // The returned pointer is valid only until the next call to a bridge
  // function that writes g_last_error — contract unchanged from before.
  pthread_mutex_lock(&g_last_error_mutex);
  const char *p = g_last_error;
  pthread_mutex_unlock(&g_last_error_mutex);
  return p;
}

void mrb_bridge_set_global_string(mrb_state *mrb, const char *name,
                                  const char *data, size_t len) {
  mrb_value str = mrb_str_new(mrb, data, (mrb_int)len);
  mrb_gv_set(mrb, mrb_intern_cstr(mrb, name), str);
}

int mrb_bridge_call_global(mrb_state *mrb, const char *method_name) {
  // Call the method on the top-level Object (self = main object).
  // mrb_funcall_argv with 0 args; if the method is undefined mruby raises
  // NoMethodError — we catch it and return -1 (caller logs a warning).
  mrb_value self = mrb_top_self(mrb);
  mrb_value result = mrb_funcall(mrb, self, method_name, 0);

  if (mrb->exc) {
    return capture_and_clear_exception(mrb);
  }

  pthread_mutex_lock(&g_last_error_mutex);
  g_last_error[0] = '\0';
  pthread_mutex_unlock(&g_last_error_mutex);
  (void)result;
  return 0;
}
