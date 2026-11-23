import Foundation

// MARK: - Interactive UI State Machines — pure core
//
// Deterministic pure reducers for subtle UI state machines previously split across
// SwiftUI `@State` flags, AppKit `NSCursor.push/pop`, and `DispatchWorkItem` timers:
//   1. `SessionDeckMachine` — Sessions tab filter, keyboard selection, radar hover &
//      safe `Return`-key jump resolution (never jumps to a filtered-out/stale session).
//   2. `CursorStackState` — Reference-counted pointing-hand cursor stack so overlapping
//      hover regions or disappearing views can NEVER unbalance macOS's global NSCursor stack.
//   3. `ModelFocusState` — Dual-region (borehole column + callout row) hover/focus arbiter
//      with automatic reconciliation when models change or visual mode switches.
//   4. `TransientBannerState` — Generation-stamped timed banner (e.g. jump hint) so an
//      expired older timer can NEVER clear a newer banner.
//
// Foundation-only (part of AGYCore); no AppKit/SwiftUI/Combine.

// MARK: - 1. Sessions Command Deck State Machine

public enum SessionDeckMode: String, CaseIterable, Equatable, Sendable {
    case live
    case blackBox
}

public struct SessionDeckState: Equatable, Sendable {
    public var mode: SessionDeckMode
    public var filter: SessionStatusFilter
    public var selectedSessionId: String?
    public var hoveredSessionId: String?

    public init(
        mode: SessionDeckMode = .live,
        filter: SessionStatusFilter = .all,
        selectedSessionId: String? = nil,
        hoveredSessionId: String? = nil
    ) {
        self.mode = mode
        self.filter = filter
        self.selectedSessionId = selectedSessionId
        self.hoveredSessionId = hoveredSessionId
    }
}

public enum SessionDeckEvent: Equatable, Sendable {
    case setMode(SessionDeckMode)
    case openBlackBox(preferredMissionId: String? = nil)
    case selectFilter(SessionStatusFilter, visibleIds: [String])
    case reconcileVisibleIds([String])
    case moveKeyboardSelection(delta: Int, visibleIds: [String])
    case activateSelected(visibleIds: [String])
    case setHoveredSession(String?, visibleIds: [String])
}

public enum SessionDeckEffect: Equatable, Sendable {
    case jumpToSession(String)
    case openBlackBox(preferredMissionId: String?)
}

public enum SessionDeckMachine {

    @discardableResult
    public static func reduce(
        _ state: inout SessionDeckState,
        event: SessionDeckEvent
    ) -> [SessionDeckEffect] {
        switch event {
        case .setMode(let target):
            guard state.mode != target else { return [] }
            state.mode = target
            if target == .blackBox {
                state.hoveredSessionId = nil
                return [.openBlackBox(preferredMissionId: nil)]
            }
            return []

        case .openBlackBox(let preferredMissionId):
            let cleanId = (preferredMissionId?.isEmpty == false) ? preferredMissionId : nil
            state.mode = .blackBox
            state.hoveredSessionId = nil
            return [.openBlackBox(preferredMissionId: cleanId)]

        case .selectFilter(let filter, let visibleIds):
            state.filter = filter
            reconcile(&state, visibleIds: visibleIds)
            return []

        case .reconcileVisibleIds(let visibleIds):
            reconcile(&state, visibleIds: visibleIds)
            return []

        case .moveKeyboardSelection(let delta, let visibleIds):
            guard state.mode == .live else { return [] }
            state.selectedSessionId = SessionNavLogic.moveSelection(
                currentId: state.selectedSessionId,
                orderedIds: visibleIds,
                delta: delta
            )
            return []

        case .activateSelected(let visibleIds):
            guard state.mode == .live else { return [] }
            reconcile(&state, visibleIds: visibleIds)
            guard let target = state.selectedSessionId ?? visibleIds.first else {
                return []
            }
            return [.jumpToSession(target)]

        case .setHoveredSession(let sessionId, let visibleIds):
            guard state.mode == .live else {
                state.hoveredSessionId = nil
                return []
            }
            if let sid = sessionId, visibleIds.contains(sid) {
                state.hoveredSessionId = sid
            } else {
                state.hoveredSessionId = nil
            }
            return []
        }
    }

