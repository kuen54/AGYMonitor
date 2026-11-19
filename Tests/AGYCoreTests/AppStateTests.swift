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
        #expect(openEff == [.setPopoverAnimates(false), .syncPanelVisibility(true)])

        // Switch to notch mode while popover is open -> closes popover, starts notch, hides status item
        let toNotch = AppPresentationMachine.reduce(&state, event: .displaySurfaceChanged(.notch))
        #expect(state.surface == .notch)
        #expect(state.isNotchControllerRunning)
        #expect(!state.isStatusItemVisible)
        #expect(!state.isMenuBarLogoActive)
        #expect(toNotch.contains(.setStatusItemVisible(false)))
        #expect(toNotch.contains(.setMenuBarLogoActive(false)))
        #expect(toNotch.contains(.closePopover))
        #expect(toNotch.contains(.startNotchController))
        #expect(toNotch.contains(.syncPanelVisibility(false)))

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
        #expect(reopen == [.setStatusItemVisible(true), .setMenuBarLogoActive(true), .setPopoverAnimates(true), .openPopover])

        // Right-click while popover is open closes popover before showing menu
        AppPresentationMachine.reduce(&state, event: .popoverShown)
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
}
