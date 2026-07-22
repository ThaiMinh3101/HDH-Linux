#!/usr/bin/env bash
# Tạo 5 file ZIP mẫu để test từng nhánh GameDetector
# Chạy: chmod +x make_test_zips.sh && ./make_test_zips.sh

set -e
OUT="$HOME/Desktop/RPGPlayer_TestZips"
mkdir -p "$OUT"

echo "📦 Tạo test ZIPs vào: $OUT"

# ---- 1. RPG Maker XP (có Game.rgssad) ----
TMP=$(mktemp -d)
mkdir -p "$TMP/XP_Demo/Data"
touch "$TMP/XP_Demo/Game.rgssad"
printf "[Game]\nTitle=Test Game XP\nRTP=\n" > "$TMP/XP_Demo/Game.ini"
touch "$TMP/XP_Demo/Game.exe"
touch "$TMP/XP_Demo/Data/Actors.rxdata"
(cd "$TMP" && zip -qr "$OUT/xp_demo.zip" XP_Demo/)
rm -rf "$TMP"
echo "  ✅ xp_demo.zip (expected: XP)"

# ---- 2. RPG Maker VX (có Game.rgss2a) ----
TMP=$(mktemp -d)
mkdir -p "$TMP/VX_Demo/Data"
touch "$TMP/VX_Demo/Game.rgss2a"
printf "[Game]\nTitle=Test Game VX\nRTP=\n" > "$TMP/VX_Demo/Game.ini"
touch "$TMP/VX_Demo/Data/Actors.rvdata"
(cd "$TMP" && zip -qr "$OUT/vx_demo.zip" VX_Demo/)
rm -rf "$TMP"
echo "  ✅ vx_demo.zip (expected: VX)"

# ---- 3. RPG Maker VX Ace (có Game.rgss3a) ----
TMP=$(mktemp -d)
mkdir -p "$TMP/VXAce_Demo/Data"
touch "$TMP/VXAce_Demo/Game.rgss3a"
printf "[Game]\nTitle=Test Game VX Ace\nRTP=\n" > "$TMP/VXAce_Demo/Game.ini"
touch "$TMP/VXAce_Demo/Data/Actors.rvdata2"
(cd "$TMP" && zip -qr "$OUT/vxace_demo.zip" VXAce_Demo/)
rm -rf "$TMP"
echo "  ✅ vxace_demo.zip (expected: VX Ace)"

# ---- 4. RPG Maker MV (có www/js/rpg_core.js) ----
TMP=$(mktemp -d)
mkdir -p "$TMP/MV_Demo/www/js"
touch "$TMP/MV_Demo/www/index.html"
echo "// RPG Maker MV - rpg_core.js stub" > "$TMP/MV_Demo/www/js/rpg_core.js"
printf '{"name":"mv-demo","version":"1.0.0","title":"MV Demo Game"}' > "$TMP/MV_Demo/package.json"
(cd "$TMP" && zip -qr "$OUT/mv_demo.zip" MV_Demo/)
rm -rf "$TMP"
echo "  ✅ mv_demo.zip (expected: MV)"

# ---- 5. RPG Maker MZ (có www/js/rmmz_core.js) ----
TMP=$(mktemp -d)
mkdir -p "$TMP/MZ_Demo/www/js"
touch "$TMP/MZ_Demo/www/index.html"
echo "// RPG Maker MZ - rmmz_core.js stub" > "$TMP/MZ_Demo/www/js/rmmz_core.js"
echo "// rmmz_managers stub" > "$TMP/MZ_Demo/www/js/rmmz_managers.js"
printf '{"name":"mz-demo","version":"1.0.0","title":"MZ Demo Game"}' > "$TMP/MZ_Demo/package.json"
(cd "$TMP" && zip -qr "$OUT/mz_demo.zip" MZ_Demo/)
rm -rf "$TMP"
echo "  ✅ mz_demo.zip (expected: MZ)"

# ---- 6. Unknown (không hợp lệ) ----
TMP=$(mktemp -d)
mkdir -p "$TMP/Unknown_Demo"
echo "This is not a valid RPG Maker game" > "$TMP/Unknown_Demo/README.txt"
touch "$TMP/Unknown_Demo/somefile.dat"
(cd "$TMP" && zip -qr "$OUT/unknown_demo.zip" Unknown_Demo/)
rm -rf "$TMP"
echo "  ✅ unknown_demo.zip (expected: ??? / lỗi rõ ràng)"

# ---- 7. MZ lồng trong subfolder (test resolveGameRoot) ----
TMP=$(mktemp -d)
mkdir -p "$TMP/www/js"  # nested dưới root thêm 1 lớp
touch "$TMP/www/index.html"
echo "// rmmz_core stub" > "$TMP/www/js/rmmz_core.js"
printf '{"title":"Nested MZ Game"}' > "$TMP/package.json"
NESTED_DIR=$(mktemp -d)
cp -r "$TMP" "$NESTED_DIR/NestedGame"
(cd "$NESTED_DIR" && zip -qr "$OUT/mz_nested.zip" NestedGame/)
rm -rf "$TMP" "$NESTED_DIR"
echo "  ✅ mz_nested.zip (expected: MZ — test nested folder detection)"

echo ""
echo "🎉 Xong! 7 file ZIP đã tạo trong: $OUT"
echo ""
echo "Cách dùng:"
echo "  1. Mở app RPGPlayer trên Simulator"
echo "  2. Tap '+' → chọn từng file .zip trong $OUT"
echo "  3. Kiểm tra badge engine hiển thị đúng theo expected ở trên"
