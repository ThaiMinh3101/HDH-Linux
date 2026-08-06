// RPGPlayer/EngineRGSS/rgss_marshal.c
//
// Clean-room Ruby Marshal 4.8 decoder + encoder.
//
// CLEAN-ROOM DECLARATION:
//   Written solely from the public Ruby Marshal binary format documentation.
//   Format reference: https://ruby-doc.org/core/Marshal.html (public rdoc),
//   plus community byte-level analysis (no GPL/LGPL code referenced).
//   NO source from mkxp, mkxp-z, or other open-source RGSS engines was used.
//
// Format summary (Ruby Marshal 4.8):
//   Header:  0x04 0x08
//   Each value: 1-byte type tag followed by type-specific data.
//
//   Integer encoding ('i'):
//     byte 0 = n
//       n == 0                     → value = 0
//       1  ≤  n ≤ 4                → read n little-endian bytes (unsigned)
//      -4  ≤  n ≤ -1               → read (-n) little-endian bytes
//      (sign-extend)
//       5  ≤  n ≤ 127              → value = n - 5
//      -128 ≤  n ≤ -6              → value = n + 5
//
//   Symbol (':', ';'):  ':' stores new symbol (length + bytes); ';' is
//   sym_table index. Object link ('@'):  references a previously decoded object
//   by object-table index. Instance variables ('I'): wraps another value, then
//   appends a Hash of ivars.
//                             We decode the inner value and ignore encoding
//                             ivars.

#include "rgss_marshal.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ── Arena allocator ────────────────────────────────────────────────────────
// Simple bump pointer. All decoded values live inside one arena per decode
// session — freed in one call. Encoder uses malloc/realloc instead.

#define ARENA_ALIGN 8

/* struct RGSSArena is defined in rgss_marshal.h — included above */

RGSSArena *rgss_arena_create(size_t capacity) {
  RGSSArena *a = malloc(sizeof(RGSSArena));
  if (!a)
    return NULL;
  a->base = malloc(capacity);
  if (!a->base) {
    free(a);
    return NULL;
  }
  a->cap = capacity;
  a->used = 0;
  return a;
}

void rgss_arena_destroy(RGSSArena *a) {
  if (!a)
    return;
  free(a->base);
  free(a);
}

static void *arena_alloc(RGSSArena *a, size_t sz) {
  // Align to ARENA_ALIGN
  size_t aligned = (sz + ARENA_ALIGN - 1) & ~(size_t)(ARENA_ALIGN - 1);
  if (a->used + aligned > a->cap)
    return NULL; // out of space
  void *p = a->base + a->used;
  a->used += aligned;
  return p;
}

// Allocate a string copy inside the arena (null-terminated).
static char *arena_strdup(RGSSArena *a, const char *s, size_t len) {
  char *p = arena_alloc(a, len + 1);
  if (!p)
    return NULL;
  memcpy(p, s, len);
  p[len] = '\0';
  return p;
}

// Allocate raw bytes inside the arena.
static uint8_t *arena_bytes(RGSSArena *a, size_t len) {
  return arena_alloc(a, len > 0 ? len : 1);
}

// ── Decode helpers ─────────────────────────────────────────────────────────

static uint8_t read_byte(RGSSMarshalDecoder *d) {
  if (d->pos >= d->len) {
    d->last_error = RGSS_MARSHAL_ERR_TRUNCATED;
    return 0;
  }
  return d->buf[d->pos++];
}

static void ensure_bytes(RGSSMarshalDecoder *d, size_t n) {
  if (d->pos + n > d->len)
    d->last_error = RGSS_MARSHAL_ERR_TRUNCATED;
}

// Read Marshal integer (variable-length signed).
// Returns 0 on error (check d->last_error).
static long long read_marshal_int(RGSSMarshalDecoder *d) {
  if (d->last_error != RGSS_MARSHAL_OK)
    return 0;
  int8_t n = (int8_t)read_byte(d);
  if (d->last_error != RGSS_MARSHAL_OK)
    return 0;

  if (n == 0)
    return 0;

  if (n > 4)
    return (long long)(n - 5);
  if (n < -4)
    return (long long)(n + 5);

  if (n > 0) {
    // Read n bytes little-endian unsigned
    ensure_bytes(d, (size_t)n);
    if (d->last_error != RGSS_MARSHAL_OK)
      return 0;
    unsigned long long val = 0;
    for (int i = 0; i < n; i++) {
      val |= ((unsigned long long)read_byte(d)) << (8 * i);
    }
    return (long long)val;
  } else {
    // Read (-n) bytes little-endian, sign-extended from 0xFFFFFFFF...
    int count = -n;
    ensure_bytes(d, (size_t)count);
    if (d->last_error != RGSS_MARSHAL_OK)
      return 0;
    long long val = -1LL; // start with all 1s for sign extension
    for (int i = 0; i < count; i++) {
      val &= ~(0xFFL << (8 * i));
      val |= ((long long)read_byte(d)) << (8 * i);
    }
    return val;
  }
}

