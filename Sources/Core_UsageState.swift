import Foundation

// MARK: - Usage Loading, Month Navigation, Refresh Queue & Archive Gates — pure core
//
// Isolates current-month, historical-month, and year-heatmap loading states so a
// background scan can never clobber an active historical month's spinner/empty/error
// view, `⌘R` force-refreshes queue cleanly instead of dropping, midnight month-end
// rollovers auto-advance when following the current month, and failed archive sweeps
// don't lock themselves out for 6 hours.
//
// Foundation-only (part of AGYCore).

public enum UsageLoadError: String, Equatable, Sendable {
    case scriptFailed
}

public enum LoadPhase<Value: Equatable & Sendable>: Equatable, Sendable {
    case idle
    case loading(cached: Value?)
    case loaded(Value)
    case empty
    case failed(UsageLoadError, cached: Value?)

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    public var value: Value? {
        switch self {
        case .loaded(let v):
            return v
        case .loading(let cached), .failed(_, let cached):
            return cached
        case .idle, .empty:
            return nil
        }
    }

    public var cachedValue: Value? { value }

    public var error: UsageLoadError? {
        if case .failed(let err, _) = self { return err }
        return nil
    }

    public var hasFailedWithoutValue: Bool {
        error != nil && value == nil
    }

    public func transitioningToLoading() -> LoadPhase<Value> {
        .loading(cached: value)
    }
}

public struct CurrentMonthBundle: Equatable, Sendable {
    public let today: PeriodUsage
    public let week: PeriodUsage
    public let month: PeriodUsage
    public let dailyBreakdown: [DailyUsage]?
    public let time: TimeData?

    public init(
        today: PeriodUsage,
        week: PeriodUsage,
        month: PeriodUsage,
        dailyBreakdown: [DailyUsage]?,
        time: TimeData?
    ) {
        self.today = today
        self.week = week
        self.month = month
        self.dailyBreakdown = dailyBreakdown
        self.time = time
    }
}

public struct HistoricalMonthBundle: Equatable, Sendable {
    public let month: PeriodUsage
    public let dailyBreakdown: [DailyUsage]?
    public let time: TimeData?

    public init(
        month: PeriodUsage,
        dailyBreakdown: [DailyUsage]?,
        time: TimeData?
    ) {
        self.month = month
        self.dailyBreakdown = dailyBreakdown
        self.time = time
    }
}

public enum RefreshQueueCompletion: Equatable, Sendable {
    case idle
    case runFollowUp(force: Bool)
}

public struct RefreshQueueState: Equatable, Sendable {
    public private(set) var isInFlight: Bool = false
    public private(set) var currentForce: Bool = false
    public private(set) var pendingFollowUp: Bool = false
    public private(set) var pendingForce: Bool = false

    public init() {}

    /// True when a forced follow-up refresh is already queued behind the active scan.
    /// Callers can check this (or use `phaseForIntermediateResult`) to avoid flashing
    /// `.loaded` / `.failed` for a single frame before the follow-up scan begins.
    public var hasPendingFollowUp: Bool { pendingFollowUp }

    /// Request a refresh. Manual `force: true` (`⌘R`) arriving while an automatic scan
    /// is in flight queues a forced follow-up rather than being silently dropped.
    public mutating func request(force: Bool) -> (shouldStartNow: Bool, effectiveForce: Bool) {
        if !isInFlight {
            isInFlight = true
            currentForce = force
            pendingFollowUp = false
            pendingForce = false
            return (true, force)
        }
        if force {
            pendingFollowUp = true
            pendingForce = true
        }
        return (false, false)
    }

    /// Returns `.loading(cached: resultPhase.value)` when a follow-up refresh is already queued,
    /// keeping the UI in a smooth loading state instead of flashing `.loaded` -> `.loading`.
    public func phaseForIntermediateResult<Value: Equatable & Sendable>(
        _ resultPhase: LoadPhase<Value>
    ) -> LoadPhase<Value> {
        pendingFollowUp ? resultPhase.transitioningToLoading() : resultPhase
    }

