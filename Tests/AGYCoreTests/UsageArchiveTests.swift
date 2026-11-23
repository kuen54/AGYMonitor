import Foundation
import Testing
@testable import AGYCore

@Suite("Core_UsageArchive")
struct UsageArchiveTests {

    @Test("Monotonic mergeDay never lowers archived tokens or costs after transcript cleanup")
    func monotonicTokenMerge() {
        var archive = UsageArchiveData()

        let fullDay = DailyUsage(
            dateString: "2026-11-10",
            day: 10,
            cost: 12.5,
            totalTokens: 50_000,
            models: [
                ModelUsage(id: "carbon", name: "Carbon", cost: 10.0, messages: 8, inputTokens: 10_000, outputTokens: 2_000, cacheRead: 28_000),
                ModelUsage(id: "claude", name: "Claude", cost: 2.5, messages: 2, inputTokens: 4_000, outputTokens: 1_000, cacheRead: 5_000),
            ]
        )
        let changed1 = UsageArchiveLogic.mergeDaily([fullDay], into: &archive)
        #expect(changed1 == ["2026-11-10"])

        // Simulate partial post-cleanup scan with fewer tokens: MUST NOT regress!
        let partialDay = DailyUsage(
            dateString: "2026-11-10",
            day: 10,
            cost: 3.0,
            totalTokens: 8_000,
            models: [
                ModelUsage(id: "carbon", name: "Carbon", cost: 3.0, messages: 2, inputTokens: 3_000, outputTokens: 500, cacheRead: 4_500),
            ]
        )
        let changed2 = UsageArchiveLogic.mergeDaily([partialDay], into: &archive)
        #expect(changed2.isEmpty)

        let reconstructed = UsageArchiveLogic.dailyBreakdown(archive, yearMonth: "2026-11")
        #expect(reconstructed.count == 1)
        #expect(reconstructed[0].totalTokens == 50_000)
        #expect(abs(reconstructed[0].cost - 12.5) < 1e-6)
        #expect(reconstructed[0].models.map(\.id) == ["carbon", "claude"])
    }

    @Test("Active time and year-seconds merges are monotonic and preserve interval detail")
    func monotonicTimeMerge() {
        var archive = UsageArchiveData()

        let td = TimeData(gapMinutes: 10, days: [
            "2026-11-16": DayTimeUsage(
                intervals: [ActiveInterval(startSec: 3600, endSec: 7200, model: "carbon")],
                totalSeconds: 3600
            ),
            "0001-01-01": DayTimeUsage(intervals: [], totalSeconds: 500),
        ])
        let changedTime = UsageArchiveLogic.mergeTime(td, into: &archive)
        #expect(changedTime == ["2026-11-16"])
        #expect(archive.days["0001-01-01"] == nil)

        // Smaller year-seconds does not lower stored seconds; larger bumps seconds while keeping intervals
        let unchanged = UsageArchiveLogic.mergeYearSeconds(["2026-11-16": 1200], into: &archive)
        #expect(unchanged.isEmpty)

        let bumped = UsageArchiveLogic.mergeYearSeconds(["2026-11-16": 5400, "2026-11-15": 1800], into: &archive)
        #expect(bumped == ["2026-11-16", "2026-11-15"])

        let timeOverlay = UsageArchiveLogic.timeDays(archive, yearMonth: "2026-11")
        #expect(timeOverlay["2026-11-16"]?.totalSeconds == 5400)
        #expect(timeOverlay["2026-11-16"]?.intervals.count == 1)
        #expect(timeOverlay["2026-11-15"]?.totalSeconds == 1800)
        #expect(timeOverlay["2026-11-15"]?.intervals.isEmpty == true)

        let yearSecs = UsageArchiveLogic.yearSeconds(archive, year: 2026)
        #expect(yearSecs == ["2026-11-16": 5400, "2026-11-15": 1800])
    }

    @Test("UsageArchiveLogic rejects 'unknown' and malformed day keys on merge and read")
    func rejectsMalformedDayKeys() {
        var archive = UsageArchiveData()

        let bogusModel = ModelUsage(id: "carbon", name: "Carbon", cost: 1.0, messages: 1, inputTokens: 100, outputTokens: 20)
        let bogusDays = [
            DailyUsage(dateString: "unknown", day: 1, cost: 1.0, totalTokens: 120, models: [bogusModel]),
            DailyUsage(dateString: "../2026-11", day: 1, cost: 1.0, totalTokens: 120, models: [bogusModel]),
            DailyUsage(dateString: "2026-02-30", day: 30, cost: 1.0, totalTokens: 120, models: [bogusModel]),
            DailyUsage(dateString: "2026-11-05", day: 5, cost: 1.0, totalTokens: 120, models: [bogusModel]),
        ]
        let changed = UsageArchiveLogic.mergeDaily(bogusDays, into: &archive)
        #expect(changed == ["2026-11-05"])
        #expect(Array(archive.days.keys) == ["2026-11-05"])

        let td = TimeData(gapMinutes: 10, days: [
            "unknown": DayTimeUsage(intervals: [], totalSeconds: 120),
            "2026-11-31": DayTimeUsage(intervals: [], totalSeconds: 120),
            "2026-11-05": DayTimeUsage(intervals: [], totalSeconds: 120),
        ])
        #expect(UsageArchiveLogic.mergeTime(td, into: &archive) == ["2026-11-05"])
        #expect(UsageArchiveLogic.mergeYearSeconds(["unknown": 500, "9999-01-01": 500], into: &archive).isEmpty)

        // Even if corrupted keys were injected directly into UsageArchiveData, reads filter them out
        archive.days["unknown"] = ArchivedDay(models: ["carbon": ArchivedModel(inputTokens: 10, outputTokens: 10, cacheRead: 0, cacheWrite: 0, messages: 1, cost: 0.1)], timeSeconds: 300)
        archive.days["2026-11-xx"] = ArchivedDay(models: ["carbon": ArchivedModel(inputTokens: 10, outputTokens: 10, cacheRead: 0, cacheWrite: 0, messages: 1, cost: 0.1)], timeSeconds: 300)
        #expect(UsageArchiveLogic.dailyBreakdown(archive, yearMonth: "2026-11").map(\.dateString) == ["2026-11-05"])
        #expect(UsageArchiveLogic.dailyBreakdown(archive, yearMonth: "unknown").isEmpty)
        #expect(Array(UsageArchiveLogic.timeDays(archive, yearMonth: "2026-11").keys) == ["2026-11-05"])
        #expect(UsageArchiveLogic.yearSeconds(archive, year: 2026) == ["2026-11-05": 120])
        #expect(UsageArchiveLogic.yearSeconds(archive, year: 9999).isEmpty)
    }
}
