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

// MARK: - AGY // TELEMETRY Multi-Theme Design System

/// Swiss Precision Telemetry palette supporting 4 distinct studio instruments
/// across Light (Swiss Paper) and Dark / Notch (Void Instrument) modes.
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
            self.accent = Color(red: 0.325, green: 0.506, blue: 1.000)         // #5381FF
            self.invertedBg = Color(red: 0.937, green: 0.945, blue: 0.965)
            self.invertedInk = Color(red: 0.024, green: 0.027, blue: 0.035)

        case (.blueprint, false):
            self.canvas = Color(red: 0.898, green: 0.918, blue: 0.961)         // #E5EAF5 Archival Cyanotype
            self.surface = Color(red: 0.859, green: 0.886, blue: 0.945)        // #DBE2F1
            self.surfaceRaised = Color(red: 0.949, green: 0.961, blue: 0.992)  // #F2F5FD
            self.hairline = Color(red: 0.110, green: 0.149, blue: 0.439).opacity(0.14)
            self.hairlineStrong = Color(red: 0.110, green: 0.149, blue: 0.439).opacity(0.32)
            self.reticle = Color(red: 0.141, green: 0.243, blue: 0.863).opacity(0.45)
            self.inkPrimary = Color(red: 0.086, green: 0.118, blue: 0.369)     // #161E5E
            self.inkSecondary = Color(red: 0.255, green: 0.302, blue: 0.549)   // #414D8C
            self.inkMuted = Color(red: 0.467, green: 0.514, blue: 0.722)       // #7783B8
            self.accent = Color(red: 0.141, green: 0.255, blue: 0.941)         // #2441F0
            self.invertedBg = Color(red: 0.086, green: 0.118, blue: 0.369)
            self.invertedInk = Color(red: 0.949, green: 0.961, blue: 0.992)

        case (.blueprint, true):
            self.canvas = isNotch ? Color.black : Color(red: 0.118, green: 0.125, blue: 0.427) // #1E206D Deep Polar Indigo
            self.surface = isNotch ? Color(red: 0.039, green: 0.047, blue: 0.180) : Color(red: 0.145, green: 0.157, blue: 0.494)
            self.surfaceRaised = Color(red: 0.886, green: 0.910, blue: 1.000).opacity(0.10)
            self.hairline = Color(red: 0.765, green: 0.816, blue: 1.000).opacity(0.18)
            self.hairlineStrong = Color(red: 0.824, green: 0.867, blue: 1.000).opacity(0.36)
            self.reticle = Color(red: 0.863, green: 0.898, blue: 1.000).opacity(0.55)
            self.inkPrimary = Color(red: 0.933, green: 0.945, blue: 0.992)     // #EEF1FD
            self.inkSecondary = Color(red: 0.678, green: 0.718, blue: 0.914)   // #ADB7E9
            self.inkMuted = Color(red: 0.478, green: 0.522, blue: 0.769)       // #7A85C4
            self.accent = Color(red: 0.945, green: 0.941, blue: 0.902)         // #F1F0E6 Archival Bone Highlight
            self.invertedBg = Color(red: 0.945, green: 0.941, blue: 0.902)     // #F1F0E6
            self.invertedInk = Color(red: 0.118, green: 0.125, blue: 0.427)    // #1E206D

        case (.phosphor, false):
            self.canvas = Color(red: 0.953, green: 0.965, blue: 0.976)         // #F3F6F9 Cold Technical Paper
            self.surface = Color(red: 0.922, green: 0.941, blue: 0.961)        // #EBF0F5
            self.surfaceRaised = Color.white
            self.hairline = Color(red: 0.051, green: 0.094, blue: 0.161).opacity(0.12)
            self.hairlineStrong = Color(red: 0.051, green: 0.094, blue: 0.161).opacity(0.28)
            self.reticle = Color(red: 0.000, green: 0.400, blue: 1.000).opacity(0.45)
            self.inkPrimary = Color(red: 0.051, green: 0.078, blue: 0.125)     // #0D1420
            self.inkSecondary = Color(red: 0.306, green: 0.357, blue: 0.431)   // #4E5B6E
            self.inkMuted = Color(red: 0.510, green: 0.565, blue: 0.639)       // #8290A3
            self.accent = Color(red: 0.000, green: 0.400, blue: 1.000)         // #0066FF
            self.invertedBg = Color(red: 0.051, green: 0.078, blue: 0.125)
            self.invertedInk = Color(red: 0.953, green: 0.965, blue: 0.976)

        case (.phosphor, true):
            self.canvas = Color.black                                          // #000000 Pure Void
            self.surface = isNotch ? Color.black : Color(red: 0.020, green: 0.031, blue: 0.051) // #05080D
            self.surfaceRaised = Color(red: 0.271, green: 0.769, blue: 1.000).opacity(0.10)
            self.hairline = Color(red: 0.659, green: 0.847, blue: 1.000).opacity(0.13)
            self.hairlineStrong = Color(red: 0.659, green: 0.847, blue: 1.000).opacity(0.30)
            self.reticle = Color(red: 0.271, green: 0.769, blue: 1.000).opacity(0.52)
            self.inkPrimary = Color(red: 0.918, green: 0.957, blue: 1.000)     // #EAF4FF
            self.inkSecondary = Color(red: 0.498, green: 0.627, blue: 0.745)   // #7FA0BE
            self.inkMuted = Color(red: 0.282, green: 0.376, blue: 0.471)       // #486078
            self.accent = Color(red: 0.271, green: 0.769, blue: 1.000)         // #45C4FF Ice Cyan
            self.invertedBg = Color(red: 0.918, green: 0.957, blue: 1.000)
            self.invertedInk = Color.black

        case (.amber, false):
            self.canvas = Color(red: 0.961, green: 0.945, blue: 0.910)         // #F5F1E8 Braun Warm Paper
            self.surface = Color(red: 0.929, green: 0.910, blue: 0.863)        // #EDE8DC
            self.surfaceRaised = Color(red: 0.988, green: 0.976, blue: 0.949)  // #FCF9F2
            self.hairline = Color(red: 0.141, green: 0.110, blue: 0.078).opacity(0.14)
            self.hairlineStrong = Color(red: 0.141, green: 0.110, blue: 0.078).opacity(0.32)
            self.reticle = Color(red: 0.784, green: 0.314, blue: 0.063).opacity(0.48)
            self.inkPrimary = Color(red: 0.110, green: 0.086, blue: 0.063)     // #1C1610
            self.inkSecondary = Color(red: 0.388, green: 0.333, blue: 0.278)   // #635547
            self.inkMuted = Color(red: 0.580, green: 0.525, blue: 0.471)       // #948678
            self.accent = Color(red: 0.784, green: 0.314, blue: 0.063)         // #C85010 Burnt Signal Orange
            self.invertedBg = Color(red: 0.110, green: 0.086, blue: 0.063)
            self.invertedInk = Color(red: 0.961, green: 0.945, blue: 0.910)

        case (.amber, true):
            self.canvas = Color.black                                          // #000000 CRT Void
            self.surface = isNotch ? Color.black : Color(red: 0.031, green: 0.024, blue: 0.016) // #080604
            self.surfaceRaised = Color(red: 0.961, green: 0.651, blue: 0.137).opacity(0.11)
            self.hairline = Color(red: 0.961, green: 0.651, blue: 0.137).opacity(0.17)
            self.hairlineStrong = Color(red: 0.961, green: 0.651, blue: 0.137).opacity(0.36)
            self.reticle = Color(red: 0.961, green: 0.651, blue: 0.137).opacity(0.55)
            self.inkPrimary = Color(red: 0.961, green: 0.925, blue: 0.863)     // #F5ECDC
            self.inkSecondary = Color(red: 0.690, green: 0.596, blue: 0.471)   // #B09878
            self.inkMuted = Color(red: 0.431, green: 0.357, blue: 0.271)       // #6E5B45
            self.accent = Color(red: 0.961, green: 0.651, blue: 0.137)         // #F5A623 Phosphor Amber
            self.invertedBg = Color(red: 0.961, green: 0.651, blue: 0.137)
            self.invertedInk = Color.black
        }

        self.accentSoft = self.accent.opacity(dark ? 0.16 : 0.10)
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

    // MARK: Model Color & Pattern Engine

    func modelColor(_ mc: ModelClass, focused: Bool = false, anyFocused: Bool = false) -> Color {
        if anyFocused {
            return focused ? accent : inkMuted.opacity(isDark ? 0.32 : 0.25)
        }
        switch preset {
        case .monolith:
            switch mc {
            case .carbon:   return accent
            case .argon:    return inkPrimary.opacity(0.82)
            case .neon:     return inkPrimary.opacity(0.62)
            case .hydrogen: return inkPrimary.opacity(0.48)
            case .flash:    return inkPrimary.opacity(0.36)
            case .claude:   return inkPrimary.opacity(0.72)
            case .other:    return inkMuted.opacity(0.48)
            }
        case .blueprint:
            // Strict cyanotype monochrome ink ramp (inspired by Polar archival blueprints)
            if isDark {
                switch mc {
                case .carbon:   return accent                                      // Archival Bone Highlight
                case .argon:    return Color(red: 0.78, green: 0.83, blue: 1.00)   // Pale Cyanotype Ink
                case .neon:     return Color(red: 0.62, green: 0.69, blue: 0.96)   // Periwinkle Ink
                case .hydrogen: return Color(red: 0.48, green: 0.56, blue: 0.88)   // Mid Blueprint Ink
                case .flash:    return Color(red: 0.36, green: 0.44, blue: 0.78)   // Deep Blueprint Ink
                case .claude:   return Color(red: 0.86, green: 0.89, blue: 0.98)   // Bright Chalk Ink
                case .other:    return inkMuted
                }
            } else {
                switch mc {
                case .carbon:   return accent                                      // Vivid Cobalt
                case .argon:    return Color(red: 0.12, green: 0.18, blue: 0.52)   // Deep Prussian Ink
                case .neon:     return Color(red: 0.24, green: 0.32, blue: 0.68)   // Mid Indigo Ink
                case .hydrogen: return Color(red: 0.38, green: 0.46, blue: 0.78)   // Muted Cobalt Ink
                case .flash:    return Color(red: 0.54, green: 0.60, blue: 0.84)   // Pale Blueprint Ink
                case .claude:   return Color(red: 0.16, green: 0.24, blue: 0.60)   // Indigo Ink
                case .other:    return inkMuted
                }
            }
        case .phosphor:
            switch mc {
            case .carbon:   return Color(red: 0.231, green: 0.482, blue: 1.000) // #3B7BFF Cobalt
            case .argon:    return Color(red: 0.133, green: 0.722, blue: 0.812) // #22B8CF Ice Cyan
            case .neon:     return Color(red: 0.482, green: 0.408, blue: 0.933) // #7B68EE Iris
            case .hydrogen: return Color(red: 0.180, green: 0.620, blue: 0.561) // #2E9E8F Deep Teal
            case .flash:    return Color(red: 0.243, green: 0.722, blue: 0.510) // #3EB882 Mint
            case .claude:   return Color(red: 0.788, green: 0.478, blue: 0.329) // #C97A54 Copper
            case .other:    return Color(red: 0.431, green: 0.482, blue: 0.549) // #6E7B8C Graphite
            }
        case .amber:
            switch mc {
            case .carbon:   return accent
            case .argon:    return inkPrimary.opacity(0.82)
            case .neon:     return accent.opacity(0.60)
            case .hydrogen: return inkSecondary.opacity(0.78)
            case .flash:    return inkMuted.opacity(0.65)
            case .claude:   return Color(red: 0.851, green: 0.439, blue: 0.220) // Warm copper
            case .other:    return inkMuted.opacity(0.42)
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
        case (.amber, false):
            let ramp: [Color] = [
                Color(red: 0.96, green: 0.86, blue: 0.75),
                Color(red: 0.91, green: 0.69, blue: 0.48),
                Color(red: 0.85, green: 0.48, blue: 0.21),
                Color(red: 0.72, green: 0.25, blue: 0.05),
            ]
            return ramp[level - 1]
        case (.amber, true):
            let ramp: [Color] = [
                Color(red: 0.24, green: 0.16, blue: 0.05),
                Color(red: 0.48, green: 0.31, blue: 0.08),
                Color(red: 0.76, green: 0.49, blue: 0.11),
                Color(red: 0.98, green: 0.69, blue: 0.18),
            ]
            return ramp[level - 1]
        case (.phosphor, true):
            let ramp: [Color] = [
                Color(red: 0.06, green: 0.18, blue: 0.30),
                Color(red: 0.10, green: 0.36, blue: 0.58),
                Color(red: 0.18, green: 0.58, blue: 0.86),
                Color(red: 0.35, green: 0.82, blue: 1.00),
            ]
            return ramp[level - 1]
        case (_, false):
            let ramp: [Color] = [
                Color(red: 0.84, green: 0.88, blue: 1.00),
                Color(red: 0.58, green: 0.69, blue: 1.00),
                Color(red: 0.28, green: 0.46, blue: 1.00),
                Color(red: 0.10, green: 0.24, blue: 0.82),
            ]
            return ramp[level - 1]
        case (_, true):
            let ramp: [Color] = [
                Color(red: 0.08, green: 0.14, blue: 0.30),
                Color(red: 0.14, green: 0.27, blue: 0.62),
                Color(red: 0.25, green: 0.46, blue: 0.98),
                Color(red: 0.50, green: 0.68, blue: 1.00),
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
