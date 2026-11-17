import Foundation

// MARK: - Local usage archive — pure core
//
// A durable, monotonic, per-day aggregate of usage facts kept by AGYMonitor so
// history survives Antigravity brain/transcript cleanup.
//
// CORRECTNESS INVARIANT: a past day's usage only ever GROWS as more of its
// conversations are scanned, and never shrinks — the only thing that lowers a
// recompute is transcript deletion. Every merge is MONOTONIC: an incoming
// day/model observation replaces the stored one only when it is at least as
// complete (≥ tokens; ≥ active seconds for time).
//
// Pure & Foundation-only (part of AGYCore): file I/O, threading, and the
// on/off preference live in the app-side `UsageArchive`.

/// One model class's token + cost aggregate for a single day.
public struct ArchivedModel: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var messages: Int
    public var cost: Double

    public var totalTokens: Int { inputTokens + outputTokens + cacheRead + cacheWrite }

    public init(
        inputTokens: Int,
        outputTokens: Int,
        cacheRead: Int,
        cacheWrite: Int,
        messages: Int,
        cost: Double
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.messages = messages
        self.cost = cost
    }
}

/// All archived facts for one local day ("yyyy-MM-dd").
public struct ArchivedDay: Codable, Equatable, Sendable {
    /// Per model-class aggregate, keyed by `ModelClass.rawValue`.
    public var models: [String: ArchivedModel]
    /// Largest active-second total ever observed for the day.
    public var timeSeconds: Int
    /// Gap-merged wall-clock intervals, present when a month/range scan observed them.
    public var timeIntervals: [ActiveInterval]?

    public init(
        models: [String: ArchivedModel] = [:],
        timeSeconds: Int = 0,
        timeIntervals: [ActiveInterval]? = nil
    ) {
        self.models = models
        self.timeSeconds = timeSeconds
        self.timeIntervals = timeIntervals
    }

    public var totalCost: Double { models.values.reduce(0) { $0 + $1.cost } }
    public var totalTokens: Int { models.values.reduce(0) { $0 + $1.totalTokens } }
}

/// The whole archive: schema version (for forward-compatible reads) + days.
public struct UsageArchiveData: Codable, Equatable, Sendable {
    public static let currentSchema = 2
    public var schemaVersion: Int
    public var days: [String: ArchivedDay]

    public init(
        schemaVersion: Int = UsageArchiveData.currentSchema,
        days: [String: ArchivedDay] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.days = days
    }
}

/// Stateless merge + read transforms over `UsageArchiveData`.
public enum UsageArchiveLogic {

    // MARK: Merges (monotonic)

    private static func adopt(_ incoming: ArchivedModel, over stored: ArchivedModel?) -> ArchivedModel {
        guard let stored = stored else { return incoming }
        return incoming.totalTokens >= stored.totalTokens ? incoming : stored
    }

    /// Merge one day's per-model token/cost breakdown. Returns true if the archive changed.
    @discardableResult
    public static func mergeDay(_ day: DailyUsage, into data: inout UsageArchiveData) -> Bool {
        guard !AppDate.isSentinelDayKey(day.dateString) else { return false }
        var stored = data.days[day.dateString] ?? ArchivedDay()
        var changed = false
        for m in day.models {
            let key = (ModelClass.parse(m.id) ?? ModelClass.classify(m.id)).rawValue
            let incoming = ArchivedModel(
                inputTokens: m.inputTokens,
                outputTokens: m.outputTokens,
                cacheRead: m.cacheRead,
                cacheWrite: m.cacheWrite,
                messages: m.messages,
                cost: m.cost
            )
            if incoming.totalTokens == 0 && incoming.messages == 0 && incoming.cost == 0
                && stored.models[key] == nil { continue }
            let merged = adopt(incoming, over: stored.models[key])
            if merged != stored.models[key] {
                stored.models[key] = merged
                changed = true
            }
        }
        if changed { data.days[day.dateString] = stored }
        return changed
    }

    /// Returns the set of day keys ("yyyy-MM-dd") whose archived value changed.
    @discardableResult
    public static func mergeDaily(_ daily: [DailyUsage]?, into data: inout UsageArchiveData) -> Set<String> {
        guard let daily = daily else { return [] }
        var changed: Set<String> = []
        for day in daily where mergeDay(day, into: &data) {
            changed.insert(day.dateString)
        }
        return changed
    }