    private static func reconcile(_ state: inout SessionDeckState, visibleIds: [String]) {
        if let sel = state.selectedSessionId, !visibleIds.contains(sel) {
            state.selectedSessionId = nil
        }
        if let hov = state.hoveredSessionId, !visibleIds.contains(hov) {
            state.hoveredSessionId = nil
        }
    }
}

// MARK: - 2. Reference-Counted Pointing Cursor Stack State Machine

public enum CursorStackTransition: Equatable, Sendable {
    case none
    case pushPointingHand
    case popPointingHand
}

/// Tracks active pointing-hand hover owners by unique token.
/// Guarantees strict 1-to-1 balance against macOS's process-global `NSCursor` stack:
/// pushes ONLY on `0 -> 1` and pops ONLY on `1 -> 0`.
public struct CursorStackState: Equatable, Sendable {
    public private(set) var activeTokens: Set<String> = []

    public init() {}

    public var isPointingHandPushed: Bool { !activeTokens.isEmpty }

    public mutating func setActive(_ active: Bool, token: String) -> CursorStackTransition {
        let wasEmpty = activeTokens.isEmpty
        if active {
            activeTokens.insert(token)
            return (wasEmpty && !activeTokens.isEmpty) ? .pushPointingHand : .none
        } else {
            activeTokens.remove(token)
            return (!wasEmpty && activeTokens.isEmpty) ? .popPointingHand : .none
        }
    }

    public mutating func releaseAll() -> CursorStackTransition {
        guard !activeTokens.isEmpty else { return .none }
        activeTokens.removeAll()
        return .popPointingHand
    }
}

// MARK: - 3. Dual-Region Model Focus Arbiter (Cost Borehole & Overview)

public struct ModelFocusState: Equatable, Sendable {
    public var columnHoveredId: String?
    public var rowHoveredId: String?

    public init(columnHoveredId: String? = nil, rowHoveredId: String? = nil) {
        self.columnHoveredId = columnHoveredId
        self.rowHoveredId = rowHoveredId
    }

    /// Unified focused model ID: column hover takes priority when active, falling back
    /// seamlessly to row hover so crossing between the borehole core and ledger never flickers.
    public var effectiveFocusedId: String? {
        columnHoveredId ?? rowHoveredId
    }

    public mutating func setColumnHover(_ id: String?) {
        columnHoveredId = id
    }

    public mutating func setRowHover(_ id: String?, inside: Bool) {
        if inside {
            rowHoveredId = id
        } else if rowHoveredId == id {
            rowHoveredId = nil
        }
    }

    public mutating func reconcile(validIds: Set<String>) {
        if let cid = columnHoveredId, !validIds.contains(cid) {
            columnHoveredId = nil
        }
        if let rid = rowHoveredId, !validIds.contains(rid) {
            rowHoveredId = nil
        }
    }

    public mutating func reset() {
        columnHoveredId = nil
        rowHoveredId = nil
    }
}

// MARK: - 4. Generation-Stamped Transient Banner State Machine

public struct TransientBannerState: Equatable, Sendable {
    public private(set) var messageKey: String? = nil
    public private(set) var generation: Int = 0

    public init() {}

    /// Show a transient message (or clear immediately when `key == nil`).
    /// Returns the generation token to bind to the auto-dismiss timer when `key != nil`.
    public mutating func show(_ key: String?) -> Int? {
        generation += 1
        messageKey = key
        return key != nil ? generation : nil
    }

    /// Expire only if `token` matches the latest generation (stale timers are no-ops).
    @discardableResult
    public mutating func expire(generation token: Int) -> Bool {
        guard token == generation, messageKey != nil else { return false }
        messageKey = nil
        return true
    }
}

// MARK: - 5. Directional Tab Transition State Machine

