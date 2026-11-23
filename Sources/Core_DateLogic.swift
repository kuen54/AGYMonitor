import Foundation

// MARK: - Date utilities (Gregorian, locale-stable) — pure core
//
// All data-path date math MUST go through these instead of Calendar.current /
// bare DateFormatter(): on a non-Gregorian system calendar (Japanese, Buddhist,
// …) Calendar.current yields era-relative years (e.g. 2569) and locale-less
// formatters can emit non-Gregorian or non-ASCII digits — every "yyyy-MM-dd"
// key would then mismatch the Python script's Gregorian local-date keys and
// Today/Week silently show 0. Human-facing display (viewingMonthLabel, …)
// intentionally keeps locale-aware formatting.
//
// Thread-safety: DateFormatter is NOT thread-safe and these helpers are hit
// from both the main thread and background queues, so no DateFormatter is
// shared — `dayKey`/`monthKey` and `parseISO8601` use pure Gregorian calendar
// components and integer arithmetic, safe from any thread.
//
// Testability: every time-dependent function takes an explicit `now: Date`
// (defaulting to `Date()` for call-site convenience; tests pass explicit dates).
public enum AppDate {
    /// Gregorian calendar pinned for data-path math. Keeps the user's LOCAL
    /// time zone: day keys must match the Python script's local-date buckets.
    public static let gregorian: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        return cal
    }()

    /// Gregorian UTC calendar for RFC3339 / ISO-8601 wire timestamp decoding.
    public static let utcGregorian: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    /// "yyyy-MM-dd" key in the local time zone, Gregorian, ASCII digits.
    public static func dayKey(_ date: Date) -> String {
        let c = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "yyyy-MM" key in the local time zone, Gregorian, ASCII digits.
    public static func monthKey(_ date: Date) -> String {
        let c = gregorian.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    /// Monday 00:00 (local) of the week containing `date`.
    public static func mondayOfWeek(containing date: Date) -> Date? {
        let weekday = gregorian.component(.weekday, from: date)  // 1=Sun, 2=Mon, …
        let daysFromMonday = (weekday + 5) % 7                   // Mon=0 … Sun=6
        guard let monday = gregorian.date(byAdding: .day, value: -daysFromMonday, to: date) else {
            return nil
        }
        return gregorian.startOfDay(for: monday)
    }

    /// Number of days in a Gregorian month (28–31), or nil on invalid month/year.
    public static func daysInMonth(year: Int, month: Int) -> Int? {
        guard (1...12).contains(month), year >= 1 else { return nil }
        let cal = gregorian
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = 1
        guard let start = cal.date(from: comps),
              let next = cal.date(byAdding: .month, value: 1, to: start),
              let last = cal.date(byAdding: .day, value: -1, to: next) else { return nil }
        return cal.component(.day, from: last)
    }

    /// Build a "YYYY-MM-01:YYYY-MM-DD" range string for a given year/month.
    public static func monthDateRange(year: Int, month: Int) -> String {
        let day = daysInMonth(year: year, month: month) ?? 28
        return String(format: "%04d-%02d-01:%04d-%02d-%02d", year, month, year, month, day)
    }

    /// Derive today's PeriodUsage from daily breakdown.
    public static func deriveToday(_ daily: [DailyUsage]?, now: Date = Date()) -> PeriodUsage {
        let todayStr = dayKey(now)
        if let day = daily?.first(where: { $0.dateString == todayStr }) {
            return PeriodUsage(
                cost: day.cost,
                models: day.models,
                totalMessages: day.models.reduce(0) { $0 + $1.messages },
                totalTokens: day.totalTokens
            )
        }
        return PeriodUsage(cost: 0, models: [], totalMessages: 0, totalTokens: 0)
    }

    /// Derive this week's PeriodUsage from daily breakdown (Monday = week start).
    public static func deriveWeek(_ daily: [DailyUsage]?, now: Date = Date()) -> PeriodUsage {
        guard let daily = daily else {
            return PeriodUsage(cost: 0, models: [], totalMessages: 0, totalTokens: 0)
        }
        guard let monday = mondayOfWeek(containing: now) else {
            return PeriodUsage(cost: 0, models: [], totalMessages: 0, totalTokens: 0)
        }
        let mondayStr = dayKey(monday)
        let weekDays = daily.filter { $0.dateString >= mondayStr }
        return UsageParser.mergeDailyUsages(weekDays)
    }

    // MARK: - Antigravity ISO-8601 & Go zero-time sentinel helpers

    /// True when `raw` is blank or represents Go's zero `time.Time{}` sentinel
    /// (`"0001-01-01T00:00:00Z"`, `"0001-01-01"`, `"0000-..."`), which Antigravity
    /// writes on 0-step uninitialized conversations.
    public static func isSentinelTimestamp(_ raw: String?) -> Bool {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return true }
        return trimmed.hasPrefix("0001-01-01") || trimmed.hasPrefix("0000-")
    }

    /// True when a day key (`"YYYY-MM-DD"`) is a Go zero-date sentinel (`"0001-01-01"`).
    public static func isSentinelDayKey(_ dayKey: String) -> Bool {
        let t = dayKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t.hasPrefix("0001-") || t.hasPrefix("0000-")
    }

    /// Pure Gregorian month-length lookup (28–31) without Calendar allocation.
    private static func gregorianDaysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11:           return 30
        case 2:
            let isLeap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
            return isLeap ? 29 : 28
        default:
            return 0
        }
    }

    /// Strict validator for `"YYYY-MM"` month keys:
    /// exactly 7 ASCII bytes, year in `1970...9998`, month in `1...12`.
    public static func isValidMonthKey(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        guard bytes.count == 7, bytes[4] == 45 else { return false } // '-'
        func digit(_ idx: Int) -> Int? {
            let b = bytes[idx]
            guard b >= 48 && b <= 57 else { return nil }
            return Int(b - 48)
        }
        guard let y0 = digit(0), let y1 = digit(1), let y2 = digit(2), let y3 = digit(3),
              let m0 = digit(5), let m1 = digit(6) else {
            return false
        }
        let year = y0 * 1000 + y1 * 100 + y2 * 10 + y3
        let month = m0 * 10 + m1
        return (1970...9998).contains(year) && (1...12).contains(month)
    }

    /// Strict validator for `"YYYY-MM-DD"` day keys:
    /// exactly 10 ASCII bytes, year in `1970...9998`, month in `1...12`,
    /// valid Gregorian calendar day for that `(year, month)`, and not a sentinel.
    public static func isValidDayKey(_ key: String) -> Bool {
        guard !isSentinelDayKey(key) else { return false }
        let bytes = Array(key.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45 else { return false } // '-'
        func digit(_ idx: Int) -> Int? {
            let b = bytes[idx]
            guard b >= 48 && b <= 57 else { return nil }
            return Int(b - 48)
        }
        guard let y0 = digit(0), let y1 = digit(1), let y2 = digit(2), let y3 = digit(3),
              let m0 = digit(5), let m1 = digit(6),
              let d0 = digit(8), let d1 = digit(9) else {
            return false
        }
        let year = y0 * 1000 + y1 * 100 + y2 * 10 + y3
        let month = m0 * 10 + m1
        let day = d0 * 10 + d1
        guard (1970...9998).contains(year), (1...12).contains(month) else {
            return false
        }
        let maxDay = gregorianDaysInMonth(year: year, month: month)
        return day >= 1 && day <= maxDay
    }

    /// Thread-safe RFC3339 / ISO-8601 parser supporting:
    /// - UTC `"Z"` and numeric offsets (`"+08:00"`, `"-05:30"`, `"+0800"`)
    /// - 0 to 9+ fractional digits (Go `time.RFC3339Nano` emits up to 9 digits,
    ///   e.g. `"2026-11-16T19:52:50.623324036+08:00"`)
    /// - Automatic filtering of `"0001-01-01..."` sentinel timestamps (`returns nil`).
    public static func parseISO8601(_ raw: String?) -> Date? {
        guard let raw = raw else { return nil }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSentinelTimestamp(s) else { return nil }

        let bytes = Array(s.utf8)
        // Minimum valid length: "YYYY-MM-DDTHH:MM:SSZ" = 20 ASCII bytes.
        guard bytes.count >= 20 else { return nil }

        func digit(_ idx: Int) -> Int? {
            let b = bytes[idx]
            guard b >= 48 && b <= 57 else { return nil }
            return Int(b - 48)
        }
        func int2(_ idx: Int) -> Int? {
            guard let a = digit(idx), let b = digit(idx + 1) else { return nil }
            return a * 10 + b
        }
        func int4(_ idx: Int) -> Int? {
            guard let hi = int2(idx), let lo = int2(idx + 2) else { return nil }
            return hi * 100 + lo
        }

        guard bytes[4] == 45, bytes[7] == 45,                       // '-'
              (bytes[10] == 84 || bytes[10] == 116 || bytes[10] == 32), // 'T', 't', ' '
              bytes[13] == 58, bytes[16] == 58,                     // ':'
              let year = int4(0), year >= 2,
              let month = int2(5), (1...12).contains(month),
              let day = int2(8), (1...31).contains(day),
              let hour = int2(11), (0...23).contains(hour),
              let minute = int2(14), (0...59).contains(minute),
              let second = int2(17), (0...60).contains(second) else {
            return nil
        }

        var i = 19
        var fractional: TimeInterval = 0
        if i < bytes.count && (bytes[i] == 46 || bytes[i] == 44) { // '.' or ','
            i += 1
            let fracStart = i
            var nanos: Int64 = 0
            var scaleDigits = 0
            while i < bytes.count, bytes[i] >= 48 && bytes[i] <= 57 {
                if scaleDigits < 9 {
                    nanos = nanos * 10 + Int64(bytes[i] - 48)
                    scaleDigits += 1
                }
                i += 1
            }
            guard i > fracStart else { return nil } // trailing '.' with no digits
            while scaleDigits < 9 {
                nanos *= 10
                scaleDigits += 1
            }
            fractional = Double(nanos) / 1_000_000_000.0
        }

        guard i < bytes.count else { return nil }
        let tzOffsetSeconds: Int
        if bytes[i] == 90 || bytes[i] == 122 { // 'Z' or 'z'
            i += 1
            guard i == bytes.count else { return nil }
            tzOffsetSeconds = 0
        } else if bytes[i] == 43 || bytes[i] == 45 { // '+' or '-'
            let sign = bytes[i] == 43 ? 1 : -1
            i += 1
            guard i + 2 <= bytes.count, let tzH = int2(i), (0...23).contains(tzH) else {
                return nil
            }
            i += 2
            var tzM = 0
            if i < bytes.count && bytes[i] == 58 { // ':'
                i += 1
                guard i + 2 <= bytes.count, let m = int2(i), (0...59).contains(m) else {
                    return nil
                }
                tzM = m
                i += 2
            } else if i + 2 <= bytes.count, let m = int2(i), (0...59).contains(m) {
                tzM = m
                i += 2
            }
            guard i == bytes.count else { return nil }
            tzOffsetSeconds = sign * (tzH * 3600 + tzM * 60)
        } else {
            return nil
        }

        let clampedSecond = min(second, 59)
        let extraLeapSecond: TimeInterval = second == 60 ? 1.0 : 0.0
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = clampedSecond
        guard let utcBase = utcGregorian.date(from: comps) else { return nil }
        // Reject overflow dates like 2026-02-30 that Calendar normalizes into March.
        let check = utcGregorian.dateComponents([.year, .month, .day], from: utcBase)
        guard check.year == year, check.month == month, check.day == day else { return nil }

        return utcBase.addingTimeInterval(fractional + extraLeapSecond - TimeInterval(tzOffsetSeconds))
    }
}
