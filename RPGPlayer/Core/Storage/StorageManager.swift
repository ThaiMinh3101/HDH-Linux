import Foundation

/// Quản lý đường dẫn sandbox, Application Support, và dung lượng file.
/// Mọi path đi qua struct này để đảm bảo nhất quán toàn app.
struct StorageManager {

    // MARK: - Singleton

    static let shared = StorageManager()
    private init() {}

    // MARK: - Root paths

    /// Application Support/RPGPlayer/
    var appSupportRoot: URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = appSupport.appendingPathComponent("RPGPlayer", isDirectory: true)
        createIfNeeded(root)
        return root
    }

    /// Application Support/RPGPlayer/Games/
    var gamesRoot: URL {
        let url = appSupportRoot.appendingPathComponent("Games", isDirectory: true)
        createIfNeeded(url)
        return url
    }

    // MARK: - Per-game paths

    /// Application Support/RPGPlayer/Games/<uuid>/
    func sandboxURL(for gameID: UUID) -> URL {
        let url = gamesRoot.appendingPathComponent(gameID.uuidString, isDirectory: true)
        createIfNeeded(url)
        return url
    }

    /// Application Support/RPGPlayer/Games/<uuid>/Saves/
    func savesURL(for gameID: UUID) -> URL {
        let url = sandboxURL(for: gameID).appendingPathComponent("Saves", isDirectory: true)
        createIfNeeded(url)
        return url
    }

    // MARK: - Metadata

    /// Application Support/RPGPlayer/library.json
    var libraryMetadataURL: URL {
        appSupportRoot.appendingPathComponent("library.json")
    }

    // MARK: - Relative paths

    /// Chuyển absolute URL thành relative path (tương đối với appSupportRoot)
    func relativePath(for absoluteURL: URL) -> String {
        let rootPath = appSupportRoot.path
        let absPath = absoluteURL.path
        if absPath.hasPrefix(rootPath) {
            return String(absPath.dropFirst(rootPath.count + 1)) // bỏ dấu "/"
        }
        return absPath
    }

    /// Chuyển relative path thành absolute URL
    func absoluteURL(fromRelative relativePath: String) -> URL {
        appSupportRoot.appendingPathComponent(relativePath)
    }

    // MARK: - Disk usage

    /// Tổng dung lượng thư mục sandbox của game (byte)
    func totalSize(for gameID: UUID) -> Int64 {
        directorySize(at: sandboxURL(for: gameID))
    }

    func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    /// Xoá toàn bộ sandbox của game (kể cả save)
    func deleteGame(id: UUID) throws {
        let url = sandboxURL(for: id)
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Helpers

    private func createIfNeeded(_ url: URL) {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if !exists || !isDir.boolValue {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
