import SwiftUI
import AppKit

// Shared view primitives: Antigravity model-class fallback palette, AGY // TELEMETRY
// drafting primitives (HairlineRule, DotGraticule, Vector Strata Patterns,
// VernierScaleBar, PrecisionHeroNumber, RefreshToolbarButton), and logo.

// MARK: - Model class UI mapping (compatibility fallback)

func modelClassColor(_ mc: ModelClass) -> Color {
    switch mc {
    case .carbon:   return Color(red: 0.231, green: 0.435, blue: 0.969)
    case .argon:    return Color(red: 0.071, green: 0.659, blue: 0.769)
    case .neon:     return Color(red: 0.910, green: 0.263, blue: 0.576)
    case .hydrogen: return Color(red: 0.486, green: 0.325, blue: 0.949)
    case .flash:    return Color(red: 0.122, green: 0.686, blue: 0.447)
    case .claude:   return Color(red: 0.851, green: 0.467, blue: 0.341)
    case .other:    return Color(red: 0.478, green: 0.522, blue: 0.588)
    }
}

func modelClassColor(_ id: String?) -> Color {
    guard let raw = id, !raw.isEmpty else {
        return modelClassColor(.other)
    }
    let mc = ModelClass(rawValue: raw.lowercased()) ?? ModelClass.classify(raw)
    return modelClassColor(mc)
}

extension ModelUsage {
    var modelClass: ModelClass {
        ModelClass(rawValue: id.lowercased()) ?? ModelClass.classify(id)
    }
    var shortCode: String { modelClass.shortCode }
    var color: Color { modelClassColor(modelClass) }
}

// MARK: - Plan Tier Formatter

func formatPlanTierBadge(_ raw: String?) -> String? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }
    switch trimmed.uppercased() {
    case "G1_PRO_TIER", "G1_PRO_LITE_TIER":     return "GOOGLE AI PRO"
    case "G1_ULTRA_TIER", "G1_ULTRA_LITE_TIER": return "GOOGLE AI ULTRA"
    case "FREE_TIER":                           return "FREE TIER"
    case "ENTERPRISE_AGENT_TIER":               return "ENTERPRISE"
    default:                                    return trimmed.uppercased()
    }
}

/// Split formatted tabular currency (e.g. "$36.40") into prefix/whole/decimal parts.
func splitCurrencyParts(_ value: Double) -> (prefix: String, whole: String, frac: String) {
    let raw = formatCostTabular(value)
    let stripped = raw.hasPrefix("$") ? String(raw.dropFirst()) : raw
    if let dot = stripped.lastIndex(of: ".") {
        return ("$", String(stripped[..<dot]), String(stripped[dot...]))
    }
    return ("$", stripped, "")
}

