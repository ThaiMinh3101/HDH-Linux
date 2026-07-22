import SwiftUI

/// Phân loại engine của game RPG Maker
enum GameEngine: String, Codable, CaseIterable {
    case rgssXP     = "rgssXP"
    case rgssVX     = "rgssVX"
    case rgssVXAce  = "rgssVXAce"
    case mv         = "mv"
    case mz         = "mz"
    case unknown    = "unknown"

    /// Tên hiển thị ngắn trên badge
    var displayName: String {
        switch self {
        case .rgssXP:    return "XP"
        case .rgssVX:    return "VX"
        case .rgssVXAce: return "VX Ace"
        case .mv:        return "MV"
        case .mz:        return "MZ"
        case .unknown:   return "???"
        }
    }

    /// Màu badge riêng cho từng engine
    var badgeColor: Color {
        switch self {
        case .rgssXP:    return Color(hue: 0.02, saturation: 0.75, brightness: 0.85) // đỏ cam
        case .rgssVX:    return Color(hue: 0.58, saturation: 0.70, brightness: 0.85) // xanh dương
        case .rgssVXAce: return Color(hue: 0.55, saturation: 0.65, brightness: 0.80) // cyan tối
        case .mv:        return Color(hue: 0.28, saturation: 0.70, brightness: 0.75) // xanh lá
        case .mz:        return Color(hue: 0.75, saturation: 0.65, brightness: 0.85) // tím
        case .unknown:   return Color(white: 0.4)
        }
    }

    /// Mô tả đầy đủ cho tooltip / GameDetailView
    var fullDescription: String {
        switch self {
        case .rgssXP:    return "RPG Maker XP (RGSS1)"
        case .rgssVX:    return "RPG Maker VX (RGSS2)"
        case .rgssVXAce: return "RPG Maker VX Ace (RGSS3)"
        case .mv:        return "RPG Maker MV"
        case .mz:        return "RPG Maker MZ"
        case .unknown:   return "Không nhận dạng được"
        }
    }
}

/// Metadata của 1 game đã import vào thư viện
struct GameEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var engine: GameEngine
    var importDate: Date
    /// Đường dẫn thư mục game tương đối với Application Support/RPGPlayer/
    /// Ví dụ: "Games/3F2A1C.../"
    var relativeSandboxPath: String
    /// Đường dẫn thumbnail tương đối (nil = dùng placeholder)
    var relativeThumbnailPath: String?
    /// Dung lượng file tính bằng byte (update khi import)
    var sizeBytes: Int64

    init(
        id: UUID = UUID(),
        name: String,
        engine: GameEngine,
        importDate: Date = Date(),
        relativeSandboxPath: String,
        relativeThumbnailPath: String? = nil,
        sizeBytes: Int64 = 0
    ) {
        self.id = id
        self.name = name
        self.engine = engine
        self.importDate = importDate
        self.relativeSandboxPath = relativeSandboxPath
        self.relativeThumbnailPath = relativeThumbnailPath
        self.sizeBytes = sizeBytes
    }
}
