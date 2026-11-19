import Foundation
import Testing
@testable import AGYCore

@Suite("Core_UsageState")
struct UsageStateTests {

    private func samplePeriod(cost: Double, tokens: Int = 1000, messages: Int = 2) -> PeriodUsage {
        PeriodUsage(
            cost: cost,
            models: [ModelUsage(id: "carbon", name: "Carbon", cost: cost, messages: messages, inputTokens: tokens, outputTokens: 0)],
            totalMessages: messages,
            totalTokens: tokens
        )
    }

    @Test("RefreshQueueState queues force refresh during in-flight scan and coalesces non-force")
    func refreshQueueBehavior() {
        var q = RefreshQueueState()

        let r1 = q.request(force: false)
        #expect(r1.shouldStartNow == true)
        #expect(r1.effectiveForce == false)
        #expect(q.isInFlight)

        // Duplicate non-forced refresh coalesces cleanly
        let r2 = q.request(force: false)
        #expect(r2.shouldStartNow == false)
        #expect(!q.pendingFollowUp)

        // Manual ⌘R while background scan is running MUST NOT be dropped
        let r3 = q.request(force: true)
        #expect(r3.shouldStartNow == false)
        #expect(q.pendingFollowUp)
        #expect(q.pendingForce)

        // Completing active scan schedules the forced follow-up
        let c1 = q.complete()
        #expect(c1.shouldRunFollowUp == true)
        #expect(c1.followUpForce == true)
        #expect(q.isInFlight)

        // Completing follow-up leaves queue idle
        let c2 = q.complete()
        #expect(c2.shouldRunFollowUp == false)
        #expect(!q.isInFlight)
    }

    @Test("MonthNavigationState auto-advances at midnight month rollover only when following current month")
    func monthNavigationAndRollover() throws {
        let nov30 = try #require(AppDate.parseISO8601("2026-11-30T10:00:00Z"))
        let dec01 = try #require(AppDate.parseISO8601("2026-12-01T10:00:00Z"))

        var nav = MonthNavigationState(now: nov30)
        #expect(nav.yearMonthKey == "2026-11")
        #expect(nav.followingCurrentMonth == true)

        // Midnight rollover to Dec 1 auto-advances when following current month
        #expect(nav.syncClock(now: dec01) == true)
        #expect(nav.yearMonthKey == "2026-12")

        // Navigate back to October 2026 (historical browsing)
        nav.navigate(offset: -2, now: dec01)
        #expect(nav.yearMonthKey == "2026-10")
        #expect(nav.followingCurrentMonth == false)

        // Clock advancing to Jan does NOT rip user away from October historical month
        let jan01 = try #require(AppDate.parseISO8601("2027-01-01T10:00:00Z"))
        #expect(nav.syncClock(now: jan01) == false)
        #expect(nav.yearMonthKey == "2026-10")

        // Navigate forward to Jan 2027 re-engages followingCurrentMonth
        nav.navigate(offset: 3, now: jan01)
        #expect(nav.yearMonthKey == "2027-01")
        #expect(nav.followingCurrentMonth == true)
    }

    @Test("YearLoadGate deduplicates overlapping same-year requests unless forced")
    func yearLoadGateDeduplication() {
        var gate = YearLoadGate()
        let g1 = gate.beginLoad(year: 2026, force: false, hasCachedValue: false)
        #expect(g1 == 1)

        // Second non-forced request for same active year is suppressed (didSet + onAppear bug)
        #expect(gate.beginLoad(year: 2026, force: false, hasCachedValue: false) == nil)

        // Cached value skips non-forced load
        gate.completeLoad(generation: 1)
        #expect(gate.beginLoad(year: 2026, force: false, hasCachedValue: true) == nil)

        // Force reload always gets a new generation
        let g2 = gate.beginLoad(year: 2026, force: true, hasCachedValue: true)
        #expect(g2 == 2)
    }