    public mutating func complete() -> (shouldRunFollowUp: Bool, followUpForce: Bool) {
        if pendingFollowUp {
            let nextForce = pendingForce
            isInFlight = true
            currentForce = nextForce
            pendingFollowUp = false
            pendingForce = false
            return (true, nextForce)
        }
        isInFlight = false
        currentForce = false
        return (false, false)
    }

    /// Typed alternative to `complete()` returning `.idle` or `.runFollowUp(force:)`.
    public mutating func completeAction() -> RefreshQueueCompletion {
        let next = complete()
        return next.shouldRunFollowUp ? .runFollowUp(force: next.followUpForce) : .idle
    }

    public mutating func reset() {
        isInFlight = false
        currentForce = false
        pendingFollowUp = false
        pendingForce = false
    }
}

public struct MonthNavigationState: Equatable, Sendable {
    public private(set) var viewingYear: Int
    public private(set) var viewingMonth: Int
    public private(set) var followingCurrentMonth: Bool

    public init(now: Date = Date()) {
        let cal = AppDate.gregorian
        self.viewingYear = cal.component(.year, from: now)
        self.viewingMonth = cal.component(.month, from: now)
        self.followingCurrentMonth = true
    }

    public init(year: Int, month: Int, followingCurrentMonth: Bool) {
        self.viewingYear = year
        self.viewingMonth = month
        self.followingCurrentMonth = followingCurrentMonth
    }

    public var yearMonthKey: String {
        String(format: "%04d-%02d", viewingYear, viewingMonth)
    }

    public func isViewingCurrentMonth(now: Date = Date()) -> Bool {
        Self.isCurrentMonth(year: viewingYear, month: viewingMonth, now: now)
    }

    /// True iff `(year, month)` matches the Gregorian wall-clock current month at `now`.
    public static func isCurrentMonth(year: Int, month: Int, now: Date = Date()) -> Bool {
        SnapshotFreshnessPolicy.isFreshCurrentMonthFetch(
            fetchedYear: year,
            fetchedMonth: month,
            now: now
        )
    }

    public mutating func setViewing(year: Int, month: Int, now: Date = Date()) {
        viewingYear = year
        viewingMonth = month
        followingCurrentMonth = isViewingCurrentMonth(now: now)
    }

    @discardableResult
    public mutating func navigate(offset: Int, now: Date = Date()) -> Bool {
        var comps = DateComponents()
        comps.year = viewingYear
        comps.month = viewingMonth + offset
        comps.day = 1
        guard let date = AppDate.gregorian.date(from: comps) else { return false }
        let cal = AppDate.gregorian
        viewingYear = cal.component(.year, from: date)
        viewingMonth = cal.component(.month, from: date)
        followingCurrentMonth = isViewingCurrentMonth(now: now)
        return true
    }

    /// Auto-advance if the user was following the current month across a midnight month boundary.
    @discardableResult
    public mutating func syncClock(now: Date = Date()) -> Bool {
        guard followingCurrentMonth else { return false }
        let cal = AppDate.gregorian
        let curY = cal.component(.year, from: now)
        let curM = cal.component(.month, from: now)
        guard viewingYear != curY || viewingMonth != curM else { return false }
        viewingYear = curY
        viewingMonth = curM
        return true
    }
}

public struct YearLoadGate: Equatable, Sendable {
    public private(set) var activeYear: Int? = nil
    public private(set) var generation: Int = 0

    public init() {}

    /// Deduplicates overlapping non-forced requests for the same year while keeping
    /// generation ordering for cross-year switches and forced refreshes.
    /// Switching to a cached year while another year is in flight cancels `activeYear`
    /// and advances `generation` so bouncing `2026 -> 2025 -> 2026 -> 2025` never gets
    /// stuck displaying the wrong year's heatmap.
    public mutating func beginLoad(year: Int, force: Bool, hasCachedValue: Bool) -> Int? {
        if !force && hasCachedValue {
            if activeYear != nil {
                activeYear = nil
                generation += 1
            }
            return nil
        }
        if !force && activeYear == year {
            return nil
        }
        generation += 1
        activeYear = year
        return generation
    }

    public mutating func completeLoad(generation gen: Int) {
        if gen == generation {
            activeYear = nil
        }
    }

