import XCTest
import Compression
@testable import RPGPlayer

/// Unit test cho ScriptLoader (M6.0) — decode Scripts.rvdata2 + zlib decompress.
/// Không cần thiết bị thật, chạy được trên Simulator.
///
/// Test tự tạo Marshal bytes bằng tay theo Ruby Marshal 4.8 format
/// (giống hệt những gì RPG Maker VX Ace ghi ra) + zlib stream bằng
/// Compression framework — hoàn toàn clean-room, không dùng engine nào.
final class ScriptLoaderTests: XCTestCase {

    // MARK: - Helpers

    /// Marshal integer encode (subset cần cho test này):
    ///   n == 0       → [0]
    ///   1 ≤ n ≤ 122  → [n+5]
    ///   n > 122      → [byteCount] + little-endian bytes
    private func marshalInt(_ n: Int) -> [UInt8] {
        if n == 0 { return [0] }
        if n > 0 && n <= 122 { return [UInt8(n + 5)] }
        var v = n
        var le = [UInt8]()
        while v > 0 {
            le.append(UInt8(v & 0xFF))
            v >>= 8
        }
        return [UInt8(le.count)] + le
    }

    /// Marshal string encode: '"' + len + bytes
    private func marshalString(_ s: String) -> [UInt8] {
        let bytes = Array(s.utf8)
        return [0x22] + marshalInt(bytes.count) + bytes
    }

