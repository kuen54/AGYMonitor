import Foundation

// MARK: - Semantic Version

/// Strict Foundation-only semantic version supporting `major.minor[.patch][-prerelease][+build]`.
/// Used by `UpdateCheckerMachine` to compare the running app version against GitHub Releases.
public struct SemanticVersion: Equatable, Hashable, Comparable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [String]

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public var canonical: String {
        let base = "\(major).\(minor).\(patch)"
        if prerelease.isEmpty { return base }
        return "\(base)-\(prerelease.joined(separator: "."))"
    }

    public var displayTag: String { "v\(canonical)" }

    public init(major: Int, minor: Int, patch: Int = 0, prerelease: [String] = []) {
        self.major = max(0, major)
        self.minor = max(0, minor)
        self.patch = max(0, patch)
        self.prerelease = prerelease
    }

    /// Parses strings like `"v1.5.2"`, `"1.5.2"`, `"V1.6"`, `"1.6.0-beta.1"`, `"1.6.0+20261121"`.
    public static func parse(_ raw: String) -> SemanticVersion? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("v") || s.hasPrefix("V") {
            s.removeFirst()
        }
        guard !s.isEmpty else { return nil }

        // Strip build metadata (+...)
        if let plusIdx = s.firstIndex(of: "+") {
            s = String(s[..<plusIdx])
        }
        guard !s.isEmpty else { return nil }

        // Split prerelease (-...)
        let corePart: String
        let preParts: [String]
        if let dashIdx = s.firstIndex(of: "-") {
            corePart = String(s[..<dashIdx])
            let preRaw = String(s[s.index(after: dashIdx)...])
            let split = preRaw.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !preRaw.isEmpty, split.allSatisfy({ !$0.isEmpty }) else { return nil }
            preParts = split
        } else {
            corePart = s
            preParts = []
        }

        let comps = corePart.split(separator: ".", omittingEmptySubsequences: false)
        guard comps.count == 2 || comps.count == 3 else { return nil }

        var nums: [Int] = []
        for comp in comps {
            guard !comp.isEmpty, comp.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let val = Int(comp), val >= 0 else {
                return nil
            }
            nums.append(val)
        }

        return SemanticVersion(
            major: nums[0],
            minor: nums[1],
            patch: nums.count == 3 ? nums[2] : 0,
            prerelease: preParts
        )
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // Stable release > prerelease of same core version
        if lhs.prerelease.isEmpty && rhs.prerelease.isEmpty { return false }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }

        let count = min(lhs.prerelease.count, rhs.prerelease.count)
        for i in 0..<count {
            let a = lhs.prerelease[i]
            let b = rhs.prerelease[i]
            if a == b { continue }
            let aInt = Int(a)
            let bInt = Int(b)
            switch (aInt, bInt) {
            case let (ai?, bi?):
                return ai < bi
            case (_?, nil):
                // Numeric identifiers have lower precedence than non-numeric per SemVer 2.0
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return a < b
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

// MARK: - Release Info & Parsers

public struct ReleaseInfo: Equatable, Sendable {
    public let version: SemanticVersion
    public let tag: String
    public let releasePageURLString: String
    public let downloadURLString: String?
    public let summary: String?
    public let publishedAt: Date?

    public init(
        version: SemanticVersion,
        tag: String,
        releasePageURLString: String,
        downloadURLString: String? = nil,
        summary: String? = nil,
        publishedAt: Date? = nil
    ) {
        self.version = version
        self.tag = tag
        self.releasePageURLString = releasePageURLString
        self.downloadURLString = downloadURLString
        self.summary = summary
        self.publishedAt = publishedAt
    }
}

public enum UpdateReleaseParser {
    public static let defaultRepoOwner = "kuen54"
    public static let defaultRepoName = "AGYMonitor"

    public static func latestReleaseRedirectURLString(
        repoOwner: String = defaultRepoOwner,
        repoName: String = defaultRepoName
    ) -> String {
        "https://github.com/\(repoOwner)/\(repoName)/releases/latest"
    }

    public static func latestReleaseAPIURLString(
        repoOwner: String = defaultRepoOwner,
        repoName: String = defaultRepoName
    ) -> String {
        "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
    }

    /// Verifies that a URL points to a release or asset on `https://github.com/<owner>/<repo>/...`.
    public static func isAllowedReleaseURL(
        _ urlString: String,
        repoOwner: String = defaultRepoOwner,
        repoName: String = defaultRepoName
    ) -> Bool {
        guard let comps = URLComponents(string: urlString),
              comps.scheme?.lowercased() == "https",
              comps.host?.lowercased() == "github.com" else {
            return false
        }
        let expectedPrefix = "/\(repoOwner)/\(repoName)/releases".lowercased()
        let path = comps.path.lowercased()
        return path == expectedPrefix || path.hasPrefix(expectedPrefix + "/")
    }

    /// Parses a GitHub `/releases/latest` 302 redirect target such as
    /// `https://github.com/kuen54/AGYMonitor/releases/tag/v1.6.0` (or relative `/kuen54/AGYMonitor/releases/tag/v1.6.0`).
    /// Rejects untrusted hosts, wrong repositories, non-semver tags, and prereleases.
    public static func parseRedirectURL(
        _ rawLocation: String,
        repoOwner: String = defaultRepoOwner,
        repoName: String = defaultRepoName
    ) -> ReleaseInfo? {
        let trimmed = rawLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let resolvedString: String
        if trimmed.hasPrefix("/") {
            resolvedString = "https://github.com\(trimmed)"
        } else {
            resolvedString = trimmed
        }

        guard isAllowedReleaseURL(resolvedString, repoOwner: repoOwner, repoName: repoName),
              let comps = URLComponents(string: resolvedString) else {
            return nil
        }

        let parts = comps.path.split(separator: "/").map(String.init)
        // Expected: [owner, repo, "releases", "tag", "<tag>"]
        guard parts.count == 5,
              parts[0].lowercased() == repoOwner.lowercased(),
              parts[1].lowercased() == repoName.lowercased(),
              parts[2].lowercased() == "releases",
              parts[3].lowercased() == "tag" else {
            return nil
        }

        let tag = parts[4]
        guard let version = SemanticVersion.parse(tag), !version.isPrerelease else {
            return nil
        }

        let canonicalPage = "https://github.com/\(repoOwner)/\(repoName)/releases/tag/\(tag)"
        return ReleaseInfo(
            version: version,
            tag: tag,
            releasePageURLString: canonicalPage
        )
    }

    /// Parses the JSON payload of `GET /repos/<owner>/<repo>/releases/latest`.
    /// Rejects drafts, prereleases, non-semver tags, and untrusted URLs.
    public static func parseGitHubReleaseJSON(
        _ data: Data,
        repoOwner: String = defaultRepoOwner,
        repoName: String = defaultRepoName
    ) -> ReleaseInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if (obj["draft"] as? Bool) == true { return nil }
        if (obj["prerelease"] as? Bool) == true { return nil }

        guard let tag = obj["tag_name"] as? String,
              let version = SemanticVersion.parse(tag),
              !version.isPrerelease else {
            return nil
        }

        let fallbackPage = "https://github.com/\(repoOwner)/\(repoName)/releases/tag/\(tag)"
        let pageURL: String
        if let htmlURL = obj["html_url"] as? String,
           isAllowedReleaseURL(htmlURL, repoOwner: repoOwner, repoName: repoName) {
            pageURL = htmlURL
        } else {
            pageURL = fallbackPage
        }

        var dmgURL: String? = nil
        if let assets = obj["assets"] as? [[String: Any]] {
            for asset in assets {
                guard let name = asset["name"] as? String,
                      name.lowercased().hasSuffix(".dmg"),
                      let url = asset["browser_download_url"] as? String,
                      isAllowedReleaseURL(url, repoOwner: repoOwner, repoName: repoName) else {
                    continue
                }
                dmgURL = url
                break
            }
        }

        let summary = extractSummaryLine(from: obj["body"] as? String)
        let publishedAt: Date? = (obj["published_at"] as? String).flatMap { parseISO8601($0) }

        return ReleaseInfo(
            version: version,
            tag: tag,
            releasePageURLString: pageURL,
            downloadURLString: dmgURL,
            summary: summary,
            publishedAt: publishedAt
        )
    }

    private static func extractSummaryLine(from body: String?) -> String? {
        guard let body = body, !body.isEmpty else { return nil }
        for rawLine in body.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") || line.hasPrefix("---") || line.hasPrefix("<!--") { continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            if line.isEmpty { continue }
            if line.count > 120 {
                return String(line.prefix(117)) + "…"
            }
            return line
        }
        return nil
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: value) { return d }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

// MARK: - Update Checker State Machine

public enum UpdateTiming {
    /// Delay after app launch or wake before kicking off an automatic check (avoids startup contention & lets Wi-Fi associate).
    public static let launchDelay: Double = 10.0
    /// Minimum interval between automatic update checks (24 hours).
    public static let autoCheckInterval: Double = 24 * 60 * 60
    /// Retry delay after a failed automatic check (2 hours).
    public static let failureRetryInterval: Double = 2 * 60 * 60
    /// Cooldown preventing rapid repeated manual checks.
    public static let manualCooldown: Double = 3.0
    /// Duration manual "Up to date" / "Check failed" feedback remains visible.
    public static let transientFeedbackDuration: Double = 4.0
}

public enum UpdateCheckTrigger: Equatable, Sendable {
    case automatic
    case manual
}

public enum UpdateFetchResult: Equatable, Sendable {
    case release(ReleaseInfo)
    case noReleaseFound
    case failure(String)
}

public enum UpdateCheckPhase: Equatable, Sendable {
    case idle
    case checking(trigger: UpdateCheckTrigger)
    case upToDate(checkedAt: Date, trigger: UpdateCheckTrigger)
    case available(ReleaseInfo)
    case failed(message: String, trigger: UpdateCheckTrigger)
}

/// Pure view-model projection for the in-app update status strip.
/// Automatic background checks never display checking / up-to-date / failure noise.
public enum UpdateBannerDisplay: Equatable, Sendable {
    case none
    case available(ReleaseInfo)
    case checking
    case upToDate(SemanticVersion)
    case failed
}

public struct UpdateCheckerState: Equatable, Sendable {
    public var currentVersion: SemanticVersion
    public var phase: UpdateCheckPhase
    /// Most recently confirmed newer release (persisted across restarts and preserved
    /// across transient offline checks/failures so the in-app banner never flickers or disappears).
    public var knownRelease: ReleaseInfo?
    public var isStarted: Bool
    public var autoCheckEnabled: Bool
    public var lastCheckAt: Date?
    public var lastManualRequestAt: Date?
    public var skippedVersion: String?
    public var notifiedVersion: String?
    public var checkGeneration: UInt64

    public init(
        currentVersion: SemanticVersion,
        autoCheckEnabled: Bool = true,
        lastCheckAt: Date? = nil,
        skippedVersion: String? = nil,
        notifiedVersion: String? = nil,
        cachedLatestTag: String? = nil,
        repoOwner: String = UpdateReleaseParser.defaultRepoOwner,
        repoName: String = UpdateReleaseParser.defaultRepoName
    ) {
        self.currentVersion = currentVersion
        if let tag = cachedLatestTag,
           let cachedVersion = SemanticVersion.parse(tag),
           !cachedVersion.isPrerelease,
           cachedVersion > currentVersion {
            let pageURL = "https://github.com/\(repoOwner)/\(repoName)/releases/tag/\(tag)"
            let info = ReleaseInfo(
                version: cachedVersion,
                tag: tag,
                releasePageURLString: pageURL
            )
            self.knownRelease = info
            self.phase = .available(info)
        } else {
            self.knownRelease = nil
            self.phase = .idle
        }
        self.isStarted = false
        self.autoCheckEnabled = autoCheckEnabled
        self.lastCheckAt = lastCheckAt
        self.lastManualRequestAt = nil
        self.skippedVersion = skippedVersion
        self.notifiedVersion = notifiedVersion
        self.checkGeneration = 0
    }

    public var isChecking: Bool {
        if case .checking = phase { return true }
        return false
    }

    /// Newer release known to be available (even if the user dismissed its banner or
    /// a background refresh is currently running/failed offline).
    public var availableUpdate: ReleaseInfo? {
        guard let info = knownRelease, info.version > currentVersion else {
            return nil
        }
        return info
    }

    /// True when the in-app update banner should show for an unskipped newer release.
    public var showsAvailableBanner: Bool {
        guard let info = availableUpdate else { return false }
        return skippedVersion != info.version.canonical
    }

    /// Pure projection for the in-panel status strip.
    /// Manual checks surface transient feedback (checking / up-to-date / failed),
    /// while automatic checks remain silent and preserve any visible update banner.
    public var bannerDisplay: UpdateBannerDisplay {
        switch phase {
        case .checking(.manual):
            return .checking
        case .upToDate(_, .manual):
            return .upToDate(currentVersion)
        case .failed(_, .manual):
            return .failed
        case .idle, .available, .checking(.automatic), .upToDate(_, .automatic), .failed(_, .automatic):
            if let info = availableUpdate, skippedVersion != info.version.canonical {
                return .available(info)
            }
            return .none
        }
    }
}

public enum UpdateCheckerEvent: Equatable, Sendable {
    case start(now: Date)
    case stop
    case periodicTick(now: Date)
    case wake(now: Date)
    case manualCheckRequested(now: Date)
    case checkCompleted(generation: UInt64, result: UpdateFetchResult, now: Date)
    case dismissAvailableUpdate
    case clearTransientFeedback
    case setAutoCheckEnabled(Bool, now: Date)
}

public enum UpdateCheckerEffect: Equatable, Sendable {
    case scheduleAutoCheck(afterSeconds: Double)
    case cancelAutoCheck
    case performFetch(generation: UInt64, trigger: UpdateCheckTrigger)
    case persistLastCheckAt(Date)
    case persistLatestReleaseTag(String?)
    case persistSkippedVersion(String?)
    case persistNotifiedVersion(String)
    case persistAutoCheckEnabled(Bool)
    case postSystemNotification(ReleaseInfo)
    case scheduleTransientFeedbackClear(afterSeconds: Double)
    case cancelTransientFeedbackClear
}

public enum UpdateCheckerMachine {
    public static func reduce(
        _ state: inout UpdateCheckerState,
        event: UpdateCheckerEvent
    ) -> [UpdateCheckerEffect] {
        switch event {
        case .start(let now):
            guard !state.isStarted else { return [] }
            state.isStarted = true
            guard state.autoCheckEnabled else { return [] }
            return [.scheduleAutoCheck(afterSeconds: nextAutoDelay(state: state, now: now))]

        case .stop:
            guard state.isStarted else { return [] }
            state.isStarted = false
            state.checkGeneration &+= 1
            if case .checking = state.phase {
                state.phase = state.availableUpdate.map { .available($0) } ?? .idle
            }
            return [.cancelAutoCheck, .cancelTransientFeedbackClear]

        case .periodicTick(let now):
            guard state.isStarted, state.autoCheckEnabled else { return [] }
            if state.isChecking { return [] }
            if let last = state.lastCheckAt {
                let elapsed = now.timeIntervalSince(last)
                if elapsed < UpdateTiming.autoCheckInterval {
                    let remaining = max(UpdateTiming.launchDelay, UpdateTiming.autoCheckInterval - elapsed)
                    return [.scheduleAutoCheck(afterSeconds: remaining)]
                }
            }
            return beginCheck(&state, trigger: .automatic, now: now)

        case .wake(let now):
            guard state.isStarted, state.autoCheckEnabled, !state.isChecking else { return [] }
            if let last = state.lastCheckAt, now.timeIntervalSince(last) < UpdateTiming.autoCheckInterval {
                return []
            }
            // Wait launchDelay (10s) after lid-open so Wi-Fi/VPN can reconnect before checking.
            return [.scheduleAutoCheck(afterSeconds: UpdateTiming.launchDelay)]

        case .manualCheckRequested(let now):
            if case .checking(.manual) = state.phase {
                return []
            }
            if let lastManual = state.lastManualRequestAt,
               now.timeIntervalSince(lastManual) < UpdateTiming.manualCooldown {
                return []
            }
            state.lastManualRequestAt = now
            var effects: [UpdateCheckerEffect] = [.cancelTransientFeedbackClear]
            effects.append(contentsOf: beginCheck(&state, trigger: .manual, now: now))
            return effects

        case .checkCompleted(let generation, let result, let now):
            guard generation == state.checkGeneration else { return [] }
            guard case .checking(let trigger) = state.phase else { return [] }

            var effects: [UpdateCheckerEffect] = []

            switch result {
            case .release(let info):
                state.lastCheckAt = now
                effects.append(.persistLastCheckAt(now))

                if info.version > state.currentVersion {
                    let canonical = info.version.canonical
                    state.knownRelease = info
                    state.phase = .available(info)
                    effects.append(.persistLatestReleaseTag(info.tag))

                    // Manual check explicitly un-skips the discovered version so the user sees it.
                    if trigger == .manual, state.skippedVersion == canonical {
                        state.skippedVersion = nil
                        effects.append(.persistSkippedVersion(nil))
                    }

                    let isSkipped = (state.skippedVersion == canonical)
                    if !isSkipped, state.notifiedVersion != canonical {
                        state.notifiedVersion = canonical
                        effects.append(.persistNotifiedVersion(canonical))
                        // Post a macOS system notification once on automatic discovery.
                        // Manual checks already surface the in-app banner immediately right in view.
                        if trigger == .automatic {
                            effects.append(.postSystemNotification(info))
                        }
                    }
                } else {
                    state.knownRelease = nil
                    state.phase = .upToDate(checkedAt: now, trigger: trigger)
                    effects.append(.persistLatestReleaseTag(nil))
                    if trigger == .manual {
                        effects.append(.scheduleTransientFeedbackClear(afterSeconds: UpdateTiming.transientFeedbackDuration))
                    }
                }

                if state.isStarted && state.autoCheckEnabled {
                    effects.append(.scheduleAutoCheck(afterSeconds: UpdateTiming.autoCheckInterval))
                }

            case .noReleaseFound:
                state.lastCheckAt = now
                state.knownRelease = nil
                effects.append(.persistLastCheckAt(now))
                effects.append(.persistLatestReleaseTag(nil))
                state.phase = .upToDate(checkedAt: now, trigger: trigger)
                if trigger == .manual {
                    effects.append(.scheduleTransientFeedbackClear(afterSeconds: UpdateTiming.transientFeedbackDuration))
                }
                if state.isStarted && state.autoCheckEnabled {
                    effects.append(.scheduleAutoCheck(afterSeconds: UpdateTiming.autoCheckInterval))
                }

            case .failure(let message):
                // Do not advance lastCheckAt or clear knownRelease on failure so
                // automatic checks retry sooner and known update banners never vanish.
                state.phase = .failed(message: message, trigger: trigger)
                if trigger == .manual {
                    effects.append(.scheduleTransientFeedbackClear(afterSeconds: UpdateTiming.transientFeedbackDuration))
                }
                if state.isStarted && state.autoCheckEnabled {
                    effects.append(.scheduleAutoCheck(afterSeconds: UpdateTiming.failureRetryInterval))
                }
            }

            return effects

        case .dismissAvailableUpdate:
            guard let info = state.availableUpdate else { return [] }
            let canonical = info.version.canonical
            state.skippedVersion = canonical
            return [.persistSkippedVersion(canonical)]

        case .clearTransientFeedback:
            switch state.phase {
            case .upToDate(_, .manual), .failed(_, .manual):
                state.phase = state.availableUpdate.map { .available($0) } ?? .idle
            default:
                break
            }
            return []

        case .setAutoCheckEnabled(let enabled, let now):
            guard state.autoCheckEnabled != enabled else { return [] }
            state.autoCheckEnabled = enabled
            var effects: [UpdateCheckerEffect] = [.persistAutoCheckEnabled(enabled)]
            if state.isStarted {
                if enabled {
                    effects.append(.scheduleAutoCheck(afterSeconds: nextAutoDelay(state: state, now: now)))
                } else {
                    effects.append(.cancelAutoCheck)
                }
            }
            return effects
        }
    }

    private static func beginCheck(
        _ state: inout UpdateCheckerState,
        trigger: UpdateCheckTrigger,
        now: Date
    ) -> [UpdateCheckerEffect] {
        state.checkGeneration &+= 1
        let gen = state.checkGeneration
        state.phase = .checking(trigger: trigger)
        return [.performFetch(generation: gen, trigger: trigger)]
    }

    private static func nextAutoDelay(state: UpdateCheckerState, now: Date) -> Double {
        guard let last = state.lastCheckAt else {
            return UpdateTiming.launchDelay
        }
        let elapsed = now.timeIntervalSince(last)
        if elapsed >= UpdateTiming.autoCheckInterval {
            return UpdateTiming.launchDelay
        }
        return max(UpdateTiming.launchDelay, UpdateTiming.autoCheckInterval - elapsed)
    }
}
