import SwiftUI
import AppKit
import QuartzCore

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

private struct TelemetryReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

private struct PopoverHostScreenHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var localizer: Localizer {
        get { self[LocalizerKey.self] }
        set { self[LocalizerKey.self] = newValue }
    }

    var telemetryReduceMotion: Bool {
        get { self[TelemetryReduceMotionKey.self] }
        set { self[TelemetryReduceMotionKey.self] = newValue }
    }

    var popoverHostScreenHeight: CGFloat? {
        get { self[PopoverHostScreenHeightKey.self] }
        set { self[PopoverHostScreenHeightKey.self] = newValue }
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

    @Environment(\.telemetryReduceMotion) private var reduceMotion
    @Environment(\.telemetryStaticRender) private var isStaticRender

    fileprivate static let levitatePeriod: Double = 1.8
    fileprivate static let breathePeriod: Double = 2.6

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
        if isStaticRender || visualState.animation == .idle {
            logoMark
        } else {
            CoreAnimationLogoView(
                mode: visualState.animation,
                size: size,
                color: color
            )
            .frame(width: size, height: size)
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
    }
}

/// Pure GPU-composited Core Animation logo renderer for `.levitate` and `.breatheOpacity`.
/// Runs entirely on the WindowServer GPU with 0 main-thread frame ticks and 0 AppKit layout passes.
private struct CoreAnimationLogoView: NSViewRepresentable {
    let mode: LogoAnimationMode
    let size: CGFloat
    let color: Color

    func makeNSView(context: Context) -> CoreAnimationLogoNSView {
        let view = CoreAnimationLogoNSView(size: size)
        view.configure(mode: mode, size: size, color: color)
        return view
    }

    func updateNSView(_ nsView: CoreAnimationLogoNSView, context: Context) {
        nsView.configure(mode: mode, size: size, color: color)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: CoreAnimationLogoNSView,
        context: Context
    ) -> CGSize? {
        CGSize(width: size, height: size)
    }

    static func dismantleNSView(_ nsView: CoreAnimationLogoNSView, coordinator: ()) {
        nsView.stopAllAnimations()
    }
}

private final class CoreAnimationLogoNSView: NSView {
    private static let shadowAnimKey = "agy.logo.shadow"
    private static let levitateAnimKey = "agy.logo.levitate"
    private static let sheenAnimKey = "agy.logo.sheen"
    private static let breatheAnimKey = "agy.logo.breathe"

