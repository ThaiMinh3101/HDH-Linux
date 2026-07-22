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
| M1a | Engine MV/MZ (WKWebView + JS shim) | 🔲 Tiếp theo |
| M1b | Engine RGSS "Hello Sprite" (CRuby + Metal) | 🔲 |
| M2 | Input (GameController + D-pad ảo) | 🔲 |
| M3 | Save game + iCloud sync | 🔲 |
| M4 | Plugin manager, chống crash, dọn cache | 🔲 |
| M5 | Dịch + tối ưu 60fps | 🔲 |

---

## License

Dự án cá nhân. Toàn bộ code engine RGSS là clean-room implementation  
(không dựa trên mkxp/mkxp-z/bất kỳ code GPL nào).