    public mutating func invalidateAll() {
        activeYear = nil
        generation += 1
    }
}

/// Generation & deduplication gate for historical-month fetches (`YYYY-MM`),
/// mirroring `YearLoadGate` so navigating months or midnight rollovers cleanly
/// invalidates stale in-flight scripts without scattered `fetchGeneration += 1`.
public struct HistoricalMonthLoadGate: Equatable, Sendable {
    public private(set) var activeYearMonth: String? = nil
    public private(set) var generation: Int = 0

    public init() {}

    /// Start a historical-month load. Returns a monotonic generation token, or `nil`
    /// if an identical non-forced load for the same `yearMonth` is already in flight.
    public mutating func beginLoad(yearMonth: String, force: Bool) -> Int? {
        if !force && activeYearMonth == yearMonth {
            return nil
        }
        generation += 1
        activeYearMonth = yearMonth
        return generation
    }

    /// True iff `generation` is still the latest load and matches `currentYearMonth`.
    public func isCurrent(generation gen: Int, yearMonth: String, currentYearMonth: String) -> Bool {
        gen == generation && yearMonth == currentYearMonth
    }

    public mutating func completeLoad(generation gen: Int) {
        if gen == generation {
            activeYearMonth = nil
        }
    }

    /// Cancel any in-flight historical load (e.g. navigating to another month or back to current).
    public mutating func invalidate() {
        activeYearMonth = nil
        generation += 1
    }
}

public struct ArchiveSweepGate: Equatable, Sendable {
    public private(set) var isInFlight: Bool = false
    public private(set) var lastSucceededAt: Date? = nil
    public private(set) var generation: Int = 0
    public let minInterval: TimeInterval

    public init(minInterval: TimeInterval = 6 * 3600, lastSucceededAt: Date? = nil) {
        self.minInterval = minInterval
        self.lastSucceededAt = lastSucceededAt
    }

    public mutating func shouldStart(force: Bool, enabled: Bool, now: Date = Date()) -> Bool {
        beginSweep(force: force, enabled: enabled, now: now) != nil
    }

    /// Starts a sweep and returns a monotonic generation token, or `nil` if gated.
    public mutating func beginSweep(force: Bool, enabled: Bool, now: Date = Date()) -> Int? {
        guard enabled, !isInFlight else { return nil }
        if !force, let last = lastSucceededAt, now.timeIntervalSince(last) < minInterval {
            return nil
        }
        isInFlight = true
        generation += 1
        return generation
    }

    public func isCurrent(generation token: Int) -> Bool {
        token == generation
    }

    /// Only successful sweeps stamp `lastSucceededAt`; failures remain immediately retryable.
    public mutating func finish(succeeded: Bool, now: Date = Date()) {
        isInFlight = false
        if succeeded {
            lastSucceededAt = now
        }
    }

    /// Generation-checked completion: returns `false` if invalidated mid-flight (e.g. `clearArchive()`
    /// or `archiveHistoryLocally = false`) so stale sweeps never resurrect deleted data.
    @discardableResult
    public mutating func finish(generation token: Int, succeeded: Bool, now: Date = Date()) -> Bool {
        guard token == generation else { return false }
        finish(succeeded: succeeded, now: now)
        return true
    }

    /// Invalidate any in-flight sweep and clear cooldown (e.g. on `clearArchive()` or toggle off).
    public mutating func reset() {
        isInFlight = false
        lastSucceededAt = nil
        generation += 1
    }
}

// MARK: - Historical Disk Snapshot Completeness & Year Bounds

public enum SnapshotFreshnessPolicy {

    /// Canonical `"YYYY-MM"` key for `(year, month)`.
    public static func yearMonthKey(year: Int, month: Int) -> String {
        String(format: "%04d-%02d", year, month)
    }

    /// Canonical `"YYYY-MM"` key for `now` using `AppDate.gregorian`.
    public static func currentYearMonthKey(now: Date = Date()) -> String {
        let cal = AppDate.gregorian
        return yearMonthKey(
            year: cal.component(.year, from: now),
            month: cal.component(.month, from: now)
        )
    }

