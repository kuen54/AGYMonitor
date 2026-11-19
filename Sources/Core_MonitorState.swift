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

    public init(
        isStarted: Bool = false,
        isActive: Bool = false,
        fsHealthy: Bool = false,
        lastFSAttemptAt: Date? = nil,
        pollInterval: TimeInterval? = nil,
        lastLiveCount: Int = 0
    ) {
        self.isStarted = isStarted
        self.isActive = isActive
        self.fsHealthy = fsHealthy
        self.lastFSAttemptAt = lastFSAttemptAt
        self.pollInterval = pollInterval
        self.lastLiveCount = lastLiveCount
    }
}

public enum SessionMonitorLifecycleEvent: Equatable, Sendable {
    case start(now: Date)
    case stop
    case setActive(Bool, now: Date)
    case fsWatcherAttempted(healthy: Bool, at: Date)
    case fsEventReceived
    case fsCoalesceFired(now: Date)
    case pollTimerFired(now: Date)
    case scanCompleted(liveCount: Int)
}

public enum SessionMonitorLifecycleEffect: Equatable, Sendable {
    case startFSWatcher
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
            return [.cancelFSCoalesce, .setPollTimer(nil), .stopFSWatcher]

        case .setActive(let active, let now):
            guard state.isStarted, state.isActive != active else { return [] }
            state.isActive = active
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

        case .fsWatcherAttempted(let healthy, let at):
            state.lastFSAttemptAt = at
            state.fsHealthy = state.isStarted ? healthy : false
            return reconcilePollEffects(&state)

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
