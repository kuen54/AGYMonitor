import Foundation
import Testing
@testable import AGYCore

@Suite("Core_UIState")
struct UIStateTests {

    @Test("SessionDeckMachine clears stale selection on filter/list change so Return never jumps to hidden session")
    func sessionDeckReconcilesStaleSelection() {
        var deck = SessionDeckState()
        let allIds = ["s-wait", "s-run", "s-idle"]

        // Move keyboard cursor to s-run
        SessionDeckMachine.reduce(&deck, event: .moveKeyboardSelection(delta: 1, visibleIds: allIds))
        SessionDeckMachine.reduce(&deck, event: .moveKeyboardSelection(delta: 1, visibleIds: allIds))
        #expect(deck.selectedSessionId == "s-run")

        // Switch filter to .waiting where only "s-wait" is visible -> stale "s-run" MUST be cleared
        SessionDeckMachine.reduce(&deck, event: .selectFilter(.waiting, visibleIds: ["s-wait"]))
        #expect(deck.filter == .waiting)
        #expect(deck.selectedSessionId == nil)

        // Pressing Return jumps to visible "s-wait", NOT hidden "s-run"!
        let effects = SessionDeckMachine.reduce(&deck, event: .activateSelected(visibleIds: ["s-wait"]))
        #expect(effects == [.jumpToSession("s-wait")])

        // If filter yields 0 visible sessions, Return emits no jump
        let emptyEffects = SessionDeckMachine.reduce(&deck, event: .activateSelected(visibleIds: []))
        #expect(emptyEffects.isEmpty)

        // Hovering a session that later disappears reconciles to nil
        SessionDeckMachine.reduce(&deck, event: .setHoveredSession("s-wait", visibleIds: ["s-wait"]))
        #expect(deck.hoveredSessionId == "s-wait")
        SessionDeckMachine.reduce(&deck, event: .reconcileVisibleIds([]))
        #expect(deck.hoveredSessionId == nil)
    }

    @Test("CursorStackState balances global push/pop strictly on 0->1 and 1->0 across overlapping views")
    func cursorStackBalance() {
        var stack = CursorStackState()

        // First hover pushes
        #expect(stack.setActive(true, token: "row-1") == .pushPointingHand)
        #expect(stack.isPointingHandPushed)

        // Overlapping hover from radar or second row does NOT double-push
        #expect(stack.setActive(true, token: "radar") == .none)
        #expect(stack.setActive(true, token: "row-1") == .none)

        // First view exiting does NOT pop while radar still holds cursor
        #expect(stack.setActive(false, token: "row-1") == .none)
        #expect(stack.isPointingHandPushed)

        // Duplicate exit for already-cleared token does NOT underflow
        #expect(stack.setActive(false, token: "row-1") == .none)

        // Last owner exiting pops once
        #expect(stack.setActive(false, token: "radar") == .popPointingHand)
        #expect(!stack.isPointingHandPushed)

        // releaseAll safety hatch pops once if any tokens remain, no-op if already empty
        #expect(stack.releaseAll() == .none)
        _ = stack.setActive(true, token: "row-2")
        _ = stack.setActive(true, token: "row-3")
        #expect(stack.releaseAll() == .popPointingHand)
        #expect(!stack.isPointingHandPushed)
    }

    @Test("ModelFocusState arbitrates borehole column and row hover and reconciles removed models")
    func modelFocusArbitrationAndReconcile() {
        var focus = ModelFocusState()

        focus.setRowHover("carbon", inside: true)
        #expect(focus.effectiveFocusedId == "carbon")

        // Column hover takes priority while active
        focus.setColumnHover("hydrogen")
        #expect(focus.effectiveFocusedId == "hydrogen")

        // Leaving column smoothly restores row hover without flicker
        focus.setColumnHover(nil)
        #expect(focus.effectiveFocusedId == "carbon")

        // Stale exit for a different row does not clear current row
        focus.setRowHover("neon", inside: false)
        #expect(focus.effectiveFocusedId == "carbon")

        // Model removed by live refresh clears stale focus automatically
        focus.reconcile(validIds: ["neon", "flash"])
        #expect(focus.effectiveFocusedId == nil)
    }

    @Test("TransientBannerState ignores expired timers from older banner generations")
    func transientBannerAntiRace() {
        var banner = TransientBannerState()

        let g1 = banner.show("sessionJumpAppOnly")
        #expect(g1 == 1)
        #expect(banner.messageKey == "sessionJumpAppOnly")

        // Newer banner supersedes g1
        let g2 = banner.show("sessionJumpNeedsPermission")
        #expect(g2 == 2)
        #expect(banner.messageKey == "sessionJumpNeedsPermission")

        // Old timer for g1 firing MUST NOT clear g2!
        #expect(banner.expire(generation: 1) == false)
        #expect(banner.messageKey == "sessionJumpNeedsPermission")

        // Timer for g2 clears cleanly
        #expect(banner.expire(generation: 2) == true)
        #expect(banner.messageKey == nil)
    }

    @Test("TabTransitionState resolves forward/backward slide directions and ignores redundant transitions")
    func tabTransitionDirectionArbiter() {
        let tabs = ["cost", "tokens", "time", "session", "plan"]
        var nav = TabTransitionState(initial: "cost")

        // Same-tab transition is a no-op
        #expect(nav.transition(to: "cost", in: tabs) == nil)
        #expect(nav.activeId == "cost")

        // Moving right -> forward
        #expect(nav.transition(to: "time", in: tabs) == .forward)
        #expect(nav.activeId == "time")
        #expect(nav.direction == .forward)

        // Moving further right -> forward
        #expect(nav.transition(to: "plan", in: tabs) == .forward)
        #expect(nav.direction == .forward)

        // Moving left -> backward
        #expect(nav.transition(to: "tokens", in: tabs) == .backward)
        #expect(nav.activeId == "tokens")
        #expect(nav.direction == .backward)

        // Unknown tab fallback defaults safely to forward
        #expect(nav.transition(to: "unknown", in: tabs) == .forward)
        #expect(nav.activeId == "unknown")
    }
}
