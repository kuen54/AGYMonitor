import Foundation

// MARK: - Telemetry, Quota Pace, Notch Live Wing & Session Nav — pure core
//
// Foundation-only (part of AGYCore); uses Double instead of CGFloat and imports
// zero UI/App frameworks.

public enum UsagePeriodScope: String, CaseIterable, Codable, Sendable {
    case today
    case week
    case month
}

public enum UsageTelemetryLogic {

    /// Cache hit percentage (`0...100`) from uncached input + cacheRead tokens.
    public static func cacheHitPercent(input: Int, cacheRead: Int) -> Double? {
        let denom = input + cacheRead
        guard denom > 0, cacheRead >= 0, input >= 0 else { return nil }
        return (Double(cacheRead) / Double(denom)) * 100.0
    }

    /// Percentage delta comparing `todayCost` against up to the 7 most recent prior
    /// active days (`day < todayDay && cost > 0`) in the current month's daily data.
    public static func costDeltaPercent(
        todayCost: Double,
        daily: [DailyUsage],
        todayDay: Int
    ) -> Double? {
        let prior = daily
            .filter { $0.day < todayDay && $0.cost > 0 }
            .sorted { $0.day < $1.day }
            .suffix(7)
        guard !prior.isEmpty else { return nil }
        let avg = prior.reduce(0.0) { $0 + $1.cost } / Double(prior.count)
        guard avg > 0.01 else { return nil }
        return ((todayCost - avg) / avg) * 100.0
    }

    /// Mean positive daily value across `daily` (`0` when no positive days exist).
    public static func dailyAverage(daily: [DailyUsage], modeIsCost: Bool) -> Double {
        let vals = daily
            .map { modeIsCost ? $0.cost : Double($0.totalTokens) }
            .filter { $0 > 0 }
        guard !vals.isEmpty else { return 0 }
        return vals.reduce(0.0, +) / Double(vals.count)
    }
}

public struct QuotaPaceSnapshot: Equatable, Sendable {
    public let elapsedFraction: Double
    public let expectedRemainingFraction: Double
    public let actualRemainingFraction: Double
    public let paceDeltaPercent: Int
    public let isOverPaceWarning: Bool

    public init(
        elapsedFraction: Double,
        expectedRemainingFraction: Double,
        actualRemainingFraction: Double,
        paceDeltaPercent: Int,
        isOverPaceWarning: Bool
    ) {
        self.elapsedFraction = elapsedFraction
        self.expectedRemainingFraction = expectedRemainingFraction
        self.actualRemainingFraction = actualRemainingFraction
        self.paceDeltaPercent = paceDeltaPercent
        self.isOverPaceWarning = isOverPaceWarning
    }
}

public enum QuotaPaceLogic {
    public static let fiveHourWindowSeconds: TimeInterval = 5 * 3600
    public static let sevenDayWindowSeconds: TimeInterval = 7 * 86400

    /// Compare actual quota consumption against uniform time-elapsed burn across a
    /// rolling window ending at `resetAt`.
    public static func compute(
        usedPercent: Int,
        resetAt: Date?,
        windowDurationSeconds: TimeInterval,
        now: Date
    ) -> QuotaPaceSnapshot? {
        guard let resetAt = resetAt, windowDurationSeconds > 0 else { return nil }
        let timeUntilReset = resetAt.timeIntervalSince(now)
        guard timeUntilReset > 0 else { return nil }

        let clampedRemainingTime = min(max(timeUntilReset, 0), windowDurationSeconds)
        let elapsedFraction = max(0.0, min(1.0, 1.0 - (clampedRemainingTime / windowDurationSeconds)))
        let expectedRemaining = max(0.0, min(1.0, 1.0 - elapsedFraction))

        let clampedUsed = max(0, min(100, usedPercent))
        let usedFraction = Double(clampedUsed) / 100.0
        let actualRemaining = max(0.0, min(1.0, 1.0 - usedFraction))

        let paceDelta = Int(((usedFraction - elapsedFraction) * 100.0).rounded())
        let overPace = paceDelta >= 12 && actualRemaining < 0.70

        return QuotaPaceSnapshot(
            elapsedFraction: elapsedFraction,
            expectedRemainingFraction: expectedRemaining,
            actualRemainingFraction: actualRemaining,
            paceDeltaPercent: paceDelta,
            isOverPaceWarning: overPace
        )
    }
}

// MARK: - Notch Live Wing State Machine

public struct NotchWingSessionSnapshot: Equatable, Sendable {
    public let sessionId: String
    public let workspace: String
    public let surface: String?
    public let isWaiting: Bool
    public let needsConfirm: Bool
    public let isDoneUnseen: Bool

