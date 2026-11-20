import Foundation

// MARK: - App Presentation & Surface Lifecycle State Machine — pure core
//
// Single source of truth for the app's active presentation surface (menu bar vs
// MacBook notch), popover/notch visibility, status-item visibility, menu-bar logo
// activity, and global hotkey lifecycle. Prevents cross-surface races such as a
// delayed `popoverDidClose` clearing `isPanelVisible` after switching to Notch mode.
//
// Foundation-only (part of AGYCore); no AppKit/SwiftUI/Combine.

public enum AppDisplaySurface: String, Equatable, CaseIterable, Sendable {
    case menubar
    case notch
}

public struct AppPresentationState: Equatable, Sendable {
    public var surface: AppDisplaySurface
    public var popoverOpen: Bool
    public var notchOpen: Bool
    public var isNotchControllerRunning: Bool
    public var hotkeyEnabled: Bool
    public var isHotkeyRegistered: Bool

    public init(
        surface: AppDisplaySurface = .menubar,
        popoverOpen: Bool = false,
        notchOpen: Bool = false,
        isNotchControllerRunning: Bool = false,
        hotkeyEnabled: Bool = true,
        isHotkeyRegistered: Bool = false
    ) {
        self.surface = surface
        self.popoverOpen = popoverOpen
        self.notchOpen = notchOpen
        self.isNotchControllerRunning = isNotchControllerRunning
        self.hotkeyEnabled = hotkeyEnabled
        self.isHotkeyRegistered = isHotkeyRegistered
    }

    /// True iff the currently active presentation surface has an open panel on screen.
    public var isPanelVisible: Bool {
        switch surface {
        case .menubar: return popoverOpen
        case .notch:   return notchOpen
        }
    }

    /// Status bar icon & menu-bar logo animation are active only in menu-bar mode.
    public var isStatusItemVisible: Bool { surface == .menubar }
    public var isMenuBarLogoActive: Bool { surface == .menubar }
}

public enum AppPresentationEvent: Equatable, Sendable {
    case displaySurfaceChanged(AppDisplaySurface)
    case popoverShown
    case popoverClosed
    case notchOpenChanged(Bool)
    case hotkeyPreferenceChanged(Bool)
    case hotkeyRegistrationFailed
    case reopenRequested
    case globalHotkeyTriggered
    case statusItemLeftClicked
    case statusItemRightClicked
    case appWillTerminate
}

public enum AppPresentationEffect: Equatable, Sendable {
    case startNotchController
    case stopNotchController
    case setStatusItemVisible(Bool)
    case setMenuBarLogoActive(Bool)
    case setPopoverAnimates(Bool)
    case openPopover
    case closePopover
    case showStatusContextMenu
    case revealNotch
    case toggleNotch
    case syncPanelVisibility(Bool)
    case registerHotkey
    case unregisterHotkey
}

public enum AppPresentationMachine {

    @discardableResult
    public static func reduce(
        _ state: inout AppPresentationState,
        event: AppPresentationEvent
    ) -> [AppPresentationEffect] {
        let prevVisible = state.isPanelVisible

        switch event {
        case .displaySurfaceChanged(let nextSurface):
            var effects: [AppPresentationEffect] = []
            state.surface = nextSurface

            switch nextSurface {
            case .menubar:
                if state.isNotchControllerRunning {
                    state.isNotchControllerRunning = false
                    state.notchOpen = false
                    effects.append(.stopNotchController)
                }
                effects.append(.setMenuBarLogoActive(true))
                effects.append(.setStatusItemVisible(true))

            case .notch:
                effects.append(.setMenuBarLogoActive(false))
                effects.append(.setStatusItemVisible(false))
                if state.popoverOpen {
                    state.popoverOpen = false
                    effects.append(.closePopover)
                }
                if !state.isNotchControllerRunning {
                    state.isNotchControllerRunning = true
                    effects.append(.startNotchController)
                }
            }

            if state.isPanelVisible != prevVisible {
                effects.append(.syncPanelVisibility(state.isPanelVisible))
            }
            return effects

        case .popoverShown:
            state.popoverOpen = true
            var effects: [AppPresentationEffect] = [.setPopoverAnimates(false)]
            if state.isPanelVisible != prevVisible {
                effects.append(.syncPanelVisibility(state.isPanelVisible))
            }
            return effects

        case .popoverClosed:
            state.popoverOpen = false
            var effects: [AppPresentationEffect] = []
            // Crucially, if we already switched to `.notch` and the notch is open,
            // `state.isPanelVisible` remains `true` so a delayed popover close never
            // stomps the notch's active session-monitor / animation visibility.
            if state.isPanelVisible != prevVisible {
                effects.append(.syncPanelVisibility(state.isPanelVisible))
            }
            return effects

        case .notchOpenChanged(let open):
            // Ignore late teardown notifications if notch controller is no longer active.
            let effectiveOpen = state.isNotchControllerRunning ? open : false
            state.notchOpen = effectiveOpen
            if state.isPanelVisible != prevVisible {
                return [.syncPanelVisibility(state.isPanelVisible)]
            }
            return []

        case .hotkeyPreferenceChanged(let enabled):
            state.hotkeyEnabled = enabled
            if enabled && !state.isHotkeyRegistered {
                state.isHotkeyRegistered = true
                return [.registerHotkey]
            } else if !enabled && state.isHotkeyRegistered {
                state.isHotkeyRegistered = false
                return [.unregisterHotkey]
            }
            return []

        case .hotkeyRegistrationFailed:
            state.isHotkeyRegistered = false
            return []

        case .reopenRequested:
            switch state.surface {
            case .notch:
                return [.revealNotch]
            case .menubar:
                var effects: [AppPresentationEffect] = [
                    .setStatusItemVisible(true),
                    .setMenuBarLogoActive(true),
                ]
                if !state.popoverOpen {
                    effects.append(.setPopoverAnimates(true))
                    effects.append(.openPopover)
                }
                return effects
            }

        case .globalHotkeyTriggered:
            switch state.surface {
            case .notch:
                return [.toggleNotch]
            case .menubar:
                if state.popoverOpen {
                    return [.closePopover]
                }
                return [.setPopoverAnimates(true), .openPopover]
            }

        case .statusItemLeftClicked:
            guard state.surface == .menubar else { return [] }
            if state.popoverOpen {
                return [.closePopover]
            }
            return [.setPopoverAnimates(true), .openPopover]

        case .statusItemRightClicked:
            guard state.surface == .menubar else { return [] }
            var effects: [AppPresentationEffect] = []
            if state.popoverOpen {
                effects.append(.closePopover)
            }
            effects.append(.showStatusContextMenu)
            return effects

        case .appWillTerminate:
            var effects: [AppPresentationEffect] = []
            if state.isHotkeyRegistered {
                state.isHotkeyRegistered = false
                effects.append(.unregisterHotkey)
            }
            if state.isNotchControllerRunning {
                state.isNotchControllerRunning = false
                state.notchOpen = false
                effects.append(.stopNotchController)
            }
            state.popoverOpen = false
            if prevVisible {
                effects.append(.syncPanelVisibility(false))
            }
            return effects
        }
    }
}
