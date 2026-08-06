// RPGPlayer/Core/Engine/DataFileLoader.swift
//
// M6.3 — Đọc file Data/*.rvdata2 của RPG Maker VX Ace qua Marshal decoder
// (rgss_marshal.c) để lấy dữ liệu tilemap cho TilemapRenderer.
//
// CLEAN-ROOM:
//   - Marshal format đã implement trong rgss_marshal.c (M3, clean-room).
//   - Cấu trúc .rvdata2 (RPG::Map, RPG::Tileset, RPG::System) được mô tả
//     trong RGSS3 Reference Manual (help file công khai).
//   - KHÔNG tham chiếu mã nguồn từ mkxp-z / bất kỳ engine RGSS GPL/LGPL nào.
//
// PHẠM VI M6.3 (bản tối thiểu):
//   - Đọc RPG::Map (width, height, data Table 3D) + RPG::Tileset (tileset_names,
//     flags Table 1D) để render tilemap.
//   - Đọc RPG::System (start_map_id, start_x, start_y) cho vị trí khởi đầu.
//   - Chưa đọc event list chi tiết (Game_Event đã xử lý trong Ruby).
//
// LƯU Ý ĐỌC: Arena và tree KHÔNG được dùng sau khi decode — extract dữ liệu
// ra struct Swift trong CÙNG scope của arena (giống ScriptLoader.swift).
// Không trả pointer ra ngoài hàm decode (use-after-free).

import Foundation

/// Một tilemap đã decode từ .rvdata2 — dữ liệu thuần Swift cho TilemapRenderer.
struct RGSSMapData {
    let mapID: Int
    let width: Int
    let height: Int
    /// Table 3D [width][height][4] — tile ID tại mỗi layer.
    let data: [Int]
    /// Tileset ID (chỉ số vào Tilesets.rvdata2).
    let tilesetID: Int
}

/// Một tileset đã decode — dữ liệu thuần Swift cho TilemapRenderer.
struct RGSSTilesetData {
    let id: Int
    /// Array[9] tên file tileset image (Graphics/Tilesets/*.png).
    let tilesetNames: [String]
    /// Table 1D — flags cho từng tile ID (bit 0 = impassable).
    let flags: [Int]
}

/// Dữ liệu System.rvdata2 — vị trí khởi đầu game.
struct RGSSSystemData {
    let startMapID: Int
    let startX: Int
    let startY: Int
}

enum DataFileLoaderError: Error, LocalizedError {
    case fileNotFound(String)
    case marshal(String)
    case invalidStructure(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let name):
            return "Data/\(name).rvdata2 does not exist in the game"
        case .marshal(let msg):
            return "Marshal error: \(msg)"
        case .invalidStructure(let msg):
            return "Invalid .rvdata2 structure: \(msg)"
        }
    }
}

enum DataFileLoader {

    /// Arena size cho Marshal decode — đủ cho Map/Tileset/System thông thường.
    private static let arenaSize = 16 * 1024 * 1024  // 16 MB

    // MARK: - Public API