    /// Zlib compress (Compression framework — COMPRESSION_ZLIB tạo zlib stream
    /// đúng định dạng Ruby Zlib::Deflate, giống RPG Maker).
    private func zlibCompress(_ input: [UInt8]) throws -> [UInt8] {
        let capacity = input.count * 2 + 64
        var dst = [UInt8](repeating: 0, count: capacity)
        let written = input.withUnsafeBufferPointer { src in
            dst.withUnsafeMutableBufferPointer { d in
                compression_encode_buffer(
                    d.baseAddress!, d.count,
                    src.baseAddress!, input.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else {
            throw ScriptLoaderError.zlib
        }
        return Array(dst.prefix(written))
    }

    /// Tạo toàn bộ file Scripts.rvdata2 giả lập:
    ///   Marshal 4.8 → Array [ Array [id, name, zlib(data)] × N ]
    private func makeScriptsData(_ scripts: [(id: Int, name: String, source: String)]) throws -> Data {
        var data = Data([0x04, 0x08])  // Marshal 4.8 header

        // Root Array
        data.append(0x5B)  // '['
        data.append(contentsOf: marshalInt(scripts.count))

        for s in scripts {
            data.append(0x5B)  // '['
            data.append(contentsOf: marshalInt(3))

            // id — Integer
            data.append(0x69)  // 'i'
            data.append(contentsOf: marshalInt(s.id))

            // name — String
            data.append(contentsOf: marshalString(s.name))

            // compressed_data — String (zlib deflate)
            let comp = try zlibCompress(Array(s.source.utf8))
            data.append(0x22)  // '"'
            data.append(contentsOf: marshalInt(comp.count))
            data.append(contentsOf: comp)
        }
        return data
    }

    // MARK: - Basic decode

    /// Verify decode + decompress đúng cả 3 script, giữ nguyên thứ tự.
    func testLoadScripts_threeScriptsInOrder() throws {
        let scripts = [
            (id: 1, name: "module_RPG", source: "module RPG\ndef self.load_data(filename)\n  nil\nend\nend"),
            (id: 2, name: "class_Sprite", source: "# -*- coding: utf-8 -*-\n# Chữ tiếng Việt: đặc biệt có dấu\nclass SpriteVX\n  attr_accessor :bitmap\nend"),
            (id: 3, name: "main", source: "rgss_main { SceneManager.run }")
        ]
        let data = try makeScriptsData(scripts)

        let loaded = try ScriptLoader.loadScripts(fromData: data)

        XCTAssertEqual(loaded.count, 3, "Phải decode đủ 3 script")
        XCTAssertEqual(loaded[0].id, 1)
        XCTAssertEqual(loaded[0].name, "module_RPG")
        XCTAssertEqual(loaded[0].source, scripts[0].source)

        XCTAssertEqual(loaded[1].id, 2)
        XCTAssertEqual(loaded[1].name, "class_Sprite")
        // UTF-8 với dấu tiếng Việt phải giữ nguyên
        XCTAssertEqual(loaded[1].source, scripts[1].source)
        XCTAssertTrue(loaded[1].source.contains("đặc biệt"))

        XCTAssertEqual(loaded[2].id, 3)
        XCTAssertEqual(loaded[2].name, "main")
        XCTAssertEqual(loaded[2].source, scripts[2].source)
    }

    /// Script tối thiểu (source 1 ký tự — zlib compress được, không phải 0-byte
    /// input vì compression_encode_buffer trả 0 khi không có dữ liệu).
    func testLoadScripts_minimalSource() throws {
        let scripts = [(id: 7, name: "minimal", source: "#")]
        let data = try makeScriptsData(scripts)
        let loaded = try ScriptLoader.loadScripts(fromData: data)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].source, "#")
    }

    // MARK: - Error handling

    /// Zlib data bị hỏng → throw ScriptLoaderError.zlib.
    func testLoadScripts_corruptZlibThrows() throws {
        let scripts = [(id: 1, name: "bad", source: "puts 'hello'")]
        var data = try makeScriptsData(scripts)

        // Tìm vị trí compressed bytes (offset: header 2 + root array 2 +
        // phần tử [ + count 1 + id 2 + name '[' + len 1 + 3 bytes "bad" = 11)
        // Đơn giản hơn: đổi byte cuối cùng (checksum) để zlib decode fail.
        data[data.count - 1] ^= 0xFF

        XCTAssertThrowsError(try ScriptLoader.loadScripts(fromData: data)) { error in
            if case ScriptLoaderError.zlib = error {
                // OK — đúng lỗi mong đợi
            } else {
                XCTFail("Phải throw ScriptLoaderError.zlib, nhận được: \(error)")
            }
        }
    }

    /// Root không phải Array → invalidStructure.
    func testLoadScripts_nonArrayRootThrows() throws {
        // Marshal dump của một Integer 12345 đơn giản
        var data = Data([0x04, 0x08])
        data.append(0x69)  // 'i'
        data.append(contentsOf: marshalInt(12_345))

        XCTAssertThrowsError(try ScriptLoader.loadScripts(fromData: data)) { error in
            if case ScriptLoaderError.invalidStructure = error {
                // OK
            } else {
                XCTFail("Phải throw invalidStructure, nhận được: \(error)")
            }
        }
    }

    /// File không phải Marshal (thiếu header 04 08) → lỗi marshal.
    func testLoadScripts_badMarshalHeaderThrows() throws {
        let data = Data([0x00, 0x01, 0x02])
        XCTAssertThrowsError(try ScriptLoader.loadScripts(fromData: data)) { error in
            if case ScriptLoaderError.marshal = error {
                // OK
            } else {
                XCTFail("Phải throw ScriptLoaderError.marshal, nhận được: \(error)")
            }
        }
    }

    // MARK: - Game root resolution

    /// Zip lồng 1 lớp subfolder → resolveGameRoot tìm đúng thư mục chứa
    /// Data/Scripts.rvdata2.
    func testResolveGameRoot_nestedSubfolder() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("MyGame/Data", isDirectory: true),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: tmp.appendingPathComponent("MyGame/Data/Scripts.rvdata2").path,
            contents: nil
        )

        let resolved = ScriptLoader.resolveGameRoot(in: tmp)
        XCTAssertTrue(
            resolved.lastPathComponent == "MyGame",
            "resolveGameRoot phải descend vào subfolder, nhận: \(resolved.lastPathComponent)"
        )
    }

    /// Game ngay tại root → resolveGameRoot trả root (không descend).
    func testResolveGameRoot_atRoot() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("Data", isDirectory: true),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: tmp.appendingPathComponent("Data/Scripts.rvdata2").path,
            contents: nil
        )

        let resolved = ScriptLoader.resolveGameRoot(in: tmp)
        XCTAssertEqual(resolved, tmp)
    }
}