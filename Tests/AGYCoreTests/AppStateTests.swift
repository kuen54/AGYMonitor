import Foundation
import Testing
@testable import AGYCore

@Suite("Core_AppState")
struct AppStateTests {

    @Test("Switching from menubar (with open popover) to notch prevents late popoverClosed from stomping notch visibility")
    func crossSurfaceVisibilityRacePrevented() {
        var state = AppPresentationState(surface: .menubar)

        // Open popover in menu bar mode
        let openEff = AppPresentationMachine.reduce(&state, event: .popoverShown)
        #expect(state.isPanelVisible)
        #expect(openEff == [.syncPanelVisibility(true)])

        // Switch to notch mode while popover is open -> closes popover BEFORE hiding status item (no duplicate close)
        let toNotch = AppPresentationMachine.reduce(&state, event: .displaySurfaceChanged(.notch))
        #expect(state.surface == .notch)
        #expect(state.isNotchControllerRunning)
        #expect(!state.isStatusItemVisible)
        #expect(!state.isMenuBarLogoActive)
        #expect(toNotch == [
            .closePopover,
            .setMenuBarLogoActive(false),
            .setStatusItemVisible(false),
            .startNotchController,
            .syncPanelVisibility(false),
        ])

        // User opens notch
        let notchOpen = AppPresentationMachine.reduce(&state, event: .notchOpenChanged(true))
        #expect(state.isPanelVisible)
        #expect(notchOpen == [.syncPanelVisibility(true)])

        // Delayed NSPopoverDelegate.popoverDidClose arrives AFTER notch opened:
        // MUST NOT emit syncPanelVisibility(false)!
        let lateClose = AppPresentationMachine.reduce(&state, event: .popoverClosed)
        #expect(state.isPanelVisible)
        #expect(lateClose.isEmpty)
    }

    @Test("Switching back to menubar tears down notch controller and restores status item & logo")
    func switchBackToMenubarRestoresAllSurfaceFlags() {
        var state = AppPresentationState(
            surface: .notch,
            popoverOpen: false,
            notchOpen: true,
            isNotchControllerRunning: true
        )

        let toMenu = AppPresentationMachine.reduce(&state, event: .displaySurfaceChanged(.menubar))
        #expect(state.surface == .menubar)
        #expect(!state.isNotchControllerRunning)
        #expect(!state.notchOpen)
        #expect(!state.isPanelVisible)
        #expect(toMenu == [
            .stopNotchController,
            .setMenuBarLogoActive(true),
            .setStatusItemVisible(true),
            .syncPanelVisibility(false),
        ])

        // Late notch teardown notification after returning to menubar is ignored
        let lateNotch = AppPresentationMachine.reduce(&state, event: .notchOpenChanged(true))
        #expect(!state.notchOpen)
        #expect(lateNotch.isEmpty)
    }

    @Test("Reopen, global hotkey, status clicks, and termination emit exact deterministic effects")
    func reopenHotkeyAndTerminateEffects() {
        var state = AppPresentationState(surface: .menubar)

        // Hotkey registration is idempotent
        #expect(AppPresentationMachine.reduce(&state, event: .hotkeyPreferenceChanged(true)) == [.registerHotkey])
        #expect(AppPresentationMachine.reduce(&state, event: .hotkeyPreferenceChanged(true)).isEmpty)

        // Reopen in menubar syncs BOTH status item visibility AND menu bar logo activity
        let reopen = AppPresentationMachine.reduce(&state, event: .reopenRequested)
        #expect(reopen == [.setStatusItemVisible(true), .setMenuBarLogoActive(true), .openPopover])

        // Status item left-click and global hotkey toggle cleanly without legacy popover animation hacks
        #expect(AppPresentationMachine.reduce(&state, event: .statusItemLeftClicked) == [.openPopover])
        #expect(AppPresentationMachine.reduce(&state, event: .globalHotkeyTriggered) == [.openPopover])

        // Right-click while popover is open closes popover before showing menu
        AppPresentationMachine.reduce(&state, event: .popoverShown)
        #expect(AppPresentationMachine.reduce(&state, event: .statusItemLeftClicked) == [.closePopover])
        #expect(AppPresentationMachine.reduce(&state, event: .globalHotkeyTriggered) == [.closePopover])
        let rightClick = AppPresentationMachine.reduce(&state, event: .statusItemRightClicked)
        #expect(rightClick == [.closePopover, .showStatusContextMenu])

        // Global hotkey in notch mode toggles notch
        AppPresentationMachine.reduce(&state, event: .displaySurfaceChanged(.notch))
        #expect(AppPresentationMachine.reduce(&state, event: .globalHotkeyTriggered) == [.toggleNotch])
        #expect(AppPresentationMachine.reduce(&state, event: .reopenRequested) == [.revealNotch])

        // Termination unregisters hotkey and stops notch controller cleanly
        let term = AppPresentationMachine.reduce(&state, event: .appWillTerminate)
        #expect(term == [.unregisterHotkey, .stopNotchController])
        #expect(!state.isHotkeyRegistered)
        #expect(!state.isNotchControllerRunning)
    }

    @Test("Switching to notch while menu-bar panel is already closed does not emit redundant closePopover")
    func switchToNotchWhenClosedHasNoClosePopover() {
        var state = AppPresentationState(surface: .menubar, popoverOpen: false)
        let effects = AppPresentationMachine.reduce(&state, event: .displaySurfaceChanged(.notch))
        #expect(effects == [
            .setMenuBarLogoActive(false),
            .setStatusItemVisible(false),
            .startNotchController,
        ])
        #expect(!effects.contains(.closePopover))
    }

    @Test("hotkeyRegistrationFailed keeps isHotkeyRegistered truthful so future toggles retry cleanly")
    func hotkeyFailureSync() {
        var state = AppPresentationState(surface: .menubar)
        #expect(AppPresentationMachine.reduce(&state, event: .hotkeyPreferenceChanged(true)) == [.registerHotkey])
        #expect(state.isHotkeyRegistered)

        #expect(AppPresentationMachine.reduce(&state, event: .hotkeyRegistrationFailed).isEmpty)
        #expect(!state.isHotkeyRegistered)

        // Re-enabling retries registration instead of silently thinking it's already registered
        #expect(AppPresentationMachine.reduce(&state, event: .hotkeyPreferenceChanged(true)) == [.registerHotkey])
    }
}