// Intern a symbol into sym_table. Returns index.
static int intern_symbol(RGSSMarshalDecoder *d, char *sym) {
  if (d->sym_count >= d->sym_cap) {
    size_t new_cap = d->sym_cap ? d->sym_cap * 2 : 16;
    char **t = realloc(d->sym_table, new_cap * sizeof(char *));
    if (!t) {
      d->last_error = RGSS_MARSHAL_ERR_ALLOC;
      return -1;
    }
    d->sym_table = t;
    d->sym_cap = new_cap;
  }
  d->sym_table[d->sym_count] = sym;
  return (int)(d->sym_count++);
}

// Register an object into obj_table. Returns index.
static int register_object(RGSSMarshalDecoder *d, RGSSValue *v) {
  if (d->obj_count >= d->obj_cap) {
    size_t new_cap = d->obj_cap ? d->obj_cap * 2 : 64;
    RGSSValue **t = realloc(d->obj_table, new_cap * sizeof(RGSSValue *));
    if (!t) {
      d->last_error = RGSS_MARSHAL_ERR_ALLOC;
      return -1;
    }
    d->obj_table = t;
    d->obj_cap = new_cap;
  }
  d->obj_table[d->obj_count] = v;
  return (int)(d->obj_count++);
}

static RGSSValue *alloc_value(RGSSMarshalDecoder *d, RGSSValueType type) {
  RGSSValue *v = arena_alloc(d->arena, sizeof(RGSSValue));
  if (!v) {
    d->last_error = RGSS_MARSHAL_ERR_ALLOC;
    return NULL;
  }
  memset(v, 0, sizeof(RGSSValue));
  v->type = type;
  return v;
}

// Forward declaration
static RGSSValue *decode_value(RGSSMarshalDecoder *d);

static RGSSValue *decode_string(RGSSMarshalDecoder *d) {
  long long len = read_marshal_int(d);
  if (d->last_error != RGSS_MARSHAL_OK)
    return NULL;
  if (len < 0 || len > 64 * 1024 * 1024) {
    d->last_error = RGSS_MARSHAL_ERR_OVERFLOW;
    return NULL;
  }
  ensure_bytes(d, (size_t)len);
  if (d->last_error != RGSS_MARSHAL_OK)
    return NULL;

  RGSSValue *v = alloc_value(d, RGSS_VAL_STRING);
  if (!v)
    return NULL;

  v->as.s.len = (size_t)len;
  v->as.s.data = arena_bytes(d->arena, v->as.s.len);
  if (!v->as.s.data && len > 0) {
    d->last_error = RGSS_MARSHAL_ERR_ALLOC;
    return NULL;
  }
  if (len > 0)
    memcpy(v->as.s.data, d->buf + d->pos, (size_t)len);
  d->pos += (size_t)len;

  register_object(d, v);
  return v;
}

static char *decode_symbol_name(RGSSMarshalDecoder *d) {
  long long len = read_marshal_int(d);
  if (d->last_error != RGSS_MARSHAL_OK)
    return NULL;
  if (len <= 0 || len > 1024) {
    d->last_error = RGSS_MARSHAL_ERR_OVERFLOW;
    return NULL;
  }
  ensure_bytes(d, (size_t)len);
  if (d->last_error != RGSS_MARSHAL_OK)
    return NULL;

  char *sym =
      arena_strdup(d->arena, (const char *)(d->buf + d->pos), (size_t)len);
  d->pos += (size_t)len;
  if (!sym) {
    d->last_error = RGSS_MARSHAL_ERR_ALLOC;
    return NULL;
  }
  return sym;
}

