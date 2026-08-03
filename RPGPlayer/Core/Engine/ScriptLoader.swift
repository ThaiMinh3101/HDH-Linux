// RPGPlayer/Core/Engine/ScriptLoader.swift
//
// M6.0 — Đọc Data/Scripts.rvdata2 của RPG Maker VX Ace:
//   Marshal stream → Array of [script_id, script_name, compressed_data]
//   compressed_data là zlib deflate → giải nén bằng Compression framework của Apple.
//
// CLEAN-ROOM:
//   - Marshal format đã implement trong rgss_marshal.c (M3, clean-room).
//   - Cấu trúc Scripts.rvdata2 được mô tả trong tài liệu công khai của RPG Maker
//     VX Ace (RGSS3 Reference Manual + help file offline).
//   - KHÔNG tham chiếu mã nguồn từ mkxp-z / bất kỳ engine RGSS GPL/LGPL nào.
//   - Giải nén zlib dùng Compression framework (COMPRESSION_ZLIB) — framework
//     hệ thống của Apple, license cho phép dùng trong app đóng gói, không cần
//     thêm dependency mới (ngược lại với việc nhúng zlib C library vào mruby).

import Foundation
import Compression

/// Một script RGSS đã giải nén, theo đúng thứ tự xuất hiện trong Scripts.rvdata2.
struct RGSSScript {
    let id: Int
    let name: String
    let source: String     // Ruby source, đã decompress + UTF-8
}

enum ScriptLoaderError: Error, LocalizedError {
    case fileNotFound
    case marshal(String)
    case invalidStructure(String)
    case zlib
    case invalidUTF8(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "Data/Scripts.rvdata2 không tồn tại trong game"
        case .marshal(let msg):
            return "Lỗi Marshal: \(msg)"
        case .invalidStructure(let msg):
            return "Cấu trúc Scripts.rvdata2 không hợp lệ: \(msg)"
        case .zlib:
            return "Giải nén zlib thất bại"
        case .invalidUTF8(let name):
            return "Script \"\(name)\" không phải UTF-8 hợp lệ"
        }
    }
}

enum ScriptLoader {

    /// Arena size cho Marshal decode — đủ cho Scripts.rvdata2 của game thông thường.
    /// Game rất lớn (hàng nghìn script) có thể cần tăng.
    private static let arenaSize = 16 * 1024 * 1024  // 16 MB

    /// Zlib safety cap — script RPG Maker hiếm khi > 10 MB sau giải nén.
    private static let maxDecompressedSize = 128 * 1024 * 1024  // 128 MB

    // MARK: - Public API