    public init(
        sessionId: String,
        workspace: String,
        surface: String?,
        isWaiting: Bool,
        needsConfirm: Bool,
        isDoneUnseen: Bool
    ) {
        self.sessionId = sessionId
        self.workspace = workspace
        self.surface = surface
        self.isWaiting = isWaiting
        self.needsConfirm = needsConfirm
        self.isDoneUnseen = isDoneUnseen
    }
}

public enum NotchWingKind: Equatable, Sendable {
    case waiting(sessionId: String, workspace: String, surface: String?, needsConfirm: Bool)
    case done(sessionId: String, workspace: String, surface: String?)

    public var sessionId: String {
        switch self {
        case .waiting(let id, _, _, _), .done(let id, _, _):
            return id
        }
    }

    public var workspace: String {
        switch self {
        case .waiting(_, let ws, _, _), .done(_, let ws, _):
            return ws
        }
    }

    public var surface: String? {
        switch self {
        case .waiting(_, _, let s, _), .done(_, _, let s):
            return s
        }
    }

    public var isWaiting: Bool {
        if case .waiting = self { return true }
        return false
    }
}

public struct NotchLiveWingState: Equatable, Sendable {
    public var activeWing: NotchWingKind?
    public var doneBannerExpiresAt: Date?
    public var announcedDoneIds: Set<String>
    public var dismissedWaitingIds: Set<String>

    public init(
        activeWing: NotchWingKind? = nil,
        doneBannerExpiresAt: Date? = nil,
        announcedDoneIds: Set<String> = [],
        dismissedWaitingIds: Set<String> = []
    ) {
        self.activeWing = activeWing
        self.doneBannerExpiresAt = doneBannerExpiresAt
        self.announcedDoneIds = announcedDoneIds
        self.dismissedWaitingIds = dismissedWaitingIds
    }
}

public enum NotchLiveWingEvent: Equatable, Sendable {
    case sessionsUpdated([NotchWingSessionSnapshot], now: Date)
    case doneTimerFired(now: Date)
    case dismissed(sessionId: String)
}

public enum NotchLiveWingEffect: Equatable, Sendable {
    case scheduleDoneRetract(after: TimeInterval)
    case cancelDoneRetract
}

public enum NotchLiveWingMachine {
    public static let doneHoldDuration: TimeInterval = 5.0

