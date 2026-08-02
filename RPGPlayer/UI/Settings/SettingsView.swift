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
                                    Text("Đồng bộ save game giữa các thiết bị")
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
                                Label("Đồng bộ ngay", systemImage: "arrow.triangle.2.circlepath")
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
                                ⚠️ iCloud không khả dụng.
                                Tính năng này yêu cầu:
                                • Đăng nhập iCloud trên thiết bị
                                • App được ký bằng Apple Developer account ($99/năm)
                                (AltStore với free Apple ID không hỗ trợ iCloud entitlement)
                                """)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            Text("Save game được lưu vào iCloud Drive/RPGPlayer/, ưu tiên file có thời gian sửa đổi mới hơn. Nếu xung đột không rõ ràng (< 2s), cả hai file được giữ nguyên.")
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
                                    Text("Ngôn ngữ dịch mặc định")
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.white)
                                    Text("Game chưa chọn riêng sẽ dùng mục này")
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
                        Text("Dịch thuật")
                            .foregroundStyle(.secondary)
                    } footer: {
                        Text("""
                            Dùng Apple Translation (on-device, iOS 17.4+). Ngôn ngữ nguồn tự động nhận diện. \
                            Mỗi game có thể đặt ngôn ngữ riêng từ menu trong game.
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
                                    Text("Quản lý bộ nhớ")
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.white)
                                    Text("Xem dung lượng, xóa cache hoặc xóa game")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "internaldrive")
                                    .foregroundStyle(.orange)
                            }
                        }
                    } header: {
                        Text("Bộ nhớ")
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color(white: 0.12))

                    // ── About ─────────────────────────────────────────────
                    Section {
                        aboutRow(icon: "gamecontroller", label: "Engine RGSS", value: "mruby (MIT)")
                        aboutRow(icon: "doc.zipper", label: "Giải nén ZIP", value: "ZIPFoundation (MIT)")
                        aboutRow(icon: "cpu", label: "Renderer", value: "MetalKit")
                        aboutRow(icon: "square.and.arrow.down", label: "Phân phối", value: "AltStore (sideload)")
                    } header: {
                        Text("Thông tin")
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color(white: 0.12))
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Cài đặt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Xong") { dismiss() }
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
            return "Chưa bật"
        case .idle:
            return "Sẵn sàng"
        case .syncing:
            return "Đang đồng bộ…"
        case .synced(let date):
            let fmt = RelativeDateTimeFormatter()
            fmt.unitsStyle = .short
            return "Đã đồng bộ \(fmt.localizedString(for: date, relativeTo: Date()))"
        case .error(let msg):
            // Show truncated error
            return "Lỗi: \(msg.prefix(60))"
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
