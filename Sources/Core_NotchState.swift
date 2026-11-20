import Foundation

// MARK: - Notch Hover, Fullscreen Edge-Reveal & Modal-Lock State Machine — pure core
//
// Explicit deterministic reducer governing per-display notch transitions so AppKit's
// NSEvent mouse coordinates, GCD timers, fullscreen Space changes, and modal popups
// cannot wedge the panel open or drift out of sync.
//
// Foundation-only (part of AGYCore); no AppKit/SwiftUI/CoreGraphics/Combine.

public enum NotchTiming {
    public static let openDwell: TimeInterval = 0.18
    public static let closeGrace: TimeInterval = 0.12
    public static let rebuildDebounce: TimeInterval = 0.30
}

public enum NotchModalLock: Hashable, Sendable {
    case languageMenu
    case optionsMenu
    case clearArchiveAlert
    case custom(String)
}

public enum NotchPhase: Equatable, Sendable {
    case hidden
    case closedPill
    case openingDwell
    case open
    case closingGrace
}

public struct NotchPointerSample: Equatable, Sendable {
    public let onScreen: Bool
    public let inHoverBand: Bool
    public let inContentRect: Bool
    public let inRevealEdge: Bool
    public let inRevealBand: Bool
    /// True when the pointer is over a visible closed-state Live Wing action pill.
    public let inClickableWing: Bool

    public static let outside = NotchPointerSample(
        onScreen: false,
        inHoverBand: false,
        inContentRect: false,
        inRevealEdge: false,
        inRevealBand: false,
        inClickableWing: false
    )

    public init(
        onScreen: Bool,
        inHoverBand: Bool,
        inContentRect: Bool,
        inRevealEdge: Bool,
        inRevealBand: Bool,
        inClickableWing: Bool = false
    ) {
        self.onScreen = onScreen
        self.inHoverBand = inHoverBand
        self.inContentRect = inContentRect
        self.inRevealEdge = inRevealEdge
        self.inRevealBand = inRevealBand
        self.inClickableWing = inClickableWing
    }
}

public struct NotchState: Equatable, Sendable {
    public var phase: NotchPhase
    public var isFullscreen: Bool
    public var revealArmed: Bool
    public var modalLocks: Set<NotchModalLock>
    /// Last pointer sample dispatched while this state's phase/fullscreen/reveal/locks were unchanged.
    /// Automatically invalidated on every non-pointer state transition or geometry change so
    /// explicit reveals (`⌥⇧A`) and Space switches NEVER swallow subsequent mouse moves.
    public var lastPointerSample: NotchPointerSample?

    public init(
        phase: NotchPhase = .closedPill,
        isFullscreen: Bool = false,
        revealArmed: Bool = false,
        modalLocks: Set<NotchModalLock> = [],
        lastPointerSample: NotchPointerSample? = nil
    ) {
        self.phase = phase
        self.isFullscreen = isFullscreen
        self.revealArmed = revealArmed
        self.modalLocks = modalLocks
        self.lastPointerSample = lastPointerSample
    }

    /// True while expanded (including closing grace hysteresis before panel collapses).
    public var isOpen: Bool { phase == .open || phase == .closingGrace }

    /// True while an NSMenu or NSAlert owns focus inside the notch panel.
    public var isPinnedOpen: Bool { !modalLocks.isEmpty }

    /// Fullscreen suppresses hover until the user pushes the cursor into the top 8pt edge.
    public var hoverCanOpen: Bool { !isFullscreen || revealArmed }
}

public enum NotchEvent: Equatable, Sendable {
    case pointerMoved(NotchPointerSample)
    case openDwellFired(NotchPointerSample)
    case closeGraceFired(NotchPointerSample)
    case fullscreenChanged(Bool)
    case modalLockAcquired(NotchModalLock)
    case modalLockReleased(NotchModalLock, pointer: NotchPointerSample)
    case explicitReveal
    case explicitClose
    case explicitToggle
}

public enum NotchEffect: Equatable, Sendable {
    case scheduleOpenDwell
    case cancelOpenDwell
    case scheduleCloseGrace
    case cancelCloseGrace
    case setInteractive(Bool)
    case resignKeyIfNeeded
    case syncSessionMonitor(active: Bool)
    case refreshUsage
    case applyPanelPresentation
}

public struct NotchPanelPresentation: Equatable, Sendable {
    public let visible: Bool
    public let ignoresMouseEvents: Bool

    public init(visible: Bool, ignoresMouseEvents: Bool) {
        self.visible = visible
        self.ignoresMouseEvents = ignoresMouseEvents
    }
}

public enum NotchMachine {

    private static func restingClosedPhase(for state: NotchState) -> NotchPhase {
        (state.isFullscreen && !state.revealArmed) ? .hidden : .closedPill
    }

