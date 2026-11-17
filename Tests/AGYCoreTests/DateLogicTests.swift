import Foundation
import Testing
@testable import AGYCore

@Suite("Core_DateLogic")
struct DateLogicTests {

    @Test("dayKey, monthKey, mondayOfWeek, and daysInMonth use pinned Gregorian calendar")
    func gregorianKeysAndMondayMath() throws {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 11
        comps.day = 22 // Sunday
        comps.hour = 15
        let sunday = try #require(AppDate.gregorian.date(from: comps))

        #expect(AppDate.dayKey(sunday) == "2026-11-22")
        #expect(AppDate.monthKey(sunday) == "2026-11")

        let monday = try #require(AppDate.mondayOfWeek(containing: sunday))
        #expect(AppDate.dayKey(monday) == "2026-11-16")

        #expect(AppDate.daysInMonth(year: 2024, month: 2) == 29)
        #expect(AppDate.daysInMonth(year: 2026, month: 2) == 28)
        #expect(AppDate.daysInMonth(year: 2026, month: 11) == 30)
        #expect(AppDate.monthDateRange(year: 2026, month: 11) == "2026-11-01:2026-11-30")
    }

    @Test("deriveToday and deriveWeek aggregate matching days for injected now")
    func deriveTodayAndWeek() throws {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 11
        comps.day = 18 // Wednesday (Monday = 2026-11-16)
        comps.hour = 12
        let wed = try #require(AppDate.gregorian.date(from: comps))

        let d15 = DailyUsage(
            dateString: "2026-11-15", day: 15, cost: 10.0, totalTokens: 1_000,
            models: [ModelUsage(id: "carbon", name: "Carbon", cost: 10.0, messages: 2, inputTokens: 800, outputTokens: 200)]
        )
        let d16 = DailyUsage(
            dateString: "2026-11-16", day: 16, cost: 4.0, totalTokens: 500,
            models: [ModelUsage(id: "carbon", name: "Carbon", cost: 4.0, messages: 1, inputTokens: 400, outputTokens: 100)]
        )
        let d18 = DailyUsage(
            dateString: "2026-11-18", day: 18, cost: 6.0, totalTokens: 900,
            models: [ModelUsage(id: "hydrogen", name: "Hydrogen", cost: 6.0, messages: 3, inputTokens: 700, outputTokens: 200)]
        )

        let today = AppDate.deriveToday([d15, d16, d18], now: wed)
        #expect(abs(today.cost - 6.0) < 1e-6)
        #expect(today.totalMessages == 3)

        let week = AppDate.deriveWeek([d15, d16, d18], now: wed)
        #expect(abs(week.cost - 10.0) < 1e-6)
        #expect(week.totalTokens == 1_400)
        #expect(week.models.map(\.id) == ["hydrogen", "carbon"])
    }

    @Test("parseISO8601 supports Go nanoseconds, offsets, and rejects 0001-01-01 sentinels")
    func parseISO8601AndSentinels() throws {
        #expect(AppDate.isSentinelTimestamp(nil) == true)
        #expect(AppDate.isSentinelTimestamp("") == true)
        #expect(AppDate.isSentinelTimestamp("0001-01-01T00:00:00Z") == true)
        #expect(AppDate.parseISO8601("0001-01-01T00:00:00Z") == nil)
        #expect(AppDate.parseISO8601("2026-02-30T10:00:00Z") == nil)

        // Plain UTC Z
        let d1 = try #require(AppDate.parseISO8601("2026-11-16T11:51:04Z"))
        // Equivalent +08:00 with 9 fractional digits (Go time.RFC3339Nano)
        let d2 = try #require(AppDate.parseISO8601("2026-11-16T19:51:04.500000000+08:00"))
        #expect(abs(d2.timeIntervalSince(d1) - 0.5) < 1e-6)

        // Negative half-hour offset (-05:30)
        let d3 = try #require(AppDate.parseISO8601("2026-11-16T06:21:04-05:30"))
        #expect(abs(d3.timeIntervalSince(d1)) < 1e-6)
    }
}