static RGSSValue *decode_array(RGSSMarshalDecoder *d) {
  RGSSValue *v = alloc_value(d, RGSS_VAL_ARRAY);
  if (!v)
    return NULL;
  register_object(d, v);

  long long count = read_marshal_int(d);
  if (d->last_error != RGSS_MARSHAL_OK)
    return NULL;
  if (count < 0 || count > 1024 * 1024) {
    d->last_error = RGSS_MARSHAL_ERR_OVERFLOW;
    return NULL;
  }

  v->as.arr.count = (size_t)count;
  if (count > 0) {
    v->as.arr.items =
        arena_alloc(d->arena, (size_t)count * sizeof(RGSSValue *));
    if (!v->as.arr.items) {
      d->last_error = RGSS_MARSHAL_ERR_ALLOC;
      return NULL;
    }
    for (long long i = 0; i < count; i++) {
      v->as.arr.items[i] = decode_value(d);
      if (d->last_error != RGSS_MARSHAL_OK)
        return NULL;
    }
  }
  return v;
}

static RGSSValue *decode_hash(RGSSMarshalDecoder *d) {
  RGSSValue *v = alloc_value(d, RGSS_VAL_HASH);
  if (!v)
    return NULL;
  register_object(d, v);

  long long count = read_marshal_int(d);
  if (d->last_error != RGSS_MARSHAL_OK)
    return NULL;
  if (count < 0 || count > 512 * 1024) {
    d->last_error = RGSS_MARSHAL_ERR_OVERFLOW;
    return NULL;
  }

  v->as.hash.count = (size_t)count;
  v->as.hash.keys = NULL;
  v->as.hash.values = NULL;
  if (count > 0) {
    v->as.hash.keys =
        arena_alloc(d->arena, (size_t)count * sizeof(RGSSValue *));
    v->as.hash.values =
        arena_alloc(d->arena, (size_t)count * sizeof(RGSSValue *));
    if (!v->as.hash.keys || !v->as.hash.values) {
      d->last_error = RGSS_MARSHAL_ERR_ALLOC;
      return NULL;
    }
    for (long long i = 0; i < count; i++) {
      v->as.hash.keys[i] = decode_value(d);
      if (d->last_error != RGSS_MARSHAL_OK)
        return NULL;
      v->as.hash.values[i] = decode_value(d);
      if (d->last_error != RGSS_MARSHAL_OK)
        return NULL;
    }
  }
  return v;
}

static RGSSValue *decode_object(RGSSMarshalDecoder *d) {
  // 'o': class name (symbol) + ivar hash count + k/v pairs
  RGSSValue *v = alloc_value(d, RGSS_VAL_OBJECT);
  if (!v)
    return NULL;
  register_object(d, v);

  // Class name: must be a symbol tag (':' or ';')
  uint8_t tag = read_byte(d);
  if (d->last_error != RGSS_MARSHAL_OK)
    return NULL;

  char *class_name = NULL;
  if (tag == ':') {
    class_name = decode_symbol_name(d);
    if (!class_name)
      return NULL;
    intern_symbol(d, class_name);
  } else if (tag == ';') {
    long long idx = read_marshal_int(d);
    if (d->last_error != RGSS_MARSHAL_OK)
      return NULL;
    if (idx < 0 || (size_t)idx >= d->sym_count) {
      d->last_error = RGSS_MARSHAL_ERR_TRUNCATED;
      return NULL;
    }
    class_name = d->sym_table[idx];
  } else {
    d->last_error = RGSS_MARSHAL_ERR_UNSUPPORTED;
    return NULL;
  }

  v->as.obj.class_name = class_name;

  // Ivar count
  long long icount = read_marshal_int(d);
  if (d->last_error != RGSS_MARSHAL_OK)
    return NULL;
  if (icount < 0 || icount > 512 * 1024) {
    d->last_error = RGSS_MARSHAL_ERR_OVERFLOW;
    return NULL;
  }

  v->as.obj.ivars.count = (size_t)icount;
  v->as.obj.ivars.keys = NULL;
  v->as.obj.ivars.values = NULL;
  if (icount > 0) {
    v->as.obj.ivars.keys =
        arena_alloc(d->arena, (size_t)icount * sizeof(RGSSValue *));
    v->as.obj.ivars.values =
        arena_alloc(d->arena, (size_t)icount * sizeof(RGSSValue *));
    if (!v->as.obj.ivars.keys || !v->as.obj.ivars.values) {
      d->last_error = RGSS_MARSHAL_ERR_ALLOC;
      return NULL;
    }
    for (long long i = 0; i < icount; i++) {
      v->as.obj.ivars.keys[i] = decode_value(d);
      if (d->last_error != RGSS_MARSHAL_OK)
        return NULL;
      v->as.obj.ivars.values[i] = decode_value(d);
      if (d->last_error != RGSS_MARSHAL_OK)
        return NULL;
    }
  }
  return v;
}

