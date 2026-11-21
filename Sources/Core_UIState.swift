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

public struct SessionDeckState: Equatable, Sendable {
    public var filter: SessionStatusFilter
    public var selectedSessionId: String?
    public var hoveredSessionId: String?

    public init(
        filter: SessionStatusFilter = .all,
        selectedSessionId: String? = nil,
        hoveredSessionId: String? = nil
    ) {
        self.filter = filter
        self.selectedSessionId = selectedSessionId
        self.hoveredSessionId = hoveredSessionId
    }
}

public enum SessionDeckEvent: Equatable, Sendable {
    case selectFilter(SessionStatusFilter, visibleIds: [String])
    case reconcileVisibleIds([String])
    case moveKeyboardSelection(delta: Int, visibleIds: [String])
    case activateSelected(visibleIds: [String])
    case setHoveredSession(String?, visibleIds: [String])
}

public enum SessionDeckEffect: Equatable, Sendable {
    case jumpToSession(String)
}

public enum SessionDeckMachine {

    @discardableResult
    public static func reduce(
        _ state: inout SessionDeckState,
        event: SessionDeckEvent
    ) -> [SessionDeckEffect] {
        switch event {
        case .selectFilter(let filter, let visibleIds):
            state.filter = filter
            reconcile(&state, visibleIds: visibleIds)
            return []

        case .reconcileVisibleIds(let visibleIds):
            reconcile(&state, visibleIds: visibleIds)
            return []

        case .moveKeyboardSelection(let delta, let visibleIds):
            state.selectedSessionId = SessionNavLogic.moveSelection(
                currentId: state.selectedSessionId,
                orderedIds: visibleIds,
                delta: delta
            )
            return []

        case .activateSelected(let visibleIds):
            reconcile(&state, visibleIds: visibleIds)
            guard let target = state.selectedSessionId ?? visibleIds.first else {
                return []
            }
            return [.jumpToSession(target)]

        case .setHoveredSession(let sessionId, let visibleIds):
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
    case ignore
}

/// Pure keyboard-event router for `SessionTabView`.
/// Gates strictly on `isPanelVisible && isSessionTabActive` so an outgoing tab during
/// slide-out transitions or a hidden `NSPopover` can never hijack `Return` or arrow keys.
public enum SessionKeyRouter {
    public static let keyCodeReturn: UInt16 = 36
    public static let keyCodeEnter: UInt16 = 76
    public static let keyCodeDownArrow: UInt16 = 125
    public static let keyCodeUpArrow: UInt16 = 126

    public static func route(
        keyCode: UInt16,
        modifiers: SessionKeyModifiers,
        isPanelVisible: Bool,
        isSessionTabActive: Bool
    ) -> SessionKeyAction {
        guard isPanelVisible, isSessionTabActive else { return .ignore }
        guard modifiers.subtracting(.arrowKeyBenign).isEmpty else { return .ignore }
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
