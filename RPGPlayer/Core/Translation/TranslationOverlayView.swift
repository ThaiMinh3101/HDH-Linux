// RPGPlayer/Core/Translation/TranslationOverlayView.swift
//
// M5: Translation overlay dùng Apple Translation framework.
//
// Thiết kế:
//  - Hiển thị bản dịch dưới game dưới dạng subtitle strip (không che game).
//  - Trạng thái bật/tắt lưu per-game trong library.json (translationEnabled).
//  - Target language chọn trong SettingsView, lưu per-game (targetLanguageCode).
//  - Auto-detect ngôn ngữ nguồn qua Apple Translation (không hardcode).
//  - Overlay ẩn khi không có text đang hiện, tự fade-out sau 4s không nhận text mới.
//
// Availability:
//  - TranslationSession + TranslationSession.Configuration chỉ available từ iOS 18.0
//    (không phải 17.4). TranslationOverlayView được guard bởi @available(iOS 18.0, *).
//  - Deployment target vẫn giữ 17.4: trên iOS 17.x app chạy bình thường, chỉ không
//    có tính năng dịch (toggle button ẩn, TranslationOverlayViewCompat render nothing).
//  - On-device model: không gửi data ra ngoài mạng.

import SwiftUI
import Translation

// MARK: - TranslationOverlayView

/// SwiftUI view hiển thị subtitle dịch phía dưới game.
/// Host trong UIHostingController và add vào RGSSViewController / GamePlayerViewController.
/// Requires iOS 18.0+ (TranslationSession available từ iOS 18.0, không phải 17.4).
@available(iOS 18.0, *)
struct TranslationOverlayView: View {

    // MARK: - Input từ parent

    /// GameEntry để lấy translationEnabled và targetLanguageCode
    let entry: GameEntry

    // MARK: - External input — text đến từ game engine

    /// Text mới nhất từ game (cập nhật bởi ViewController)
    @Binding var pendingText: String

    // MARK: - Internal state

    @State private var displayedTranslation: String = ""
    @State private var isTranslating: Bool = false
    @State private var isVisible: Bool = false
    @State private var fadeTimer: Timer? = nil

    // Apple Translation session — quản lý model download & translate requests
    @State private var translationSession: TranslationSession? = nil
    // Configuration: source = nil (auto-detect), target = từ targetLanguageCode
    @State private var sessionConfig: TranslationSession.Configuration? = nil

    // Toggle bật/tắt per-game (sync với library.json)
    @State private var isEnabled: Bool = false

