import AppKit
import SwiftUI

// MARK: - Shared brand / status colors
//
// Single source for the brand & attention-dot colors shared across the menu bar,
// notch pill, popover header, and Session rows so no two surfaces can drift apart.
extension NSColor {
    /// Google Antigravity brand cosmic blue-indigo (#4F7CFF dark / #2648FF light).
    static let agyBrand = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0x4F / 255.0, green: 0x7C / 255.0, blue: 0xFF / 255.0, alpha: 1.0)
            : NSColor(srgbRed: 0x26 / 255.0, green: 0x48 / 255.0, blue: 0xFF / 255.0, alpha: 1.0)
    }

    /// "A session is waiting for you" amber (#F5A623).
    static let agyStatusWaiting = NSColor(srgbRed: 0.961, green: 0.651, blue: 0.137, alpha: 1.0)

    /// Compatibility aliases per shared contract.
    static var ccBrand: NSColor { agyBrand }
    static var ccStatusWaiting: NSColor { agyStatusWaiting }
}

extension Color {
    /// Antigravity brand cosmic blue-indigo — logo mark in menu bar, notch pill, and header.
    static let agyBrand = Color(nsColor: .agyBrand)

    /// "A session is waiting for you" amber — status dot shared by Session rows and logo dot.
    static let agyStatusWaiting = Color(red: 0.961, green: 0.651, blue: 0.137)

    /// Compatibility aliases per shared contract.
    static var ccBrand: Color { agyBrand }
    static var ccStatusWaiting: Color { agyStatusWaiting }
}

// MARK: - Strata Visual Patterns (Vector Textures for Charts & Legend Swatches)

enum StrataPattern: Equatable {
    case solid
    case dense
    case diagonalHatch
    case stipple
    case horizontalHatch
    case outline
    case muted
}

// MARK: - AGY // TELEMETRY Two-Color Duotone & Studio Design System

/// Swiss Precision Telemetry palette supporting 7 curated studio instruments
/// (Monolith, Google Primary 4, plus 5 chromatic duotones) across Light, Dark, and Notch modes.
struct AGYTheme: Equatable {
    struct CacheKey: Hashable {
        let preset: TelemetryThemePreset
        let isDark: Bool
        let isNotch: Bool
    }

    static let panelWidth: CGFloat = 420
    static let cardRadius: CGFloat = 1.5
    static let controlRadius: CGFloat = 1.5

    let preset: TelemetryThemePreset
    let isDark: Bool
    let isNotch: Bool

    var cacheKey: CacheKey {
        CacheKey(preset: preset, isDark: isDark, isNotch: isNotch)
    }

    let canvas: Color
    let surface: Color
    let surfaceRaised: Color
    let hairline: Color
    let hairlineStrong: Color
    let reticle: Color
    let inkPrimary: Color
    let inkSecondary: Color
    let inkMuted: Color
    let accent: Color
    let accentSoft: Color
    let accentSecondary: Color
    let accentSecondarySoft: Color
    let accentTertiary: Color
    let accentQuaternary: Color
    let isMultiColorSpectrum: Bool
    let invertedBg: Color
    let invertedInk: Color

    let signalAmber: Color
    let signalRed: Color
    let signalGreen: Color