static RGSSValue *decode_value(RGSSMarshalDecoder *d) {
  if (d->last_error != RGSS_MARSHAL_OK)
    return NULL;

  uint8_t tag = read_byte(d);
  if (d->last_error != RGSS_MARSHAL_OK)
    return NULL;

  switch (tag) {
  case '0': {
    RGSSValue *v = alloc_value(d, RGSS_VAL_NIL);
    return v;
  }
  case 'T': {
    RGSSValue *v = alloc_value(d, RGSS_VAL_BOOL);
    if (v)
      v->as.b = 1;
    return v;
  }
  case 'F': {
    RGSSValue *v = alloc_value(d, RGSS_VAL_BOOL);
    if (v)
      v->as.b = 0;
    return v;
  }
  case 'i': {
    long long n = read_marshal_int(d);
    if (d->last_error != RGSS_MARSHAL_OK)
      return NULL;
    RGSSValue *v = alloc_value(d, RGSS_VAL_INT);
    if (v)
      v->as.i = n;
    return v;
  }
  case 'f': {
    // Float stored as Marshal string of its decimal representation
    long long len = read_marshal_int(d);
    if (d->last_error != RGSS_MARSHAL_OK)
      return NULL;
    if (len <= 0 || len > 64) {
      d->last_error = RGSS_MARSHAL_ERR_OVERFLOW;
      return NULL;
    }
    ensure_bytes(d, (size_t)len);
    if (d->last_error != RGSS_MARSHAL_OK)
      return NULL;
    char buf[65];
    memcpy(buf, d->buf + d->pos, (size_t)len);
    buf[len] = '\0';
    d->pos += (size_t)len;
    RGSSValue *v = alloc_value(d, RGSS_VAL_FLOAT);
    if (v) {
      if (strcmp(buf, "inf") == 0)
        v->as.f = HUGE_VAL;
      else if (strcmp(buf, "-inf") == 0)
        v->as.f = -HUGE_VAL;
      else if (strcmp(buf, "nan") == 0)
        v->as.f = 0.0 / 0.0;
      else
        v->as.f = strtod(buf, NULL);
    }
    register_object(d, v);
    return v;
  }
  case '"': {
    return decode_string(d);
  }
  case ':': {
    // New symbol
    char *sym = decode_symbol_name(d);
    if (!sym)
      return NULL;
    intern_symbol(d, sym);
    RGSSValue *v = alloc_value(d, RGSS_VAL_SYMBOL);
    if (v)
      v->as.sym = sym;
    return v;
  }
  case ';': {
    // Symbol back-reference
    long long idx = read_marshal_int(d);
    if (d->last_error != RGSS_MARSHAL_OK)
      return NULL;
    if (idx < 0 || (size_t)idx >= d->sym_count) {
      d->last_error = RGSS_MARSHAL_ERR_TRUNCATED;
      return NULL;
    }
    RGSSValue *v = alloc_value(d, RGSS_VAL_SYMBOL);
    if (v)
      v->as.sym = d->sym_table[idx];
    return v;
  }
  case '@': {
    // Object back-reference
    long long idx = read_marshal_int(d);
    if (d->last_error != RGSS_MARSHAL_OK)
      return NULL;
    if (idx < 0 || (size_t)idx >= d->obj_count) {
      d->last_error = RGSS_MARSHAL_ERR_TRUNCATED;
      return NULL;
    }
    return d->obj_table[idx];
  }
  case '[': {
    return decode_array(d);
  }
  case '{': {
    return decode_hash(d);
  }
  case '}': {
    // Hash with default value (Ruby Marshal '}' tag).
    // Format: '}' <count> <key/value pairs...> <default_value>
    // a6 fix: decode_hash() reads count + pairs, but the trailing default
    // value must ALSO be consumed — otherwise the stream position is wrong
    // and any subsequent object reference / value decodes incorrectly.
    RGSSValue *h = decode_hash(d);
    if (d->last_error != RGSS_MARSHAL_OK)
      return NULL;
    // Consume and discard the default value (we don't need it at this layer).
    decode_value(d);
    if (d->last_error != RGSS_MARSHAL_OK)
      return NULL;
    return h;
  }
  case 'o': {
    return decode_object(d);
  }
  case 'I': {
    // Instance variable wrapper: decode inner value, then skip ivar pairs
    // Most common use: String with encoding annotation ("E" => true/false).
    //
    // a2 fix: DO NOT call register_object(inner) here. The inner value has
    // ALREADY been registered by its own decoder (decode_string registers at
    // construction, decode_array/decode_hash/decode_object register at
    // allocation). Registering it again duplicates the entry in obj_table —
    // a later '@' back-reference would then resolve to the WRONG index,
    // producing a corrupted object tree.
    RGSSValue *inner = decode_value(d);
    if (d->last_error != RGSS_MARSHAL_OK)
      return NULL;
    // Consume ivar pairs (we don't need encoding info at this layer)
    long long icount = read_marshal_int(d);
    if (d->last_error != RGSS_MARSHAL_OK)
      return NULL;
    for (long long i = 0; i < icount * 2; i++) {
      decode_value(d); // key + value — decode and discard
      if (d->last_error != RGSS_MARSHAL_OK)
        return NULL;
    }
    return inner;
  }
  default: {
    d->last_error = RGSS_MARSHAL_ERR_UNSUPPORTED;
    return NULL;
  }
  }
}

