import Foundation

/// Mức độ yêu cầu RTP (Runtime Package) của game RGSS.
/// RPG Maker XP/VX/VX Ace cần bộ Runtime Package riêng (Audio/Fonts/Graphics).
/// MV/MZ không dùng RTP (asset đã bundle trong www/).
enum RTPRequirement: String, Codable {
    /// Game không dùng RTP (MV/MZ, hoặc Game.ini không có dòng rtp=)
    case none
    /// rtp= non-empty trong Game.ini, nhưng Audio/Fonts/Graphics chưa đủ
    case required
    /// rtp= non-empty và người dùng đã merge đủ 3 thư mục
    case satisfied
}

/// Phân loại engine của game dựa vào cấu trúc thư mục sau khi giải nén.
/// Clean-room implementation — chỉ dựa vào tài liệu công khai RPG Maker.
///
/// Thứ tự ưu tiên kiểm tra:
/// 1. File archive RGSS (Game.rgssad / rgss2a / rgss3a) — chắc chắn nhất
/// 2. Thư mục Data/ với extension *.rxdata / *.rvdata / *.rvdata2 — fallback khi game không đóng gói
/// 3. Thư mục www/ với file JS đặc trưng của MV/MZ
enum GameDetector {

    // MARK: - Public API

    /// Phân loại engine từ thư mục gốc của game (sau khi giải nén zip).
    /// - Parameter rootURL: thư mục gốc chứa nội dung game (Application Support/RPGPlayer/Games/<uuid>/)
    /// - Returns: GameEngine phù hợp
    static func detect(in rootURL: URL) -> GameEngine {
        let fm = FileManager.default

        // --- Bước 1: Tìm thư mục chứa nội dung thực sự ---
        // Một số zip lồng thêm 1 thư mục con (ví dụ: zip chứa "MyGame/Game.exe")
        let gameRoot = resolveGameRoot(in: rootURL, fileManager: fm)

        // --- Bước 2: Kiểm tra RGSS archive files ---
        if fm.fileExists(atPath: gameRoot.appendingPathComponent("Game.rgssad").path) {
            return .rgssXP
        }
        if fm.fileExists(atPath: gameRoot.appendingPathComponent("Game.rgss2a").path) {
            return .rgssVX
        }
        if fm.fileExists(atPath: gameRoot.appendingPathComponent("Game.rgss3a").path) {
            return .rgssVXAce
        }

        // --- Bước 3: Kiểm tra MV/MZ (www/ structure) ---
        let wwwJS = gameRoot.appendingPathComponent("www/js")
        if fm.fileExists(atPath: wwwJS.appendingPathComponent("rmmz_core.js").path) {
            return .mz
        }
        if fm.fileExists(atPath: wwwJS.appendingPathComponent("rpg_core.js").path) {
            return .mv
        }

        // --- Bước 4: Kiểm tra thư mục Data/ theo extension ---
        let dataURL = gameRoot.appendingPathComponent("Data")
        if let dataEngine = detectFromDataFolder(dataURL, fileManager: fm) {
            return dataEngine
        }

        return .unknown
    }

    /// Xác định mức độ yêu cầu RTP (Runtime Package) của game RGSS.
    ///
    /// Logic:
    /// - Đọc Game.ini, tìm dòng bắt đầu bằng "rtp=" (case-insensitive).
    /// - Không có dòng rtp= hoặc giá trị rỗng → `.none` (MV/MZ cũng không có Game.ini → `.none`).
    /// - rtp= non-empty → kiểm tra 3 thư mục Audio/, Fonts/, Graphics/:
    ///   - Cả 3 đều tồn tại → `.satisfied` (user đã merge RTP)
    ///   - Thiếu bất kỳ 1 → `.required`
    ///
    /// Lưu ý: giá trị rtp= có thể là "RPGVXAce", "RPGVXace", "RPGXPace" hay bất kỳ
    /// chuỗi nào — KHÔNG hardcode whitelist, chỉ cần non-empty là đủ điều kiện.
    /// - Parameter rootURL: thư mục gốc chứa nội dung game (Application Support/RPGPlayer/Games/<uuid>/)
    /// - Returns: RTPRequirement tương ứng
    static func detectRTP(in rootURL: URL) -> RTPRequirement {
        let fm = FileManager.default
        let gameRoot = resolveGameRoot(in: rootURL, fileManager: fm)

        // --- Bước 1: Đọc Game.ini, tìm dòng rtp= ---
        let iniURL = gameRoot.appendingPathComponent("Game.ini")
        guard let iniContent = try? String(contentsOf: iniURL, encoding: .utf8) else {
            // Không có Game.ini (MV/MZ hoặc game không chuẩn) → không dùng RTP
            return .none
        }

        var rtpValue: String? = nil
        for line in iniContent.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("rtp=") {
                let value = String(trimmed.dropFirst("rtp=".count))
                    .trimmingCharacters(in: .whitespaces)
                rtpValue = value
                break
            }
        }

