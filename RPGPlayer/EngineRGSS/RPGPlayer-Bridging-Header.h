// RPGPlayer/EngineRGSS/RPGPlayer-Bridging-Header.h
//
// Swift ↔ Objective-C/C bridging header.
// Exposes mruby C API and RGSS bridge functions to Swift code.

#ifndef RPGPlayer_Bridging_Header_h
#define RPGPlayer_Bridging_Header_h

// mruby public API (from mruby XCFramework headers)
#include <mruby.h>
#include <mruby/compile.h>

// RGSS C bridge (M1b: Sprite class + script runner)
#include "mruby_bridge.h"

#endif /* RPGPlayer_Bridging_Header_h */
