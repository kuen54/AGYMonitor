import Foundation
import Testing
@testable import AGYCore

@Suite("Update Checker State Machine")
struct UpdateStateTests {

    private func makeRelease(
        _ tag: String,
        summary: String? = nil
    ) -> ReleaseInfo {
        let ver = SemanticVersion.parse(tag)!
        return ReleaseInfo(
            version: ver,
            tag: tag,
            releasePageURLString: "https://github.com/kuen54/AGYMonitor/releases/tag/\(tag)",
            summary: summary
        )
    }

    // MARK: - SemanticVersion

    @Test("SemanticVersion parses valid strings and rejects malformed inputs")
    func semanticVersionParsing() {
        #expect(SemanticVersion.parse("v1.5.2") == SemanticVersion(major: 1, minor: 5, patch: 2))
        #expect(SemanticVersion.parse("V2.0") == SemanticVersion(major: 2, minor: 0, patch: 0))
        #expect(SemanticVersion.parse(" 1.6.0+20261121 ") == SemanticVersion(major: 1, minor: 6, patch: 0))
        #expect(SemanticVersion.parse("1.6.0-beta.2") == SemanticVersion(major: 1, minor: 6, patch: 0, prerelease: ["beta", "2"]))
        #expect(SemanticVersion.parse("v1.5.2")?.displayTag == "v1.5.2")

        #expect(SemanticVersion.parse("") == nil)
        #expect(SemanticVersion.parse("v") == nil)
        #expect(SemanticVersion.parse("1") == nil)
        #expect(SemanticVersion.parse("1.2.3.4") == nil)
        #expect(SemanticVersion.parse("1.2.x") == nil)
        #expect(SemanticVersion.parse("1.2.3-") == nil)
        #expect(SemanticVersion.parse("1.2.3-beta..1") == nil)
    }

    @Test("SemanticVersion comparison follows SemVer 2.0 precedence")
    func semanticVersionOrdering() {
        let v152 = SemanticVersion.parse("1.5.2")!
        let v160Beta1 = SemanticVersion.parse("1.6.0-beta.1")!
        let v160Beta2 = SemanticVersion.parse("1.6.0-beta.2")!
        let v160Beta10 = SemanticVersion.parse("1.6.0-beta.10")!
        let v160 = SemanticVersion.parse("1.6.0")!
        let v200 = SemanticVersion.parse("2.0.0")!

        #expect(v152 < v160Beta1)
        #expect(v160Beta1 < v160Beta2)
        #expect(v160Beta2 < v160Beta10)
        #expect(v160Beta10 < v160)
        #expect(v160 < v200)
        #expect(!(v160 < v160))
    }

    // MARK: - Release Parsers

    @Test("parseRedirectURL accepts GitHub tag redirects and rejects spoofed or prerelease URLs")
    func parseRedirectURL() {
        let parsed = UpdateReleaseParser.parseRedirectURL("https://github.com/kuen54/AGYMonitor/releases/tag/v1.6.0")
        #expect(parsed?.version == SemanticVersion(major: 1, minor: 6, patch: 0))
        #expect(parsed?.tag == "v1.6.0")
        #expect(parsed?.releasePageURLString == "https://github.com/kuen54/AGYMonitor/releases/tag/v1.6.0")

        let relative = UpdateReleaseParser.parseRedirectURL("/kuen54/AGYMonitor/releases/tag/v1.6.1")
        #expect(relative?.version == SemanticVersion(major: 1, minor: 6, patch: 1))

        // Reject spoofed host, wrong repo, prerelease, non-tag redirect
        #expect(UpdateReleaseParser.parseRedirectURL("https://evil.example/kuen54/AGYMonitor/releases/tag/v9.9.9") == nil)
        #expect(UpdateReleaseParser.parseRedirectURL("https://github.com/other/AGYMonitor/releases/tag/v1.6.0") == nil)
        #expect(UpdateReleaseParser.parseRedirectURL("https://github.com/kuen54/AGYMonitor/releases/tag/v1.6.0-rc.1") == nil)
        #expect(UpdateReleaseParser.parseRedirectURL("https://github.com/kuen54/AGYMonitor/releases") == nil)
    }