    @discardableResult
    public static func reduce(_ state: inout NotchState, event: NotchEvent) -> [NotchEffect] {
        switch event {
        case .pointerMoved(let sample):
            if sample == state.lastPointerSample {
                return []
            }
            state.lastPointerSample = sample
            if !state.isFullscreen {
                state.revealArmed = false
            } else if sample.inRevealEdge {
                state.revealArmed = true
            } else if !state.isOpen && sample.onScreen && !sample.inRevealBand {
                state.revealArmed = false
            }

            var effects: [NotchEffect] = []
            if state.isOpen {
                if state.isPinnedOpen {
                    if state.phase == .closingGrace {
                        state.phase = .open
                        effects.append(.cancelCloseGrace)
                    }
                } else if !sample.onScreen || !sample.inContentRect {
                    if state.phase != .closingGrace {
                        state.phase = .closingGrace
                        effects.append(.scheduleCloseGrace)
                    }
                } else if state.phase == .closingGrace {
                    state.phase = .open
                    effects.append(.cancelCloseGrace)
                }
            } else {
                if sample.onScreen && sample.inHoverBand && state.hoverCanOpen {
                    if state.phase != .openingDwell {
                        state.phase = .openingDwell
                        effects.append(.scheduleOpenDwell)
                    }
                } else {
                    if state.phase == .openingDwell {
                        effects.append(.cancelOpenDwell)
                    }
                    state.phase = restingClosedPhase(for: state)
                }
            }
            effects.append(.applyPanelPresentation)
            return effects

        case .openDwellFired(let sample):
            guard state.phase == .openingDwell else { return [] }
            state.lastPointerSample = nil
            guard sample.onScreen && sample.inHoverBand && state.hoverCanOpen else {
                state.phase = restingClosedPhase(for: state)
                return [.applyPanelPresentation]
            }
            state.phase = .open
            return [
                .cancelOpenDwell,
                .cancelCloseGrace,
                .setInteractive(true),
                .syncSessionMonitor(active: true),
                .refreshUsage,
                .applyPanelPresentation,
            ]

        case .closeGraceFired(let sample):
            guard state.phase == .closingGrace || state.phase == .open else { return [] }
            state.lastPointerSample = nil
            if state.isPinnedOpen || (sample.onScreen && sample.inContentRect) {
                state.phase = .open
                return [.cancelCloseGrace, .applyPanelPresentation]
            }
            state.phase = restingClosedPhase(for: state)
            return [
                .cancelOpenDwell,
                .cancelCloseGrace,
                .setInteractive(false),
                .resignKeyIfNeeded,
                .syncSessionMonitor(active: false),
                .applyPanelPresentation,
            ]

        case .fullscreenChanged(let isFS):
            let changed = state.isFullscreen != isFS
            state.isFullscreen = isFS
            state.lastPointerSample = nil
            if changed {
                state.revealArmed = false
            }
            var effects: [NotchEffect] = []
            if !state.isOpen {
                if state.phase == .openingDwell && !state.hoverCanOpen {
                    effects.append(.cancelOpenDwell)
                    state.phase = restingClosedPhase(for: state)
                } else if state.phase != .openingDwell {
                    state.phase = restingClosedPhase(for: state)
                }
            }
            effects.append(.applyPanelPresentation)
            return effects

        case .modalLockAcquired(let lock):
            state.modalLocks.insert(lock)
            state.lastPointerSample = nil
            var effects: [NotchEffect] = []
            if !state.isOpen {
                let wasDwell = state.phase == .openingDwell
                state.phase = .open
                if wasDwell { effects.append(.cancelOpenDwell) }
                effects.append(.cancelCloseGrace)
                effects.append(.setInteractive(true))
                effects.append(.syncSessionMonitor(active: true))
                effects.append(.applyPanelPresentation)
            } else if state.phase == .closingGrace {
                state.phase = .open
                effects.append(.cancelCloseGrace)
                effects.append(.applyPanelPresentation)
            } else {
                effects.append(.cancelCloseGrace)
            }
            return effects

        case .modalLockReleased(let lock, let pointer):
            state.modalLocks.remove(lock)
            state.lastPointerSample = nil
            guard state.modalLocks.isEmpty, state.isOpen else { return [] }
            if !pointer.onScreen || !pointer.inContentRect {
                state.phase = .closingGrace
                return [.scheduleCloseGrace, .applyPanelPresentation]
            }
            if state.phase == .closingGrace {
                state.phase = .open
                return [.cancelCloseGrace, .applyPanelPresentation]
            }
            return [.applyPanelPresentation]

        case .explicitReveal:
            state.lastPointerSample = nil
            var effects: [NotchEffect] = [.cancelOpenDwell, .cancelCloseGrace]
            if !state.isOpen {
                state.phase = .open
                effects.append(.setInteractive(true))
                effects.append(.syncSessionMonitor(active: true))
                effects.append(.refreshUsage)
            } else {
                state.phase = .open
            }
            effects.append(.applyPanelPresentation)
            return effects

        case .explicitClose:
            guard !state.isPinnedOpen else { return [] }
            state.lastPointerSample = nil
            if state.isOpen {
                state.phase = restingClosedPhase(for: state)
                return [
                    .cancelOpenDwell,
                    .cancelCloseGrace,
                    .setInteractive(false),
                    .resignKeyIfNeeded,
                    .syncSessionMonitor(active: false),
                    .applyPanelPresentation,
                ]
            }
            if state.phase == .openingDwell {
                state.phase = restingClosedPhase(for: state)
                return [.cancelOpenDwell, .applyPanelPresentation]
            }
            return []

        case .explicitToggle:
            return reduce(&state, event: state.isOpen ? .explicitClose : .explicitReveal)
        }
    }

