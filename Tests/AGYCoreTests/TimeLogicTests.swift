import Foundation
import Testing
@testable import AGYCore

@Suite("Core_TimeLogic")
struct TimeLogicTests {

    @Test("formatDurationShort and formatClock handle edge boundaries")
    func durationAndClockFormatting() {
        #expect(TimeLogic.formatDurationShort(0) == "0min")
        #expect(TimeLogic.formatDurationShort(-10) == "0min")
        #expect(TimeLogic.formatDurationShort(15) == "1min")
        #expect(TimeLogic.formatDurationShort(1_920) == "32min")
        #expect(TimeLogic.formatDurationShort(3_600) == "1.0hr")
        #expect(TimeLogic.formatDurationShort(12_240) == "3.4hr")

        #expect(TimeLogic.formatClock(0) == "00:00")
        #expect(TimeLogic.formatClock(3_660) == "01:01")
        #expect(TimeLogic.formatClock(86_400) == "24:00")
    }

    @Test("heatLevel maps active seconds into 5 buckets (0..4)")
    func heatLevels() {
        #expect(TimeLogic.heatLevel(0) == 0)
        #expect(TimeLogic.heatLevel(1) == 1)
        #expect(TimeLogic.heatLevel(3_599) == 1)
        #expect(TimeLogic.heatLevel(3_600) == 2)
        #expect(TimeLogic.heatLevel(10_800) == 3)
        #expect(TimeLogic.heatLevel(21_600) == 4)
    }

    @Test("Week navigation, renderedDayKeys, and avgDivisor behave deterministically")
    func weekCalculations() throws {
        let weeks = TimeLogic.weeksOfMonth(year: 2026, month: 11)
        #expect(!weeks.isEmpty)
        let firstKeys = TimeLogic.weekDayKeys(monday: weeks[0])
        #expect(firstKeys.count == 7)
        #expect(firstKeys.contains("2026-11-01"))

        let idx = TimeLogic.weekIndex(of: weeks[1], in: weeks)
        #expect(idx == 1)

        // Mid-week Tuesday -> divisor is 2 (Mon + Tue)
        let sampleKeys = ["2026-11-16", "2026-11-17", "2026-11-18", "2026-11-19", "2026-11-20", "2026-11-21", "2026-11-22"]
        #expect(TimeLogic.avgDivisor(dayKeys: sampleKeys, todayKey: "2026-11-17", renderedCount: 7) == 2)
        // Past week -> renderedCount
        #expect(TimeLogic.avgDivisor(dayKeys: sampleKeys, todayKey: "2026-11-30", renderedCount: 5) == 5)
        // Future week -> 1
        #expect(TimeLogic.avgDivisor(dayKeys: sampleKeys, todayKey: "2026-11-10", renderedCount: 7) == 1)
    }

    @Test("53x7 Monday-first year grid round-trips day keys cleanly")
    func yearGridRoundTrip() throws {
        let startMonday = try #require(TimeLogic.yearGridStartMonday(year: 2026))
        let pos = try #require(TimeLogic.gridPosition(dayKey: "2026-11-16", startMonday: startMonday))
        #expect(pos.row == 0) // 2026-11-16 is a Monday -> row 0
        #expect(pos.col >= 0 && pos.col < 53)

        let roundTripped = TimeLogic.dayKey(col: pos.col, row: pos.row, startMonday: startMonday)
        #expect(roundTripped == "2026-11-16")

        // Invalid & sentinel keys rejected
        #expect(TimeLogic.date(fromDayKey: "0001-01-01") == nil)
        #expect(TimeLogic.date(fromDayKey: "2026-02-29") == nil)
    }
}
