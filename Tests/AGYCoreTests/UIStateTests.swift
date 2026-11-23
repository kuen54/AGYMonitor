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

    @Test("BoundedLRUState.trim(to:) preserves MRU entries in LRU order, handles no-ops, and empties cleanly at 0")
    func boundedLRUTrimBehavior() {
        var lru = BoundedLRUState<String, Int>(maxEntries: 6)
        lru.set(1, for: "a")
        lru.set(2, for: "b")
        lru.set(3, for: "c")
        lru.set(4, for: "d")
        // Promote "a" -> order is now ["b", "c", "d", "a"] (oldest -> newest)
        #expect(lru.get("a") == 1)

        // trim(to: >= count) is a no-op and preserves all entries & order
        lru.trim(to: 4)
        #expect(lru.count == 4)
        lru.trim(to: 10)
        #expect(lru.count == 4)

        // trim(to: 2) evicts oldest ("b", "c") and keeps ("d", "a") in LRU order
        lru.trim(to: 2)
        #expect(lru.count == 2)
        #expect(lru.get("b") == nil)
        #expect(lru.get("c") == nil)

        // Verify remaining LRU order without disturbing order first: trim(to: 1) must evict "d" and keep "a"
        lru.trim(to: 1)
        #expect(lru.count == 1)
        #expect(lru.get("d") == nil)
        #expect(lru.get("a") == 1)

        // trim(to: 0) empties cleanly
        lru.set(5, for: "e")
        #expect(lru.count == 2)
        lru.trim(to: 0)
        #expect(lru.count == 0)
        #expect(lru.get("a") == nil)
        #expect(lru.get("e") == nil)

        // Negative maxCount also empties cleanly and cache stays reusable
        lru.set(6, for: "f")
        lru.trim(to: -3)
        #expect(lru.count == 0)
        lru.set(7, for: "g")
        #expect(lru.count == 1)
        #expect(lru.get("g") == 7)
    }

    @Test("TelemetryAnimationGate enforces 0Hz when hidden, reduced-motion, static, or inactive")
    func animationGateMatrix() {
        #expect(TelemetryAnimationGate.shouldAnimate(active: true, panelVisible: true, reduceMotion: false, staticRender: false))
        #expect(!TelemetryAnimationGate.shouldAnimate(active: false, panelVisible: true, reduceMotion: false, staticRender: false))
        #expect(!TelemetryAnimationGate.shouldAnimate(active: true, panelVisible: false, reduceMotion: false, staticRender: false))
        #expect(!TelemetryAnimationGate.shouldAnimate(active: true, panelVisible: true, reduceMotion: true, staticRender: false))
        #expect(!TelemetryAnimationGate.shouldAnimate(active: true, panelVisible: true, reduceMotion: false, staticRender: true))
    }

    @Test("SessionDeckMachine manages live/blackBox mode switches, clears live hover, and gates live actions in blackBox")
    func sessionDeckModeTransitions() {
        var deck = SessionDeckState()
        #expect(deck.mode == .live)

        SessionDeckMachine.reduce(&deck, event: .setHoveredSession("s1", visibleIds: ["s1", "s2"]))
        SessionDeckMachine.reduce(&deck, event: .moveKeyboardSelection(delta: 1, visibleIds: ["s1", "s2"]))
        #expect(deck.hoveredSessionId == "s1")
        #expect(deck.selectedSessionId == "s1")

        // Entering blackBox clears live hover and emits .openBlackBox(nil)
        let toBB = SessionDeckMachine.reduce(&deck, event: .setMode(.blackBox))
        #expect(deck.mode == .blackBox)
        #expect(deck.hoveredSessionId == nil)
        #expect(toBB == [.openBlackBox(preferredMissionId: nil)])

        // Redundant setMode(.blackBox) is a no-op
        #expect(SessionDeckMachine.reduce(&deck, event: .setMode(.blackBox)).isEmpty)

        // While in blackBox, live activateSelected & hover are blocked
        #expect(SessionDeckMachine.reduce(&deck, event: .activateSelected(visibleIds: ["s1"])).isEmpty)
        SessionDeckMachine.reduce(&deck, event: .setHoveredSession("s1", visibleIds: ["s1"]))
        #expect(deck.hoveredSessionId == nil)

        // Explicit openBlackBox(preferredMissionId:) works from either mode and clears live hover
        let toLive = SessionDeckMachine.reduce(&deck, event: .setMode(.live))
        #expect(toLive.isEmpty)
        SessionDeckMachine.reduce(&deck, event: .setHoveredSession("s2", visibleIds: ["s1", "s2"]))
        let directReplay = SessionDeckMachine.reduce(&deck, event: .openBlackBox(preferredMissionId: "s2"))
        #expect(deck.mode == .blackBox)
        #expect(deck.hoveredSessionId == nil)
        #expect(directReplay == [.openBlackBox(preferredMissionId: "s2")])
    }

    @Test("SessionKeyRouter routes Space/Left/Right in blackBox mode and isolates live vs blackBox commands")
    func sessionKeyRouterBlackBoxMode() {
        // Space toggles play in blackBox (only with empty modifiers)
        #expect(SessionKeyRouter.route(
            keyCode: SessionKeyRouter.keyCodeSpace,
            modifiers: [],
            isPanelVisible: true,
            isSessionTabActive: true,
            mode: .blackBox
        ) == .replayTogglePlay)

        #expect(SessionKeyRouter.route(
            keyCode: SessionKeyRouter.keyCodeSpace,
            modifiers: [.command],
            isPanelVisible: true,
            isSessionTabActive: true,
            mode: .blackBox
        ) == .ignore)

        // Left / Right step replay events even with macOS [.numericPad, .function] flags
        #expect(SessionKeyRouter.route(
            keyCode: SessionKeyRouter.keyCodeLeftArrow,
            modifiers: [.numericPad, .function],
            isPanelVisible: true,
            isSessionTabActive: true,
            mode: .blackBox
        ) == .replayStepPrev)

        #expect(SessionKeyRouter.route(
            keyCode: SessionKeyRouter.keyCodeRightArrow,
            modifiers: [.numericPad, .function],
            isPanelVisible: true,
            isSessionTabActive: true,
            mode: .blackBox
        ) == .replayStepNext)

        // Up/Down/Return are ignored in blackBox mode; Space/Left/Right are ignored in live mode
        #expect(SessionKeyRouter.route(
            keyCode: SessionKeyRouter.keyCodeReturn,
            modifiers: [],
            isPanelVisible: true,
            isSessionTabActive: true,
            mode: .blackBox
        ) == .ignore)

        #expect(SessionKeyRouter.route(
            keyCode: SessionKeyRouter.keyCodeDownArrow,
            modifiers: [.numericPad, .function],
            isPanelVisible: true,
            isSessionTabActive: true,
            mode: .blackBox
        ) == .ignore)

        #expect(SessionKeyRouter.route(
            keyCode: SessionKeyRouter.keyCodeSpace,
            modifiers: [],
            isPanelVisible: true,
            isSessionTabActive: true,
            mode: .live
        ) == .ignore)

        #expect(SessionKeyRouter.route(
            keyCode: SessionKeyRouter.keyCodeLeftArrow,
            modifiers: [.numericPad, .function],
            isPanelVisible: true,
            isSessionTabActive: true,
            mode: .live
        ) == .ignore)

        // Hidden panel still gates blackBox keys
        #expect(SessionKeyRouter.route(
            keyCode: SessionKeyRouter.keyCodeSpace,
            modifiers: [],
            isPanelVisible: false,
            isSessionTabActive: true,
            mode: .blackBox
        ) == .ignore)
    }

    @Test("PolarChronometerInspectionState enforces arc/ledger mutual exclusion, pinning, and week reconciliation")
    func polarChronometerInspectionInvariants() {
        let week1 = ["2026-11-16", "2026-11-17", "2026-11-18", "2026-11-19", "2026-11-20", "2026-11-21", "2026-11-22"]
        let week2 = ["2026-11-23", "2026-11-24", "2026-11-25", "2026-11-26", "2026-11-27", "2026-11-28", "2026-11-29"]
        let arcMon = PolarArc(
            dayIndex: 0,
            dayKey: "2026-11-16",
            startAngle: 0.0,
            endAngle: 0.4,
            interval: ActiveInterval(startSec: 36000, endSec: 39600, model: "carbon"),
            inMonth: true
        )
        let arcWed = PolarArc(
            dayIndex: 2,
            dayKey: "2026-11-18",
            startAngle: 0.5,
            endAngle: 1.0,
            interval: ActiveInterval(startSec: 50000, endSec: 54000, model: "argon"),
            inMonth: true
        )

        var insp = PolarChronometerInspectionState(scopeDayKeys: week1)
        #expect(insp.effectiveDayKey == nil)
        #expect(!insp.hasAnyFocus)

        // Pin Tuesday -> effectiveDayKey falls back to pin
        #expect(insp.togglePin(dayKey: "2026-11-17") == true)
        #expect(insp.pinnedDayKey == "2026-11-17")
        #expect(insp.effectiveDayKey == "2026-11-17")
        #expect(insp.isPinnedOnly)

        // Out-of-scope day pin is rejected
        #expect(insp.togglePin(dayKey: "2026-11-25") == false)
        #expect(insp.pinnedDayKey == "2026-11-17")

        // Hovering a dial arc overrides effectiveDayKey and clears any ledger hover
        insp.setHoveredArc(arcMon)
        #expect(insp.hoveredArc == arcMon)
        #expect(insp.hoveredDayKey == nil)
        #expect(insp.effectiveDayKey == "2026-11-16")
        #expect(!insp.isPinnedOnly)

        // Hovering a ledger day atomically replaces dial arc hover (mutual exclusion!)
        insp.setHoveredDay("2026-11-19", inside: true)
        #expect(insp.hoveredArc == nil)
        #expect(insp.hoveredDayKey == "2026-11-19")
        #expect(insp.effectiveDayKey == "2026-11-19")

        // Leaving dial canvas (setHoveredArc(nil)) MUST NOT clobber active ledger hover
        insp.setHoveredArc(nil)
        #expect(insp.hoveredDayKey == "2026-11-19")

        // Stale exit for another day does not clobber current ledger hover
        insp.setHoveredDay("2026-11-16", inside: false)
        #expect(insp.hoveredDayKey == "2026-11-19")

        // Proper exit restores pinned Tuesday cleanly
        insp.setHoveredDay("2026-11-19", inside: false)
        #expect(insp.hover == nil)
        #expect(insp.effectiveDayKey == "2026-11-17")

        // Dial tap while hovering arcWed pins Wednesday; tapping empty dial unpins
        insp.setHoveredArc(arcWed)
        #expect(insp.tapDial() == true)
        #expect(insp.pinnedDayKey == "2026-11-18")
        insp.setHoveredArc(nil)
        #expect(insp.tapDial() == false)
        #expect(insp.pinnedDayKey == nil)
        #expect(insp.tapDial() == nil)

        // Same-week reconcile drops vanished hovered arc while preserving pin
        _ = insp.togglePin(dayKey: "2026-11-17")
        insp.setHoveredArc(arcWed)
        #expect(insp.reconcile(dayKeys: week1, validArcs: [arcMon]) == false)
        #expect(insp.hoveredArc == nil)
        #expect(insp.pinnedDayKey == "2026-11-17")

        // Stepping to week2 resets both hover and pin atomically
        insp.setHoveredDay("2026-11-20", inside: true)
        #expect(insp.reconcile(dayKeys: week2, validArcs: []) == true)
        #expect(insp.scopeDayKeys == week2)
        #expect(insp.hover == nil)
        #expect(insp.pinnedDayKey == nil)
    }

    @Test("MonthElevationFocus and YearContourHoverTarget pair cleanly with ChartInspectionState")
    func monthElevationAndYearContourInspection() {
        var monthInsp = ChartInspectionState<String, MonthElevationFocus>(scope: "2026-11-")
        monthInsp.setTarget(.day(14))
        #expect(monthInsp.target?.dayIndex == 14)
        #expect(monthInsp.target?.diurnalBinIndex == nil)

        monthInsp.setTarget(.diurnalBin(28))
        #expect(monthInsp.target?.dayIndex == nil)
        #expect(monthInsp.target?.diurnalBinIndex == 28)

        #expect(monthInsp.syncScope("2026-12-") == true)
        #expect(monthInsp.target == nil)

        var yearInsp = ChartInspectionState<Int, YearContourHoverTarget>(scope: 2026)
        let target = YearContourHoverTarget(dayKey: "2026-11-22", normX: 0.88, normY: 0.92)
        yearInsp.setTarget(target)
        #expect(yearInsp.target?.dayKey == "2026-11-22")
        #expect(yearInsp.target?.normPos == Point2D(x: 0.88, y: 0.92))

        #expect(yearInsp.syncScope(2025) == true)
        #expect(yearInsp.target == nil)
    }

    @Test("PanelHeightBudget caps scrollable content height strictly inside NotchPanel 860pt and MenuBarPanel bounds")
    func panelHeightBudgetPreventsHeaderTabClipping() {
        // 1. Tall external display (1415pt) in Notch mode MUST still respect 860pt NotchPanel cap
        let notchTall = PanelHeightBudget.maxContentHeight(
            hostAvailableHeight: 1415,
            isNotch: true,
            notchClosedHeight: 38,
            hasUpdateBanner: false
        )
        // Actual total height = top(33) + header/tabs/footer(116) + content + bottom(14) must be <= 860
        #expect(notchTall + 33 + 116 + 14 <= PanelHeightBudget.notchMaxWindowHeight)
        #expect(notchTall >= 600)

        // 2. Update banner reduces content budget so footer never clips
        let notchWithBanner = PanelHeightBudget.maxContentHeight(
            hostAvailableHeight: 860,
            isNotch: true,
            notchClosedHeight: 38,
            hasUpdateBanner: true
        )
        #expect(notchWithBanner == notchTall - 36)

        // 3. Compact 13" MacBook Air (772pt expanded frame) stays strictly inside 772pt
        let notchSmall = PanelHeightBudget.maxContentHeight(
            hostAvailableHeight: 772,
            isNotch: true,
            notchClosedHeight: 32,
            hasUpdateBanner: false
        )
        #expect(notchSmall + 27 + 116 + 14 <= 772)

        // 4. Floating MenuBarPanel on 5K monitor caps cleanly below menuBarMaxPanelHeight
        let menuBar5K = PanelHeightBudget.maxContentHeight(
            hostAvailableHeight: 1415,
            isNotch: false,
            hasUpdateBanner: false
        )
        #expect(menuBar5K + 132 <= PanelHeightBudget.menuBarMaxPanelHeight)

        // 5. Degenerate / non-finite heights fall back cleanly without trapping
        #expect(PanelHeightBudget.maxContentHeight(hostAvailableHeight: .nan, isNotch: true) >= PanelHeightBudget.minContentHeight)
        #expect(PanelHeightBudget.maxContentHeight(hostAvailableHeight: 120, isNotch: true) == PanelHeightBudget.minContentHeight)
    }
}
