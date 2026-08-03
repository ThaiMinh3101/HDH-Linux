// RPGPlayer/EngineRGSS/rgss_marshal.h
//
// Clean-room Ruby Marshal 4.8 reader/writer for RGSS save files.
//
// CLEAN-ROOM DECLARATION:
//   This implementation was written solely from the public Ruby language
//   documentation of the Marshal binary format (ruby-lang.org rdoc, community
//   format analysis that describes bytes without carrying GPL/LGPL code).
//   NO source code from mkxp, mkxp-z, or any GPL/LGPL engine was read or
//   referenced during authorship.
//
// Supported type tags (subset used by RPG Maker XP/VX/VXAce save files):
//   0x30 '0'  nil
//   0x54 'T'  true
//   0x46 'F'  false
//   0x69 'i'  Integer (Fixnum, variable-length signed)
//   0x66 'f'  Float  (stored as decimal string)
//   0x22 '"'  String (raw bytes)
//   0x3A ':'  Symbol (new)
//   0x3B ';'  Symbol link (back-reference into symbol table)
//   0x40 '@'  Object link (back-reference into object table)
//   0x5B '['  Array
//   0x7B '{'  Hash
//   0x6F 'o'  Object (class instance with ivar hash)
//   0x49 'I'  Instance variable wrapper (e.g., String + encoding ivar)
//
// NOT supported (not emitted by RPG Maker save routines):
//   Bignum, Regex, Struct, Module, Class, Data, extended object.

#ifndef RGSS_MARSHAL_H
#define RGSS_MARSHAL_H

#include <stddef.h>
#include <stdint.h>

// ── Error codes ────────────────────────────────────────────────────────────

typedef enum {
  RGSS_MARSHAL_OK = 0,
  RGSS_MARSHAL_ERR_VERSION = -1,     // not a Marshal stream or wrong version
  RGSS_MARSHAL_ERR_TRUNCATED = -2,   // unexpected end of input
  RGSS_MARSHAL_ERR_UNSUPPORTED = -3, // type tag not supported
  RGSS_MARSHAL_ERR_ALLOC = -4,       // memory allocation failed
  RGSS_MARSHAL_ERR_OVERFLOW = -5,    // integer/length out of range
} RGSSMarshalError;

// ── Value types ────────────────────────────────────────────────────────────

typedef enum {
  RGSS_VAL_NIL = 0,
  RGSS_VAL_BOOL,
  RGSS_VAL_INT,
  RGSS_VAL_FLOAT,
  RGSS_VAL_STRING,
  RGSS_VAL_SYMBOL,
  RGSS_VAL_ARRAY,
  RGSS_VAL_HASH,
  RGSS_VAL_OBJECT, // generic class instance
} RGSSValueType;

struct RGSSValue;
typedef struct RGSSValue RGSSValue;

typedef struct {
  RGSSValue **items;
  size_t count;
} RGSSArray;

typedef struct {
  RGSSValue **keys;
  RGSSValue **values;
  size_t count;
} RGSSHash;

typedef struct {
  char *class_name; // null-terminated, owned
  RGSSHash ivars;   // instance variable hash
} RGSSObject;

struct RGSSValue {
  RGSSValueType type;
  union {
    int b;       // BOOL (0 = false, 1 = true)
    long long i; // INT
    double f;    // FLOAT
    struct {
      uint8_t *data;
      size_t len;
    } s;            // STRING (raw bytes, not null-terminated)
    char *sym;      // SYMBOL (null-terminated, owned)
    RGSSArray arr;  // ARRAY
    RGSSHash hash;  // HASH
    RGSSObject obj; // OBJECT
  } as;
};

// ── Allocator context ──────────────────────────────────────────────────────
// All allocations go through a bump arena — cheap and trivially freed.
// Full struct definition is exposed here so .c files that need to create
// stack-allocated dummy arenas (e.g. mruby_marshal_binding.c) can do so
// without requiring a public rgss_arena_alloc() API.

typedef struct RGSSArena {
  uint8_t *base;
  size_t cap;
  size_t used;
} RGSSArena;

RGSSArena *rgss_arena_create(size_t capacity); // suggested: 2 MB
void rgss_arena_destroy(RGSSArena *a);

// ── Decoder ───────────────────────────────────────────────────────────────