public enum SlideDirection: Int, Equatable, Sendable {
    case forward = 1   // moving right (target index >= previous index)
    case backward = -1 // moving left (target index < previous index)
}

/// Pure directional arbiter for tab / segmented-strip switches (`01 COST`..`05 PLAN`,
/// `WEEK`/`MONTH`/`YEAR`). Computes deterministic slide direction from visual order
/// so clicks, keyboard shortcuts (`⌘1`–`⌘5`), and badge jumps share identical motion.
public struct TabTransitionState<ID: Hashable & Sendable>: Equatable, Sendable {
    public private(set) var activeId: ID
    public private(set) var direction: SlideDirection

    public init(initial: ID, direction: SlideDirection = .forward) {
        self.activeId = initial
        self.direction = direction
    }

    /// Transitions to `next` using `orderedIds` to determine horizontal slide direction.
    /// Returns the resolved `SlideDirection` if `next != activeId`, or `nil` for a no-op.
    @discardableResult
    public mutating func transition(to next: ID, in orderedIds: [ID]) -> SlideDirection? {
        guard next != activeId else { return nil }
        if let oldIndex = orderedIds.firstIndex(of: activeId),
           let newIndex = orderedIds.firstIndex(of: next) {
            direction = newIndex >= oldIndex ? .forward : .backward
        } else {
            direction = .forward
        }
        activeId = next
        return direction
    }
}

// MARK: - 6. Sessions Keyboard Router (Fixes macOS [.numericPad, .function] Arrow Bug)

public struct SessionKeyModifiers: OptionSet, Equatable, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let command    = SessionKeyModifiers(rawValue: 1 << 0)
    public static let option     = SessionKeyModifiers(rawValue: 1 << 1)
    public static let control    = SessionKeyModifiers(rawValue: 1 << 2)
    public static let shift      = SessionKeyModifiers(rawValue: 1 << 3)
    public static let numericPad = SessionKeyModifiers(rawValue: 1 << 4)
    public static let function   = SessionKeyModifiers(rawValue: 1 << 5)

    /// AppKit sets BOTH `.numericPad` and `.function` simultaneously on macOS arrow keys.
    public static let arrowKeyBenign: SessionKeyModifiers = [.numericPad, .function]
}

public enum SessionKeyAction: Equatable, Sendable {
    case moveSelection(delta: Int)
    case activateSelected
    case replayTogglePlay
    case replayStepPrev
    case replayStepNext
    case ignore
}

/// Pure keyboard-event router for `SessionTabView`.
/// Gates strictly on `isPanelVisible && isSessionTabActive` so an outgoing tab during
/// slide-out transitions or a hidden `NSPopover` can never hijack `Return` or arrow keys.
/// Routes Up/Down/Return in `.live` mode and Space/Left/Right in `.blackBox` mode.
public enum SessionKeyRouter {
    public static let keyCodeReturn: UInt16 = 36
    public static let keyCodeSpace: UInt16 = 49
    public static let keyCodeEnter: UInt16 = 76
    public static let keyCodeLeftArrow: UInt16 = 123
    public static let keyCodeRightArrow: UInt16 = 124
    public static let keyCodeDownArrow: UInt16 = 125
    public static let keyCodeUpArrow: UInt16 = 126

    public static func route(
        keyCode: UInt16,
        modifiers: SessionKeyModifiers,
        isPanelVisible: Bool,
        isSessionTabActive: Bool,
        mode: SessionDeckMode = .live
    ) -> SessionKeyAction {
        guard isPanelVisible, isSessionTabActive else { return .ignore }
        guard modifiers.subtracting(.arrowKeyBenign).isEmpty else { return .ignore }
        switch mode {
        case .live:
            switch keyCode {
            case keyCodeDownArrow:
                return .moveSelection(delta: 1)
            case keyCodeUpArrow:
                return .moveSelection(delta: -1)
            case keyCodeReturn, keyCodeEnter:
                return .activateSelected
            default:
                return .ignore
            }
        case .blackBox:
            switch keyCode {
            case keyCodeSpace:
                guard modifiers.isEmpty else { return .ignore }
                return .replayTogglePlay
            case keyCodeLeftArrow:
                return .replayStepPrev
            case keyCodeRightArrow:
                return .replayStepNext
            default:
                return .ignore
            }
        }
    }
}

