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
}