typedef struct {
  const uint8_t *buf;
  size_t len;
  size_t pos;

  // Symbol / object back-reference tables (grow dynamically)
  char **sym_table;
  size_t sym_count;
  size_t sym_cap;

  RGSSValue **obj_table;
  size_t obj_count;
  size_t obj_cap;

  RGSSArena *arena;
  RGSSMarshalError last_error;
} RGSSMarshalDecoder;

// Initialise decoder for a Marshal stream (does NOT take ownership of buf).
// arena is used for all allocations; caller owns it.
void rgss_marshal_decoder_init(RGSSMarshalDecoder *d, const uint8_t *buf,
                               size_t len, RGSSArena *arena);

// Decode the entire stream. Returns NULL on error; check d->last_error.
RGSSValue *rgss_marshal_load(RGSSMarshalDecoder *d);

// Free the decoder's internal symbol/object back-reference tables.
// The decoded tree itself lives in the arena (still valid until
// rgss_arena_destroy). Safe to call even if no decode happened.
void rgss_marshal_decoder_free_tables(RGSSMarshalDecoder *d);

// ── Encoder ───────────────────────────────────────────────────────────────

typedef struct {
  uint8_t *buf;
  size_t len;
  size_t cap;

  char **sym_table; // interned symbols (for ';' back-refs)
  size_t sym_count;
  size_t sym_cap;

  void **obj_table; // encoded object pointers (for '@' back-refs)
  size_t obj_count;
  size_t obj_cap;

  RGSSMarshalError last_error;
} RGSSMarshalEncoder;

void rgss_marshal_encoder_init(RGSSMarshalEncoder *e);
void rgss_marshal_encoder_free(RGSSMarshalEncoder *e);

// Encode a single RGSSValue tree into the encoder's buffer.
int rgss_marshal_dump(RGSSMarshalEncoder *e, const RGSSValue *val);

// Access encoded bytes.
const uint8_t *rgss_marshal_bytes(const RGSSMarshalEncoder *e);
size_t rgss_marshal_length(const RGSSMarshalEncoder *e);

// ── Convenience helpers ────────────────────────────────────────────────────

// Human-readable string for an error code (static, no allocation).
const char *rgss_marshal_error_string(RGSSMarshalError err);

// ── Tree accessors (M6.0) ──────────────────────────────────────────────────
// Swift tránh access C union/struct trực tiếp (tên field `as` xung đột với
// Swift keyword, anonymous struct có tên synthesized không ổn định).
// Các hàm này cho phép đọc RGSSValue tree một cách an toàn từ Swift.

// Returns the RGSSValueType of the value.
RGSSValueType rgss_value_type(const RGSSValue *v);

// Array access.
size_t rgss_value_array_count(const RGSSValue *v);
const RGSSValue *rgss_value_array_item(const RGSSValue *v, size_t index);

// String access (raw bytes, may contain NUL).
const uint8_t *rgss_value_string_data(const RGSSValue *v);
size_t rgss_value_string_len(const RGSSValue *v);

// Integer access.
long long rgss_value_int(const RGSSValue *v);

// Symbol access (M6.3): symbol name as C string (null-terminated).
// Returns NULL if v is not a SYMBOL.
const char *rgss_value_symbol_name(const RGSSValue *v);

// Object access (M6.3): class names + ivars for reading .rvdata2 data files.
// Return the class name of an OBJECT value (e.g. "RPG::Map", "RPG::Tileset").
// Returns NULL if v is not an OBJECT.
const char *rgss_value_object_class_name(const RGSSValue *v);

// Number of instance variables on an OBJECT value.
size_t rgss_value_object_ivar_count(const RGSSValue *v);

// The i-th ivar key (a SYMBOL value) or NULL if out of range / not OBJECT.
const RGSSValue *rgss_value_object_ivar_key(const RGSSValue *v, size_t index);

// The i-th ivar value (any type) or NULL if out of range / not OBJECT.
const RGSSValue *rgss_value_object_ivar_value(const RGSSValue *v, size_t index);

// Hash access (M6.3): RPG::Map.events is a Hash keyed by Integer event id.
// Count of key/value pairs in a HASH value.
size_t rgss_value_hash_count(const RGSSValue *v);

// The i-th hash key (any type) or NULL if out of range / not HASH.
const RGSSValue *rgss_value_hash_key(const RGSSValue *v, size_t index);

// The i-th hash value (any type) or NULL if out of range / not HASH.
const RGSSValue *rgss_value_hash_value(const RGSSValue *v, size_t index);

#endif /* RGSS_MARSHAL_H */
