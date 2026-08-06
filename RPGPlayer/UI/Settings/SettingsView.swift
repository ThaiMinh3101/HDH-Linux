// RPGPlayer/UI/Settings/SettingsView.swift
//
// M3: Settings screen — iCloud sync toggle + status display.
// M4: Added storage management section (CleanupView link).
// M5: Added translation section (default target language picker).
// Presented as a sheet from LibraryView toolbar.

import SwiftUI
import Translation

struct SettingsView: View {

    @StateObject private var cloudSync = CloudSaveManager.shared
    @Environment(\.dismiss) private var dismiss

    // M5: Default target language — lưu per-app, dùng làm fallback khi game chưa set riêng.
    // Bản thân game lưu targetLanguageCode riêng trong GameEntry.
    @AppStorage("rpgplayer_default_target_language") private var defaultTargetLang: String = {
        // Default: tiếng Việt, trừ phi hệ thống đang dùng ngôn ngữ khác không phải tiếng Nhật
        let sys = Locale.current.language.languageCode?.identifier ?? "vi"
        return sys == "ja" ? "vi" : sys
    }()

    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                Color(white: 0.06).ignoresSafeArea()
                GeometryReader { geo in
                    Circle()
                        .fill(Color.purple.opacity(0.10))
                        .frame(width: 250, height: 250)
                        .blur(radius: 70)
                        .offset(x: geo.size.width * 0.7, y: 20)
                }
                .ignoresSafeArea()

                Form {
                    // ── iCloud Sync ───────────────────────────────────────
                    Section {
                        Toggle(isOn: $cloudSync.isEnabled) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("iCloud Sync")
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.white)
                                    Text("Sync save games across devices")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "icloud.fill")
                                    .foregroundStyle(cloudSync.isEnabled ? .blue : .secondary)
                            }
                        }
                        .tint(.blue)
                        .disabled(!CloudSaveManager.isICloudAvailable && !cloudSync.isEnabled)

                        // Status row
                        HStack(spacing: 10) {
                            statusIcon
                            Text(statusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if case .syncing = cloudSync.status {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                        }
                        .padding(.vertical, 2)

                        // Manual sync button
                        if cloudSync.isEnabled {
                            Button {
                                Task { await cloudSync.startSync() }
                            } label: {
                                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.blue)
                            }
                            .disabled({
                                if case .syncing = cloudSync.status { return true }
                                return false
                            }())
                        }

                    } header: {
                        Text("iCloud")
                            .foregroundStyle(.secondary)
                    } footer: {
                        if !CloudSaveManager.isICloudAvailable {
                            Text("""
                                ⚠️ iCloud is unavailable.
                                This feature requires:
                                • Signed in to iCloud on this device
                                • App signed with an Apple Developer account ($99/year)
                                (AltStore with a free Apple ID does not support the iCloud entitlement)
                                """)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            Text("Save games are stored in iCloud Drive/RPGPlayer/. The file with the newer modification date wins. If the conflict is ambiguous (< 2s), both files are kept.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Color(white: 0.12))

                    // ── Dịch thuật (M5) ───────────────────────────────────────────────
                    Section {
                        Picker(selection: $defaultTargetLang) {
                            ForEach(translationTargetLanguages, id: \.code) { lang in
                                Text(lang.displayName)
                                    .tag(lang.code)
                            }
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Default Translation Language")
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.white)
                                    Text("Games without their own setting use this")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "character.bubble")
                                    .foregroundStyle(.cyan)
                            }
                        }
                        .pickerStyle(.navigationLink)
                        .tint(.cyan)
                    } header: {
                        Text("Translation")
                            .foregroundStyle(.secondary)
                    } footer: {
                        Text("""
                            Uses Apple Translation (on-device, iOS 17.4+). Source language is auto-detected. \
                            Each game can set its own language from the in-game menu.
                            """)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color(white: 0.12))

                    // ── Bộ nhớ (M4) ───────────────────────────────────────
                    Section {
                        NavigationLink(destination: CleanupView()) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Storage Management")
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.white)
                                    Text("View size, delete cache, or delete games")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "internaldrive")
                                    .foregroundStyle(.orange)
                            }
                        }
                    } header: {
                        Text("Storage")
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color(white: 0.12))

                    // ── About ─────────────────────────────────────────────
                    Section {
                        aboutRow(icon: "gamecontroller", label: "Engine RGSS", value: "mruby (MIT)")
                        aboutRow(icon: "doc.zipper", label: "ZIP Extraction", value: "ZIPFoundation (MIT)")
                        aboutRow(icon: "cpu", label: "Renderer", value: "MetalKit")
                        aboutRow(icon: "square.and.arrow.down", label: "Distribution", value: "AltStore (sideload)")
                    } header: {
                        Text("About")
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color(white: 0.12))
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.purple)
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - Status helpers

    private var statusIcon: AnyView {
        switch cloudSync.status {
        case .disabled:
            return AnyView(Image(systemName: "icloud.slash").foregroundStyle(.secondary))
        case .idle:
            return AnyView(Image(systemName: "checkmark.icloud").foregroundStyle(.secondary))
        case .syncing:
            return AnyView(Image(systemName: "icloud.and.arrow.up.and.arrow.down").foregroundStyle(.blue))
        case .synced:
            return AnyView(Image(systemName: "checkmark.icloud.fill").foregroundStyle(.green))
        case .error:
            return AnyView(Image(systemName: "exclamationmark.icloud.fill").foregroundStyle(.red))
        }
    }

    private var statusText: String {
        switch cloudSync.status {
        case .disabled:
            return "Off"
        case .idle:
            return "Ready"
        case .syncing:
            return "Syncing…"
        case .synced(let date):
            let fmt = RelativeDateTimeFormatter()
            fmt.unitsStyle = .short
            return "Synced \(fmt.localizedString(for: date, relativeTo: Date()))"
        case .error(let msg):
            // Show truncated error
            return "Error: \(msg.prefix(60))"
        }
    }

    // MARK: - Reusable row

    private func aboutRow(icon: String, label: String, value: String) -> some View {
        HStack {
            Label(label, systemImage: icon)
                .font(.body)
                .foregroundStyle(.white)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Translation language list

/// Danh sách ngôn ngữ dịch đích mà Apple Translation hỗ trợ tốt.
/// BCP-47 code phải khớp với Locale.Language(languageCode:).
struct TranslationTargetLanguage: Identifiable {
    let id = UUID()
    let code: String
    let displayName: String
}

let translationTargetLanguages: [TranslationTargetLanguage] = [
    .init(code: "vi",      displayName: "🇻🇳 Tiếng Việt"),
    .init(code: "en",      displayName: "🇺🇸 English"),
    .init(code: "zh-Hans", displayName: "🇨🇳 中文（简体）"),
    .init(code: "zh-Hant", displayName: "🇹🇼 中文（繁體）"),
    .init(code: "ko",      displayName: "🇰🇷 한국어"),
    .init(code: "fr",      displayName: "🇫🇷 Français"),
    .init(code: "de",      displayName: "🇩🇪 Deutsch"),
    .init(code: "es",      displayName: "🇪🇸 Español"),
    .init(code: "pt",      displayName: "🇧🇷 Português"),
    .init(code: "ru",      displayName: "🇷🇺 Русский"),
    .init(code: "it",      displayName: "🇮🇹 Italiano"),
    .init(code: "ar",      displayName: "🇸🇦 العربية"),
    .init(code: "th",      displayName: "🇹🇭 ภาษาไทย"),
    .init(code: "id",      displayName: "🇮🇩 Bahasa Indonesia"),
]

#Preview {
    SettingsView()
}
