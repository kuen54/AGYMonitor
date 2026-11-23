import Foundation

// MARK: - Poll Cadence, FSEvents Throttle, MenuBar Anchor, Logo & Session Status — pure core
//
// Consolidates small UI/runtime state machines AND provides the single canonical
// `SessionLogic.resolveLiveSessionStatus(...)` so `SessionMonitor` and `AITitleReader`
// never diverge on `swarm_wait`, `ask_question`, or DB `not_fully_idle` status priority.
//
// Foundation-only (part of AGYCore); uses Double instead of CGFloat.

public enum SessionPollCadence {

    public static func interval(
        started: Bool,
        fsHealthy: Bool,
        isActive: Bool,
        liveCount: Int
    ) -> TimeInterval? {
        guard started else { return nil }
        if liveCount > 0 {
            return isActive ? 2.0 : 6.0
        }
        if isActive {
            return 6.0
        }
        return fsHealthy ? 15.0 : 6.0
    }

    public static func shouldRetryFSWatcher(
        started: Bool,
        fsHealthy: Bool,
        now: Date,
        lastAttemptAt: Date?,
        retryInterval: TimeInterval = 30.0
    ) -> Bool {
        guard started, !fsHealthy else { return false }
        guard let last = lastAttemptAt else { return true }
        return now.timeIntervalSince(last) >= retryInterval
    }
}

// MARK: - SessionMonitor Runtime Lifecycle State Machine

public struct SessionMonitorLifecycleState: Equatable, Sendable {
    public var isStarted: Bool
    public var isActive: Bool
    public var fsHealthy: Bool
    public var lastFSAttemptAt: Date?
    public var pollInterval: TimeInterval?
    public var lastLiveCount: Int
    /// Monotonic generation bumped on `stop()` so in-flight async `onChange` / `markSeen`
    /// dispatches can NEVER publish stale snapshots after shutdown.
    public var runGeneration: Int
    /// Sorted list of directories currently attached to the active `FSEventStream`.
    /// Mutated exclusively by `SessionMonitorLifecycleMachine`.
    public fileprivate(set) var watchedDirs: [String]
    /// Sorted list of directories last attempted for FSEvents so failed starts don't
    /// thrash on every scan tick while still allowing brand-new directories to attach immediately.
    public fileprivate(set) var lastAttemptedDirs: [String]

    public init(
        isStarted: Bool = false,
        isActive: Bool = false,
        fsHealthy: Bool = false,
        lastFSAttemptAt: Date? = nil,
        pollInterval: TimeInterval? = nil,
        lastLiveCount: Int = 0,
        runGeneration: Int = 0,
        watchedDirs: [String] = [],
        lastAttemptedDirs: [String] = []
    ) {
        self.isStarted = isStarted
        self.isActive = isActive
        self.fsHealthy = fsHealthy
        self.lastFSAttemptAt = lastFSAttemptAt
        self.pollInterval = pollInterval
        self.lastLiveCount = lastLiveCount
        self.runGeneration = runGeneration
        self.watchedDirs = Array(Set(watchedDirs)).sorted()
        self.lastAttemptedDirs = Array(Set(lastAttemptedDirs)).sorted()
    }
}

public enum SessionMonitorLifecycleEvent: Equatable, Sendable {
    case start(now: Date)
    case stop
    case setActive(Bool, now: Date)
    case fsWatcherAttempted(healthy: Bool, watchedDirs: [String], at: Date)
    case reconcileWatchedDirs([String])
    case fsEventReceived
    case fsCoalesceFired(now: Date)
    case pollTimerFired(now: Date)
    case scanCompleted(liveCount: Int)
}

public enum SessionMonitorLifecycleEffect: Equatable, Sendable {
    case startFSWatcher
    case restartFSEvents(dirs: [String])
    case stopFSWatcher
    case scheduleFSCoalesce
    case cancelFSCoalesce
    case runScan
    case setPollTimer(TimeInterval?)
}

/// Pure lifecycle reducer for `SessionMonitor`. Replaces 7 loose mutable vars
/// (`started`, `isActive`, `fsHealthy`, `lastFSAttemptAt`, `pollInterval`,
/// `lastLiveCount`, `fsCoalesceWork`) and guarantees post-`stop()` FS or timer
/// callbacks can NEVER spawn `ps`/`lsof` or emit stale `onChange` updates.
public enum SessionMonitorLifecycleMachine {

    @discardableResult
    public static func reduce(
        _ state: inout SessionMonitorLifecycleState,
        event: SessionMonitorLifecycleEvent
    ) -> [SessionMonitorLifecycleEffect] {
        switch event {
        case .start(let now):
            guard !state.isStarted else { return [] }
            state.isStarted = true
            state.lastFSAttemptAt = now
            return [.startFSWatcher, .runScan]

        case .stop:
            guard state.isStarted else { return [] }
            state.isStarted = false
            state.fsHealthy = false
            state.pollInterval = nil
            state.watchedDirs = []
            state.lastAttemptedDirs = []
            state.runGeneration += 1
            return [.cancelFSCoalesce, .setPollTimer(nil), .stopFSWatcher]

        case .setActive(let active, let now):
            guard state.isActive != active else { return [] }
            state.isActive = active
            guard state.isStarted else { return [] }
            if active {
                var effects: [SessionMonitorLifecycleEffect] = []
                if SessionPollCadence.shouldRetryFSWatcher(
                    started: state.isStarted,
                    fsHealthy: state.fsHealthy,
                    now: now,
                    lastAttemptAt: state.lastFSAttemptAt
                ) {
                    state.lastFSAttemptAt = now
                    effects.append(.startFSWatcher)
                }
                effects.append(.runScan)
                return effects
            }
            // Closing panel: relax poll timer cleanly (e.g. 2s -> 6s) without spawning a redundant scan.
            return reconcilePollEffects(&state)

        case .fsWatcherAttempted(let healthy, let dirs, let at):
            state.lastFSAttemptAt = at
            let normalized = Array(Set(dirs)).sorted()
            if state.isStarted && healthy {
                state.fsHealthy = true
                state.watchedDirs = normalized
                state.lastAttemptedDirs = normalized
            } else {
                state.fsHealthy = false
                state.watchedDirs = []
                state.lastAttemptedDirs = state.isStarted ? normalized : []
            }
            return reconcilePollEffects(&state)

        case .reconcileWatchedDirs(let candidateDirs):
            guard state.isStarted else { return [] }
            let normalized = Array(Set(candidateDirs)).sorted()
            guard !normalized.isEmpty else {
                if state.fsHealthy || !state.watchedDirs.isEmpty {
                    state.fsHealthy = false
                    state.watchedDirs = []
                    state.lastAttemptedDirs = []
                    var effects: [SessionMonitorLifecycleEffect] = [.stopFSWatcher]
                    effects.append(contentsOf: reconcilePollEffects(&state))
                    return effects
                }
                return []
            }
            // Even when `fsHealthy == true` (e.g. CLI-only setup where Desktop/IDE brain dir appears later),
            // newly discovered or removed directories trigger `.restartFSEvents(dirs:)`.
            if state.fsHealthy {
                guard normalized != state.watchedDirs else { return [] }
                state.lastAttemptedDirs = normalized
                return [.restartFSEvents(dirs: normalized)]
            }
            // Unhealthy watcher: immediately attach if the directory set changed (e.g. [] -> ["/cli"]),
            // but avoid thrashing on the exact same failing directory set (30s retry handles that).
            guard normalized != state.lastAttemptedDirs else { return [] }
            state.lastAttemptedDirs = normalized
            return [.restartFSEvents(dirs: normalized)]

        case .fsEventReceived:
            guard state.isStarted else { return [] }
            return [.scheduleFSCoalesce]

        case .fsCoalesceFired(let now), .pollTimerFired(let now):
            guard state.isStarted else { return [] }
            var effects: [SessionMonitorLifecycleEffect] = []
            if SessionPollCadence.shouldRetryFSWatcher(
                started: state.isStarted,
                fsHealthy: state.fsHealthy,
                now: now,
                lastAttemptAt: state.lastFSAttemptAt
            ) {
                state.lastFSAttemptAt = now
                effects.append(.startFSWatcher)
            }
            effects.append(.runScan)
            return effects

        case .scanCompleted(let liveCount):
            guard state.isStarted else { return [] }
            state.lastLiveCount = max(0, liveCount)
            return reconcilePollEffects(&state)
        }
    }

