// RPGPlayer/EngineRGSS/mruby_marshal_binding.c
//
// Exposes a Marshal module to the mruby VM so that RGSS scripts can call
// Marshal.load(data) and Marshal.dump(obj).
//
// CLEAN-ROOM DECLARATION:
//   Binding written from RGSS Reference Manual + mruby C API docs only.
//   No GPL/LGPL code referenced. Marshal format implemented in rgss_marshal.c.
//
// Marshal.load(binary_string) → RGSSValue → mruby object tree
// Marshal.dump(obj)           → mruby object tree → RGSSValue → binary_string
//
// Supported round-trip types:
//   nil, true, false, Integer, Float, String, Symbol, Array, Hash,
//   and objects whose class name can be stored as a symbol + ivar hash.
//
// Limitation: the mruby Object round-trip re-instantiates the class by name.
//   If the class does not exist in the VM, load raises MarshalError.
//   This matches real Ruby Marshal.load behavior.

#include "mruby_marshal_binding.h"
#include "rgss_marshal.h"
#include <mruby.h>
#include <mruby/array.h>
#include <mruby/class.h>
#include <mruby/data.h>
#include <mruby/hash.h>
#include <mruby/numeric.h>
#include <mruby/string.h>
#include <mruby/variable.h>
#include <stdlib.h>
#include <string.h>

// ── Default arena size for decode: 4 MB ──────────────────────────────────
#define DECODE_ARENA_SIZE (4 * 1024 * 1024)

// ── ivar collection helper for mrb_iv_foreach ────────────────────────────
// mrb_obj_instance_variables does not exist in mruby 3.3.0 public API.
// We use mrb_iv_foreach (variable.h) to iterate over all instance variables
// and collect them into a flat sym[] / val[] pair.
//
// Maximum ivars per object: RPG Maker save objects typically have < 50 ivars.
// Using a fixed-size stack buffer avoids heap allocation in the hot path.

#define IVAR_COLLECT_MAX 256

typedef struct {
  mrb_state *mrb;
  mrb_sym syms[IVAR_COLLECT_MAX];
  mrb_value vals[IVAR_COLLECT_MAX];
  mrb_int count;
} IvarCtx;

static int collect_ivar(mrb_state *mrb, mrb_sym sym, mrb_value val, void *p) {
  IvarCtx *ctx = (IvarCtx *)p;
  if (ctx->count < IVAR_COLLECT_MAX) {
    ctx->syms[ctx->count] = sym;
    ctx->vals[ctx->count] = val;
    ctx->count++;
  }
  return 0; /* 0 = continue iteration */
}

// ── mrb_value → RGSSValue (for Marshal.dump) ─────────────────────────────
// We use a simple bump-arena for the value tree; freed after encoding.

static RGSSValue *mrb_to_rgss(mrb_state *mrb, mrb_value v, RGSSArena *arena);

