import Foundation

// MARK: - Usage JSON parsing & merging — pure core
//
// Stateless statics over the `analyze_usage.py --json` output dictionary.
// No process spawning, no file I/O, no Date() — fully testable with synthetic
// JSON fixtures. UsageStore owns orchestration/caching and calls into these.
public enum UsageParser {

    private struct ModelAccum {
        var inp: Int = 0
        var out: Int = 0
        var cr: Int = 0
        var cw: Int = 0
        var msgs: Int = 0
        var cost: Double = 0.0
    }

    private static func isBoolean(_ any: Any) -> Bool {
        if type(of: any) == Bool.self { return true }
        if let n = any as? NSNumber {
            return CFGetTypeID(n) == CFBooleanGetTypeID()
        }
        return false
    }

    private static func intVal(_ any: Any?) -> Int? {
        guard let any = any, !isBoolean(any) else { return nil }
        if let i = any as? Int { return i }
        if let d = any as? Double {
            return Int(exactly: d.rounded())
        }
        if let n = any as? NSNumber {
            return Int(exactly: n.doubleValue.rounded())
        }
        return nil
    }

    private static func doubleVal(_ any: Any?) -> Double {
        guard let any = any, !isBoolean(any) else { return 0.0 }
        if let d = any as? Double, d.isFinite { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber, n.doubleValue.isFinite { return n.doubleValue }
        return 0.0
    }

    /// Normalize a JSON model key via `ModelClass(rawValue:) ?? ModelClass.classify(key)`
    /// per the shared AGYMonitor contract.
    private static func resolveClass(_ rawKey: String) -> ModelClass {
        let lower = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ModelClass(rawValue: lower) ?? ModelClass.classify(rawKey)
    }

    private static func parseModelsMap(_ rawDict: [String: Any]) -> (models: [ModelUsage], totalMessages: Int, totalTokens: Int) {
        var accum: [ModelClass: ModelAccum] = [:]
        for (key, rawVal) in rawDict {
            guard let data = rawVal as? [String: Any] else { continue }
            let cls = resolveClass(key)
            var entry = accum[cls] ?? ModelAccum()
            entry.inp  += intVal(data["input_tokens"]) ?? 0
            entry.out  += intVal(data["output_tokens"]) ?? 0
            entry.cr   += intVal(data["cache_read"]) ?? 0
            entry.cw   += intVal(data["cache_write"]) ?? 0
            entry.msgs += intVal(data["messages"]) ?? 0
            entry.cost += doubleVal(data["cost"])
            accum[cls] = entry
        }

        var models: [ModelUsage] = []
        var totalMessages = 0
        var totalTokens = 0
        for cls in ModelClass.allCases {
            guard let a = accum[cls] else { continue }
            let mu = ModelUsage(
                id: cls.rawValue,
                name: cls.displayName,
                cost: a.cost,
                messages: a.msgs,
                inputTokens: a.inp,
                outputTokens: a.out,
                cacheRead: a.cr,
                cacheWrite: a.cw
            )
            models.append(mu)
            totalMessages += a.msgs
            totalTokens += mu.totalTokens
        }
        return (models, totalMessages, totalTokens)
    }

    /// Parse PeriodUsage from JSON.
    public static func parsePeriod(_ json: [String: Any]) -> PeriodUsage? {
        let grandTotal = doubleVal(json["grand_total_cost"])
        if let totals = json["totals_by_model"] as? [String: Any] {
            let parsed = parseModelsMap(totals)
            return PeriodUsage(
                cost: grandTotal,
                models: parsed.models,
                totalMessages: parsed.totalMessages,
                totalTokens: parsed.totalTokens
            )
        }
        return PeriodUsage(cost: grandTotal, models: [], totalMessages: 0, totalTokens: 0)
    }

    /// Parse `daily_breakdown` from JSON filtered by `yearMonth` ("YYYY-MM").
    public static func parseDailyBreakdown(_ json: [String: Any], yearMonth: String) -> [DailyUsage]? {
        guard let breakdown = json["daily_breakdown"] as? [String: Any], !breakdown.isEmpty else {
            return nil
        }
        var result: [DailyUsage] = []
        for dateStr in breakdown.keys.sorted() {
            guard !AppDate.isSentinelDayKey(dateStr),
                  dateStr.hasPrefix(yearMonth),
                  let dayData = breakdown[dateStr] as? [String: Any],
                  let day = parseDayEntry(dateStr, dayData) else { continue }
            result.append(day)
        }
        return result.isEmpty ? nil : result
    }

    /// Parse the whole `daily_breakdown` with no month filter — used by the
    /// archive sweep. Sentinel date keys ("0001-01-01") are skipped.
    public static func parseAllDailyBreakdown(_ json: [String: Any]) -> [DailyUsage]? {
        guard let breakdown = json["daily_breakdown"] as? [String: Any], !breakdown.isEmpty else {
            return nil
        }
        var result: [DailyUsage] = []
        for dateStr in breakdown.keys.sorted() {
            guard !AppDate.isSentinelDayKey(dateStr),
                  let dayData = breakdown[dateStr] as? [String: Any],
                  let day = parseDayEntry(dateStr, dayData) else { continue }
            result.append(day)
        }
        return result.isEmpty ? nil : result
    }

    private static func parseDayEntry(_ dateStr: String, _ dayData: [String: Any]) -> DailyUsage? {
        let dayCost = doubleVal(dayData["total_cost"])
        var models: [ModelUsage] = []
        var totalTokens = 0
        if let modelsDict = dayData["models"] as? [String: Any] {
            let parsed = parseModelsMap(modelsDict)
            models = parsed.models
            totalTokens = parsed.totalTokens
        }
        let dayNum = Int(dateStr.suffix(2)) ?? 1
        return DailyUsage(
            dateString: dateStr,
            day: dayNum,
            cost: dayCost,
            totalTokens: totalTokens,
            models: models
        )
    }

    /// Merge multiple DailyUsage entries into a single PeriodUsage.
    public static func mergeDailyUsages(_ days: [DailyUsage]) -> PeriodUsage {
        guard !days.isEmpty else {
            return PeriodUsage(cost: 0, models: [], totalMessages: 0, totalTokens: 0)
        }
        var totalCost = 0.0
        var accum: [ModelClass: ModelAccum] = [:]
        for day in days {
            totalCost += day.cost
            for m in day.models {
                let cls = resolveClass(m.id)
                var prev = accum[cls] ?? ModelAccum()
                prev.inp  += m.inputTokens
                prev.out  += m.outputTokens
                prev.cr   += m.cacheRead
                prev.cw   += m.cacheWrite
                prev.msgs += m.messages
                prev.cost += m.cost
                accum[cls] = prev
            }
        }
        var models: [ModelUsage] = []
        var totalTokens = 0
        for cls in ModelClass.allCases {
            guard let a = accum[cls] else { continue }
            let mu = ModelUsage(
                id: cls.rawValue,
                name: cls.displayName,
                cost: a.cost,
                messages: a.msgs,
                inputTokens: a.inp,
                outputTokens: a.out,
                cacheRead: a.cr,
                cacheWrite: a.cw
            )
            models.append(mu)
            totalTokens += mu.totalTokens
        }
        return PeriodUsage(
            cost: totalCost,
            models: models,
            totalMessages: models.reduce(0) { $0 + $1.messages },
            totalTokens: totalTokens
        )
    }

    // MARK: Active time ("time" section / --time-year output)

    /// Parse the additive top-level `"time"` section of a month/range scan:
    ///   {"gap_minutes": G, "days": {"yyyy-MM-dd": {"intervals": [[s,e,model|null],...],
    ///                                              "total_seconds": N}, ...}}
    public static func parseTimeSection(_ json: [String: Any]) -> TimeData? {
        guard let section = json["time"] as? [String: Any],
              let gap = intVal(section["gap_minutes"]),
              let daysRaw = section["days"] as? [String: Any] else { return nil }
        var days: [String: DayTimeUsage] = [:]
        for (dayKey, value) in daysRaw {
            guard !AppDate.isSentinelDayKey(dayKey),
                  let dayDict = value as? [String: Any],
                  let entriesRaw = dayDict["intervals"] as? [Any],
                  let total = intVal(dayDict["total_seconds"]) else { continue }
            var intervals: [ActiveInterval] = []
            for entryAny in entriesRaw {
                guard let entry = entryAny as? [Any], (2...3).contains(entry.count),
                      let s = intVal(entry[0]), let e = intVal(entry[1]),
                      s >= 0, s <= e, e <= 86400 else { continue }
                let normalizedModel: String?
                if entry.count == 3,
                   let rawModel = entry[2] as? String,
                   !rawModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    normalizedModel = resolveClass(rawModel).rawValue
                } else {
                    normalizedModel = nil
                }
                intervals.append(ActiveInterval(startSec: s, endSec: e, model: normalizedModel))
            }
            days[dayKey] = DayTimeUsage(intervals: intervals, totalSeconds: total)
        }
        return TimeData(gapMinutes: gap, days: days)
    }

