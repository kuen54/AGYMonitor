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
    /// Set to false whenever the hosting surface is hidden (e.g. menu bar in Notch mode,
    /// closed popover, or hidden fullscreen notch pill) so the logo drops to 0 Hz.
    var isActive: Bool = true

    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @Environment(\.telemetryStaticRender) private var isStaticRender

    private static let levitatePeriod: Double = 1.8
    private static let breathePeriod: Double = 2.6

    private var logoMark: some View {
        LogoShape().fill(color).frame(width: size, height: size)
    }

    private var visualState: LogoVisualState {
        LogoVisualState.resolve(
            anyBusy: sessionStore.anyBusy && !isStaticRender && isActive,
            anyWaiting: sessionStore.anyWaiting,
            anyDoneUnseen: sessionStore.anyDoneUnseen,
            reduceMotion: reduceMotion || isStaticRender || !isActive
        )
    }

    @ViewBuilder private var animatedLogo: some View {
        switch visualState.animation {
        case .levitate:
            // Pure Canvas at 12fps: avoids 120Hz NSHostingView AutoLayout passes & dynamic color churn.
            TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let rawProgress = (t / Self.levitatePeriod).truncatingRemainder(dividingBy: 1.0)
                let progress = rawProgress < 0 ? rawProgress + 1.0 : rawProgress
                let wave = sin(2 * Double.pi * progress)
                let yOffset = CGFloat(-size * 0.08 * wave)
                let scale = CGFloat(1.0 + 0.04 * wave)
                let sweepY = CGFloat(1.35 - 1.70 * progress)

                Canvas { context, canvasSize in
                    let w = canvasSize.width
                    let h = canvasSize.height

                    // Ground shadow capsule
                    let capW = w * 0.28 * CGFloat(1.0 - 0.35 * progress)
                    let capH = max(1.3, h * 0.085)
                    let capY = h * 0.5 + h * CGFloat(0.28 + 0.16 * progress) - capH * 0.5
                    let capRect = CGRect(x: (w - capW) * 0.5, y: capY, width: capW, height: capH)
                    context.fill(
                        Path(roundedRect: capRect, cornerRadius: capH * 0.5),
                        with: .color(color.opacity(0.75 * (1.0 - progress)))
                    )

                    // Levitating logo mark + upward optical sheen
                    context.drawLayer { layer in
                        layer.translateBy(x: w * 0.5, y: h * 0.5 + yOffset)
                        layer.scaleBy(x: scale, y: scale)
                        layer.translateBy(x: -w * 0.5, y: -h * 0.5)

                        let logoPath = AGYLogo.swiftUIPath(in: CGRect(origin: .zero, size: canvasSize))
                        layer.fill(logoPath, with: .color(color.opacity(0.84)))
                        layer.fill(
                            logoPath,
                            with: .linearGradient(
                                Gradient(stops: [
                                    .init(color: .clear, location: 0.0),
                                    .init(color: Color(red: 0.45, green: 0.88, blue: 1.0).opacity(0.85), location: 0.35),
                                    .init(color: Color.white.opacity(0.95), location: 0.50),
                                    .init(color: Color(red: 0.45, green: 0.88, blue: 1.0).opacity(0.85), location: 0.65),
                                    .init(color: .clear, location: 1.0),
                                ]),
                                startPoint: CGPoint(x: w * 0.5, y: h * (sweepY + 0.38)),
                                endPoint: CGPoint(x: w * 0.5, y: h * (sweepY - 0.38))
                            )
                        )
                    }
                }
                .frame(width: size, height: size)
            }
        case .breatheOpacity:
            TimelineView(.animation(minimumInterval: 1.0 / 8.0)) { ctx in
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
                        let inset: CGFloat = 14
                        let alpha: Double = theme.isDark ? 0.52 : 0.46
                        if theme.isMultiColorSpectrum {
                            Path { p in
                                p.move(to: CGPoint(x: inset, y: -2.0))
                                p.addLine(to: CGPoint(x: inset, y: 3.0))
                            }
                            .stroke(theme.accentQuaternary.opacity(alpha), lineWidth: 0.9)
                            Path { p in
                                p.move(to: CGPoint(x: w - inset, y: -2.0))
                                p.addLine(to: CGPoint(x: w - inset, y: 3.0))
                            }
                            .stroke(theme.accentTertiary.opacity(alpha), lineWidth: 0.9)
                        } else {
                            Path { p in
                                p.move(to: CGPoint(x: inset, y: -2.0))
                                p.addLine(to: CGPoint(x: inset, y: 3.0))
                                p.move(to: CGPoint(x: w - inset, y: -2.0))
                                p.addLine(to: CGPoint(x: w - inset, y: 3.0))
                            }
                            .stroke(theme.accentSecondary.opacity(theme.isDark ? 0.48 : 0.42), lineWidth: 0.85)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
    }
}

/// Deterministic archival paper / film micro-grain tile pre-baked with premultiplied alpha.
/// Uses native hardware-tiled Image(.tile) with normal source-over compositing — ZERO offscreen
/// `.blendMode` render pass, ZERO per-frame Canvas draw loops, identical print materiality.
struct ArchivalGrainOverlay: View {
    @Environment(\.agyTheme) private var theme

    private static func makePremultipliedTile(darkMode: Bool) -> NSImage? {
        let side = 128
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for i in 0..<(side * side) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let r1 = Int((seed >> 33) & 0xFF)
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let r2 = Int((seed >> 33) & 0xFF)
            let n = (r1 + r2) >> 1 // triangular 0...255 centered around 128
            let base = i * 4
            if darkMode {
                // Subtle bright film micro-grain (premultiplied white, alpha 0...11/255)
                let a = UInt8(min(11, max(0, (n * 11) / 255)))
                rgba[base] = a
                rgba[base + 1] = a
                rgba[base + 2] = a
                rgba[base + 3] = a
            } else {
                // Subtle dark archival paper fiber (premultiplied charcoal, alpha 0...12/255)
                let inv = 255 - n
                let a = UInt8(min(12, max(0, (inv * 12) / 255)))
                rgba[base] = 0
                rgba[base + 1] = 0
                rgba[base + 2] = 0
                rgba[base + 3] = a
            }
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        guard let cg = CGImage(
            width: side,
            height: side,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: side * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: side, height: side))
    }

    private static let lightTileImage: NSImage? = makePremultipliedTile(darkMode: false)
    private static let darkTileImage: NSImage? = makePremultipliedTile(darkMode: true)

    var body: some View {
        if !theme.isNotch, let nsImage = (theme.isDark ? Self.darkTileImage : Self.lightTileImage) {
            Image(nsImage: nsImage)
                .resizable(resizingMode: .tile)
                .allowsHitTesting(false)
        }
    }
}

