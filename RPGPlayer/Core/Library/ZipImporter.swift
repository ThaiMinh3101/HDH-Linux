import Foundation
import ZIPFoundation

/// Giải nén file ZIP vào thư mục đích.
/// Dùng ZIPFoundation (MIT license) — an toàn về license cho dự án này.
struct ZipImporter {

    // MARK: - Errors

    enum ImportError: LocalizedError {
        case notAZipFile
        case destinationNotWritable
        case extractionFailed(underlying: Error)
        case emptyArchive

        /// d2 fix: tất cả dialog/error message dùng tiếng Anh (M8 requirement).
        var errorDescription: String? {
            switch self {
            case .notAZipFile:
                return "The file is not a valid ZIP archive."
            case .destinationNotWritable:
                return "Cannot write to the destination folder."
            case .extractionFailed(let err):
                return "Extraction failed: \(err.localizedDescription)"
            case .emptyArchive:
                return "The ZIP archive is empty or contains no valid game files."
            }
        }
    }

    // MARK: - Public API

    /// Giải nén file ZIP bất đồng bộ vào thư mục đích.
    /// - Parameters:
    ///   - zipURL: URL file .zip đã được security-scoped access
    ///   - destination: thư mục đích (sẽ được tạo nếu chưa có)
    ///   - progress: closure nhận giá trị 0.0–1.0
    static func extract(
        from zipURL: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        // Đảm bảo extension là .zip (kiểm tra sơ bộ trước khi mở)
        guard zipURL.pathExtension.lowercased() == "zip" else {
            throw ImportError.notAZipFile
        }

        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default

            // Tạo thư mục đích
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)

            // Mở archive
            guard let archive = Archive(url: zipURL, accessMode: .read) else {
                throw ImportError.notAZipFile
            }

            // Đếm tổng số entry để tính progress
            let totalEntries = archive.reduce(0) { count, _ in count + 1 }
            guard totalEntries > 0 else {
                throw ImportError.emptyArchive
            }

            var extractedCount = 0

            for entry in archive {
                // Bỏ qua macOS metadata files (__MACOSX, .DS_Store)
                let entryPath = entry.path
                if entryPath.hasPrefix("__MACOSX/") || entryPath.hasSuffix(".DS_Store") {
                    continue
                }

                let entryURL = destination.appendingPathComponent(entryPath)

                do {
                    _ = try archive.extract(entry, to: entryURL, skipCRC32: false)
                } catch {
                    // Nếu entry là thư mục, ZIPFoundation có thể báo lỗi — bỏ qua
                    if entry.type == .directory { continue }
                    throw ImportError.extractionFailed(underlying: error)
                }

                extractedCount += 1
                let progressValue = Double(extractedCount) / Double(totalEntries)
                await MainActor.run { progress(progressValue) }
            }
        }.value
    }
}
