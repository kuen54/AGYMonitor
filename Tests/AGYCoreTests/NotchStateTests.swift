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

    @Test("Clickable Live Wing accepts clicks when visible, NEVER intercepts clicks while hidden in fullscreen")
    func clickableWingFullscreenClickSafety() {
        let onWingOnly = NotchPointerSample(
            onScreen: true, inHoverBand: false, inContentRect: false,
            inRevealEdge: false, inRevealBand: false, inClickableWing: true
        )

        // Visible closed pill: pointer over Live Wing pill enables clicks
        let normalState = NotchState(phase: .closedPill, isFullscreen: false)
        let normalPres = NotchMachine.panelPresentation(for: normalState, pointer: onWingOnly)
        #expect(normalPres.visible)
        #expect(!normalPres.ignoresMouseEvents)

        // Hidden fullscreen pill: even if pointer crosses wing rect, invisible panel MUST pass clicks through!
        let hiddenFSState = NotchState(phase: .hidden, isFullscreen: true, revealArmed: false)
        let hiddenPres = NotchMachine.panelPresentation(for: hiddenFSState, pointer: onWingOnly)
        #expect(!hiddenPres.visible)
        #expect(hiddenPres.ignoresMouseEvents)
    }

    @Test("lastPointerSample auto-invalidates on explicitReveal and fullscreenChanged so mouse moves are never swallowed")
    func pointerSampleInvalidationPreventsStuckOpenAndDeadZone() {
        var state = NotchState()
        // Mouse rests outside notch -> sample cached
        _ = NotchMachine.reduce(&state, event: .pointerMoved(outsideOnScreen))
        // Duplicate pointer sample while idle is a no-op
        #expect(NotchMachine.reduce(&state, event: .pointerMoved(outsideOnScreen)).isEmpty)

        // User triggers ⌥⇧A (explicitReveal) while mouse stays outside -> MUST invalidate lastPointerSample
        _ = NotchMachine.reduce(&state, event: .explicitReveal)
        #expect(state.phase == .open)
        #expect(state.lastPointerSample == nil)

        // Subsequent mouse move outside MUST NOT be dropped -> immediately enters closingGrace
        let closeEff = NotchMachine.reduce(&state, event: .pointerMoved(outsideOnScreen))
        #expect(state.phase == .closingGrace)
        #expect(closeEff.contains(.scheduleCloseGrace))

        // Fullscreen Space switch resets revealArmed AND invalidates lastPointerSample
        _ = NotchMachine.reduce(&state, event: .explicitClose)
        _ = NotchMachine.reduce(&state, event: .fullscreenChanged(true))
        _ = NotchMachine.reduce(&state, event: .pointerMoved(topEdgeFullscreen))
        #expect(state.revealArmed)
        _ = NotchMachine.reduce(&state, event: .fullscreenChanged(false))
        _ = NotchMachine.reduce(&state, event: .fullscreenChanged(true))
        #expect(!state.revealArmed)
        // Wiggling inside top 8pt edge immediately re-arms reveal!
        _ = NotchMachine.reduce(&state, event: .pointerMoved(topEdgeFullscreen))
        #expect(state.revealArmed)
    }

    @Test("NotchGeometryState separates closed/open dimensions and aligns initial compactGapOffset")
    func notchGeometrySeparatesClosedAndOpen() {
        var geo = NotchGeometryState()
        #expect(geo.compactGapOffset == 8.5)

        let closedChanged = geo.updateContentSize(width: 280, height: 32, isOpen: false)
        let openChanged = geo.updateContentSize(width: 396, height: 540, isOpen: true)
        #expect(closedChanged)
        #expect(openChanged)

        // Closing immediately reads 280x32 (never leaks 396x540 into closedWingRect)
        let closed = geo.contentSize(isOpen: false)
        let open = geo.contentSize(isOpen: true)
        #expect(closed.width == 280 && closed.height == 32)
        #expect(open.width == 396 && open.height == 540)

        let wingsChanged = geo.updateWingWidths(left: 40, right: 80)
        #expect(wingsChanged)
        #expect(geo.compactGapOffset == 20.0)
    }

    @Test("NotchCoordinatorMachine preserves open/modal displays across screen changes, enforces single-open exclusivity, and diffs visibility")
    func notchCoordinatorInvariants() {
        var coord = NotchCoordinatorState()
        #expect(NotchCoordinatorMachine.start(&coord))
        #expect(!NotchCoordinatorMachine.start(&coord)) // idempotent

        let d1 = NotchDisplayDescriptor(displayId: 10, isBuiltin: true, isMain: true, isFullscreen: false)
        let d2 = NotchDisplayDescriptor(displayId: 20, isBuiltin: false, isMain: false, isFullscreen: false)
        let p1 = NotchCoordinatorMachine.reconcileScreens(&coord, descriptors: [d1, d2])
        #expect(p1.added.count == 2)
        #expect(p1.removed.isEmpty)

        // Open display 10 and pin a modal lock on it
        var st1 = coord.displays[10]!
        _ = NotchMachine.reduce(&st1, event: .modalLockAcquired(.optionsMenu))
        coord.displays[10] = st1

        // Reconcile when display 20 disconnects and display 30 connects: display 10 MUST keep modal lock!
        let d3 = NotchDisplayDescriptor(displayId: 30, isBuiltin: false, isMain: false, isFullscreen: false)
        let p2 = NotchCoordinatorMachine.reconcileScreens(&coord, descriptors: [d1, d3])
        #expect(p2.removed == [20])
        #expect(p2.kept == [10])
        #expect(p2.added == [d3])
        #expect(coord.displays[10]?.isPinnedOpen == true)

        // Unpin display 10; opening display 30 asks display 10 to close (single-open exclusivity)
        var st1Unpin = coord.displays[10]!
        st1Unpin.modalLocks.removeAll()
        coord.displays[10] = st1Unpin
        #expect(NotchCoordinatorMachine.displaysToCloseForExclusivity(coord, openingDisplayId: 30) == [10])

        // Deterministic primary display: mouse -> builtin -> main -> lowest ID
        #expect(NotchCoordinatorMachine.selectPrimaryDisplay(descriptors: [d3, d1], mouseDisplayId: 30) == 30)
        #expect(NotchCoordinatorMachine.selectPrimaryDisplay(descriptors: [d3, d1], mouseDisplayId: nil) == 10)

        // Visibility diffing: first apply snaps (shouldAnimate == false), duplicate is no-op, flip animates once
        let v1 = NotchCoordinatorMachine.updateVisibility(&coord, displayId: 10, visible: true)
        #expect(v1.changed && !v1.shouldAnimate)
        let v2 = NotchCoordinatorMachine.updateVisibility(&coord, displayId: 10, visible: true)
        #expect(!v2.changed)
        let v3 = NotchCoordinatorMachine.updateVisibility(&coord, displayId: 10, visible: false)
        #expect(v3.changed && v3.shouldAnimate)
    }
}