    private static func reconcilePollEffects(
        _ state: inout SessionMonitorLifecycleState
    ) -> [SessionMonitorLifecycleEffect] {
        let desired = SessionPollCadence.interval(
            started: state.isStarted,
            fsHealthy: state.fsHealthy,
            isActive: state.isActive,
            liveCount: state.lastLiveCount
        )
        if state.pollInterval != desired {
            state.pollInterval = desired
            return [.setPollTimer(desired)]
        }
        return []
    }
}

public struct FSEventsThrottleState: Equatable, Sendable {
    public let debounceSeconds: TimeInterval
    public let minGapSeconds: TimeInterval
    public private(set) var lastRefreshTriggeredAt: Date?

    public init(
        debounceSeconds: TimeInterval = 3.0,
        minGapSeconds: TimeInterval = 120.0,
        lastRefreshTriggeredAt: Date? = nil
    ) {
        self.debounceSeconds = debounceSeconds
        self.minGapSeconds = minGapSeconds
        self.lastRefreshTriggeredAt = lastRefreshTriggeredAt
    }

    /// Recorded across ALL refresh sources (⌘R, timer, wake, popover open, and FSEvents)
    /// so an FSEvent right after a manual scan respects `minGapSeconds`.
    public mutating func noteRefreshTriggered(at date: Date) {
        lastRefreshTriggeredAt = date
    }

    public func delayForFSEvent(at now: Date) -> TimeInterval {
        guard let last = lastRefreshTriggeredAt else { return debounceSeconds }
        let untilWindowEnd = last.addingTimeInterval(minGapSeconds).timeIntervalSince(now)
        return max(debounceSeconds, untilWindowEnd)
    }
}

// MARK: - Brain FSEvents Watcher & Refresh Scheduler Lifecycle Machine

public struct BrainWatcherLifecycleState: Equatable, Sendable {
    public var isStarted: Bool
    public var watchedPaths: [String]
    public var lastWatchAttemptAt: Date?
    public var debounceGeneration: Int
    public var wakeGeneration: Int
    public var throttle: FSEventsThrottleState

    public init(
        isStarted: Bool = false,
        watchedPaths: [String] = [],
        lastWatchAttemptAt: Date? = nil,
        debounceGeneration: Int = 0,
        wakeGeneration: Int = 0,
        throttle: FSEventsThrottleState = FSEventsThrottleState()
    ) {
        self.isStarted = isStarted
        self.watchedPaths = watchedPaths
        self.lastWatchAttemptAt = lastWatchAttemptAt
        self.debounceGeneration = debounceGeneration
        self.wakeGeneration = wakeGeneration
        self.throttle = throttle
    }

    public var isWatcherHealthy: Bool { !watchedPaths.isEmpty }
}

public enum BrainWatcherLifecycleEvent: Equatable, Sendable {
    case start(candidatePaths: [String], now: Date)
    case fsWatcherResult(watchedPaths: [String], at: Date)
    case reconcileWatchPaths(candidatePaths: [String], now: Date)
    case fsEventReceived(now: Date)
    case debounceFired(generation: Int)
    case refreshTriggered(at: Date)
    case periodicTimerFired(candidatePaths: [String], now: Date)
    case wakeReceived
    case wakeTimerFired(generation: Int, candidatePaths: [String], now: Date)
    case terminate
}

public enum BrainWatcherLifecycleEffect: Equatable, Sendable {
    case startPeriodicTimer
    case stopPeriodicTimer
    case startFSWatcher(paths: [String])
    case stopFSWatcher
    case scheduleDebounce(generation: Int, delay: TimeInterval)
    case cancelDebounce
    case scheduleWakeRefresh(generation: Int, delay: TimeInterval)
    case cancelWakeRefresh
    case triggerRefresh
}

/// Pure lifecycle reducer for `AppDelegate`'s Antigravity brain FSEvents watcher,
/// 30-min periodic timer, sleep/wake refresh, and 120s minimum-gap debounce floor.
/// Guarantees:
/// 1. Any refresh (`⌘R`, wake, popover/notch open, timer) cancels pending FSEvent
///    debounces so stale timers can NEVER violate the 120s floor.
/// 2. Newly created Antigravity surfaces (`antigravity/brain`, `antigravity-ide/brain`)
///    trigger watcher path reconciliation instead of staying permanently unwatched.
/// 3. `terminate` cleanly stops periodic timer, wake timer, debounce, and FSEventStream.
public enum BrainWatcherLifecycleMachine {