/// Process-wide reference-counted pointing-hand cursor coordinator backed by `CursorStackState`.
/// Prevents macOS global `NSCursor.push()` / `NSCursor.pop()` imbalance when overlapping hover
/// regions fire out of order or views unmount mid-hover.
@MainActor
final class PointingCursorCoordinator {
    static let shared = PointingCursorCoordinator()

    private var state = CursorStackState()

    func setPointing(_ active: Bool, token: String) {
        switch state.setActive(active, token: token) {
        case .none:
            break
        case .pushPointingHand:
            NSCursor.pointingHand.push()
        case .popPointingHand:
            NSCursor.pop()
        }
    }

    func releaseAll() {
        if state.releaseAll() == .popPointingHand {
            NSCursor.pop()
        }
    }
}

/// Bounded LRU cache of pre-rendered 2x Retina NSImages for heavy static Canvas artwork
/// (10,000-dot stipple clouds, 12-band Marching Squares contours, 6-stratum rock lithologies).
/// Renders ONCE via SwiftUI ImageRenderer and blits as a native GPU texture (~0.03ms) across
/// every subsequent hover, scroll, tab switch, and Notch open/close without CAMetalLayer stalls.
@MainActor
final class TelemetryArtworkCache {
    static let shared = TelemetryArtworkCache()

    private var entries: [AnyHashable: NSImage] = [:]
    private var order: [AnyHashable] = []
    private let maxEntries = 24

    func image<K: Hashable, V: View>(
        for key: K,
        size: CGSize,
        @ViewBuilder content: () -> V
    ) -> NSImage? {
        guard size.width >= 2, size.height >= 2 else { return nil }
        let box = AnyHashable(key)
        if let hit = entries[box] {
            if let idx = order.firstIndex(of: box) {
                order.remove(at: idx)
                order.append(box)
            }
            return hit
        }
        let renderer = ImageRenderer(
            content: content()
                .frame(width: size.width, height: size.height)
                .environment(\.telemetryStaticRender, true)
        )
        renderer.scale = 2.0
        guard let img = renderer.nsImage else { return nil }
        entries[box] = img
        order.removeAll { $0 == box }
        order.append(box)
        while order.count > maxEntries {
            let evicted = order.removeFirst()
            entries.removeValue(forKey: evicted)
        }
        return img
    }
}