    private static let sheenColors: [CGColor] = [
        NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.0).cgColor,
        NSColor(srgbRed: 0.45, green: 0.88, blue: 1.0, alpha: 0.85).cgColor,
        NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.95).cgColor,
        NSColor(srgbRed: 0.45, green: 0.88, blue: 1.0, alpha: 0.85).cgColor,
        NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.0).cgColor,
    ]
    private static let sheenLocations: [NSNumber] = [0.0, 0.35, 0.50, 0.65, 1.0]

    private let shadowLayer = CAShapeLayer()
    private let logoContainerLayer = CALayer()
    private let baseLogoLayer = CAShapeLayer()
    private let sheenHostLayer = CALayer()
    private let sheenMaskLayer = CAShapeLayer()
    private let sheenGradientLayer = CAGradientLayer()

    private var logoSize: CGFloat
    private var appliedMode: LogoAnimationMode = .idle
    private var appliedSize: CGFloat = 0
    private var appliedSwiftUIColor: Color?
    private var appliedCGColor: CGColor?
    private var animationsInstalled = false

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: logoSize, height: logoSize)
    }

    init(size: CGFloat) {
        self.logoSize = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setupLayerHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        shadowLayer.removeAllAnimations()
        logoContainerLayer.removeAllAnimations()
        baseLogoLayer.removeAllAnimations()
        sheenGradientLayer.removeAllAnimations()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func removeFromSuperview() {
        stopAllAnimations()
        super.removeFromSuperview()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            stopAllAnimations()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        syncContentsScale()
        if appliedMode != .idle && !animationsInstalled {
            applyAnimations(for: appliedMode, size: appliedSize)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncContentsScale()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard let color = appliedSwiftUIColor else { return }
        let resolved = resolvedCGColor(for: color)
        guard !Self.cgColorsEqual(resolved, appliedCGColor) else { return }
        appliedCGColor = resolved
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowLayer.fillColor = resolved
        baseLogoLayer.fillColor = resolved
        CATransaction.commit()
    }

    func configure(mode: LogoAnimationMode, size: CGFloat, color: Color) {
        let resolved = resolvedCGColor(for: color)
        let modeChanged = (mode != appliedMode)
        let sizeChanged = abs(size - appliedSize) > 0.01
        let colorChanged = !Self.cgColorsEqual(resolved, appliedCGColor)

        appliedSwiftUIColor = color

        // Fast-path: identical (mode, size, cgColor) — never restart running GPU animations.
        if !modeChanged && !sizeChanged && !colorChanged {
            if mode != .idle && !animationsInstalled && window != nil {
                applyAnimations(for: mode, size: size)
            }
            return
        }

        // Color-only update: tint layers atomically without disrupting running animations.
        if !modeChanged && !sizeChanged && colorChanged {
            appliedCGColor = resolved
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shadowLayer.fillColor = resolved
            baseLogoLayer.fillColor = resolved
            CATransaction.commit()
            return
        }

        if abs(size - logoSize) > 0.01 {
            logoSize = size
            invalidateIntrinsicContentSize()
        }

        appliedMode = mode
        appliedSize = size
        appliedCGColor = resolved

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if sizeChanged {
            updateGeometry(for: size)
        }

        shadowLayer.fillColor = resolved
        baseLogoLayer.fillColor = resolved

        switch mode {
        case .levitate:
            shadowLayer.isHidden = false
            shadowLayer.opacity = 0.75
            baseLogoLayer.opacity = 0.84
            sheenHostLayer.isHidden = false
            applyAnimations(for: .levitate, size: size)

        case .breatheOpacity:
            shadowLayer.isHidden = true
            sheenHostLayer.isHidden = true
            baseLogoLayer.opacity = 1.0
            applyAnimations(for: .breatheOpacity, size: size)

        case .idle:
            stopAllAnimations()
            shadowLayer.isHidden = true
            sheenHostLayer.isHidden = true
            baseLogoLayer.opacity = 1.0
        }

        CATransaction.commit()
    }

    func stopAllAnimations() {
        shadowLayer.removeAllAnimations()
        logoContainerLayer.removeAllAnimations()
        baseLogoLayer.removeAllAnimations()
        sheenGradientLayer.removeAllAnimations()
        animationsInstalled = false
    }

    private func setupLayerHierarchy() {
        guard let root = self.layer else { return }
        let disabledActions: [String: CAAction] = [
            "bounds": NSNull(),
            "position": NSNull(),
            "transform": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull(),
            "fillColor": NSNull(),
            "path": NSNull(),
            "sublayers": NSNull(),
        ]

        root.masksToBounds = false
        root.actions = disabledActions

        shadowLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        shadowLayer.actions = disabledActions

        logoContainerLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        logoContainerLayer.masksToBounds = false
        logoContainerLayer.actions = disabledActions

        baseLogoLayer.actions = disabledActions

        sheenHostLayer.masksToBounds = false
        sheenHostLayer.actions = disabledActions

        sheenMaskLayer.fillColor = NSColor.white.cgColor
        sheenMaskLayer.actions = disabledActions
        sheenHostLayer.mask = sheenMaskLayer

        sheenGradientLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        sheenGradientLayer.colors = Self.sheenColors
        sheenGradientLayer.locations = Self.sheenLocations
        sheenGradientLayer.startPoint = CGPoint(x: 0.5, y: 1.0)
        sheenGradientLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
        sheenGradientLayer.actions = disabledActions
        sheenHostLayer.addSublayer(sheenGradientLayer)

        logoContainerLayer.addSublayer(baseLogoLayer)
        logoContainerLayer.addSublayer(sheenHostLayer)

        root.addSublayer(shadowLayer)
        root.addSublayer(logoContainerLayer)

        syncContentsScale()
    }

    private func updateGeometry(for size: CGFloat) {
        let fullRect = CGRect(x: 0, y: 0, width: size, height: size)
        // Flipped NSView gives the root layer top-down coordinates (`isGeometryFlipped == true`),
        // so `flippedForCoreAnimation: false` renders the logo right-side up.
        let logoPath = AGYLogo.cgPath(in: fullRect, flippedForCoreAnimation: false)

        let capW = size * 0.28
        let capH = max(1.3, size * 0.085)
        let capBounds = CGRect(x: 0, y: 0, width: capW, height: capH)
        shadowLayer.bounds = capBounds
        shadowLayer.position = CGPoint(x: size * 0.5, y: size * 0.5 + size * 0.28)
        shadowLayer.path = CGPath(
            roundedRect: capBounds,
            cornerWidth: capH * 0.5,
            cornerHeight: capH * 0.5,
            transform: nil
        )

        logoContainerLayer.bounds = fullRect
        logoContainerLayer.position = CGPoint(x: size * 0.5, y: size * 0.5)

        baseLogoLayer.frame = fullRect
        baseLogoLayer.path = logoPath

        sheenHostLayer.frame = fullRect
        sheenMaskLayer.frame = fullRect
        sheenMaskLayer.path = logoPath

        sheenGradientLayer.bounds = CGRect(x: 0, y: 0, width: size, height: size * 0.76)
        sheenGradientLayer.position = CGPoint(x: size * 0.5, y: size * 1.35)
    }

    private func applyAnimations(for mode: LogoAnimationMode, size: CGFloat) {
        stopAllAnimations()
        guard size > 0 else { return }

        switch mode {
        case .levitate:
            let period = SessionAwareLogo.levitatePeriod
            let linear = CAMediaTimingFunction(name: .linear)

            // 1. Ground shadow capsule: X-scale 1.0 -> 0.65, drift down +0.28h -> +0.44h, fade 0.75 -> 0
            let shadowScaleX = CABasicAnimation(keyPath: "transform.scale.x")
            shadowScaleX.fromValue = 1.0
            shadowScaleX.toValue = 0.65

            let shadowDriftY = CABasicAnimation(keyPath: "transform.translation.y")
            shadowDriftY.fromValue = 0.0
            shadowDriftY.toValue = size * 0.16

            let shadowOpacity = CABasicAnimation(keyPath: "opacity")
            shadowOpacity.fromValue = 0.75
            shadowOpacity.toValue = 0.0

            let shadowGroup = CAAnimationGroup()
            shadowGroup.animations = [shadowScaleX, shadowDriftY, shadowOpacity]
            shadowGroup.duration = period
            shadowGroup.repeatCount = .infinity
            shadowGroup.timingFunction = linear
            shadowGroup.isRemovedOnCompletion = false
            shadowLayer.add(shadowGroup, forKey: Self.shadowAnimKey)

            // 2. Levitating logo container: smooth sine wave translation.y & scale
            let sampleCount = 16
            var keyTimes: [NSNumber] = []
            var yValues: [NSNumber] = []
            var scaleValues: [NSNumber] = []
            keyTimes.reserveCapacity(sampleCount + 1)
            yValues.reserveCapacity(sampleCount + 1)
            scaleValues.reserveCapacity(sampleCount + 1)
            for i in 0...sampleCount {
                let progress = Double(i) / Double(sampleCount)
                let wave = sin(2.0 * Double.pi * progress)
                keyTimes.append(NSNumber(value: progress))
                yValues.append(NSNumber(value: Double(-size * 0.08) * wave))
                scaleValues.append(NSNumber(value: 1.0 + 0.04 * wave))
            }

            let floatY = CAKeyframeAnimation(keyPath: "transform.translation.y")
            floatY.values = yValues
            floatY.keyTimes = keyTimes

            let floatScale = CAKeyframeAnimation(keyPath: "transform.scale")
            floatScale.values = scaleValues
            floatScale.keyTimes = keyTimes

            let levitateGroup = CAAnimationGroup()
            levitateGroup.animations = [floatY, floatScale]
            levitateGroup.duration = period
            levitateGroup.repeatCount = .infinity
            levitateGroup.timingFunction = linear
            levitateGroup.isRemovedOnCompletion = false
            logoContainerLayer.add(levitateGroup, forKey: Self.levitateAnimKey)

            // 3. Upward optical sheen swept across the logo mask every 1.8s
            let sheenSweep = CABasicAnimation(keyPath: "position.y")
            sheenSweep.fromValue = size * 1.35
            sheenSweep.toValue = -size * 0.35
            sheenSweep.duration = period
            sheenSweep.repeatCount = .infinity
            sheenSweep.timingFunction = linear
            sheenSweep.isRemovedOnCompletion = false
            sheenGradientLayer.add(sheenSweep, forKey: Self.sheenAnimKey)

            animationsInstalled = true

        case .breatheOpacity:
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 0.55
            breathe.toValue = 1.0
            breathe.duration = SessionAwareLogo.breathePeriod * 0.5
            breathe.autoreverses = true
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            breathe.repeatCount = .infinity
            breathe.isRemovedOnCompletion = false
            baseLogoLayer.add(breathe, forKey: Self.breatheAnimKey)

            animationsInstalled = true

        case .idle:
            break
        }
    }

    private func syncContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        layer?.contentsScale = scale
        shadowLayer.contentsScale = scale
        logoContainerLayer.contentsScale = scale
        baseLogoLayer.contentsScale = scale
        sheenHostLayer.contentsScale = scale
        sheenMaskLayer.contentsScale = scale
        sheenGradientLayer.contentsScale = scale
    }

    private func resolvedCGColor(for swiftUIColor: Color) -> CGColor {
        let nsColor = NSColor(swiftUIColor)
        var resolved = nsColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = nsColor.usingColorSpace(.sRGB)?.cgColor ?? nsColor.cgColor
        }
        return resolved
    }

    private static func cgColorsEqual(_ lhs: CGColor?, _ rhs: CGColor?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (a?, b?):
            guard let ca = a.components, let cb = b.components, ca.count == cb.count else {
                return a == b
            }
            for i in 0..<ca.count where abs(ca[i] - cb[i]) > 0.001 {
                return false
            }
            return true
        default:
            return false
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

    private var lru = BoundedLRUState<AnyHashable, NSImage>(maxEntries: 16)
    private let memoryPressureSource: DispatchSourceMemoryPressure

    init() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        self.memoryPressureSource = source
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let event = self.memoryPressureSource.data
                if event.contains(.critical) {
                    self.clear()
                } else if event.contains(.warning) {
                    self.trim(to: 4)
                }
            }
        }
        source.resume()
    }

    deinit {
        memoryPressureSource.cancel()
    }

    func trim(to maxCount: Int) {
        lru.trim(to: maxCount)
    }

    func clear() {
        lru.removeAll()
    }

    func image<K: Hashable, V: View>(
        for key: K,
        size: CGSize,
        @ViewBuilder content: () -> V
    ) -> NSImage? {
        guard size.width >= 2, size.height >= 2 else { return nil }
        let box = AnyHashable(key)
        if let hit = lru.get(box) {
            return hit
        }
        let renderer = ImageRenderer(
            content: content()
                .frame(width: size.width, height: size.height)
                .environment(\.telemetryStaticRender, true)
        )
        renderer.scale = 2.0
        guard let img = renderer.nsImage else { return nil }
        lru.set(img, for: box)
        return img
    }
}

