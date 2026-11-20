import Foundation
import Testing
@testable import AGYCore

@Suite("Core_QuotaState")
struct QuotaStateTests {

    @Test("QuotaCooldownState keeps 429 deadline across offline fallback and clears only on live success")
    func cooldownPreservedAcrossOfflineFallback() {
        let now = Date(timeIntervalSince1970: 10_000)
        let deadline = now.addingTimeInterval(300)
        var cooldown = QuotaCooldownState()

        cooldown.recordRateLimit(until: deadline)
        #expect(cooldown.isCoolingDown(at: now))
        #expect(cooldown.activeDeadline(at: now) == deadline)

        // Offline fallback MUST NOT clear cooldown
        cooldown.recordOfflineFallback()
        #expect(cooldown.isCoolingDown(at: now.addingTimeInterval(30)))
        #expect(cooldown.activeDeadline(at: now.addingTimeInterval(30)) == deadline)

        // Past deadline expires naturally
        #expect(!cooldown.isCoolingDown(at: deadline.addingTimeInterval(1)))

        // Live success clears immediately even before deadline
        cooldown.recordRateLimit(until: deadline)
        cooldown.recordLiveSuccess()
        #expect(!cooldown.isCoolingDown(at: now))
    }

    @Test("LiveQuotaHTTPOutcome distinguishes 429, 401/403, 200-empty decode error, and network failure")
    func httpClassification() {
        let dl = Date(timeIntervalSince1970: 20_000)
        #expect(LiveQuotaHTTPOutcome.classifyLiveHTTP(hasMergedBuckets: true, statuses: [200], rateLimitDeadline: nil) == .live)
        #expect(LiveQuotaHTTPOutcome.classifyLiveHTTP(hasMergedBuckets: false, statuses: [200, 429, 500], rateLimitDeadline: dl) == .rateLimited(retryAt: dl))
        #expect(LiveQuotaHTTPOutcome.classifyLiveHTTP(hasMergedBuckets: false, statuses: [401, 404], rateLimitDeadline: nil) == .unauthorized)
        #expect(LiveQuotaHTTPOutcome.classifyLiveHTTP(hasMergedBuckets: false, statuses: [403, -1], rateLimitDeadline: nil) == .unauthorized)
        #expect(LiveQuotaHTTPOutcome.classifyLiveHTTP(hasMergedBuckets: false, statuses: [200, 200], rateLimitDeadline: nil) == .decodeFailure)
        #expect(LiveQuotaHTTPOutcome.classifyLiveHTTP(hasMergedBuckets: false, statuses: [-1, 503], rateLimitDeadline: nil) == .networkFailure)
    }

    @Test("QuotaStateReducer preserves Plan tab visibility on .unauthorized and keeps 429 notice on offline snapshot")
    func quotaPhaseTransitions() {
        let t1 = Date(timeIntervalSince1970: 5_000)
        let retry = Date(timeIntervalSince1970: 5_300)
        var phase: QuotaPhase<String> = .noAccount
        #expect(!phase.hasAccountSurface)

        phase = QuotaStateReducer.reduce(phase, event: .tokenPresenceChanged(true))
        #expect(phase == .loading)
        #expect(phase.hasAccountSurface)

        // Auth failure MUST keep Plan tab visible so user can read the expired-auth hint
        phase = QuotaStateReducer.reduce(phase, event: .fetchFailed(.unauthorized, retryAt: nil, at: t1))
        #expect(phase == .failed(error: .unauthorized, retryAt: nil))
        #expect(phase.hasAccountSurface)

        // 429 + offline cache stays ready WITH rateLimited notice + retryAt
        phase = QuotaStateReducer.reduce(
            phase,
            event: .fetched("offline-snap", source: .offlineCache, at: t1, notice: .rateLimited(retryAt: retry))
        )
        #expect(phase.snapshot == "offline-snap")
        #expect(phase.isOfflineCached)
        #expect(phase.error == .rateLimited)
        #expect(phase.retryAt == retry)

        // Stale network error while ready preserves existing live snapshot with .staleError notice
        phase = QuotaStateReducer.reduce(
            phase,
            event: .fetched("live-snap", source: .live, at: t1, notice: .none)
        )
        phase = QuotaStateReducer.reduce(
            phase,
            event: .fetchFailed(.networkFailure, retryAt: nil, at: t1.addingTimeInterval(60))
        )
        #expect(phase.snapshot == "live-snap")
        #expect(phase.error == .networkFailure)

        // Live 401 when prior state was live moves directly to .failed(.unauthorized)
        phase = QuotaStateReducer.reduce(
            phase,
            event: .fetchFailed(.unauthorized, retryAt: nil, at: t1.addingTimeInterval(90))
        )
        #expect(phase == .failed(error: .unauthorized, retryAt: nil))
        #expect(phase.hasAccountSurface)
    }

