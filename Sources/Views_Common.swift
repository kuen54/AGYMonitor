import SwiftUI
import AppKit

// Shared view primitives: Antigravity model-class palette, localizer environment,
// Antigravity logo shape + session-aware levitation pulse/dot, and usage proportion bars.

// MARK: - Model class UI mapping
//
// Color mapping lives in the UI layer so SwiftUI Color stays out of Core_*.swift.

/// Single source of truth for Antigravity's 7 model classes (tier order):
/// - `.carbon`: Antigravity cobalt blue (flagship pro / orchestrator)
/// - `.argon`: cyan/teal (heavy workhorse pro)
/// - `.neon`: vivid neon magenta/pink (mid-tier pro / orchestrator)
/// - `.hydrogen`: deep violet/indigo (high-speed reasoning / worker)
/// - `.flash`: emerald/mint (Gemini Flash)
/// - `.claude`: warm terracotta/coral (#D97757)
/// - `.other`: neutral slate
func modelClassColor(_ mc: ModelClass) -> Color {
    switch mc {
    case .carbon:   return Color(red: 0.250, green: 0.480, blue: 0.970) // #407AF8 Antigravity cobalt blue
    case .argon:    return Color(red: 0.080, green: 0.710, blue: 0.830) // #14B5D4 cyan/teal
    case .neon:     return Color(red: 0.925, green: 0.282, blue: 0.600) // #EC4899 neon magenta/pink
    case .hydrogen: return Color(red: 0.520, green: 0.320, blue: 0.960) // #8552F5 deep violet/indigo
    case .flash:    return Color(red: 0.160, green: 0.770, blue: 0.510) // #29C482 emerald/mint
    case .claude:   return Color(red: 0.851, green: 0.467, blue: 0.341) // #D97757 warm terracotta/coral
    case .other:    return Color(red: 0.560, green: 0.600, blue: 0.660) // #8F99A8 neutral slate
    }
}

/// String/optional-id overload shared by ModelUsage.color and Time-tab interval capsules.
func modelClassColor(_ id: String?) -> Color {
    guard let raw = id, !raw.isEmpty else {
        return modelClassColor(.other)
    }
    let mc = ModelClass(rawValue: raw.lowercased()) ?? ModelClass.classify(raw)
    return modelClassColor(mc)
}

extension ModelUsage {
    var color: Color { modelClassColor(id) }
}

// MARK: - Localizer environment

private struct LocalizerKey: EnvironmentKey {
    static let defaultValue = Localizer(language: AppLanguage.fromSystem())
}

extension EnvironmentValues {
    var localizer: Localizer {
        get { self[LocalizerKey.self] }
        set { self[LocalizerKey.self] = newValue }
    }
}

// MARK: - Antigravity Logo Views

/// Official Antigravity vector mark normalized into the bounding rect.
struct LogoShape: Shape {
    func path(in rect: CGRect) -> SwiftUI.Path {
        AGYLogo.swiftUIPath(in: rect)
    }
}

typealias AGYLogoShape = LogoShape

/// Session-aware Antigravity logo shared across the compact notch pill, popover
/// header, and menu-bar status item:
/// - Performs an upright zero-G levitation + upward energy shimmer + underside thruster
///   pulse (1.8s cycle) while any live session is busy (or breathes opacity on
///   Reduce Motion); tears down TimelineView completely when idle for zero CPU.
/// - Shows top-trailing attention dot: amber (`anyWaiting`) outranks green (`anyDoneUnseen`).
struct SessionAwareLogo: View {
    @ObservedObject var sessionStore: SessionStore
    var size: CGFloat = 16
    var color: Color = .agyBrand
    var dotSize: CGFloat = 5

    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    /// Anti-gravity levitation + shimmer cycle (seconds).
    private static let levitatePeriod: Double = 1.8
    /// Reduce-motion opacity breathe period (seconds).
    private static let breathePeriod: Double = 2.6

    private var logoMark: some View {
        LogoShape().fill(color).frame(width: size, height: size)
    }

