import XCTest
@testable import RPGPlayer

/// Unit test cho M6.3 — TilemapRenderer logic thuần (không cần Metal device).
///
/// Xác minh:
///   1. Tile ID ranges (A1-A4, B-E) phân loại đúng.
///   2. Normal tile B-E → vị trí (col, row) trong sheet 8×8.
///   3. Autotile variant (0-15) tính đúng theo tile xung quanh.
///   4. Autotile set index phân biệt đúng A1/A2/A3/A4.
///
/// CLEAN-ROOM: test dùng chính logic của dự án (TilemapRenderer static helpers)
/// — không tham chiếu engine mã nguồn mở nào.
final class TilemapTests: XCTestCase {

    // MARK: - 1. Tile ID ranges

    /// Tile ID ranges phân loại đúng A1-A4, B-E.
    func testTileIDRanges() {
        // Autotile
        XCTAssertTrue(TilemapRenderer.autotileA1Range.contains(1))
        XCTAssertTrue(TilemapRenderer.autotileA1Range.contains(256))
        XCTAssertTrue(TilemapRenderer.autotileA2Range.contains(257))
        XCTAssertTrue(TilemapRenderer.autotileA2Range.contains(512))
        XCTAssertTrue(TilemapRenderer.autotileA3Range.contains(513))
        XCTAssertTrue(TilemapRenderer.autotileA3Range.contains(768))
        XCTAssertTrue(TilemapRenderer.autotileA4Range.contains(769))
        XCTAssertTrue(TilemapRenderer.autotileA4Range.contains(1024))

        // Normal
        XCTAssertTrue(TilemapRenderer.normalBRange.contains(2049))
        XCTAssertTrue(TilemapRenderer.normalBRange.contains(2304))
        XCTAssertTrue(TilemapRenderer.normalCRange.contains(2305))
        XCTAssertTrue(TilemapRenderer.normalCRange.contains(2560))
        XCTAssertTrue(TilemapRenderer.normalDRange.contains(2561))
        XCTAssertTrue(TilemapRenderer.normalDRange.contains(2816))
        XCTAssertTrue(TilemapRenderer.normalERange.contains(2817))
        XCTAssertTrue(TilemapRenderer.normalERange.contains(3072))

        // Không thuộc range nào
        XCTAssertFalse(TilemapRenderer.autotileA1Range.contains(0))
        XCTAssertFalse(TilemapRenderer.normalBRange.contains(1025))
        XCTAssertFalse(TilemapRenderer.normalERange.contains(3073))
    }

    // MARK: - 2. Normal tile position

    /// Normal tile B-E → vị trí (col, row) trong sheet 8×8.
    func testNormalTilePosition() {
        // B: 2049 → (0,0), 2050 → (1,0), 2057 → (0,1), 2304 → (7,7)
        XCTAssertEqual(TilemapRenderer.normalTilePosition(tileID: 2049)?.col, 0)
        XCTAssertEqual(TilemapRenderer.normalTilePosition(tileID: 2049)?.row, 0)
        XCTAssertEqual(TilemapRenderer.normalTilePosition(tileID: 2050)?.col, 1)
        XCTAssertEqual(TilemapRenderer.normalTilePosition(tileID: 2050)?.row, 0)
        XCTAssertEqual(TilemapRenderer.normalTilePosition(tileID: 2057)?.col, 0)
        XCTAssertEqual(TilemapRenderer.normalTilePosition(tileID: 2057)?.row, 1)
        XCTAssertEqual(TilemapRenderer.normalTilePosition(tileID: 2304)?.col, 7)
        XCTAssertEqual(TilemapRenderer.normalTilePosition(tileID: 2304)?.row, 7)

        // C: 2305 → (0,0), 2313 → (0,1)
        XCTAssertEqual(TilemapRenderer.normalTilePosition(tileID: 2305)?.col, 0)
        XCTAssertEqual(TilemapRenderer.normalTilePosition(tileID: 2305)?.row, 0)
        XCTAssertEqual(TilemapRenderer.normalTilePosition(tileID: 2313)?.col, 0)
        XCTAssertEqual(TilemapRenderer.normalTilePosition(tileID: 2313)?.row, 1)

        // D: 2561 → (0,0)
        XCTAssertEqual(TilemapRenderer.normalTilePosition(tileID: 2561)?.col, 0)
        XCTAssertEqual(TilemapRenderer.normalTilePosition(tileID: 2561)?.row, 0)

        // E: 2817 → (0,0), 3072 → (7,7)
        XCTAssertEqual(TilemapRenderer.normalTilePosition(tileID: 2817)?.col, 0)
        XCTAssertEqual(TilemapRenderer.normalTilePosition(tileID: 2817)?.row, 0)
        XCTAssertEqual(TilemapRenderer.normalTilePosition(tileID: 3072)?.col, 7)
        XCTAssertEqual(TilemapRenderer.normalTilePosition(tileID: 3072)?.row, 7)

        // Ngoài phạm vi → nil
        XCTAssertNil(TilemapRenderer.normalTilePosition(tileID: 0))
        XCTAssertNil(TilemapRenderer.normalTilePosition(tileID: 1025))
        XCTAssertNil(TilemapRenderer.normalTilePosition(tileID: 3073))
    }