    public static func panelPresentation(
        for state: NotchState,
        pointer: NotchPointerSample
    ) -> NotchPanelPresentation {
        let visible = !state.isFullscreen
            || state.isOpen
            || (state.revealArmed && pointer.inRevealBand)
        if !visible {
            return NotchPanelPresentation(visible: false, ignoresMouseEvents: true)
        }
        if state.isOpen {
            return NotchPanelPresentation(visible: true, ignoresMouseEvents: !pointer.inContentRect)
        }
        return NotchPanelPresentation(
            visible: true,
            ignoresMouseEvents: !(pointer.inHoverBand || pointer.inClickableWing)
        )
    }
}

// MARK: - Split Closed / Open Notch Geometry State

/// Separates closed-pill and expanded-popover content dimensions so closing the notch
/// can NEVER feed the expanded 380x600pt rect into `closedWingRect` hit-testing.
/// Also keeps `compactGapOffset` aligned with `NotchRootView`'s initial wing widths.
public struct NotchGeometryState: Equatable, Sendable {
    public var closedWidth: Double
    public var closedHeight: Double
    public var openWidth: Double
    public var openHeight: Double
    public var leftWingWidth: Double
    public var rightWingWidth: Double

    public init(
        closedWidth: Double = 0,
        closedHeight: Double = 0,
        openWidth: Double = 0,
        openHeight: Double = 0,
        leftWingWidth: Double = 39,
        rightWingWidth: Double = 56
    ) {
        self.closedWidth = closedWidth
        self.closedHeight = closedHeight
        self.openWidth = openWidth
        self.openHeight = openHeight
        self.leftWingWidth = leftWingWidth
        self.rightWingWidth = rightWingWidth
    }

    public var compactGapOffset: Double {
        (rightWingWidth - leftWingWidth) / 2.0
    }

    @discardableResult
    public mutating func updateContentSize(width: Double, height: Double, isOpen: Bool) -> Bool {
        guard width > 1, height > 1 else { return false }
        if isOpen {
            guard abs(width - openWidth) > 0.5 || abs(height - openHeight) > 0.5 else { return false }
            openWidth = width
            openHeight = height
            return true
        } else {
            guard abs(width - closedWidth) > 0.5 || abs(height - closedHeight) > 0.5 else { return false }
            closedWidth = width
            closedHeight = height
            return true
        }
    }

    @discardableResult
    public mutating func updateWingWidths(left: Double? = nil, right: Double? = nil) -> Bool {
        var changed = false
        if let l = left, l > 0, abs(l - leftWingWidth) > 0.5 {
            leftWingWidth = l
            changed = true
        }
        if let r = right, r > 0, abs(r - rightWingWidth) > 0.5 {
            rightWingWidth = r
            changed = true
        }
        return changed
    }

    public func contentSize(isOpen: Bool) -> (width: Double, height: Double) {
        isOpen ? (openWidth, openHeight) : (closedWidth, closedHeight)
    }
}

// MARK: - Multi-Display Notch Coordinator State Machine

public struct NotchDisplayDescriptor: Equatable, Sendable {
    public let displayId: UInt32
    public let isBuiltin: Bool
    public let isMain: Bool
    public let isFullscreen: Bool

    public init(displayId: UInt32, isBuiltin: Bool, isMain: Bool, isFullscreen: Bool) {
        self.displayId = displayId
        self.isBuiltin = isBuiltin
        self.isMain = isMain
        self.isFullscreen = isFullscreen
    }
}

public struct NotchCoordinatorState: Equatable, Sendable {
    public var isStarted: Bool = false
    public var displays: [UInt32: NotchState] = [:]
    public var appliedVisibility: [UInt32: Bool] = [:]
    public var rebuildGeneration: Int = 0

    public init() {}