    init(preset: TelemetryThemePreset = .monolith, colorScheme: ColorScheme, isNotch: Bool = false) {
        self.preset = preset
        let dark = isNotch || (colorScheme == .dark)
        self.isDark = dark
        self.isNotch = isNotch

        switch (preset, dark) {
        // 1. Monolith — Cobalt × Slate-Steel (Swiss gallery default)
        case (.monolith, false):
            self.canvas = Color(red: 0.953, green: 0.949, blue: 0.933)         // #F3F2EE Archival Gallery Paper
            self.surface = Color(red: 0.929, green: 0.925, blue: 0.906)        // #EDECE7
            self.surfaceRaised = Color(red: 0.984, green: 0.980, blue: 0.969)  // #FBFAF7
            self.hairline = Color.black.opacity(0.105)
            self.hairlineStrong = Color.black.opacity(0.24)
            self.reticle = Color.black.opacity(0.36)
            self.inkPrimary = Color(red: 0.075, green: 0.082, blue: 0.098)     // #131519 Carbon Ink
            self.inkSecondary = Color(red: 0.341, green: 0.361, blue: 0.408)   // #575C68
            self.inkMuted = Color(red: 0.545, green: 0.561, blue: 0.600)       // #8B8F99
            self.accent = Color(red: 0.141, green: 0.275, blue: 1.000)         // #2446FF Electric Cobalt
            self.accentSecondary = Color(red: 0.294, green: 0.369, blue: 0.533) // #4B5E88 Drafting Steel-Blue
            self.invertedBg = Color(red: 0.075, green: 0.082, blue: 0.098)
            self.invertedInk = Color(red: 0.953, green: 0.949, blue: 0.933)

        case (.monolith, true):
            self.canvas = isNotch ? Color.black : Color(red: 0.024, green: 0.027, blue: 0.035) // #060709
            self.surface = isNotch ? Color.black : Color(red: 0.043, green: 0.051, blue: 0.067) // #0B0D11
            self.surfaceRaised = Color.white.opacity(0.065)
            self.hairline = Color.white.opacity(0.11)
            self.hairlineStrong = Color.white.opacity(0.24)
            self.reticle = Color.white.opacity(0.38)
            self.inkPrimary = Color(red: 0.937, green: 0.945, blue: 0.965)     // #EFF1F6
            self.inkSecondary = Color(red: 0.549, green: 0.580, blue: 0.651)   // #8C94A6
            self.inkMuted = Color(red: 0.337, green: 0.369, blue: 0.435)       // #565E6F
            self.accent = Color(red: 0.325, green: 0.506, blue: 1.000)         // #5381FF Electric Cobalt
            self.accentSecondary = Color(red: 0.541, green: 0.643, blue: 0.839) // #8AA4D6 Cool Steel-Blue
            self.invertedBg = Color(red: 0.937, green: 0.945, blue: 0.965)
            self.invertedInk = Color(red: 0.024, green: 0.027, blue: 0.035)

        // 2. Google — Primary 4 Spectrum (Google Blue × Red × Yellow × Green)
        case (.google, false):
            self.canvas = Color(red: 0.973, green: 0.976, blue: 0.980)         // #F8F9FA Google Studio Chalk
            self.surface = Color(red: 0.945, green: 0.953, blue: 0.957)        // #F1F3F4 Google Surface 100
            self.surfaceRaised = Color(red: 1.000, green: 1.000, blue: 1.000)  // #FFFFFF Crisp White
            self.hairline = Color(red: 0.125, green: 0.129, blue: 0.141).opacity(0.11)
            self.hairlineStrong = Color(red: 0.125, green: 0.129, blue: 0.141).opacity(0.24)
            self.reticle = Color(red: 0.918, green: 0.263, blue: 0.208).opacity(0.42) // Google Red ticks
            self.inkPrimary = Color(red: 0.125, green: 0.129, blue: 0.141)     // #202124 Google Grey 900
            self.inkSecondary = Color(red: 0.373, green: 0.388, blue: 0.408)   // #5F6368 Google Grey 700
            self.inkMuted = Color(red: 0.502, green: 0.525, blue: 0.545)       // #80868B Google Grey 600
            self.accent = Color(red: 0.102, green: 0.451, blue: 0.910)         // #1A73E8 Google Blue 600
            self.accentSecondary = Color(red: 0.918, green: 0.263, blue: 0.208) // #EA4335 Google Red 500
            self.invertedBg = Color(red: 0.125, green: 0.129, blue: 0.141)     // #202124
            self.invertedInk = Color(red: 0.973, green: 0.976, blue: 0.980)    // #F8F9FA

        case (.google, true):
            self.canvas = isNotch ? Color.black : Color(red: 0.067, green: 0.075, blue: 0.094) // #111318 Google Carbon Dark
            self.surface = isNotch ? Color.black : Color(red: 0.094, green: 0.106, blue: 0.133) // #181B22
            self.surfaceRaised = Color(red: 0.259, green: 0.522, blue: 0.957).opacity(0.105)
            self.hairline = Color(red: 0.910, green: 0.918, blue: 0.929).opacity(0.12)
            self.hairlineStrong = Color(red: 0.910, green: 0.918, blue: 0.929).opacity(0.26)
            self.reticle = Color(red: 0.984, green: 0.737, blue: 0.016).opacity(0.52) // Google Yellow ticks
            self.inkPrimary = Color(red: 0.910, green: 0.918, blue: 0.929)     // #E8EAED Google Grey 200
            self.inkSecondary = Color(red: 0.604, green: 0.627, blue: 0.651)   // #9AA0A6 Google Grey 500
            self.inkMuted = Color(red: 0.373, green: 0.388, blue: 0.408)       // #5F6368 Google Grey 700
            self.accent = Color(red: 0.259, green: 0.522, blue: 0.957)         // #4285F4 Canonical Google Blue
            self.accentSecondary = Color(red: 0.918, green: 0.263, blue: 0.208) // #EA4335 Canonical Google Red
            self.invertedBg = Color(red: 0.259, green: 0.522, blue: 0.957)     // #4285F4
            self.invertedInk = Color(red: 1.000, green: 1.000, blue: 1.000)    // #FFFFFF

        // 3. Blueprint — Polar Indigo × Signal Orange (Architectural Cyanotype + Drafting Pencil)
        case (.blueprint, false):
            self.canvas = Color(red: 0.902, green: 0.925, blue: 0.969)         // #E6ECF7 Cyanotype Paper
            self.surface = Color(red: 0.863, green: 0.894, blue: 0.957)        // #DCE4F4
            self.surfaceRaised = Color(red: 0.953, green: 0.965, blue: 0.992)  // #F3F6FD
            self.hairline = Color(red: 0.075, green: 0.106, blue: 0.329).opacity(0.14)
            self.hairlineStrong = Color(red: 0.075, green: 0.106, blue: 0.329).opacity(0.30)
            self.reticle = Color(red: 0.851, green: 0.282, blue: 0.059).opacity(0.48)
            self.inkPrimary = Color(red: 0.075, green: 0.106, blue: 0.329)     // #131B54 Deep Indigo Ink
            self.inkSecondary = Color(red: 0.231, green: 0.278, blue: 0.522)   // #3B4785
            self.inkMuted = Color(red: 0.431, green: 0.478, blue: 0.698)       // #6E7AB2
            self.accent = Color(red: 0.114, green: 0.235, blue: 0.949)         // #1D3CF2 Klein Cobalt
            self.accentSecondary = Color(red: 0.851, green: 0.282, blue: 0.059) // #D9480F Drafting Signal Orange
            self.invertedBg = Color(red: 0.075, green: 0.106, blue: 0.329)     // #131B54
            self.invertedInk = Color(red: 0.953, green: 0.965, blue: 0.992)    // #F3F6FD

        case (.blueprint, true):
            self.canvas = isNotch ? Color.black : Color(red: 0.078, green: 0.098, blue: 0.322) // #141952 Deep Polar Indigo
            self.surface = isNotch ? Color.black : Color(red: 0.106, green: 0.129, blue: 0.392) // #1B2164
            self.surfaceRaised = Color(red: 0.478, green: 0.608, blue: 1.000).opacity(0.11)
            self.hairline = Color(red: 0.478, green: 0.608, blue: 1.000).opacity(0.20)
            self.hairlineStrong = Color(red: 0.478, green: 0.608, blue: 1.000).opacity(0.38)
            self.reticle = Color(red: 1.000, green: 0.420, blue: 0.208).opacity(0.55)
            self.inkPrimary = Color(red: 0.945, green: 0.941, blue: 0.902)     // #F1F0E6 Archival Bone
            self.inkSecondary = Color(red: 0.659, green: 0.710, blue: 0.910)   // #A8B5E8
            self.inkMuted = Color(red: 0.447, green: 0.502, blue: 0.745)       // #7280BE
            self.accent = Color(red: 0.478, green: 0.608, blue: 1.000)         // #7A9BFF Luminous Cyanotype Blue
            self.accentSecondary = Color(red: 1.000, green: 0.420, blue: 0.208) // #FF6B35 Drafting Signal Orange
            self.invertedBg = Color(red: 0.945, green: 0.941, blue: 0.902)     // #F1F0E6
            self.invertedInk = Color(red: 0.078, green: 0.098, blue: 0.322)    // #141952

        // 3. Risograph — Fluorescent Pink × Federal Blue (Tokyo 2-Drum Overprint)
        case (.risograph, false):
            self.canvas = Color(red: 0.980, green: 0.957, blue: 0.925)         // #FAF4EC Warm Cream Riso Paper
            self.surface = Color(red: 0.949, green: 0.914, blue: 0.867)        // #F2E9DD
            self.surfaceRaised = Color(red: 1.000, green: 0.984, blue: 0.961)  // #FFFBF5
            self.hairline = Color(red: 0.106, green: 0.078, blue: 0.149).opacity(0.13)
            self.hairlineStrong = Color(red: 0.106, green: 0.078, blue: 0.149).opacity(0.28)
            self.reticle = Color(red: 0.118, green: 0.294, blue: 1.000).opacity(0.45)
            self.inkPrimary = Color(red: 0.106, green: 0.078, blue: 0.149)     // #1B1426 Deep Riso Ink
            self.inkSecondary = Color(red: 0.325, green: 0.275, blue: 0.408)   // #534668
            self.inkMuted = Color(red: 0.541, green: 0.486, blue: 0.620)       // #8A7C9E
            self.accent = Color(red: 0.863, green: 0.110, blue: 0.431)         // #DC1C6E Fluorescent Riso Pink
            self.accentSecondary = Color(red: 0.118, green: 0.294, blue: 1.000) // #1E4BFF Federal Cobalt Blue
            self.invertedBg = Color(red: 0.106, green: 0.078, blue: 0.149)     // #1B1426
            self.invertedInk = Color(red: 0.980, green: 0.957, blue: 0.925)    // #FAF4EC

        case (.risograph, true):
            self.canvas = isNotch ? Color.black : Color(red: 0.055, green: 0.039, blue: 0.094) // #0E0A18 Deep Ink-Plum Void
            self.surface = isNotch ? Color.black : Color(red: 0.086, green: 0.063, blue: 0.149) // #161026
            self.surfaceRaised = Color(red: 1.000, green: 0.200, blue: 0.545).opacity(0.10)
            self.hairline = Color(red: 0.980, green: 0.941, blue: 0.965).opacity(0.14)
            self.hairlineStrong = Color(red: 0.302, green: 0.545, blue: 1.000).opacity(0.34)
            self.reticle = Color(red: 0.302, green: 0.545, blue: 1.000).opacity(0.55)
            self.inkPrimary = Color(red: 0.980, green: 0.941, blue: 0.965)     // #FAF0F6 Warm Rose-White
            self.inkSecondary = Color(red: 0.722, green: 0.616, blue: 0.710)   // #B89DB5
            self.inkMuted = Color(red: 0.471, green: 0.380, blue: 0.482)       // #78617B
            self.accent = Color(red: 1.000, green: 0.200, blue: 0.545)         // #FF338B Fluorescent Pink
            self.accentSecondary = Color(red: 0.302, green: 0.545, blue: 1.000) // #4D8BFF Federal Electric Blue
            self.invertedBg = Color(red: 1.000, green: 0.200, blue: 0.545)     // #FF338B
            self.invertedInk = Color(red: 0.055, green: 0.039, blue: 0.094)    // #0E0A18

        // 4. Amber — Braun Amber × Petrol Teal (Dieter Rams Warm/Cool Duotone)
        case (.amber, false):
            self.canvas = Color(red: 0.961, green: 0.941, blue: 0.902)         // #F5F0E6 Warm Braun Paper
            self.surface = Color(red: 0.925, green: 0.898, blue: 0.847)        // #ECE5D8
            self.surfaceRaised = Color(red: 0.988, green: 0.976, blue: 0.949)  // #FCF9F2
            self.hairline = Color(red: 0.106, green: 0.086, blue: 0.067).opacity(0.13)
            self.hairlineStrong = Color(red: 0.106, green: 0.086, blue: 0.067).opacity(0.28)
            self.reticle = Color(red: 0.055, green: 0.463, blue: 0.478).opacity(0.46)
            self.inkPrimary = Color(red: 0.106, green: 0.086, blue: 0.067)     // #1B1611 Espresso Ink
            self.inkSecondary = Color(red: 0.376, green: 0.325, blue: 0.275)   // #605346
            self.inkMuted = Color(red: 0.573, green: 0.518, blue: 0.463)       // #928476
            self.accent = Color(red: 0.784, green: 0.314, blue: 0.063)         // #C85010 Burnt Braun Orange
            self.accentSecondary = Color(red: 0.055, green: 0.463, blue: 0.478) // #0E767A Deep Petrol Teal
            self.invertedBg = Color(red: 0.106, green: 0.086, blue: 0.067)     // #1B1611
            self.invertedInk = Color(red: 0.961, green: 0.941, blue: 0.902)    // #F5F0E6

        case (.amber, true):
            self.canvas = isNotch ? Color.black : Color(red: 0.047, green: 0.039, blue: 0.031) // #0C0A08 Warm CRT Charcoal
            self.surface = isNotch ? Color.black : Color(red: 0.082, green: 0.071, blue: 0.055) // #15120E
            self.surfaceRaised = Color(red: 0.961, green: 0.651, blue: 0.137).opacity(0.10)
            self.hairline = Color(red: 0.961, green: 0.925, blue: 0.863).opacity(0.13)
            self.hairlineStrong = Color(red: 0.961, green: 0.651, blue: 0.137).opacity(0.32)
            self.reticle = Color(red: 0.176, green: 0.831, blue: 0.749).opacity(0.52)
            self.inkPrimary = Color(red: 0.961, green: 0.925, blue: 0.863)     // #F5ECDC Warm Cream
            self.inkSecondary = Color(red: 0.702, green: 0.612, blue: 0.494)   // #B39C7E
            self.inkMuted = Color(red: 0.447, green: 0.373, blue: 0.282)       // #725F48
            self.accent = Color(red: 0.961, green: 0.651, blue: 0.137)         // #F5A623 Phosphor Amber
            self.accentSecondary = Color(red: 0.176, green: 0.831, blue: 0.749) // #2DD4BF Luminous Petrol Teal
            self.invertedBg = Color(red: 0.961, green: 0.651, blue: 0.137)     // #F5A623
            self.invertedInk = Color(red: 0.047, green: 0.039, blue: 0.031)    // #0C0A08

        // 5. Racing — British Racing Emerald × Burnished Gold (Heritage Chronograph)
        case (.racing, false):
            self.canvas = Color(red: 0.925, green: 0.949, blue: 0.929)         // #ECF2ED Heritage Sage Paper
            self.surface = Color(red: 0.882, green: 0.918, blue: 0.890)        // #E1EAE3
            self.surfaceRaised = Color(red: 0.965, green: 0.980, blue: 0.969)  // #F6FAF7
            self.hairline = Color(red: 0.051, green: 0.141, blue: 0.106).opacity(0.13)
            self.hairlineStrong = Color(red: 0.051, green: 0.141, blue: 0.106).opacity(0.28)
            self.reticle = Color(red: 0.702, green: 0.455, blue: 0.000).opacity(0.48)
            self.inkPrimary = Color(red: 0.051, green: 0.141, blue: 0.106)     // #0D241B Deep Pine Ink
            self.inkSecondary = Color(red: 0.196, green: 0.341, blue: 0.278)   // #325747
            self.inkMuted = Color(red: 0.376, green: 0.518, blue: 0.455)       // #608474
            self.accent = Color(red: 0.047, green: 0.451, blue: 0.294)         // #0C734B British Racing Emerald
            self.accentSecondary = Color(red: 0.702, green: 0.455, blue: 0.000) // #B37400 Burnished Brass Gold
            self.invertedBg = Color(red: 0.051, green: 0.141, blue: 0.106)     // #0D241B
            self.invertedInk = Color(red: 0.925, green: 0.949, blue: 0.929)    // #ECF2ED

        case (.racing, true):
            self.canvas = isNotch ? Color.black : Color(red: 0.031, green: 0.090, blue: 0.067) // #081711 Deep British Racing Green
            self.surface = isNotch ? Color.black : Color(red: 0.055, green: 0.141, blue: 0.106) // #0E241B
            self.surfaceRaised = Color(red: 0.176, green: 0.831, blue: 0.533).opacity(0.095)
            self.hairline = Color(red: 0.925, green: 0.961, blue: 0.933).opacity(0.14)
            self.hairlineStrong = Color(red: 0.949, green: 0.718, blue: 0.251).opacity(0.34)
            self.reticle = Color(red: 0.949, green: 0.718, blue: 0.251).opacity(0.54)
            self.inkPrimary = Color(red: 0.925, green: 0.961, blue: 0.933)     // #ECF5EE Warm Ivory-Mint
            self.inkSecondary = Color(red: 0.545, green: 0.702, blue: 0.612)   // #8BB39C
            self.inkMuted = Color(red: 0.310, green: 0.459, blue: 0.376)       // #4F7560
            self.accent = Color(red: 0.176, green: 0.831, blue: 0.533)         // #2DD488 Racing Emerald
            self.accentSecondary = Color(red: 0.949, green: 0.718, blue: 0.251) // #F2B740 Burnished Chronograph Gold
            self.invertedBg = Color(red: 0.949, green: 0.718, blue: 0.251)     // #F2B740
            self.invertedInk = Color(red: 0.031, green: 0.090, blue: 0.067)    // #081711

        // 6. Volt — Acid Volt × Electric Ultraviolet (High-Visibility Telemetry)
        case (.volt, false):
            self.canvas = Color(red: 0.949, green: 0.957, blue: 0.973)         // #F2F4F8 Cool Technical Chalk
            self.surface = Color(red: 0.906, green: 0.918, blue: 0.949)        // #E7EAF2
            self.surfaceRaised = Color(red: 0.980, green: 0.984, blue: 0.992)  // #FAFBFD
            self.hairline = Color(red: 0.075, green: 0.086, blue: 0.122).opacity(0.12)
            self.hairlineStrong = Color(red: 0.075, green: 0.086, blue: 0.122).opacity(0.28)
            self.reticle = Color(red: 0.427, green: 0.157, blue: 0.851).opacity(0.46)
            self.inkPrimary = Color(red: 0.075, green: 0.086, blue: 0.122)     // #13161F Graphite Ink
            self.inkSecondary = Color(red: 0.278, green: 0.302, blue: 0.380)   // #474D61
            self.inkMuted = Color(red: 0.482, green: 0.506, blue: 0.588)       // #7B8196
            self.accent = Color(red: 0.247, green: 0.431, blue: 0.000)         // #3F6E00 High-Contrast Acid Moss
            self.accentSecondary = Color(red: 0.427, green: 0.157, blue: 0.851) // #6D28D9 Deep Ultraviolet
            self.invertedBg = Color(red: 0.075, green: 0.086, blue: 0.122)     // #13161F
            self.invertedInk = Color(red: 0.949, green: 0.957, blue: 0.973)    // #F2F4F8

        case (.volt, true):
            self.canvas = isNotch ? Color.black : Color(red: 0.031, green: 0.024, blue: 0.059) // #08060F Ultraviolet Obsidian
            self.surface = isNotch ? Color.black : Color(red: 0.067, green: 0.051, blue: 0.118) // #110D1E
            self.surfaceRaised = Color(red: 0.702, green: 0.420, blue: 1.000).opacity(0.11)
            self.hairline = Color(red: 0.953, green: 0.965, blue: 0.918).opacity(0.13)
            self.hairlineStrong = Color(red: 0.702, green: 0.420, blue: 1.000).opacity(0.34)
            self.reticle = Color(red: 0.702, green: 0.420, blue: 1.000).opacity(0.55)
            self.inkPrimary = Color(red: 0.953, green: 0.965, blue: 0.918)     // #F3F6EA Crisp Ivory
            self.inkSecondary = Color(red: 0.639, green: 0.620, blue: 0.722)   // #A39EB8
            self.inkMuted = Color(red: 0.400, green: 0.376, blue: 0.482)       // #66607B
            self.accent = Color(red: 0.784, green: 1.000, blue: 0.000)         // #C8FF00 Acid Volt Chartreuse
            self.accentSecondary = Color(red: 0.702, green: 0.420, blue: 1.000) // #B36BFF Electric Ultraviolet
            self.invertedBg = Color(red: 0.784, green: 1.000, blue: 0.000)     // #C8FF00
            self.invertedInk = Color(red: 0.031, green: 0.024, blue: 0.059)    // #08060F
        }

        self.accentSoft = self.accent.opacity(dark ? 0.16 : 0.10)
        self.accentSecondarySoft = self.accentSecondary.opacity(dark ? 0.16 : 0.10)
        if preset == .google {
            self.isMultiColorSpectrum = true
            self.accentTertiary = dark
                ? Color(red: 0.984, green: 0.737, blue: 0.016) // #FBBC04 Canonical Google Yellow
                : Color(red: 0.922, green: 0.620, blue: 0.000) // #EB9E00 Crisp Light-Paper Google Yellow
            self.accentQuaternary = dark
                ? Color(red: 0.204, green: 0.659, blue: 0.325) // #34A853 Canonical Google Green
                : Color(red: 0.094, green: 0.502, blue: 0.220) // #188038 Google Green 700
            self.signalAmber = self.accentTertiary
            self.signalRed = dark
                ? Color(red: 0.918, green: 0.263, blue: 0.208) // #EA4335 Google Red
                : Color(red: 0.851, green: 0.188, blue: 0.145) // #D93025 Google Red 600
            self.signalGreen = self.accentQuaternary
        } else {
            self.isMultiColorSpectrum = false
            self.accentTertiary = self.accentSecondary
            self.accentQuaternary = self.accent
            self.signalAmber = dark
                ? Color(red: 0.961, green: 0.651, blue: 0.137)
                : Color(red: 0.855, green: 0.520, blue: 0.020)
            self.signalRed = dark
                ? Color(red: 1.000, green: 0.302, blue: 0.310)
                : Color(red: 0.870, green: 0.215, blue: 0.225)
            self.signalGreen = dark
                ? Color(red: 0.184, green: 0.831, blue: 0.478)
                : Color(red: 0.085, green: 0.640, blue: 0.340)
        }
    }

