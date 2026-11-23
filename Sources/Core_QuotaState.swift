import Foundation

// MARK: - Plan Quota, Auth & Rate-Limit Cooldown State Machine — pure core
//
// Models quota lifecycle explicitly so:
// 1. Offline desktop fallbacks during a 429 NEVER wipe the active cooldown timer
//    and continue surfacing the rate-limit notice banner.
// 2. HTTP 401/403 stays visibly surfaced in the Plan tab (`.unauthorized`) instead
//    of hiding the Plan tab behind `hasOAuthToken = false`.
// 3. HTTP 200 with unreadable schema surfaces `.decodeFailure`, while 5xx / transport
//    errors surface `.networkFailure`.
//
// Generic over `Snapshot` so `Models.swift`'s app-layer `OAuthUsage` stays out of AGYCore.

public enum CoreQuotaError: String, Equatable, Sendable {
    case unauthorized
    case rateLimited
    case networkFailure
    case decodeFailure
}

public enum QuotaSource: String, Equatable, Sendable {
    case live
    case offlineCache
}

public enum QuotaRefreshNotice: Equatable, Sendable {
    case none
    case rateLimited(retryAt: Date?)
    case staleError(CoreQuotaError)
}

public enum QuotaPhase<Snapshot: Equatable & Sendable>: Equatable, Sendable {
    case noAccount
    case loading
    case ready(
        snapshot: Snapshot,
        source: QuotaSource,
        updatedAt: Date?,
        notice: QuotaRefreshNotice,
        isRefreshing: Bool
    )
    case failed(error: CoreQuotaError, retryAt: Date?)

    /// Convenience factory defaulting `isRefreshing` to `false`.
    public static func ready(
        snapshot: Snapshot,
        source: QuotaSource,
        updatedAt: Date?,
        notice: QuotaRefreshNotice
    ) -> QuotaPhase<Snapshot> {
        .ready(
            snapshot: snapshot,
            source: source,
            updatedAt: updatedAt,
            notice: notice,
            isRefreshing: false
        )
    }

    /// Keep the Plan tab accessible whenever an account surface exists, including `.unauthorized`.
    public var hasAccountSurface: Bool {
        switch self {
        case .noAccount:
            return false
        case .loading, .ready, .failed:
            return true
        }
    }

    /// True during initial `.loading` OR while refreshing on top of a `.ready` snapshot.
    public var isLoading: Bool {
        switch self {
        case .loading:
            return true
        case .ready(_, _, _, _, let isRefreshing):
            return isRefreshing
        case .noAccount, .failed:
            return false
        }
    }

    /// True only while an in-flight refresh is running on top of an already-loaded `.ready` snapshot.
    public var isRefreshing: Bool {
        if case .ready(_, _, _, _, let isRefreshing) = self { return isRefreshing }
        return false
    }

    public var snapshot: Snapshot? {
        if case .ready(let snapshot, _, _, _, _) = self { return snapshot }
        return nil
    }

    public var error: CoreQuotaError? {
        switch self {
        case .failed(let err, _):
            return err
        case .ready(_, _, _, let notice, _):
            switch notice {
            case .none:
                return nil
            case .rateLimited:
                return .rateLimited
            case .staleError(let err):
                return err
            }
        case .noAccount, .loading:
            return nil
        }
    }

    public var retryAt: Date? {
        switch self {
        case .failed(_, let retryAt):
            return retryAt
        case .ready(_, _, _, .rateLimited(let retryAt), _):
            return retryAt
        case .ready, .noAccount, .loading:
            return nil
        }
    }

    public var updatedAt: Date? {
        if case .ready(_, _, let updatedAt, _, _) = self { return updatedAt }
        return nil
    }

    public var isOfflineCached: Bool {
        if case .ready(_, .offlineCache, _, _, _) = self { return true }
        return false
    }
}

public struct QuotaCooldownState: Equatable, Sendable {
    public private(set) var rateLimitedUntil: Date?

    public init(rateLimitedUntil: Date? = nil) {
        self.rateLimitedUntil = rateLimitedUntil
    }

    public mutating func recordRateLimit(until: Date) {
        if let existing = rateLimitedUntil {
            rateLimitedUntil = max(existing, until)
        } else {
            rateLimitedUntil = until
        }
    }

    /// Only live Cloud Code PA success clears a server rate-limit cooldown.
    public mutating func recordLiveSuccess() {
        rateLimitedUntil = nil
    }

    /// Serving cached desktop quota during a 429 deliberately preserves `rateLimitedUntil`.
    public mutating func recordOfflineFallback() {
        // Intentional no-op: keep rateLimitedUntil intact.
    }

    public func activeDeadline(at now: Date = Date()) -> Date? {
        guard let until = rateLimitedUntil, until > now else { return nil }
        return until
    }

    public func isCoolingDown(at now: Date = Date()) -> Bool {
        activeDeadline(at: now) != nil
    }
}

public enum LiveQuotaHTTPOutcome: Equatable, Sendable {
    case live
    case rateLimited(retryAt: Date)
    case unauthorized
    case networkFailure
    case decodeFailure