// MARK: - 7. Mutually Exclusive Dual-Axis Token Flow Focus State

/// Prevents the illegal simultaneous `(focusedModelId, hoveredChannel)` state in
/// `FoldedTokenFlowChart` so header, left column, canvas, and right column ALWAYS agree.
public enum TokenFlowFocus<Channel: Hashable & Sendable>: Equatable, Sendable {
    case none
    case model(String)
    case channel(Channel)

    public var modelId: String? {
        if case .model(let id) = self { return id }
        return nil
    }

    public var channel: Channel? {
        if case .channel(let ch) = self { return ch }
        return nil
    }

    public mutating func setModel(_ id: String?) {
        if let id = id {
            self = .model(id)
        } else if case .model = self {
            self = .none
        }
    }

    public mutating func setChannel(_ ch: Channel?) {
        if let ch = ch {
            self = .channel(ch)
        } else if case .channel = self {
            self = .none
        }
    }

    public mutating func reconcile(validModelIds: Set<String>) {
        if case .model(let id) = self, !validModelIds.contains(id) {
            self = .none
        }
    }

    public mutating func reset() {
        self = .none
    }
}

// MARK: - 8. Scope-Bound Chart Hover / Inspection State

/// Generic scope-bound hover/inspection reducer for time/cost/token charts.
/// Whenever the chart's logical `scope` changes (e.g. `⌘[`/`⌘]` month/week/year stepping
/// or `⌘I` visual-mode switch), `target` resets atomically so stale readouts like
/// `"02/31 NO DATA"` or ghost week arcs can never persist across scopes.
public struct ChartInspectionState<Scope: Equatable & Sendable, Target: Equatable & Sendable>: Equatable, Sendable {
    public private(set) var scope: Scope
    public private(set) var target: Target?

    public init(scope: Scope, target: Target? = nil) {
        self.scope = scope
        self.target = target
    }

    @discardableResult
    public mutating func syncScope(_ nextScope: Scope) -> Bool {
        guard nextScope != scope else { return false }
        scope = nextScope
        target = nil
        return true
    }

    public mutating func setTarget(_ next: Target?) {
        target = next
    }

    public mutating func reset() {
        target = nil
    }
}

// MARK: - 9. Keyed Panel Height Measurement State Machine

public enum PanelHeightPhase: Equatable, Sendable {
    case unmeasured
    case measured
}

public struct PanelHeightUpdate: Equatable, Sendable {
    public let height: Double
    public let animate: Bool

    public init(height: Double, animate: Bool) {
        self.height = height
        self.animate = animate
    }
}

/// Replaces ad-hoc `PopoverHeightMemory` + `contentHeight` + `hasMeasuredInitialHeight`.
/// Keyed by composite layout state (tab + visualMode + timeRange + isCurrentMonth) and
/// ALWAYS transitions `.unmeasured -> .measured` on the first valid measurement `> 1pt`
/// even when the first measurement matches the initial/remembered height within `0.5pt`.
public struct PanelHeightState<Key: Hashable & Sendable>: Equatable, Sendable {
    public private(set) var activeKey: Key
    public private(set) var currentHeight: Double
    public private(set) var phase: PanelHeightPhase
    public private(set) var memory: [Key: Double]

    public init(
        initialKey: Key,
        defaultHeight: Double = 460.0,
        memory: [Key: Double] = [:]
    ) {
        self.activeKey = initialKey
        self.memory = memory
        self.currentHeight = memory[initialKey] ?? defaultHeight
        self.phase = .unmeasured
    }