/// Safe finite `Double` → `Int` conversion that never traps on `NaN`, `Inf`, or out-of-range values.
@inline(__always)
func safeRoundedInt(
    _ value: Double,
    min minVal: Int = -1_000_000_000_000_000,
    max maxVal: Int = 1_000_000_000_000_000
) -> Int {
    guard value.isFinite else { return 0 }
    let rounded = value.rounded()
    if rounded <= Double(minVal) { return minVal }
    if rounded >= Double(maxVal) { return maxVal }
    return Int(rounded)
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
        let hasValidBounds = width.isFinite && height.isFinite
            && width >= 2 && height >= 2
            && width <= 8192 && height <= 8192
        if isStaticRender || !hasValidBounds {
            content()
                .frame(
                    width: width.isFinite ? max(0, width) : 0,
                    height: height.isFinite ? max(0, height) : 0
                )
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
    @Environment(\.telemetryStaticRender) private var isStaticRender
    @Environment(\.telemetryReduceMotion) private var reduceMotion

    var body: some View {
        let numericTransition: ContentTransition = (isStaticRender || reduceMotion) ? .identity : .numericText()
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
                .contentTransition(numericTransition)
            if let f = fraction, !f.isEmpty {
                Text(f)
                    .font(.system(size: size * 0.50, weight: .light, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(accentPrimary?.opacity(0.8) ?? theme.inkSecondary)
                    .contentTransition(numericTransition)
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
    @Environment(\.telemetryReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch kind {
            case .busy:
                if !TelemetryAnimationGate.shouldAnimate(
                    panelVisible: isPanelVisible,
                    reduceMotion: reduceMotion,
                    staticRender: isStaticRender
                ) {
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
    }
}

struct TelemetrySkeleton: View {
    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @Environment(\.telemetryStaticRender) private var isStaticRender
    @Environment(\.telemetryPanelVisible) private var isPanelVisible
    @Environment(\.telemetryReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if !TelemetryAnimationGate.shouldAnimate(
                panelVisible: isPanelVisible,
                reduceMotion: reduceMotion,
                staticRender: isStaticRender
            ) {
                content(opacity: 0.85)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { ctx in
                    let wave = (sin(ctx.date.timeIntervalSinceReferenceDate * 3.5) + 1) / 2
                    content(opacity: 0.45 + 0.45 * wave)
                }
            }
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(helpText)
            .accessibilityAddTraits(.isButton)
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
    @Environment(\.telemetryReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Group {
            if TelemetryAnimationGate.shouldAnimate(
                active: isLoading,
                panelVisible: isPanelVisible,
                reduceMotion: reduceMotion,
                staticRender: isStaticRender
            ) {
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(helpText)
        .accessibilityAddTraits(.isButton)
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
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
    static let tabIndicator        = Animation.spring(response: 0.26, dampingFraction: 0.84, blendDuration: 0)
    static let popoverTabIndicator = Animation.spring(response: 0.22, dampingFraction: 0.96, blendDuration: 0)
    static let tabContent          = Animation.spring(response: 0.28, dampingFraction: 0.88, blendDuration: 0)
    static let popoverTabContent   = Animation.timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.18)
    static let panelHeight         = Animation.spring(response: 0.28, dampingFraction: 0.90, blendDuration: 0)
    static let reduced             = Animation.easeOut(duration: 0.14)

    static func tabContentTransition(
        direction: SlideDirection,
        isNotch: Bool = true,
        reduceMotion: Bool
    ) -> AnyTransition {
        if reduceMotion {
            return .opacity
        }
        if !isNotch {
            let incomingOffset: CGFloat = direction == .forward ? 10 : -10
            return .asymmetric(
                insertion: .opacity.combined(with: .offset(x: incomingOffset)),
                removal: .opacity
            )
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

    func accessibilityTitle(_ loc: Localizer) -> String {
        switch self {
        case .cost:         return loc("cost")
        case .tokens:       return loc("tokens")
        case .time:         return loc("timeTab")
        case .session:      return loc("sessionTab")
        case .subscription: return loc("subTab")
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
    @Environment(\.telemetryReduceMotion) private var reduceMotion
    @Namespace private var tabNamespace
    @State private var hovered: DisplayTab? = nil

    private var indicatorAnimation: Animation? {
        guard !isStaticRender else { return nil }
        if reduceMotion { return TelemetryMotion.reduced }
        return theme.isNotch ? TelemetryMotion.tabIndicator : TelemetryMotion.popoverTabIndicator
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
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(tab.accessibilityTitle(loc))
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                    .onHover { inside in hovered = inside ? tab : (hovered == tab ? nil : hovered) }
                    .onTapGesture {
                        guard selection != tab else { return }
                        selection = tab
                    }

                    if index < items.count - 1 {
                        Rectangle().fill(theme.hairline.opacity(0.75)).frame(width: 1)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .animation(indicatorAnimation, value: selection)

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
    @Environment(\.telemetryReduceMotion) private var reduceMotion
    @Namespace private var stripNamespace
    @State private var hovered: Value? = nil

    private var indicatorAnimation: Animation? {
        guard !isStaticRender else { return nil }
        if reduceMotion { return TelemetryMotion.reduced }
        return theme.isNotch ? TelemetryMotion.tabIndicator : TelemetryMotion.popoverTabIndicator
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
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(label(item))
                        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                        .onHover { inside in hovered = inside ? item : (hovered == item ? nil : hovered) }
                        .onTapGesture {
                            guard selection != item else { return }
                            selection = item
                        }

                    if index < items.count - 1 {
                        Rectangle().fill(theme.hairline.opacity(0.75)).frame(width: 1)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .animation(indicatorAnimation, value: selection)

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