    @Test("QuotaFetchGate serves cache/cooldown, coalesces in-flight, and queues forced follow-up on ⌘R")
    func quotaFetchGateCoalescingAndUpgrade() {
        var gate = QuotaFetchGate()
        let t0 = Date(timeIntervalSince1970: 10_000)

        // Fresh cache short-circuits non-forced fetch
        #expect(gate.request(force: false, cacheTimestamp: t0.addingTimeInterval(-10), ttl: 60, cooldownDeadline: nil, now: t0) == .serveCache)

        // Active 429 cooldown blocks even forced refreshes from hammering server
        let until = t0.addingTimeInterval(120)
        #expect(gate.request(force: true, cacheTimestamp: nil, ttl: 60, cooldownDeadline: until, now: t0) == .serveCooldown(retryAt: until))

        // Start a non-forced network fetch
        #expect(gate.request(force: false, cacheTimestamp: nil, ttl: 60, cooldownDeadline: nil, now: t0) == .startNetworkFetch(force: false))
        #expect(gate.isInFlight)

        // Non-forced caller coalesces without queueing a follow-up
        #expect(gate.request(force: false, cacheTimestamp: nil, ttl: 60, cooldownDeadline: nil, now: t0) == .coalesceIntoInFlight)
        #expect(!gate.pendingForcedFollowUp)

        // Forced ⌘R during non-forced in-flight queues a single forced follow-up
        #expect(gate.request(force: true, cacheTimestamp: nil, ttl: 60, cooldownDeadline: nil, now: t0) == .coalesceIntoInFlight)
        #expect(gate.pendingForcedFollowUp)

        // Completing the first fetch triggers the forced follow-up
        #expect(gate.complete() == true)
        #expect(gate.isInFlight)
        #expect(gate.currentForce)

        // Completing the forced follow-up leaves gate idle
        #expect(gate.complete() == false)
        #expect(!gate.isInFlight)
    }

    @Test("TokenPresenceProbeState performs SWR revalidation without overlapping probes")
    func tokenPresenceSWR() {
        var swr = TokenPresenceProbeState(ttl: 60)
        let t0 = Date(timeIntervalSince1970: 1_000)

        #expect(swr.evaluate(now: t0) == .probeSynchronously)
        swr.recordResult(true, at: t0)

        // Fresh within TTL
        #expect(swr.evaluate(now: t0.addingTimeInterval(30)) == .returnCached(true))

        // Stale past TTL triggers one background revalidation
        #expect(swr.evaluate(now: t0.addingTimeInterval(65)) == .returnCachedAndRevalidate(true))
        // Second call while revalidating does NOT spawn duplicate probe
        #expect(swr.evaluate(now: t0.addingTimeInterval(66)) == .returnCached(true))

        swr.recordResult(false, at: t0.addingTimeInterval(67))
        #expect(swr.evaluate(now: t0.addingTimeInterval(70)) == .returnCached(false))
    }

