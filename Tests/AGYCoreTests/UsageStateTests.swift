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

    @Test("SnapshotFreshnessPolicy rejects partial mid-month snapshots and clamps year bounds")
    func snapshotFreshnessAndYearClamping() throws {
        let oct15 = try #require(AppDate.parseISO8601("2026-10-15T12:00:00Z"))
        let nov02 = try #require(AppDate.parseISO8601("2026-11-02T09:00:00Z"))

        // Snapshot saved Oct 15 is incomplete when viewing October in November!
        #expect(!SnapshotFreshnessPolicy.isCompleteHistoricalSnapshot(year: 2026, month: 10, lastUpdated: oct15))
        // Snapshot saved Nov 2 (after Oct ended) is complete!
        #expect(SnapshotFreshnessPolicy.isCompleteHistoricalSnapshot(year: 2026, month: 10, lastUpdated: nov02))

        #expect(SnapshotFreshnessPolicy.clampedYear(2035, now: nov02) == 2026)
        #expect(SnapshotFreshnessPolicy.clampedYear(1900, now: nov02) == 1970)
        #expect(SnapshotFreshnessPolicy.clampedYear(2025, now: nov02) == 2025)
    }

    @Test("YearLoadGate switching to cached year cancels activeYear so bouncing back starts a fresh load")
    func yearLoadGateBounceFix() {
        var gate = YearLoadGate()
        // 2026 (cached) -> 2025 (uncached, gen 1) -> 2026 (cached, cancels activeYear) -> 2025 (uncached, gen 3)
        #expect(gate.beginLoad(year: 2025, force: false, hasCachedValue: false) == 1)
        #expect(gate.beginLoad(year: 2026, force: false, hasCachedValue: true) == nil)
        #expect(gate.activeYear == nil)
        let g3 = gate.beginLoad(year: 2025, force: false, hasCachedValue: false)
        #expect(g3 == 3)
        #expect(gate.activeYear == 2025)
    }

    @Test("ArchiveSweepGate reset invalidates in-flight sweep so clearArchive cannot be resurrected")
    func archiveSweepGateResetRejectsStaleCompletion() {
        var gate = ArchiveSweepGate(minInterval: 3600)
        let t0 = Date(timeIntervalSince1970: 500_000)

        let gen = gate.beginSweep(force: false, enabled: true, now: t0)
        #expect(gen == 1)

        // User clicks Clear Archive while sweep is in flight
        gate.reset()
        #expect(!gate.isInFlight)
        #expect(gate.lastSucceededAt == nil)

        // Stale sweep gen 1 finishing MUST return false and NOT record lastSucceededAt!
        let staleApplied = gate.finish(generation: 1, succeeded: true, now: t0.addingTimeInterval(5))
        #expect(!staleApplied)
        #expect(gate.lastSucceededAt == nil)
    }

    @Test("RefreshQueueState suppresses intermediate .loaded flash when forced follow-up is pending and exposes typed completeAction")
    func refreshQueuePendingFollowUpHelpers() {
        var q = RefreshQueueState()
        let bundle = CurrentMonthBundle(
            today: samplePeriod(cost: 1.0),
            week: samplePeriod(cost: 5.0),
            month: samplePeriod(cost: 10.0),
            dailyBreakdown: nil,
            time: nil
        )

        _ = q.request(force: false)
        #expect(!q.hasPendingFollowUp)
        #expect(q.phaseForIntermediateResult(LoadPhase.loaded(bundle)) == .loaded(bundle))

        // User hits ⌘R while scan is running -> follow-up pending
        _ = q.request(force: true)
        #expect(q.hasPendingFollowUp)
        // Intermediate result stays .loading(cached: bundle) so UI never flashes .loaded -> .loading
        #expect(q.phaseForIntermediateResult(LoadPhase.loaded(bundle)) == .loading(cached: bundle))
        #expect(q.phaseForIntermediateResult(LoadPhase<CurrentMonthBundle>.failed(.scriptFailed, cached: bundle)) == .loading(cached: bundle))

        // Typed completion reports .runFollowUp(force: true), then .idle
        #expect(q.completeAction() == .runFollowUp(force: true))
        #expect(!q.hasPendingFollowUp)
        #expect(q.phaseForIntermediateResult(LoadPhase.loaded(bundle)) == .loaded(bundle))
        #expect(q.completeAction() == .idle)
    }

    @Test("SnapshotFreshnessPolicy and MonthNavigationState reject stale current-month fetches across midnight rollover")
    func currentMonthFreshnessAcrossMidnightRollover() throws {
        // Use explicit Gregorian components in local timezone to avoid UTC offset ambiguity across midnight
        let cal = AppDate.gregorian
        let nov30Late = try #require(cal.date(from: DateComponents(year: 2026, month: 11, day: 30, hour: 23, minute: 59, second: 55)))
        let dec01Early = try #require(cal.date(from: DateComponents(year: 2026, month: 12, day: 1, hour: 0, minute: 0, second: 5)))
        let jan01Next = try #require(cal.date(from: DateComponents(year: 2027, month: 1, day: 1, hour: 0, minute: 0, second: 5)))

        #expect(SnapshotFreshnessPolicy.yearMonthKey(year: 2026, month: 11) == "2026-11")
        #expect(SnapshotFreshnessPolicy.currentYearMonthKey(now: nov30Late) == "2026-11")
        #expect(SnapshotFreshnessPolicy.currentYearMonthKey(now: dec01Early) == "2026-12")

        // Same month -> fresh
        #expect(SnapshotFreshnessPolicy.isFreshCurrentMonthFetch(fetchedYear: 2026, fetchedMonth: 11, now: nov30Late))
        #expect(SnapshotFreshnessPolicy.isFreshCurrentMonthFetch(fetchedYearMonth: "2026-11", now: nov30Late))
        #expect(MonthNavigationState.isCurrentMonth(year: 2026, month: 11, now: nov30Late))

        // Midnight month rollover Nov 30 -> Dec 1 -> stale fetch MUST NOT overwrite currentMonthData!
        #expect(!SnapshotFreshnessPolicy.isFreshCurrentMonthFetch(fetchedYear: 2026, fetchedMonth: 11, now: dec01Early))
        #expect(!SnapshotFreshnessPolicy.isFreshCurrentMonthFetch(fetchedYearMonth: "2026-11", now: dec01Early))
        #expect(!MonthNavigationState.isCurrentMonth(year: 2026, month: 11, now: dec01Early))

        // Year rollover Dec 31 -> Jan 1 -> stale
        #expect(!SnapshotFreshnessPolicy.isFreshCurrentMonthFetch(fetchedYear: 2026, fetchedMonth: 12, now: jan01Next))
        #expect(SnapshotFreshnessPolicy.isFreshCurrentMonthFetch(fetchedYear: 2027, fetchedMonth: 1, now: jan01Next))
    }
}
