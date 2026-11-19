import Foundation
import Testing
@testable import AGYCore

@Suite("Core_NotchState")
struct NotchStateTests {

    private let insideHover = NotchPointerSample(
        onScreen: true, inHoverBand: true, inContentRect: false, inRevealEdge: false, inRevealBand: false
    )
    private let insideContent = NotchPointerSample(
        onScreen: true, inHoverBand: false, inContentRect: true, inRevealEdge: false, inRevealBand: false
    )
    private let outsideOnScreen = NotchPointerSample(
        onScreen: true, inHoverBand: false, inContentRect: false, inRevealEdge: false, inRevealBand: false
    )
    private let topEdgeFullscreen = NotchPointerSample(
        onScreen: true, inHoverBand: true, inContentRect: false, inRevealEdge: true, inRevealBand: true
    )

    @Test("Hover dwell opens, leaving starts grace and closes, brief hover cancels dwell")
    func hoverDwellOpenLeaveGraceClose() {
        var state = NotchState()

        // Move into hover band -> enters openingDwell & schedules dwell timer
        let e1 = NotchMachine.reduce(&state, event: .pointerMoved(insideHover))
        #expect(state.phase == .openingDwell)
        #expect(!state.isOpen)
        #expect(e1.contains(.scheduleOpenDwell))

        // Briefly leave before dwell fires -> cancels dwell timer, stays closedPill
        let e2 = NotchMachine.reduce(&state, event: .pointerMoved(outsideOnScreen))
        #expect(state.phase == .closedPill)
        #expect(e2.contains(.cancelOpenDwell))

        // Hover again and let dwell fire -> opens panel & activates session monitor
        NotchMachine.reduce(&state, event: .pointerMoved(insideHover))
        let e3 = NotchMachine.reduce(&state, event: .openDwellFired(insideHover))
        #expect(state.phase == .open)
        #expect(state.isOpen)
        #expect(e3.contains(.setInteractive(true)))
        #expect(e3.contains(.syncSessionMonitor(active: true)))
        #expect(e3.contains(.refreshUsage))

        // Leave content rect -> closingGrace & scheduleCloseGrace
        let e4 = NotchMachine.reduce(&state, event: .pointerMoved(outsideOnScreen))
        #expect(state.phase == .closingGrace)
        #expect(e4.contains(.scheduleCloseGrace))

        // Move back inside before grace fires -> cancels close & restores .open
        let e5 = NotchMachine.reduce(&state, event: .pointerMoved(insideContent))
        #expect(state.phase == .open)
        #expect(e5.contains(.cancelCloseGrace))

        // Leave again and let grace fire -> closes cleanly
        NotchMachine.reduce(&state, event: .pointerMoved(.outside))
        let e6 = NotchMachine.reduce(&state, event: .closeGraceFired(.outside))
        #expect(state.phase == .closedPill)
        #expect(!state.isOpen)
        #expect(e6.contains(.setInteractive(false)))
        #expect(e6.contains(.resignKeyIfNeeded))
        #expect(e6.contains(.syncSessionMonitor(active: false)))
    }

    @Test("Overlapping modal locks stay pinned until last lock releases, then grace-close if pointer outside")
    func modalLocksPreventStuckOpenBug() {
        var state = NotchState(phase: .open)

        NotchMachine.reduce(&state, event: .modalLockAcquired(.optionsMenu))
        NotchMachine.reduce(&state, event: .modalLockAcquired(.clearArchiveAlert))
        #expect(state.isPinnedOpen)

        // Pointer leaves while alert/menu open: no close grace scheduled while pinned
        let eLeave = NotchMachine.reduce(&state, event: .pointerMoved(outsideOnScreen))
        #expect(state.phase == .open)
        #expect(!eLeave.contains(.scheduleCloseGrace))

        // Explicit close is blocked while pinned
        let eExplicit = NotchMachine.reduce(&state, event: .explicitClose)
        #expect(state.phase == .open)
        #expect(eExplicit.isEmpty)

        // Releasing first lock still keeps panel pinned
        let eRel1 = NotchMachine.reduce(&state, event: .modalLockReleased(.optionsMenu, pointer: outsideOnScreen))
        #expect(state.isPinnedOpen)
        #expect(eRel1.isEmpty)

        // Releasing last lock while pointer is outside IMMEDIATELY enters closingGrace & schedules close!
        let eRel2 = NotchMachine.reduce(&state, event: .modalLockReleased(.clearArchiveAlert, pointer: outsideOnScreen))
        #expect(!state.isPinnedOpen)
        #expect(state.phase == .closingGrace)
        #expect(eRel2.contains(.scheduleCloseGrace))

        // When grace timer fires with pointer outside -> closes
        NotchMachine.reduce(&state, event: .closeGraceFired(outsideOnScreen))
        #expect(state.phase == .closedPill)
    }

    @Test("Explicit reveal/close/toggle cancel pending dwell & grace timers")
    func explicitControlsCancelPendingTimers() {
        var state = NotchState(phase: .openingDwell)
        let eRev = NotchMachine.reduce(&state, event: .explicitReveal)
        #expect(state.phase == .open)
        #expect(eRev.contains(.cancelOpenDwell))
        #expect(eRev.contains(.cancelCloseGrace))
        #expect(eRev.contains(.refreshUsage))

        // Simulate grace countdown then explicitToggle / reveal cancels close
        NotchMachine.reduce(&state, event: .pointerMoved(outsideOnScreen))
        #expect(state.phase == .closingGrace)

        let eClose = NotchMachine.reduce(&state, event: .explicitToggle)
        #expect(state.phase == .closedPill)
        #expect(eClose.contains(.cancelOpenDwell))
        #expect(eClose.contains(.cancelCloseGrace))
        #expect(eClose.contains(.setInteractive(false)))
    }

    @Test("Fullscreen hides idle pill until top 8pt edge arms reveal, and gates mouse passthrough")
    func fullscreenEdgeRevealAndPresentation() {
        var state = NotchState()
        NotchMachine.reduce(&state, event: .fullscreenChanged(true))
        #expect(state.isFullscreen)
        #expect(state.phase == .hidden)
        #expect(!state.hoverCanOpen)

        // Normal hover does not open while unarmed in fullscreen
        NotchMachine.reduce(&state, event: .pointerMoved(insideHover))
        #expect(state.phase == .hidden)
        let hiddenPres = NotchMachine.panelPresentation(for: state, pointer: insideHover)
        #expect(!hiddenPres.visible)
        #expect(hiddenPres.ignoresMouseEvents)

        // Push to top 8pt edge arms reveal and begins hover dwell
        NotchMachine.reduce(&state, event: .pointerMoved(topEdgeFullscreen))
        #expect(state.revealArmed)
        #expect(state.hoverCanOpen)
        #expect(state.phase == .openingDwell)
        let armedPres = NotchMachine.panelPresentation(for: state, pointer: topEdgeFullscreen)
        #expect(armedPres.visible)
        #expect(!armedPres.ignoresMouseEvents)
    }
}
