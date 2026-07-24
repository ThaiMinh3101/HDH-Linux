// RPGPlayer/Core/Engine/WebViewPool.swift
//
// Milestone 4 — Fast Launch: WKWebView Warm-up Pool
//
// DESIGN DECISION:
// After iOS 14+, WKUserContentController cannot be mutated (addUserScript /
// add messageHandler) once the WKWebView has been created with that config.
// Because of this restriction, we cannot safely pre-allocate a full
// WKWebView with all message handlers and reuse it across view controllers.
//
// What this pool DOES:
//   - Pre-computes the sandboxURL for a given game so buildWebView()
//     can skip the FileManager lookup on the hot path.
//   - Provides a `wasWarmed(for:)` API that GameDetailViewMV can use
//     to measure warm vs cold launch timing.
//   - Frees cached URLs on memory pressure / app background.
//
// The main fast-launch wins in Milestone 4 come from:
//   1. LaunchTimingBridge.js measuring where time is actually spent
//   2. onAppear warm-up so Swift-side setup happens during navigation animation
//   3. Reduced setup path (static makeWebViewConfig avoids redundant allocs)
//
// Future milestone: explore WKURLSchemeTask pre-fetching of game assets.

import UIKit
import WebKit

@MainActor
final class WebViewPool: NSObject {

    // MARK: - Singleton

    static let shared = WebViewPool()
    private override init() {
        super.init()
        registerMemoryPressureObserver()
    }

    // MARK: - State

    /// Pre-computed sandbox URL for each warmed game ID.
    private var warmedURLs: [UUID: URL] = [:]

    // MARK: - Public API

    /// Pre-computes and caches the sandbox URL for the given game entry.
    /// Lightweight — no WKWebView is created here.
    func warmUp(for entry: GameEntry) {
        guard warmedURLs[entry.id] == nil else { return }
        let sandboxURL = StorageManager.shared.sandboxURL(for: entry.id)
        warmedURLs[entry.id] = sandboxURL
        print("[WebViewPool] ♻️  Warmed sandbox URL for '\(entry.name)'")
    }

    /// Returns the pre-computed sandbox URL if available, else computes it now.
    /// Always returns a valid URL — never nil.
    func sandboxURL(for gameID: UUID) -> URL {
        if let cached = warmedURLs[gameID] {
            warmedURLs.removeValue(forKey: gameID)
            return cached
        }
        return StorageManager.shared.sandboxURL(for: gameID)
    }

    /// True if a sandbox URL has been pre-computed for this game.
    func wasWarmed(for gameID: UUID) -> Bool {
        warmedURLs[gameID] != nil
    }

    /// Clears all cached entries (called on memory pressure or background).
    func clear() {
        if !warmedURLs.isEmpty {
            print("[WebViewPool] 🧹 Cleared \(warmedURLs.count) warmed URLs")
        }
        warmedURLs.removeAll()
    }

    // MARK: - Memory pressure

    private func registerMemoryPressureObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    @objc private func handleMemoryWarning() { clear() }
    @objc private func handleBackground()    { clear() }
}