// ── Public decoder API ─────────────────────────────────────────────────────

void rgss_marshal_decoder_init(RGSSMarshalDecoder *d, const uint8_t *buf,
                               size_t len, RGSSArena *arena) {
  memset(d, 0, sizeof(*d));
  d->buf = buf;
  d->len = len;
  d->pos = 0;
  d->arena = arena;
  d->last_error = RGSS_MARSHAL_OK;
}

RGSSValue *rgss_marshal_load(RGSSMarshalDecoder *d) {
  // Verify Marshal 4.8 header: 0x04 0x08
  if (d->len < 2) {
    d->last_error = RGSS_MARSHAL_ERR_TRUNCATED;
    return NULL;
  }
  if (d->buf[0] != 0x04 || d->buf[1] != 0x08) {
    d->last_error = RGSS_MARSHAL_ERR_VERSION;
    return NULL;
  }
  d->pos = 2;
  return decode_value(d);
}

void rgss_marshal_decoder_free_tables(RGSSMarshalDecoder *d) {
  if (!d)
    return;
  free(d->sym_table);
  free(d->obj_table);
  d->sym_table = NULL;
  d->sym_count = 0;
  d->sym_cap = 0;
  d->obj_table = NULL;
  d->obj_count = 0;
  d->obj_cap = 0;
}

// ── Encoder implementation ─────────────────────────────────────────────────

#define ENC_INIT_CAP (4 * 1024)

void rgss_marshal_encoder_init(RGSSMarshalEncoder *e) {
  memset(e, 0, sizeof(*e));
  e->buf = malloc(ENC_INIT_CAP);
  e->cap = e->buf ? ENC_INIT_CAP : 0;
  e->last_error = RGSS_MARSHAL_OK;
}

void rgss_marshal_encoder_free(RGSSMarshalEncoder *e) {
  free(e->buf);
  free(e->sym_table);
  free(e->obj_table);
  memset(e, 0, sizeof(*e));
}

static int enc_ensure(RGSSMarshalEncoder *e, size_t extra) {
  if (e->len + extra <= e->cap)
    return 1;
  size_t new_cap = e->cap ? e->cap : ENC_INIT_CAP;
  while (new_cap < e->len + extra)
    new_cap *= 2;
  uint8_t *nb = realloc(e->buf, new_cap);
  if (!nb) {
    e->last_error = RGSS_MARSHAL_ERR_ALLOC;
    return 0;
  }
  e->buf = nb;
  e->cap = new_cap;
  return 1;
}

static void enc_byte(RGSSMarshalEncoder *e, uint8_t b) {
  if (!enc_ensure(e, 1))
    return;
  e->buf[e->len++] = b;
}

static void enc_bytes(RGSSMarshalEncoder *e, const uint8_t *data, size_t len) {
  if (!enc_ensure(e, len))
    return;
  memcpy(e->buf + e->len, data, len);
  e->len += len;
}

