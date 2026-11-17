import AppKit
import SwiftUI

// MARK: - Shared brand / status colors
//
// Single source for the brand & attention-dot colors shared across the menu bar,
// notch pill, popover header, and Session rows so no two surfaces can drift apart.
extension NSColor {
    /// Google Antigravity brand cosmic blue-indigo (#4F7CFF dark / #3B66F5 light).
    static let agyBrand = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0x4F / 255.0, green: 0x7C / 255.0, blue: 0xFF / 255.0, alpha: 1.0)
            : NSColor(srgbRed: 0x3B / 255.0, green: 0x66 / 255.0, blue: 0xF5 / 255.0, alpha: 1.0)
    }

    /// "A session is waiting for you" amber (#F2B45C).
    static let agyStatusWaiting = NSColor(srgbRed: 0.949, green: 0.706, blue: 0.361, alpha: 1.0)

    /// Compatibility aliases per shared contract.
    static var ccBrand: NSColor { agyBrand }
    static var ccStatusWaiting: NSColor { agyStatusWaiting }
}

extension Color {
    /// Antigravity brand cosmic blue-indigo (#4F7CFF dark / #3B66F5 light) — logo mark
    /// in the menu bar, compact notch pill, and popover header.
    static let agyBrand = Color(nsColor: .agyBrand)

    /// "A session is waiting for you" amber (#F2B45C) — status dot shared by Session
    /// rows and the logo's attention dot.
    static let agyStatusWaiting = Color(red: 0.949, green: 0.706, blue: 0.361)

    /// Compatibility aliases per shared contract.
    static var ccBrand: Color { agyBrand }
    static var ccStatusWaiting: Color { agyStatusWaiting }
}