    /// Parse `--time-year YYYY` output:
    ///   {"year": YYYY, "gap_minutes": G, "days": {"yyyy-MM-dd": total_seconds}}
    public static func parseYearTime(_ json: [String: Any]) -> (year: Int, gapMinutes: Int, days: [String: Int])? {
        guard let year = intVal(json["year"]),
              let gap = intVal(json["gap_minutes"]),
              let daysRaw = json["days"] as? [String: Any] else { return nil }
        var days: [String: Int] = [:]
        for (dayKey, value) in daysRaw {
            guard !AppDate.isSentinelDayKey(dayKey),
                  let seconds = intVal(value) else { continue }
            days[dayKey] = seconds
        }
        return (year: year, gapMinutes: gap, days: days)
    }

    /// Merge the month scan's time days with the cross-week extra scan's:
    /// override days REPLACE base days.
    public static func mergeTimeData(base: TimeData?, override: TimeData?) -> TimeData? {
        guard let base = base else { return override }
        guard let override = override else { return base }
        var merged = base
        merged.days.merge(override.days) { _, overrideDay in overrideDay }
        return merged
    }

    // MARK: Cache snapshot codec (pure — UsageStore owns the file I/O)

    /// Encode a MonthlySnapshot with ISO-8601 dates.
    public static func encodeSnapshot(_ snapshot: MonthlySnapshot) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(snapshot)
    }

    /// Decode a MonthlySnapshot from the on-disk cache format.
    public static func decodeSnapshot(_ data: Data) -> MonthlySnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MonthlySnapshot.self, from: data)
    }
}