/// Renders a heavy static Canvas artwork once into `TelemetryArtworkCache` at 2x Retina scale
/// and blits the cached `NSImage` on all subsequent opens, tab switches, and hovers.
/// Falls back directly to live vector rendering during `ImageRenderer` export snapshots.
struct CachedTelemetryArtwork<Key: Hashable, Content: View>: View {
    let key: Key
    let width: CGFloat
    let height: CGFloat
    let content: () -> Content

    @Environment(\.telemetryStaticRender) private var isStaticRender

    private struct SizedKey: Hashable {
        let key: Key
        let wPx: Int
        let hPx: Int
    }

    init(
        key: Key,
        width: CGFloat,
        height: CGFloat,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.key = key
        self.width = width
        self.height = height
        self.content = content
    }

    var body: some View {
        if isStaticRender || width < 2 || height < 2 {
            content()
                .frame(width: width, height: height)
        } else {
            let sizedKey = SizedKey(
                key: key,
                wPx: Int((width * 2.0).rounded()),
                hPx: Int((height * 2.0).rounded())
            )
            if let img = TelemetryArtworkCache.shared.image(
                for: sizedKey,
                size: CGSize(width: width, height: height),
                content: content
            ) {
                Image(nsImage: img)
                    .resizable()
                    .frame(width: width, height: height)
            } else {
                content()
                    .frame(width: width, height: height)
            }
        }
    }
}

extension View {
    /// Retained as an intentional no-op: heavy static Canvases now use `CachedTelemetryArtwork`
    /// instead of `.drawingGroup()` to avoid CAMetalLayer creation hitches on Notch open / tab switch.
    @ViewBuilder
    func telemetryRasterized(_ enabled: Bool) -> some View {
        self
    }
}

/// Oscilloscope / blueprint 1px dot graticule background rendered cleanly in Canvas.
struct DotGraticuleBackground: View {
    var spacing: CGFloat = 10
    @Environment(\.agyTheme) private var theme