    @discardableResult
    public static func reduce(
        _ state: inout BrainWatcherLifecycleState,
        event: BrainWatcherLifecycleEvent
    ) -> [BrainWatcherLifecycleEffect] {
        switch event {
        case .start(let candidatePaths, let now):
            guard !state.isStarted else { return [] }
            state.isStarted = true
            state.lastWatchAttemptAt = now
            var effects: [BrainWatcherLifecycleEffect] = [.startPeriodicTimer]
            let normalized = Array(Set(candidatePaths)).sorted()
            if !normalized.isEmpty {
                effects.append(.startFSWatcher(paths: normalized))
            }
            return effects

        case .fsWatcherResult(let watchedPaths, let at):
            state.lastWatchAttemptAt = at
            state.watchedPaths = state.isStarted ? Array(Set(watchedPaths)).sorted() : []
            return []

        case .reconcileWatchPaths(let candidatePaths, let now):
            guard state.isStarted else { return [] }
            return reconcilePaths(&state, candidatePaths: candidatePaths, now: now)

        case .fsEventReceived(let now):
            guard state.isStarted else { return [] }
            state.debounceGeneration += 1
            let delay = state.throttle.delayForFSEvent(at: now)
            return [.scheduleDebounce(generation: state.debounceGeneration, delay: delay)]

        case .debounceFired(let generation):
            guard state.isStarted, generation == state.debounceGeneration else { return [] }
            return [.triggerRefresh]

        case .refreshTriggered(let at):
            state.throttle.noteRefreshTriggered(at: at)
            guard state.isStarted else { return [] }
            // Invalidate any pending FSEvent debounce scheduled before this refresh so it
            // cannot fire prematurely inside the new 120s cooldown window.
            state.debounceGeneration += 1
            return [.cancelDebounce]

        case .periodicTimerFired(let candidatePaths, let now):
            guard state.isStarted else { return [] }
            var effects = reconcilePaths(&state, candidatePaths: candidatePaths, now: now)
            effects.append(.triggerRefresh)
            return effects

        case .wakeReceived:
            guard state.isStarted else { return [] }
            state.wakeGeneration += 1
            return [.scheduleWakeRefresh(generation: state.wakeGeneration, delay: 5.0)]

        case .wakeTimerFired(let generation, let candidatePaths, let now):
            guard state.isStarted, generation == state.wakeGeneration else { return [] }
            var effects = reconcilePaths(&state, candidatePaths: candidatePaths, now: now)
            effects.append(.triggerRefresh)
            return effects

        case .terminate:
            guard state.isStarted else { return [] }
            state.isStarted = false
            state.watchedPaths = []
            state.debounceGeneration += 1
            state.wakeGeneration += 1
            return [.cancelDebounce, .cancelWakeRefresh, .stopPeriodicTimer, .stopFSWatcher]
        }
    }

    private static func reconcilePaths(
        _ state: inout BrainWatcherLifecycleState,
        candidatePaths: [String],
        now: Date
    ) -> [BrainWatcherLifecycleEffect] {
        let normalized = Array(Set(candidatePaths)).sorted()
        guard !normalized.isEmpty else { return [] }
        // Start/restart if new surface directories appeared, or retry after 30s if unhealthy.
        if normalized != state.watchedPaths {
            if !state.watchedPaths.isEmpty || SessionPollCadence.shouldRetryFSWatcher(
                started: true,
                fsHealthy: false,
                now: now,
                lastAttemptAt: state.lastWatchAttemptAt
            ) {
                state.lastWatchAttemptAt = now
                return [.startFSWatcher(paths: normalized)]
            }
        }
        return []
    }
}

// MARK: - Done-Unseen State Wrapper (Single Source of Truth)

/// Encapsulates `prevStatuses` + `doneUnseen` so `SessionMonitor` never mutates
/// `doneUnseen` outside `SessionLogic.stepDoneUnseen` and resets atomically on `stop()`.
public struct DoneUnseenState: Equatable, Sendable {
    public private(set) var prevStatuses: [String: SessionStatus] = [:]
    public private(set) var doneUnseen: [String: Double] = [:]

    public init() {}

    public var ids: Set<String> { Set(doneUnseen.keys) }
    public var anyUnseen: Bool { !doneUnseen.isEmpty }

    public mutating func step(sessions: [SessionInfo], now: Double) {
        let stepped = SessionLogic.stepDoneUnseen(
            prev: prevStatuses,
            current: sessions,
            doneUnseen: doneUnseen,
            seenAll: false,
            now: now
        )
        prevStatuses = stepped.prev
        doneUnseen = stepped.doneUnseen
    }

    @discardableResult
    public mutating func markSeen(_ sessionId: String) -> Bool {
        doneUnseen.removeValue(forKey: sessionId) != nil
    }

    public mutating func reset() {
        prevStatuses.removeAll()
        doneUnseen.removeAll()
    }
}

public struct MenuBarAnchorState: Equatable, Sendable {
    public private(set) var latestText: String
    public private(set) var displayedText: String
    public private(set) var measuredWidth: Double
    public private(set) var appliedWidth: Double
    public private(set) var isPopoverShown: Bool
    public private(set) var isMenuBarVisible: Bool

    public init(
        initialText: String = "…",
        initialWidth: Double = 40.0,
        isMenuBarVisible: Bool = true
    ) {
        let clamped = max(20.0, initialWidth)
        self.latestText = initialText
        self.displayedText = initialText
        self.measuredWidth = clamped
        self.appliedWidth = clamped
        self.isPopoverShown = false
        self.isMenuBarVisible = isMenuBarVisible
    }

    /// Defers visible updates while popover is open so an expanding status item
    /// doesn't push NSPopover horizontally across the menu bar.
    public mutating func updateValue(_ text: String) {
        latestText = text
        if !isPopoverShown {
            displayedText = text
        }
    }

    public mutating func updateMeasuredWidth(_ width: Double) {
        let clamped = max(20.0, width)
        measuredWidth = clamped
        if isMenuBarVisible && !isPopoverShown {
            appliedWidth = clamped
        }
    }

    public mutating func popoverOpened() {
        isPopoverShown = true
    }

    public mutating func popoverClosed() {
        isPopoverShown = false
        displayedText = latestText
        if isMenuBarVisible {
            appliedWidth = measuredWidth
        }
    }

    public mutating func setMenuBarVisible(_ visible: Bool) {
        isMenuBarVisible = visible
        if visible && !isPopoverShown {
            displayedText = latestText
            appliedWidth = measuredWidth
        }
    }

    /// `DisplayTab.session` (rawValue 4) and `DisplayTab.subscription` (rawValue 2)
    /// must not stall on `"…"` when `currentMonthData == nil`.
    public static func shouldPublishMenuBarValue(
        tabRawValue: Int,
        hasCurrentMonthData: Bool,
        hasSubscriptionQuota: Bool
    ) -> Bool {
        switch tabRawValue {
        case 4: // DisplayTab.session
            return true
        case 2: // DisplayTab.subscription
            return hasSubscriptionQuota || hasCurrentMonthData
        default: // .cost (0), .tokens (1), .time (3)
            return hasCurrentMonthData
        }
    }