    public static func classifyLiveHTTP(
        hasMergedBuckets: Bool,
        statuses: [Int],
        rateLimitDeadline: Date?,
        defaultDeadline: Date = Date().addingTimeInterval(60)
    ) -> LiveQuotaHTTPOutcome {
        if hasMergedBuckets {
            return .live
        }
        if statuses.contains(429) {
            return .rateLimited(retryAt: rateLimitDeadline ?? defaultDeadline)
        }
        if statuses.contains(401) || statuses.contains(403) {
            return .unauthorized
        }
        if statuses.contains(200) {
            return .decodeFailure
        }
        return .networkFailure
    }
}

public enum QuotaStateEvent<Snapshot: Equatable & Sendable>: Equatable, Sendable {
    case tokenPresenceChanged(Bool)
    case beginFetch
    case fetched(Snapshot, source: QuotaSource, at: Date, notice: QuotaRefreshNotice)
    case fetchFailed(CoreQuotaError, retryAt: Date?, at: Date)
    case cooldownExpired(now: Date)
}

public enum QuotaStateReducer {

    public static func reduce<Snapshot: Equatable & Sendable>(
        _ phase: QuotaPhase<Snapshot>,
        event: QuotaStateEvent<Snapshot>
    ) -> QuotaPhase<Snapshot> {
        switch event {
        case .tokenPresenceChanged(false):
            return .noAccount

        case .tokenPresenceChanged(true):
            if case .noAccount = phase {
                return .loading
            }
            return phase

        case .beginFetch:
            switch phase {
            case .noAccount, .failed:
                return .loading
            case .loading:
                return .loading
            case .ready(let snapshot, let source, let updatedAt, let notice, _):
                return .ready(
                    snapshot: snapshot,
                    source: source,
                    updatedAt: updatedAt,
                    notice: notice,
                    isRefreshing: true
                )
            }

        case .fetched(let snapshot, let source, let at, let notice):
            return .ready(
                snapshot: snapshot,
                source: source,
                updatedAt: at,
                notice: notice,
                isRefreshing: false
            )

        case .fetchFailed(let error, let retryAt, _):
            if case .ready(let snapshot, let source, let updatedAt, _, _) = phase {
                if error == .unauthorized && source == .live {
                    return .failed(error: .unauthorized, retryAt: nil)
                }
                let notice: QuotaRefreshNotice = (error == .rateLimited)
                    ? .rateLimited(retryAt: retryAt)
                    : .staleError(error)
                return .ready(
                    snapshot: snapshot,
                    source: source,
                    updatedAt: updatedAt,
                    notice: notice,
                    isRefreshing: false
                )
            }
            return .failed(error: error, retryAt: retryAt)

        case .cooldownExpired(let now):
            switch phase {
            case .ready(let snapshot, let source, let updatedAt, .rateLimited(let retryAt), let isRefreshing):
                if let retryAt = retryAt, retryAt <= now {
                    return .ready(
                        snapshot: snapshot,
                        source: source,
                        updatedAt: updatedAt,
                        notice: .none,
                        isRefreshing: isRefreshing
                    )
                }
                return phase
            case .failed(.rateLimited, let retryAt):
                if let retryAt = retryAt, retryAt <= now {
                    return .failed(error: .rateLimited, retryAt: nil)
                }
                return phase
            default:
                return phase
            }
        }
    }

    /// Pure gate for deciding whether entering the Plan tab should trigger a quota refresh.
    /// Prevents redundant synchronous token probes while already loading/refreshing or actively
    /// cooling down from an HTTP 429 rate limit.
    public static func shouldAutoRefreshOnTabEntry<Snapshot: Equatable & Sendable>(
        phase: QuotaPhase<Snapshot>,
        cooldownUntil: Date?,
        now: Date = Date(),
        minFreshInterval: TimeInterval = 30
    ) -> Bool {
        if phase.isLoading { return false }
        if let until = cooldownUntil, until > now { return false }
        if let retryAt = phase.retryAt, retryAt > now { return false }
        guard let updatedAt = phase.updatedAt else { return true }
        return now.timeIntervalSince(updatedAt) > minFreshInterval
    }
}

// MARK: - Quota Fetch Generation Guard

/// Monotonic generation tracker for in-flight quota fetches so an account logout
/// (`.noAccount` -> `invalidate()`) or a superseding refresh can NEVER resurrect stale
/// quota snapshots in the Plan tab.
public struct QuotaFetchGenerationState: Equatable, Sendable {
    public private(set) var generation: UInt64
    public private(set) var activeGeneration: UInt64?

    public init(generation: UInt64 = 0, activeGeneration: UInt64? = nil) {
        self.generation = generation
        self.activeGeneration = activeGeneration
    }

    public var hasActiveFetch: Bool { activeGeneration != nil }

