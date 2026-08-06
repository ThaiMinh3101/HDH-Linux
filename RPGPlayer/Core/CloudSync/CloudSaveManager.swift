// RPGPlayer/Core/CloudSync/CloudSaveManager.swift
//
// M3: iCloud Documents sync for game save data + library.json.
//
// Architecture:
//   - Uses NSFileManager ubiquity container (iCloud Documents), NOT CloudKit.
//   - Each game's Saves/ directory is synced to:
//       <iCloud>/RPGPlayer/<gameID>/Saves/
//   - library.json is synced to:
//       <iCloud>/RPGPlayer/library.json
//
// Conflict resolution:
//   - File with newer mtime wins.
//   - If timestamps are within CONFLICT_AMBIGUOUS_SECONDS of each other,
//     neither is auto-overwritten; both files are kept and a warning is logged.
//     (This follows the task spec: "ask me" rather than auto-decide.)
//
// IMPORTANT — iCloud entitlement requirement:
//   This code is correct and complete, but iCloud Documents ONLY works when the
//   app is signed with a provisioning profile that has the iCloud capability
//   enabled for a registered iCloud Container ID (requires paid Apple Developer
//   account). When sideloaded via AltStore with a free Apple ID, the ubiquity
//   container URL will be nil and sync will be disabled automatically with a
//   clear log message.
//
// Entitlement needed in project.yml (see note at bottom of this file):
//   com.apple.developer.ubiquity-container-identifiers: [iCloud.com.rpgplayer.app]
//   com.apple.developer.icloud-services: [CloudDocuments]

import Foundation
import Combine

// ── Sync status ───────────────────────────────────────────────────────────

enum CloudSyncStatus: Equatable {
    case disabled           // iCloud not available or toggled off
    case idle               // enabled, nothing pending
    case syncing            // upload/download in progress
    case synced(Date)       // last successful sync timestamp
    case error(String)      // last error message
}

// ── Constants ─────────────────────────────────────────────────────────────

private let kICloudContainerID     = "iCloud.com.rpgplayer.app"
private let kCloudRootFolder       = "RPGPlayer"
private let kConflictAmbiguousSeconds: TimeInterval = 2.0
private let kSyncSettingsKey       = "rpgplayer_icloud_sync_enabled"

// ── CloudSaveManager ──────────────────────────────────────────────────────

@MainActor
final class CloudSaveManager: ObservableObject {

    // MARK: - Published state