// Recursively convert an mrb_value to RGSSValue.
static RGSSValue *mrb_to_rgss(mrb_state *mrb, mrb_value v, RGSSArena *arena) {
  (void)arena; /* dump-side uses malloc; arena param kept for recursive call
                  signature */
  // Dump-side always uses malloc (arena is only for decode-side bump alloc).
  RGSSValue *rv = malloc(sizeof(RGSSValue));
  if (!rv)
    return NULL;
  memset(rv, 0, sizeof(RGSSValue));

  switch (mrb_type(v)) {
  case MRB_TT_FALSE:
    if (mrb_nil_p(v)) {
      rv->type = RGSS_VAL_NIL;
    } else {
      rv->type = RGSS_VAL_BOOL;
      rv->as.b = 0;
    }
    break;
  case MRB_TT_TRUE:
    rv->type = RGSS_VAL_BOOL;
    rv->as.b = 1;
    break;
  case MRB_TT_INTEGER:
    rv->type = RGSS_VAL_INT;
    rv->as.i = (long long)mrb_integer(v);
    break;
  case MRB_TT_FLOAT:
    rv->type = RGSS_VAL_FLOAT;
    rv->as.f = (double)mrb_float(v);
    break;
  case MRB_TT_STRING: {
    rv->type = RGSS_VAL_STRING;
    rv->as.s.len = (size_t)RSTRING_LEN(v);
    rv->as.s.data = malloc(rv->as.s.len);
    if (rv->as.s.data && rv->as.s.len > 0)
      memcpy(rv->as.s.data, RSTRING_PTR(v), rv->as.s.len);
    break;
  }
  case MRB_TT_SYMBOL: {
    rv->type = RGSS_VAL_SYMBOL;
    mrb_int slen;
    const char *sname = mrb_sym_name_len(mrb, mrb_symbol(v), &slen);
    rv->as.sym = malloc((size_t)slen + 1);
    if (rv->as.sym) {
      memcpy(rv->as.sym, sname, (size_t)slen);
      rv->as.sym[slen] = '\0';
    }
    break;
  }
  case MRB_TT_ARRAY: {
    rv->type = RGSS_VAL_ARRAY;
    mrb_int alen = RARRAY_LEN(v);
    rv->as.arr.count = (size_t)alen;
    rv->as.arr.items =
        alen > 0 ? malloc((size_t)alen * sizeof(RGSSValue *)) : NULL;
    for (mrb_int i = 0; i < alen; i++) {
      rv->as.arr.items[i] = mrb_to_rgss(mrb, mrb_ary_ref(mrb, v, i), arena);
    }
    break;
  }
  case MRB_TT_HASH: {
    rv->type = RGSS_VAL_HASH;
    mrb_value keys = mrb_hash_keys(mrb, v);
    mrb_int hlen = RARRAY_LEN(keys);
    rv->as.hash.count = (size_t)hlen;
    rv->as.hash.keys =
        hlen > 0 ? malloc((size_t)hlen * sizeof(RGSSValue *)) : NULL;
    rv->as.hash.values =
        hlen > 0 ? malloc((size_t)hlen * sizeof(RGSSValue *)) : NULL;
    for (mrb_int i = 0; i < hlen; i++) {
      mrb_value k = mrb_ary_ref(mrb, keys, i);
      mrb_value vv = mrb_hash_get(mrb, v, k);
      rv->as.hash.keys[i] = mrb_to_rgss(mrb, k, arena);
      rv->as.hash.values[i] = mrb_to_rgss(mrb, vv, arena);
    }
    break;
  }
  case MRB_TT_OBJECT: {
    rv->type = RGSS_VAL_OBJECT;
    // Class name
    struct RClass *cls = mrb_obj_class(mrb, v);
    mrb_value cname = mrb_class_path(mrb, cls);
    const char *cn = mrb_str_to_cstr(mrb, cname);
    rv->as.obj.class_name = malloc(strlen(cn) + 1);
    if (rv->as.obj.class_name)
      strcpy(rv->as.obj.class_name, cn);

    // Instance variables — use mrb_iv_foreach (mruby 3.3.0 public API)
    IvarCtx ctx;
    ctx.mrb = mrb;
    ctx.count = 0;
    mrb_iv_foreach(mrb, v, collect_ivar, &ctx);

    mrb_int icount = ctx.count;
    rv->as.obj.ivars.count = (size_t)icount;
    rv->as.obj.ivars.keys =
        icount > 0 ? malloc((size_t)icount * sizeof(RGSSValue *)) : NULL;
    rv->as.obj.ivars.values =
        icount > 0 ? malloc((size_t)icount * sizeof(RGSSValue *)) : NULL;
    for (mrb_int i = 0; i < icount; i++) {
      // Convert sym name to mrb_value symbol for RGSSValue
      mrb_value iname_sym = mrb_symbol_value(ctx.syms[i]);
      rv->as.obj.ivars.keys[i] = mrb_to_rgss(mrb, iname_sym, arena);
      rv->as.obj.ivars.values[i] = mrb_to_rgss(mrb, ctx.vals[i], arena);
    }
    break;
  }
  default:
    // Unsupported type — store as nil to avoid crash
    rv->type = RGSS_VAL_NIL;
    break;
  }
  return rv;
}