// Write a Marshal integer
static void enc_int(RGSSMarshalEncoder *e, long long n) {
  if (n == 0) {
    enc_byte(e, 0);
    return;
  }
  if (n > 0 && n <= 122) {
    enc_byte(e, (uint8_t)(n + 5));
    return;
  }
  if (n < 0 && n >= -123) {
    enc_byte(e, (uint8_t)(n - 5));
    return;
  }

  // Determine number of bytes needed
  int bytes;
  if (n > 0) {
    if (n <= 0xFF)
      bytes = 1;
    else if (n <= 0xFFFF)
      bytes = 2;
    else if (n <= 0xFFFFFF)
      bytes = 3;
    else
      bytes = 4;
    enc_byte(e, (uint8_t)bytes);
    for (int i = 0; i < bytes; i++) {
      enc_byte(e, (uint8_t)(n & 0xFF));
      n >>= 8;
    }
  } else {
    // Negative: use minimum bytes that sign-extend correctly
    if (n >= -(1LL << 7))
      bytes = 1;
    else if (n >= -(1LL << 15))
      bytes = 2;
    else if (n >= -(1LL << 23))
      bytes = 3;
    else
      bytes = 4;
    enc_byte(e, (uint8_t)(-bytes));
    for (int i = 0; i < bytes; i++) {
      enc_byte(e, (uint8_t)(n & 0xFF));
      n >>= 8;
    }
  }
}

// Intern symbol for encoder, returns symbol index or -1 if new.
static int enc_find_sym(RGSSMarshalEncoder *e, const char *sym) {
  for (size_t i = 0; i < e->sym_count; i++) {
    if (strcmp(e->sym_table[i], sym) == 0)
      return (int)i;
  }
  return -1;
}

static int enc_intern_sym(RGSSMarshalEncoder *e, const char *sym) {
  if (e->sym_count >= e->sym_cap) {
    size_t nc = e->sym_cap ? e->sym_cap * 2 : 16;
    char **t = realloc(e->sym_table, nc * sizeof(char *));
    if (!t) {
      e->last_error = RGSS_MARSHAL_ERR_ALLOC;
      return -1;
    }
    e->sym_table = t;
    e->sym_cap = nc;
  }
  e->sym_table[e->sym_count] = (char *)sym;
  return (int)(e->sym_count++);
}

// Write symbol (using back-ref if already seen)
static void enc_symbol(RGSSMarshalEncoder *e, const char *sym) {
  int idx = enc_find_sym(e, sym);
  if (idx >= 0) {
    enc_byte(e, ';');
    enc_int(e, (long long)idx);
  } else {
    enc_intern_sym(e, sym);
    enc_byte(e, ':');
    size_t slen = strlen(sym);
    enc_int(e, (long long)slen);
    enc_bytes(e, (const uint8_t *)sym, slen);
  }
}

// Register object pointer for back-ref tracking.
// Returns the existing index if already seen (for '@' ref), or -1 if new.
static int enc_find_obj(RGSSMarshalEncoder *e, const void *ptr) {
  for (size_t i = 0; i < e->obj_count; i++) {
    if (e->obj_table[i] == ptr)
      return (int)i;
  }
  return -1;
}

static void enc_register_obj(RGSSMarshalEncoder *e, const void *ptr) {
  if (e->obj_count >= e->obj_cap) {
    size_t nc = e->obj_cap ? e->obj_cap * 2 : 64;
    void **t = realloc(e->obj_table, nc * sizeof(void *));
    if (!t) {
      e->last_error = RGSS_MARSHAL_ERR_ALLOC;
      return;
    }
    e->obj_table = t;
    e->obj_cap = nc;
  }
  e->obj_table[e->obj_count++] = (void *)ptr;
}

// Forward declaration
static void encode_value(RGSSMarshalEncoder *e, const RGSSValue *v);

