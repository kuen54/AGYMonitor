import Foundation

// MARK: - Notch Hover, Fullscreen Edge-Reveal & Modal-Lock State Machine — pure core
//
// Explicit deterministic reducer governing per-display notch transitions so AppKit's
// NSEvent mouse coordinates, GCD timers, fullscreen Space changes, and modal popups
// cannot wedge the panel open or drift out of sync.
//
// Foundation-only (part of AGYCore); no AppKit/SwiftUI/CoreGraphics/Combine.

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

    public static let outside = NotchPointerSample(
        onScreen: false,
        inHoverBand: false,
        inContentRect: false,
        inRevealEdge: false,
        inRevealBand: false
    )

    public init(
        onScreen: Bool,
        inHoverBand: Bool,
        inContentRect: Bool,
        inRevealEdge: Bool,
        inRevealBand: Bool
    ) {
        self.onScreen = onScreen
        self.inHoverBand = inHoverBand
        self.inContentRect = inContentRect
        self.inRevealEdge = inRevealEdge
        self.inRevealBand = inRevealBand
    }
}

public struct NotchState: Equatable, Sendable {
    public var phase: NotchPhase
    public var isFullscreen: Bool
    public var revealArmed: Bool
    public var modalLocks: Set<NotchModalLock>

    public init(
        phase: NotchPhase = .closedPill,
        isFullscreen: Bool = false,
        revealArmed: Bool = false,
        modalLocks: Set<NotchModalLock> = []
    ) {
        self.phase = phase
        self.isFullscreen = isFullscreen
        self.revealArmed = revealArmed
        self.modalLocks = modalLocks
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
        return NotchPanelPresentation(visible: true, ignoresMouseEvents: !pointer.inHoverBand)
    }
}