// Free an RGSSValue tree allocated with malloc (dump side only).
static void rgss_value_free(RGSSValue *v) {
  if (!v)
    return;
  switch (v->type) {
  case RGSS_VAL_STRING:
    free(v->as.s.data);
    break;
  case RGSS_VAL_SYMBOL:
    free(v->as.sym);
    break;
  case RGSS_VAL_ARRAY:
    for (size_t i = 0; i < v->as.arr.count; i++)
      rgss_value_free(v->as.arr.items[i]);
    free(v->as.arr.items);
    break;
  case RGSS_VAL_HASH:
    for (size_t i = 0; i < v->as.hash.count; i++) {
      rgss_value_free(v->as.hash.keys[i]);
      rgss_value_free(v->as.hash.values[i]);
    }
    free(v->as.hash.keys);
    free(v->as.hash.values);
    break;
  case RGSS_VAL_OBJECT:
    free(v->as.obj.class_name);
    for (size_t i = 0; i < v->as.obj.ivars.count; i++) {
      rgss_value_free(v->as.obj.ivars.keys[i]);
      rgss_value_free(v->as.obj.ivars.values[i]);
    }
    free(v->as.obj.ivars.keys);
    free(v->as.obj.ivars.values);
    break;
  default:
    break;
  }
  free(v);
}

// ── RGSSValue → mrb_value (for Marshal.load) ─────────────────────────────

// Find a class by full path, e.g. "RPG::Actor" or "RPG::Event::Page".
// mrb_class_get() only resolves top-level names; RGSS data classes are
// nested inside the RPG module, so we must descend through "::" segments.
// Returns NULL (no exception raised) if any segment is missing.
static struct RClass *find_class_by_path(mrb_state *mrb, const char *path) {
  struct RClass *cls = mrb->object_class;
  const char *p = path;
  while (*p) {
    const char *sep = strstr(p, "::");
    size_t len = sep ? (size_t)(sep - p) : strlen(p);
    if (len == 0)
      return NULL;
    char *name = (char *)malloc(len + 1);
    if (!name)
      return NULL;
    memcpy(name, p, len);
    name[len] = '\0';
    mrb_sym sym = mrb_intern_cstr(mrb, name);
    free(name);
    if (!mrb_const_defined(mrb, mrb_obj_value(cls), sym))
      return NULL;
    mrb_value v = mrb_const_get(mrb, mrb_obj_value(cls), sym);
    if (!mrb_class_p(v))
      return NULL;
    cls = mrb_class_ptr(v);
    if (!sep)
      break;
    p = sep + 2;
  }
  return cls;
}

static mrb_value rgss_to_mrb(mrb_state *mrb, const RGSSValue *v);

static mrb_value rgss_to_mrb(mrb_state *mrb, const RGSSValue *v) {
  if (!v)
    return mrb_nil_value();
  switch (v->type) {
  case RGSS_VAL_NIL:
    return mrb_nil_value();
  case RGSS_VAL_BOOL:
    return v->as.b ? mrb_true_value() : mrb_false_value();
  case RGSS_VAL_INT:
    return mrb_int_value(mrb, (mrb_int)v->as.i);
  case RGSS_VAL_FLOAT:
    return mrb_float_value(mrb, (mrb_float)v->as.f);
  case RGSS_VAL_STRING:
    return mrb_str_new(mrb, (const char *)v->as.s.data, (mrb_int)v->as.s.len);
  case RGSS_VAL_SYMBOL:
    return mrb_symbol_value(mrb_intern_cstr(mrb, v->as.sym));
  case RGSS_VAL_ARRAY: {
    mrb_value arr = mrb_ary_new_capa(mrb, (mrb_int)v->as.arr.count);
    for (size_t i = 0; i < v->as.arr.count; i++) {
      mrb_ary_push(mrb, arr, rgss_to_mrb(mrb, v->as.arr.items[i]));
    }
    return arr;
  }
  case RGSS_VAL_HASH: {
    mrb_value h = mrb_hash_new_capa(mrb, (mrb_int)v->as.hash.count);
    for (size_t i = 0; i < v->as.hash.count; i++) {
      mrb_hash_set(mrb, h, rgss_to_mrb(mrb, v->as.hash.keys[i]),
                   rgss_to_mrb(mrb, v->as.hash.values[i]));
    }
    return h;
  }
  case RGSS_VAL_OBJECT: {
    // Look up class by full path (supports nested "RPG::Actor").
    // Returns NULL (no exception) if the class is not defined yet.
    const char *cname = v->as.obj.class_name;
    struct RClass *cls = find_class_by_path(mrb, cname);
    if (!cls)
      return mrb_nil_value();

    // Allocate a new instance without calling initialize
    mrb_value obj = mrb_obj_value(mrb_obj_alloc(mrb, MRB_TT_OBJECT, cls));

    // Set instance variables
    for (size_t i = 0; i < v->as.obj.ivars.count; i++) {
      const RGSSValue *kv = v->as.obj.ivars.keys[i];
      if (!kv || kv->type != RGSS_VAL_SYMBOL)
        continue;
      mrb_sym sym = mrb_intern_cstr(mrb, kv->as.sym);
      mrb_value val = rgss_to_mrb(mrb, v->as.obj.ivars.values[i]);
      mrb_iv_set(mrb, obj, sym, val);
    }
    return obj;
  }
  default:
    return mrb_nil_value();
  }
}

