// RPGPlayer/EngineRGSS/TilemapRenderer.swift
//
// M6.3 — Render tilemap RPG Maker VX Ace (RGSS3) qua Metal.
//
// CLEAN-ROOM: viết từ RGSS3 Reference Manual (help file công khai đi kèm
// RPG Maker VX Ace). KHÔNG tham chiếu cấu trúc field/logic từ bất kỳ engine
// mã nguồn mở GPL/LGPL nào (mkxp-z, v.v.).
//
// CÁCH TIẾP CẬN (M6.3 bản tối thiểu):
//   - Đọc RPG::Map.data (Table 3D) + RPG::Tileset (tileset_names, flags)
//     qua DataFileLoader (đã decode từ .rvdata2).
//   - Vẽ toàn bộ map vào 1 bitmap CPU-side (CGContext) — mỗi tile 32×32.
//   - Tạo MTLTexture từ bitmap → SpriteRenderer vẽ texture này.
//   - Autotile: 16 biến thể ghép theo tile xung quanh (RGSS3 Reference Manual).
//
// PHẠM VI M6.3 (bản tối thiểu):
//   - Layer 0-3: vẽ từ dưới lên (layer 0 = nền, layer 3 = trên cùng).
//   - Autotile A1-A4: 16 biến thể (chưa xử lý animation frame A1).
//   - Normal tile B-E: vẽ trực tiếp từ tileset image.
//   - Chưa có scrolling camera (hiển thị toàn bộ map).
//
// TILE ID RANGES (RGSS3 Reference Manual):
//   A1 = 1-2048   (autotile: A1=1-256, A2=257-512, A3=513-768, A4=769-1024)
//   B  = 2049-2304
//   C  = 2305-2560
//   D  = 2561-2816
//   E  = 2817-3072
//
// TILESET IMAGE LAYOUT (RGSS3 Reference Manual):
//   A1: 2 rows × 12 cols (6 autotile sets × 2 animation frames)
//   A2: 1 row  × 8 cols  (8 autotile sets)
//   A3: 1 row  × 8 cols  (8 autotile sets)
//   A4: 2 rows × 8 cols  (16 autotile sets)
//   B-E: 8 rows × 8 cols (64 tiles mỗi sheet)
//
// AUTOTILE VARIANT (16 biến thể, mỗi biến thể 1 tile 32×32 trong set):
//   Variant 0-15 → vị trí (col, row) trong autotile set:
//     0:(0,0) 1:(1,0) 2:(2,0) 3:(3,0)
//     4:(0,1) 5:(1,1) 6:(2,1) 7:(3,1)
//     8:(0,2) 9:(1,2) 10:(2,2) 11:(3,2)
//     12:(0,3) 13:(1,3) 14:(2,3) 15:(3,3)
//
// AUTOTILE BIT MAPPING (RGSS3 Reference Manual):
//   bit 0 = up, bit 1 = right, bit 2 = down, bit 3 = left

 import Foundation
 import Metal
 import MetalKit
 import UIKit

/// Renderer vẽ tilemap RGSS3 thành MTLTexture.
/// M6.3: dùng CGContext để vẽ toàn bộ map vào bitmap, rồi tạo MTLTexture.
final class TilemapRenderer {

    /// Kích thước 1 tile (RGSS3: 32×32 px).
    static let tileSize: Int = 32

    // MARK: - Tile ID ranges (RGSS3 Reference Manual)

    /// Autotile A1: 1-256 (water/animation)
    static let autotileA1Range = 1...256
    /// Autotile A2: 257-512 (ground)
    static let autotileA2Range = 257...512
    /// Autotile A3: 513-768 (building)
    static let autotileA3Range = 513...768
    /// Autotile A4: 769-1024 (wall)
    static let autotileA4Range = 769...1024
    /// Normal tile B: 2049-2304
    static let normalBRange = 2049...2304
    /// Normal tile C: 2305-2560
    static let normalCRange = 2305...2560
    /// Normal tile D: 2561-2816
    static let normalDRange = 2561...2816
    /// Normal tile E: 2817-3072
    static let normalERange = 2817...3072

