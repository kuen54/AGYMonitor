import Foundation
import Testing
@testable import AGYCore

@Suite("Core_Telemetry")
struct TelemetryTests {

    @Test("ModelClass.shortCode returns 3-letter codes for all 7 tiers")
    func modelShortCodes() {
        #expect(ModelClass.carbon.shortCode == "CRB")
        #expect(ModelClass.argon.shortCode == "ARG")
        #expect(ModelClass.neon.shortCode == "NEO")
        #expect(ModelClass.hydrogen.shortCode == "HYD")
        #expect(ModelClass.flash.shortCode == "FLS")
        #expect(ModelClass.claude.shortCode == "CLD")
        #expect(ModelClass.other.shortCode == "OTH")
    }

    @Test("TimeLogic.yearSummary computes total, active days, and longest cross-month streak")
    func yearSummaryAndMonthColumns() {
        #expect(TimeLogic.yearSummary(days: [:], year: 2026) ==
            TimeLogic.YearTimeSummary(totalSeconds: 0, activeDays: 0, longestStreakDays: 0))

        let days: [String: Int] = [
            "2026-01-30": 3600,
            "2026-01-31": 1800,
            "2026-02-01": 7200,
            "2026-02-02": 1200,
            "2026-02-03": 0, // breaks streak
            "2026-03-10": 5400,
            "2026-03-11": 5400,
            "2025-12-31": 9999, // other year ignored
        ]
        let summary = TimeLogic.yearSummary(days: days, year: 2026)
        #expect(summary.totalSeconds == 3600 + 1800 + 7200 + 1200 + 5400 + 5400)
        #expect(summary.activeDays == 6)
        #expect(summary.longestStreakDays == 4)