    @Test("parseGitHubReleaseJSON parses published release with DMG asset and rejects draft/prerelease")
    func parseGitHubReleaseJSON() {
        let json = """
        {
          "tag_name": "v1.6.0",
          "draft": false,
          "prerelease": false,
          "html_url": "https://github.com/kuen54/AGYMonitor/releases/tag/v1.6.0",
          "published_at": "2026-11-21T12:00:00Z",
          "body": "## Highlights\\n- Added automatic update notifications\\n- Bug fixes",
          "assets": [
            {
              "name": "AGYMonitor.dmg",
              "browser_download_url": "https://github.com/kuen54/AGYMonitor/releases/download/v1.6.0/AGYMonitor.dmg"
            }
          ]
        }
        """.data(using: .utf8)!

        let info = UpdateReleaseParser.parseGitHubReleaseJSON(json)
        #expect(info?.version == SemanticVersion(major: 1, minor: 6, patch: 0))
        #expect(info?.downloadURLString == "https://github.com/kuen54/AGYMonitor/releases/download/v1.6.0/AGYMonitor.dmg")
        #expect(info?.summary == "Added automatic update notifications")
        #expect(info?.publishedAt != nil)

        let draftJSON = #"{"tag_name":"v1.7.0","draft":true,"prerelease":false}"#.data(using: .utf8)!
        #expect(UpdateReleaseParser.parseGitHubReleaseJSON(draftJSON) == nil)

        let preJSON = #"{"tag_name":"v1.7.0","draft":false,"prerelease":true}"#.data(using: .utf8)!
        #expect(UpdateReleaseParser.parseGitHubReleaseJSON(preJSON) == nil)

        // Spoofed html_url / asset URL are sanitized/ignored
        let spoofJSON = """
        {
          "tag_name": "v1.6.0",
          "draft": false,
          "prerelease": false,
          "html_url": "https://evil.example/phish",
          "assets": [
            {"name": "AGYMonitor.dmg", "browser_download_url": "https://evil.example/AGYMonitor.dmg"}
          ]
        }
        """.data(using: .utf8)!
        let sanitized = UpdateReleaseParser.parseGitHubReleaseJSON(spoofJSON)
        #expect(sanitized?.releasePageURLString == "https://github.com/kuen54/AGYMonitor/releases/tag/v1.6.0")
        #expect(sanitized?.downloadURLString == nil)
    }

    // MARK: - State Machine Lifecycle & Notification Semantics

    @Test("Launch schedules check after launchDelay when never checked, or remaining interval when recent")
    func launchScheduling() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        var fresh = UpdateCheckerState(currentVersion: SemanticVersion(major: 1, minor: 5, patch: 2))
        let freshEffects = UpdateCheckerMachine.reduce(&fresh, event: .start(now: now))
        #expect(freshEffects == [.scheduleAutoCheck(afterSeconds: UpdateTiming.launchDelay)])

        // Duplicate start is a no-op
        #expect(UpdateCheckerMachine.reduce(&fresh, event: .start(now: now)).isEmpty)

        // Recently checked 4 hours ago -> waits remaining 20 hours
        var recent = UpdateCheckerState(
            currentVersion: SemanticVersion(major: 1, minor: 5, patch: 2),
            lastCheckAt: now.addingTimeInterval(-4 * 3600)
        )
        let recentEffects = UpdateCheckerMachine.reduce(&recent, event: .start(now: now))
        #expect(recentEffects == [.scheduleAutoCheck(afterSeconds: 20 * 3600)])

