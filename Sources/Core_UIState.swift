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