    @discardableResult
    public static func reduce(
        _ state: inout NotchLiveWingState,
        event: NotchLiveWingEvent
    ) -> [NotchLiveWingEffect] {
        switch event {
        case .sessionsUpdated(let snapshots, let now):
            let waitingIds = Set(snapshots.filter(\.isWaiting).map(\.sessionId))
            state.dismissedWaitingIds = state.dismissedWaitingIds.intersection(waitingIds)

            let unseenDoneIds = Set(snapshots.filter(\.isDoneUnseen).map(\.sessionId))
            state.announcedDoneIds = state.announcedDoneIds.intersection(unseenDoneIds)

            let eligibleWaiting = snapshots.filter { $0.isWaiting && !state.dismissedWaitingIds.contains($0.sessionId) }
            let pickedWaiting = eligibleWaiting.first(where: \.needsConfirm) ?? eligibleWaiting.first

            if let waiting = pickedWaiting {
                let hadDoneTimer = state.doneBannerExpiresAt != nil
                state.activeWing = .waiting(
                    sessionId: waiting.sessionId,
                    workspace: waiting.workspace,
                    surface: waiting.surface,
                    needsConfirm: waiting.needsConfirm
                )
                state.doneBannerExpiresAt = nil
                return hadDoneTimer ? [.cancelDoneRetract] : []
            }

            // No active un-dismissed waiting session.
            if case .waiting = state.activeWing {
                state.activeWing = nil
            }

            // Check if a currently active .done banner is still valid and unexpired.
            if case .done(let activeId, _, _) = state.activeWing {
                let expired = state.doneBannerExpiresAt.map { now >= $0 } ?? true
                if !expired, let updated = snapshots.first(where: { $0.sessionId == activeId && $0.isDoneUnseen }) {
                    state.activeWing = .done(
                        sessionId: updated.sessionId,
                        workspace: updated.workspace,
                        surface: updated.surface
                    )
                    return []
                } else {
                    state.activeWing = nil
                    state.doneBannerExpiresAt = nil
                    // Fall through so if another unseen-done just became eligible, it can announce;
                    // otherwise return cancelDoneRetract below.
                    if let freshDone = snapshots.first(where: { $0.isDoneUnseen && !state.announcedDoneIds.contains($0.sessionId) }) {
                        state.announcedDoneIds.insert(freshDone.sessionId)
                        state.activeWing = .done(
                            sessionId: freshDone.sessionId,
                            workspace: freshDone.workspace,
                            surface: freshDone.surface
                        )
                        state.doneBannerExpiresAt = now.addingTimeInterval(doneHoldDuration)
                        return [.scheduleDoneRetract(after: doneHoldDuration)]
                    }
                    return [.cancelDoneRetract]
                }
            }

            // Otherwise look for a freshly finished unseen session not yet announced.
            if let freshDone = snapshots.first(where: { $0.isDoneUnseen && !state.announcedDoneIds.contains($0.sessionId) }) {
                state.announcedDoneIds.insert(freshDone.sessionId)
                state.activeWing = .done(
                    sessionId: freshDone.sessionId,
                    workspace: freshDone.workspace,
                    surface: freshDone.surface
                )
                state.doneBannerExpiresAt = now.addingTimeInterval(doneHoldDuration)
                return [.scheduleDoneRetract(after: doneHoldDuration)]
            }

            return []

        case .doneTimerFired(let now):
            guard case .done = state.activeWing else {
                state.doneBannerExpiresAt = nil
                return []
            }
            if let expiresAt = state.doneBannerExpiresAt, now < expiresAt {
                return []
            }
            state.activeWing = nil
            state.doneBannerExpiresAt = nil
            return [.cancelDoneRetract]

        case .dismissed(let sessionId):
            var effects: [NotchLiveWingEffect] = []
            if case .waiting(let activeId, _, _, _) = state.activeWing, activeId == sessionId {
                state.dismissedWaitingIds.insert(sessionId)
                state.activeWing = nil
            } else {
                // Record waiting dismissal defensively if active matches or caller dismissed a waiting session.
                state.dismissedWaitingIds.insert(sessionId)
            }
            if case .done(let activeId, _, _) = state.activeWing, activeId == sessionId {
                state.activeWing = nil
                state.doneBannerExpiresAt = nil
                effects.append(.cancelDoneRetract)
            } else if state.doneBannerExpiresAt != nil && state.activeWing == nil {
                state.doneBannerExpiresAt = nil
                effects.append(.cancelDoneRetract)
            }
            return effects
        }
    }
}

// MARK: - Sessions Filter & Keyboard Navigation

public enum SessionStatusFilter: String, CaseIterable, Sendable {
    case all
    case running
    case waiting
    case done
}

public enum SessionNavLogic {

    /// Deterministic wrap-around list cursor navigation for keyboard ↑/↓ selection.
    public static func moveSelection(
        currentId: String?,
        orderedIds: [String],
        delta: Int
    ) -> String? {
        guard !orderedIds.isEmpty else { return nil }
        guard let currentId = currentId,
              let idx = orderedIds.firstIndex(of: currentId) else {
            return delta >= 0 ? orderedIds.first : orderedIds.last
        }
        let count = orderedIds.count
        let next = ((idx + delta) % count + count) % count
        return orderedIds[next]
    }
}

public enum SessionFilterLogic {
    /// Remove `.waiting` sessions from workspace groups when elevated to the top
    /// `NEEDS ATTENTION` block so sessions never appear duplicated on screen.
    public static func nonWaitingGroups(from groups: [SessionGroup]) -> [SessionGroup] {
        groups.compactMap { group in
            let remaining = group.sessions.filter { $0.status != .waiting }
            guard !remaining.isEmpty else { return nil }
            return SessionGroup(cwd: group.cwd, label: group.label, sessions: remaining)
        }
    }
}

// MARK: - Switchable Telemetry Theme Presets

public enum TelemetryThemePreset: String, CaseIterable, Codable, Sendable {
    case monolith
    case blueprint
    case phosphor
    case amber

    public var next: TelemetryThemePreset {
        switch self {
        case .monolith:  return .blueprint
        case .blueprint: return .phosphor
        case .phosphor:  return .amber
        case .amber:     return .monolith
        }
    }

    public var usesMonochromeStrata: Bool {
        switch self {
        case .monolith, .amber:
            return true
        case .blueprint, .phosphor:
            return false
        }
    }
}

// MARK: - Telemetry Visual Mode (Instrument vs Classic Charts)

public enum TelemetryVisualMode: String, CaseIterable, Codable, Sendable {
    case instrument
    case classic

    public var toggled: TelemetryVisualMode {
        self == .instrument ? .classic : .instrument
    }
}