    // MARK: Multi-Color Spectrum Helpers (Google 4-Color vs Duotone)

    /// Cycles the 4 canonical spectrum accents (Blue · Red · Yellow · Green) on multi-color themes;
    /// falls back to the primary/secondary duotone pair on 2-color themes.
    func spectrumAccent(index: Int) -> Color {
        guard isMultiColorSpectrum else {
            return (index == 0) ? accent : accentSecondary
        }
        switch ((index % 4) + 4) % 4 {
        case 0: return accent            // Google Blue
        case 1: return accentSecondary   // Google Red
        case 2: return accentTertiary    // Google Yellow
        default: return accentQuaternary // Google Green
        }
    }

    /// Maps normalized elevation / intensity (`0...1`) into a 4-stage spectrum
    /// (Green valleys -> Yellow slopes -> Red ridges -> Blue summit) on multi-color themes,
    /// or a 2-stage duotone transition on 2-color themes.
    func elevationColor(normalized: Double) -> Color {
        guard isMultiColorSpectrum else {
            return normalized < 0.55 ? accentSecondary : accent
        }
        switch normalized {
        case ..<0.28:       return accentQuaternary // Green base
        case 0.28..<0.54:   return accentTertiary   // Yellow mid-low
        case 0.54..<0.78:   return accentSecondary  // Red mid-high
        default:            return accent           // Blue summit
        }
    }