    public var anyOpen: Bool {
        displays.values.contains { $0.isOpen }
    }
}

public struct NotchScreenReconcilePlan: Equatable, Sendable {
    public let removed: [UInt32]
    public let kept: [UInt32]
    public let added: [NotchDisplayDescriptor]

    public init(removed: [UInt32], kept: [UInt32], added: [NotchDisplayDescriptor]) {
        self.removed = removed
        self.kept = kept
        self.added = added
    }
}

/// Pure multi-display coordinator rules for `NotchController`:
/// - Eliminates raw `isStarted` shadow booleans and destructive full-teardown rebuilds.
/// - Enforces single-open exclusivity across displays (opening Display B closes Display A).
/// - Deterministically selects primary display (mouse -> builtin -> main -> lowest ID).
/// - Diffs target panel visibility so mid-fade mouse moves never restart alpha animations.
public enum NotchCoordinatorMachine {

    @discardableResult
    public static func start(_ state: inout NotchCoordinatorState) -> Bool {
        guard !state.isStarted else { return false }
        state.isStarted = true
        state.rebuildGeneration += 1
        return true
    }

    @discardableResult
    public static func stop(_ state: inout NotchCoordinatorState) -> [UInt32] {
        guard state.isStarted || !state.displays.isEmpty else { return [] }
        let removed = state.displays.keys.sorted()
        state.isStarted = false
        state.displays.removeAll()
        state.appliedVisibility.removeAll()
        state.rebuildGeneration += 1
        return removed
    }

    public static func scheduleRebuild(_ state: inout NotchCoordinatorState) -> Int? {
        guard state.isStarted else { return nil }
        state.rebuildGeneration += 1
        return state.rebuildGeneration
    }

    public static func isCurrentRebuild(_ state: NotchCoordinatorState, generation: Int) -> Bool {
        state.isStarted && state.rebuildGeneration == generation
    }

    /// Incrementally reconcile connected displays, preserving open/modal state on surviving displays.
    public static func reconcileScreens(
        _ state: inout NotchCoordinatorState,
        descriptors: [NotchDisplayDescriptor]
    ) -> NotchScreenReconcilePlan {
        let incomingIds = Set(descriptors.map(\.displayId))
        let existingIds = Set(state.displays.keys)

        let removed = existingIds.subtracting(incomingIds).sorted()
        for id in removed {
            state.displays.removeValue(forKey: id)
            state.appliedVisibility.removeValue(forKey: id)
        }

        var kept: [UInt32] = []
        var added: [NotchDisplayDescriptor] = []
        for desc in descriptors {
            if state.displays[desc.displayId] != nil {
                kept.append(desc.displayId)
            } else {
                state.displays[desc.displayId] = NotchState(
                    phase: desc.isFullscreen ? .hidden : .closedPill,
                    isFullscreen: desc.isFullscreen
                )
                added.append(desc)
            }
        }
        return NotchScreenReconcilePlan(removed: removed, kept: kept, added: added)
    }

    /// Returns any OTHER open displays that should close when `activeDisplayId` opens,
    /// guaranteeing at most one expanded `PopoverView` exists across all monitors.
    public static func displaysToCloseForExclusivity(
        _ state: NotchCoordinatorState,
        openingDisplayId: UInt32
    ) -> [UInt32] {
        state.displays
            .filter { $0.key != openingDisplayId && $0.value.isOpen && !$0.value.isPinnedOpen }
            .map(\.key)
            .sorted()
    }

    /// Deterministic primary display selector (never relies on Dictionary hash order).
    public static func selectPrimaryDisplay(
        descriptors: [NotchDisplayDescriptor],
        mouseDisplayId: UInt32?
    ) -> UInt32? {
        if let mid = mouseDisplayId, descriptors.contains(where: { $0.displayId == mid }) {
            return mid
        }
        if let builtin = descriptors.filter(\.isBuiltin).min(by: { $0.displayId < $1.displayId }) {
            return builtin.displayId
        }
        if let main = descriptors.filter(\.isMain).min(by: { $0.displayId < $1.displayId }) {
            return main.displayId
        }
        return descriptors.min(by: { $0.displayId < $1.displayId })?.displayId
    }

    /// Returns `(changed: Bool, shouldAnimate: Bool)`. First visibility apply on a freshly
    /// created panel snaps cleanly without a fade-in blink; subsequent flips animate once.
    public static func updateVisibility(
        _ state: inout NotchCoordinatorState,
        displayId: UInt32,
        visible: Bool
    ) -> (changed: Bool, shouldAnimate: Bool) {
        if let prev = state.appliedVisibility[displayId] {
            guard prev != visible else { return (false, false) }
            state.appliedVisibility[displayId] = visible
            return (true, true)
        }
        state.appliedVisibility[displayId] = visible
        return (true, false)
    }
}