    /// True iff a current-month fetch started for `(fetchedYear, fetchedMonth)` still matches
    /// the Gregorian wall-clock current month at `now`. Prevents a scan started at 23:59 on the
    /// last day of a month from overwriting `currentMonthData` after midnight rollover.
    public static func isFreshCurrentMonthFetch(
        fetchedYear: Int,
        fetchedMonth: Int,
        now: Date = Date()
    ) -> Bool {
        let cal = AppDate.gregorian
        return fetchedYear == cal.component(.year, from: now)
            && fetchedMonth == cal.component(.month, from: now)
    }

    /// String-key (`"YYYY-MM"`) overload of `isFreshCurrentMonthFetch`.
    public static func isFreshCurrentMonthFetch(
        fetchedYearMonth: String,
        now: Date = Date()
    ) -> Bool {
        fetchedYearMonth == currentYearMonthKey(now: now)
    }

    /// A cached `YYYY-MM.json` snapshot is complete for a historical month ONLY if it was
    /// written at or after the first instant of the FOLLOWING month (`YYYY-(MM+1)-01 00:00`).
    /// Prevents permanent data truncation when a snapshot was written mid-month (e.g. Oct 15)
    /// and later viewed as a historical month (e.g. in November).
    public static func isCompleteHistoricalSnapshot(
        year: Int,
        month: Int,
        lastUpdated: Date
    ) -> Bool {
        var nextMonthComps = DateComponents()
        nextMonthComps.year = year
        nextMonthComps.month = month + 1
        nextMonthComps.day = 1
        guard let nextMonthStart = AppDate.gregorian.date(from: nextMonthComps) else {
            return false
        }
        return lastUpdated >= nextMonthStart
    }

    /// Clamp a requested heatmap year to `[1970, currentYear]` so keyboard/programmatic
    /// navigation can never request future years or invalid years below Python's floor.
    public static func clampedYear(_ year: Int, now: Date = Date()) -> Int {
        let currentYear = AppDate.gregorian.component(.year, from: now)
        return min(max(year, 1970), currentYear)
    }
}

public enum UsageStateLogic {

    public static func isEffectivelyEmpty(
        month: PeriodUsage,
        dailyBreakdown: [DailyUsage]?,
        time: TimeData?
    ) -> Bool {
        let hasDaily = !(dailyBreakdown?.isEmpty ?? true)
        let hasTime = time?.days.values.contains(where: {
            $0.totalSeconds > 0 || !$0.intervals.isEmpty
        }) ?? false
        return month.cost == 0
            && month.totalTokens == 0
            && month.totalMessages == 0
            && !hasDaily
            && !hasTime
    }

    public static func classifyCurrentMonth(
        today: PeriodUsage?,
        week: PeriodUsage?,
        month: PeriodUsage?,
        dailyBreakdown: [DailyUsage]?,
        time: TimeData?,
        scriptSucceeded: Bool,
        cached: CurrentMonthBundle?
    ) -> LoadPhase<CurrentMonthBundle> {
        guard scriptSucceeded, let m = month else {
            return .failed(.scriptFailed, cached: cached)
        }
        let empty = PeriodUsage(cost: 0, models: [], totalMessages: 0, totalTokens: 0)
        return .loaded(CurrentMonthBundle(
            today: today ?? empty,
            week: week ?? empty,
            month: m,
            dailyBreakdown: dailyBreakdown,
            time: time
        ))
    }

    public static func classifyHistoricalMonth(
        month: PeriodUsage?,
        dailyBreakdown: [DailyUsage]?,
        time: TimeData?,
        scriptSucceeded: Bool,
        cached: HistoricalMonthBundle?
    ) -> LoadPhase<HistoricalMonthBundle> {
        guard scriptSucceeded, let m = month else {
            return .failed(.scriptFailed, cached: cached)
        }
        if isEffectivelyEmpty(month: m, dailyBreakdown: dailyBreakdown, time: time) {
            return .empty
        }
        return .loaded(HistoricalMonthBundle(
            month: m,
            dailyBreakdown: dailyBreakdown,
            time: time
        ))
    }
}