    /// Destination channel color for the Folded Token Stream (02 TOK).
    func tokenChannelColor(_ channel: TokenChannel) -> Color {
        guard isMultiColorSpectrum else { return accentSecondary }
        switch channel {
        case .cacheRead:  return accentQuaternary // Google Green (cache efficiency)
        case .input:      return accentTertiary   // Google Yellow (prompt fuel)
        case .output:     return accentSecondary  // Google Red (model output)
        case .cacheWrite: return accent           // Google Blue
        }
    }

    /// Tab bar accent color: 4-color cadence on Google (01 Blue · 02 Red · 03 Yellow · 04 Green · 05 Blue),
    /// classic single active accent on all other presets.
    func tabAccent(index: Int) -> Color {
        guard isMultiColorSpectrum else { return accent }
        return spectrumAccent(index: index)
    }

    // MARK: Model Color & Pattern Engine

    func modelColor(_ mc: ModelClass, focused: Bool = false, anyFocused: Bool = false) -> Color {
        if anyFocused {
            return focused ? accent : inkMuted.opacity(isDark ? 0.32 : 0.25)
        }
        switch preset {
        case .monolith:
            // Monochrome lithology ramp + Electric Cobalt focal accent on .carbon
            switch mc {
            case .carbon:   return accent
            case .argon:    return inkPrimary.opacity(0.82)
            case .neon:     return inkPrimary.opacity(0.62)
            case .hydrogen: return inkPrimary.opacity(0.48)
            case .flash:    return inkPrimary.opacity(0.36)
            case .claude:   return inkPrimary.opacity(0.72)
            case .other:    return inkMuted.opacity(0.48)
            }
        case .google:
            // Canonical Google 4-color identity across the model strata:
            // Blue (.carbon / .hydrogen), Red (.claude), Yellow (.neon), Green (.argon / .flash).
            switch mc {
            case .carbon:
                return accent // #1A73E8 light / #4285F4 dark
            case .claude:
                return accentSecondary // #EA4335 Google Red
            case .neon:
                return isDark
                    ? Color(red: 0.984, green: 0.737, blue: 0.016) // #FBBC04 Google Yellow
                    : Color(red: 0.949, green: 0.600, blue: 0.000) // #F29900 Google Yellow 600
            case .argon:
                return isDark
                    ? Color(red: 0.204, green: 0.659, blue: 0.325) // #34A853 Google Green
                    : Color(red: 0.094, green: 0.502, blue: 0.220) // #188038 Google Green 700
            case .hydrogen:
                return isDark
                    ? Color(red: 0.541, green: 0.706, blue: 0.973) // #8AB4F8 Google Blue 300
                    : Color(red: 0.259, green: 0.522, blue: 0.957) // #4285F4 Google Blue 500
            case .flash:
                return isDark
                    ? Color(red: 0.506, green: 0.788, blue: 0.584) // #81C995 Google Green 300
                    : Color(red: 0.204, green: 0.659, blue: 0.325) // #34A853 Google Green 500
            case .other:
                return inkMuted.opacity(0.68)
            }
        case .blueprint, .risograph, .amber, .racing, .volt:
            // Two-color duotone ramp: primary Gemini models in Color 1 (accent),
            // counter-group (.claude, .hydrogen, .flash) in Color 2 (accentSecondary).
            switch mc {
            case .carbon:   return accent
            case .argon:    return accent.opacity(0.76)
            case .neon:     return accent.opacity(0.56)
            case .claude:   return accentSecondary
            case .hydrogen: return accentSecondary.opacity(0.78)
            case .flash:    return accentSecondary.opacity(0.58)
            case .other:    return inkMuted.opacity(0.55)
            }
        }
    }