    public static func shouldPublishMenuBarValue(
        metric: MenuBarMetricPreference,
        tabRawValue: Int,
        hasTodayData: Bool,
        hasCurrentMonthData: Bool,
        hasSubscriptionQuota: Bool
    ) -> Bool {
        switch metric {
        case .followTab:
            return shouldPublishMenuBarValue(
                tabRawValue: tabRawValue,
                hasCurrentMonthData: hasCurrentMonthData,
                hasSubscriptionQuota: hasSubscriptionQuota
            )
        case .todayCost:
            return hasTodayData || hasCurrentMonthData
        case .quota5h:
            return hasSubscriptionQuota
        case .liveSessions:
            return true
        case .costAndQuota:
            return hasTodayData || hasCurrentMonthData || hasSubscriptionQuota
        }
    }
}

public enum MenuBarMetricPreference: String, CaseIterable, Codable, Sendable {
    case followTab
    case todayCost
    case quota5h
    case liveSessions
    case costAndQuota
}

// MARK: - Popover & Context-Menu Anchor Validation, Fallback & Drift Detection

/// Foundation-only screen rectangle (`Double` coordinates, AppKit bottom-left origin).
public struct ScreenRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isFinite: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite
    }

    public var minX: Double { x }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var maxY: Double { y + height }
    public var midX: Double { x + width * 0.5 }
    public var midY: Double { y + height * 0.5 }
    public var area: Double { max(0.0, width) * max(0.0, height) }

    public func contains(x px: Double, y py: Double) -> Bool {
        guard isFinite, px.isFinite, py.isFinite, width > 0.0, height > 0.0 else {
            return false
        }
        return px >= minX && px <= maxX && py >= minY && py <= maxY
    }

    public func intersection(_ other: ScreenRect) -> ScreenRect? {
        guard isFinite, other.isFinite,
              width > 0.0, height > 0.0,
              other.width > 0.0, other.height > 0.0 else {
            return nil
        }
        let ix1 = max(minX, other.minX)
        let iy1 = max(minY, other.minY)
        let ix2 = min(maxX, other.maxX)
        let iy2 = min(maxY, other.maxY)
        guard ix2 > ix1, iy2 > iy1 else { return nil }
        return ScreenRect(x: ix1, y: iy1, width: ix2 - ix1, height: iy2 - iy1)
    }
}

/// Pure display geometry snapshot corresponding to one connected `NSScreen`.
public struct MenuBarDisplayDescriptor: Equatable, Sendable {
    public let displayId: UInt32
    public let frame: ScreenRect
    public let visibleFrame: ScreenRect
    public let auxiliaryTopLeftArea: ScreenRect?
    public let auxiliaryTopRightArea: ScreenRect?
    public let safeAreaTop: Double
    public let isBuiltin: Bool
    public let isMain: Bool
    public let isFullscreen: Bool

    public init(
        displayId: UInt32,
        frame: ScreenRect,
        visibleFrame: ScreenRect,
        auxiliaryTopLeftArea: ScreenRect? = nil,
        auxiliaryTopRightArea: ScreenRect? = nil,
        safeAreaTop: Double = 0.0,
        isBuiltin: Bool = false,
        isMain: Bool = false,
        isFullscreen: Bool = false
    ) {
        self.displayId = displayId
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.auxiliaryTopLeftArea = auxiliaryTopLeftArea
        self.auxiliaryTopRightArea = auxiliaryTopRightArea
        self.safeAreaTop = safeAreaTop
        self.isBuiltin = isBuiltin
        self.isMain = isMain
        self.isFullscreen = isFullscreen
    }

    /// True when the menu bar on this display slides out of view after the pointer leaves
    /// the top edge (native macOS Fullscreen Space or auto-hidden desktop menu bar).
    /// Anchoring `NSPopover` directly to `NSStatusBarButton` on an ephemeral menu bar drags
    /// the popover upward/off-screen as macOS retracts `NSStatusBarWindow`.
    public var hasEphemeralMenuBar: Bool {
        let dockedMenuBarHeight = frame.maxY - visibleFrame.maxY
        return isFullscreen || dockedMenuBarHeight <= 1.0
    }

    public var hasNotch: Bool {
        guard safeAreaTop.isFinite, safeAreaTop > 0.0,
              let left = auxiliaryTopLeftArea,
              let right = auxiliaryTopRightArea else {
            return false
        }
        return left.isFinite && left.width > 0.0 && left.height > 0.0
            && right.isFinite && right.width > 0.0 && right.height > 0.0
    }

    /// Physical notch cutout gap between `auxiliaryTopLeftArea` and `auxiliaryTopRightArea`.
    public var notchCutoutRect: ScreenRect? {
        guard safeAreaTop > 0.0,
              let left = auxiliaryTopLeftArea,
              let right = auxiliaryTopRightArea,
              right.minX > left.maxX else {
            return nil
        }
        let bandY = frame.maxY - safeAreaTop
        return ScreenRect(
            x: left.maxX,
            y: bandY,
            width: right.minX - left.maxX,
            height: safeAreaTop
        )
    }
}

/// Pure snapshot of `NSStatusItem` / `NSStatusBarButton` window visibility and screen rect.
public struct StatusItemAnchorSnapshot: Equatable, Sendable {
    public let statusItemVisible: Bool
    public let hasWindow: Bool
    public let windowVisible: Bool
    public let windowAlpha: Double
    public let buttonScreenRect: ScreenRect?
    public let windowScreenDisplayId: UInt32?

    public init(
        statusItemVisible: Bool,
        hasWindow: Bool,
        windowVisible: Bool,
        windowAlpha: Double,
        buttonScreenRect: ScreenRect?,
        windowScreenDisplayId: UInt32?
    ) {
        self.statusItemVisible = statusItemVisible
        self.hasWindow = hasWindow
        self.windowVisible = windowVisible
        self.windowAlpha = windowAlpha
        self.buttonScreenRect = buttonScreenRect
        self.windowScreenDisplayId = windowScreenDisplayId
    }
}

public enum AnchorFallbackReason: Equatable, Sendable {
    case statusItemHidden
    case missingWindow
    case windowNotVisible
    case degenerateRect
    case offScreen
    case notchOccluded
    case outsideMenuBarBand
    case ephemeralMenuBar
}

public enum PopoverAnchorDecision: Equatable, Sendable {
    case statusItem(displayId: UInt32, buttonRect: ScreenRect)
    case fallbackMenuBar(displayId: UInt32, anchorRect: ScreenRect, reason: AnchorFallbackReason)
    case unavailable
}

