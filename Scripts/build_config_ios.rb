# Scripts/build_config_ios.rb
# mruby 3.3.x cross-compile configuration for iOS arm64 (device + simulator)
#
# License: mruby — MIT License (https://github.com/mruby/mruby/blob/master/LICENSE)
# This file is called by rake via:  MRUBY_CONFIG=<path> rake
#
# Outputs (relative to mruby source root):
#   build/ios/lib/libmruby.a        — arm64 iOS device
#   build/ios-sim/lib/libmruby.a    — arm64 iOS Simulator (Apple Silicon)
#   include/                         — mruby public headers
#
# Notes:
#   - mruby-io is EXCLUDED: it uses fork()/pipe()/exec() which are unavailable
#     in the iOS process sandbox. All other standard mruby gems are included.
#   - Marshal / Encoding are not present in mruby (it's a subset Ruby).
#     RGSS save data using Marshal will be addressed at Milestone 3 (Save & iCloud).

# ── Host build (macOS x86_64/arm64) ─────────────────────────────────────────
# Required: mruby's own build tools (mrbc) must run on the host during the build.
MRuby::Build.new do |conf|
  toolchain :clang
  conf.gembox "default"
end

# ── iOS Device — arm64 ───────────────────────────────────────────────────────
MRuby::CrossBuild.new("ios") do |conf|
  toolchain :clang

  ios_sdk = `xcrun --sdk iphoneos --show-sdk-path 2>/dev/null`.strip
  ios_cc  = `xcrun --sdk iphoneos --find clang 2>/dev/null`.strip
  ios_ar  = `xcrun --sdk iphoneos --find ar 2>/dev/null`.strip

  conf.cc do |cc|
    cc.command = ios_cc
    cc.flags = [
      "-arch", "arm64",
      "-miphoneos-version-min=17.0",
      "-isysroot", ios_sdk,
      "-fembed-bitcode",
      "-g", "-std=gnu99",
      "-DTARGET_OS_IPHONE=1",
      "-Wall", "-Wno-unused-function", "-Wno-shorten-64-to-32"
    ]
    cc.include_paths << "#{root}/include"
  end

  conf.archiver do |ar|
    ar.command = ios_ar
    # MRuby::Command::Archiver 3.3.0: attribute is `archive_options` (format string),
    # NOT `flags` (which does not exist on Archiver — only on Compiler/Linker).
    # Confirmed from mruby/mruby@3.3.0 lib/mruby/build/command.rb: attr_accessor :archive_options
    # Placeholders: %{outfile} = output .a path, %{objs} = space-separated .o files.
    # 'rcs': r=insert/replace, c=create if not exist, s=write symbol table index.
    ar.archive_options = 'rcs %{outfile} %{objs}'
  end

  conf.linker do |linker|
    linker.command = ios_cc
    linker.flags = ["-arch", "arm64", "-isysroot", ios_sdk]
  end

  conf.bins = []   # No standalone executables — library only

  # ── Gem selection (default minus mruby-io) ───────────────────────────────
  conf.gem :core => "mruby-sprintf"
  conf.gem :core => "mruby-print"
  conf.gem :core => "mruby-gemcut"
  conf.gem :core => "mruby-metaprog"
  conf.gem :core => "mruby-method"
  conf.gem :core => "mruby-fiber"       # Important: RGSS uses fibers for scene loops
  conf.gem :core => "mruby-proc-ext"
  conf.gem :core => "mruby-enumerator"
  conf.gem :core => "mruby-string-ext"
  conf.gem :core => "mruby-numeric-ext"
  conf.gem :core => "mruby-array-ext"
  conf.gem :core => "mruby-hash-ext"
  conf.gem :core => "mruby-comparable"
  conf.gem :core => "mruby-compar-ext"
  conf.gem :core => "mruby-enum-ext"
  conf.gem :core => "mruby-math"
  conf.gem :core => "mruby-time"
  conf.gem :core => "mruby-struct"
  conf.gem :core => "mruby-class-ext"
  conf.gem :core => "mruby-object-ext"
  conf.gem :core => "mruby-toplevel-ext"
  conf.gem :core => "mruby-kernel-ext"
  conf.gem :core => "mruby-objectspace"
  conf.gem :core => "mruby-range-ext"
  conf.gem :core => "mruby-eval"        # RGSS scripts use eval extensively
  # EXCLUDED: mruby-io   — uses fork()/pipe() unavailable on iOS
  # EXCLUDED: mruby-pack — binary packing, not needed for M1b
end

# ── iOS Simulator — arm64 (Apple Silicon Mac) ─────────────────────────────
MRuby::CrossBuild.new("ios-sim") do |conf|
  toolchain :clang

  sim_sdk = `xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null`.strip
  sim_cc  = `xcrun --sdk iphonesimulator --find clang 2>/dev/null`.strip
  sim_ar  = `xcrun --sdk iphonesimulator --find ar 2>/dev/null`.strip

  conf.cc do |cc|
    cc.command = sim_cc
    cc.flags = [
      "-arch", "arm64",
      "-mios-simulator-version-min=17.0",
      "-isysroot", sim_sdk,
      "-g", "-std=gnu99",
      "-DTARGET_OS_IPHONE=1",
      "-Wall", "-Wno-unused-function", "-Wno-shorten-64-to-32"
    ]
    cc.include_paths << "#{root}/include"
  end

  conf.archiver do |ar|
    ar.command = sim_ar
    # MRuby::Command::Archiver 3.3.0: attribute is `archive_options` (format string),
    # NOT `flags`. Same fix as iOS device target above.
    ar.archive_options = 'rcs %{outfile} %{objs}'
  end

  conf.linker do |linker|
    linker.command = sim_cc
    linker.flags = ["-arch", "arm64", "-isysroot", sim_sdk]
  end

  conf.bins = []

  # Same gem set as device target
  conf.gem :core => "mruby-sprintf"
  conf.gem :core => "mruby-print"
  conf.gem :core => "mruby-gemcut"
  conf.gem :core => "mruby-metaprog"
  conf.gem :core => "mruby-method"
  conf.gem :core => "mruby-fiber"
  conf.gem :core => "mruby-proc-ext"
  conf.gem :core => "mruby-enumerator"
  conf.gem :core => "mruby-string-ext"
  conf.gem :core => "mruby-numeric-ext"
  conf.gem :core => "mruby-array-ext"
  conf.gem :core => "mruby-hash-ext"
  conf.gem :core => "mruby-comparable"
  conf.gem :core => "mruby-compar-ext"
  conf.gem :core => "mruby-enum-ext"
  conf.gem :core => "mruby-math"
  conf.gem :core => "mruby-time"
  conf.gem :core => "mruby-struct"
  conf.gem :core => "mruby-class-ext"
  conf.gem :core => "mruby-object-ext"
  conf.gem :core => "mruby-toplevel-ext"
  conf.gem :core => "mruby-kernel-ext"
  conf.gem :core => "mruby-objectspace"
  conf.gem :core => "mruby-range-ext"
  conf.gem :core => "mruby-eval"
end
