import SwiftUI

/// Thẻ game hiển thị trong lưới Library.
/// Thiết kế: glassmorphism tối, thumbnail + badge engine + tên game.
struct GameCardView: View {

    let entry: GameEntry
    var onDelete: (() -> Void)? = nil

    // Thumbnail từ sandbox (nil nếu không có)
    private var thumbnailImage: Image? {
        guard let rel = entry.relativeThumbnailPath else { return nil }
        let url = StorageManager.shared.absoluteURL(fromRelative: rel)
        guard FileManager.default.fileExists(atPath: url.path),
              let uiImage = UIImage(contentsOfFile: url.path) else { return nil }
        return Image(uiImage: uiImage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // MARK: Thumbnail / Placeholder
            ZStack(alignment: .topTrailing) {
                thumbnailArea
                engineBadge
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
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
        .contextMenu {
            Button(role: .destructive) {
                onDelete?()
            } label: {
                Label("Xoá game", systemImage: "trash")
            }
        }
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
