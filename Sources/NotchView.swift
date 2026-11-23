import SwiftUI
import AppKit

// MARK: - Notch UI (SwiftUI layer)
//
// Pure OLED black obsidian void with 1px precision outline and sharp inverted
// Live Activity Wing action pills. macOS 13 safe.

// MARK: - NotchShape

struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    static let closed: (top: CGFloat, bottom: CGFloat) = (6, 11)
    static let open: (top: CGFloat, bottom: CGFloat) = (11, 19)

    init(topCornerRadius: CGFloat? = nil, bottomCornerRadius: CGFloat? = nil) {
        self.topCornerRadius = topCornerRadius ?? NotchShape.closed.top
        self.bottomCornerRadius = bottomCornerRadius ?? NotchShape.closed.bottom
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        return path
    }
}

// MARK: - Animation constants

enum NotchAnimations {
    static let open  = Animation.spring(response: 0.40, dampingFraction: 0.82, blendDuration: 0)
    static let close = Animation.spring(response: 0.44, dampingFraction: 0.98, blendDuration: 0)
    static let reduced = Animation.linear(duration: 0.12)
}

// MARK: - Measurement keys

private struct NotchContentSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let n = nextValue()
        if n != .zero { value = n }
    }
}

private struct NotchLeftWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let n = nextValue()
        if n > 0 { value = n }
    }
}

private struct NotchRightWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let n = nextValue()
        if n > 0 { value = n }
    }
}

// MARK: - Shared view model

final class NotchViewModel: ObservableObject {
    @Published var isOpen: Bool = false
    @Published var isPanelShown: Bool = false
    @Published var closedNotchSize: CGSize = .zero
    @Published var isSynthetic: Bool = false
    @Published var activeWing: NotchWingKind? = nil
    @Published var screenVisibleHeight: CGFloat? = nil

    /// AppKit geometry readouts consumed only by NotchController — intentionally NOT @Published
    /// so PreferenceKey updates during spring animations never trigger SwiftUI body rebuild storms.
    /// Separates closed-pill and expanded-popover dimensions so closing the notch can never feed
    /// expanded dimensions into `closedWingRect` hit-testing.
    var geometry = NotchGeometryState()

    var onGeometryChanged: (() -> Void)?
    var onAcquireModalLock: ((NotchModalLock) -> Void)?
    var onReleaseModalLock: ((NotchModalLock) -> Void)?
    var onTapWing: ((String) -> Void)?
    var onRequestClose: (() -> Void)?

    func acquireModalLock(_ lock: NotchModalLock) { onAcquireModalLock?(lock) }
    func releaseModalLock(_ lock: NotchModalLock) { onReleaseModalLock?(lock) }
}

private struct NotchViewModelKey: EnvironmentKey {
    static let defaultValue: NotchViewModel? = nil
}

extension EnvironmentValues {
    var notchViewModel: NotchViewModel? {
        get { self[NotchViewModelKey.self] }
        set { self[NotchViewModelKey.self] = newValue }
    }
}

// MARK: - COMPACT content (Idle Pill + Inverted Live Wing Block)