    // MARK: - 3. Autotile set index

    /// Autotile set index phân biệt đúng A1/A2/A3/A4.
    func testAutotileSetIndex() {
        // A1: 1-256 → 0-127 (2 tiles per set)
        XCTAssertEqual(TilemapRenderer.autotileSetIndex(1), 0)
        XCTAssertEqual(TilemapRenderer.autotileSetIndex(2), 0)
        XCTAssertEqual(TilemapRenderer.autotileSetIndex(3), 1)
        XCTAssertEqual(TilemapRenderer.autotileSetIndex(256), 127)

        // A2: 257-512 → 1000-1031 (8 tiles per set)
        XCTAssertEqual(TilemapRenderer.autotileSetIndex(257), 1000)
        XCTAssertEqual(TilemapRenderer.autotileSetIndex(264), 1000)
        XCTAssertEqual(TilemapRenderer.autotileSetIndex(265), 1001)
        XCTAssertEqual(TilemapRenderer.autotileSetIndex(512), 1031)

        // A3: 513-768 → 2000-2031
        XCTAssertEqual(TilemapRenderer.autotileSetIndex(513), 2000)
        XCTAssertEqual(TilemapRenderer.autotileSetIndex(768), 2031)

        // A4: 769-1024 → 3000-3031
        XCTAssertEqual(TilemapRenderer.autotileSetIndex(769), 3000)
        XCTAssertEqual(TilemapRenderer.autotileSetIndex(1024), 3031)

        // Ngoài phạm vi → -1
        XCTAssertEqual(TilemapRenderer.autotileSetIndex(0), -1)
        XCTAssertEqual(TilemapRenderer.autotileSetIndex(2049), -1)
    }

    // MARK: - 4. Autotile variant

    /// Autotile variant tính đúng theo tile xung quanh.
    /// Map 3×3, tile A2 (257) ở giữa, các tile xung quanh cùng set.
    func testAutotileVariant() {
        // Map 3×3, layer 0: toàn bộ tile 257 (cùng set A2)
        // data index: x + y*3 + layer*9
        var data = [Int](repeating: 0, count: 3 * 3 * 4)
        for y in 0..<3 {
            for x in 0..<3 {
                data[x + y * 3] = 257
            }
        }
        let map = RGSSMapData(mapID: 1, width: 3, height: 3, data: data, tilesetID: 1)

        // Tile giữa (1,1): có tile ở cả 4 hướng → variant = 0x0F = 15
        let centerVariant = TilemapRenderer.autotileVariant(atX: 1, y: 1, tileID: 257, map: map)
        XCTAssertEqual(centerVariant, 0x0F, "Tile giữa phải có variant 15 (cả 4 hướng)")

        // Tile góc (0,0): chỉ có right + down → variant = 0x02 | 0x04 = 6
        let cornerVariant = TilemapRenderer.autotileVariant(atX: 0, y: 0, tileID: 257, map: map)
        XCTAssertEqual(cornerVariant, 0x06, "Tile góc phải có variant 6 (right+down)")

        // Tile cạnh trên (1,0): có left + right + down → variant = 0x08|0x02|0x04 = 14
        let topEdgeVariant = TilemapRenderer.autotileVariant(atX: 1, y: 0, tileID: 257, map: map)
        XCTAssertEqual(topEdgeVariant, 0x0E, "Tile cạnh trên phải có variant 14 (left+right+down)")
    }

    /// Autotile variant = 0 khi không có tile xung quanh cùng set.
    func testAutotileVariantIsolated() {
        // Map 3×3, chỉ có 1 tile 257 ở giữa
        var data = [Int](repeating: 0, count: 3 * 3 * 4)
        data[1 + 1 * 3] = 257
        let map = RGSSMapData(mapID: 1, width: 3, height: 3, data: data, tilesetID: 1)

        let variant = TilemapRenderer.autotileVariant(atX: 1, y: 1, tileID: 257, map: map)
        XCTAssertEqual(variant, 0, "Tile cô lập phải có variant 0")
    }

    /// Autotile variant không tính tile khác set (A2 vs A4).
    func testAutotileVariantDifferentSet() {
        // Map 3×3: tile 257 (A2) ở giữa, tile 769 (A4) xung quanh
        var data = [Int](repeating: 0, count: 3 * 3 * 4)
        data[1 + 1 * 3] = 257
        for y in 0..<3 {
            for x in 0..<3 {
                if x == 1 && y == 1 { continue }
                data[x + y * 3] = 769
            }
        }
        let map = RGSSMapData(mapID: 1, width: 3, height: 3, data: data, tilesetID: 1)

        // Tile 257 ở giữa: xung quanh là 769 (A4) — khác set → variant 0
        let variant = TilemapRenderer.autotileVariant(atX: 1, y: 1, tileID: 257, map: map)
        XCTAssertEqual(variant, 0, "Tile khác set không được tính vào variant")
    }
}