    public mutating func recordMeasurement(
        for key: Key,
        height: Double,
        allowsAnimation: Bool = true
    ) -> PanelHeightUpdate? {
        guard height.isFinite, height > 1.0 else { return nil }
        let normalized = allowsAnimation ? height : ceil(height)
        memory[key] = normalized
        guard key == activeKey else { return nil }
        let wasMeasured = (phase == .measured)
        phase = .measured
        guard abs(normalized - currentHeight) > 0.5 else { return nil }
        currentHeight = normalized
        return PanelHeightUpdate(height: normalized, animate: allowsAnimation && wasMeasured)
    }

    public mutating func switchKey(
        to nextKey: Key,
        allowsAnimation: Bool = true
    ) -> PanelHeightUpdate? {
        activeKey = nextKey
        guard let remembered = memory[nextKey] else { return nil }
        let target = allowsAnimation ? remembered : ceil(remembered)
        guard abs(target - currentHeight) > 0.5 else { return nil }
        currentHeight = target
        return PanelHeightUpdate(height: target, animate: allowsAnimation && phase == .measured)
    }
}

/// Pure vertical height budget guaranteeing `PopoverView`'s header, tab bar, update banner,
/// and footer stay pinned inside the hosting window (`NotchPanel` or floating `MenuBarPanel`)
/// and NEVER clip off the top/bottom when a long session list or tall tab content overflows.
public enum PanelHeightBudget {
    /// Hard vertical cap matching `NotchController.maxWindowSize.height`.
    public static let notchMaxWindowHeight: Double = 860.0
    /// Comfortable vertical cap for floating `MenuBarPanel` on large 4K/5K monitors.
    public static let menuBarMaxPanelHeight: Double = 820.0
    /// Minimum scrollable tab content height so compact/short screens remain usable.
    public static let minContentHeight: Double = 220.0

    public static func maxContentHeight(
        hostAvailableHeight: Double,
        isNotch: Bool,
        notchClosedHeight: Double = 0.0,
        hasUpdateBanner: Bool = false
    ) -> Double {
        let safeHost = hostAvailableHeight.isFinite && hostAvailableHeight > 0.0
            ? hostAvailableHeight
            : 900.0
        let updateReserve: Double = hasUpdateBanner ? 36.0 : 0.0
        if isNotch {
            // NotchPanel window height is bounded by `notchMaxWindowHeight` (860pt).
            // Reserve top notch padding + bottomMargin (14) + PopoverView header/tabs/footer (~132).
            let windowCap = min(safeHost, notchMaxWindowHeight)
            let safeClosedH = notchClosedHeight.isFinite && notchClosedHeight > 0.0 ? notchClosedHeight : 0.0
            let notchTop = max(8.0, safeClosedH + 6.0 - 11.0)
            let chromeReserve = notchTop + 14.0 + 132.0 + updateReserve
            return max(minContentHeight, floor(windowCap - chromeReserve))
        } else {
            let windowCap = min(safeHost - 24.0, menuBarMaxPanelHeight)
            let chromeReserve = 132.0 + updateReserve
            return max(minContentHeight, floor(windowCap - chromeReserve))
        }
    }
}

// MARK: - 10. Generic Pure Bounded LRU Cache

/// Unified pure value-type LRU cache replacing 5 duplicated ad-hoc `entries + order`
/// caches across Views/Instruments (and fixing the FIFO hit bug in `PolarWeekArcsCache`).
public struct BoundedLRUState<Key: Hashable, Value> {
    public let maxEntries: Int
    private var entries: [Key: Value] = [:]
    private var order: [Key] = []

    public init(maxEntries: Int) {
        self.maxEntries = max(1, maxEntries)
    }

    public var count: Int { entries.count }

    /// Look up `key` and promote it to most-recently-used on hit.
    public mutating func get(_ key: Key) -> Value? {
        guard let hit = entries[key] else { return nil }
        if let idx = order.firstIndex(of: key), idx != order.count - 1 {
            order.remove(at: idx)
            order.append(key)
        }
        return hit
    }