public enum PopoverAnchorSessionMode: Equatable, Sendable {
    case none
    case statusItem(displayId: UInt32, anchorRect: ScreenRect)
    case fallback(displayId: UInt32, anchorRect: ScreenRect)

    public init(decision: PopoverAnchorDecision) {
        switch decision {
        case .statusItem(let displayId, let buttonRect):
            self = .statusItem(displayId: displayId, anchorRect: buttonRect)
        case .fallbackMenuBar(let displayId, let anchorRect, _):
            self = .fallback(displayId: displayId, anchorRect: anchorRect)
        case .unavailable:
            self = .none
        }
    }

    public var displayId: UInt32? {
        switch self {
        case .none: return nil
        case .statusItem(let id, _), .fallback(let id, _): return id
        }
    }

    public var anchorRect: ScreenRect? {
        switch self {
        case .none: return nil
        case .statusItem(_, let rect), .fallback(_, let rect): return rect
        }
    }

    public var isFallback: Bool {
        if case .fallback = self { return true }
        return false
    }
}

// MARK: - Control-Center Floating MenuBarPanel Lifecycle State Machine

public enum MenuBarPanelPhase: Equatable, Sendable {
    case closed
    case opening(token: UInt64)
    case open
    case closing(token: UInt64)

    /// True while the panel is presented or fading in (monitors & height sync active).
    public var isVisibleOrOpening: Bool {
        switch self {
        case .opening, .open:
            return true
        case .closed, .closing:
            return false
        }
    }
}

/// Pure lifecycle state for `AppDelegate`'s borderless floating `MenuBarPanel`.
/// Consolidates phase, monotonic animation token, anchor mode, measured height,
/// nested `NSMenu` tracking depth, and status-item click-bounce suppression.
public struct MenuBarPanelState: Equatable, Sendable {
    public static let minHeight: Double = 180.0
    public static let defaultHeight: Double = 560.0

    public var phase: MenuBarPanelPhase
    public var animationTokenCounter: UInt64
    public var anchorMode: PopoverAnchorSessionMode
    public var measuredHeight: Double
    public var activeMenuTrackingDepth: Int
    public var suppressedStatusItemClickUntil: Date?

    public init(
        phase: MenuBarPanelPhase = .closed,
        animationTokenCounter: UInt64 = 0,
        anchorMode: PopoverAnchorSessionMode = .none,
        measuredHeight: Double = MenuBarPanelState.defaultHeight,
        activeMenuTrackingDepth: Int = 0,
        suppressedStatusItemClickUntil: Date? = nil
    ) {
        self.phase = phase
        self.animationTokenCounter = animationTokenCounter
        self.anchorMode = anchorMode
        self.measuredHeight = (measuredHeight.isFinite && measuredHeight > 1.0)
            ? max(Self.minHeight, ceil(measuredHeight))
            : Self.defaultHeight
        self.activeMenuTrackingDepth = max(0, activeMenuTrackingDepth)
        self.suppressedStatusItemClickUntil = suppressedStatusItemClickUntil
    }

    public var isVisibleOrOpening: Bool { phase.isVisibleOrOpening }
    public var isMenuTrackingActive: Bool { activeMenuTrackingDepth > 0 }

    /// Consumes a pending status-item click suppression window recorded when resign-key
    /// dismissed the panel on `leftMouseDown` over `statusItem.button`, preventing the
    /// matching `leftMouseUp` from immediately bouncing the panel back open.
    public mutating func consumeSuppressedStatusItemClick(at now: Date) -> Bool {
        defer { suppressedStatusItemClickUntil = nil }
        guard let until = suppressedStatusItemClickUntil else { return false }
        return now <= until
    }
}

public enum MenuBarPanelEvent: Equatable, Sendable {
    case openRequested(anchorMode: PopoverAnchorSessionMode, height: Double, animated: Bool)
    case openAnimationFinished(token: UInt64)
    case closeRequested(animated: Bool, suppressStatusItemClickUntil: Date?)
    case closeAnimationFinished(token: UInt64)
    case heightMeasured(Double)
    case menuTrackingBegan
    case menuTrackingEnded
    case appDeactivated
    case outsideClick
    case escapePressed
    case terminate
}

public enum MenuBarPanelEffect: Equatable, Sendable {
    case presentPanel(animated: Bool, token: UInt64)
    case dismissPanel(animated: Bool, token: UInt64)
    /// Emitted when an animated close completes with a still-current token so the shell
    /// orders the panel out and resets alpha without maintaining a parallel token check.
    case orderOutPanel
    case attachDismissMonitors
    case detachDismissMonitors
    case updatePanelHeight(Double)
    case syncAppPresentationShown
    case syncAppPresentationClosed
}

public enum MenuBarPanelMachine {

    @discardableResult
    public static func reduce(
        _ state: inout MenuBarPanelState,
        event: MenuBarPanelEvent
    ) -> [MenuBarPanelEffect] {
        switch event {
        case .openRequested(let anchorMode, let height, let animated):
            guard anchorMode != .none else { return [] }
            let wasVisible = state.phase.isVisibleOrOpening
            if height.isFinite && height > 1.0 {
                state.measuredHeight = max(MenuBarPanelState.minHeight, ceil(height))
            }
            state.anchorMode = anchorMode
            state.suppressedStatusItemClickUntil = nil
            state.animationTokenCounter &+= 1
            let token = state.animationTokenCounter
            state.phase = animated ? .opening(token: token) : .open

            var effects: [MenuBarPanelEffect] = []
            if wasVisible {
                effects.append(.detachDismissMonitors)
            }
            effects.append(.presentPanel(animated: animated, token: token))
            if !wasVisible {
                effects.append(.syncAppPresentationShown)
            }
            effects.append(.attachDismissMonitors)
            return effects

        case .openAnimationFinished(let token):
            guard case .opening(let activeToken) = state.phase, activeToken == token else {
                return []
            }
            state.phase = .open
            return []

        case .closeRequested(let animated, let suppressUntil):
            return performClose(&state, animated: animated, suppressStatusItemClickUntil: suppressUntil)

        case .closeAnimationFinished(let token):
            guard case .closing(let activeToken) = state.phase, activeToken == token else {
                return []
            }
            state.phase = .closed
            return [.orderOutPanel]

        case .heightMeasured(let rawHeight):
            guard rawHeight.isFinite, rawHeight > 1.0 else { return [] }
            let clamped = max(MenuBarPanelState.minHeight, ceil(rawHeight))
            guard abs(clamped - state.measuredHeight) > 0.5 else { return [] }
            state.measuredHeight = clamped
            guard state.phase.isVisibleOrOpening else { return [] }
            return [.updatePanelHeight(clamped)]

        case .menuTrackingBegan:
            state.activeMenuTrackingDepth += 1
            return []

        case .menuTrackingEnded:
            state.activeMenuTrackingDepth = max(0, state.activeMenuTrackingDepth - 1)
            return []

        case .appDeactivated, .outsideClick, .escapePressed:
            guard state.phase.isVisibleOrOpening, state.activeMenuTrackingDepth == 0 else {
                return []
            }
            return performClose(&state, animated: true, suppressStatusItemClickUntil: nil)

        case .terminate:
            state.activeMenuTrackingDepth = 0
            state.suppressedStatusItemClickUntil = nil
            state.anchorMode = .none
            guard state.phase != .closed else { return [] }
            let wasVisible = state.phase.isVisibleOrOpening
            state.animationTokenCounter &+= 1
            let token = state.animationTokenCounter
            state.phase = .closed
            var effects: [MenuBarPanelEffect] = [.detachDismissMonitors]
            if wasVisible {
                effects.append(.syncAppPresentationClosed)
            }
            effects.append(.dismissPanel(animated: false, token: token))
            return effects
        }
    }