    @Test("shouldAutoRefreshOnTabEntry skips redundant probes during .loading and active 429 cooldown")
    func tabEntryAutoRefreshGate() {
        let now = Date(timeIntervalSince1970: 50_000)
        let future = now.addingTimeInterval(90)

        #expect(!QuotaStateReducer.shouldAutoRefreshOnTabEntry(phase: QuotaPhase<String>.loading, cooldownUntil: nil, now: now))
        #expect(!QuotaStateReducer.shouldAutoRefreshOnTabEntry(phase: QuotaPhase<String>.failed(error: .rateLimited, retryAt: future), cooldownUntil: nil, now: now))
        #expect(!QuotaStateReducer.shouldAutoRefreshOnTabEntry(phase: QuotaPhase<String>.noAccount, cooldownUntil: future, now: now))

        // Fresh snapshot (< 30s) skips refresh; stale snapshot (> 30s) refreshes
        let freshReady: QuotaPhase<String> = .ready(snapshot: "ok", source: .live, updatedAt: now.addingTimeInterval(-10), notice: .none)
        let staleReady: QuotaPhase<String> = .ready(snapshot: "ok", source: .live, updatedAt: now.addingTimeInterval(-45), notice: .none)
        #expect(!QuotaStateReducer.shouldAutoRefreshOnTabEntry(phase: freshReady, cooldownUntil: nil, now: now))
        #expect(QuotaStateReducer.shouldAutoRefreshOnTabEntry(phase: staleReady, cooldownUntil: nil, now: now))
    }

    @Test("QuotaFetchGate prioritizes active 429 cooldown over TTL cache, Retry enters .loading, cooldownExpired recovers, and SWR checks generation")
    func quotaCooldownPrecedenceAndRecovery() {
        var gate = QuotaFetchGate()
        let t0 = Date(timeIntervalSince1970: 80_000)
        let until = t0.addingTimeInterval(180)

        // Even with a fresh 10s-old offline cache, active 429 cooldown MUST return .serveCooldown (never wipe banner!)
        #expect(
            gate.request(
                force: false,
                cacheTimestamp: t0.addingTimeInterval(-10),
                ttl: 60,
                cooldownDeadline: until,
                now: t0
            ) == .serveCooldown(retryAt: until)
        )

        // Clicking Retry (.beginFetch) from .failed transitions immediately to .loading
        let failed: QuotaPhase<String> = .failed(error: .networkFailure, retryAt: nil)
        #expect(QuotaStateReducer.reduce(failed, event: .beginFetch) == .loading)

        // Cooldown expiry clears expired .rateLimited notice on ready snapshot and unlocks Retry on .failed
        let readyRL: QuotaPhase<String> = .ready(snapshot: "s", source: .offlineCache, updatedAt: t0, notice: .rateLimited(retryAt: until))
        #expect(QuotaStateReducer.reduce(readyRL, event: .cooldownExpired(now: until.addingTimeInterval(-1))) == readyRL)
        #expect(QuotaStateReducer.reduce(readyRL, event: .cooldownExpired(now: until)) == .ready(snapshot: "s", source: .offlineCache, updatedAt: t0, notice: .none))

        let failedRL: QuotaPhase<String> = .failed(error: .rateLimited, retryAt: until)
        #expect(QuotaStateReducer.reduce(failedRL, event: .cooldownExpired(now: until)) == .failed(error: .rateLimited, retryAt: nil))

        // Generation-stamped SWR probe never overwrites a newer forced probe
        var swr = TokenPresenceProbeState(ttl: 60)
        swr.recordResult(true, at: t0)
        _ = swr.evaluate(now: t0.addingTimeInterval(70))
        let staleGen = swr.generation
        // Forced probe supersedes SWR
        swr.recordResult(false, at: t0.addingTimeInterval(71))
        let staleRevalAccepted = swr.recordRevalidatedResult(true, generation: staleGen, at: t0.addingTimeInterval(72))
        #expect(!staleRevalAccepted)
        #expect(swr.cachedValue == false)
    }
}