    /// Đọc MapXXX.rvdata2 → RGSSMapData.
    /// Arena + tree sống trong scope này — extract trước khi destroy.
    static func loadMap(fromGameRoot rootURL: URL, mapID: Int) throws -> RGSSMapData {
        let fileName = String(format: "Map%03d", mapID)
        let dataURL = rootURL.appendingPathComponent("Data/\(fileName).rvdata2")
        guard FileManager.default.fileExists(atPath: dataURL.path),
              let data = try? Data(contentsOf: dataURL) else {
            throw DataFileLoaderError.fileNotFound(fileName)
        }

        // ── Decode trong arena ──
        guard let arena = rgss_arena_create(arenaSize) else {
            throw DataFileLoaderError.marshal("Not enough memory to create decode arena")
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
            throw DataFileLoaderError.marshal(msg)
        }

        // ── Root phải là OBJECT class RPG::Map ──
        guard let classNamePtr = rgss_value_object_class_name(loadedRoot),
              String(cString: classNamePtr) == "RPG::Map" else {
            throw DataFileLoaderError.invalidStructure("\(fileName).rvdata2 root must be RPG::Map")
        }

        // ── Extract (trong scope arena) ──
        var width = 0
        var height = 0
        var tilesetID = 0
        var dataArray: [Int] = []

        let ivarCount = Int(rgss_value_object_ivar_count(loadedRoot))
        for i in 0..<ivarCount {
            guard let keyPtr = rgss_value_object_ivar_key(loadedRoot, i),
                  let valuePtr = rgss_value_object_ivar_value(loadedRoot, i) else { continue }
            guard let key = symbolName(keyPtr) else { continue }

            switch key {
            case "width":
                width = Int(rgss_value_int(valuePtr))
            case "height":
                height = Int(rgss_value_int(valuePtr))
            case "tileset_id":
                tilesetID = Int(rgss_value_int(valuePtr))
            case "data":
                dataArray = tableData(valuePtr)
            default:
                break
            }
        }

        guard width > 0, height > 0 else {
            throw DataFileLoaderError.invalidStructure("\(fileName).rvdata2 missing width/height")
        }

        return RGSSMapData(mapID: mapID, width: width, height: height,
                           data: dataArray, tilesetID: tilesetID)
    }

    /// Đọc Tilesets.rvdata2 → [RGSSTilesetData] (toàn bộ tileset).
    /// Arena + tree sống trong scope này — extract trước khi destroy.
    static func loadTilesets(fromGameRoot rootURL: URL) throws -> [RGSSTilesetData] {
        let dataURL = rootURL.appendingPathComponent("Data/Tilesets.rvdata2")
        guard FileManager.default.fileExists(atPath: dataURL.path),
              let data = try? Data(contentsOf: dataURL) else {
            throw DataFileLoaderError.fileNotFound("Tilesets")
        }

        // ── Decode trong arena ──
        guard let arena = rgss_arena_create(arenaSize) else {
            throw DataFileLoaderError.marshal("Not enough memory to create decode arena")
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
            throw DataFileLoaderError.marshal(msg)
        }

        // ── Root phải là Array of RPG::Tileset ──
        guard rgss_value_type(loadedRoot) == RGSS_VAL_ARRAY else {
            throw DataFileLoaderError.invalidStructure("Tilesets.rvdata2 root must be an Array")
        }

        // ── Extract (trong scope arena) ──
        let count = Int(rgss_value_array_count(loadedRoot))
        var result: [RGSSTilesetData] = []
        result.reserveCapacity(count)

        for i in 0..<count {
            guard let tilesetPtr = rgss_value_array_item(loadedRoot, i) else { continue }
            guard let classNamePtr = rgss_value_object_class_name(tilesetPtr),
                  String(cString: classNamePtr) == "RPG::Tileset" else { continue }

            var id = 0
            var names: [String] = []
            var flags: [Int] = []

            let ivarCount = Int(rgss_value_object_ivar_count(tilesetPtr))
            for j in 0..<ivarCount {
                guard let keyPtr = rgss_value_object_ivar_key(tilesetPtr, j),
                      let valuePtr = rgss_value_object_ivar_value(tilesetPtr, j) else { continue }
                guard let key = symbolName(keyPtr) else { continue }

                switch key {
                case "id":
                    id = Int(rgss_value_int(valuePtr))
                case "tileset_names":
                    names = stringArray(valuePtr)
                case "flags":
                    flags = tableData(valuePtr)
                default:
                    break
                }
            }

            result.append(RGSSTilesetData(id: id, tilesetNames: names, flags: flags))
        }

        return result
    }