    /// Insert or update `key`, promoting it to MRU and evicting LRU entries past `maxEntries`.
    public mutating func set(_ value: Value, for key: Key) {
        entries[key] = value
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
        }
        order.append(key)
        while order.count > maxEntries {
            let evicted = order.removeFirst()
            entries.removeValue(forKey: evicted)
        }
    }

    /// Retain at most `max(0, maxCount)` most-recently-used entries, evicting the oldest
    /// entries from the front of `order`.
    public mutating func trim(to maxCount: Int) {
        let target = max(0, maxCount)
        if target == 0 {
            removeAll()
            return
        }
        guard order.count > target else { return }
        let evictCount = order.count - target
        for key in order.prefix(evictCount) {
            entries.removeValue(forKey: key)
        }
        order.removeFirst(evictCount)
    }

    public mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
    }
}

// MARK: - 11. Unified Telemetry Animation Gate

/// Single canonical 0 Hz idle / Reduce Motion / static-render animation gate.
public enum TelemetryAnimationGate {
    public static func shouldAnimate(
        active: Bool = true,
        panelVisible: Bool,
        reduceMotion: Bool,
        staticRender: Bool
    ) -> Bool {
        active && panelVisible && !reduceMotion && !staticRender
    }
}

// MARK: - 12. Time Instrument Inspection States (Polar Chronometer, Month Elevation, Year Contour)

/// Mutually exclusive hover target for `PolarChronometerWeekChart`.
/// Prevents simultaneous dial-arc hover and day-ledger hover so center hub,
/// readout row, meridian gate, and ledger cells always agree.
public enum PolarHoverTarget: Equatable, Sendable {
    case arc(PolarArc)
    case day(String)

    public var dayKey: String {
        switch self {
        case .arc(let arc): return arc.dayKey
        case .day(let key): return key
        }
    }

    public var arc: PolarArc? {
        if case .arc(let arc) = self { return arc }
        return nil
    }

    public var ledgerDayKey: String? {
        if case .day(let key) = self { return key }
        return nil
    }
}

/// Pure scope-bound inspection state for `PolarChronometerInteractiveDeck`.
/// Owns `scopeDayKeys`, mutually exclusive dial/ledger `hover`, and click-to-pin `pinnedDayKey`.
public struct PolarChronometerInspectionState: Equatable, Sendable {
    public private(set) var scopeDayKeys: [String]
    public private(set) var hover: PolarHoverTarget?
    public private(set) var pinnedDayKey: String?

    public init(
        scopeDayKeys: [String] = [],
        hover: PolarHoverTarget? = nil,
        pinnedDayKey: String? = nil
    ) {
        self.scopeDayKeys = scopeDayKeys
        self.hover = hover
        self.pinnedDayKey = pinnedDayKey
    }

    /// Currently hovered dial arc (mutually exclusive with ledger day hover).
    public var hoveredArc: PolarArc? { hover?.arc }

    /// Currently hovered ledger day key (mutually exclusive with dial arc hover).
    public var hoveredDayKey: String? { hover?.ledgerDayKey }

    /// Single canonical focused day key: active hover (arc or ledger) takes priority,
    /// falling back seamlessly to pinned day.
    public var effectiveDayKey: String? {
        hover?.dayKey ?? pinnedDayKey
    }

    /// True when a day is pinned and nothing is actively hovered.
    public var isPinnedOnly: Bool {
        hover == nil && pinnedDayKey != nil
    }

    /// True when any arc/ledger hover or pin focus is active.
    public var hasAnyFocus: Bool {
        hover != nil || pinnedDayKey != nil
    }

    /// Sets or clears dial arc hover. Setting a non-nil arc atomically replaces any
    /// ledger day hover (mutual exclusion). Clearing (`nil`) clears ONLY if currently
    /// hovering an arc, so leaving the dial canvas never clobbers a ledger hover.
    public mutating func setHoveredArc(_ arc: PolarArc?) {
        if let arc = arc {
            guard scopeDayKeys.isEmpty || scopeDayKeys.contains(arc.dayKey) else {
                if case .arc = hover { hover = nil }
                return
            }
            hover = .arc(arc)
        } else if case .arc = hover {
            hover = nil
        }
    }