struct CompactNotchView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var sessionStore: SessionStore
    @ObservedObject var vm: NotchViewModel
    var notchWidth: CGFloat
    var notchHeight: CGFloat

    static let innerPad: CGFloat = 10
    static let outerPad: CGFloat = 14

    private var loc: Localizer { Localizer(language: store.language) }
    private var darkTheme: AGYTheme {
        AGYTheme(preset: store.themePreset, colorScheme: .dark, isNotch: true)
    }

    var body: some View {
        HStack(spacing: 0) {
            leftBlock
                .background(GeometryReader { geo in
                    Color.clear.preference(key: NotchLeftWidthKey.self, value: geo.size.width)
                })

            Color.clear.frame(width: max(8, notchWidth))

            rightBlock
                .background(GeometryReader { geo in
                    Color.clear.preference(key: NotchRightWidthKey.self, value: geo.size.width)
                })
        }
        .frame(height: max(24, notchHeight))
        .fixedSize()
    }

    @ViewBuilder
    private var leftBlock: some View {
        HStack(spacing: 6) {
            SessionAwareLogo(sessionStore: sessionStore,
                             size: 14.5, color: darkTheme.accent, dotSize: 5,
                             isActive: vm.isPanelShown && !vm.isOpen)
            if let wing = vm.activeWing {
                Text(wing.workspace)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(darkTheme.inkPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: 108, alignment: .leading)
            }
        }
        .padding(.leading, Self.outerPad)
        .padding(.trailing, Self.innerPad)
    }

    @ViewBuilder
    private var rightBlock: some View {
        if let wing = vm.activeWing {
            wingButton(wing)
                .padding(.leading, Self.innerPad)
                .padding(.trailing, Self.outerPad)
        } else if sessionStore.liveTPS.shouldShowInNotch {
            workingTPSBlock(sessionStore.liveTPS)
                .padding(.leading, Self.innerPad)
                .padding(.trailing, Self.outerPad)
        } else {
            Text(store.menuBarValue)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(sessionStore.anyWaiting ? darkTheme.signalAmber : darkTheme.inkPrimary)
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, Self.innerPad)
                .padding(.trailing, Self.outerPad)
        }
    }

    private func workingTPSBlock(_ tps: LiveTPSSnapshot) -> some View {
        HStack(spacing: 5) {
            NotchTPSSparkline(
                values: tps.sparkline,
                peak: tps.peakTPS,
                accent: darkTheme.accent
            )
            .frame(width: 24, height: 11)
            Text(LiveTPSTracker.formatCompactTPS(tps.currentTPS))
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(sessionStore.anyWaiting ? darkTheme.signalAmber : darkTheme.inkPrimary)
                .lineLimit(1)
                .frame(minWidth: 44, alignment: .trailing)
                .fixedSize()
        }
        .fixedSize()
    }

    private func wingButton(_ wing: NotchWingKind) -> some View {
        let isWaiting = wing.isWaiting
        let badgeBg: Color = isWaiting ? darkTheme.signalAmber : darkTheme.signalGreen
        let prefix: String = {
            switch wing {
            case .waiting(_, _, _, let needsConfirm):
                return "▲ \(needsConfirm ? loc("badgeConfirm") : loc("badgeInput"))"
            case .done:
                return "● \(loc("badgeDone"))"
            }
        }()
        let surfaceTag = wing.surface.map { " · \($0.uppercased())" } ?? ""

        return HStack(spacing: 4) {
            Text(prefix + surfaceTag + " ↗")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.black)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(badgeBg)
        .fixedSize()
        .contentShape(Rectangle())
        .onTapGesture {
            vm.onTapWing?(wing.sessionId)
        }
    }
}

// MARK: - Mini Working Output TPS Sparkline (OLED-black, zero timers)

private struct NotchTPSSparkline: View, Equatable {
    let values: [Double]
    let peak: Double
    let accent: Color

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            guard w > 4, h > 4 else { return }

            let leftX: CGFloat = 1.0
            let rightX: CGFloat = w - 2.0
            let topY: CGFloat = 2.0
            let bottomY: CGFloat = h - 1.5
            let plotH = max(1.0, bottomY - topY)

            let sanitized = values.map { $0.isFinite ? max(0.0, $0) : 0.0 }
            let scaleMax = max(peak.isFinite ? peak : 0.0, sanitized.max() ?? 0.0, 1.0)

            let points: [CGPoint]
            if sanitized.count >= 2 {
                let spanX = max(1.0, rightX - leftX)
                let denom = CGFloat(sanitized.count - 1)
                points = sanitized.enumerated().map { idx, val in
                    let norm = min(1.0, max(0.0, val / scaleMax))
                    let x = leftX + (CGFloat(idx) / denom) * spanX
                    let y = bottomY - CGFloat(norm) * plotH
                    return CGPoint(x: x, y: y)
                }
            } else if let single = sanitized.first {
                let norm = min(1.0, max(0.0, single / scaleMax))
                let tipY = bottomY - CGFloat(norm) * plotH
                points = [
                    CGPoint(x: leftX, y: bottomY - plotH * 0.15),
                    CGPoint(x: rightX, y: tipY),
                ]
            } else {
                points = [
                    CGPoint(x: leftX, y: bottomY),
                    CGPoint(x: rightX, y: topY + plotH * 0.4),
                ]
            }

            guard let first = points.first, let last = points.last else { return }

            var line = Path()
            line.move(to: first)
            for pt in points.dropFirst() {
                line.addLine(to: pt)
            }

            var fill = line
            fill.addLine(to: CGPoint(x: last.x, y: bottomY))
            fill.addLine(to: CGPoint(x: first.x, y: bottomY))
            fill.closeSubpath()