    private static func performClose(
        _ state: inout MenuBarPanelState,
        animated: Bool,
        suppressStatusItemClickUntil: Date?
    ) -> [MenuBarPanelEffect] {
        switch state.phase {
        case .closed:
            return []

        case .closing:
            // If an animated fade-out is already in flight and an immediate non-animated close
            // arrives (e.g. Space switch or display disconnect), snap closed immediately.
            guard !animated else { return [] }
            if let until = suppressStatusItemClickUntil {
                state.suppressedStatusItemClickUntil = until
            }
            state.anchorMode = .none
            state.animationTokenCounter &+= 1
            let token = state.animationTokenCounter
            state.phase = .closed
            return [.dismissPanel(animated: false, token: token)]

        case .opening, .open:
            if let until = suppressStatusItemClickUntil {
                state.suppressedStatusItemClickUntil = until
            }
            state.anchorMode = .none
            state.animationTokenCounter &+= 1
            let token = state.animationTokenCounter
            state.phase = animated ? .closing(token: token) : .closed
            return [
                .detachDismissMonitors,
                .syncAppPresentationClosed,
                .dismissPanel(animated: animated, token: token),
            ]
        }
    }
}

/// Pure anchor validation, deterministic top-right fallback placement, and live
/// popover-window drift detection (resolves macOS crowded/notched/multi-display
/// menu-bar overflow where `NSStatusBarWindow` is parked off-screen or behind the notch).
public enum MenuBarAnchorResolver {

    public static func resolve(
        snapshot: StatusItemAnchorSnapshot,
        displays: [MenuBarDisplayDescriptor],
        mouseDisplayId: UInt32? = nil,
        panelWidth: Double = 420.0
    ) -> PopoverAnchorDecision {
        guard !displays.isEmpty else { return .unavailable }

        func fallback(_ reason: AnchorFallbackReason) -> PopoverAnchorDecision {
            guard let target = selectFallbackDisplay(displays: displays, mouseDisplayId: mouseDisplayId) else {
                return .unavailable
            }
            let rect = fallbackAnchorRect(on: target, panelWidth: panelWidth)
            return .fallbackMenuBar(displayId: target.displayId, anchorRect: rect, reason: reason)
        }

        guard snapshot.statusItemVisible else {
            return fallback(.statusItemHidden)
        }
        guard snapshot.hasWindow else {
            return fallback(.missingWindow)
        }
        guard snapshot.windowVisible, snapshot.windowAlpha.isFinite, snapshot.windowAlpha > 0.01 else {
            return fallback(.windowNotVisible)
        }
        guard let rect = snapshot.buttonScreenRect,
              rect.isFinite,
              rect.width >= 1.0,
              rect.height >= 1.0 else {
            return fallback(.degenerateRect)
        }

        var validCandidates: [(displayId: UInt32, visibleArea: Double)] = []
        var sawNotchOcclusion = false
        var sawOutsideMenuBarBand = false

        for display in displays {
            guard let frameIntersection = rect.intersection(display.frame) else {
                continue
            }

            if display.hasNotch,
               let topLeft = display.auxiliaryTopLeftArea,
               let topRight = display.auxiliaryTopRightArea {
                var bestZoneArea: Double? = nil
                for zone in [topLeft, topRight] {
                    if let hit = rect.intersection(zone),
                       (hit.area / rect.area) >= 0.5,
                       zone.contains(x: rect.midX, y: rect.midY) {
                        if bestZoneArea == nil || hit.area > bestZoneArea! {
                            bestZoneArea = hit.area
                        }
                    }
                }
                if let area = bestZoneArea {
                    validCandidates.append((displayId: display.displayId, visibleArea: area))
                } else if let notch = display.notchCutoutRect,
                          (rect.intersection(notch) != nil || notch.contains(x: rect.midX, y: rect.midY)) {
                    sawNotchOcclusion = true
                } else if display.isFullscreen {
                    // In native Fullscreen Space on a notched MacBook, hovering the top edge
                    // can reveal the overlay menu bar slightly below `auxiliaryTopRightArea`.
                    let fsBandH = min(
                        display.frame.height,
                        display.safeAreaTop + max(rect.height, 24.0) + 16.0
                    )
                    let fsBand = ScreenRect(
                        x: display.frame.minX,
                        y: display.frame.maxY - fsBandH,
                        width: display.frame.width,
                        height: fsBandH
                    )
                    if let hit = rect.intersection(fsBand),
                       (hit.area / rect.area) >= 0.5,
                       fsBand.contains(x: rect.midX, y: rect.midY) {
                        validCandidates.append((displayId: display.displayId, visibleArea: hit.area))
                    } else if (frameIntersection.area / rect.area) >= 0.5
                                && display.frame.contains(x: rect.midX, y: rect.midY) {
                        sawOutsideMenuBarBand = true
                    }
                } else if (frameIntersection.area / rect.area) >= 0.5
                            && display.frame.contains(x: rect.midX, y: rect.midY) {
                    sawOutsideMenuBarBand = true
                }
            } else {
                let menuBarThickness = max(0.0, display.frame.maxY - display.visibleFrame.maxY)
                let bandH = min(
                    display.frame.height,
                    max(menuBarThickness, max(rect.height, 24.0) + 16.0)
                )
                let topBand = ScreenRect(
                    x: display.frame.minX,
                    y: display.frame.maxY - bandH,
                    width: display.frame.width,
                    height: bandH
                )
                if let hit = rect.intersection(topBand),
                   (hit.area / rect.area) >= 0.5,
                   topBand.contains(x: rect.midX, y: rect.midY) {
                    validCandidates.append((displayId: display.displayId, visibleArea: hit.area))
                } else if (frameIntersection.area / rect.area) >= 0.5
                            && display.frame.contains(x: rect.midX, y: rect.midY) {
                    sawOutsideMenuBarBand = true
                }
            }
        }

        if !validCandidates.isEmpty {
            let resolvedDisplayId: UInt32
            if let preferredId = snapshot.windowScreenDisplayId,
               validCandidates.contains(where: { $0.displayId == preferredId }) {
                resolvedDisplayId = preferredId
            } else {
                let best = validCandidates.min { lhs, rhs in
                    if abs(lhs.visibleArea - rhs.visibleArea) > 0.5 {
                        return lhs.visibleArea > rhs.visibleArea
                    }
                    return lhs.displayId < rhs.displayId
                }!
                resolvedDisplayId = best.displayId
            }
            if let resolvedDisplay = displays.first(where: { $0.displayId == resolvedDisplayId }),
               resolvedDisplay.hasEphemeralMenuBar {
                // Pin stationary anchor right below the clicked icon so the popover never
                // rides `NSStatusBarWindow` upward when the fullscreen/auto-hide menu bar retracts.
                return .fallbackMenuBar(
                    displayId: resolvedDisplayId,
                    anchorRect: pinnedAnchorRect(for: rect),
                    reason: .ephemeralMenuBar
                )
            }
            return .statusItem(displayId: resolvedDisplayId, buttonRect: rect)
        }

        if sawNotchOcclusion {
            return fallback(.notchOccluded)
        }
        if sawOutsideMenuBarBand {
            return fallback(.outsideMenuBarBand)
        }
        return fallback(.offScreen)
    }

