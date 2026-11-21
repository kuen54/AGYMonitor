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

    @Test("SessionKeyRouter accepts macOS [.numericPad, .function] arrows and ignores hidden/inactive panels")
    func sessionKeyRouterMacOSArrowsAndGating() {
        // Real macOS arrow keys carry BOTH .numericPad AND .function simultaneously
        #expect(SessionKeyRouter.route(
            keyCode: SessionKeyRouter.keyCodeDownArrow,
            modifiers: [.numericPad, .function],
            isPanelVisible: true,
            isSessionTabActive: true
        ) == .moveSelection(delta: 1))

        #expect(SessionKeyRouter.route(
            keyCode: SessionKeyRouter.keyCodeUpArrow,
            modifiers: [.numericPad, .function],
            isPanelVisible: true,
            isSessionTabActive: true
        ) == .moveSelection(delta: -1))

        // Return activates only when panel is visible AND Sessions tab is active
        #expect(SessionKeyRouter.route(
            keyCode: SessionKeyRouter.keyCodeReturn,
            modifiers: [],
            isPanelVisible: true,
            isSessionTabActive: true
        ) == .activateSelected)

        #expect(SessionKeyRouter.route(
            keyCode: SessionKeyRouter.keyCodeReturn,
            modifiers: [],
            isPanelVisible: false,
            isSessionTabActive: true
        ) == .ignore)

        #expect(SessionKeyRouter.route(
            keyCode: SessionKeyRouter.keyCodeReturn,
            modifiers: [],
            isPanelVisible: true,
            isSessionTabActive: false
        ) == .ignore)

        // Command+Down is ignored (not a plain arrow key)
        #expect(SessionKeyRouter.route(
            keyCode: SessionKeyRouter.keyCodeDownArrow,
            modifiers: [.command, .numericPad, .function],
            isPanelVisible: true,
            isSessionTabActive: true
        ) == .ignore)
    }

    @Test("TokenFlowFocus enforces mutual exclusivity between model and channel hover and reconciles removed models")
    func tokenFlowFocusExclusivity() {
        var focus: TokenFlowFocus<String> = .none
        focus.setModel("carbon")
        #expect(focus.modelId == "carbon" && focus.channel == nil)

        // Hovering a channel immediately clears model focus (impossible to hold both!)
        focus.setChannel("cacheRead")
        #expect(focus.channel == "cacheRead" && focus.modelId == nil)

        // Exiting model while channel is active does NOT clear channel
        focus.setModel(nil)
        #expect(focus.channel == "cacheRead")

        // Model reconciliation clears vanished models
        focus.setModel("argon")
        focus.reconcile(validModelIds: ["carbon", "flash"])
        #expect(focus == .none)
    }

    @Test("ChartInspectionState clears stale hover atomically on scope change")
    func chartInspectionScopeReset() {
        var insp = ChartInspectionState<String, Int>(scope: "2026-01")
        insp.setTarget(31)
        #expect(insp.target == 31)

        // Stepping to Feb clears day 31 so "02/31 NO DATA" can never appear
        #expect(insp.syncScope("2026-02") == true)
        #expect(insp.target == nil)
        #expect(insp.syncScope("2026-02") == false)
    }

    @Test("PanelHeightState transitions .unmeasured -> .measured even when first measure matches initial height")
    func panelHeightLatchAndCompositeMemory() {
        var hs = PanelHeightState<String>(initialKey: "cost-instrument", defaultHeight: 460.0)
        #expect(hs.phase == .unmeasured)

        // First measurement matches defaultHeight within 0.5pt -> returns nil (no resize), BUT marks .measured!
        #expect(hs.recordMeasurement(for: "cost-instrument", height: 460.2) == nil)
        #expect(hs.phase == .measured)

        // Next legitimate resize MUST animate (latch bug fixed!)
        let upd = hs.recordMeasurement(for: "cost-instrument", height: 520.0)
        #expect(upd == PanelHeightUpdate(height: 520.0, animate: true))

        // Outgoing tab measurement does NOT clobber active tab height
        #expect(hs.switchKey(to: "tokens-instrument") == nil)
        #expect(hs.recordMeasurement(for: "cost-instrument", height: 480.0) == nil)
        #expect(hs.currentHeight == 520.0)
    }

    @Test("PanelHeightState suppresses height animation and applies integer ceiling when allowsAnimation is false (Menu Bar mode)")
    func panelHeightMenuBarDiscretePolicy() {
        var hs = PanelHeightState<String>(initialKey: "cost", defaultHeight: 460.0)
        #expect(hs.phase == .unmeasured)

        // First measurement transitions .unmeasured -> .measured, ceils fractional pt, animate == false
        let first = hs.recordMeasurement(for: "cost", height: 412.3, allowsAnimation: false)
        #expect(hs.phase == .measured)
        #expect(first == PanelHeightUpdate(height: 413.0, animate: false))
        #expect(hs.currentHeight == 413.0)

        // Subsequent measurement in Menu Bar mode still returns animate == false
        let second = hs.recordMeasurement(for: "cost", height: 501.2, allowsAnimation: false)
        #expect(second == PanelHeightUpdate(height: 502.0, animate: false))

        // Switch to a second key, measure it, then switch back — switchKey also returns animate == false
        #expect(hs.switchKey(to: "time-week", allowsAnimation: false) == nil)
        let weekMeasure = hs.recordMeasurement(for: "time-week", height: 359.4, allowsAnimation: false)
        #expect(weekMeasure == PanelHeightUpdate(height: 360.0, animate: false))

        let backToCost = hs.switchKey(to: "cost", allowsAnimation: false)
        #expect(backToCost == PanelHeightUpdate(height: 502.0, animate: false))
    }

    @Test("PanelHeightState dynamically toggles animation on runtime menubar <-> notch switches while preserving memory")
    func panelHeightDynamicSurfaceToggle() {
        var hs = PanelHeightState<String>(initialKey: "cost", defaultHeight: 460.0)

        // Start in Menu Bar mode (allowsAnimation: false)
        _ = hs.recordMeasurement(for: "cost", height: 400.0, allowsAnimation: false)
        _ = hs.switchKey(to: "tokens", allowsAnimation: false)
        _ = hs.recordMeasurement(for: "tokens", height: 510.0, allowsAnimation: false)
        #expect(hs.phase == .measured)

        // Switch to Notch mode (allowsAnimation: true) — memory and .measured phase stay intact, now animates!
        let toCostNotch = hs.switchKey(to: "cost", allowsAnimation: true)
        #expect(toCostNotch == PanelHeightUpdate(height: 400.0, animate: true))

        let notchGrow = hs.recordMeasurement(for: "cost", height: 445.5, allowsAnimation: true)
        #expect(notchGrow == PanelHeightUpdate(height: 445.5, animate: true))

        // Switch back to Menu Bar mode (allowsAnimation: false) — immediately disables height animation & ceils
        let backToTokensMenuBar = hs.switchKey(to: "tokens", allowsAnimation: false)
        #expect(backToTokensMenuBar == PanelHeightUpdate(height: 510.0, animate: false))
        let backToCostMenuBar = hs.switchKey(to: "cost", allowsAnimation: false)
        #expect(backToCostMenuBar == PanelHeightUpdate(height: 446.0, animate: false))
    }

    @Test("PanelHeightState isolates outgoing TimeRange measurements so YEAR never pollutes WEEK height")
    func panelHeightOutgoingTimeRangeIsolation() {
        var hs = PanelHeightState<String>(initialKey: "time-year", defaultHeight: 460.0)
        _ = hs.recordMeasurement(for: "time-year", height: 500.0, allowsAnimation: false)
        #expect(hs.currentHeight == 500.0)

        // Switch from YEAR to WEEK (first visit to WEEK, unremembered)
        #expect(hs.switchKey(to: "time-week", allowsAnimation: false) == nil)
        let weekUpdate = hs.recordMeasurement(for: "time-week", height: 360.0, allowsAnimation: false)
        #expect(weekUpdate == PanelHeightUpdate(height: 360.0, animate: false))

        // Outgoing YEAR still transitioning out reports 500pt — MUST NOT clobber WEEK's currentHeight or memory!
        #expect(hs.recordMeasurement(for: "time-year", height: 500.0, allowsAnimation: false) == nil)
        #expect(hs.currentHeight == 360.0)
        #expect(hs.memory["time-week"] == 360.0)
        #expect(hs.memory["time-year"] == 500.0)
    }

    @Test("BoundedLRUState promotes hits to MRU and evicts true LRU entry")
    func boundedLRUEvictionOrder() {
        var lru = BoundedLRUState<String, Int>(maxEntries: 2)
        lru.set(1, for: "a")
        lru.set(2, for: "b")
        // Hit "a" promotes it to MRU, so "b" is now LRU
        #expect(lru.get("a") == 1)
        lru.set(3, for: "c")
        #expect(lru.get("b") == nil)
        #expect(lru.get("a") == 1)
        #expect(lru.get("c") == 3)
    }

    @Test("TelemetryAnimationGate enforces 0Hz when hidden, reduced-motion, static, or inactive")
    func animationGateMatrix() {
        #expect(TelemetryAnimationGate.shouldAnimate(active: true, panelVisible: true, reduceMotion: false, staticRender: false))
        #expect(!TelemetryAnimationGate.shouldAnimate(active: false, panelVisible: true, reduceMotion: false, staticRender: false))
        #expect(!TelemetryAnimationGate.shouldAnimate(active: true, panelVisible: false, reduceMotion: false, staticRender: false))
        #expect(!TelemetryAnimationGate.shouldAnimate(active: true, panelVisible: true, reduceMotion: true, staticRender: false))
        #expect(!TelemetryAnimationGate.shouldAnimate(active: true, panelVisible: true, reduceMotion: false, staticRender: true))
    }
}