/// Split compact token readout (e.g. "23.8M") into numeric body and unit suffix.
func splitTokenParts(_ count: Int) -> (number: String, unit: String) {
    let raw = formatTokensShort(count).uppercased()
    if let last = raw.last, last.isLetter {
        return (String(raw.dropLast()), String(last))
    }
    return (raw, "")
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

struct LogoShape: Shape {
    func path(in rect: CGRect) -> SwiftUI.Path {
        AGYLogo.swiftUIPath(in: rect)
    }
}

typealias AGYLogoShape = LogoShape

struct SessionAwareLogo: View {
    @ObservedObject var sessionStore: SessionStore
    var size: CGFloat = 16
    var color: Color = .agyBrand
    var dotSize: CGFloat = 5

    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @Environment(\.telemetryStaticRender) private var isStaticRender

    private static let levitatePeriod: Double = 1.8
    private static let breathePeriod: Double = 2.6

    private var logoMark: some View {
        LogoShape().fill(color).frame(width: size, height: size)
    }

    private var visualState: LogoVisualState {
        LogoVisualState.resolve(
            anyBusy: sessionStore.anyBusy && !isStaticRender,
            anyWaiting: sessionStore.anyWaiting,
            anyDoneUnseen: sessionStore.anyDoneUnseen,
            reduceMotion: reduceMotion || isStaticRender
        )
    }

    @ViewBuilder private var animatedLogo: some View {
        switch visualState.animation {
        case .levitate:
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
        case .breatheOpacity:
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let phase = (sin(2 * Double.pi * t / Self.breathePeriod) + 1) / 2
                logoMark.opacity(0.55 + 0.45 * phase)
            }
        case .idle:
            logoMark
        }
    }

    private var dotColor: Color? {
        switch visualState.dot {
        case .waitingAmber:    return .agyStatusWaiting
        case .doneUnseenGreen: return .green
        case .none:            return nil
        }
    }

    var body: some View {
        animatedLogo
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                if let c = dotColor {
                    Circle()
                        .fill(c)
                        .frame(width: dotSize, height: dotSize)
                        .overlay(Circle().stroke(Color.black.opacity(0.45), lineWidth: 0.7))
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

// MARK: - Precision Drafting Primitives

/// Crisp 1px L-shaped corner targeting reticles (`┌ ┐ └ ┘`).
struct CornerReticleOverlay: View {
    let color: Color
    var length: CGFloat = 5
    var lineWidth: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let inset = lineWidth / 2
            let len = min(length, min(w, h) / 3)
            Path { p in
                p.move(to: CGPoint(x: inset, y: inset + len))
                p.addLine(to: CGPoint(x: inset, y: inset))
                p.addLine(to: CGPoint(x: inset + len, y: inset))

                p.move(to: CGPoint(x: w - inset - len, y: inset))
                p.addLine(to: CGPoint(x: w - inset, y: inset))
                p.addLine(to: CGPoint(x: w - inset, y: inset + len))

                p.move(to: CGPoint(x: inset, y: h - inset - len))
                p.addLine(to: CGPoint(x: inset, y: h - inset))
                p.addLine(to: CGPoint(x: inset + len, y: h - inset))

                p.move(to: CGPoint(x: w - inset - len, y: h - inset))
                p.addLine(to: CGPoint(x: w - inset, y: h - inset))
                p.addLine(to: CGPoint(x: w - inset, y: h - inset - len))
            }
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .square, lineJoin: .miter))
        }
        .allowsHitTesting(false)
    }
}

/// Full-bleed 1px horizontal hairline with `+` registration crosshairs inset 12pt from margins.
struct HairlineRule: View {
    var showCrosshairs: Bool = true
    @Environment(\.agyTheme) private var theme

    var body: some View {
        Rectangle()
            .fill(theme.hairline)
            .frame(height: 1)
            .overlay {
                if showCrosshairs {
                    GeometryReader { geo in
                        let w = geo.size.width
                        let inset: CGFloat = 12
                        Path { p in
                            p.move(to: CGPoint(x: inset, y: -2.5))
                            p.addLine(to: CGPoint(x: inset, y: 3.5))
                            p.move(to: CGPoint(x: w - inset, y: -2.5))
                            p.addLine(to: CGPoint(x: w - inset, y: 3.5))
                        }
                        .stroke(theme.reticle, lineWidth: 1)
                    }
                    .allowsHitTesting(false)
                }
            }
    }
}

/// Oscilloscope / blueprint 1px dot graticule background rendered cleanly in Canvas.
struct DotGraticuleBackground: View {
    var spacing: CGFloat = 10
    @Environment(\.agyTheme) private var theme

    var body: some View {
        Canvas { context, size in
            let color = theme.hairline.opacity(0.65)
            var y: CGFloat = spacing * 0.5
            while y < size.height {
                var x: CGFloat = spacing * 0.5
                while x < size.width {
                    context.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)), with: .color(color))
                    x += spacing
                }
                y += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Vector Strata Rendering (Canvas Hatches & Swatches)

func drawStrataRect(
    in context: inout GraphicsContext,
    rect: CGRect,
    color: Color,
    pattern: StrataPattern
) {
    guard rect.width > 0.2, rect.height > 0.2 else { return }
    switch pattern {
    case .solid:
        context.fill(Path(rect), with: .color(color))
    case .dense:
        context.fill(Path(rect), with: .color(color.opacity(0.88)))
    case .muted:
        context.fill(Path(rect), with: .color(color.opacity(0.42)))
    case .diagonalHatch:
        context.fill(Path(rect), with: .color(color.opacity(0.16)))
        context.drawLayer { layer in
            layer.clip(to: Path(rect))
            let step: CGFloat = 3.2
            let span = rect.height
            var path = Path()
            var x = rect.minX - span
            while x <= rect.maxX + span {
                path.move(to: CGPoint(x: x, y: rect.maxY))
                path.addLine(to: CGPoint(x: x + span, y: rect.minY))
                x += step
            }
            layer.stroke(path, with: .color(color), lineWidth: 1)
        }
    case .horizontalHatch:
        context.fill(Path(rect), with: .color(color.opacity(0.14)))
        context.drawLayer { layer in
            layer.clip(to: Path(rect))
            var path = Path()
            var y = rect.minY + 1
            while y < rect.maxY {
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
                y += 2.6
            }
            layer.stroke(path, with: .color(color), lineWidth: 1)
        }
    case .stipple:
        context.fill(Path(rect), with: .color(color.opacity(0.14)))
        context.drawLayer { layer in
            layer.clip(to: Path(rect))
            let step: CGFloat = 3.0
            var row = 0
            var y = rect.minY + 0.5
            while y < rect.maxY {
                let offset: CGFloat = (row % 2 == 0) ? 0.5 : 2.0
                var x = rect.minX + offset
                while x < rect.maxX {
                    layer.fill(Path(CGRect(x: x, y: y, width: 1.2, height: 1.2)), with: .color(color))
                    x += step
                }
                row += 1
                y += step * 0.85
            }
        }
    case .outline:
        context.fill(Path(rect), with: .color(color.opacity(0.10)))
        context.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(color), lineWidth: 1)
    }
}

