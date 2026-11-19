import SwiftUI
import AppKit

// MARK: - Notch UI (SwiftUI layer)
//
// ONE fixed-size transparent window; inside it ONE shared black+clip layer wrapping
// BOTH states. The black's size is intrinsic (it hugs its content), so opening —
// swapping from the compact pill to PopoverView — animates the black growing out of
// the notch. macOS 13 safe.

// MARK: - NotchShape

/// The notch silhouette. Top corners curve inward and the side walls are inset by
/// `topCornerRadius` from the bounding box. `animatableData` rides the radii.
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
    static let open  = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
    static let close = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
    static let reduced = Animation.linear(duration: 0.12)
}

/// Hysteresis timings used by the AppKit controller.
enum NotchTiming {
    static let openDwell:  TimeInterval = 0.18
    static let closeGrace: TimeInterval = 0.12
}

// MARK: - Content size measurement (for the controller's hit-testing only)

private struct NotchContentSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let n = nextValue()
        if n != .zero { value = n }
    }
}

private struct NotchValueWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let n = nextValue()
        if n > 0 { value = n }
    }
}

// MARK: - Shared view model

/// Owned by NotchController, observed by NotchRootView.
final class NotchViewModel: ObservableObject {
    @Published var isOpen: Bool = false
    @Published var contentSize: CGSize = .zero
    @Published var closedNotchSize: CGSize = .zero
    @Published var isSynthetic: Bool = false

    var onAcquireModalLock: ((NotchModalLock) -> Void)?
    var onReleaseModalLock: ((NotchModalLock) -> Void)?

    func acquireModalLock(_ lock: NotchModalLock) { onAcquireModalLock?(lock) }
    func releaseModalLock(_ lock: NotchModalLock) { onReleaseModalLock?(lock) }
}

// MARK: - Environment plumbing for the shared footer menus

private struct NotchViewModelKey: EnvironmentKey {
    static let defaultValue: NotchViewModel? = nil
}

extension EnvironmentValues {
    var notchViewModel: NotchViewModel? {
        get { self[NotchViewModelKey.self] }
        set { self[NotchViewModelKey.self] = newValue }
    }
}

// MARK: - COMPACT content (the idle pill): icon hugs left shoulder, value hugs right

/// Intrinsic-width pill: Antigravity logo just left of the notch, value just right,
/// with the physical-notch-width clear gap between them.
struct CompactNotchView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var sessionStore: SessionStore
    var notchWidth: CGFloat
    var notchHeight: CGFloat

    static let iconBlockWidth: CGFloat = 14 + 16 + 10
    static let innerPad: CGFloat = 10
    static let outerPad: CGFloat = 14

    var body: some View {
        HStack(spacing: 0) {
            SessionAwareLogo(sessionStore: sessionStore,
                             size: 16, color: .agyBrand, dotSize: 5)
                .padding(.leading, Self.outerPad)
                .padding(.trailing, Self.innerPad)

            // The physical notch (real black camera housing) sits in this gap.
            Color.clear.frame(width: max(8, notchWidth))

            Text(store.menuBarValue)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.white)
                .lineLimit(1)
                .fixedSize()
                .background(GeometryReader { geo in
                    Color.clear.preference(key: NotchValueWidthKey.self, value: geo.size.width)
                })
                .padding(.leading, Self.innerPad)
                .padding(.trailing, Self.outerPad)
        }
        .frame(height: max(24, notchHeight))
        .fixedSize()
    }
}

// MARK: - Root notch view (one shared black layer that GROWS from the notch)

struct NotchRootView: View {
    @ObservedObject var store: UsageStore
    // Plain `let`, NOT @ObservedObject: NotchRootView only forwards this down to
    // CompactNotchView (which observes it itself), avoiding 2s churn on PopoverView.
    let sessionStore: SessionStore
    @ObservedObject var vm: NotchViewModel
    let onQuit: () -> Void

    private let hMargin: CGFloat = 18
    private let notchHeaderGap: CGFloat = 6
    private let popoverInnerTopPadding: CGFloat = 14
    private let bottomMargin: CGFloat = 14

    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @State private var valueWidth: CGFloat = 0

    private var compactGapOffset: CGFloat {
        let valueBlock = CompactNotchView.innerPad + valueWidth + CompactNotchView.outerPad
        return (valueBlock - CompactNotchView.iconBlockWidth) / 2
    }

    var body: some View {
        VStack(spacing: 0) {
            if vm.isOpen {
                PopoverView(store: store, onQuit: onQuit)
                    .environment(\.notchViewModel, vm)
                    .fixedSize()
                    .padding(.horizontal, hMargin)
                    .padding(.top, max(8, vm.closedNotchSize.height
                                          + notchHeaderGap - popoverInnerTopPadding))
                    .padding(.bottom, bottomMargin)
                    .transition(reduceMotion
                        ? .opacity
                        : .scale(scale: 0.9, anchor: .top).combined(with: .opacity))
            } else {
                CompactNotchView(store: store,
                                 sessionStore: sessionStore,
                                 notchWidth: vm.closedNotchSize.width,
                                 notchHeight: vm.closedNotchSize.height)
            }
        }
        .background(GeometryReader { geo in
            Color.black.preference(key: NotchContentSizeKey.self, value: geo.size)
        })
        .clipShape(NotchShape(
            topCornerRadius: vm.isOpen ? NotchShape.open.top : NotchShape.closed.top,
            bottomCornerRadius: vm.isOpen ? NotchShape.open.bottom
                                          : (vm.isSynthetic ? 16 : NotchShape.closed.bottom)))
        .offset(x: vm.isOpen ? 0 : compactGapOffset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(currentAnimation, value: vm.isOpen)
        .animation(reduceMotion ? NotchAnimations.reduced : NotchAnimations.open, value: store.selectedTab)
        .preferredColorScheme(.dark)
        .onPreferenceChange(NotchContentSizeKey.self) { size in
            if size != .zero { vm.contentSize = size }
        }
        .onPreferenceChange(NotchValueWidthKey.self) { w in
            if w > 0 { valueWidth = w }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }

    private var currentAnimation: Animation? {
        if reduceMotion { return NotchAnimations.reduced }
        return vm.isOpen ? NotchAnimations.open : NotchAnimations.close
    }
}
