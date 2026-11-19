import Foundation

// MARK: - Data Models — pure core
//
// Foundation-only on purpose: these structs are part of the pure testable core
// (consumed by Core_UsageParser / Core_DateLogic and the AGYCore SPM target).
// UI concerns (ModelUsage.color) live in Views_Common.swift.
// App-only models (quota snapshots, DisplayTab, DisplayMode) stay in Models.swift.

public struct ModelUsage: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let cost: Double
    public let messages: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheRead: Int
    public let cacheWrite: Int

    public var totalTokens: Int { inputTokens + outputTokens + cacheRead + cacheWrite }

    public init(
        id: String,
        name: String,
        cost: Double,
        messages: Int,
        inputTokens: Int,
        outputTokens: Int,
        cacheRead: Int = 0,
        cacheWrite: Int = 0
    ) {
        self.id = id
        self.name = name
        self.cost = cost
        self.messages = messages
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }
}

public struct PeriodUsage: Codable, Equatable, Sendable {
    public let cost: Double
    public let models: [ModelUsage]
    public let totalMessages: Int
    public let totalTokens: Int

    public var totalInput: Int { models.reduce(0) { $0 + $1.inputTokens } }
    public var totalOutput: Int { models.reduce(0) { $0 + $1.outputTokens } }
    public var totalCacheRead: Int { models.reduce(0) { $0 + $1.cacheRead } }
    public var totalCacheWrite: Int { models.reduce(0) { $0 + $1.cacheWrite } }

    public init(cost: Double, models: [ModelUsage], totalMessages: Int, totalTokens: Int) {
        self.cost = cost
        self.models = models
        self.totalMessages = totalMessages
        self.totalTokens = totalTokens
    }
}

public struct DailyUsage: Codable, Identifiable, Equatable, Sendable {
    public var id: String { dateString }
    public let dateString: String   // "2026-11-16"
    public let day: Int             // 1..31
    public let cost: Double
    public let totalTokens: Int
    public let models: [ModelUsage]

    public init(dateString: String, day: Int, cost: Double, totalTokens: Int, models: [ModelUsage]) {
        self.dateString = dateString
        self.day = day
        self.cost = cost
        self.totalTokens = totalTokens
        self.models = models
    }
}

public struct MonthlySnapshot: Codable, Equatable, Sendable {
    public let year: Int
    public let month: Int
    public let data: PeriodUsage
    public let lastUpdated: Date
    public var dailyBreakdown: [DailyUsage]?
    /// Cross-month-safe "This Week" totals persisted alongside the month data:
    /// when the week's Monday falls in the previous month, the month scan
    /// (1st..today) can't cover those days, so the derived week would undercount.
    /// Optional so caches written by older versions still decode.
    public var week: PeriodUsage?
    /// "yyyy-MM-dd" Monday of the week `week` covers — staleness check on restore.
    public var weekStart: String?
    /// Active-time intervals for the snapshot's days (additive "time" section of
    /// the script JSON, plus cross-week extra-scan days when the week spans a
    /// month boundary). Optional so caches written by older versions still decode.
    public var time: TimeData?

    public init(
        year: Int,
        month: Int,
        data: PeriodUsage,
        lastUpdated: Date,
        dailyBreakdown: [DailyUsage]? = nil,
        week: PeriodUsage? = nil,
        weekStart: String? = nil,
        time: TimeData? = nil
    ) {
        self.year = year
        self.month = month
        self.data = data
        self.lastUpdated = lastUpdated
        self.dailyBreakdown = dailyBreakdown
        self.week = week
        self.weekStart = weekStart
        self.time = time
    }
}

// MARK: - Active time ("Time" tab)

/// One gap-merged active interval within a single local day, stored as
/// wall-clock seconds-of-day. `endSec` may be 86400 (next-midnight sentinel for
/// intervals split at a day boundary); `startSec == endSec` is a truthful
/// zero-duration interval (isolated single event) — the renderer pads it.
public struct ActiveInterval: Codable, Equatable, Sendable {
    public let startSec: Int
    public let endSec: Int
    /// Dominant model class for the interval ("carbon"/"argon"/"neon"/"hydrogen"/
    /// "flash"/"claude"/"other"). nil = no model-tagged event in the interval (user-only)
    /// or a pre-attribution payload. Cosmetic only — never affects durations.
    public let model: String?
    public var durationSeconds: Int { endSec - startSec }

    public init(startSec: Int, endSec: Int, model: String? = nil) {
        self.startSec = startSec
        self.endSec = endSec
        self.model = model
    }

    // Codable form mirrors the script's compact array [start, end, model|null]
    // so the snapshot cache and the wire JSON stay one shape. A 2-element
    // array decodes as model = nil — robustness against a 2-element payload.
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        startSec = try container.decode(Int.self)
        endSec = try container.decode(Int.self)
        model = container.isAtEnd ? nil : try container.decodeIfPresent(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(startSec)
        try container.encode(endSec)
        try container.encode(model)
    }
}

public struct DayTimeUsage: Codable, Equatable, Sendable {
    public let intervals: [ActiveInterval]
    public let totalSeconds: Int

    public init(intervals: [ActiveInterval], totalSeconds: Int) {
        self.intervals = intervals
        self.totalSeconds = totalSeconds
    }
}

/// Decoded `"time"` section of the script's month JSON: per-day gap-merged
/// active intervals. Keys are "yyyy-MM-dd" local day keys.
public struct TimeData: Codable, Equatable, Sendable {
    public let gapMinutes: Int
    public var days: [String: DayTimeUsage]

    public init(gapMinutes: Int, days: [String: DayTimeUsage]) {
        self.gapMinutes = gapMinutes
        self.days = days
    }
}