        // --- Bước 2: Không có rtp= hoặc giá trị rỗng → .none ---
        guard let rtp = rtpValue, !rtp.isEmpty else {
            return .none
        }

        // --- Bước 3: rtp= non-empty → kiểm tra 3 thư mục RTP ---
        let requiredDirs = ["Audio", "Fonts", "Graphics"]
        let allPresent = requiredDirs.allSatisfy { dir in
            fm.fileExists(atPath: gameRoot.appendingPathComponent(dir).path)
        }

        return allPresent ? .satisfied : .required
    }

    // MARK: - Private helpers

    /// Một số zip có cấu trúc lồng: zip root → subfolder → Game.exe
    /// Hàm này "descend" vào 1 lớp subfolder nếu root không chứa file game trực tiếp.
    private static func resolveGameRoot(in rootURL: URL, fileManager fm: FileManager) -> URL {
        // Nếu đã thấy file đặc trưng ở root → không cần descend
        let rgssFiles = ["Game.rgssad", "Game.rgss2a", "Game.rgss3a", "Game.exe", "Game.ini"]
        for file in rgssFiles {
            if fm.fileExists(atPath: rootURL.appendingPathComponent(file).path) {
                return rootURL
            }
        }
        // Kiểm tra www/ ở root
        if fm.fileExists(atPath: rootURL.appendingPathComponent("www").path) {
            return rootURL
        }

        // Descend vào 1 lớp subfolder duy nhất (nếu có)
        guard let contents = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return rootURL }

        let subdirs = contents.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        if subdirs.count == 1 {
            return subdirs[0]
        }

        return rootURL
    }

    /// Phân loại dựa vào extension file trong thư mục Data/
    private static func detectFromDataFolder(_ dataURL: URL, fileManager fm: FileManager) -> GameEngine? {
        guard fm.fileExists(atPath: dataURL.path) else { return nil }
        guard let contents = try? fm.contentsOfDirectory(
            at: dataURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var hasRxdata = false
        var hasRvdata = false
        var hasRvdata2 = false

        for url in contents {
            switch url.pathExtension.lowercased() {
            case "rxdata":  hasRxdata = true
            case "rvdata":  hasRvdata = true
            case "rvdata2": hasRvdata2 = true
            default: break
            }
        }

        // Ưu tiên rvdata2 > rvdata > rxdata
        if hasRvdata2 { return .rgssVXAce }
        if hasRvdata  { return .rgssVX }
        if hasRxdata  { return .rgssXP }
        return nil
    }

    /// Tìm tên game từ Game.ini (RPG Maker XP/VX/VXAce) hoặc package.json (MV/MZ)
    static func detectGameName(in rootURL: URL) -> String? {
        let gameRoot = resolveGameRoot(in: rootURL, fileManager: FileManager.default)

        // Thử Game.ini (dòng "Title=...")
        let iniURL = gameRoot.appendingPathComponent("Game.ini")
        if let iniContent = try? String(contentsOf: iniURL, encoding: .utf8) {
            for line in iniContent.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.lowercased().hasPrefix("title=") {
                    let title = String(trimmed.dropFirst("title=".count))
                        .trimmingCharacters(in: .whitespaces)
                    if !title.isEmpty { return title }
                }
            }
        }

        // Thử package.json (MV/MZ)
        let packageURL = gameRoot.appendingPathComponent("package.json")
        if let data = try? Data(contentsOf: packageURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let title = json["title"] as? String, !title.isEmpty {
            return title
        }

        return nil
    }

    /// Tìm file thumbnail/icon tiêu chuẩn của game (đường dẫn tương đối với gameRoot)
    static func detectThumbnail(in rootURL: URL) -> URL? {
        let gameRoot = resolveGameRoot(in: rootURL, fileManager: FileManager.default)
        let fm = FileManager.default

        // RPG Maker MV/MZ: icon.png ở www/
        let mvIcon = gameRoot.appendingPathComponent("www/icon/icon.png")
        if fm.fileExists(atPath: mvIcon.path) { return mvIcon }

        // Một số game để icon.png ở root
        let rootIcon = gameRoot.appendingPathComponent("icon.png")
        if fm.fileExists(atPath: rootIcon.path) { return rootIcon }

        // RPG Maker XP/VX/VXAce: không có icon chuẩn, một số game để GameIcon.png
        let gameIcon = gameRoot.appendingPathComponent("GameIcon.png")
        if fm.fileExists(atPath: gameIcon.path) { return gameIcon }

        return nil
    }
}