    /// Deterministic fallback display priority: `mouseDisplayId` > `isMain` > `isBuiltin` > lowest `displayId`.
    public static func selectFallbackDisplay(
        displays: [MenuBarDisplayDescriptor],
        mouseDisplayId: UInt32?
    ) -> MenuBarDisplayDescriptor? {
        guard !displays.isEmpty else { return nil }
        if let mouseId = mouseDisplayId,
           let match = displays.first(where: { $0.displayId == mouseId }) {
            return match
        }
        if let main = displays
            .filter({ $0.isMain })
            .min(by: { $0.displayId < $1.displayId }) {
            return main
        }
        if let builtin = displays
            .filter({ $0.isBuiltin })
            .min(by: { $0.displayId < $1.displayId }) {
            return builtin
        }
        return displays.min(by: { $0.displayId < $1.displayId })
    }

    /// Computes a 2x2 anchor rect at the bottom of the target display's top-right menu bar
    /// area so an `NSPopover` anchored with `preferredEdge: .minY` drops cleanly inside the
    /// display without clipping or overlapping a physical notch.
    public static func fallbackAnchorRect(
        on display: MenuBarDisplayDescriptor,
        panelWidth: Double = 420.0
    ) -> ScreenRect {
        let menuBarBottomY: Double = {
            if (display.frame.maxY - display.visibleFrame.maxY) > 0.5 {
                return display.visibleFrame.maxY
            }
            if display.safeAreaTop > 0.0 {
                return display.frame.maxY - display.safeAreaTop
            }
            return display.frame.maxY - 24.0
        }()

        let usableArea: ScreenRect = {
            if display.hasNotch,
               let topRight = display.auxiliaryTopRightArea,
               topRight.width > 0.0 {
                return topRight
            }
            return display.frame
        }()

        let anchorX: Double
        if usableArea.width <= 32.0 {
            anchorX = usableArea.midX
        } else {
            let desiredX = usableArea.maxX - panelWidth * 0.5 - 12.0
            anchorX = min(max(desiredX, usableArea.minX + 16.0), usableArea.maxX - 16.0)
        }

        return ScreenRect(x: anchorX - 1.0, y: menuBarBottomY, width: 2.0, height: 2.0)
    }

    /// 2x2 stationary anchor rect positioned directly at the bottom-center of a visible
    /// `NSStatusBarButton` so a floating menu-bar panel opens directly below the icon without
    /// riding `NSStatusBarWindow` when an ephemeral fullscreen/auto-hide menu bar retracts.
    public static func pinnedAnchorRect(for buttonRect: ScreenRect) -> ScreenRect {
        ScreenRect(x: buttonRect.midX - 1.0, y: buttonRect.minY, width: 2.0, height: 2.0)
    }

    /// Computes the screen-space frame for a borderless floating menu-bar panel (Control Center
    /// style) positioned directly beneath `anchorRect` on `hostDisplay`, horizontally centered on
    /// `anchorRect.midX` and clamped inside the display's usable bounds (respecting side/bottom
    /// Dock insets and display edges, including negative-coordinate secondary displays).
    public static func panelFrame(
        anchorRect: ScreenRect,
        hostDisplay: MenuBarDisplayDescriptor,
        panelWidth: Double = 420.0,
        panelHeight: Double,
        topGap: Double = 6.0,
        edgeMargin: Double = 8.0
    ) -> ScreenRect {
        let safeW = max(1.0, panelWidth.isFinite ? panelWidth : 420.0)
        let safeH = max(1.0, panelHeight.isFinite ? panelHeight : 460.0)
        let gap = max(0.0, topGap.isFinite ? topGap : 6.0)
        let margin = max(0.0, edgeMargin.isFinite ? edgeMargin : 8.0)

        // Prefer `visibleFrame` horizontal bounds so a left/right Dock is never overlapped;
        // fall back to full `frame` if `visibleFrame` is narrower than the panel.
        let horizBounds: ScreenRect = (hostDisplay.visibleFrame.width >= safeW + margin * 2.0)
            ? hostDisplay.visibleFrame
            : hostDisplay.frame
        let minX = horizBounds.minX + margin
        let maxX = horizBounds.maxX - margin - safeW
        let idealX = anchorRect.midX - safeW * 0.5
        let clampedX: Double
        if maxX >= minX {
            clampedX = min(max(idealX, minX), maxX)
        } else {
            clampedX = horizBounds.minX
        }

        // Never let the floating panel intrude into the docked menu bar or physical notch.
        // On notched MacBooks, `NSStatusBarButton` (~22pt tall) is vertically centered inside
        // the ~37pt menu bar so `button.minY` sits ~9pt ABOVE `visibleFrame.maxY`. Clamping
        // the anchor bottom to `menuBarBottomCeiling` keeps a crisp `topGap` below the actual
        // bottom edge of both the menu bar and the notch housing on every display.
        var menuBarBottomCeiling = hostDisplay.frame.maxY
        if (hostDisplay.frame.maxY - hostDisplay.visibleFrame.maxY) > 0.5 {
            menuBarBottomCeiling = min(menuBarBottomCeiling, hostDisplay.visibleFrame.maxY)
        }
        if hostDisplay.safeAreaTop.isFinite && hostDisplay.safeAreaTop > 0.0 {
            menuBarBottomCeiling = min(menuBarBottomCeiling, hostDisplay.frame.maxY - hostDisplay.safeAreaTop)
        }
        let effectiveAnchorBottomY = min(anchorRect.minY, menuBarBottomCeiling)
        let topY = effectiveAnchorBottomY - gap
        let minBottomY = hostDisplay.visibleFrame.minY + margin
        let maxAvailableH = max(120.0, topY - minBottomY)
        let clampedH = min(safeH, maxAvailableH)
        let originY = topY - clampedH

        return ScreenRect(x: clampedX, y: originY, width: safeW, height: clampedH)
    }