struct StrataSwatch: View {
    let color: Color
    let pattern: StrataPattern
    var size: CGFloat = 7

    var body: some View {
        Canvas { context, canvasSize in
            var ctx = context
            drawStrataRect(
                in: &ctx,
                rect: CGRect(origin: .zero, size: canvasSize),
                color: color,
                pattern: pattern
            )
        }
        .frame(width: size, height: size)
    }
}

struct StrataSegment: Identifiable {
    let id: String
    let color: Color
    let pattern: StrataPattern
    let fraction: Double
}

/// Crisp vector proportion bar with interactive focus highlighting & strata hatching.
struct StrataBarView: View {
    let segments: [StrataSegment]
    var focusedId: String? = nil
    var height: CGFloat = 5
    @Environment(\.agyTheme) private var theme

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(theme.hairline))
            let active = segments.filter { $0.fraction > 0 }
            guard !active.isEmpty else { return }
            let gap: CGFloat = 1.5
            let usableWidth = max(1, size.width - gap * CGFloat(max(0, active.count - 1)))
            var x: CGFloat = 0
            for seg in active {
                let w = max(2, CGFloat(seg.fraction) * usableWidth)
                let rect = CGRect(x: x, y: 0, width: min(w, size.width - x), height: size.height)
                var ctx = context
                let segColor: Color = {
                    if let f = focusedId {
                        return (seg.id == f) ? theme.accent : theme.inkMuted.opacity(theme.isDark ? 0.28 : 0.22)
                    }
                    return seg.color
                }()
                drawStrataRect(in: &ctx, rect: rect, color: segColor, pattern: seg.pattern)
                x += w + gap
                if x >= size.width { break }
            }
        }
        .frame(height: height)
    }
}

// MARK: - Vernier Scale Quota Bar & Precision Hero Number

/// 60-tick precision vernier caliper bar with `▼` pace marker needle.
struct VernierScaleBar: View {
    let fraction: CGFloat
    let fillColor: Color
    var paceMarkerFraction: CGFloat? = nil
    var paceWarning: Bool = false
    var ticks: Int = 60

    @Environment(\.agyTheme) private var theme

    var body: some View {
        let clamped = max(0, min(1, fraction))
        Canvas { context, size in
            let topPad: CGFloat = 4
            let barBottom = size.height
            let step = size.width / CGFloat(ticks)
            let tickW = max(1.0, step * 0.46)
            let filledCount = clamped > 0 ? max(1, Int((clamped * CGFloat(ticks)).rounded(.up))) : 0

            for i in 0..<ticks {
                let isMajor = (i % 15 == 0 || i == ticks - 1)
                let tickH: CGFloat = isMajor ? (barBottom - topPad) : (barBottom - topPad) * 0.66
                let y = barBottom - tickH
                let x = CGFloat(i) * step + (step - tickW) * 0.5
                let rect = CGRect(x: x, y: y, width: tickW, height: tickH)
                let c = (i < filledCount) ? fillColor : theme.hairlineStrong.opacity(theme.isDark ? 0.55 : 0.48)
                context.fill(Path(rect), with: .color(c))
            }

            if let pace = paceMarkerFraction {
                let pClamped = max(0.02, min(0.98, pace))
                let px = size.width * pClamped
                let markerColor = paceWarning ? theme.signalAmber : theme.inkPrimary

                // Inverted precision index triangle `▼`
                var tri = Path()
                tri.move(to: CGPoint(x: px - 3, y: 0))
                tri.addLine(to: CGPoint(x: px + 3, y: 0))
                tri.addLine(to: CGPoint(x: px, y: 3.5))
                tri.closeSubpath()
                context.fill(tri, with: .color(markerColor))

                // Vertical calibrated cursor line cutting across ticks
                let cursorRect = CGRect(x: px - 0.6, y: 3, width: 1.2, height: barBottom - 2)
                context.fill(Path(cursorRect), with: .color(markerColor))
            }
        }
        .frame(height: 17)
    }
}