    func modelColor(_ id: String?, focused: Bool = false, anyFocused: Bool = false) -> Color {
        guard let raw = id, !raw.isEmpty else {
            return modelColor(.other, focused: focused, anyFocused: anyFocused)
        }
        let mc = ModelClass(rawValue: raw.lowercased()) ?? ModelClass.classify(raw)
        return modelColor(mc, focused: focused, anyFocused: anyFocused)
    }

    func modelPattern(_ mc: ModelClass) -> StrataPattern {
        guard preset.usesMonochromeStrata else { return .solid }
        switch mc {
        case .carbon:   return .solid
        case .argon:    return .dense
        case .neon:     return .diagonalHatch
        case .hydrogen: return .stipple
        case .flash:    return .muted
        case .claude:   return .horizontalHatch
        case .other:    return .outline
        }
    }

    func heatmapColor(level: Int) -> Color {
        guard (1...4).contains(level) else {
            return hairline.opacity(isDark ? 0.90 : 0.85)
        }
        switch (preset, isDark) {
        case (.monolith, false):
            let ramp: [Color] = [
                Color(red: 0.84, green: 0.88, blue: 1.00),
                Color(red: 0.58, green: 0.69, blue: 1.00),
                Color(red: 0.28, green: 0.46, blue: 1.00),
                Color(red: 0.10, green: 0.24, blue: 0.82),
            ]
            return ramp[level - 1]
        case (.monolith, true):
            let ramp: [Color] = [
                Color(red: 0.08, green: 0.14, blue: 0.30),
                Color(red: 0.14, green: 0.27, blue: 0.62),
                Color(red: 0.25, green: 0.46, blue: 0.98),
                Color(red: 0.50, green: 0.68, blue: 1.00),
            ]
            return ramp[level - 1]

        // Google 4-color spectrum: Green -> Yellow -> Red -> Blue (Light) / Green -> Red -> Blue -> Yellow (Dark)
        case (.google, false):
            let ramp: [Color] = [
                Color(red: 0.808, green: 0.918, blue: 0.839), // #CEEAD6 Google Green 100
                Color(red: 0.984, green: 0.737, blue: 0.016), // #FBBC04 Google Yellow 500
                Color(red: 0.918, green: 0.263, blue: 0.208), // #EA4335 Google Red 500
                Color(red: 0.102, green: 0.451, blue: 0.910), // #1A73E8 Google Blue 600
            ]
            return ramp[level - 1]
        case (.google, true):
            let ramp: [Color] = [
                Color(red: 0.106, green: 0.302, blue: 0.180), // #1B4D2E Deep Google Green
                Color(red: 0.702, green: 0.196, blue: 0.149), // #B33226 Rich Google Red
                Color(red: 0.259, green: 0.522, blue: 0.957), // #4285F4 Canonical Google Blue
                Color(red: 0.984, green: 0.737, blue: 0.016), // #FBBC04 Luminous Google Yellow
            ]
            return ramp[level - 1]

        // Duotone transition: Signal Orange (L1–L2) -> Cyanotype Cobalt (L3–L4)
        case (.blueprint, false):
            let ramp: [Color] = [
                Color(red: 0.949, green: 0.776, blue: 0.690), // #F2C6B0
                Color(red: 0.898, green: 0.478, blue: 0.267), // #E57A44
                Color(red: 0.322, green: 0.439, blue: 0.980), // #5270FA
                Color(red: 0.086, green: 0.184, blue: 0.831), // #162FD4
            ]
            return ramp[level - 1]
        case (.blueprint, true):
            let ramp: [Color] = [
                Color(red: 0.302, green: 0.133, blue: 0.078), // #4D2214
                Color(red: 0.788, green: 0.302, blue: 0.125), // #C94D20
                Color(red: 0.275, green: 0.416, blue: 0.902), // #466AE6
                Color(red: 0.549, green: 0.667, blue: 1.000), // #8CAAFF
            ]
            return ramp[level - 1]

        // Duotone transition: Federal Blue (L1–L2) -> Fluorescent Pink (L3–L4)
        case (.risograph, false):
            let ramp: [Color] = [
                Color(red: 0.769, green: 0.824, blue: 0.980), // #C4D2FA
                Color(red: 0.329, green: 0.471, blue: 0.980), // #5478FA
                Color(red: 0.910, green: 0.302, blue: 0.557), // #E84D8E
                Color(red: 0.769, green: 0.063, blue: 0.365), // #C4105D
            ]
            return ramp[level - 1]
        case (.risograph, true):
            let ramp: [Color] = [
                Color(red: 0.078, green: 0.149, blue: 0.322), // #142652
                Color(red: 0.180, green: 0.357, blue: 0.839), // #2E5BD6
                Color(red: 0.788, green: 0.141, blue: 0.431), // #C9246E
                Color(red: 1.000, green: 0.278, blue: 0.592), // #FF4797
            ]
            return ramp[level - 1]

        // Duotone transition: Petrol Teal (L1–L2) -> Braun Amber (L3–L4)
        case (.amber, false):
            let ramp: [Color] = [
                Color(red: 0.725, green: 0.867, blue: 0.851), // #B9DDD9
                Color(red: 0.231, green: 0.604, blue: 0.612), // #3B9A9C
                Color(red: 0.875, green: 0.463, blue: 0.200), // #DF7633
                Color(red: 0.710, green: 0.263, blue: 0.031), // #B54308
            ]
            return ramp[level - 1]
        case (.amber, true):
            let ramp: [Color] = [
                Color(red: 0.051, green: 0.220, blue: 0.204), // #0D3834
                Color(red: 0.114, green: 0.541, blue: 0.494), // #1D8A7E
                Color(red: 0.761, green: 0.478, blue: 0.078), // #C27A14
                Color(red: 1.000, green: 0.710, blue: 0.212), // #FFB536
            ]
            return ramp[level - 1]

        // Duotone transition: Burnished Gold (L1–L2) -> British Racing Emerald (L3–L4)
        case (.racing, false):
            let ramp: [Color] = [
                Color(red: 0.902, green: 0.827, blue: 0.639), // #E6D3A3
                Color(red: 0.788, green: 0.565, blue: 0.141), // #C99024
                Color(red: 0.169, green: 0.580, blue: 0.408), // #2B9468
                Color(red: 0.031, green: 0.361, blue: 0.227), // #085C3A
            ]
            return ramp[level - 1]
        case (.racing, true):
            let ramp: [Color] = [
                Color(red: 0.239, green: 0.180, blue: 0.055), // #3D2E0E
                Color(red: 0.659, green: 0.482, blue: 0.118), // #A87B1E
                Color(red: 0.102, green: 0.580, blue: 0.365), // #1A945D
                Color(red: 0.220, green: 0.878, blue: 0.580), // #38E094
            ]
            return ramp[level - 1]

        // Duotone transition: Ultraviolet (L1–L2) -> Acid Volt (L3–L4)
        case (.volt, false):
            let ramp: [Color] = [
                Color(red: 0.843, green: 0.780, blue: 0.980), // #D7C7FA
                Color(red: 0.553, green: 0.357, blue: 0.941), // #8D5BF0
                Color(red: 0.392, green: 0.620, blue: 0.071), // #649E12
                Color(red: 0.224, green: 0.388, blue: 0.000), // #396300
            ]
            return ramp[level - 1]
        case (.volt, true):
            let ramp: [Color] = [
                Color(red: 0.176, green: 0.090, blue: 0.302), // #2D174D
                Color(red: 0.478, green: 0.243, blue: 0.839), // #7A3ED6
                Color(red: 0.518, green: 0.722, blue: 0.000), // #84B800
                Color(red: 0.784, green: 1.000, blue: 0.000), // #C8FF00
            ]
            return ramp[level - 1]
        }
    }
}

private struct AGYThemeKey: EnvironmentKey {
    static let defaultValue = AGYTheme(preset: .monolith, colorScheme: .light, isNotch: false)
}

private struct TelemetryStaticRenderKey: EnvironmentKey {
    static let defaultValue = false
}

private struct TelemetryPanelVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var agyTheme: AGYTheme {
        get { self[AGYThemeKey.self] }
        set { self[AGYThemeKey.self] = newValue }
    }

    var telemetryStaticRender: Bool {
        get { self[TelemetryStaticRenderKey.self] }
        set { self[TelemetryStaticRenderKey.self] = newValue }
    }

    var telemetryPanelVisible: Bool {
        get { self[TelemetryPanelVisibleKey.self] }
        set { self[TelemetryPanelVisibleKey.self] = newValue }
    }
}
