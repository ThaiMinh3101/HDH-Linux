// RPGPlayer/EngineRGSS/mruby_marshal_binding.h
//
// Header for the mruby Marshal module binding.
// Call mrb_define_marshal_module() once after mrb_open() to expose
// Marshal.load / Marshal.dump / Marshal.restore to RGSS scripts.

#ifndef MRUBY_MARSHAL_BINDING_H
#define MRUBY_MARSHAL_BINDING_H

#include <mruby.h>

/// Register the Marshal module into the given mruby VM.
/// Safe to call multiple times (re-registration is a no-op).
void mrb_define_marshal_module(mrb_state *mrb);

#endif /* MRUBY_MARSHAL_BINDING_H */