    /// Computes a top-pinned resized frame when tab content height changes, keeping `minX`,
    /// `width`, and `maxY` (the top edge below the menu bar) mathematically constant so switching
    /// tabs never shifts the header/tab bar vertically or drifts horizontally.
    public static func resizedPanelFrame(
        currentFrame: ScreenRect,
        newHeight: Double,
        hostDisplay: MenuBarDisplayDescriptor?,
        edgeMargin: Double = 8.0
    ) -> ScreenRect {
        let safeH = max(1.0, newHeight.isFinite ? newHeight : currentFrame.height)
        let topY = currentFrame.maxY
        let clampedH: Double
        if let host = hostDisplay {
            let margin = max(0.0, edgeMargin.isFinite ? edgeMargin : 8.0)
            let maxAvailableH = max(120.0, topY - (host.visibleFrame.minY + margin))
            clampedH = min(safeH, maxAvailableH)
        } else {
            clampedH = safeH
        }
        return ScreenRect(
            x: currentFrame.minX,
            y: topY - clampedH,
            width: currentFrame.width,
            height: clampedH
        )
    }
}

public enum LogoAnimationMode: Equatable, Sendable {
    case idle
    case levitate
    case breatheOpacity
}

public enum LogoAttentionDot: Equatable, Sendable {
    case none
    case waitingAmber
    case doneUnseenGreen
}

public struct LogoVisualState: Equatable, Sendable {
    public let animation: LogoAnimationMode
    public let dot: LogoAttentionDot

    public init(animation: LogoAnimationMode, dot: LogoAttentionDot) {
        self.animation = animation
        self.dot = dot
    }

    public static func resolve(
        anyBusy: Bool,
        anyWaiting: Bool,
        anyDoneUnseen: Bool,
        reduceMotion: Bool
    ) -> LogoVisualState {
        let animation: LogoAnimationMode
        if !anyBusy {
            animation = .idle
        } else if reduceMotion {
            animation = .breatheOpacity
        } else {
            animation = .levitate
        }

        let dot: LogoAttentionDot
        if anyWaiting {
            dot = .waitingAmber
        } else if anyDoneUnseen {
            dot = .doneUnseenGreen
        } else {
            dot = .none
        }
        return LogoVisualState(animation: animation, dot: dot)
    }
}

public enum SessionSurfaceBadge: String, Equatable, Sendable {
    case cli = "CLI"
    case desktop = "Desktop"
    case ide = "IDE"

    public static func from(entrypoint: String?, surface: String? = nil) -> SessionSurfaceBadge? {
        let candidate = (surface ?? entrypoint)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch candidate {
        case "antigravity-ide", "ide":
            return .ide
        case "antigravity", "desktop":
            return .desktop
        case "antigravity-cli", "cli", "agy":
            return .cli
        default:
            return nil
        }
    }
}

extension SessionLogic {

    /// Single canonical status resolver shared by `SessionMonitor` and `AITitleReader`.
    public static func resolveLiveSessionStatus(
        swarmWorkerBusy: Bool,
        rawStatus: String?,
        notFullyIdle: Bool,
        transcriptSummary: TranscriptSummary?,
        transcriptFileMtime: TimeInterval?,
        now: TimeInterval,
        waitingRecencySeconds: TimeInterval = 3600,
        busyRecencySeconds: TimeInterval = 180
    ) -> (status: SessionStatus, waitingFor: String?) {
        if swarmWorkerBusy {
            return (.busy, nil)
        }

        let pendingTools = transcriptSummary?.pendingToolNames ?? []
        let pendingNonSwarmWait = pendingTools.filter { $0 != "swarm_wait" }
        let onlySwarmWait = !pendingTools.isEmpty && pendingNonSwarmWait.isEmpty

        let waitingRecent: Bool = {
            if notFullyIdle { return true }
            if let mtime = transcriptFileMtime {
                return (now - mtime) < waitingRecencySeconds
            }
            return true
        }()

        if transcriptSummary?.isWaitingForQuestion == true && waitingRecent {
            return (.waiting, "input needed")
        }

        if let raw = rawStatus?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
           !raw.isEmpty {
            if raw.contains("WAITING") || raw.contains("CONFIRM")
                || raw.contains("PERMISSION") || raw.contains("APPROVAL") {
                let reason = (raw.contains("CONFIRM") || raw.contains("PERMISSION") || raw.contains("APPROVAL"))
                    ? "permission prompt"
                    : "input needed"
                return (.waiting, reason)
            }
            if raw.contains("RUNNING") || raw.contains("BUSY") || raw.contains("EXECUTING") {
                return (.busy, nil)
            }
        }

        if notFullyIdle {
            return (.busy, nil)
        }

        let busyRecent: Bool = {
            if let mtime = transcriptFileMtime {
                return (now - mtime) < busyRecencySeconds
            }
            if let at = transcriptSummary?.lastStepAt {
                return (now - at.timeIntervalSince1970) < busyRecencySeconds
            }
            return true
        }()

        if let ts = transcriptSummary {
            if ts.lastStepStatus == .running && busyRecent {
                return (.busy, nil)
            }
            if !pendingNonSwarmWait.isEmpty && busyRecent {
                return (.busy, nil)
            }
            if onlySwarmWait {
                return (.idle, nil)
            }
            if (ts.lastStepType == .userInput || ts.lastStepType == .generic)
                && ts.lastStepStatus != .error && busyRecent {
                return (.busy, nil)
            }
        }

        return (.idle, nil)
    }
}
