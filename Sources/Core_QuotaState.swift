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
    case ready(snapshot: Snapshot, source: QuotaSource, updatedAt: Date?, notice: QuotaRefreshNotice)
    case failed(error: CoreQuotaError, retryAt: Date?)

    /// Keep the Plan tab accessible whenever an account surface exists, including `.unauthorized`.
    public var hasAccountSurface: Bool {
        switch self {
        case .noAccount:
            return false
        case .loading, .ready, .failed:
            return true
        }
    }

    public var snapshot: Snapshot? {
        if case .ready(let snapshot, _, _, _) = self { return snapshot }
        return nil
    }

    public var error: CoreQuotaError? {
        switch self {
        case .failed(let err, _):
            return err
        case .ready(_, _, _, let notice):
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
        case .ready(_, _, _, .rateLimited(let retryAt)):
            return retryAt
        case .ready, .noAccount, .loading:
            return nil
        }
    }

    public var updatedAt: Date? {
        if case .ready(_, _, let updatedAt, _) = self { return updatedAt }
        return nil
    }

    public var isOfflineCached: Bool {
        if case .ready(_, .offlineCache, _, _) = self { return true }
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
            if case .noAccount = phase {
                return .loading
            }
            return phase

        case .fetched(let snapshot, let source, let at, let notice):
            return .ready(snapshot: snapshot, source: source, updatedAt: at, notice: notice)

        case .fetchFailed(let error, let retryAt, _):
            if case .ready(let snapshot, let source, let updatedAt, _) = phase {
                if error == .unauthorized && source == .live {
                    return .failed(error: .unauthorized, retryAt: nil)
                }
                let notice: QuotaRefreshNotice = (error == .rateLimited)
                    ? .rateLimited(retryAt: retryAt)
                    : .staleError(error)
                return .ready(snapshot: snapshot, source: source, updatedAt: updatedAt, notice: notice)
            }
            return .failed(error: error, retryAt: retryAt)
        }
    }
}
