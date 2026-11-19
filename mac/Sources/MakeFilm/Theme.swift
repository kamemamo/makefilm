import SwiftUI
import AppKit

enum Theme {
    static let bg = Color(hex: 0x171B18)
    static let panel = Color(hex: 0x20261F)
    static let panel2 = Color(hex: 0x2A3129)
    static let line = Color(hex: 0x38423A)
    static let text = Color(hex: 0xE8E4D6)
    static let muted = Color(hex: 0x98A092)
    static let accent = Color(hex: 0xE3A548)
    static let accentInk = Color(hex: 0x1D1406)
    static let grease = Color(hex: 0xF6EEB4)
    static let film = Color(hex: 0x2B1A0D)
    static let hole = Color(hex: 0x0F110F)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

extension CGColor {
    static func hex(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }
}

enum TC {
    /// HH:MM:SS:FF (non-drop) at the given frame rate.
    static func string(_ seconds: Double, fps: Double) -> String {
        let r = max(1, Int(fps.rounded()))
        let f = Int((max(seconds, 0) * Double(r) + 1e-6).rounded(.down))
        let ff = f % r, ss = (f / r) % 60, mm = (f / r / 60) % 60, hh = f / r / 3600
        return String(format: "%02d:%02d:%02d:%02d", hh, mm, ss, ff)
    }

    /// 35mm footage: 16 frames per foot at 24 fps.
    static func feet(_ seconds: Double) -> String {
        let fr = Int((max(seconds, 0) * 24 + 1e-6).rounded(.down))
        return String(format: "%d+%02d", fr / 16, fr % 16)
    }
}

/// Version from Info.plist (nil when running unbundled via `swift run`).
enum AppVersion {
    static var short: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
    static var build: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String }
    static var full: String { "MakeFilm \(short ?? "dev") (\(build ?? "-"))" }
}