struct PrecisionHeroNumber: View {
    var prefix: String? = nil
    let whole: String
    var fraction: String? = nil
    var suffix: String? = nil
    var size: CGFloat = 34
    var accentPrimary: Color? = nil

    @Environment(\.agyTheme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if let p = prefix, !p.isEmpty {
                Text(p)
                    .font(.system(size: size * 0.48, weight: .light, design: .monospaced))
                    .foregroundColor(theme.inkSecondary)
                    .padding(.trailing, 2)
            }
            Text(whole)
                .font(.system(size: size, weight: .light, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(accentPrimary ?? theme.inkPrimary)
                .contentTransition(.numericText())
            if let f = fraction, !f.isEmpty {
                Text(f)
                    .font(.system(size: size * 0.54, weight: .light, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(accentPrimary?.opacity(0.8) ?? theme.inkSecondary)
                    .contentTransition(.numericText())
            }
            if let s = suffix, !s.isEmpty {
                Text(s)
                    .font(.system(size: size * 0.42, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.inkSecondary)
                    .padding(.leading, 3)
            }
        }
    }
}

// MARK: - Radar Status Dot & Telemetry Skeleton

struct RadarStatusDot: View {
    let kind: SessionLogic.SessionDotKind
    @Environment(\.agyTheme) private var theme
    @Environment(\.telemetryStaticRender) private var isStaticRender
    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var body: some View {
        Group {
            switch kind {
            case .busy:
                if reduceMotion || isStaticRender {
                    ZStack {
                        Circle()
                            .stroke(theme.accent.opacity(0.45), lineWidth: 1)
                            .frame(width: 11, height: 11)
                        Circle()
                            .fill(theme.accent)
                            .frame(width: 5.5, height: 5.5)
                    }
                } else {
                    TimelineView(.animation) { ctx in
                        let raw = (ctx.date.timeIntervalSinceReferenceDate / 1.6)
                            .truncatingRemainder(dividingBy: 1.0)
                        let t = raw < 0 ? raw + 1.0 : raw
                        ZStack {
                            Circle()
                                .stroke(theme.accent.opacity(0.65 * (1.0 - t)), lineWidth: 1)
                                .frame(width: 6 + 8 * t, height: 6 + 8 * t)
                            Circle()
                                .fill(theme.accent)
                                .frame(width: 5.5, height: 5.5)
                        }
                    }
                }
            case .waiting:
                Rectangle()
                    .fill(theme.signalAmber)
                    .frame(width: 6, height: 6)
                    .rotationEffect(.degrees(45))
            case .doneUnseen:
                Circle()
                    .fill(theme.signalGreen)
                    .frame(width: 6, height: 6)
            case .grey:
                Circle()
                    .fill(theme.inkMuted)
                    .frame(width: 5, height: 5)
            }
        }
        .frame(width: 12, height: 12)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }
}

struct TelemetrySkeleton: View {
    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @Environment(\.telemetryStaticRender) private var isStaticRender
    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var body: some View {
        Group {
            if isStaticRender || reduceMotion {
                content(opacity: 0.85)
            } else {
                TimelineView(.animation) { ctx in
                    let wave = (sin(ctx.date.timeIntervalSinceReferenceDate * 3.5) + 1) / 2
                    content(opacity: 0.45 + 0.45 * wave)
                }
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }

    private func content(opacity: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(loc("loadingTelemetry"))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundColor(theme.accent)
                    Spacer()
                    Rectangle()
                        .fill(theme.hairlineStrong)
                        .frame(width: 52, height: 8)
                }
                Rectangle()
                    .fill(theme.hairlineStrong)
                    .frame(width: 148, height: 28)
                Rectangle()
                    .fill(theme.hairline)
                    .frame(height: 5)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .opacity(opacity)

            HairlineRule(showCrosshairs: true)

            VStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { i in
                    HStack {
                        Rectangle().fill(theme.hairlineStrong).frame(width: CGFloat(86 - i * 10), height: 8)
                        Spacer()
                        Rectangle().fill(theme.hairline).frame(width: 96, height: 8)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .opacity(opacity)
        }
    }
}

// MARK: - Bare Statusline Toolbar Controls (Zero Floating Layout Bug)

struct ToolbarIconButton: View {
    let systemName: String
    let helpText: String
    let action: () -> Void

    @Environment(\.agyTheme) private var theme
    @State private var hovering = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundColor(hovering ? theme.inkPrimary : theme.inkSecondary)
            .frame(width: 24, height: 22)
            .background(
                RoundedRectangle(cornerRadius: AGYTheme.controlRadius, style: .continuous)
                    .fill(hovering ? theme.surfaceRaised : Color.clear)
            )
            .contentShape(Rectangle())
            .help(helpText)
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
    }
}

/// Isolated TimelineView spinner so rotation NEVER animates frame layout coordinates.
struct RefreshToolbarButton: View {
    let isLoading: Bool
    let helpText: String
    let action: () -> Void

    @Environment(\.agyTheme) private var theme
    @Environment(\.telemetryStaticRender) private var isStaticRender
    @State private var hovering = false
    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var body: some View {
        Group {
            if isLoading && !isStaticRender && !reduceMotion {
                TimelineView(.animation) { ctx in
                    let angle = (ctx.date.timeIntervalSinceReferenceDate * 360.0)
                        .truncatingRemainder(dividingBy: 360.0)
                    iconView(angle: angle, tint: theme.accent)
                }
            } else {
                iconView(angle: 0, tint: hovering ? theme.inkPrimary : (isLoading ? theme.accent : theme.inkSecondary))
            }
        }
        .frame(width: 24, height: 22)
        .background(
            RoundedRectangle(cornerRadius: AGYTheme.controlRadius, style: .continuous)
                .fill(hovering ? theme.surfaceRaised : Color.clear)
        )
        .contentShape(Rectangle())
        .help(helpText)
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }

    private func iconView(angle: Double, tint: Color) -> some View {
        Image(systemName: "arrow.clockwise")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundColor(tint)
            .rotationEffect(.degrees(angle))
    }
}

// MARK: - Grid-Native Tab Bar & Segmented Strip

extension DisplayTab {
    func shortLabel(_ loc: Localizer) -> String {
        switch self {
        case .cost:         return loc("tabCostShort")
        case .tokens:       return loc("tabTokensShort")
        case .time:         return loc("tabTimeShort")
        case .session:      return loc("tabSessionShort")
        case .subscription: return loc("tabPlanShort")
        }
    }
}

/// Full-bleed 5-column drafting tab grid bounded by edge-to-edge 1px hairlines.
/// Active tab flips cleanly into a sharp inverted cursor block.
struct TelemetryTabBar: View {
    let items: [DisplayTab]
    @Binding var selection: DisplayTab
    @ObservedObject var sessionStore: SessionStore
    let loc: Localizer

    @Environment(\.agyTheme) private var theme
    @Namespace private var tabNamespace
    @State private var hovered: DisplayTab? = nil

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(theme.hairline).frame(height: 1)

            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element) { index, tab in
                    let isSelected = (tab == selection)
                    let isHovered = (tab == hovered)
                    let indexLabel = String(format: "%02d", index + 1)

                    HStack(spacing: 3.5) {
                        Text(indexLabel)
                            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                            .foregroundColor(isSelected ? theme.invertedInk.opacity(0.68) : theme.inkMuted)
                        Text(tab.shortLabel(loc))
                            .font(.system(size: 10, weight: isSelected ? .bold : .medium, design: .monospaced))
                            .foregroundColor(isSelected ? theme.invertedInk : theme.inkSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        if tab == .session {
                            sessionIndicator(isSelected: isSelected)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .background(
                        ZStack {
                            if isSelected {
                                Rectangle()
                                    .fill(theme.invertedBg)
                                    .matchedGeometryEffect(id: "activeTabPlate", in: tabNamespace)
                            } else if isHovered {
                                Rectangle()
                                    .fill(theme.surfaceRaised.opacity(0.75))
                            }
                        }
                    )
                    .contentShape(Rectangle())
                    .onHover { inside in hovered = inside ? tab : (hovered == tab ? nil : hovered) }
                    .onTapGesture {
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
                            selection = tab
                        }
                    }

                    if index < items.count - 1 {
                        Rectangle().fill(theme.hairline).frame(width: 1)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            Rectangle().fill(theme.hairline).frame(height: 1)
        }
    }

    @ViewBuilder
    private func sessionIndicator(isSelected: Bool) -> some View {
        let count = sessionStore.liveCount
        if sessionStore.anyWaiting {
            HStack(spacing: 2) {
                Circle().fill(theme.signalAmber).frame(width: 4.5, height: 4.5)
                Text("\(count)")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundColor(isSelected ? theme.signalAmber : theme.signalAmber)
            }
        } else if count > 0 {
            let dotColor: Color = sessionStore.anyBusy
                ? (isSelected ? theme.invertedInk : theme.accent)
                : (sessionStore.anyDoneUnseen ? theme.signalGreen : (isSelected ? theme.invertedInk.opacity(0.7) : theme.inkMuted))
            HStack(spacing: 2) {
                Circle().fill(dotColor).frame(width: 4, height: 4)
                Text("\(count)")
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(isSelected ? theme.invertedInk : (dotColor == theme.inkMuted ? theme.inkSecondary : dotColor))
            }
        }
    }
}

/// Edge-to-edge sub-tab strip bounded by 1px hairlines (Week / Month / Year).
struct TelemetrySegmentedStrip<Value: Hashable>: View {
    let items: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    @Environment(\.agyTheme) private var theme
    @Namespace private var stripNamespace
    @State private var hovered: Value? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element) { index, item in
                    let isSelected = (item == selection)
                    let isHovered = (item == hovered)

                    Text(label(item).uppercased())
                        .font(.system(size: 9.5, weight: isSelected ? .bold : .medium, design: .monospaced))
                        .tracking(0.8)
                        .foregroundColor(isSelected ? theme.invertedInk : theme.inkSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background(
                            ZStack {
                                if isSelected {
                                    Rectangle()
                                        .fill(theme.invertedBg)
                                        .matchedGeometryEffect(id: "subPlate", in: stripNamespace)
                                } else if isHovered {
                                    Rectangle()
                                        .fill(theme.surfaceRaised.opacity(0.75))
                                }
                            }
                        )
                        .contentShape(Rectangle())
                        .onHover { inside in hovered = inside ? item : (hovered == item ? nil : hovered) }
                        .onTapGesture {
                            withAnimation(.spring(response: 0.20, dampingFraction: 0.88)) {
                                selection = item
                            }
                        }

                    if index < items.count - 1 {
                        Rectangle().fill(theme.hairline).frame(width: 1)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            HairlineRule(showCrosshairs: true)
        }
    }
}

// MARK: - Monochrome Token Type Telemetry Bar

struct TokenTypeBar: View {
    let usage: PeriodUsage
    var focusedModelId: String? = nil

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme

    private var entries: [(id: String, key: String, color: Color, pattern: StrataPattern, value: Int)] {
        [
            ("cr", "tkCR",  theme.accent,                     .solid,         usage.totalCacheRead),
            ("in", "tkIn",  theme.inkPrimary.opacity(0.68),   .dense,         usage.totalInput),
            ("ot", "tkOut", theme.inkSecondary.opacity(0.70), .diagonalHatch, usage.totalOutput),
            ("cw", "tkCW",  theme.inkMuted.opacity(0.45),     .outline,       usage.totalCacheWrite),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            StrataBarView(
                segments: entries.map { item in
                    StrataSegment(
                        id: item.id,
                        color: item.color,
                        pattern: item.pattern,
                        fraction: usage.totalTokens > 0 ? Double(item.value) / Double(usage.totalTokens) : 0
                    )
                },
                focusedId: nil,
                height: 5
            )

            HStack(spacing: 10) {
                ForEach(entries, id: \.id) { item in
                    HStack(spacing: 4) {
                        StrataSwatch(color: item.color, pattern: item.pattern, size: 6)
                        Text(loc(item.key).uppercased())
                            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(theme.inkSecondary)
                        Text(formatTokensShort(item.value).uppercased())
                            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.inkPrimary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}