    /// Đọc System.rvdata2 → RGSSSystemData (vị trí khởi đầu).
    /// Arena + tree sống trong scope này — extract trước khi destroy.
    static func loadSystem(fromGameRoot rootURL: URL) throws -> RGSSSystemData {
        let dataURL = rootURL.appendingPathComponent("Data/System.rvdata2")
        guard FileManager.default.fileExists(atPath: dataURL.path),
              let data = try? Data(contentsOf: dataURL) else {
            throw DataFileLoaderError.fileNotFound("System")
        }

        // ── Decode trong arena ──
        guard let arena = rgss_arena_create(arenaSize) else {
            throw DataFileLoaderError.marshal("Not enough memory to create decode arena")
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
            throw DataFileLoaderError.marshal(msg)
        }

        // ── Root phải là OBJECT class RPG::System ──
        guard let classNamePtr = rgss_value_object_class_name(loadedRoot),
              String(cString: classNamePtr) == "RPG::System" else {
            throw DataFileLoaderError.invalidStructure("System.rvdata2 root must be RPG::System")
        }

        // ── Extract (trong scope arena) ──
        var startMapID = 0
        var startX = 0
        var startY = 0

        let ivarCount = Int(rgss_value_object_ivar_count(loadedRoot))
        for i in 0..<ivarCount {
            guard let keyPtr = rgss_value_object_ivar_key(loadedRoot, i),
                  let valuePtr = rgss_value_object_ivar_value(loadedRoot, i) else { continue }
            guard let key = symbolName(keyPtr) else { continue }

            switch key {
            case "start_map_id":
                startMapID = Int(rgss_value_int(valuePtr))
            case "start_x":
                startX = Int(rgss_value_int(valuePtr))
            case "start_y":
                startY = Int(rgss_value_int(valuePtr))
            default:
                break
            }
        }

        return RGSSSystemData(startMapID: startMapID, startX: startX, startY: startY)
    }

    // MARK: - Extract helpers

    /// Lấy tên symbol từ RGSSValue (SYMBOL type).
    /// Marshal lưu instance variable names dạng symbol có prefix "@"
    /// (ví dụ ":@width", ":@data") — strip "@" để so sánh với field name.
    private static func symbolName(_ v: UnsafePointer<RGSSValue>) -> String? {
        guard rgss_value_type(v) == RGSS_VAL_SYMBOL else { return nil }
        // Symbol lưu dưới dạng C string (null-terminated).
        guard let name = rgss_value_symbol_name(v) else { return nil }
        var result = String(cString: name)
        if result.hasPrefix("@") {
            result.removeFirst()
        }
        return result
    }

    /// Đọc Table (RGSS built-in) từ RGSSValue OBJECT → mảng phẳng [Int].
    /// Table lưu dưới dạng object với ivars: @dim, @xsize, @ysize, @zsize, @data.
    private static func tableData(_ v: UnsafePointer<RGSSValue>) -> [Int] {
        guard rgss_value_type(v) == RGSS_VAL_OBJECT else { return [] }

        let ivarCount = Int(rgss_value_object_ivar_count(v))
        for i in 0..<ivarCount {
            guard let keyPtr = rgss_value_object_ivar_key(v, i),
                  let valuePtr = rgss_value_object_ivar_value(v, i) else { continue }
            guard let key = symbolName(keyPtr) else { continue }
            if key == "data" {
                // @data là Array of Integer
                guard rgss_value_type(valuePtr) == RGSS_VAL_ARRAY else { return [] }
                let count = Int(rgss_value_array_count(valuePtr))
                var result = [Int](repeating: 0, count: count)
                for j in 0..<count {
                    if let item = rgss_value_array_item(valuePtr, j) {
                        result[j] = Int(rgss_value_int(item))
                    }
                }
                return result
            }
        }
        return []
    }

    /// Đọc Array of String từ RGSSValue.
    private static func stringArray(_ v: UnsafePointer<RGSSValue>) -> [String] {
        guard rgss_value_type(v) == RGSS_VAL_ARRAY else { return [] }
        let count = Int(rgss_value_array_count(v))
        var result: [String] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            guard let item = rgss_value_array_item(v, i) else { continue }
            guard rgss_value_type(item) == RGSS_VAL_STRING else { continue }
            let len = Int(rgss_value_string_len(item))
            if len > 0, let base = rgss_value_string_data(item) {
                result.append(String(bytes: UnsafeBufferPointer(start: base, count: len),
                                     encoding: .utf8) ?? "")
            } else {
                result.append("")
            }
        }
        return result
    }
}