    @Published private(set) var status: CloudSyncStatus = .disabled
    @Published          var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: kSyncSettingsKey)
            if isEnabled { Task { await startSync() } }
            else          { status = .disabled }
        }
    }

    // MARK: - Singleton

    static let shared = CloudSaveManager()
    private init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: kSyncSettingsKey)
    }

    // MARK: - iCloud container URL

    /// Returns the iCloud Documents container root, or nil if unavailable.
    /// Nil means either the entitlement is missing (sideload) or iCloud is
    /// disabled in Settings on this device.
    private var cloudRoot: URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: kICloudContainerID)?
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(kCloudRootFolder, isDirectory: true)
    }

    // MARK: - Public API

    /// Call this on app launch (and when toggled on) to kick off a sync cycle.
    func startSync() async {
        guard isEnabled else { status = .disabled; return }

        guard let root = cloudRoot else {
            status = .error(
                "iCloud container niet beschikbaar. " +
                "Controleer of iCloud is ingeschakeld en of de app juist ondertekend is. " +
                "(iCloud container unavailable — requires paid Apple Developer account signing.)"
            )
            print("[CloudSync] ⚠️  iCloud container URL is nil. iCloud sync is not available " +
                  "with sideload signing (free Apple ID). " +
                  "A paid Apple Developer account is required to enable this feature.")
            return
        }

        status = .syncing
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try await syncLibraryJSON(cloudRoot: root)
            try await syncAllGameSaves(cloudRoot: root)
            status = .synced(Date())
        } catch {
            status = .error(error.localizedDescription)
            print("[CloudSync] ❌ Sync failed: \(error)")
        }
    }

    /// Sync a single game's Saves/ directory immediately (e.g., after in-game save).
    func syncGameSaves(for gameID: UUID) async {
        guard isEnabled, let root = cloudRoot else { return }
        status = .syncing
        do {
            try await syncSavesDirectory(gameID: gameID, cloudRoot: root)
            status = .synced(Date())
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    // MARK: - Library JSON sync

    private func syncLibraryJSON(cloudRoot: URL) async throws {
        let localURL = StorageManager.shared.libraryMetadataURL
        let cloudURL = cloudRoot.appendingPathComponent("library.json")

        // a7 fix: ensure the cloud directory exists before copyItem.
        // startSync() creates cloudRoot, but if the app was killed between
        // createDirectory and this call (or iCloud evicted the folder), the
        // parent of library.json may not exist → copyItem would throw.
        try FileManager.default.createDirectory(
            at: cloudRoot,
            withIntermediateDirectories: true
        )

        try syncFile(local: localURL, cloud: cloudURL, description: "library.json")
    }

    // MARK: - All games saves sync

    private func syncAllGameSaves(cloudRoot: URL) async throws {
        let fm = FileManager.default
        let gamesRoot = StorageManager.shared.gamesRoot

        guard let contents = try? fm.contentsOfDirectory(
            at: gamesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for gameDir in contents {
            guard let uuidStr = Optional(gameDir.lastPathComponent),
                  let gameID = UUID(uuidString: uuidStr) else { continue }
            try await syncSavesDirectory(gameID: gameID, cloudRoot: cloudRoot)
        }
    }

    private func syncSavesDirectory(gameID: UUID, cloudRoot: URL) async throws {
        let localSaves = StorageManager.shared.savesURL(for: gameID)
        let cloudSaves = cloudRoot
            .appendingPathComponent(gameID.uuidString, isDirectory: true)
            .appendingPathComponent("Saves", isDirectory: true)

        let fm = FileManager.default
        try fm.createDirectory(at: cloudSaves, withIntermediateDirectories: true)

        // Collect all files from both sides
        let localFiles  = (try? fm.contentsOfDirectory(at: localSaves,  includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        let cloudFiles  = (try? fm.contentsOfDirectory(at: cloudSaves, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []

        var allNames = Set<String>()
        localFiles.forEach  { allNames.insert($0.lastPathComponent) }
        cloudFiles.forEach  { allNames.insert($0.lastPathComponent) }

        for name in allNames {
            let local = localSaves.appendingPathComponent(name)
            let cloud = cloudSaves.appendingPathComponent(name)
            try syncFile(local: local, cloud: cloud,
                         description: "\(gameID.uuidString)/Saves/\(name)")
        }
    }

    // MARK: - File-level sync

    /// Bidirectional sync for a single file.
    /// Conflict resolution: newer mtime wins. Ambiguous timestamps kept as-is + logged.
    private func syncFile(local: URL, cloud: URL, description: String) throws {
        let fm = FileManager.default
        let localExists = fm.fileExists(atPath: local.path)
        let cloudExists = fm.fileExists(atPath: cloud.path)

        switch (localExists, cloudExists) {
        case (false, false):
            return  // nothing to do

        case (true, false):
            // Upload: copy local → cloud
            try fm.copyItem(at: local, to: cloud)
            print("[CloudSync] ⬆️  Uploaded \(description)")

        case (false, true):
            // Download: copy cloud → local
            try fm.copyItem(at: cloud, to: local)
            print("[CloudSync] ⬇️  Downloaded \(description)")

        case (true, true):
            // Both exist — compare mtimes
            let localMtime = try local.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            let cloudMtime = try cloud.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            let diff = abs(localMtime.timeIntervalSince(cloudMtime))

            if diff < kConflictAmbiguousSeconds {
                // ⚠️ Ambiguous — do NOT overwrite either side. Log and leave both.
                print("""
                [CloudSync] ⚠️  CONFLICT (ambiguous) for \(description):
                   local  mtime = \(localMtime)
                   cloud  mtime = \(cloudMtime)
                   diff   = \(String(format: "%.3f", diff))s (< \(kConflictAmbiguousSeconds)s threshold)
                   Action: NO automatic resolution — both files kept as-is.
                   Manual resolution required.
                """)
                return
            }

            if localMtime > cloudMtime {
                // Local is newer → upload
                try fm.removeItem(at: cloud)
                try fm.copyItem(at: local, to: cloud)
                print("[CloudSync] ⬆️  Replaced cloud with newer local: \(description)")
            } else {
                // Cloud is newer → download
                try fm.removeItem(at: local)
                try fm.copyItem(at: cloud, to: local)
                print("[CloudSync] ⬇️  Replaced local with newer cloud: \(description)")
            }
        }
    }
}

// MARK: - iCloud Availability Check (static helper)

extension CloudSaveManager {
    /// True if the iCloud container is reachable on this device.
    /// Will return false on AltStore sideload with free Apple ID.
    static var isICloudAvailable: Bool {
        FileManager.default.url(forUbiquityContainerIdentifier: kICloudContainerID) != nil
    }
}

/*
 NOTE FOR PROJECT.YML — iCloud entitlement setup:
 ─────────────────────────────────────────────────
 To activate iCloud Documents sync, add the following to project.yml
 under targets.RPGPlayer.settings:

     ENABLE_ICLOUD: YES

 And create an entitlements file at RPGPlayer/RPGPlayer.entitlements with:

     <?xml version="1.0" encoding="UTF-8"?>
     <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" ...>
     <plist version="1.0"><dict>
       <key>com.apple.developer.icloud-container-identifiers</key>
       <array><string>iCloud.com.rpgplayer.app</string></array>
       <key>com.apple.developer.icloud-services</key>
       <array><string>CloudDocuments</string></array>
       <key>com.apple.developer.ubiquity-container-identifiers</key>
       <array><string>iCloud.com.rpgplayer.app</string></array>
     </dict></plist>

 Then in project.yml settings add:
     CODE_SIGN_ENTITLEMENTS: RPGPlayer/RPGPlayer.entitlements

 ⚠️ This ONLY works with a paid Apple Developer account ($99/year)
    that has registered the iCloud container in the Apple Developer Portal.
    AltStore sideload (free Apple ID) cannot activate iCloud entitlements.
*/