        // Auto-check disabled -> schedules nothing
        var disabled = UpdateCheckerState(
            currentVersion: SemanticVersion(major: 1, minor: 5, patch: 2),
            autoCheckEnabled: false
        )
        #expect(UpdateCheckerMachine.reduce(&disabled, event: .start(now: now)).isEmpty)
    }

    @Test("Automatic discovery notifies ONCE per version and shows in-app banner")
    func automaticDiscoveryOneTimeNotification() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var state = UpdateCheckerState(currentVersion: SemanticVersion(major: 1, minor: 5, patch: 2))
        _ = UpdateCheckerMachine.reduce(&state, event: .start(now: t0))

        // Tick triggers automatic fetch (generation 1)
        let tickEffects = UpdateCheckerMachine.reduce(&state, event: .periodicTick(now: t0))
        #expect(tickEffects == [.performFetch(generation: 1, trigger: .automatic)])
        // Automatic checking stays silent in-app
        #expect(state.bannerDisplay == .none)

        let release160 = makeRelease("v1.6.0")
        let doneEffects = UpdateCheckerMachine.reduce(
            &state,
            event: .checkCompleted(generation: 1, result: .release(release160), now: t0)
        )
        #expect(doneEffects.contains(.postSystemNotification(release160)))
        #expect(doneEffects.contains(.persistNotifiedVersion("1.6.0")))
        #expect(doneEffects.contains(.persistLatestReleaseTag("v1.6.0")))
        #expect(doneEffects.contains(.persistLastCheckAt(t0)))
        #expect(doneEffects.contains(.scheduleAutoCheck(afterSeconds: UpdateTiming.autoCheckInterval)))
        #expect(state.notifiedVersion == "1.6.0")
        #expect(state.bannerDisplay == .available(release160))

        // 24h later, same v1.6.0 -> NO duplicate system notification, banner still visible
        let t1 = t0.addingTimeInterval(UpdateTiming.autoCheckInterval + 5)
        let tick2 = UpdateCheckerMachine.reduce(&state, event: .periodicTick(now: t1))
        #expect(tick2 == [.performFetch(generation: 2, trigger: .automatic)])
        let done2 = UpdateCheckerMachine.reduce(
            &state,
            event: .checkCompleted(generation: 2, result: .release(release160), now: t1)
        )
        #expect(!done2.contains(.postSystemNotification(release160)))
        #expect(state.bannerDisplay == .available(release160))
    }

    @Test("Skipping a version hides banner until a newer version arrives or user manually checks")
    func skipVersionResurfaceAndManualOverride() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var state = UpdateCheckerState(
            currentVersion: SemanticVersion(major: 1, minor: 5, patch: 2),
            notifiedVersion: "1.6.0",
            cachedLatestTag: "v1.6.0"
        )
        #expect(state.showsAvailableBanner)

        // Dismiss/skip v1.6.0
        let dismissEffects = UpdateCheckerMachine.reduce(&state, event: .dismissAvailableUpdate)
        #expect(dismissEffects == [.persistSkippedVersion("1.6.0")])
        #expect(!state.showsAvailableBanner)
        #expect(state.bannerDisplay == .none)
        // availableUpdate still reflects v1.6.0 so Options menu can still offer it
        #expect(state.availableUpdate?.version == SemanticVersion(major: 1, minor: 6, patch: 0))

        // Manual check un-skips v1.6.0 and displays the banner without firing a duplicate notification
        let manualEffects = UpdateCheckerMachine.reduce(&state, event: .manualCheckRequested(now: t0))
        #expect(manualEffects.contains(.performFetch(generation: 1, trigger: .manual)))
        #expect(state.bannerDisplay == .checking)

        let release160 = makeRelease("v1.6.0")
        let manualDone = UpdateCheckerMachine.reduce(
            &state,
            event: .checkCompleted(generation: 1, result: .release(release160), now: t0)
        )
        #expect(manualDone.contains(.persistSkippedVersion(nil)))
        #expect(!manualDone.contains(.postSystemNotification(release160)))
        #expect(state.bannerDisplay == .available(release160))

        // Skip v1.6.0 again, then automatic check finds v1.6.1 -> resurfaces banner AND posts one-time notification
        _ = UpdateCheckerMachine.reduce(&state, event: .dismissAvailableUpdate)
        _ = UpdateCheckerMachine.reduce(&state, event: .start(now: t0))
        let t1 = t0.addingTimeInterval(UpdateTiming.autoCheckInterval + 10)
        _ = UpdateCheckerMachine.reduce(&state, event: .periodicTick(now: t1))
        let release161 = makeRelease("v1.6.1")
        let nextEffects = UpdateCheckerMachine.reduce(
            &state,
            event: .checkCompleted(generation: 2, result: .release(release161), now: t1)
        )
        #expect(nextEffects.contains(.postSystemNotification(release161)))
        #expect(nextEffects.contains(.persistNotifiedVersion("1.6.1")))
        #expect(state.bannerDisplay == .available(release161))
    }

    @Test("Cached latest release tag clears automatically once user upgrades to that version")
    func cachedTagClearsAfterUpgrade() {
        let upgraded = UpdateCheckerState(
            currentVersion: SemanticVersion(major: 1, minor: 6, patch: 0),
            notifiedVersion: "1.6.0",
            cachedLatestTag: "v1.6.0"
        )
        #expect(upgraded.phase == .idle)
        #expect(upgraded.availableUpdate == nil)
        #expect(upgraded.bannerDisplay == .none)
    }

    @Test("Manual up-to-date and failure show transient feedback while automatic failures remain silent")
    func manualVsAutomaticFeedback() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var state = UpdateCheckerState(currentVersion: SemanticVersion(major: 1, minor: 5, patch: 2))
        _ = UpdateCheckerMachine.reduce(&state, event: .start(now: t0))

        // Automatic failure stays silent, does not persist lastCheckAt, and schedules retry
        _ = UpdateCheckerMachine.reduce(&state, event: .periodicTick(now: t0))
        let autoFail = UpdateCheckerMachine.reduce(
            &state,
            event: .checkCompleted(generation: 1, result: .failure("offline"), now: t0)
        )
        #expect(state.bannerDisplay == .none)
        #expect(state.lastCheckAt == nil)
        #expect(autoFail == [.scheduleAutoCheck(afterSeconds: UpdateTiming.failureRetryInterval)])

        // Manual up-to-date shows transient banner and clears after timeout
        _ = UpdateCheckerMachine.reduce(&state, event: .manualCheckRequested(now: t0))
        let sameRelease = makeRelease("v1.5.2")
        let manualUpToDate = UpdateCheckerMachine.reduce(
            &state,
            event: .checkCompleted(generation: 2, result: .release(sameRelease), now: t0)
        )
        #expect(state.bannerDisplay == .upToDate(SemanticVersion(major: 1, minor: 5, patch: 2)))
        #expect(manualUpToDate.contains(.scheduleTransientFeedbackClear(afterSeconds: UpdateTiming.transientFeedbackDuration)))
        #expect(manualUpToDate.contains(.persistLatestReleaseTag(nil)))

        _ = UpdateCheckerMachine.reduce(&state, event: .clearTransientFeedback)
        #expect(state.bannerDisplay == .none)
        #expect(state.phase == .idle)

        // Manual failure shows transient failure banner and clears
        _ = UpdateCheckerMachine.reduce(&state, event: .manualCheckRequested(now: t0.addingTimeInterval(10)))
        let manualFail = UpdateCheckerMachine.reduce(
            &state,
            event: .checkCompleted(generation: 3, result: .failure("timeout"), now: t0.addingTimeInterval(10))
        )
        #expect(state.bannerDisplay == .failed)
        #expect(manualFail.contains(.scheduleTransientFeedbackClear(afterSeconds: UpdateTiming.transientFeedbackDuration)))

        _ = UpdateCheckerMachine.reduce(&state, event: .clearTransientFeedback)
        #expect(state.bannerDisplay == .none)
    }

    @Test("Stop invalidates in-flight generations and wake schedules delayed check only when overdue")
    func stopGenerationAndWakeSemantics() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var state = UpdateCheckerState(currentVersion: SemanticVersion(major: 1, minor: 5, patch: 2))
        _ = UpdateCheckerMachine.reduce(&state, event: .start(now: t0))
        _ = UpdateCheckerMachine.reduce(&state, event: .periodicTick(now: t0))
        #expect(state.checkGeneration == 1)

        // Stop bumps generation and cancels timers
        let stopEffects = UpdateCheckerMachine.reduce(&state, event: .stop)
        #expect(stopEffects == [.cancelAutoCheck, .cancelTransientFeedbackClear])
        #expect(state.phase == .idle)

        // Late completion from generation 1 is dropped cleanly
        let staleEffects = UpdateCheckerMachine.reduce(
            &state,
            event: .checkCompleted(generation: 1, result: .release(makeRelease("v1.9.0")), now: t0)
        )
        #expect(staleEffects.isEmpty)
        #expect(state.availableUpdate == nil)

        // Restart with recent lastCheckAt: wake does nothing; wake after 24h schedules 10s check
        state.lastCheckAt = t0
        _ = UpdateCheckerMachine.reduce(&state, event: .start(now: t0))
        #expect(UpdateCheckerMachine.reduce(&state, event: .wake(now: t0.addingTimeInterval(3600))).isEmpty)
        let overdueWake = UpdateCheckerMachine.reduce(
            &state,
            event: .wake(now: t0.addingTimeInterval(UpdateTiming.autoCheckInterval + 1))
        )
        #expect(overdueWake == [.scheduleAutoCheck(afterSeconds: UpdateTiming.launchDelay)])
    }

    @Test("Known available release is preserved across offline automatic retries and manual failures")
    func knownReleaseSurvivesOfflineChecks() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let release160 = makeRelease("v1.6.0")
        var state = UpdateCheckerState(
            currentVersion: SemanticVersion(major: 1, minor: 5, patch: 2),
            lastCheckAt: t0.addingTimeInterval(-UpdateTiming.autoCheckInterval - 10),
            notifiedVersion: "1.6.0",
            cachedLatestTag: "v1.6.0"
        )
        _ = UpdateCheckerMachine.reduce(&state, event: .start(now: t0))
        #expect(state.bannerDisplay == .available(release160))

        // 24h automatic re-check runs offline -> banner NEVER flickers or disappears
        _ = UpdateCheckerMachine.reduce(&state, event: .periodicTick(now: t0))
        #expect(state.bannerDisplay == .available(release160))
        _ = UpdateCheckerMachine.reduce(
            &state,
            event: .checkCompleted(generation: 1, result: .failure("offline"), now: t0)
        )
        #expect(state.bannerDisplay == .available(release160))
        #expect(state.availableUpdate == release160)

        // Manual re-check while offline shows transient checking -> failed -> restores available banner
        _ = UpdateCheckerMachine.reduce(&state, event: .manualCheckRequested(now: t0.addingTimeInterval(10)))
        #expect(state.bannerDisplay == .checking)
        #expect(state.availableUpdate == release160)
        _ = UpdateCheckerMachine.reduce(
            &state,
            event: .checkCompleted(generation: 2, result: .failure("offline"), now: t0.addingTimeInterval(11))
        )
        #expect(state.bannerDisplay == .failed)
        _ = UpdateCheckerMachine.reduce(&state, event: .clearTransientFeedback)
        #expect(state.bannerDisplay == .available(release160))
        #expect(state.phase == .available(release160))
    }

    @Test("Manual check cooldown throttles rapid repeat clicks within 3 seconds")
    func manualCooldownThrottlesRapidClicks() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var state = UpdateCheckerState(currentVersion: SemanticVersion(major: 1, minor: 5, patch: 2))

        let first = UpdateCheckerMachine.reduce(&state, event: .manualCheckRequested(now: t0))
        #expect(first.contains(.performFetch(generation: 1, trigger: .manual)))

        // Fast completion in 0.9s
        _ = UpdateCheckerMachine.reduce(
            &state,
            event: .checkCompleted(generation: 1, result: .release(makeRelease("v1.5.2")), now: t0.addingTimeInterval(0.9))
        )

        // Click again at t0 + 1.5s (< 3s cooldown) -> ignored
        let rapid = UpdateCheckerMachine.reduce(&state, event: .manualCheckRequested(now: t0.addingTimeInterval(1.5)))
        #expect(rapid.isEmpty)

        // Click again at t0 + 3.5s (>= 3s cooldown) -> executes
        let allowed = UpdateCheckerMachine.reduce(&state, event: .manualCheckRequested(now: t0.addingTimeInterval(3.5)))
        #expect(allowed.contains(.performFetch(generation: 2, trigger: .manual)))
    }

    @Test("isManualChecking is true ONLY during manual checks so silent background checks never disable context menu")
    func isManualCheckingDistinguishesAutomaticVsManual() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var state = UpdateCheckerState(currentVersion: SemanticVersion(major: 1, minor: 5, patch: 2))
        #expect(!state.isChecking)
        #expect(!state.isManualChecking)

        // Start & trigger automatic background check
        _ = UpdateCheckerMachine.reduce(&state, event: .start(now: t0))
        _ = UpdateCheckerMachine.reduce(&state, event: .periodicTick(now: t0))
        #expect(state.isChecking)
        #expect(!state.isManualChecking) // MUST stay false for automatic background check!

        // Complete automatic check
        _ = UpdateCheckerMachine.reduce(
            &state,
            event: .checkCompleted(generation: 1, result: .noReleaseFound, now: t0)
        )
        #expect(!state.isChecking)
        #expect(!state.isManualChecking)

        // Manual check flips BOTH isChecking and isManualChecking true
        _ = UpdateCheckerMachine.reduce(&state, event: .manualCheckRequested(now: t0))
        #expect(state.isChecking)
        #expect(state.isManualChecking)

        // Stop cancels manual check and resets isManualChecking
        _ = UpdateCheckerMachine.reduce(&state, event: .stop)
        #expect(!state.isChecking)
        #expect(!state.isManualChecking)
    }

    @Test("isAllowedReleaseURL and SemanticVersion reject traversal, encoded segments, userinfo/port, and malicious build metadata")
    func releaseURLAndBuildMetadataHardening() {
        // Valid release & asset URLs
        #expect(UpdateReleaseParser.isAllowedReleaseURL("https://github.com/kuen54/AGYMonitor/releases/tag/v2.0.0"))
        #expect(UpdateReleaseParser.isAllowedReleaseURL("https://github.com/kuen54/AGYMonitor/releases/download/v2.0.0/AGYMonitor.dmg"))
        #expect(UpdateReleaseParser.isAllowedReleaseURL("https://github.com/kuen54/AGYMonitor/releases/latest"))

        // Reject bare /releases without trailing subpath, userinfo, and explicit port
        #expect(!UpdateReleaseParser.isAllowedReleaseURL("https://github.com/kuen54/AGYMonitor/releases"))
        #expect(!UpdateReleaseParser.isAllowedReleaseURL("https://github.com/kuen54/AGYMonitor/releases/"))
        #expect(!UpdateReleaseParser.isAllowedReleaseURL("https://user@github.com/kuen54/AGYMonitor/releases/tag/v2.0.0"))
        #expect(!UpdateReleaseParser.isAllowedReleaseURL("https://user:pass@github.com/kuen54/AGYMonitor/releases/tag/v2.0.0"))
        #expect(!UpdateReleaseParser.isAllowedReleaseURL("https://github.com:443/kuen54/AGYMonitor/releases/tag/v2.0.0"))
        #expect(!UpdateReleaseParser.isAllowedReleaseURL("https://github.com:8443/kuen54/AGYMonitor/releases/tag/v2.0.0"))

        // Reject dot segments, percent-encoded dot/slash/backslash, and backslashes
        #expect(!UpdateReleaseParser.isAllowedReleaseURL("https://github.com/kuen54/AGYMonitor/releases/tag/../../evil/repo"))
        #expect(!UpdateReleaseParser.isAllowedReleaseURL("https://github.com/kuen54/AGYMonitor/releases/./tag/v2.0.0"))
        #expect(!UpdateReleaseParser.isAllowedReleaseURL("https://github.com/kuen54/AGYMonitor/releases/%2e%2e/evil"))
        #expect(!UpdateReleaseParser.isAllowedReleaseURL("https://github.com/kuen54/AGYMonitor/releases/%2E%2E/evil"))
        #expect(!UpdateReleaseParser.isAllowedReleaseURL("https://github.com/kuen54/AGYMonitor/releases/tag/v2.0.0%2f..%2fevil"))
        #expect(!UpdateReleaseParser.isAllowedReleaseURL("https://github.com/kuen54/AGYMonitor/releases/tag/v2.0.0%2F.."))
        #expect(!UpdateReleaseParser.isAllowedReleaseURL("https://github.com/kuen54/AGYMonitor/releases/tag/v2.0.0%5cevil"))
        #expect(!UpdateReleaseParser.isAllowedReleaseURL("https://github.com/kuen54/AGYMonitor/releases/tag/v2.0.0%5Cevil"))
        #expect(!UpdateReleaseParser.isAllowedReleaseURL("https://github.com/kuen54/AGYMonitor/releases/tag/v2.0.0\\evil"))

        // Valid SemVer + build metadata
        #expect(SemanticVersion.parse("v2.0.0+20261123") == SemanticVersion(major: 2, minor: 0, patch: 0))
        #expect(SemanticVersion.parse("2.0.0+exp.sha.5114f85-rc1") == SemanticVersion(major: 2, minor: 0, patch: 0))
        #expect(UpdateReleaseParser.releasePageURLString(forTag: "v2.0.0+20261123") == "https://github.com/kuen54/AGYMonitor/releases/tag/v2.0.0+20261123")

        // Reject empty or malicious + build metadata tags
        #expect(SemanticVersion.parse("2.0.0+") == nil)
        #expect(SemanticVersion.parse("v2.0.0+../../evil/repo") == nil)
        #expect(SemanticVersion.parse("v2.0.0+foo/bar") == nil)
        #expect(SemanticVersion.parse("v2.0.0+a..b") == nil)
        #expect(SemanticVersion.parse("v2.0.0+.leading") == nil)
        #expect(SemanticVersion.parse("v2.0.0+trailing.") == nil)
        #expect(SemanticVersion.parse("v2.0.0+has space") == nil)
        #expect(SemanticVersion.parse("v2.0.0+a?b=c") == nil)
        #expect(SemanticVersion.parse("v2.0.0+a#frag") == nil)
        #expect(UpdateReleaseParser.releasePageURLString(forTag: "v2.0.0+../../evil") == nil)

        // Malicious tag_name in GitHub JSON or cachedLatestTag is rejected cleanly
        let maliciousJSON = #"{"tag_name":"v2.0.0+../../../attacker/repo","draft":false,"prerelease":false}"#.data(using: .utf8)!
        #expect(UpdateReleaseParser.parseGitHubReleaseJSON(maliciousJSON) == nil)

        let cachedMalicious = UpdateCheckerState(
            currentVersion: SemanticVersion(major: 1, minor: 9, patch: 0),
            cachedLatestTag: "v2.0.0+../../../attacker/repo"
        )
        #expect(cachedMalicious.availableUpdate == nil)
        #expect(cachedMalicious.phase == .idle)
    }
}