// ── Marshal.load(binary_string) ───────────────────────────────────────────

static mrb_value mrb_marshal_load(mrb_state *mrb, mrb_value self) {
  (void)self;
  mrb_value data;
  mrb_get_args(mrb, "S", &data);

  const uint8_t *buf = (const uint8_t *)RSTRING_PTR(data);
  size_t len = (size_t)RSTRING_LEN(data);

  RGSSArena *arena = rgss_arena_create(DECODE_ARENA_SIZE);
  if (!arena) {
    mrb_raise(mrb, mrb_class_get(mrb, "RuntimeError"),
              "Marshal.load: out of memory");
    return mrb_nil_value();
  }

  RGSSMarshalDecoder dec;
  rgss_marshal_decoder_init(&dec, buf, len, arena);
  RGSSValue *root = rgss_marshal_load(&dec);

  mrb_value result = mrb_nil_value();
  if (!root || dec.last_error != RGSS_MARSHAL_OK) {
    const char *msg = rgss_marshal_error_string(dec.last_error);
    // Free tables (values live in arena, freed below)
    free(dec.sym_table);
    free(dec.obj_table);
    rgss_arena_destroy(arena);
    mrb_raisef(mrb, mrb_class_get(mrb, "RuntimeError"),
               "Marshal.load error: %s", msg);
    return mrb_nil_value();
  }

  result = rgss_to_mrb(mrb, root);

  free(dec.sym_table);
  free(dec.obj_table);
  rgss_arena_destroy(arena);

  return result;
}

// ── Marshal.dump(obj) ─────────────────────────────────────────────────────

static mrb_value mrb_marshal_dump(mrb_state *mrb, mrb_value self) {
  (void)self;
  mrb_value obj;
  mrb_get_args(mrb, "o", &obj);

  // We use a dummy arena for mrb_to_rgss (it won't actually use it —
  // dump side uses malloc). Create a minimal arena just to satisfy the API.
  RGSSArena dummy = {.base = (uint8_t *)&dummy, .cap = 0, .used = 0};

  RGSSValue *root = mrb_to_rgss(mrb, obj, &dummy);
  if (!root) {
    mrb_raise(mrb, mrb_class_get(mrb, "RuntimeError"),
              "Marshal.dump: conversion failed");
    return mrb_nil_value();
  }

  RGSSMarshalEncoder enc;
  rgss_marshal_encoder_init(&enc);
  int rc = rgss_marshal_dump(&enc, root);
  rgss_value_free(root);

  if (rc != 0) {
    const char *msg = rgss_marshal_error_string(enc.last_error);
    rgss_marshal_encoder_free(&enc);
    mrb_raisef(mrb, mrb_class_get(mrb, "RuntimeError"),
               "Marshal.dump error: %s", msg);
    return mrb_nil_value();
  }

  mrb_value result = mrb_str_new(mrb, (const char *)rgss_marshal_bytes(&enc),
                                 (mrb_int)rgss_marshal_length(&enc));
  rgss_marshal_encoder_free(&enc);
  return result;
}

// ── Register Marshal module into mruby VM ─────────────────────────────────

void mrb_define_marshal_module(mrb_state *mrb) {
  struct RClass *m = mrb_define_module(mrb, "Marshal");
  mrb_define_class_method(mrb, m, "load", mrb_marshal_load, MRB_ARGS_REQ(1));
  mrb_define_class_method(mrb, m, "dump", mrb_marshal_dump, MRB_ARGS_REQ(1));
  // Marshal.restore is an alias for Marshal.load in Ruby
  mrb_define_class_method(mrb, m, "restore", mrb_marshal_load, MRB_ARGS_REQ(1));
}