    @Test("ArchiveSweepGate does not lock out retries after failed script execution")
    func archiveSweepGateFailureRetry() {
        var gate = ArchiveSweepGate(minInterval: 3600)
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        #expect(gate.shouldStart(force: false, enabled: true, now: t0) == true)
        #expect(gate.shouldStart(force: false, enabled: true, now: t0) == false) // in-flight guard

        // Failed sweep clears in-flight WITHOUT recording lastSucceededAt
        gate.finish(succeeded: false, now: t0)
        #expect(gate.lastSucceededAt == nil)
        #expect(gate.shouldStart(force: false, enabled: true, now: t0.addingTimeInterval(5)) == true)

        // Succeeded sweep enforces 6h cooldown unless forced
        gate.finish(succeeded: true, now: t0.addingTimeInterval(10))
        #expect(gate.shouldStart(force: false, enabled: true, now: t0.addingTimeInterval(100)) == false)
        #expect(gate.shouldStart(force: true, enabled: true, now: t0.addingTimeInterval(100)) == true)
    }

    @Test("UsageStateLogic distinguishes script failure from empty historical months and preserves caches")
    func classificationDistinguishesFailureAndEmpty() {
        let zeroPeriod = PeriodUsage(cost: 0, models: [], totalMessages: 0, totalTokens: 0)
        let nonemptyPeriod = samplePeriod(cost: 12.5)
        let cachedHist = HistoricalMonthBundle(month: nonemptyPeriod, dailyBreakdown: nil, time: nil)

        // Historical script failure yields .failed(.scriptFailed), NOT .empty!
        let histFail = UsageStateLogic.classifyHistoricalMonth(
            month: nil, dailyBreakdown: nil, time: nil, scriptSucceeded: false, cached: nil
        )
        #expect(histFail == .failed(.scriptFailed, cached: nil))
        #expect(histFail.hasFailedWithoutValue)

        // Historical script failure preserves cached data if available
        let histFailCached = UsageStateLogic.classifyHistoricalMonth(
            month: nil, dailyBreakdown: nil, time: nil, scriptSucceeded: false, cached: cachedHist
        )
        #expect(histFailCached == .failed(.scriptFailed, cached: cachedHist))
        #expect(histFailCached.value == cachedHist)
        #expect(!histFailCached.hasFailedWithoutValue)

        // Historical script success with zero usage yields .empty
        let histEmpty = UsageStateLogic.classifyHistoricalMonth(
            month: zeroPeriod, dailyBreakdown: nil, time: nil, scriptSucceeded: true, cached: nil
        )
        #expect(histEmpty == .empty)

        // Current month script failure yields .failed preserving cached bundle
        let curFail = UsageStateLogic.classifyCurrentMonth(
            today: nil, week: nil, month: nil, dailyBreakdown: nil, time: nil, scriptSucceeded: false, cached: nil
        )
        #expect(curFail == .failed(.scriptFailed, cached: nil))
    }

    @Test("HistoricalMonthLoadGate deduplicates overlapping month fetches and rejects stale completions")
    func historicalMonthLoadGateBehavior() {
        var gate = HistoricalMonthLoadGate()

        let g1 = gate.beginLoad(yearMonth: "2026-10", force: false)
        #expect(g1 == 1)
        #expect(gate.activeYearMonth == "2026-10")

        // Duplicate non-forced fetch for same month deduplicates cleanly
        #expect(gate.beginLoad(yearMonth: "2026-10", force: false) == nil)

        // Forced reload or navigating to a new month advances generation
        let g2 = gate.beginLoad(yearMonth: "2026-09", force: false)
        #expect(g2 == 2)
        #expect(!gate.isCurrent(generation: 1, yearMonth: "2026-10", currentYearMonth: "2026-09"))
        #expect(gate.isCurrent(generation: 2, yearMonth: "2026-09", currentYearMonth: "2026-09"))

        // Invalidating (e.g. navigating back to current month) rejects in-flight g2
        gate.invalidate()
        #expect(gate.activeYearMonth == nil)
        #expect(!gate.isCurrent(generation: 2, yearMonth: "2026-09", currentYearMonth: "2026-09"))
    }
}
