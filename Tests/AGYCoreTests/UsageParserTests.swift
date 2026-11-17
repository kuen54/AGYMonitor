import Foundation
import Testing
@testable import AGYCore

@Suite("Core_UsageParser")
struct UsageParserTests {

    @Test("parsePeriod decodes canonical and raw model keys in ModelClass order")
    func parsePeriodAndNormalizeKeys() throws {
        let json: [String: Any] = [
            "grand_total_cost": 14.75,
            "totals_by_model": [
                "gemini-4-carbon-medium": [
                    "input_tokens": 5_000,
                    "output_tokens": 1_000,
                    "cache_read": 20_000,
                    "cache_write": 0,
                    "messages": 3,
                    "cost": 8.25,
                ],
                "hydrogen": [
                    "input_tokens": 2_000,
                    "output_tokens": 500,
                    "cache_read": 10_000,
                    "cache_write": 500,
                    "messages": 1,
                    "cost": 4.50,
                ],
                "claude-opus-5-5-high": [
                    "input_tokens": 1_000,
                    "output_tokens": 400,
                    "cache_read": 0,
                    "cache_write": 0,
                    "messages": 2,
                    "cost": 2.00,
                ],
            ]
        ]

        let period = try #require(UsageParser.parsePeriod(json))
        #expect(abs(period.cost - 14.75) < 1e-6)
        #expect(period.totalMessages == 6)
        #expect(period.totalTokens == 40_400)
        #expect(period.models.map(\.id) == ["hydrogen", "carbon", "claude"])

        // Also verify real JSONSerialization (NSNumber-backed) dictionary round-trip
        let wireData = try JSONSerialization.data(withJSONObject: json)
        let wireDict = try #require(JSONSerialization.jsonObject(with: wireData) as? [String: Any])
        let wirePeriod = try #require(UsageParser.parsePeriod(wireDict))
        #expect(wirePeriod == period)
    }

    @Test("parseDailyBreakdown filters by yearMonth and skips 0001-01-01 sentinel dates")
    func parseDailyBreakdownSkipsSentinels() throws {
        let json: [String: Any] = [
            "daily_breakdown": [
                "0001-01-01": [
                    "total_cost": 99.0,
                    "models": ["carbon": ["input_tokens": 100, "output_tokens": 10, "cache_read": 0, "cache_write": 0, "messages": 1, "cost": 99.0]]
                ],
                "2026-10-31": [
                    "total_cost": 1.0,
                    "models": ["flash": ["input_tokens": 500, "output_tokens": 100, "cache_read": 0, "cache_write": 0, "messages": 1, "cost": 1.0]]
                ],
                "2026-11-16": [
                    "total_cost": 3.5,
                    "models": ["argon": ["input_tokens": 2_000, "output_tokens": 300, "cache_read": 4_000, "cache_write": 0, "messages": 4, "cost": 3.5]]
                ],
            ]
        ]

        let nov = try #require(UsageParser.parseDailyBreakdown(json, yearMonth: "2026-11"))
        #expect(nov.count == 1)
        #expect(nov[0].dateString == "2026-11-16")
        #expect(nov[0].day == 16)
        #expect(nov[0].totalTokens == 6_300)

        let all = try #require(UsageParser.parseAllDailyBreakdown(json))
        #expect(all.map(\.dateString) == ["2026-10-31", "2026-11-16"])

        let merged = UsageParser.mergeDailyUsages(all)
        #expect(abs(merged.cost - 4.5) < 1e-6)
        #expect(merged.totalMessages == 5)
        #expect(merged.models.map(\.id) == ["argon", "flash"])
    }

    @Test("parseTimeSection, parseYearTime, and mergeTimeData handle model normalization and bounds")
    func parseAndMergeTime() throws {
        let baseJSON: [String: Any] = [
            "time": [
                "gap_minutes": 10,
                "days": [
                    "0001-01-01": ["intervals": [[0, 600, "carbon"]], "total_seconds": 600],
                    "2026-11-16": [
                        "intervals": [
                            [3600, 7200, "gemini-pro-orchestrator-argon"],
                            [8000, 8000],
                            [-5, 100, "carbon"], // invalid start < 0 -> skipped
                        ],
                        "total_seconds": 3600,
                    ]
                ]
            ]
        ]

        let base = try #require(UsageParser.parseTimeSection(baseJSON))
        #expect(base.gapMinutes == 10)
        #expect(base.days["0001-01-01"] == nil)
        let day16 = try #require(base.days["2026-11-16"])
        #expect(day16.intervals.count == 2)
        #expect(day16.intervals[0].model == "argon")
        #expect(day16.intervals[1].model == nil)

        let override = TimeData(gapMinutes: 10, days: [
            "2026-11-16": DayTimeUsage(intervals: [ActiveInterval(startSec: 0, endSec: 7200, model: "carbon")], totalSeconds: 7200),
            "2026-10-31": DayTimeUsage(intervals: [ActiveInterval(startSec: 82800, endSec: 86400, model: "carbon")], totalSeconds: 3600),
        ])
        let merged = try #require(UsageParser.mergeTimeData(base: base, override: override))
        #expect(merged.days["2026-11-16"]?.totalSeconds == 7200)
        #expect(merged.days["2026-10-31"]?.totalSeconds == 3600)

        let yearJSON: [String: Any] = [
            "year": 2026,
            "gap_minutes": 10,
            "days": [
                "2026-11-16": 5400,
                "2026-11-17": 1,
                "2026-11-18": 0,
                "2026-11-19": true,
                "0001-01-01": 900,
                "2026-11-15": "invalid",
            ]
        ]
        let yearWire = try JSONSerialization.data(withJSONObject: yearJSON)
        let yearWireDict = try #require(JSONSerialization.jsonObject(with: yearWire) as? [String: Any])
        let yearParsed = try #require(UsageParser.parseYearTime(yearWireDict))
        #expect(yearParsed.year == 2026)
        #expect(yearParsed.gapMinutes == 10)
        #expect(yearParsed.days == ["2026-11-16": 5400, "2026-11-17": 1, "2026-11-18": 0])
    }
}
