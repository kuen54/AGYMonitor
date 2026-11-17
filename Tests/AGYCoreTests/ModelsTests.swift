import Foundation
import Testing
@testable import AGYCore

@Suite("Core_Models")
struct ModelsTests {

    @Test("ModelUsage computes totalTokens across all four token counters")
    func modelUsageTotalTokens() {
        let m = ModelUsage(
            id: "carbon",
            name: "Carbon",
            cost: 1.25,
            messages: 4,
            inputTokens: 10_000,
            outputTokens: 2_500,
            cacheRead: 40_000,
            cacheWrite: 1_500
        )
        #expect(m.totalTokens == 54_000)
        #expect(m.id == "carbon")
    }

    @Test("PeriodUsage aggregates per-type token totals")
    func periodUsageTotals() {
        let a = ModelUsage(
            id: "hydrogen", name: "Hydrogen", cost: 3.0, messages: 2,
            inputTokens: 1_000, outputTokens: 500, cacheRead: 2_000, cacheWrite: 100
        )
        let b = ModelUsage(
            id: "claude", name: "Claude", cost: 2.0, messages: 3,
            inputTokens: 4_000, outputTokens: 800, cacheRead: 6_000, cacheWrite: 0
        )
        let p = PeriodUsage(cost: 5.0, models: [a, b], totalMessages: 5, totalTokens: a.totalTokens + b.totalTokens)
        #expect(p.totalInput == 5_000)
        #expect(p.totalOutput == 1_300)
        #expect(p.totalCacheRead == 8_000)
        #expect(p.totalCacheWrite == 100)
    }

    @Test("ActiveInterval encodes and decodes compact [start, end, model] array and 2-element legacy array")
    func activeIntervalCompactCodable() throws {
        let interval = ActiveInterval(startSec: 3_600, endSec: 7_200, model: "carbon")
        #expect(interval.durationSeconds == 3_600)

        let encoded = try JSONEncoder().encode(interval)
        let jsonStr = String(decoding: encoded, as: UTF8.self)
        #expect(jsonStr == "[3600,7200,\"carbon\"]")

        let decoded = try JSONDecoder().decode(ActiveInterval.self, from: encoded)
        #expect(decoded == interval)

        // Two-element array (no model element) decodes with model == nil
        let pairData = Data("[1200,86400]".utf8)
        let decodedPair = try JSONDecoder().decode(ActiveInterval.self, from: pairData)
        #expect(decodedPair.startSec == 1_200)
        #expect(decodedPair.endSec == 86_400)
        #expect(decodedPair.model == nil)
        #expect(decodedPair.durationSeconds == 85_200)
    }

    @Test("MonthlySnapshot preserves optional fields across Codable round-trip")
    func monthlySnapshotCodable() throws {
        let now = Date(timeIntervalSince1970: 1_794_830_000)
        let mu = ModelUsage(id: "flash", name: "Flash", cost: 0.42, messages: 10, inputTokens: 5_000, outputTokens: 1_000)
        let period = PeriodUsage(cost: 0.42, models: [mu], totalMessages: 10, totalTokens: 6_000)
        let day = DailyUsage(dateString: "2026-11-16", day: 16, cost: 0.42, totalTokens: 6_000, models: [mu])
        let td = TimeData(gapMinutes: 10, days: [
            "2026-11-16": DayTimeUsage(intervals: [ActiveInterval(startSec: 600, endSec: 1_800, model: "flash")], totalSeconds: 1_200)
        ])

        let snap = MonthlySnapshot(
            year: 2026,
            month: 11,
            data: period,
            lastUpdated: now,
            dailyBreakdown: [day],
            week: period,
            weekStart: "2026-11-16",
            time: td
        )
        let encoded = try #require(UsageParser.encodeSnapshot(snap))
        let restored = try #require(UsageParser.decodeSnapshot(encoded))
        #expect(restored == snap)
        #expect(restored.dailyBreakdown?.first?.id == "2026-11-16")
    }
}