    /// Starts a new fetch, returning a monotonic token that supersedes earlier in-flight fetches.
    @discardableResult
    public mutating func beginFetch() -> UInt64 {
        generation &+= 1
        if generation == 0 { generation = 1 }
        activeGeneration = generation
        return generation
    }

    /// Invalidates any in-flight fetch (e.g. on logout / `.noAccount`).
    public mutating func invalidate() {
        generation &+= 1
        if generation == 0 { generation = 1 }
        activeGeneration = nil
    }

    /// True iff `gen` is still the current active, non-invalidated fetch generation.
    public func isCurrent(_ gen: UInt64) -> Bool {
        activeGeneration == gen && generation == gen
    }

    /// Marks `gen` completed if it is still current. Returns `true` if the caller should apply
    /// the fetch result, or `false` if this fetch was superseded or invalidated.
    @discardableResult
    public mutating func complete(_ gen: UInt64) -> Bool {
        guard isCurrent(gen) else { return false }
        activeGeneration = nil
        return true
    }
}

// MARK: - Quota Fetch Coalescing & Forced Follow-Up Gate

public enum QuotaFetchDecision: Equatable, Sendable {
    case serveCache
    case serveCooldown(retryAt: Date)
    case startNetworkFetch(force: Bool)
    case coalesceIntoInFlight
}

/// Deterministic gate governing `SubscriptionQuotaService.fetch(forceRefresh:)`:
/// - Serves fresh cache within TTL unless `force == true`.
/// - Enforces active 429 cooldown windows without hitting the server.
/// - Coalesces overlapping requests, AND upgrades an in-flight non-forced fetch by
///   queueing a single forced follow-up if `force == true` (`⌘R`) arrives mid-flight.
public struct QuotaFetchGate: Equatable, Sendable {
    public private(set) var isInFlight: Bool = false
    public private(set) var currentForce: Bool = false
    public private(set) var pendingForcedFollowUp: Bool = false

    public init() {}

    public mutating func request(
        force: Bool,
        cacheTimestamp: Date?,
        ttl: TimeInterval,
        cooldownDeadline: Date?,
        now: Date = Date()
    ) -> QuotaFetchDecision {
        // Active 429 cooldown ALWAYS takes precedence over TTL cache so a non-forced
        // refresh within 60s never wipes an active rate-limit notice banner.
        if let until = cooldownDeadline, until > now {
            return .serveCooldown(retryAt: until)
        }
        if !force, let cachedAt = cacheTimestamp, now.timeIntervalSince(cachedAt) < ttl {
            return .serveCache
        }
        if !isInFlight {
            isInFlight = true
            currentForce = force
            pendingForcedFollowUp = false
            return .startNetworkFetch(force: force)
        }
        if force && !currentForce {
            pendingForcedFollowUp = true
        }
        return .coalesceIntoInFlight
    }

    /// Complete the active fetch. Returns `true` if a queued forced follow-up should run immediately.
    public mutating func complete() -> Bool {
        if pendingForcedFollowUp {
            isInFlight = true
            currentForce = true
            pendingForcedFollowUp = false
            return true
        }
        isInFlight = false
        currentForce = false
        return false
    }

    public mutating func reset() {
        isInFlight = false
        currentForce = false
        pendingForcedFollowUp = false
    }
}

// MARK: - Stale-While-Revalidate Token Presence Probe State Machine

public enum TokenPresenceAction: Equatable, Sendable {
    case returnCached(Bool)
    case returnCachedAndRevalidate(Bool)
    case probeSynchronously
}

/// Pure SWR state machine for `SubscriptionQuotaService.hasOAuthToken`.
/// Generation-stamped so a slow background SWR revalidation can NEVER overwrite
/// a newer synchronous `probeTokenPresenceNow()` result.
public struct TokenPresenceProbeState: Equatable, Sendable {
    public private(set) var cachedValue: Bool?
    public private(set) var cachedAt: Date?
    public private(set) var isRevalidating: Bool = false
    public private(set) var generation: Int = 0
    public let ttl: TimeInterval

    public init(ttl: TimeInterval = 60) {
        self.ttl = ttl
    }

    public mutating func evaluate(now: Date = Date()) -> TokenPresenceAction {
        guard let value = cachedValue, let at = cachedAt else {
            return .probeSynchronously
        }
        if now.timeIntervalSince(at) < ttl {
            return .returnCached(value)
        }
        if isRevalidating {
            return .returnCached(value)
        }
        isRevalidating = true
        generation += 1
        return .returnCachedAndRevalidate(value)
    }

    /// Record a direct/synchronous probe result (advances generation, superseding any in-flight SWR).
    public mutating func recordResult(_ value: Bool, at now: Date = Date()) {
        generation += 1
        cachedValue = value
        cachedAt = now
        isRevalidating = false
    }

    /// Record a background SWR result only if `token` still matches the latest generation.
    @discardableResult
    public mutating func recordRevalidatedResult(_ value: Bool, generation token: Int, at now: Date = Date()) -> Bool {
        guard token == generation else { return false }
        cachedValue = value
        cachedAt = now
        isRevalidating = false
        return true
    }
}