    /// Sets or clears ledger day hover. Entering (`inside == true`) atomically replaces
    /// any dial arc hover (mutual exclusion). Exiting (`inside == false`) clears ONLY
    /// if `hover == .day(dayKey)` so stale exit callbacks never clobber a newer hover.
    public mutating func setHoveredDay(_ dayKey: String, inside: Bool) {
        if inside {
            guard scopeDayKeys.isEmpty || scopeDayKeys.contains(dayKey) else { return }
            hover = .day(dayKey)
        } else if hover == .day(dayKey) {
            hover = nil
        }
    }

    /// Toggles pin on `dayKey` (validated against `scopeDayKeys` when non-empty).
    /// Returns `true` if `dayKey` is now pinned, `false` if unpinned or rejected.
    @discardableResult
    public mutating func togglePin(dayKey: String) -> Bool {
        if pinnedDayKey == dayKey {
            pinnedDayKey = nil
            return false
        }
        guard scopeDayKeys.isEmpty || scopeDayKeys.contains(dayKey) else {
            return false
        }
        pinnedDayKey = dayKey
        return true
    }

    /// Clears the current pin if present. Returns `true` if a pin was cleared.
    @discardableResult
    public mutating func clearPin() -> Bool {
        guard pinnedDayKey != nil else { return false }
        pinnedDayKey = nil
        return true
    }

    /// Handles a tap on the dial canvas: toggles pin on the hovered arc's day if hovering
    /// an arc, otherwise unpins an active pin. Returns `true` if pinned, `false` if unpinned,
    /// or `nil` if no state changed.
    @discardableResult
    public mutating func tapDial() -> Bool? {
        if let arc = hoveredArc {
            return togglePin(dayKey: arc.dayKey)
        }
        return clearPin() ? false : nil
    }

    /// Reconciles inspection state against updated week `dayKeys` and optional live `validArcs`.
    /// Stepping to a different week (`dayKeys != scopeDayKeys`) resets both hover and pin atomically.
    /// Within the same week, drops any hovered arc missing from `validArcs` while preserving pin.
    /// Returns `true` if the week scope changed.
    @discardableResult
    public mutating func reconcile(dayKeys: [String], validArcs: [PolarArc]? = nil) -> Bool {
        if dayKeys != scopeDayKeys {
            scopeDayKeys = dayKeys
            hover = nil
            pinnedDayKey = nil
            return true
        }
        if let pin = pinnedDayKey, !dayKeys.contains(pin) {
            pinnedDayKey = nil
        }
        switch hover {
        case .arc(let arc):
            if !dayKeys.contains(arc.dayKey) || (validArcs != nil && !(validArcs!.contains(arc))) {
                hover = nil
            }
        case .day(let key):
            if !dayKeys.contains(key) {
                hover = nil
            }
        case nil:
            break
        }
        return false
    }

    /// Clears all transient hover and pin state (e.g. when the panel hides).
    public mutating func reset() {
        hover = nil
        pinnedDayKey = nil
    }
}

/// Mutually exclusive upper/lower deck hover focus for `MonthElevationInstrumentChart`
/// (paired with `ChartInspectionState<String, MonthElevationFocus>`).
public enum MonthElevationFocus: Equatable, Sendable {
    case day(Int)
    case diurnalBin(Int)

    public var dayIndex: Int? {
        if case .day(let idx) = self { return idx }
        return nil
    }

    public var diurnalBinIndex: Int? {
        if case .diurnalBin(let idx) = self { return idx }
        return nil
    }
}

/// Atomic hover target for `TopographicYearContourChart` pairing the resolved day key
/// with normalized contour reticle coordinates (paired with
/// `ChartInspectionState<Int, YearContourHoverTarget>`).
public struct YearContourHoverTarget: Equatable, Sendable {
    public let dayKey: String
    public let normX: Double
    public let normY: Double

    public var normPos: Point2D {
        Point2D(x: normX, y: normY)
    }

    public init(dayKey: String, normX: Double, normY: Double) {
        self.dayKey = dayKey
        self.normX = normX
        self.normY = normY
    }
}
