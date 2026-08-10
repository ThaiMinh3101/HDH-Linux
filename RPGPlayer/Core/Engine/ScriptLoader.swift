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
            return "Data/Scripts.rvdata2 does not exist in the game"
        case .marshal(let msg):
            return "Marshal error: \(msg)"
        case .invalidStructure(let msg):
            return "Invalid Scripts.rvdata2 structure: \(msg)"
        case .zlib:
            return "zlib decompression failed"
        case .invalidUTF8(let name):
            return "Script \"\(name)\" is not valid UTF-8"
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
            throw ScriptLoaderError.marshal("Not a Marshal 4.8 stream (missing 04 08 header)")
        }

        // Decode + extract trong CÙNG scope — tree sống trong arena, phải dùng
        // trước khi arena bị destroy.
        guard let arena = rgss_arena_create(arenaSize) else {
            throw ScriptLoaderError.marshal("Not enough memory to create decode arena")
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
            throw ScriptLoaderError.invalidStructure("Root must be an Array")
        }

        let rootCount = Int(rgss_value_array_count(root))
        var scripts: [RGSSScript] = []
        scripts.reserveCapacity(rootCount)

        for i in 0..<rootCount {
            guard let elemPtr = rgss_value_array_item(root, i) else {
                throw ScriptLoaderError.invalidStructure("Script \(i): null element")
            }
            guard rgss_value_type(elemPtr) == RGSS_VAL_ARRAY else {
                throw ScriptLoaderError.invalidStructure("Script \(i): must be an Array [id, name, data]")
            }
            guard rgss_value_array_count(elemPtr) == 3 else {
                throw ScriptLoaderError.invalidStructure("Script \(i): must have exactly 3 elements [id, name, data]")
            }

            // ── id (Integer) ──
            guard let idPtr = rgss_value_array_item(elemPtr, 0),
                  rgss_value_type(idPtr) == RGSS_VAL_INT else {
                throw ScriptLoaderError.invalidStructure("Script \(i): id must be an Integer")
            }
            let id = Int(rgss_value_int(idPtr))

            // ── name (String) ──
            guard let namePtr = rgss_value_array_item(elemPtr, 1),
                  rgss_value_type(namePtr) == RGSS_VAL_STRING else {
                throw ScriptLoaderError.invalidStructure("Script \(i): name must be a String")
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
                throw ScriptLoaderError.invalidStructure("Script \(i): compressed data must be a String")
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
    /// c3 fix: dùng `compression_stream` (streaming API) thay vì
    /// `compression_decode_buffer` với buffer doubling + re-decode từ đầu.
    /// Streaming decode một lần duy nhất, append vào output — tránh copy
    /// toàn bộ dữ liệu nhiều lần (O(n²) worst case với input lớn).
    private static func zlibDecompress(_ data: Data) -> Data? {
        // Streaming decode — một pass duy nhất, không re-decode từ đầu.
        var output = Data()
        output.reserveCapacity(max(data.count * 4, 64 * 1024))

        let status = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> compression_status in
            guard let srcBase = src.baseAddress else { return COMPRESSION_STATUS_ERROR }

            // Buffer đích cố định 64 KB — đủ cho hầu hết script RGSS.
            // Khai báo TRƯỚC stream init vì cần con trỏ hợp lệ cho dst_ptr.
            var dstBuffer = [UInt8](repeating: 0, count: 64 * 1024)

            // compression_stream dùng memberwise init — dst_ptr là
            // UnsafeMutablePointer<UInt8> KHÔNG optional (truyền nil gây lỗi
            // compile "expected argument type"), và Swift KHÔNG tự sinh no-arg
            // init cho C struct có pointer fields. Vì vậy phải truyền con trỏ
            // thật tới dstBuffer (sống cùng scope — buffer không bị thu hồi).
            // dst_ptr được set lại mỗi vòng lặp bên dưới nên giá trị ban đầu
            // chỉ cần hợp lệ, không cần chính xác.
            let dstPtr = dstBuffer.withUnsafeMutableBytes {
                $0.baseAddress!.assumingMemoryBound(to: UInt8.self)
            }
            var stream = compression_stream(
                dst_ptr: dstPtr,
                dst_size: dstBuffer.count,
                src_ptr: srcBase.assumingMemoryBound(to: UInt8.self),
                src_size: data.count,
                state: nil
            )

            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
                return COMPRESSION_STATUS_ERROR
            }
            defer { compression_stream_destroy(&stream) }

            // Guard chống infinite loop: track tiến triển thực tế.
            // Nếu 2 lần gọi liên tiếp không sản xuất output và không tiêu thụ
            // input → dữ liệu hỏng (hoặc stream không thể tiến triển).
            var lastSrcSize = data.count
            var noProgressCount = 0

            while true {
                // Pattern chuẩn: gọi process với flag 0 cho đến khi hết input,
                // rồi mới gọi với COMPRESSION_STREAM_FINALIZE để kết thúc.
                // Gọi FINALIZE ngay từ đầu khi input chưa hết có thể gây lỗi.
                // COMPRESSION_STREAM_FINALIZE import sang Swift có type
                // compression_stream_flags (= UInt32). Ternary `? FINALIZE : 0`
                // gây mismatch type (0 literal suy ra Int, annotation không
                // propagate vào ternary) — dùng if/else để ép kiểu qua phép
                // gán đơn (annotation context áp dụng chắc chắn).
                let flag: compression_stream_flags
                if stream.src_size == 0 {
                    flag = COMPRESSION_STREAM_FINALIZE
                } else {
                    flag = 0
                }


                guard let dstBase = dstBuffer.withUnsafeMutableBytes({ $0.baseAddress }) else {
                    return COMPRESSION_STATUS_ERROR
                }
                stream.dst_ptr = dstBase.assumingMemoryBound(to: UInt8.self)
                stream.dst_size = dstBuffer.count

                let status = compression_stream_process(&stream, flag)
                let produced = dstBuffer.count - Int(stream.dst_size)
                if produced > 0 {
                    output.append(dstBuffer, count: produced)
                }
                if output.count > maxDecompressedSize {
                    return COMPRESSION_STATUS_ERROR  // vượt giới hạn an toàn
                }

                if status == COMPRESSION_STATUS_END {
                    return COMPRESSION_STATUS_OK
                }
                if status != COMPRESSION_STATUS_OK {
                    return status
                }

                // Kiểm tra tiến triển: input tiêu thụ hoặc output sản xuất.
                let consumed = lastSrcSize - Int(stream.src_size)
                if produced == 0 && consumed == 0 {
                    noProgressCount += 1
                    if noProgressCount >= 2 {
                        return COMPRESSION_STATUS_ERROR  // dữ liệu hỏng
                    }
                } else {
                    noProgressCount = 0
                }
                lastSrcSize = Int(stream.src_size)
            }
        }

        return status == COMPRESSION_STATUS_OK ? output : nil
    }
}