    @ViewBuilder private var animatedLogo: some View {
        if sessionStore.anyBusy && !reduceMotion {
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let rawProgress = (t / Self.levitatePeriod).truncatingRemainder(dividingBy: 1.0)
                let progress = rawProgress < 0 ? rawProgress + 1.0 : rawProgress
                let wave = sin(2 * Double.pi * progress)
                let yOffset = -size * 0.08 * wave
                let scale = 1.0 + 0.04 * wave
                let sweepY = 1.35 - 1.70 * progress

                ZStack {
                    Capsule()
                        .fill(color.opacity(0.75 * (1.0 - progress)))
                        .frame(
                            width: size * 0.28 * (1.0 - 0.35 * progress),
                            height: max(1.3, size * 0.085)
                        )
                        .offset(y: size * (0.28 + 0.16 * progress))

                    ZStack {
                        LogoShape().fill(color.opacity(0.82))
                        LogoShape().fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.0),
                                    .init(color: Color(red: 0.45, green: 0.88, blue: 1.0).opacity(0.85), location: 0.35),
                                    .init(color: Color.white.opacity(0.95), location: 0.50),
                                    .init(color: Color(red: 0.45, green: 0.88, blue: 1.0).opacity(0.85), location: 0.65),
                                    .init(color: .clear, location: 1.0),
                                ],
                                startPoint: UnitPoint(x: 0.5, y: sweepY + 0.38),
                                endPoint: UnitPoint(x: 0.5, y: sweepY - 0.38)
                            )
                        )
                    }
                    .frame(width: size, height: size)
                    .scaleEffect(scale)
                    .offset(y: yOffset)
                }
                .frame(width: size, height: size)
            }
        } else if sessionStore.anyBusy && reduceMotion {
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let phase = (sin(2 * Double.pi * t / Self.breathePeriod) + 1) / 2
                logoMark.opacity(0.55 + 0.45 * phase)
            }
        } else {
            logoMark
        }
    }

    private var dotColor: Color? {
        if sessionStore.anyWaiting { return .agyStatusWaiting }
        if sessionStore.anyDoneUnseen { return .green }
        return nil
    }

    var body: some View {
        animatedLogo
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                if let c = dotColor {
                    Circle()
                        .fill(c)
                        .frame(width: dotSize, height: dotSize)
                        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 0.8))
                        .offset(x: dotSize * 0.3, y: -dotSize * 0.3)
                }
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
                reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
    }
}

typealias SessionAwareAGYLogo = SessionAwareLogo

// MARK: - Proportion Bars

/// Generic horizontal proportion bar (works for cost or token shares).
struct ProportionBar: View {
    let segments: [(color: Color, fraction: CGFloat)]

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1.5) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    if seg.fraction > 0 {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(seg.color)
                            .frame(width: max(3, seg.fraction * geo.size.width))
                    }
                }
            }
        }
        .frame(height: 6)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.primary.opacity(0.06))
        )
    }
}

/// Cost proportion bar by model class.
struct CostBar: View {
    let models: [ModelUsage]
    let total: Double

    var body: some View {
        ProportionBar(segments: models.map { m in
            (color: m.color, fraction: total > 0 ? CGFloat(m.cost / total) : 0)
        })
    }
}

/// Token proportion bar by model class.
struct TokenBar: View {
    let models: [ModelUsage]
    let total: Int

    var body: some View {
        ProportionBar(segments: models.map { m in
            (color: m.color, fraction: total > 0 ? CGFloat(Double(m.totalTokens) / Double(total)) : 0)
        })
    }
}

/// Token type proportion bar (in / out / cache_read / cache_write).
struct TokenTypeBar: View {
    let usage: PeriodUsage
    @Environment(\.localizer) private var loc

    static let typeEntries: [(String, Color, KeyPath<PeriodUsage, Int>)] = [
        ("tkIn",  Color(red: 0.10, green: 0.60, blue: 0.65), \.totalInput),      // teal
        ("tkOut", Color(red: 0.90, green: 0.40, blue: 0.30), \.totalOutput),      // coral
        ("tkCR",  Color(red: 0.55, green: 0.78, blue: 0.80), \.totalCacheRead),   // desaturated teal
        ("tkCW",  Color(red: 0.92, green: 0.70, blue: 0.62), \.totalCacheWrite),  // desaturated coral
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProportionBar(segments: Self.typeEntries.map { (_, color, kp) in
                let val = usage[keyPath: kp]
                return (color: color, fraction: usage.totalTokens > 0
                    ? CGFloat(Double(val) / Double(usage.totalTokens)) : 0)
            })

            // Legend row
            HStack(spacing: 10) {
                ForEach(Array(Self.typeEntries.enumerated()), id: \.offset) { _, item in
                    let (key, color, kp) = item
                    HStack(spacing: 3) {
                        Circle().fill(color).frame(width: 5, height: 5)
                        Text(loc(key))
                            .font(.system(size: 9))
                            .foregroundColor(color.opacity(0.9))
                        Text(formatTokensShort(usage[keyPath: kp]))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}