static void encode_value(RGSSMarshalEncoder *e, const RGSSValue *v) {
  if (e->last_error != RGSS_MARSHAL_OK)
    return;
  if (!v) {
    enc_byte(e, '0');
    return;
  } // nil

  switch (v->type) {
  case RGSS_VAL_NIL:
    enc_byte(e, '0');
    break;
  case RGSS_VAL_BOOL:
    enc_byte(e, v->as.b ? 'T' : 'F');
    break;
  case RGSS_VAL_INT:
    enc_byte(e, 'i');
    enc_int(e, v->as.i);
    break;
  case RGSS_VAL_FLOAT: {
    // Check for object back-ref
    int idx = enc_find_obj(e, v);
    if (idx >= 0) {
      enc_byte(e, '@');
      enc_int(e, (long long)idx);
      break;
    }
    enc_register_obj(e, v);
    enc_byte(e, 'f');
    char fbuf[64];
    if (isinf(v->as.f))
      snprintf(fbuf, sizeof(fbuf), v->as.f > 0 ? "inf" : "-inf");
    else if (isnan(v->as.f))
      snprintf(fbuf, sizeof(fbuf), "nan");
    else
      snprintf(fbuf, sizeof(fbuf), "%.17g", v->as.f);
    size_t flen = strlen(fbuf);
    enc_int(e, (long long)flen);
    enc_bytes(e, (const uint8_t *)fbuf, flen);
    break;
  }
  case RGSS_VAL_STRING: {
    int idx = enc_find_obj(e, v);
    if (idx >= 0) {
      enc_byte(e, '@');
      enc_int(e, (long long)idx);
      break;
    }
    // Wrap in 'I' to add encoding annotation (E => true = UTF-8)
    enc_byte(e, 'I');
    enc_register_obj(e, v);
    enc_byte(e, '"');
    enc_int(e, (long long)v->as.s.len);
    enc_bytes(e, v->as.s.data, v->as.s.len);
    // ivar: 1 pair: :E => true (UTF-8)
    enc_int(e, 1);
    enc_symbol(e, "E");
    enc_byte(e, 'T');
    break;
  }
  case RGSS_VAL_SYMBOL:
    enc_symbol(e, v->as.sym);
    break;
  case RGSS_VAL_ARRAY: {
    int idx = enc_find_obj(e, v);
    if (idx >= 0) {
      enc_byte(e, '@');
      enc_int(e, (long long)idx);
      break;
    }
    enc_register_obj(e, v);
    enc_byte(e, '[');
    enc_int(e, (long long)v->as.arr.count);
    for (size_t i = 0; i < v->as.arr.count; i++) {
      encode_value(e, v->as.arr.items[i]);
      if (e->last_error != RGSS_MARSHAL_OK)
        return;
    }
    break;
  }
  case RGSS_VAL_HASH: {
    int idx = enc_find_obj(e, v);
    if (idx >= 0) {
      enc_byte(e, '@');
      enc_int(e, (long long)idx);
      break;
    }
    enc_register_obj(e, v);
    enc_byte(e, '{');
    enc_int(e, (long long)v->as.hash.count);
    for (size_t i = 0; i < v->as.hash.count; i++) {
      encode_value(e, v->as.hash.keys[i]);
      if (e->last_error != RGSS_MARSHAL_OK)
        return;
      encode_value(e, v->as.hash.values[i]);
      if (e->last_error != RGSS_MARSHAL_OK)
        return;
    }
    break;
  }
  case RGSS_VAL_OBJECT: {
    int idx = enc_find_obj(e, v);
    if (idx >= 0) {
      enc_byte(e, '@');
      enc_int(e, (long long)idx);
      break;
    }
    enc_register_obj(e, v);
    enc_byte(e, 'o');
    enc_symbol(e, v->as.obj.class_name);
    enc_int(e, (long long)v->as.obj.ivars.count);
    for (size_t i = 0; i < v->as.obj.ivars.count; i++) {
      encode_value(e, v->as.obj.ivars.keys[i]);
      if (e->last_error != RGSS_MARSHAL_OK)
        return;
      encode_value(e, v->as.obj.ivars.values[i]);
      if (e->last_error != RGSS_MARSHAL_OK)
        return;
    }
    break;
  }
  }
}

int rgss_marshal_dump(RGSSMarshalEncoder *e, const RGSSValue *val) {
  if (e->last_error != RGSS_MARSHAL_OK)
    return -1;
  // Write header if this is the first call
  if (e->len == 0) {
    enc_byte(e, 0x04);
    enc_byte(e, 0x08);
  }
  encode_value(e, val);
  return (e->last_error == RGSS_MARSHAL_OK) ? 0 : -1;
}

const uint8_t *rgss_marshal_bytes(const RGSSMarshalEncoder *e) {
  return e->buf;
}