        let cols = TimeLogic.monthLabelColumns(year: 2026)
        #expect(cols.count == 12)
        #expect(cols.first?.month == 1)
        #expect(cols.first?.col == 0)
        #expect(cols.last?.month == 12)
        #expect(cols.allSatisfy { (0..<53).contains($0.col) })
    }

    @Test("UsageTelemetryLogic computes cacheHitPercent, costDeltaPercent, and dailyAverage")
    func usageTelemetryHelpers() {
        #expect(UsageTelemetryLogic.cacheHitPercent(input: 0, cacheRead: 0) == nil)
        let hit = UsageTelemetryLogic.cacheHitPercent(input: 3_000_000, cacheRead: 20_500_000)
        #expect(hit != nil && abs(hit! - 87.234) < 0.05)

        let daily: [DailyUsage] = [
            DailyUsage(dateString: "2026-11-10", day: 10, cost: 10, totalTokens: 100, models: []),
            DailyUsage(dateString: "2026-11-11", day: 11, cost: 20, totalTokens: 200, models: []),
            DailyUsage(dateString: "2026-11-12", day: 12, cost: 0, totalTokens: 0, models: []),
            DailyUsage(dateString: "2026-11-13", day: 13, cost: 30, totalTokens: 300, models: []),
        ]
        // Avg prior to day 13 with cost > 0 is (10 + 20) / 2 = 15.0; today 30 -> +100%
        let delta = UsageTelemetryLogic.costDeltaPercent(todayCost: 30, daily: daily, todayDay: 13)
        #expect(delta != nil && abs(delta! - 100.0) < 0.001)
        #expect(UsageTelemetryLogic.costDeltaPercent(todayCost: 10, daily: daily, todayDay: 10) == nil)

        #expect(abs(UsageTelemetryLogic.dailyAverage(daily: daily, modeIsCost: true) - 20.0) < 0.001)
        #expect(abs(UsageTelemetryLogic.dailyAverage(daily: daily, modeIsCost: false) - 200.0) < 0.001)
    }

    @Test("QuotaPaceLogic detects over-pace burn, safe pace, and expired resets")
    func quotaPaceLogic() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Expired reset -> nil
        #expect(QuotaPaceLogic.compute(
            usedPercent: 20,
            resetAt: now.addingTimeInterval(-60),
            windowDurationSeconds: QuotaPaceLogic.fiveHourWindowSeconds,
            now: now
        ) == nil)

        // 7d window with 5d remaining -> elapsed 2/7 (~28.57%), expected remaining ~71.43%.
        // Used 60% -> paceDelta = +31%, actualRemaining = 0.40 (<0.70) -> over-pace warning!
        let over = try #require(QuotaPaceLogic.compute(
            usedPercent: 60,
            resetAt: now.addingTimeInterval(5 * 86400),
            windowDurationSeconds: QuotaPaceLogic.sevenDayWindowSeconds,
            now: now
        ))
        #expect(over.paceDeltaPercent >= 30)
        #expect(over.isOverPaceWarning == true)
        #expect(abs(over.expectedRemainingFraction - (5.0 / 7.0)) < 0.001)

        // Safe pace: 5h window with 1h remaining (elapsed 80%), used only 30% -> paceDelta = -50%
        let safe = try #require(QuotaPaceLogic.compute(
            usedPercent: 30,
            resetAt: now.addingTimeInterval(3600),
            windowDurationSeconds: QuotaPaceLogic.fiveHourWindowSeconds,
            now: now
        ))
        #expect(safe.paceDeltaPercent == -50)
        #expect(safe.isOverPaceWarning == false)
    }

    @Test("NotchLiveWingMachine persists Waiting, outranks Done, and auto-retracts Done after 5s")
    func notchLiveWingTransitions() {
        var state = NotchLiveWingState()
        let t0 = Date(timeIntervalSince1970: 10_000)

        let waiting = NotchWingSessionSnapshot(
            sessionId: "s-wait",
            workspace: "hyperframes",
            surface: "cli",
            isWaiting: true,
            needsConfirm: true,
            isDoneUnseen: false
        )
        let done = NotchWingSessionSnapshot(
            sessionId: "s-done",
            workspace: "AGYMonitor",
            surface: "ide",
            isWaiting: false,
            needsConfirm: false,
            isDoneUnseen: true
        )

        // Waiting wins over Done and holds without timer
        let e1 = NotchLiveWingMachine.reduce(&state, event: .sessionsUpdated([done, waiting], now: t0))
        #expect(e1 == [])
        #expect(state.activeWing == .waiting(sessionId: "s-wait", workspace: "hyperframes", surface: "cli", needsConfirm: true))

        // Dismiss waiting -> suppresses s-wait while still waiting
        let e2 = NotchLiveWingMachine.reduce(&state, event: .dismissed(sessionId: "s-wait"))
        #expect(e2 == [])
        #expect(state.activeWing == nil)

        // Fresh done triggers 5s auto-retract while dismissed waiting stays quiet
        let e3 = NotchLiveWingMachine.reduce(&state, event: .sessionsUpdated([done, waiting], now: t0.addingTimeInterval(1)))
        #expect(e3 == [.scheduleDoneRetract(after: 5.0)])
        #expect(state.activeWing == .done(sessionId: "s-done", workspace: "AGYMonitor", surface: "ide"))

        // Early tick before 5s does not retract
        let eEarly = NotchLiveWingMachine.reduce(&state, event: .doneTimerFired(now: t0.addingTimeInterval(4)))
        #expect(eEarly == [])
        #expect(state.activeWing != nil)

        // Timer at t0 + 6 retracts Done cleanly
        let e4 = NotchLiveWingMachine.reduce(&state, event: .doneTimerFired(now: t0.addingTimeInterval(6)))
        #expect(e4 == [.cancelDoneRetract])
        #expect(state.activeWing == nil)

        // Same doneUnseen id does NOT re-pop
        let e5 = NotchLiveWingMachine.reduce(&state, event: .sessionsUpdated([done], now: t0.addingTimeInterval(7)))
        #expect(e5 == [])
        #expect(state.activeWing == nil)

        // Once s-wait stops waiting and then waits again, it re-arms
        let notWaiting = NotchWingSessionSnapshot(
            sessionId: "s-wait",
            workspace: "hyperframes",
            surface: "cli",
            isWaiting: false,
            needsConfirm: false,
            isDoneUnseen: false
        )
        let eClear = NotchLiveWingMachine.reduce(&state, event: .sessionsUpdated([notWaiting], now: t0.addingTimeInterval(7.5)))
        #expect(eClear == [])
        #expect(state.dismissedWaitingIds.isEmpty)

        let e6 = NotchLiveWingMachine.reduce(&state, event: .sessionsUpdated([waiting], now: t0.addingTimeInterval(8)))
        #expect(e6 == [])
        #expect(state.activeWing == .waiting(sessionId: "s-wait", workspace: "hyperframes", surface: "cli", needsConfirm: true))
    }

    @Test("SessionNavLogic wraps cleanly up and down")
    func sessionNavMovement() {
        #expect(SessionNavLogic.moveSelection(currentId: nil, orderedIds: [], delta: 1) == nil)
        let ids = ["a", "b", "c"]
        #expect(SessionNavLogic.moveSelection(currentId: nil, orderedIds: ids, delta: 1) == "a")
        #expect(SessionNavLogic.moveSelection(currentId: nil, orderedIds: ids, delta: -1) == "c")
        #expect(SessionNavLogic.moveSelection(currentId: "a", orderedIds: ids, delta: -1) == "c")
        #expect(SessionNavLogic.moveSelection(currentId: "c", orderedIds: ids, delta: 1) == "a")
        #expect(SessionNavLogic.moveSelection(currentId: "b", orderedIds: ids, delta: 1) == "c")
    }

    @Test("MenuBarAnchorState.shouldPublishMenuBarValue honors all MenuBarMetricPreference cases")
    func menuBarMetricPublishMatrix() {
        #expect(MenuBarAnchorState.shouldPublishMenuBarValue(
            metric: .todayCost, tabRawValue: 0, hasTodayData: true, hasCurrentMonthData: false, hasSubscriptionQuota: false
        ) == true)
        #expect(MenuBarAnchorState.shouldPublishMenuBarValue(
            metric: .todayCost, tabRawValue: 0, hasTodayData: false, hasCurrentMonthData: false, hasSubscriptionQuota: true
        ) == false)
        #expect(MenuBarAnchorState.shouldPublishMenuBarValue(
            metric: .quota5h, tabRawValue: 0, hasTodayData: false, hasCurrentMonthData: false, hasSubscriptionQuota: true
        ) == true)
        #expect(MenuBarAnchorState.shouldPublishMenuBarValue(
            metric: .quota5h, tabRawValue: 0, hasTodayData: true, hasCurrentMonthData: true, hasSubscriptionQuota: false
        ) == false)
        #expect(MenuBarAnchorState.shouldPublishMenuBarValue(
            metric: .liveSessions, tabRawValue: 0, hasTodayData: false, hasCurrentMonthData: false, hasSubscriptionQuota: false
        ) == true)
        #expect(MenuBarAnchorState.shouldPublishMenuBarValue(
            metric: .costAndQuota, tabRawValue: 0, hasTodayData: false, hasCurrentMonthData: false, hasSubscriptionQuota: true
        ) == true)
    }

    @Test("TelemetryThemePreset cycles deterministically and identifies monochrome strata presets")
    func themePresetCycleAndStrata() {
        #expect(TelemetryThemePreset.allCases == [
            .monolith,
            .blueprint,
            .risograph,
            .amber,
            .racing,
            .volt,
        ])
        #expect(TelemetryThemePreset.allCases.count == 6)

        #expect(TelemetryThemePreset.monolith.next == .blueprint)
        #expect(TelemetryThemePreset.blueprint.next == .risograph)
        #expect(TelemetryThemePreset.risograph.next == .amber)
        #expect(TelemetryThemePreset.amber.next == .racing)
        #expect(TelemetryThemePreset.racing.next == .volt)
        #expect(TelemetryThemePreset.volt.next == .monolith)

        // Full cycle from .monolith visits all 6 distinct presets and wraps back to .monolith
        var cursor: TelemetryThemePreset = .monolith
        var visited: [TelemetryThemePreset] = []
        for _ in 0..<TelemetryThemePreset.allCases.count {
            visited.append(cursor)
            cursor = cursor.next
        }
        #expect(visited == TelemetryThemePreset.allCases)
        #expect(cursor == .monolith)

        #expect(TelemetryThemePreset.monolith.usesMonochromeStrata == true)
        #expect(TelemetryThemePreset.blueprint.usesMonochromeStrata == false)
        #expect(TelemetryThemePreset.risograph.usesMonochromeStrata == false)
        #expect(TelemetryThemePreset.amber.usesMonochromeStrata == false)
        #expect(TelemetryThemePreset.racing.usesMonochromeStrata == false)
        #expect(TelemetryThemePreset.volt.usesMonochromeStrata == false)
    }

    @Test("SessionFilterLogic.nonWaitingGroups deduplicates waiting sessions cleanly")
    func nonWaitingDeduplication() {
        let s1 = SessionInfo(pid: 1, sessionId: "wait-1", cwd: "/tmp/a", status: .waiting)
        let s2 = SessionInfo(pid: 2, sessionId: "busy-1", cwd: "/tmp/a", status: .busy)
        let s3 = SessionInfo(pid: 3, sessionId: "wait-only", cwd: "/tmp/b", status: .waiting)
        let groups = [
            SessionGroup(cwd: "/tmp/a", label: "a", sessions: [s1, s2]),
            SessionGroup(cwd: "/tmp/b", label: "b", sessions: [s3]),
        ]
        let stripped = SessionFilterLogic.nonWaitingGroups(from: groups)
        #expect(stripped.count == 1)
        #expect(stripped[0].label == "a")
        #expect(stripped[0].sessions.map(\.sessionId) == ["busy-1"])
    }
}
