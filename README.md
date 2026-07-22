# RPG Player — iOS

App iOS chơi game RPG Maker (XP, VX, VX Ace, MV, MZ) trên iPhone/iPad.  
Dự án cá nhân, phân phối qua TestFlight / sideload — không public.

---

## Cấu trúc project

```
RPGPlayer/
├── App/            SwiftUI entry point
├── Core/
│   ├── Library/    GameDetector, LibraryStore, ZipImporter
│   └── Storage/    StorageManager
└── UI/Library/     LibraryView, GameCardView, ImportProgressView
RPGPlayerTests/     XCTest unit tests
project.yml         xcodegen spec (source of truth cho .xcodeproj)
```

## Phát triển cục bộ

**Yêu cầu:** Xcode 15.4+ · iOS 17 SDK · [xcodegen](https://github.com/yonaskolb/XcodeGen)

```bash
# Cài xcodegen (1 lần)
brew install xcodegen

# Generate .xcodeproj từ project.yml rồi mở
xcodegen generate --spec project.yml
open RPGPlayer.xcodeproj
```

> `.xcodeproj` được sinh tự động từ `project.yml` — đây là file nguồn sự thật.  
> Không cần commit `.xcodeproj` nếu chạy lệnh trên trước khi mở.

---

## Cách build & cài thử (không cần Xcode trên máy)

> **CI runner:** `macos-15` (Sequoia) · Xcode 16.x · iOS 18 SDK  
> Deployment target vẫn là iOS 17 — app chạy được từ iOS 17 trở lên.

### Bước 1 — Trigger build trên GitHub Actions

1. Vào repo trên GitHub → tab **Actions**
2. Chọn workflow **"Build iOS IPA"** (cột trái)
3. Bấm nút **"Run workflow"** (góc phải) → điền ghi chú nếu muốn → **"Run workflow"**
4. Đợi ~5–10 phút, workflow chuyển sang ✅ xanh
5. Bấm vào run vừa xong → kéo xuống mục **Artifacts** → tải file **`RPGPlayer-<hash>-<số>.ipa`**

> Workflow **chỉ chạy khi bấm nút thủ công**, không tự chạy khi push code.

### Bước 2 — Sideload bằng AltServer

**Windows:**
1. Cài [AltServer cho Windows](https://altstore.io)
2. Mở iTunes, cắm iPhone/iPad vào máy bằng USB
3. Click icon AltServer ở System Tray → **"Sideload .ipa…"**
4. Chọn file `.ipa` vừa tải về
5. Nhập **Apple ID cá nhân** (tài khoản thường, không cần trả phí)
6. Chờ cài xong → vào **Settings → General → VPN & Device Management** → Trust app

**macOS:**
1. Cài AltServer, bật trong menu bar
2. Cắm thiết bị hoặc dùng WiFi sync (cùng mạng)
3. Quy trình tương tự như Windows

> ⚠️ App sideload bằng Apple ID miễn phí **hết hạn sau 7 ngày** — cần sideload lại.  
> Dùng tài khoản Apple Developer ($99/năm) để có 1 năm, hoặc dùng AltStore để tự refresh.

### Cách nhận biết các lần build

Tên artifact có dạng: `RPGPlayer-<git-commit-hash>-<run-number>`  
Ví dụ: `RPGPlayer-4b1ff92abc-12` → commit `4b1ff92`, lần chạy thứ 12.

---

## Roadmap Milestone

| # | Milestone | Trạng thái |
|---|-----------|-----------| 
| M0 | Khung app, Library UI, Import ZIP, GameDetector | ✅ Xong |
| M1a | Engine MV/MZ (WKWebView + JS shim) | ✅ Xong |
| M1b | Engine RGSS "Hello Sprite" (mruby + Metal) | 🔧 In progress |
| M2 | Input (GameController + D-pad ảo) | 🔲 |
| M3 | Save game + iCloud sync | 🔲 |
| M4 | Plugin manager, chống crash, dọn cache | 🔲 |
| M5 | Dịch + tối ưu 60fps | 🔲 |

---

## M1b — Engine RGSS "Hello Sprite": Chi tiết kỹ thuật

### Mục tiêu

Chứng minh pipeline **Ruby script → Ruby C binding → Metal render** hoạt động
trước khi làm bất kỳ tính năng RGSS nào khác.

### Cấu trúc file mới

```
RPGPlayer/EngineRGSS/
├── mruby_bridge.h           C API: SpriteSetBitmapCallback, mrb_define_sprite_class
├── mruby_bridge.c           C impl: Sprite.new, Sprite#bitmap= (clean-room)
├── RPGPlayer-Bridging-Header.h  Swift ↔ C bridging header
├── RubyBridge.swift         Swift wrapper quản lý mruby VM lifecycle
├── Shaders.metal            Vertex/fragment shader cho full-screen sprite quad
├── SpriteRenderer.swift     MTKView renderer, load PNG texture / fallback
├── RGSSViewController.swift UIViewController: host MTKView + chạy Ruby script
└── RGSSEngineView.swift     SwiftUI wrapper (UIViewControllerRepresentable)

Scripts/
├── build_config_ios.rb      mruby cross-compile config (arm64 device + sim)
└── build_mruby.sh           CI script: download→build→XCFramework mruby 3.3.0
```

### Luồng data

```
RGSSViewController.viewDidLoad()
  └─ setupMetal()  →  SpriteRenderer (MTKView delegate, 60fps loop)
  └─ startRubyEngine()  →  RubyBridge.start(script:, renderer:)
       └─ mrb_open()
       └─ mrb_define_sprite_class(mrb, callback)   [C]
       └─ mrb_bridge_run_script(mrb, "sprite = Sprite.new\nsprite.bitmap = 'test.png'")
            └─ Sprite#bitmap= fires C callback
                 └─ DispatchQueue.main: SpriteRenderer.loadTexture("test.png")
                      └─ MTKTextureLoader (bundle PNG) | fallback checkerboard
                           └─ MTKView.draw() → renders texture at 60fps
```

### mruby vs CRuby — lý do chọn mruby

| | mruby (MIT) | CRuby/MRI |
|---|---|---|
| Cross-compile iOS | ✅ Documented, stable | ❌ Rất phức tạp, không official |
| License | ✅ MIT | ✅ Ruby/BSD |
| Marshal.load | ❌ Không có | ✅ Có sẵn |
| RGSS script cơ bản | ✅ Đủ | ✅ Đủ |

> **Nợ kỹ thuật ghi nhận:** `Marshal` và `Encoding` không có trong mruby.
> RGSS save data (`.rxdata`, `.rvdata`, `.rvdata2`) dùng `Marshal.load` — sẽ
> implement custom Marshal reader ở **Milestone 3 (Save & iCloud)**.

### Gems được include (mruby-io bị loại)

mruby-io bị exclude vì nó dùng `fork()`/`pipe()` — không có trên iOS sandbox.
Tất cả gems khác trong `default` gembox đều được include, bao gồm `mruby-fiber`
(quan trọng cho scene loop của RGSS) và `mruby-eval` (RGSS scripts dùng `eval`).

### Fallback texture

Nếu `test.png` không có trong bundle, `SpriteRenderer` tự tạo một checkerboard
64×64 orange/teal — vẫn chứng minh Metal pipeline hoạt động.

### CI pipeline (thêm vào M1a)

Bước mới trong `build-ios.yml` (chạy trước `xcodegen generate`):
1. `Scripts/build_mruby.sh` — download mruby 3.3.0, cross-compile → `Frameworks/mruby.xcframework`
2. Verify: kiểm tra `Frameworks/mruby-headers/mruby.h` tồn tại
3. Ước tính thêm ~3–5 phút vào tổng thời gian build

> `Frameworks/` được gitignore — rebuild từ source mỗi lần CI.

---

## M1a — Engine MV/MZ: Chi tiết kỹ thuật

### Cấu trúc file mới

```
RPGPlayer/
├── App/
│   ├── RPGPlayerApp.swift  (đã sửa: thêm @UIApplicationDelegateAdaptor)
│   └── AppDelegate.swift   (mới: runtime orientation lock)
├── Core/Engine/
│   └── RPGGameSchemeHandler.swift  (mới: custom URL scheme handler)
├── UI/Game/
│   ├── GameDetailViewMV.swift      (mới: SwiftUI wrapper)
│   └── GamePlayerViewController.swift  (mới: WKWebView + message handlers)
├── UI/Library/
│   └── GameCardView.swift  (đã sửa: NavigationLink cho MV/MZ)
└── Resources/
    ├── NWJSPolyfill.js  (mới: stub window.nw / process / require)
    └── SaveBridge.js    (mới: save game bridge JS → Swift)
```

### Đo FPS

`NWJSPolyfill.js` tự động cài FPS monitor: đo qua `requestAnimationFrame`, log ra console
mm 5 giây một lần. Xem trong Xcode console dạng:
```
[GamePlayer][FPS] 59.8 fps (avg over 5s)
[GamePlayer][WebGL] Renderer: Apple GPU
```

### NW.js API đã stub

| API | Mức độ |
|---|---|
| `window.nw.App` (argv, dataPath, quit, clearCache) | ✅ Stub đủ |
| `window.nw.Window.get()` | ✅ Fake object |
| `window.nw.Screen` | ✅ Fake (1 screen) |
| `window.nw.Shell` | ✅ No-op |
| `window.nw.Clipboard` | ✅ Fake |
| `require('nw.gui')` | ✅ Return `window.nw` |
| `require('path')` | ✅ join/dirname/basename/extname |
| `require('fs')` | ⚠️ Safe mock (readFileSync thước Error, write → no-op) |
| `require('os')` | ✅ Stub |
| `require('events')` | ✅ EventEmitter cơ bản |
| `require('child_process')` | ⚠️ Stub (exec/spawn trả error) |
| `process.platform/env/argv` | ✅ |
| `setImmediate` | ✅ `setTimeout(fn, 0)` |
| `localStorage` | ✅ Proxy → bridge Swift save |

### Rủi ro plugin

| Plugin | Tình trạng |
|---|---|
| VisuStella MZ (core, battles, etc.) | ✅ Thuần JS, không dùng NW.js |
| Yanfly MV Core / Save Core | ⚠️ Save Core override `StorageManager` — bridge đã tương thích |
| HUD Maker Ultra | ⚠️ Dùng `require('fs')` để đọc config — trả mock rỗng, UI có thể trống |
| SRD_GameUpgrade | ⚠️ Dùng `nw.App.dataPath` — trả empty string, có thể fallback OK |
| FOSSIL (SQLite native) | ❌ Không thể chạy — native Node module |
| QMovement, Irina_X series | ✅ Thuần JS |
| OcRam Plugins (MZ) | ✅ Thuần JS |

---

## License

Dự án cá nhân. Toàn bộ code engine RGSS là clean-room implementation  
(không dựa trên mkxp/mkxp-z/bất kỳ code GPL nào).
