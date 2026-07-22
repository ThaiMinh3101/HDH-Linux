#!/usr/bin/env bash
# Scripts/build_mruby.sh
# Cross-compile mruby 3.3.0 for iOS arm64 (device + simulator).
# Produces:
#   Frameworks/mruby.xcframework      — XCFramework for Xcode linkage
#   Frameworks/mruby-headers/         — flat header copy for HEADER_SEARCH_PATHS
#
# License: mruby — MIT (https://github.com/mruby/mruby/blob/master/LICENSE)
# Called from: .github/workflows/build-ios.yml
# Prereqs: macOS + Xcode CLT, Ruby + rake (both on macos-15 runner by default)

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
MRUBY_VERSION="3.3.0"
MRUBY_TARBALL="/tmp/mruby-${MRUBY_VERSION}.tar.gz"
MRUBY_DIR="/tmp/mruby-${MRUBY_VERSION}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
FRAMEWORKS_DIR="$REPO_ROOT/Frameworks"
XCFRAMEWORK_OUT="$FRAMEWORKS_DIR/mruby.xcframework"
HEADERS_OUT="$FRAMEWORKS_DIR/mruby-headers"
BUILD_CONFIG="$SCRIPT_DIR/build_config_ios.rb"

echo "==================================================================="
echo " Building mruby ${MRUBY_VERSION} for iOS arm64"
echo "==================================================================="
echo " Repo root      : $REPO_ROOT"
echo " Frameworks dir : $FRAMEWORKS_DIR"
echo " Build config   : $BUILD_CONFIG"
echo ""

# ── Verify Xcode toolchain ───────────────────────────────────────────────────
echo "── Xcode toolchain ─────────────────────────────────────────────────"
xcode-select --print-path
xcrun --sdk iphoneos --show-sdk-path
xcrun --sdk iphonesimulator --show-sdk-path
echo ""

# ── Verify rake ──────────────────────────────────────────────────────────────
echo "── rake / ruby ─────────────────────────────────────────────────────"
ruby --version
if ! command -v rake &>/dev/null; then
  echo "rake not found — installing..."
  gem install rake --no-document
fi
rake --version
echo ""

# ── Download mruby source ────────────────────────────────────────────────────
echo "── Downloading mruby ${MRUBY_VERSION} ──────────────────────────────"
if [ ! -f "$MRUBY_TARBALL" ]; then
  curl -fL \
    "https://github.com/mruby/mruby/archive/refs/tags/${MRUBY_VERSION}.tar.gz" \
    -o "$MRUBY_TARBALL"
  echo "✅ Downloaded"
else
  echo "  (using cached tarball)"
fi

rm -rf "$MRUBY_DIR"
tar -xf "$MRUBY_TARBALL" -C /tmp
echo "✅ Extracted to $MRUBY_DIR"
echo ""

# ── Copy build config ────────────────────────────────────────────────────────
cp "$BUILD_CONFIG" "$MRUBY_DIR/build_config_ios.rb"

# ── Build with rake ──────────────────────────────────────────────────────────
echo "── rake (estimating 3–5 min) ───────────────────────────────────────"
cd "$MRUBY_DIR"
MRUBY_CONFIG="$MRUBY_DIR/build_config_ios.rb" rake 2>&1 | tee /tmp/mruby_build.log
echo ""
echo "✅ rake finished"
echo ""

# ── Verify artifacts ─────────────────────────────────────────────────────────
echo "── Verifying build artifacts ───────────────────────────────────────"
IOS_LIB="$MRUBY_DIR/build/ios/lib/libmruby.a"
SIM_LIB="$MRUBY_DIR/build/ios-sim/lib/libmruby.a"
INCLUDE_DIR="$MRUBY_DIR/include"

MISSING=0
for ARTIFACT in "$IOS_LIB" "$SIM_LIB" "$INCLUDE_DIR/mruby.h"; do
  if [ -e "$ARTIFACT" ]; then
    echo "  ✅ $ARTIFACT"
  else
    echo "  ❌ MISSING: $ARTIFACT"
    MISSING=1
  fi
done

if [ "$MISSING" -eq 1 ]; then
  echo ""
  echo "=== Last 60 lines of mruby build log ==="
  tail -60 /tmp/mruby_build.log
  echo ""
  echo "❌ mruby build failed — see log above"
  exit 1
fi

# Print sizes
echo ""
echo "  iOS device  lib: $(du -sh "$IOS_LIB" | cut -f1)"
echo "  iOS sim     lib: $(du -sh "$SIM_LIB" | cut -f1)"
echo ""

# ── Verify arm64 architecture ────────────────────────────────────────────────
echo "── Checking architectures ──────────────────────────────────────────"
file "$IOS_LIB"
file "$SIM_LIB"
echo ""

# ── Create Frameworks directory ──────────────────────────────────────────────
mkdir -p "$FRAMEWORKS_DIR"
rm -rf "$XCFRAMEWORK_OUT"

# ── Create XCFramework ───────────────────────────────────────────────────────
echo "── Creating mruby.xcframework ──────────────────────────────────────"
xcodebuild -create-xcframework \
  -library "$IOS_LIB" \
  -headers "$INCLUDE_DIR" \
  -library "$SIM_LIB" \
  -headers "$INCLUDE_DIR" \
  -output "$XCFRAMEWORK_OUT"
echo "✅ XCFramework: $XCFRAMEWORK_OUT"
echo ""

# ── Copy flat headers (stable HEADER_SEARCH_PATHS target) ───────────────────
echo "── Copying headers to mruby-headers/ ───────────────────────────────"
rm -rf "$HEADERS_OUT"
mkdir -p "$HEADERS_OUT"
cp -R "$INCLUDE_DIR/." "$HEADERS_OUT/"
H_COUNT=$(find "$HEADERS_OUT" -name "*.h" | wc -l | tr -d ' ')
echo "✅ $H_COUNT header files at $HEADERS_OUT"
echo ""

# ── Summary ──────────────────────────────────────────────────────────────────
echo "==================================================================="
echo " mruby ${MRUBY_VERSION} build complete"
echo ""
echo " XCFramework : $XCFRAMEWORK_OUT"
echo " Headers     : $HEADERS_OUT"
echo "==================================================================="
echo ""
echo "── XCFramework structure (depth 3) ─────────────────────────────────"
find "$XCFRAMEWORK_OUT" -maxdepth 3 | head -30
