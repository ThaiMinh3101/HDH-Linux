import Foundation
import WebKit
import UniformTypeIdentifiers

// MARK: - RPGGameSchemeHandler
// Serves game files from the sandbox via custom scheme "rpggame://".
//
// URL format:  rpggame://<gameUUID>/path/to/file.ext
//              rpggame://<gameUUID>/index.html
//
// Maps to:     <AppSupport>/RPGPlayer/Games/<uuid>/<resolvedRoot>/path/to/file.ext
//
// Why a custom scheme instead of file://?
//   WKWebView restricts cross-origin access when using file:// URLs — assets
//   in sub-directories may be blocked.  A custom scheme handler bypasses those
//   restrictions while keeping the game fully sandboxed.

final class RPGGameSchemeHandler: NSObject, WKURLSchemeHandler {

    // MARK: - Properties

    private let gameID: UUID
    /// Absolute URL to the directory that contains index.html (www/ or game root).
    private let wwwRoot: URL

    // Track active tasks so we can cancel them when WKWebView requests it.
    private var activeTasks = Set<ObjectIdentifier>()
    private let lock = NSLock()

    // MARK: - Init

    /// - Parameters:
    ///   - gameID: UUID of the game entry.
    ///   - sandboxRoot: URL returned by `StorageManager.shared.sandboxURL(for: gameID)`.
    init(gameID: UUID, sandboxRoot: URL) {
        self.gameID = gameID
        self.wwwRoot = Self.resolveWWWRoot(in: sandboxRoot)
        super.init()
    }

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask)
        lock.lock()
        activeTasks.insert(taskID)
        lock.unlock()

        // Resolve file path from URL
        guard let fileURL = resolveFileURL(from: urlSchemeTask.request.url) else {
            finish(urlSchemeTask, with: .notFound, id: taskID)
            return
        }

        // Read asynchronously on a global queue to avoid blocking the main thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // Check task is still active before doing work
            self.lock.lock()
            let isActive = self.activeTasks.contains(taskID)
            self.lock.unlock()
            guard isActive else { return }

            do {
                let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                let mimeType = Self.mimeType(for: fileURL)
                let headers: [String: String] = [
                    "Content-Type":   mimeType,
                    "Content-Length": "\(data.count)",
                    "Cache-Control":  "max-age=3600",
                    // Allow same-origin requests from within the game's JS
                    "Access-Control-Allow-Origin": "*"
                ]
                let response = HTTPURLResponse(
                    url: urlSchemeTask.request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                )!
                self.lock.lock()
                let stillActive = self.activeTasks.contains(taskID)
                self.lock.unlock()
                guard stillActive else { return }

                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()

                self.lock.lock()
                self.activeTasks.remove(taskID)
                self.lock.unlock()
            } catch {
                self.finish(urlSchemeTask, with: .notFound, id: taskID)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask)
        lock.lock()
        activeTasks.remove(taskID)
        lock.unlock()
    }

    // MARK: - Path Resolution

    /// Convert `rpggame://<uuid>/some/path.ext` → absolute file URL inside wwwRoot.
    private func resolveFileURL(from url: URL?) -> URL? {
        guard let url,
              url.scheme == "rpggame" else { return nil }

        // url.path starts with "/<uuid>/rest/of/path" when host is the uuid
        // OR the path may already be the file path if host is empty.
        // We strip the leading "/" then skip the first segment (uuid) if present.
        var pathComponents = url.pathComponents
            .filter { $0 != "/" }

        // If host == gameID.uuidString, pathComponents is the subpath directly.
        // If host is empty/nil, first component might be the uuid — strip it.
        if let host = url.host, host == gameID.uuidString {
            // path components are already the subpath (host consumed the uuid part)
        } else if pathComponents.first == gameID.uuidString {
            pathComponents.removeFirst()
        }

        guard !pathComponents.isEmpty else {
            // Default to index.html when root is requested
            return wwwRoot.appendingPathComponent("index.html")
        }

        var fileURL = wwwRoot
        for component in pathComponents {
            fileURL = fileURL.appendingPathComponent(component)
        }
        return fileURL
    }

    // MARK: - Error Helper

    private enum HTTPError: Int { case notFound = 404 }

    private func finish(_ task: WKURLSchemeTask, with error: HTTPError, id: ObjectIdentifier) {
        lock.lock()
        let isActive = activeTasks.contains(id)
        activeTasks.remove(id)
        lock.unlock()
        guard isActive else { return }

        let response = HTTPURLResponse(
            url: task.request.url!,
            statusCode: error.rawValue,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/plain"]
        )!
        task.didReceive(response)
        task.didReceive(Data())
        task.didFinish()
    }

    // MARK: - MIME Type Detection

    static func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        // Web
        case "html", "htm":  return "text/html; charset=utf-8"
        case "css":          return "text/css"
        case "js":           return "application/javascript"
        case "json":         return "application/json"
        case "xml":          return "application/xml"
        // Images
        case "png":          return "image/png"
        case "jpg", "jpeg":  return "image/jpeg"
        case "gif":          return "image/gif"
        case "webp":         return "image/webp"
        case "svg":          return "image/svg+xml"
        case "ico":          return "image/x-icon"
        // Audio (RPG Maker MZ supports ogg + m4a fallback)
        case "ogg":          return "audio/ogg"
        case "m4a":          return "audio/mp4"
        case "mp3":          return "audio/mpeg"
        case "wav":          return "audio/wav"
        // Video
        case "mp4":          return "video/mp4"
        case "webm":         return "video/webm"
        // Fonts
        case "woff":         return "font/woff"
        case "woff2":        return "font/woff2"
        case "ttf":          return "font/ttf"
        case "otf":          return "font/otf"
        // Data
        case "bin":          return "application/octet-stream"
        case "rpgmvp",
             "rpgmvo",
             "rpgmvm":       return "application/octet-stream" // encrypted RPG Maker assets
        default:
            // Ask the system if UTType knows it
            if let utType = UTType(filenameExtension: ext),
               let mime = utType.preferredMIMEType {
                return mime
            }
            return "application/octet-stream"
        }
    }

    // MARK: - WWW Root Resolution
    // Mirrors GameDetector.resolveGameRoot but returns the www/ directory.

    static func resolveWWWRoot(in sandboxRoot: URL) -> URL {
        let fm = FileManager.default

        // Check direct www/ at sandbox root
        let wwwDirect = sandboxRoot.appendingPathComponent("www")
        if fm.fileExists(atPath: wwwDirect.path) { return wwwDirect }

        // Check for a single subdirectory (zip wrapped in folder)
        if let contents = try? fm.contentsOfDirectory(
            at: sandboxRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            let subdirs = contents.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            if subdirs.count == 1 {
                let nested = subdirs[0].appendingPathComponent("www")
                if fm.fileExists(atPath: nested.path) { return nested }
                // MV games sometimes have index.html at game root (no www/)
                let nestedIndex = subdirs[0].appendingPathComponent("index.html")
                if fm.fileExists(atPath: nestedIndex.path) { return subdirs[0] }
            }
        }

        // Fallback: index.html at sandbox root (unusual but possible)
        return sandboxRoot
    }
}