    /// Tìm thư mục gốc thực sự của game (zip có thể lồng 1 lớp subfolder).
    /// Cùng logic với GameDetector.resolveGameRoot — chỉ tìm bằng Scripts.rvdata2.
    static func resolveGameRoot(in rootURL: URL) -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: rootURL.appendingPathComponent("Data/Scripts.rvdata2").path) {
            return rootURL
        }
        guard let contents = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return rootURL }

        let subdirs = contents.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        if subdirs.count == 1,
           fm.fileExists(atPath: subdirs[0].appendingPathComponent("Data/Scripts.rvdata2").path) {
            return subdirs[0]
        }
        return rootURL
    }

    /// Đọc + giải nén toàn bộ script từ game root.
    static func loadScripts(fromGameRoot rootURL: URL) throws -> [RGSSScript] {
        let dataURL = rootURL.appendingPathComponent("Data/Scripts.rvdata2")
        guard FileManager.default.fileExists(atPath: dataURL.path),
              let data = try? Data(contentsOf: dataURL) else {
            throw ScriptLoaderError.fileNotFound
        }
        return try loadScripts(fromData: data)
    }

    /// Đọc + giải nén script từ dữ liệu Marshal thô (dùng cho unit test).
    static func loadScripts(fromData data: Data) throws -> [RGSSScript] {
        guard data.count >= 2, data[0] == 0x04, data[1] == 0x08 else {
            throw ScriptLoaderError.marshal("Không phải Marshal 4.8 (thiếu header 04 08)")
        }

        // Decode + extract trong CÙNG scope — tree sống trong arena, phải dùng
        // trước khi arena bị destroy.
        guard let arena = rgss_arena_create(arenaSize) else {
            throw ScriptLoaderError.marshal("Không đủ bộ nhớ để tạo arena decode")
        }
        defer { rgss_arena_destroy(arena) }

        var decoder = RGSSMarshalDecoder()
        var root: UnsafeMutablePointer<RGSSValue>?

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            rgss_marshal_decoder_init(
                &decoder,
                base.assumingMemoryBound(to: UInt8.self),
                data.count,
                arena
            )
            root = rgss_marshal_load(&decoder)
        }
        defer { rgss_marshal_decoder_free_tables(&decoder) }

        guard let loadedRoot = root, decoder.last_error == RGSS_MARSHAL_OK else {
            let msg = String(cString: rgss_marshal_error_string(decoder.last_error))
            throw ScriptLoaderError.marshal(msg)
        }

        // Root là UnsafeMutablePointer — truyền thẳng vào hàm nhận UnsafePointer
        return try extractScripts(from: UnsafePointer(loadedRoot))
    }

    // MARK: - Script extraction

    /// Duyệt tree Marshal theo cấu trúc Scripts.rvdata2:
    ///   Array [ Array [id Integer, name String, compressed_data String] × N ]
    /// Giải nén từng compressed_data (zlib) và trả về danh sách theo thứ tự.
    ///
    /// Truy cập tree qua C accessor functions (rgss_value_*) — tránh access
    /// C union/struct trực tiếp từ Swift (tên field `as` là Swift keyword,
    /// anonymous struct có tên synthesized không ổn định).
    private static func extractScripts(from root: UnsafePointer<RGSSValue>) throws -> [RGSSScript] {
        // C enum values import vào Swift như global constants (RGSSValueType struct).
        // So sánh trực tiếp với constant, không ép rawValue.
        guard rgss_value_type(root) == RGSS_VAL_ARRAY else {
            throw ScriptLoaderError.invalidStructure("Root phải là Array")
        }

        let rootCount = Int(rgss_value_array_count(root))
        var scripts: [RGSSScript] = []
        scripts.reserveCapacity(rootCount)

        for i in 0..<rootCount {
            guard let elemPtr = rgss_value_array_item(root, i) else {
                throw ScriptLoaderError.invalidStructure("Script \(i): phần tử null")
            }
            guard rgss_value_type(elemPtr) == RGSS_VAL_ARRAY else {
                throw ScriptLoaderError.invalidStructure("Script \(i): phải là Array [id, name, data]")
            }
            guard rgss_value_array_count(elemPtr) == 3 else {
                throw ScriptLoaderError.invalidStructure("Script \(i): phải có đúng 3 phần tử [id, name, data]")
            }

            // ── id (Integer) ──
            guard let idPtr = rgss_value_array_item(elemPtr, 0),
                  rgss_value_type(idPtr) == RGSS_VAL_INT else {
                throw ScriptLoaderError.invalidStructure("Script \(i): id phải là Integer")
            }
            let id = Int(rgss_value_int(idPtr))

            // ── name (String) ──
            guard let namePtr = rgss_value_array_item(elemPtr, 1),
                  rgss_value_type(namePtr) == RGSS_VAL_STRING else {
                throw ScriptLoaderError.invalidStructure("Script \(i): name phải là String")
            }
            let nameDataLen = Int(rgss_value_string_len(namePtr))
            let name: String
            if nameDataLen > 0, let nameBase = rgss_value_string_data(namePtr) {
                name = String(
                    bytes: UnsafeBufferPointer(start: nameBase, count: nameDataLen),
                    encoding: .utf8
                ) ?? ""
            } else {
                name = ""
            }

            // ── compressed_data (String → zlib deflate) ──
            guard let dataPtr = rgss_value_array_item(elemPtr, 2),
                  rgss_value_type(dataPtr) == RGSS_VAL_STRING else {
                throw ScriptLoaderError.invalidStructure("Script \(i): compressed data phải là String")
            }
            let compLen = Int(rgss_value_string_len(dataPtr))
            guard compLen > 0, let compBase = rgss_value_string_data(dataPtr) else {
                throw ScriptLoaderError.zlib
            }
            let compData = Data(bytes: compBase, count: compLen)

            guard let decompressed = zlibDecompress(compData) else {
                throw ScriptLoaderError.zlib
            }
            guard let source = String(data: decompressed, encoding: .utf8) else {
                throw ScriptLoaderError.invalidUTF8(name)
            }

            scripts.append(RGSSScript(id: id, name: name, source: source))
        }

        return scripts
    }

    // MARK: - Zlib (Compression framework)

    /// Giải nén zlib deflate bằng Compression framework (COMPRESSION_ZLIB).
    /// Trả nil nếu dữ liệu hỏng hoặc output vượt quá giới hạn an toàn.
    ///
    /// Lưu ý: dùng `compression_decode_buffer` với capacity tăng dần thay vì
    /// streaming API để tránh lỗi edge-case khi set COMPRESSION_STREAM_FINALIZE
    /// giữa chừng. Data .rvdata2 thường nhỏ (< 1 MB), retry decode là chấp nhận được.
    private static func zlibDecompress(_ data: Data) -> Data? {
        var capacity = max(data.count * 4, 64 * 1024)  // ước lượng 4x + tối thiểu 64 KB
        var output = Data()

        while capacity <= maxDecompressedSize {
            var buffer = [UInt8](repeating: 0, count: capacity)

            let decoded = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let srcBase = src.baseAddress else { return 0 }
                return buffer.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
                    guard let dstBase = dst.baseAddress else { return 0 }
                    return compression_decode_buffer(
                        dstBase.assumingMemoryBound(to: UInt8.self),
                        dst.count,
                        srcBase.assumingMemoryBound(to: UInt8.self),
                        data.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }

            if decoded < capacity {
                // Đã decode hết toàn bộ input
                output.append(buffer, count: decoded)
                return output
            }
            // Output có thể vẫn chưa hết — tăng capacity và decode lại từ đầu
            capacity *= 2
        }
        return nil
    }
}