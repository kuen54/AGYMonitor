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

        // Hover again and let dwell fire -> opens panel & activates session monitor (NO focusPanel on passive hover!)
        NotchMachine.reduce(&state, event: .pointerMoved(insideHover))
        let e3 = NotchMachine.reduce(&state, event: .openDwellFired(insideHover))
        #expect(state.phase == .open)
        #expect(state.isOpen)
        #expect(!state.awaitingPointerEntry)
        #expect(e3.contains(.setInteractive(true)))
        #expect(!e3.contains(.focusPanel))
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
        #expect(state.awaitingPointerEntry)
        #expect(eRev.contains(.cancelOpenDwell))
        #expect(eRev.contains(.cancelCloseGrace))
        #expect(eRev.contains(.refreshUsage))
        #expect(eRev.contains(.focusPanel))

        // Enter contentRect to clear awaitingPointerEntry, then leave to enter closingGrace
        NotchMachine.reduce(&state, event: .pointerMoved(insideContent))
        #expect(!state.awaitingPointerEntry)
        NotchMachine.reduce(&state, event: .pointerMoved(outsideOnScreen))
        #expect(state.phase == .closingGrace)

        let eClose = NotchMachine.reduce(&state, event: .explicitToggle)
        #expect(state.phase == .closedPill)
        #expect(!state.awaitingPointerEntry)
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
        #expect(state.awaitingPointerEntry)
        #expect(state.lastPointerSample == nil)

        // Subsequent mouse move outside MUST NOT be dropped (re-applies presentation),
        // while awaitingPointerEntry holds the notch open until the cursor enters contentRect
        let holdEff = NotchMachine.reduce(&state, event: .pointerMoved(outsideOnScreen))
        #expect(!holdEff.isEmpty)
        #expect(state.phase == .open)
        #expect(!holdEff.contains(.scheduleCloseGrace))
        #expect(state.lastPointerSample == outsideOnScreen)

        // Once pointer enters contentRect, awaitingPointerEntry clears and leaving starts closingGrace
        _ = NotchMachine.reduce(&state, event: .pointerMoved(insideContent))
        #expect(!state.awaitingPointerEntry)
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

    @Test("NotchCoordinatorMachine.reconcileScreens reconciles fullscreen changes on kept displays and invalidates pointer samples")
    func reconcileScreensHandlesKeptFullscreenAndPointerInvalidation() {
        var coord = NotchCoordinatorState()
        NotchCoordinatorMachine.start(&coord)

        let d1Normal = NotchDisplayDescriptor(displayId: 10, isBuiltin: true, isMain: true, isFullscreen: false)
        let d2FS = NotchDisplayDescriptor(displayId: 20, isBuiltin: false, isMain: false, isFullscreen: true)
        let d3Open = NotchDisplayDescriptor(displayId: 30, isBuiltin: false, isMain: false, isFullscreen: false)
        _ = NotchCoordinatorMachine.reconcileScreens(&coord, descriptors: [d1Normal, d2FS, d3Open])

        // Display 10 enters openingDwell; Display 30 opens and caches a pointer sample
        var st1 = coord.displays[10]!
        _ = NotchMachine.reduce(&st1, event: .pointerMoved(insideHover))
        #expect(st1.phase == .openingDwell)
        coord.displays[10] = st1

        var st3 = coord.displays[30]!
        _ = NotchMachine.reduce(&st3, event: .explicitReveal)
        _ = NotchMachine.reduce(&st3, event: .pointerMoved(insideContent))
        #expect(st3.lastPointerSample == insideContent)
        coord.displays[30] = st3

        // Reconcile: Display 10 enters fullscreen, Display 20 exits fullscreen, Display 30 stays normal
        let d1FS = NotchDisplayDescriptor(displayId: 10, isBuiltin: true, isMain: true, isFullscreen: true)
        let d2Normal = NotchDisplayDescriptor(displayId: 20, isBuiltin: false, isMain: false, isFullscreen: false)
        let plan = NotchCoordinatorMachine.reconcileScreens(&coord, descriptors: [d1FS, d2Normal, d3Open])

        #expect(plan.kept == [10, 20, 30])
        // Display 10 canceled open dwell and hid
        #expect(coord.displays[10]?.isFullscreen == true)
        #expect(coord.displays[10]?.phase == .hidden)
        #expect(coord.displays[10]?.lastPointerSample == nil)
        #expect(plan.keptEffects[10] == [.cancelOpenDwell, .applyPanelPresentation])

        // Display 20 exited fullscreen to closedPill
        #expect(coord.displays[20]?.isFullscreen == false)
        #expect(coord.displays[20]?.phase == .closedPill)
        #expect(plan.keptEffects[20] == [.applyPanelPresentation])

        // Display 30 kept open state, invalidated stale pointer sample, emitted no fullscreen effects
        #expect(coord.displays[30]?.phase == .open)
        #expect(coord.displays[30]?.lastPointerSample == nil)
        #expect(plan.keptEffects[30] == nil)

        // Direct invalidatePointerSample helper clears cached sample without swallowing next move
        var st3Again = coord.displays[30]!
        _ = NotchMachine.reduce(&st3Again, event: .pointerMoved(insideContent))
        coord.displays[30] = st3Again
        #expect(coord.displays[30]?.lastPointerSample == insideContent)

        NotchCoordinatorMachine.invalidatePointerSample(&coord, displayId: 30)
        #expect(coord.displays[30]?.lastPointerSample == nil)
        // Unknown display ID is a safe no-op
        NotchCoordinatorMachine.invalidatePointerSample(&coord, displayId: 999)

        var st3Post = coord.displays[30]!
        let reprocessed = NotchMachine.reduce(&st3Post, event: .pointerMoved(insideContent))
        #expect(!reprocessed.isEmpty)
    }

    @Test("NotchGeometryState.compactWindowSize fits builtin/synthetic pills, wide wings, active Live Wings, and clamps to maxWidth")
    func compactWindowSizeBoundsAndClamping() {
        #expect(NotchTiming.panelShrinkDelay == 0.42)
        #expect(NotchPanelBackingMode.compact != NotchPanelBackingMode.expanded)

        // 1. Built-in MacBook notch (180x32, default wings 39/56, no Live Wing)
        let builtin = NotchGeometryState.compactWindowSize(
            maxWidth: 600,
            closedNotchWidth: 180,
            closedNotchHeight: 32,
            leftWingWidth: 39,
            rightWingWidth: 56,
            hasActiveWing: false
        )
        // symmetricHalfSpan = 90 + 56 + 48 = 194 -> 388, floor = 180 + 260 = 440; height = max(56, 60) = 60
        #expect(builtin.width == 440)
        #expect(builtin.height == 60)
        // Must comfortably fit asymmetric compactGapOffset shift with margin
        #expect(builtin.width / 2.0 >= 180.0 / 2.0 + 56.0 + 48.0)

        // Taller built-in notch (e.g. 14"/16" MBP 38pt height -> 38 + 24 = 62pt)
        let tallBuiltin = NotchGeometryState.compactWindowSize(
            maxWidth: 600,
            closedNotchWidth: 180,
            closedNotchHeight: 38,
            leftWingWidth: 39,
            rightWingWidth: 56,
            hasActiveWing: false
        )
        #expect(tallBuiltin.height == 62)

        // 2. Synthetic external display pill (200x25, default wings, no Live Wing)
        let synthetic = NotchGeometryState.compactWindowSize(
            maxWidth: 600,
            closedNotchWidth: 200,
            closedNotchHeight: 25,
            leftWingWidth: 39,
            rightWingWidth: 56,
            hasActiveWing: false
        )
        // floor = 200 + 260 = 460; height = max(49, 60) = 60 (~18.7x fewer pixels than 600x860)
        #expect(synthetic.width == 460)
        #expect(synthetic.height == 60)
        #expect(synthetic.width * synthetic.height < (600.0 * 860.0) / 15.0)

        // 3. Asymmetric wide right wing (e.g. working TPS sparkline pill right=120, left=39)
        let wideTPS = NotchGeometryState.compactWindowSize(
            maxWidth: 600,
            closedNotchWidth: 200,
            closedNotchHeight: 25,
            leftWingWidth: 39,
            rightWingWidth: 120,
            hasActiveWing: false
        )
        // symmetricHalfSpan = 100 + 120 + 48 = 268 -> 536 > 460
        #expect(wideTPS.width == 536)
        #expect(wideTPS.height == 60)

        // 4. Active Live Wing alert expands margin from +48 to +96 per side
        let activeWing = NotchGeometryState.compactWindowSize(
            maxWidth: 600,
            closedNotchWidth: 180,
            closedNotchHeight: 32,
            leftWingWidth: 92,
            rightWingWidth: 108,
            hasActiveWing: true
        )
        // symmetricHalfSpan = 90 + 108 + 96 = 294 -> 588
        #expect(activeWing.width == 588)
        #expect(activeWing.height == 60)

        // 5. Clamping to maxWidth when Live Wing exceeds 600pt (or on a narrow display)
        let clampedWide = NotchGeometryState.compactWindowSize(
            maxWidth: 600,
            closedNotchWidth: 200,
            closedNotchHeight: 32,
            leftWingWidth: 140,
            rightWingWidth: 160,
            hasActiveWing: true
        )
        #expect(clampedWide.width == 600)

        let narrowDisplay = NotchGeometryState.compactWindowSize(
            maxWidth: 320,
            closedNotchWidth: 200,
            closedNotchHeight: 25,
            leftWingWidth: 39,
            rightWingWidth: 56,
            hasActiveWing: false
        )
        #expect(narrowDisplay.width == 320)
        #expect(narrowDisplay.height == 60)
    }

    @Test("Explicit reveal/toggle holds open via awaitingPointerEntry, emits focusPanel only on explicit open, and clears on entry or dismissal")
    func explicitRevealPointerHoldFocusAndDismissal() {
        var state = NotchState()

        // 1. Passive hover dwell open must NOT set awaitingPointerEntry or emit focusPanel
        _ = NotchMachine.reduce(&state, event: .pointerMoved(insideHover))
        let hoverEff = NotchMachine.reduce(&state, event: .openDwellFired(insideHover))
        #expect(state.phase == .open)
        #expect(!state.awaitingPointerEntry)
        #expect(!hoverEff.contains(.focusPanel))
        _ = NotchMachine.reduce(&state, event: .explicitClose)
        #expect(state.phase == .closedPill)

        // 2. Explicit toggle open sets awaitingPointerEntry and emits focusPanel AFTER setInteractive(true)
        let toggleOpenEff = NotchMachine.reduce(&state, event: .explicitToggle)
        #expect(state.phase == .open)
        #expect(state.awaitingPointerEntry)
        let interactiveIdx = toggleOpenEff.firstIndex(of: .setInteractive(true))
        let focusIdx = toggleOpenEff.firstIndex(of: .focusPanel)
        #expect(interactiveIdx != nil && focusIdx != nil && interactiveIdx! < focusIdx!)

        // Moving pointer outside (both on-screen and off-screen) holds .open without closingGrace
        let moveOut1 = NotchMachine.reduce(&state, event: .pointerMoved(outsideOnScreen))
        #expect(state.phase == .open)
        #expect(state.awaitingPointerEntry)
        #expect(!moveOut1.contains(.scheduleCloseGrace))

        let moveOut2 = NotchMachine.reduce(&state, event: .pointerMoved(.outside))
        #expect(state.phase == .open)
        #expect(state.awaitingPointerEntry)
        #expect(!moveOut2.contains(.scheduleCloseGrace))

        // Entering contentRect clears awaitingPointerEntry; leaving afterwards transitions to closingGrace
        let enterEff = NotchMachine.reduce(&state, event: .pointerMoved(insideContent))
        #expect(state.phase == .open)
        #expect(!state.awaitingPointerEntry)
        #expect(!enterEff.contains(.scheduleCloseGrace))

        let leaveEff = NotchMachine.reduce(&state, event: .pointerMoved(outsideOnScreen))
        #expect(state.phase == .closingGrace)
        #expect(leaveEff.contains(.scheduleCloseGrace))
        _ = NotchMachine.reduce(&state, event: .closeGraceFired(outsideOnScreen))
        #expect(state.phase == .closedPill)

        // 3. Dismissal via outsideClick clears awaitingPointerEntry and closes immediately
        _ = NotchMachine.reduce(&state, event: .explicitReveal)
        #expect(state.awaitingPointerEntry)
        let outsideEff = NotchMachine.reduce(&state, event: .outsideClick)
        #expect(state.phase == .closedPill)
        #expect(!state.awaitingPointerEntry)
        #expect(outsideEff.contains(.setInteractive(false)))
        #expect(outsideEff.contains(.resignKeyIfNeeded))

        // 4. Dismissal via escapePressed clears awaitingPointerEntry and closes immediately
        _ = NotchMachine.reduce(&state, event: .explicitReveal)
        #expect(state.awaitingPointerEntry)
        let escEff = NotchMachine.reduce(&state, event: .escapePressed)
        #expect(state.phase == .closedPill)
        #expect(!state.awaitingPointerEntry)
        #expect(escEff.contains(.setInteractive(false)))
        #expect(escEff.contains(.resignKeyIfNeeded))

        // 5. Dismissal via explicitClose clears awaitingPointerEntry
        _ = NotchMachine.reduce(&state, event: .explicitReveal)
        #expect(state.awaitingPointerEntry)
        let closeEff = NotchMachine.reduce(&state, event: .explicitClose)
        #expect(state.phase == .closedPill)
        #expect(!state.awaitingPointerEntry)
        #expect(closeEff.contains(.resignKeyIfNeeded))

        // 6. Fullscreen / Space change clears awaitingPointerEntry so outside moves can close normally
        _ = NotchMachine.reduce(&state, event: .explicitReveal)
        #expect(state.awaitingPointerEntry)
        _ = NotchMachine.reduce(&state, event: .fullscreenChanged(true))
        #expect(!state.awaitingPointerEntry)
        let postFSEff = NotchMachine.reduce(&state, event: .pointerMoved(outsideOnScreen))
        #expect(state.phase == .closingGrace)
        #expect(postFSEff.contains(.scheduleCloseGrace))
        _ = NotchMachine.reduce(&state, event: .explicitClose)
        #expect(state.phase == .hidden)

        // 7. Modal lock pins open against outsideClick & escapePressed
        _ = NotchMachine.reduce(&state, event: .fullscreenChanged(false))
        _ = NotchMachine.reduce(&state, event: .explicitReveal)
        _ = NotchMachine.reduce(&state, event: .modalLockAcquired(.optionsMenu))
        #expect(NotchMachine.reduce(&state, event: .outsideClick).isEmpty)
        #expect(NotchMachine.reduce(&state, event: .escapePressed).isEmpty)
        #expect(state.phase == .open)
    }
}
