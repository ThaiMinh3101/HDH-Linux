import SwiftUI

/// Thẻ game hiển thị trong lưới Library.
/// Thiết kế: glassmorphism tối, thumbnail + badge engine + tên game.
/// MV/MZ cards tap → GameDetailViewMV. RGSS cards are not yet playable.
struct GameCardView: View {

    let entry: GameEntry
    var onDelete: (() -> Void)? = nil

    // MARK: - M8.1: RTP warning dialog state
    /// True khi đang hiện dialog cảnh báo RTP (chỉ khi rtpRequirement == .required).
    @State private var showRTPWarning = false
    /// Điều hướng programmatically vào màn hình game (sau khi xác nhận dialog).
    @State private var isNavigating = false

    /// True khi engine đã hỗ trợ play.
    /// M6.0: thêm VX Ace (chạy được script load pipeline mruby).
    /// XP/VX chưa hỗ trợ (data format khác — sẽ làm sau).
    private var isPlayable: Bool {
        entry.engine == .mv || entry.engine == .mz || entry.engine == .rgssVXAce
    }

    // Thumbnail từ sandbox (nil nếu không có)
    private var thumbnailImage: Image? {
        guard let rel = entry.relativeThumbnailPath else { return nil }
        let url = StorageManager.shared.absoluteURL(fromRelative: rel)
        guard FileManager.default.fileExists(atPath: url.path),
              let uiImage = UIImage(contentsOfFile: url.path) else { return nil }
        return Image(uiImage: uiImage)
    }

    var body: some View {
        Group {
            if isPlayable {
                ZStack {
                    // Hidden NavigationLink — trigger programmatically
                    // (M8.1) sau khi user xác nhận dialog RTP cảnh báo.
                    NavigationLink(destination: destinationView(entry), isActive: $isNavigating) {
                        EmptyView()
                    }
                    .opacity(0)
                    .frame(width: 0, height: 0)

                    Button(action: handlePlayTap) {
                        cardContent
                    }
                    .buttonStyle(.plain)
                }
            } else {
                cardContent
            }
        }
        .contextMenu {
            // d4 fix: English UI strings
            Button(role: .destructive) {
                onDelete?()
            } label: {
                Label("Delete Game", systemImage: "trash")
            }
        }
        // M8.1: Warning dialog "Run-Time Package Required" — English, same tone as Empo.
        // Chỉ hiện khi entry.rtpRequirement == .required (game RGSS chưa merge RTP).
        .alert("Run-Time Package Required", isPresented: $showRTPWarning) {
            Button("Cancel", role: .cancel) { }
            Button("Continue Anyway") { isNavigating = true }
        } message: {
            Text(rtpWarningMessage)
        }
    }

    // MARK: - M8.1: Play tap handling

    /// Tap play: nếu game yêu cầu RTP chưa được merge → hiện cảnh báo trước.
    /// .none (MV/MZ) và .satisfied (đã merge đủ RTP) → launch thẳng.
    private func handlePlayTap() {
        if entry.rtpRequirement == .required {
            showRTPWarning = true
        } else {
            isNavigating = true
        }
    }

    /// Message tiếng Anh cho dialog cảnh báo RTP (giống tone Empo).
    private var rtpWarningMessage: String {
        """
        "\(entry.name)" needs shared RPG Maker assets (Audio, Fonts, Graphics) \
        that are not bundled with the game.

        To fix this: extract the RPG Maker Run-Time Package, then copy the Audio, \
        Fonts and Graphics folders into the game folder and re-import.

        You can continue without RTP, but the game may crash or have missing \
        graphics and audio.
        """
    }

    /// Chọn destination theo engine: MV/MZ → web engine, RGSS → mruby/Metal engine.
    @ViewBuilder
    private func destinationView(_ entry: GameEntry) -> some View {
        switch entry.engine {
        case .mv, .mz:
            GameDetailViewMV(entry: entry)
        case .rgssVXAce:
            GameDetailViewRGSS(entry: entry)
        case .rgssXP, .rgssVX, .unknown:
            // Chưa hỗ trợ play — không nên tới đây (isPlayable = false)
            EmptyView()
        }
    }

    // MARK: - Card content

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {

            // MARK: Thumbnail / Placeholder
            ZStack(alignment: .topTrailing) {
                thumbnailArea
                VStack(alignment: .trailing, spacing: 4) {
                    engineBadge
                    if isPlayable {
                        playBadge
                    }
                }
                .padding(8)
            }
            .frame(height: 130)
            .clipped()

            // MARK: Info
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name)
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)

                Text(entry.importDate, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isPlayable ? entry.engine.badgeColor.opacity(0.25) : .white.opacity(0.08),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Sub views

    @ViewBuilder
    private var thumbnailArea: some View {
        if let image = thumbnailImage {
            image
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
        } else {
            placeholderView
        }
    }

    private var placeholderView: some View {
        ZStack {
            LinearGradient(
                colors: [
                    entry.engine.badgeColor.opacity(0.3),
                    entry.engine.badgeColor.opacity(0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 6) {
                Image(systemName: placeholderIcon)
                    .font(.system(size: 32, weight: .thin))
                    .foregroundStyle(entry.engine.badgeColor.opacity(0.7))
                Text(entry.engine.displayName)
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(entry.engine.badgeColor.opacity(0.6))
                    .kerning(1.5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholderIcon: String {
        switch entry.engine {
        case .rgssXP, .rgssVX, .rgssVXAce: return "gamecontroller"
        case .mv, .mz:                      return "globe"
        case .unknown:                      return "questionmark.square.dashed"
        }
    }

    private var engineBadge: some View {
        Text(entry.engine.displayName)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .kerning(0.8)
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(entry.engine.badgeColor)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .shadow(color: entry.engine.badgeColor.opacity(0.6), radius: 4)
    }

    /// Small ▶ play indicator shown only on playable (MV/MZ) cards
    private var playBadge: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(5)
            .background(.black.opacity(0.55))
            .clipShape(Circle())
    }

    private var cardBackground: some View {
        ZStack {
            Color(white: 0.10)
            LinearGradient(
                colors: [.white.opacity(0.04), .clear],
                startPoint: .top,
                endPoint: .center
            )
        }
    }
}

#Preview {
    HStack {
        GameCardView(entry: GameEntry(
            name: "Sword of Dawn",
            engine: .rgssVXAce,
            relativeSandboxPath: "Games/preview/"
        ))
        GameCardView(entry: GameEntry(
            name: "Forest Chronicles MZ",
            engine: .mz,
            relativeSandboxPath: "Games/preview2/"
        ))
    }
    .padding()
    .background(Color(white: 0.07))
}