    private let FADE_DELAY: TimeInterval = 4.0

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            // Chỉ render khi enabled và có translation
            if isEnabled && isVisible && !displayedTranslation.isEmpty {
                subtitleStrip
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Toggle button — luôn hiển thị góc dưới-phải
            toggleButton
        }
        .onAppear {
            isEnabled = entry.translationEnabled
            updateSessionConfig()
        }
        // Nhận text mới từ game engine
        .onChange(of: pendingText) { _, newText in
            guard isEnabled, !newText.isEmpty else { return }
            translate(newText)
        }
        // Nếu translationEnabled thay đổi từ bên ngoài (SettingsView), sync lại
        .onChange(of: entry.translationEnabled) { _, enabled in
            isEnabled = enabled
            if !enabled {
                hideOverlay()
            }
        }
        .onChange(of: entry.targetLanguageCode) { _, _ in
            // Target language thay đổi → reset session để tạo lại với config mới
            translationSession = nil
            updateSessionConfig()
        }
        // translationTask modifier quản lý model download tự động
        .translationTask(sessionConfig) { session in
            translationSession = session
        }
    }

    // MARK: - Subtitle strip UI

    private var subtitleStrip: some View {
        VStack(spacing: 0) {
            // Indicator đang dịch
            if isTranslating {
                HStack(spacing: 6) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.7)
                        .tint(.white.opacity(0.7))
                    Text("Đang dịch…")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            // Translation text
            if !displayedTranslation.isEmpty {
                Text(displayedTranslation)
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.vertical, isTranslating ? 8 : 12)
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial.opacity(0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)  // Above safe area / D-pad
        .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
    }

    // MARK: - Toggle button

    private var toggleButton: some View {
        HStack {
            Spacer()
            Button {
                withAnimation(.spring(response: 0.3)) {
                    let newEnabled = !isEnabled
                    isEnabled = newEnabled
                    // Persist vào library.json
                    LibraryStore.shared.updateTranslationSettings(
                        for: entry.id,
                        enabled: newEnabled
                    )
                    if !newEnabled { hideOverlay() }
                }
            } label: {
                Image(systemName: isEnabled ? "character.bubble.fill" : "character.bubble")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isEnabled ? .white : .white.opacity(0.5))
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(isEnabled
                                  ? Color(hue: 0.6, saturation: 0.7, brightness: 0.6).opacity(0.85)
                                  : Color.black.opacity(0.4))
                    )
            }
            .padding(.trailing, 12)
            .padding(.bottom, 60)  // Above D-pad area
            .accessibilityLabel(isEnabled ? "Tắt dịch" : "Bật dịch")
        }
    }

    // MARK: - Translation logic

    private func translate(_ text: String) {
        guard isEnabled, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Nếu session chưa sẵn sàng, đợi .translationTask callback
        guard let session = translationSession else {
            // Tạo config để kích hoạt download model nếu chưa có
            updateSessionConfig()
            return
        }

        isTranslating = true
        showOverlay()
        resetFadeTimer()

        Task {
            do {
                let response = try await session.translate(text)
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        displayedTranslation = response.targetText
                    }
                    isTranslating = false
                    resetFadeTimer()
                }
            } catch {
                await MainActor.run {
                    isTranslating = false
                    // Không crash, không hiện lỗi kỹ thuật cho user —
                    // chỉ ẩn overlay nếu text cũ đã hết hạn
                    if displayedTranslation.isEmpty { hideOverlay() }
                    print("[TranslationOverlay] ⚠️ Translation error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func updateSessionConfig() {
        // source = nil → auto-detect
        // target = từ targetLanguageCode của game, fallback sang system language
        let targetLocale: Locale.Language
        if let code = entry.targetLanguageCode, !code.isEmpty {
            targetLocale = Locale.Language(languageCode: Locale.LanguageCode(code))
        } else {
            // Ngôn ngữ hệ thống, nhưng nếu là tiếng Nhật (game RPG Maker thường vậy)
            // thì fallback về tiếng Việt để có ý nghĩa hơn
            let systemCode = Locale.current.language.languageCode?.identifier ?? "vi"
            let fallback = systemCode == "ja" ? "vi" : systemCode
            targetLocale = Locale.Language(languageCode: Locale.LanguageCode(fallback))
        }

        sessionConfig = TranslationSession.Configuration(
            source: nil,             // auto-detect ngôn ngữ game
            target: targetLocale
        )
    }

    // MARK: - Visibility helpers

    private func showOverlay() {
        withAnimation(.easeIn(duration: 0.15)) { isVisible = true }
    }

    private func hideOverlay() {
        withAnimation(.easeOut(duration: 0.3)) {
            isVisible = false
            displayedTranslation = ""
        }
        fadeTimer?.invalidate()
        fadeTimer = nil
    }

    private func resetFadeTimer() {
        fadeTimer?.invalidate()
        // a4 fix: TranslationOverlayView là struct (SwiftUI View) — không dùng
        // được [weak self] (chỉ hợp lệ cho class). Capture struct copy trực tiếp:
        // @State dùng shared storage box nên mutation qua self.hideOverlay()
        // vẫn cập nhật đúng state của view đang hiển thị.
        fadeTimer = Timer.scheduledTimer(withTimeInterval: FADE_DELAY, repeats: false) { _ in
            Task { @MainActor in self.hideOverlay() }
        }
    }
}

// MARK: - Fallback for iOS < 18.0

/// @Observable bridge — single source of truth cho text từ game engine.
/// UIKit set bridge.pendingText, SwiftUI đọc trực tiếp (không cần @Binding).
@Observable
final class TranslationTextBridge {
    var pendingText: String = ""
}

/// Wrapper hiển thị tính năng dịch.
/// Dùng #available(iOS 18.0, *) thay vì 17.4 vì TranslationSession cần iOS 18.0.
struct TranslationOverlayViewCompat: View {
    let entry: GameEntry
    @Bindable var bridge: TranslationTextBridge

    var body: some View {
        if #available(iOS 18.0, *) {
            // Chuyển bridge.pendingText thành @Binding cho TranslationOverlayView
            TranslationOverlayView(entry: entry, pendingText: $bridge.pendingText)
        }
        // Trên iOS < 18.0: không render gì (TranslationSession không available)
    }
}

// MARK: - UIKit hosting wrapper

/// UIHostingController wrapper để dễ add vào UIViewController hierarchy.
/// Bridge (@Observable) là cầu nối UIKit → SwiftUI không cần @Binding trực tiếp.
final class TranslationOverlayHostingController: UIHostingController<TranslationOverlayViewCompat> {

    private let bridge: TranslationTextBridge

    init(entry: GameEntry) {
        let b = TranslationTextBridge()
        self.bridge = b
        super.init(rootView: TranslationOverlayViewCompat(entry: entry, bridge: b))
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    /// Gọi từ ViewController khi nhận được text mới từ game (JS hoặc RGSS).
    /// @Observable bridge tự notify SwiftUI — không cần recreate rootView.
    @MainActor
    func receiveText(_ text: String) {
        bridge.pendingText = text
    }
}