size_t rgss_marshal_length(const RGSSMarshalEncoder *e) { return e->len; }

const char *rgss_marshal_error_string(RGSSMarshalError err) {
  switch (err) {
  case RGSS_MARSHAL_OK:
    return "OK";
  case RGSS_MARSHAL_ERR_VERSION:
    return "not a Marshal 4.8 stream";
  case RGSS_MARSHAL_ERR_TRUNCATED:
    return "unexpected end of input";
  case RGSS_MARSHAL_ERR_UNSUPPORTED:
    return "unsupported type tag";
  case RGSS_MARSHAL_ERR_ALLOC:
    return "memory allocation failed";
  case RGSS_MARSHAL_ERR_OVERFLOW:
    return "integer or length overflow";
  default:
    return "unknown error";
  }
}

// ── Tree accessors (M6.0) ──────────────────────────────────────────────────
// Cho phép Swift đọc RGSSValue tree an toàn, tránh access C union trực tiếp
// (tên field `as` xung đột với Swift keyword, anonymous struct synthesized
// name).

RGSSValueType rgss_value_type(const RGSSValue *v) {
  if (!v)
    return RGSS_VAL_NIL;
  return v->type;
}

size_t rgss_value_array_count(const RGSSValue *v) {
  if (!v || v->type != RGSS_VAL_ARRAY)
    return 0;
  return v->as.arr.count;
}

const RGSSValue *rgss_value_array_item(const RGSSValue *v, size_t index) {
  if (!v || v->type != RGSS_VAL_ARRAY)
    return NULL;
  if (index >= v->as.arr.count)
    return NULL;
  return v->as.arr.items[index];
}

const uint8_t *rgss_value_string_data(const RGSSValue *v) {
  if (!v || v->type != RGSS_VAL_STRING)
    return NULL;
  return v->as.s.data;
}

size_t rgss_value_string_len(const RGSSValue *v) {
  if (!v || v->type != RGSS_VAL_STRING)
    return 0;
  return v->as.s.len;
}

long long rgss_value_int(const RGSSValue *v) {
  if (!v || v->type != RGSS_VAL_INT)
    return 0;
  return v->as.i;
}

const char *rgss_value_symbol_name(const RGSSValue *v) {
  if (!v || v->type != RGSS_VAL_SYMBOL)
    return NULL;
  return v->as.sym;
}

// ── Object / Hash accessors (M6.3) ────────────────────────────────────────
// Cho phép Swift đọc RPG::Map / RPG::Tileset / RPG::System từ .rvdata2
// (dùng cho TilemapRenderer khởi tạo tilemap).

const char *rgss_value_object_class_name(const RGSSValue *v) {
  if (!v || v->type != RGSS_VAL_OBJECT)
    return NULL;
  return v->as.obj.class_name;
}

size_t rgss_value_object_ivar_count(const RGSSValue *v) {
  if (!v || v->type != RGSS_VAL_OBJECT)
    return 0;
  return v->as.obj.ivars.count;
}

const RGSSValue *rgss_value_object_ivar_key(const RGSSValue *v, size_t index) {
  if (!v || v->type != RGSS_VAL_OBJECT)
    return NULL;
  if (index >= v->as.obj.ivars.count)
    return NULL;
  return v->as.obj.ivars.keys[index];
}

const RGSSValue *rgss_value_object_ivar_value(const RGSSValue *v,
                                              size_t index) {
  if (!v || v->type != RGSS_VAL_OBJECT)
    return NULL;
  if (index >= v->as.obj.ivars.count)
    return NULL;
  return v->as.obj.ivars.values[index];
}

size_t rgss_value_hash_count(const RGSSValue *v) {
  if (!v || v->type != RGSS_VAL_HASH)
    return 0;
  return v->as.hash.count;
}

const RGSSValue *rgss_value_hash_key(const RGSSValue *v, size_t index) {
  if (!v || v->type != RGSS_VAL_HASH)
    return NULL;
  if (index >= v->as.hash.count)
    return NULL;
  return v->as.hash.keys[index];
}

const RGSSValue *rgss_value_hash_value(const RGSSValue *v, size_t index) {
  if (!v || v->type != RGSS_VAL_HASH)
    return NULL;
  if (index >= v->as.hash.count)
    return NULL;
  return v->as.hash.values[index];
}