    // MARK: - State

    private let device: MTLDevice
    private let textureLoader: MTKTextureLoader

    /// Texture tilemap đã render (nil nếu chưa render hoặc lỗi).
    private(set) var tilemapTexture: MTLTexture?

    /// Kích thước map (tile).
    private(set) var mapWidth: Int = 0
    private(set) var mapHeight: Int = 0

    // MARK: - Init

    init?(device: MTLDevice) {
        self.device = device
        self.textureLoader = MTKTextureLoader(device: device)
    }

    // MARK: - Public API

    /// Render tilemap từ dữ liệu đã decode.
    /// - Parameters:
    ///   - map: RGSSMapData (từ DataFileLoader.loadMap)
    ///   - tileset: RGSSTilesetData (từ DataFileLoader.loadTilesets)
    ///   - gameRoot: thư mục gốc game (để load Graphics/Tilesets/*.png)
    /// - Returns: true nếu render thành công, false nếu lỗi (log chi tiết).
    @discardableResult
    func render(map: RGSSMapData, tileset: RGSSTilesetData, gameRoot: URL) -> Bool {
        mapWidth = map.width
        mapHeight = map.height

        // Load tileset images (Graphics/Tilesets/*.png)
        guard let tilesetImages = loadTilesetImages(tileset: tileset, gameRoot: gameRoot) else {
            print("[TilemapRenderer] ❌ Không load được tileset images")
            return false
        }

        // Tạo bitmap context cho toàn bộ map
        let pixelWidth = map.width * Self.tileSize
        let pixelHeight = map.height * Self.tileSize
        guard let context = createBitmapContext(width: pixelWidth, height: pixelHeight) else {
            print("[TilemapRenderer] ❌ Không tạo được bitmap context")
            return false
        }

        // Vẽ từng tile từ layer 0 (dưới) lên layer 3 (trên)
        for layer in 0..<4 {
            for y in 0..<map.height {
                for x in 0..<map.width {
                    let tileID = map.data[x + y * map.width + layer * map.width * map.height]
                    guard tileID != 0 else { continue }
                    drawTile(tileID, atX: x, y: y, in: context,
                             tilesetImages: tilesetImages, map: map)
                }
            }
        }

        // Tạo MTLTexture từ bitmap
        guard let cgImage = context.makeImage() else {
            print("[TilemapRenderer] ❌ makeImage() thất bại")
            return false
        }

        do {
            tilemapTexture = try textureLoader.newTexture(
                cgImage: cgImage,
                options: [.textureUsage: MTLTextureUsage.shaderRead.rawValue,
                          .SRGB: false]
            )
            print("[TilemapRenderer] ✅ Tilemap rendered: \(map.width)×\(map.height) tiles (\(pixelWidth)×\(pixelHeight) px)")
            return true
        } catch {
            print("[TilemapRenderer] ❌ Tạo MTLTexture thất bại: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Tileset image loading

    /// Load 9 tileset images (Graphics/Tilesets/*.png) từ game sandbox.
    /// Trả nil nếu không load được image nào cần thiết.
    private func loadTilesetImages(tileset: RGSSTilesetData, gameRoot: URL) -> [UIImage?]? {
        var images: [UIImage?] = []
        images.reserveCapacity(9)

        for (index, name) in tileset.tilesetNames.enumerated() {
            guard !name.isEmpty else {
                images.append(nil)
                continue
            }
            let fileURL = gameRoot
                .appendingPathComponent("Graphics/Tilesets/\(name)")
            if let image = UIImage(contentsOfFile: fileURL.path) {
                images.append(image)
            } else {
                print("[TilemapRenderer] ⚠️  Không tìm thấy tileset image: \(name)")
                images.append(nil)
            }
        }

        // Cần ít nhất 1 image để render
        if images.allSatisfy({ $0 == nil }) {
            return nil
        }
        return images
    }

    // MARK: - Bitmap context

    /// Tạo RGBA bitmap context (premultiplied alpha, 8-bit).
    private func createBitmapContext(width: Int, height: Int) -> CGContext? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Fill nền đen
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    // MARK: - Tile drawing

     /// Vẽ 1 tile vào bitmap context.
     /// LƯU Ý Y-FLIP: RPG Maker map có y=0 ở TRÊN CÙNG (Y-down). CGContext
     /// origin ở GÓC DƯỚI TRÁI (Y-up) → phải flip Y để map không bị lộn ngược:
     ///   destY = (mapHeight - 1 - y) * tileSize
     private func drawTile(_ tileID: Int, atX x: Int, y: Int, in context: CGContext,
                           tilesetImages: [UIImage?], map: RGSSMapData) {
         let destRect = CGRect(x: x * Self.tileSize,
                               y: (map.height - 1 - y) * Self.tileSize,
                               width: Self.tileSize, height: Self.tileSize)

        // Autotile A1-A4 — truyền x, y GỐC (chưa flip) để variant tính đúng
        // (variant dựa trên tile xung quanh theo toạ độ map Y-down, không
        // phải toạ độ bitmap Y-up đã flip).
        if Self.autotileA1Range.contains(tileID) {
            drawAutotile(tileID, atX: x, y: y, destRect: destRect,
                         in: context, tilesetImages: tilesetImages,
                         map: map, autotileIndex: 0)
        } else if Self.autotileA2Range.contains(tileID) {
            drawAutotile(tileID, atX: x, y: y, destRect: destRect,
                         in: context, tilesetImages: tilesetImages,
                         map: map, autotileIndex: 1)
        } else if Self.autotileA3Range.contains(tileID) {
            drawAutotile(tileID, atX: x, y: y, destRect: destRect,
                         in: context, tilesetImages: tilesetImages,
                         map: map, autotileIndex: 2)
        } else if Self.autotileA4Range.contains(tileID) {
            drawAutotile(tileID, atX: x, y: y, destRect: destRect,
                         in: context, tilesetImages: tilesetImages,
                         map: map, autotileIndex: 3)
        }
        // Normal tile B-E
        else if Self.normalBRange.contains(tileID) {
            drawNormalTile(tileID, at: destRect, in: context, tilesetImages: tilesetImages,
                           sheetIndex: 4)
        } else if Self.normalCRange.contains(tileID) {
            drawNormalTile(tileID, at: destRect, in: context, tilesetImages: tilesetImages,
                           sheetIndex: 5)
        } else if Self.normalDRange.contains(tileID) {
            drawNormalTile(tileID, at: destRect, in: context, tilesetImages: tilesetImages,
                           sheetIndex: 6)
        } else if Self.normalERange.contains(tileID) {
            drawNormalTile(tileID, at: destRect, in: context, tilesetImages: tilesetImages,
                           sheetIndex: 7)
        } else {
            // Tile ID ngoài phạm vi — bỏ qua (không vẽ)
            print("[TilemapRenderer] ⚠️  Tile ID \(tileID) ngoài phạm vi tại (\(x),\(y))")
        }
    }

    /// Vẽ normal tile (B-E) từ tileset image.
    /// - Parameters:
    ///   - tileID: tile ID (2049-3072)
    ///   - sheetIndex: chỉ số vào tilesetNames (4=B, 5=C, 6=D, 7=E)
    private func drawNormalTile(_ tileID: Int, at destRect: CGRect, in context: CGContext,
                                tilesetImages: [UIImage?], sheetIndex: Int) {
        guard sheetIndex < tilesetImages.count,
              let image = tilesetImages[sheetIndex] else { return }

        // Tile ID → vị trí trong sheet (8×8 grid, mỗi tile 32×32)
        // B = 2049 → (0,0), B = 2050 → (1,0), ..., B = 2304 → (7,7)
        let baseID: Int
        switch sheetIndex {
        case 4: baseID = 2049
        case 5: baseID = 2305
        case 6: baseID = 2561
        case 7: baseID = 2817
        default: return
        }
        let offset = tileID - baseID
        let col = offset % 8
        let row = offset / 8

        let sourceRect = CGRect(x: col * Self.tileSize, y: row * Self.tileSize,
                                width: Self.tileSize, height: Self.tileSize)
        guard let cgImage = image.cgImage else { return }
        // Vẽ đúng vùng source — dùng draw với clip
        context.saveGState()
        context.clip(to: destRect)
        context.translateBy(x: destRect.origin.x - sourceRect.origin.x,
                            y: destRect.origin.y - sourceRect.origin.y)
        context.draw(cgImage, in: CGRect(origin: .zero, size: image.size))
        context.restoreGState()
    }

    /// Vẽ autotile (A1-A4) — 16 biến thể ghép theo tile xung quanh.
    /// - Parameters:
    ///   - tileID: tile ID (1-1024)
    ///   - x, y: toạ độ map GỐC (Y-down, chưa flip) — dùng cho variant
    ///   - destRect: vị trí vẽ trong bitmap (đã flip Y)
    ///   - autotileIndex: 0=A1, 1=A2, 2=A3, 3=A4
    private func drawAutotile(_ tileID: Int, atX x: Int, y: Int,
                              destRect: CGRect, in context: CGContext,
                              tilesetImages: [UIImage?], map: RGSSMapData,
                              autotileIndex: Int) {
        guard autotileIndex < tilesetImages.count,
              let image = tilesetImages[autotileIndex] else { return }

        // Tile ID → autotile set index trong sheet
        // A1: 1-256 → 6 sets × 2 frames (mỗi set 2×2 tiles)
        // A2: 257-512 → 8 sets (mỗi set 1×8 tiles)
        // A3: 513-768 → 8 sets
        // A4: 769-1024 → 16 sets (mỗi set 2×8 tiles)
        let setIndex: Int
        let setCol: Int
        let setRow: Int
        switch autotileIndex {
         case 0: // A1: 6 sets × 2 frames, mỗi set 2×2 tiles
             let offset = tileID - 1
             setIndex = offset / 2  // 2 tiles per set
             let frame = offset % 2 // 0 = frame 0, 1 = frame 1
             setCol = setIndex % 6
             setRow = frame * 2     // frame 0 → row 0, frame 1 → row 2
        case 1: // A2: 8 sets, mỗi set 1×8 tiles
            let offset = tileID - 257
            setIndex = offset / 8
            setCol = setIndex % 8
            setRow = 0
        case 2: // A3: 8 sets, mỗi set 1×8 tiles
            let offset = tileID - 513
            setIndex = offset / 8
            setCol = setIndex % 8
            setRow = 0
        case 3: // A4: 16 sets, mỗi set 2×8 tiles
            let offset = tileID - 769
            setIndex = offset / 8
            setCol = setIndex % 8
            setRow = setIndex / 8
        default:
            return
        }

        // Tính variant (0-15) dựa trên tile xung quanh (toạ độ map GỐC Y-down)
        let variant = autotileVariant(atX: x, y: y, tileID: tileID, map: map)

        // Variant → vị trí trong autotile set (4×4 grid)
        let variantCol = variant % 4
        let variantRow = variant / 4

        // Vị trí trong tileset image
        let sourceX = (setCol * 4 + variantCol) * Self.tileSize
        let sourceY = (setRow * 4 + variantRow) * Self.tileSize

        guard let cgImage = image.cgImage else { return }
        let sourceRect = CGRect(x: sourceX, y: sourceY,
                                width: Self.tileSize, height: Self.tileSize)

        // Vẽ đúng vùng source
        context.saveGState()
        context.clip(to: destRect)
        context.translateBy(x: destRect.origin.x - sourceRect.origin.x,
                            y: destRect.origin.y - sourceRect.origin.y)
        context.draw(cgImage, in: CGRect(origin: .zero, size: image.size))
        context.restoreGState()
    }

     /// Tính autotile variant (0-15) dựa trên tile xung quanh.
     /// RGSS3 Reference Manual: bit 0 = up, bit 1 = right, bit 2 = down, bit 3 = left.
     /// Tile cùng autotile set ở 4 hướng → set bit tương ứng.
     private func autotileVariant(atX x: Int, y: Int, tileID: Int, map: RGSSMapData) -> Int {
         Self.autotileVariant(atX: x, y: y, tileID: tileID, map: map)
     }

     /// Kiểm tra tile (x, y) có cùng autotile set với tileID không.
     /// So sánh theo set index (cùng A1/A2/A3/A4 + cùng set).
     private func isSameAutotile(_ tileID: Int, atX x: Int, y: Int, map: RGSSMapData) -> Bool {
         Self.isSameAutotile(tileID, atX: x, y: y, map: map)
     }

     /// Trả về set index của autotile (cùng A1/A2/A3/A4 + cùng set).
     private func autotileSetIndex(_ tileID: Int) -> Int {
         Self.autotileSetIndex(tileID)
     }

     // MARK: - Testable static helpers (M6.3)

     /// Tính autotile variant (0-15) dựa trên tile xung quanh.
     /// RGSS3 Reference Manual: bit 0 = up, bit 1 = right, bit 2 = down, bit 3 = left.
     /// Tile cùng autotile set ở 4 hướng → set bit tương ứng.
     static func autotileVariant(atX x: Int, y: Int, tileID: Int, map: RGSSMapData) -> Int {
         var variant = 0

         // Up (bit 0)
         if y > 0 && isSameAutotile(tileID, atX: x, y: y - 1, map: map) {
             variant |= 0x01
         }
         // Right (bit 1)
         if x < map.width - 1 && isSameAutotile(tileID, atX: x + 1, y: y, map: map) {
             variant |= 0x02
         }
         // Down (bit 2)
         if y < map.height - 1 && isSameAutotile(tileID, atX: x, y: y + 1, map: map) {
             variant |= 0x04
         }
         // Left (bit 3)
         if x > 0 && isSameAutotile(tileID, atX: x - 1, y: y, map: map) {
             variant |= 0x08
         }

         return variant
     }

     /// Kiểm tra tile (x, y) có cùng autotile set với tileID không.
     /// So sánh theo set index (cùng A1/A2/A3/A4 + cùng set).
     static func isSameAutotile(_ tileID: Int, atX x: Int, y: Int, map: RGSSMapData) -> Bool {
         // Duyệt 4 layer — tile ở layer nào cũng được (autotile so sánh theo set)
         for layer in 0..<4 {
             let otherID = map.data[x + y * map.width + layer * map.width * map.height]
             guard otherID != 0 else { continue }
             if autotileSetIndex(otherID) == autotileSetIndex(tileID) {
                 return true
             }
         }
         return false
     }

     /// Trả về set index của autotile (cùng A1/A2/A3/A4 + cùng set).
     static func autotileSetIndex(_ tileID: Int) -> Int {
         if autotileA1Range.contains(tileID) {
             return (tileID - 1) / 2  // 2 tiles per set (frame 0)
         } else if autotileA2Range.contains(tileID) {
             return 1000 + (tileID - 257) / 8
         } else if autotileA3Range.contains(tileID) {
             return 2000 + (tileID - 513) / 8
         } else if autotileA4Range.contains(tileID) {
             return 3000 + (tileID - 769) / 8
         }
         return -1
     }

     /// Vị trí (col, row) của normal tile B-E trong sheet 8×8.
     /// - Returns: (col, row) hoặc nil nếu tile ID không thuộc B-E.
     static func normalTilePosition(tileID: Int) -> (col: Int, row: Int)? {
         let baseID: Int
         if normalBRange.contains(tileID) {
             baseID = 2049
         } else if normalCRange.contains(tileID) {
             baseID = 2305
         } else if normalDRange.contains(tileID) {
             baseID = 2561
         } else if normalERange.contains(tileID) {
             baseID = 2817
         } else {
             return nil
         }
         let offset = tileID - baseID
         return (col: offset % 8, row: offset / 8)
     }
 }