            ctx.fill(
                fill,
                with: .linearGradient(
                    Gradient(colors: [accent.opacity(0.28), accent.opacity(0.0)]),
                    startPoint: CGPoint(x: 0, y: topY),
                    endPoint: CGPoint(x: 0, y: bottomY)
                )
            )
            ctx.stroke(
                line,
                with: .color(accent),
                style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round)
            )

            // Subtle live tip dot + soft halo
            let haloRect = CGRect(x: last.x - 2.3, y: last.y - 2.3, width: 4.6, height: 4.6)
            ctx.fill(Path(ellipseIn: haloRect), with: .color(accent.opacity(0.32)))
            let dotRect = CGRect(x: last.x - 1.25, y: last.y - 1.25, width: 2.5, height: 2.5)
            ctx.fill(Path(ellipseIn: dotRect), with: .color(accent))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Root notch view (Pure Obsidian Black Void)

struct NotchRootView: View {
    @ObservedObject var store: UsageStore
    let sessionStore: SessionStore
    @ObservedObject var vm: NotchViewModel
    let onQuit: () -> Void

    private let hMargin: CGFloat = 18
    private let notchHeaderGap: CGFloat = 6
    private let popoverInnerTopPadding: CGFloat = 11
    private let bottomMargin: CGFloat = 14

    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @State private var leftWidth: CGFloat = 39
    @State private var rightWidth: CGFloat = 56

    private var darkTheme: AGYTheme {
        AGYTheme(preset: store.themePreset, colorScheme: .dark, isNotch: true)
    }

    private var compactGapOffset: CGFloat {
        (rightWidth - leftWidth) / 2
    }

    private var currentShape: NotchShape {
        NotchShape(
            topCornerRadius: vm.isOpen ? NotchShape.open.top : NotchShape.closed.top,
            bottomCornerRadius: vm.isOpen ? NotchShape.open.bottom
                                          : (vm.isSynthetic ? 16 : NotchShape.closed.bottom)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if vm.isOpen {
                PopoverView(
                    store: store,
                    onQuit: onQuit,
                    onClose: { vm.onRequestClose?() }
                )
                .environment(\.notchViewModel, vm)
                .environment(\.popoverHostScreenHeight, vm.screenVisibleHeight)
                .fixedSize()
                .padding(.horizontal, hMargin)
                .padding(.top, max(8, vm.closedNotchSize.height
                                      + notchHeaderGap - popoverInnerTopPadding))
                .padding(.bottom, bottomMargin)
                .transition(reduceMotion
                    ? .opacity
                    : .scale(scale: 0.94, anchor: .top).combined(with: .opacity))
            } else {
                CompactNotchView(store: store,
                                 sessionStore: sessionStore,
                                 vm: vm,
                                 notchWidth: vm.closedNotchSize.width,
                                 notchHeight: vm.closedNotchSize.height)
            }
        }
        .background(
            ZStack(alignment: .top) {
                Color.black
                GeometryReader { geo in
                    Color.clear.preference(key: NotchContentSizeKey.self, value: geo.size)
                }
            }
        )
        .overlay(
            currentShape.stroke(
                Color.white.opacity(vm.isOpen ? 0.14 : (vm.activeWing != nil ? 0.18 : 0.10)),
                lineWidth: 1
            )
            .allowsHitTesting(false)
        )
        .clipShape(currentShape)
        .offset(x: vm.isOpen ? 0 : compactGapOffset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(currentAnimation, value: vm.isOpen)
        .animation(reduceMotion ? NotchAnimations.reduced : NotchAnimations.open, value: vm.activeWing)
        .preferredColorScheme(.dark)
        .onPreferenceChange(NotchContentSizeKey.self) { size in
            guard size != .zero else { return }
            if vm.geometry.updateContentSize(
                width: Double(size.width),
                height: Double(size.height),
                isOpen: vm.isOpen
            ) {
                vm.onGeometryChanged?()
            }
        }
        .onPreferenceChange(NotchLeftWidthKey.self) { w in
            if w > 0, abs(w - leftWidth) > 0.5 {
                leftWidth = w
                if vm.geometry.updateWingWidths(left: Double(w)) {
                    vm.onGeometryChanged?()
                }
            }
        }
        .onPreferenceChange(NotchRightWidthKey.self) { w in
            if w > 0, abs(w - rightWidth) > 0.5 {
                rightWidth = w
                if vm.geometry.updateWingWidths(right: Double(w)) {
                    vm.onGeometryChanged?()
                }
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        .environment(\.telemetryReduceMotion, reduceMotion)
    }

    private var currentAnimation: Animation? {
        if reduceMotion { return NotchAnimations.reduced }
        return vm.isOpen ? NotchAnimations.open : NotchAnimations.close
    }
}