    /// Merge full active-time days (seconds + intervals). Returns changed day keys.
    @discardableResult
    public static func mergeTime(_ time: TimeData?, into data: inout UsageArchiveData) -> Set<String> {
        guard let time = time else { return [] }
        var changed: Set<String> = []
        for (key, dtu) in time.days {
            guard !AppDate.isSentinelDayKey(key) else { continue }
            if dtu.totalSeconds == 0 && dtu.intervals.isEmpty { continue }
            var stored = data.days[key] ?? ArchivedDay()
            if dtu.totalSeconds >= stored.timeSeconds {
                let newIntervals = dtu.intervals
                if stored.timeSeconds != dtu.totalSeconds || stored.timeIntervals != newIntervals {
                    stored.timeSeconds = dtu.totalSeconds
                    stored.timeIntervals = newIntervals
                    data.days[key] = stored
                    changed.insert(key)
                }
            }
        }
        return changed
    }

    /// Merge per-day active seconds only (`--time-year` payload).
    @discardableResult
    public static func mergeYearSeconds(_ days: [String: Int], into data: inout UsageArchiveData) -> Set<String> {
        var changed: Set<String> = []
        for (key, seconds) in days where seconds > 0 && !AppDate.isSentinelDayKey(key) {
            var stored = data.days[key] ?? ArchivedDay()
            if seconds > stored.timeSeconds {
                stored.timeSeconds = seconds
                data.days[key] = stored
                changed.insert(key)
            }
        }
        return changed
    }

    // MARK: Reads (overlay sources)

    /// Reconstruct a month's `[DailyUsage]` from the archive (sorted by day).
    public static func dailyBreakdown(_ data: UsageArchiveData, yearMonth: String) -> [DailyUsage] {
        var result: [DailyUsage] = []
        for dateStr in data.days.keys.sorted() where dateStr.hasPrefix(yearMonth) && !AppDate.isSentinelDayKey(dateStr) {
            guard let day = data.days[dateStr], !day.models.isEmpty else { continue }
            var models: [ModelUsage] = []
            var totalTokens = 0
            var totalCost = 0.0
            for cls in ModelClass.allCases {
                guard let a = day.models[cls.rawValue] else { continue }
                if a.totalTokens == 0 && a.messages == 0 && a.cost == 0 { continue }
                models.append(ModelUsage(
                    id: cls.rawValue,
                    name: cls.displayName,
                    cost: a.cost,
                    messages: a.messages,
                    inputTokens: a.inputTokens,
                    outputTokens: a.outputTokens,
                    cacheRead: a.cacheRead,
                    cacheWrite: a.cacheWrite
                ))
                totalTokens += a.totalTokens
                totalCost += a.cost
            }
            guard !models.isEmpty else { continue }
            let dayNum = Int(dateStr.suffix(2)) ?? 1
            result.append(DailyUsage(
                dateString: dateStr,
                day: dayNum,
                cost: totalCost,
                totalTokens: totalTokens,
                models: models
            ))
        }
        return result
    }

    /// Reconstruct a month's active-time days from the archive.
    public static func timeDays(_ data: UsageArchiveData, yearMonth: String) -> [String: DayTimeUsage] {
        var days: [String: DayTimeUsage] = [:]
        for (key, day) in data.days where key.hasPrefix(yearMonth) && !AppDate.isSentinelDayKey(key) {
            let intervals = day.timeIntervals ?? []
            guard day.timeSeconds > 0 || !intervals.isEmpty else { continue }
            days[key] = DayTimeUsage(intervals: intervals, totalSeconds: day.timeSeconds)
        }
        return days
    }

    /// Per-day active seconds for a whole year (year-heatmap overlay source).
    public static func yearSeconds(_ data: UsageArchiveData, year: Int) -> [String: Int] {
        let prefix = String(format: "%04d-", year)
        var days: [String: Int] = [:]
        for (key, day) in data.days where key.hasPrefix(prefix) && !AppDate.isSentinelDayKey(key) && day.timeSeconds > 0 {
            days[key] = day.timeSeconds
        }
        return days
    }
}