    var body: some View {
        Canvas { context, size in
            let color = theme.hairline.opacity(0.65)
            var dots = Path()
            var y: CGFloat = spacing * 0.5
            while y < size.height {
                var x: CGFloat = spacing * 0.5
                while x < size.width {
                    dots.addRect(CGRect(x: x, y: y, width: 1, height: 1))
                    x += spacing
                }
                y += spacing
            }
            if !dots.isEmpty {
                context.fill(dots, with: .color(color))
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
            var dots = Path()
            var row = 0
            var y = rect.minY + 0.5
            while y < rect.maxY {
                let offset: CGFloat = (row % 2 == 0) ? 0.5 : 2.0
                var x = rect.minX + offset
                while x < rect.maxX {
                    dots.addRect(CGRect(x: x, y: y, width: 1.2, height: 1.2))
                    x += step
                }
                row += 1
                y += step * 0.85
            }
            if !dots.isEmpty {
                layer.fill(dots, with: .color(color))
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

            var litTicks = Path()
            var dimTicks = Path()
            for i in 0..<ticks {
                let isMajor = (i % 15 == 0 || i == ticks - 1)
                let tickH: CGFloat = isMajor ? (barBottom - topPad) : (barBottom - topPad) * 0.66
                let y = barBottom - tickH
                let x = CGFloat(i) * step + (step - tickW) * 0.5
                let rect = CGRect(x: x, y: y, width: tickW, height: tickH)
                if i < filledCount {
                    litTicks.addRect(rect)
                } else {
                    dimTicks.addRect(rect)
                }
            }
            if !dimTicks.isEmpty {
                context.fill(dimTicks, with: .color(theme.hairlineStrong.opacity(theme.isDark ? 0.55 : 0.48)))
            }
            if !litTicks.isEmpty {
                context.fill(litTicks, with: .color(fillColor))
            }

            if let pace = paceMarkerFraction {
                let pClamped = max(0.02, min(0.98, pace))
                let px = size.width * pClamped
                let markerColor = paceWarning ? theme.signalAmber : theme.inkPrimary

                // Inverted precision index triangle `▼` + calibrated cursor line
                var marker = Path()
                marker.move(to: CGPoint(x: px - 3, y: 0))
                marker.addLine(to: CGPoint(x: px + 3, y: 0))
                marker.addLine(to: CGPoint(x: px, y: 3.5))
                marker.closeSubpath()
                marker.addRect(CGRect(x: px - 0.6, y: 3, width: 1.2, height: barBottom - 2))
                context.fill(marker, with: .color(markerColor))
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
    var weight: Font.Weight = .light
    var accentPrimary: Color? = nil

    @Environment(\.agyTheme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if let p = prefix, !p.isEmpty {
                Text(p)
                    .font(.system(size: size * 0.44, weight: .light, design: .monospaced))
                    .foregroundColor(theme.inkMuted)
                    .padding(.trailing, 2.5)
            }
            Text(whole)
                .font(.system(size: size, weight: weight, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(accentPrimary ?? theme.inkPrimary)
                .contentTransition(.numericText())
            if let f = fraction, !f.isEmpty {
                Text(f)
                    .font(.system(size: size * 0.50, weight: .light, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(accentPrimary?.opacity(0.8) ?? theme.inkSecondary)
                    .contentTransition(.numericText())
            }
            if let s = suffix, !s.isEmpty {
                Text(s)
                    .font(.system(size: size * 0.40, weight: .medium, design: .monospaced))
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
    @Environment(\.telemetryPanelVisible) private var isPanelVisible
    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var body: some View {
        Group {
            switch kind {
            case .busy:
                if reduceMotion || isStaticRender || !isPanelVisible {
                    ZStack {
                        Circle()
                            .stroke(theme.accent.opacity(0.45), lineWidth: 1)
                            .frame(width: 11, height: 11)
                        Circle()
                            .fill(theme.accent)
                            .frame(width: 5.5, height: 5.5)
                    }
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { ctx in
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
    @Environment(\.telemetryPanelVisible) private var isPanelVisible
    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var body: some View {
        Group {
            if isStaticRender || reduceMotion || !isPanelVisible {
                content(opacity: 0.85)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { ctx in
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
    @Environment(\.telemetryPanelVisible) private var isPanelVisible
    @State private var hovering = false
    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var body: some View {
        Group {
            if isLoading && isPanelVisible && !isStaticRender && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { ctx in
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

// MARK: - Telemetry Motion Language (120fps Spring & Directional Tab Transitions)

/// Shared spring curves and transitions for AGY // TELEMETRY tab switches and
/// segmented controls. Respects Reduce Motion and static `ImageRenderer` snapshots.
enum TelemetryMotion {
    static let tabIndicator = Animation.spring(response: 0.26, dampingFraction: 0.84, blendDuration: 0)
    static let tabContent   = Animation.spring(response: 0.28, dampingFraction: 0.88, blendDuration: 0)
    static let panelHeight  = Animation.spring(response: 0.28, dampingFraction: 0.90, blendDuration: 0)
    static let reduced      = Animation.easeOut(duration: 0.14)

    static func tabContentTransition(direction: SlideDirection, reduceMotion: Bool) -> AnyTransition {
        if reduceMotion {
            return .opacity
        }
        let incomingOffset: CGFloat = direction == .forward ? 18 : -18
        return .asymmetric(
            insertion: .opacity
                .combined(with: .offset(x: incomingOffset))
                .combined(with: .scale(scale: 0.992, anchor: .top)),
            removal: .opacity
                .combined(with: .scale(scale: 0.992, anchor: .top))
        )
    }

    static func headerAccessoryTransition(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 3)),
            removal: .opacity.combined(with: .offset(y: -3))
        )
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
/// Active tab uses a whisper-clean tonal plate + 1.5px bottom accent rule instead of heavy solid slabs.
struct TelemetryTabBar: View {
    let items: [DisplayTab]
    @Binding var selection: DisplayTab
    @ObservedObject var sessionStore: SessionStore
    let loc: Localizer

    @Environment(\.agyTheme) private var theme
    @Environment(\.telemetryStaticRender) private var isStaticRender
    @Namespace private var tabNamespace
    @State private var hovered: DisplayTab? = nil
    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    private var indicatorAnimation: Animation? {
        guard !isStaticRender else { return nil }
        return reduceMotion ? TelemetryMotion.reduced : TelemetryMotion.tabIndicator
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(theme.hairline).frame(height: 1)

            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element) { index, tab in
                    let isSelected = (tab == selection)
                    let isHovered = (tab == hovered)
                    let indexLabel = String(format: "%02d", index + 1)
                    let tabRuleColor = theme.tabAccent(index: index)
                    let inactiveIndexColor = theme.isMultiColorSpectrum
                        ? tabRuleColor.opacity(theme.isDark ? 0.78 : 0.72)
                        : theme.accentSecondary.opacity(theme.isDark ? 0.55 : 0.50)

                    HStack(spacing: 3.5) {
                        Text(indexLabel)
                            .font(.system(size: 8, weight: isSelected ? .semibold : .regular, design: .monospaced))
                            .foregroundColor(isSelected ? tabRuleColor : inactiveIndexColor)
                        Text(tab.shortLabel(loc))
                            .font(.system(size: 9.5, weight: isSelected ? .semibold : .regular, design: .monospaced))
                            .tracking(0.4)
                            .foregroundColor(isSelected ? theme.inkPrimary : (isHovered ? theme.inkPrimary.opacity(0.85) : theme.inkSecondary))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        if tab == .session {
                            sessionIndicator(isSelected: isSelected)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 25)
                    .background(
                        ZStack(alignment: .bottom) {
                            if isSelected {
                                Rectangle()
                                    .fill(theme.surfaceRaised.opacity(theme.isDark ? 0.50 : 0.72))
                                    .matchedGeometryEffect(id: "activeTabPlate", in: tabNamespace)
                                Rectangle()
                                    .fill(tabRuleColor)
                                    .frame(height: 1.5)
                                    .matchedGeometryEffect(id: "activeTabRule", in: tabNamespace)
                            } else if isHovered {
                                Rectangle()
                                    .fill(theme.surfaceRaised.opacity(0.42))
                            }
                        }
                    )
                    .contentShape(Rectangle())
                    .onHover { inside in hovered = inside ? tab : (hovered == tab ? nil : hovered) }
                    .onTapGesture {
                        guard selection != tab else { return }
                        withAnimation(indicatorAnimation) {
                            selection = tab
                        }
                    }

                    if index < items.count - 1 {
                        Rectangle().fill(theme.hairline.opacity(0.75)).frame(width: 1)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .animation(indicatorAnimation, value: selection)
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
                reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }

            Rectangle().fill(theme.hairline).frame(height: 1)
        }
    }

    @ViewBuilder
    private func sessionIndicator(isSelected: Bool) -> some View {
        let count = sessionStore.liveCount
        if sessionStore.anyWaiting {
            HStack(spacing: 2) {
                Circle().fill(theme.signalAmber).frame(width: 4, height: 4)
                Text("\(count)")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.signalAmber)
            }
        } else if count > 0 {
            let dotColor: Color = sessionStore.anyBusy
                ? theme.accent
                : (sessionStore.anyDoneUnseen ? theme.signalGreen : theme.inkMuted)
            HStack(spacing: 2) {
                Circle().fill(dotColor).frame(width: 3.5, height: 3.5)
                Text("\(count)")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundColor(isSelected ? theme.inkPrimary : (dotColor == theme.inkMuted ? theme.inkSecondary : dotColor))
            }
        }
    }
}

/// Edge-to-edge sub-tab strip bounded by 1px hairlines (Week / Month / Year).
/// Selected segment uses whisper-light tonal plate + 1.5px bottom accent rule (no heavy solid slab).
struct TelemetrySegmentedStrip<Value: Hashable>: View {
    let items: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    @Environment(\.agyTheme) private var theme
    @Environment(\.telemetryStaticRender) private var isStaticRender
    @Namespace private var stripNamespace
    @State private var hovered: Value? = nil
    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    private var indicatorAnimation: Animation? {
        guard !isStaticRender else { return nil }
        return reduceMotion ? TelemetryMotion.reduced : TelemetryMotion.tabIndicator
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element) { index, item in
                    let isSelected = (item == selection)
                    let isHovered = (item == hovered)

                    Text(label(item).uppercased())
                        .font(.system(size: 9.5, weight: isSelected ? .semibold : .regular, design: .monospaced))
                        .tracking(0.8)
                        .foregroundColor(
                            isSelected
                                ? theme.inkPrimary
                                : (isHovered ? theme.inkPrimary.opacity(0.85) : theme.inkSecondary)
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background(
                            ZStack(alignment: .bottom) {
                                if isSelected {
                                    Rectangle()
                                        .fill(theme.surfaceRaised.opacity(theme.isDark ? 0.45 : 0.68))
                                        .matchedGeometryEffect(id: "subPlate", in: stripNamespace)
                                    Rectangle()
                                        .fill(theme.accent)
                                        .frame(height: 1.5)
                                        .matchedGeometryEffect(id: "subRule", in: stripNamespace)
                                } else if isHovered {
                                    Rectangle()
                                        .fill(theme.surfaceRaised.opacity(0.42))
                                }
                            }
                        )
                        .contentShape(Rectangle())
                        .onHover { inside in hovered = inside ? item : (hovered == item ? nil : hovered) }
                        .onTapGesture {
                            guard selection != item else { return }
                            withAnimation(indicatorAnimation) {
                                selection = item
                            }
                        }

                    if index < items.count - 1 {
                        Rectangle().fill(theme.hairline.opacity(0.75)).frame(width: 1)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .animation(indicatorAnimation, value: selection)
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
                reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }

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
