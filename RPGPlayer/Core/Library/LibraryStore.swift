import Foundation
import Observation

/// Trạng thái import đang diễn ra
struct ImportState {
    var isImporting: Bool = false
    var progress: Double = 0
    var currentFileName: String = ""
    var error: String? = nil
}

/// Store trung tâm cho thư viện game.
/// Dùng @Observable (iOS 17) — không dùng @ObservableObject để tận dụng macro mới.
///
/// Lý do chọn JSON thay vì SwiftData:
/// - Schema đơn giản, không cần query phức tạp ở M0
/// - Dễ debug (readable file), dễ port lên iCloud Documents ở M3
/// - Tránh SwiftData migration complexity khi schema thay đổi
@Observable
@MainActor
final class LibraryStore {

    // MARK: - Published state

    var games: [GameEntry] = []
    var importState = ImportState()

    // MARK: - Singleton

    static let shared = LibraryStore()
    private init() {
        load()
    }

    // MARK: - Persistence

    private var metadataURL: URL {
        StorageManager.shared.libraryMetadataURL
    }

    func load() {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            games = []
            return
        }
        do {
            let data = try Data(contentsOf: metadataURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            games = try decoder.decode([GameEntry].self, from: data)
        } catch {
            // Nếu decode thất bại (file hỏng), reset về rỗng thay vì crash
            print("[LibraryStore] Decode thất bại, reset thư viện: \(error)")
            games = []
        }
    }

    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(games)
            try data.write(to: metadataURL, options: .atomic)
        } catch {
            print("[LibraryStore] Ghi library.json thất bại: \(error)")
        }
    }

    // MARK: - Import

    /// Import một file ZIP: giải nén → phát hiện engine → lưu metadata → thêm vào thư viện.
    /// Báo lỗi rõ ràng thay vì crash nếu không nhận ra engine hoặc giải nén thất bại.
    func importGame(from zipURL: URL) async {
        // Security-scoped access cho file từ Files app
        let accessing = zipURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { zipURL.stopAccessingSecurityScopedResource() }
        }

        let newID = UUID()
        let destination = StorageManager.shared.sandboxURL(for: newID)

        importState = ImportState(isImporting: true, currentFileName: zipURL.lastPathComponent)

        do {
            // 1. Giải nén
            try await ZipImporter.extract(from: zipURL, to: destination) { [weak self] prog in
                guard let self else { return }
                Task { @MainActor in
                    self.importState.progress = prog
                }
            }

            // 2. Phát hiện engine
            let engine = GameDetector.detect(in: destination)

            // 3. Tên game
            let detectedName = GameDetector.detectGameName(in: destination)
            let gameName = detectedName ?? zipURL.deletingPathExtension().lastPathComponent

            // 4. Thumbnail
            let thumbnailURL = GameDetector.detectThumbnail(in: destination)
            var relativeThumbnail: String? = nil
            if let tURL = thumbnailURL {
                relativeThumbnail = StorageManager.shared.relativePath(for: tURL)
            }

            // 5. Kích thước
            let size = StorageManager.shared.totalSize(for: newID)

            let entry = GameEntry(
                id: newID,
                name: gameName,
                engine: engine,
                importDate: Date(),
                relativeSandboxPath: StorageManager.shared.relativePath(for: destination),
                relativeThumbnailPath: relativeThumbnail,
                sizeBytes: size
            )

            games.append(entry)
            save()

            // 6. Nếu engine không nhận ra → giữ entry nhưng báo user
            if engine == .unknown {
                importState = ImportState(
                    isImporting: false,
                    error: "Game \"\(gameName)\" đã được import nhưng không nhận dạng được engine. " +
                           "Kiểm tra lại cấu trúc thư mục game."
                )
            } else {
                importState = ImportState(isImporting: false)
            }

        } catch {
            // Dọn dẹp thư mục đã tạo nếu thất bại
            try? FileManager.default.removeItem(at: destination)
            importState = ImportState(
                isImporting: false,
                error: "Import thất bại: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Delete

    func deleteGame(_ entry: GameEntry) {
        do {
            try StorageManager.shared.deleteGame(id: entry.id)
        } catch {
            print("[LibraryStore] Xoá game thất bại: \(error)")
        }
        games.removeAll { $0.id == entry.id }
        save()
    }

    // MARK: - Helpers

    func absoluteSandboxURL(for entry: GameEntry) -> URL {
        StorageManager.shared.absoluteURL(fromRelative: entry.relativeSandboxPath)
    }
}
