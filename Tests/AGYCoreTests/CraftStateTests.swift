import Foundation
import Testing
@testable import AGYCore

@Suite("Core_CraftState")
struct CraftStateTests {

    // MARK: - CraftPreferences

    @Test("CraftPreferences defaults, Codable round-trip, and partial JSON fallback")
    func craftPreferencesCodableRoundTrip() throws {
        let def = CraftPreferences.default
        #expect(def.hapticsEnabled == true)
        #expect(def.acousticChimesEnabled == false)
        #expect(def.dailyWallpaperEnabled == false)
        #expect(def.wallpaperStyle == .darkMonolith)
        #expect(def.lastWallpaperDateKey == nil)
        #expect(def.previousWallpaperPath == nil)

        let custom = CraftPreferences(
            hapticsEnabled: false,
            acousticChimesEnabled: true,
            dailyWallpaperEnabled: true,
            wallpaperStyle: .lightGallery,
            lastWallpaperDateKey: "2026-11-22",
            previousWallpaperPath: "/Users/test/Pictures/orig.png"
        )
        let data = try JSONEncoder().encode(custom)
        let decoded = try JSONDecoder().decode(CraftPreferences.self, from: data)
        #expect(decoded == custom)

        // Forward-compatible decoding from minimal JSON falls back to defaults
        let emptyDecoded = try JSONDecoder().decode(CraftPreferences.self, from: Data("{}".utf8))
        #expect(emptyDecoded == CraftPreferences.default)
    }

    // MARK: - AcousticTriggerState

    @Test("AcousticTriggerState stays silent on startup baseline, fires on new edges, and prioritizes waitingPing")
    func acousticTriggerEdgeDetectionAndPriority() {
        var state = AcousticTriggerState()

        // First call seeds baseline — never chimes on startup even if sessions are already waiting/done
        let bootCue = state.update(waitingIds: ["w1"], doneUnseenIds: ["d1"])
        #expect(bootCue == nil)
        #expect(state.hasBaseline == true)

        // Steady state: no new IDs -> nil
        #expect(state.update(waitingIds: ["w1"], doneUnseenIds: ["d1"]) == nil)

        // New done-unseen session -> .turnDoneChord
        #expect(state.update(waitingIds: ["w1"], doneUnseenIds: ["d1", "d2"]) == .turnDoneChord)

        // Simultaneous new waiting AND new done -> .waitingPing takes higher priority
        #expect(state.update(waitingIds: ["w1", "w2"], doneUnseenIds: ["d1", "d2", "d3"]) == .waitingPing)

        // Next tick with same sets -> nil (d3 was already absorbed into baseline)
        #expect(state.update(waitingIds: ["w1", "w2"], doneUnseenIds: ["d1", "d2", "d3"]) == nil)

        // Removing an ID does not chime; re-entering later DOES chime
        #expect(state.update(waitingIds: ["w1"], doneUnseenIds: ["d1"]) == nil)
        #expect(state.update(waitingIds: ["w1", "w2"], doneUnseenIds: ["d1"]) == .waitingPing)
    }

    @Test("AcousticTriggerState ignores pre-scan emissions and supports clean reset()")
    func acousticTriggerInitialScanGuardAndReset() {
        var state = AcousticTriggerState()

        // Pre-scan Combine emissions must NOT seed baseline or chime
        #expect(state.update(waitingIds: [], doneUnseenIds: [], hasCompletedInitialScan: false) == nil)
        #expect(state.hasBaseline == false)
        #expect(state.update(waitingIds: ["w1"], doneUnseenIds: ["d1"], hasCompletedInitialScan: false) == nil)
        #expect(state.hasBaseline == false)

        // First post-scan emission seeds baseline silently
        #expect(state.update(waitingIds: ["w1"], doneUnseenIds: ["d1"], hasCompletedInitialScan: true) == nil)
        #expect(state.hasBaseline == true)

        // Subsequent new edge fires
        #expect(state.update(waitingIds: ["w1", "w2"], doneUnseenIds: ["d1"], hasCompletedInitialScan: true) == .waitingPing)

        // reset() returns to un-baselined state so next post-scan update seeds silently again
        state.reset()
        #expect(state.hasBaseline == false)
        #expect(state.lastWaitingIds.isEmpty)
        #expect(state.lastDoneUnseenIds.isEmpty)
        #expect(state.update(waitingIds: ["w1", "w2"], doneUnseenIds: ["d1"], hasCompletedInitialScan: true) == nil)
        #expect(state.hasBaseline == true)
    }

    // MARK: - HapticCadenceMachine

    @Test("HapticCadenceMachine covers all 19 cues, fires at now=0, honors salient interrupt floor & generation guard")
    func hapticCadenceTransitions() {
        #expect(InstrumentHapticCue.allCases.count == 19)
        for cue in InstrumentHapticCue.allCases {
            let r = HapticCadenceMachine.recipe(for: cue)
            #expect(r.minInterval > 0)
        }

        // Initial-fire bug fix: lastFiredAt == nil fires immediately even at now == 0.0
        var state = HapticCadenceState()
        let e0 = HapticCadenceMachine.reduce(&state, event: .perform(cue: .chronometerCrown, enabled: true, now: 0.0))
        #expect(e0 == [.cancelFollowUp, .trigger(.alignment)])
        #expect(state.lastFiredAt == 0.0)
        #expect(state.lastCue == .chronometerCrown)

        // Throttled within chronometerCrown minInterval (0.035)
        let eThrottled = HapticCadenceMachine.reduce(&state, event: .perform(cue: .chronometerCrown, enabled: true, now: 0.020))
        #expect(eThrottled.isEmpty)
        #expect(state.lastFiredAt == 0.0)

        // Salient landmark (.chronometerPin) cuts through different scrub cue at >= 0.018s
        let eSalientTooSoon = HapticCadenceMachine.reduce(&state, event: .perform(cue: .chronometerPin, enabled: true, now: 0.010))
        #expect(eSalientTooSoon.isEmpty)
        let eSalient = HapticCadenceMachine.reduce(&state, event: .perform(cue: .chronometerPin, enabled: true, now: 0.018))
        #expect(eSalient == [.cancelFollowUp, .trigger(.levelChange)])
        #expect(state.lastCue == .chronometerPin)

        // Same salient cue obeys its own minInterval (0.065), NOT 0.018
        let eSameSalient = HapticCadenceMachine.reduce(&state, event: .perform(cue: .chronometerPin, enabled: true, now: 0.050))
        #expect(eSameSalient.isEmpty)

        // Double-tap cadence (.radarAlertLock) schedules follow-up with monotonic generation
        let eDouble = HapticCadenceMachine.reduce(&state, event: .perform(cue: .radarAlertLock, enabled: true, now: 0.200))
        let gen1 = state.cadenceGeneration
        #expect(eDouble == [
            .cancelFollowUp,
            .trigger(.alignment),
            .scheduleFollowUp(generation: gen1, pattern: .levelChange, delay: 0.055),
        ])

        // Matching followUpFired triggers once, duplicate delivery is ignored
        let eFollow = HapticCadenceMachine.reduce(&state, event: .followUpFired(generation: gen1, pattern: .levelChange))
        #expect(eFollow == [.trigger(.levelChange)])
        let eDup = HapticCadenceMachine.reduce(&state, event: .followUpFired(generation: gen1, pattern: .levelChange))
        #expect(eDup.isEmpty)

        // Double-tap (.orbitalDeficitWarn) cancelled by disabled / cancel invalidates stale followUpFired
        let eWarn = HapticCadenceMachine.reduce(&state, event: .perform(cue: .orbitalDeficitWarn, enabled: true, now: 0.500))
        let gen2 = state.cadenceGeneration
        #expect(eWarn == [
            .cancelFollowUp,
            .trigger(.levelChange),
            .scheduleFollowUp(generation: gen2, pattern: .alignment, delay: 0.060),
        ])
        let eCancel = HapticCadenceMachine.reduce(&state, event: .cancel)
        #expect(eCancel == [.cancelFollowUp])
        #expect(HapticCadenceMachine.reduce(&state, event: .followUpFired(generation: gen2, pattern: .alignment)).isEmpty)

        // Disabled perform emits cancelFollowUp and does not trigger
        let eDisabled = HapticCadenceMachine.reduce(&state, event: .perform(cue: .tabDetent, enabled: false, now: 1.0))
        #expect(eDisabled == [.cancelFollowUp])
    }

    // MARK: - AcousticEngineLifecycleMachine

    @Test("AcousticEngineLifecycleMachine accumulates drain horizon across 3+ rapid chimes and handles teardown/resets")
    func acousticEngineLifecycleAccumulation() {
        var state = AcousticEngineState()

        // Chime 1 at t=10.0 (dur=0.24) -> drainUntil=10.24, after=0.74
        let e1 = AcousticEngineLifecycleMachine.reduce(
            &state,
            event: .play(cue: .turnDoneChord, bufferDuration: 0.24, now: 10.0)
        )
        #expect(e1.count == 2)
        #expect(e1[0] == .ensureGraphAndPlay(.turnDoneChord))
        if case .scheduleTeardown(let g1, let after1) = e1[1] {
            #expect(g1 == 1)
            #expect(abs(after1 - 0.74) < 1e-9)
        } else {
            Issue.record("Expected scheduleTeardown")
        }

        // Chime 2 at t=10.02 (dur=0.24) -> queued back-to-back: drainUntil=10.48, after=0.96
        let e2 = AcousticEngineLifecycleMachine.reduce(
            &state,
            event: .play(cue: .turnDoneChord, bufferDuration: 0.24, now: 10.02)
        )
        #expect(e2.count == 3)
        #expect(e2[0] == .cancelTeardown)
        #expect(e2[1] == .ensureGraphAndPlay(.turnDoneChord))
        if case .scheduleTeardown(let g2, let after2) = e2[2] {
            #expect(g2 == 2)
            #expect(abs(after2 - 0.96) < 1e-9)
        } else {
            Issue.record("Expected scheduleTeardown")
        }

        // Chime 3 at t=10.05 (dur=0.18) -> drainUntil=10.66, after=(10.66 - 10.05) + 0.50 = 1.11
        let e3 = AcousticEngineLifecycleMachine.reduce(
            &state,
            event: .play(cue: .waitingPing, bufferDuration: 0.18, now: 10.05)
        )
        #expect(e3.count == 3)
        if case .scheduleTeardown(let g3, let after3) = e3[2] {
            #expect(g3 == 3)
            #expect(abs(after3 - 1.11) < 1e-9)
        } else {
            Issue.record("Expected scheduleTeardown")
        }
        #expect(state.phase == .active(drainUntil: 10.66, generation: 3))

        // Stale teardowns (gen 1, 2) are no-ops
        #expect(AcousticEngineLifecycleMachine.reduce(&state, event: .teardownFired(generation: 1)).isEmpty)
        #expect(AcousticEngineLifecycleMachine.reduce(&state, event: .teardownFired(generation: 2)).isEmpty)
        #expect(state.phase == .active(drainUntil: 10.66, generation: 3))

        // Matching teardown tears down cleanly to .idle
        #expect(AcousticEngineLifecycleMachine.reduce(&state, event: .teardownFired(generation: 3)) == [.teardownGraph])
        #expect(state.phase == .idle)

        // Configuration changed / disabled / terminate cancel teardown, tear down graph, and reset to .idle
        _ = AcousticEngineLifecycleMachine.reduce(&state, event: .play(cue: .waitingPing, bufferDuration: 0.18, now: 20.0))
        #expect(AcousticEngineLifecycleMachine.reduce(&state, event: .configurationChanged) == [.cancelTeardown, .teardownGraph])
        #expect(state.phase == .idle)

        _ = AcousticEngineLifecycleMachine.reduce(&state, event: .play(cue: .waitingPing, bufferDuration: 0.18, now: 21.0))
        #expect(AcousticEngineLifecycleMachine.reduce(&state, event: .disabled) == [.cancelTeardown, .teardownGraph])
        #expect(state.phase == .idle)

        _ = AcousticEngineLifecycleMachine.reduce(&state, event: .play(cue: .waitingPing, bufferDuration: 0.18, now: 22.0))
        let prevGen = state.generationCounter
        #expect(AcousticEngineLifecycleMachine.reduce(&state, event: .terminate) == [.cancelTeardown, .teardownGraph])
        #expect(state.phase == .idle)
        #expect(AcousticEngineLifecycleMachine.reduce(&state, event: .teardownFired(generation: prevGen)).isEmpty)
    }

    // MARK: - BlueprintWallpaperPath & BlueprintWallpaperMachine

    @Test("BlueprintWallpaperPath enforces strict trailing slash boundary and filename prefix")
    func blueprintWallpaperPathBoundary() {
        let dir = "/Users/test/Library/Application Support/AGYMonitor/wallpapers"
        #expect(BlueprintWallpaperPath.isManagedPath("\(dir)/agy-blueprint-2026-11-22-darkMonolith.png", directoryPath: dir) == true)
        #expect(BlueprintWallpaperPath.isManagedPath("\(dir)/agy-blueprint-2026-11-22-darkMonolith.png", directoryPath: dir + "/") == true)

        // Sibling directory with matching prefix MUST be rejected
        #expect(BlueprintWallpaperPath.isManagedPath("\(dir)-backup/agy-blueprint-2026-11-22.png", directoryPath: dir) == false)
        // Non-blueprint file inside managed dir rejected
        #expect(BlueprintWallpaperPath.isManagedPath("\(dir)/my-photo.png", directoryPath: dir) == false)
        // Nested subdirectory rejected
        #expect(BlueprintWallpaperPath.isManagedPath("\(dir)/sub/agy-blueprint-2026-11-22.png", directoryPath: dir) == false)
        // Parent traversal rejected
        #expect(BlueprintWallpaperPath.isManagedPath("\(dir)/../wallpapers-backup/agy-blueprint-2026-11-22.png", directoryPath: dir) == false)
        // Empty inputs rejected
        #expect(BlueprintWallpaperPath.isManagedPath("", directoryPath: dir) == false)
        #expect(BlueprintWallpaperPath.isManagedPath("\(dir)/agy-blueprint-a.png", directoryPath: "") == false)
    }

    @Test("BlueprintWallpaperMachine handles manual apply without cache, backoff, and restore cleanup")
    func blueprintWallpaperMachineLifecycle() {
        var state = BlueprintWallpaperState()

        // 1. Manual apply without year cache (even with daily disabled) fetches silently then auto-applies
        let e1 = BlueprintWallpaperMachine.reduce(
            &state,
            event: .manualApply(todayKey: "2026-11-22", style: .darkMonolith, hasYearCache: false, now: 100.0)
        )
        #expect(e1 == [.fetchYearDataSilently])
        #expect(state.phase == .awaitingYearData(trigger: .manualApply, style: .darkMonolith, dateKey: "2026-11-22", generation: 1))

        let e2 = BlueprintWallpaperMachine.reduce(&state, event: .yearDataReady(todayKey: "2026-11-22"))
        #expect(e2 == [.renderAndApply(generation: 2, style: .darkMonolith, dateKey: "2026-11-22")])
        #expect(state.phase == .applying(trigger: .manualApply, style: .darkMonolith, dateKey: "2026-11-22", generation: 2))

        // Stale completion ignored
        let eStale = BlueprintWallpaperMachine.reduce(
            &state,
            event: .applyCompleted(generation: 1, succeeded: true, dateKey: "2026-11-22", style: .darkMonolith, capturedPreviousPath: "/orig.png", now: 101.0)
        )
        #expect(eStale.isEmpty)
        #expect(state.isBusy == true)

        // Matching completion persists preferences & captures previous wallpaper once
        let eDone = BlueprintWallpaperMachine.reduce(
            &state,
            event: .applyCompleted(generation: 2, succeeded: true, dateKey: "2026-11-22", style: .darkMonolith, capturedPreviousPath: "/orig.png", now: 102.0)
        )
        #expect(eDone == [.persistPreferences])
        #expect(state.phase == .idle)
        #expect(state.lastAppliedDateKey == "2026-11-22")
        #expect(state.lastAppliedStyle == .darkMonolith)
        #expect(state.previousWallpaperPath == "/orig.png")
        #expect(state.canRestorePrevious == true)

        // 2. Same-day dailyCheck with same style is a no-op
        let eNoop = BlueprintWallpaperMachine.reduce(
            &state,
            event: .dailyCheck(enabled: true, todayKey: "2026-11-22", style: .darkMonolith, hasYearCache: true, now: 110.0)
        )
        #expect(eNoop.isEmpty)

        // 3. Next day dailyCheck failure applies 300s backoff to prevent retry storms
        let eNextDay = BlueprintWallpaperMachine.reduce(
            &state,
            event: .dailyCheck(enabled: true, todayKey: "2026-11-23", style: .darkMonolith, hasYearCache: true, now: 1000.0)
        )
        #expect(eNextDay == [.renderAndApply(generation: 3, style: .darkMonolith, dateKey: "2026-11-23")])
        let eFail = BlueprintWallpaperMachine.reduce(
            &state,
            event: .applyCompleted(generation: 3, succeeded: false, dateKey: "2026-11-23", style: .darkMonolith, capturedPreviousPath: "/should-not-overwrite.png", now: 1005.0)
        )
        #expect(eFail.isEmpty)
        #expect(state.lastFailureAt == 1005.0)
        #expect(state.previousWallpaperPath == "/orig.png")

        // Retry within 300s is suppressed
        #expect(BlueprintWallpaperMachine.reduce(
            &state,
            event: .dailyCheck(enabled: true, todayKey: "2026-11-23", style: .darkMonolith, hasYearCache: true, now: 1200.0)
        ).isEmpty)

        // Retry at >= 300s proceeds
        let eRetry = BlueprintWallpaperMachine.reduce(
            &state,
            event: .dailyCheck(enabled: true, todayKey: "2026-11-23", style: .darkMonolith, hasYearCache: true, now: 1305.0)
        )
        #expect(eRetry == [.renderAndApply(generation: 4, style: .darkMonolith, dateKey: "2026-11-23")])

        // 4. Restore cancels in-flight apply and clears previousWallpaperPath on success
        let eRestoreReq = BlueprintWallpaperMachine.reduce(&state, event: .restoreRequested)
        #expect(eRestoreReq == [.restoreDesktop(path: "/orig.png")])
        #expect(state.phase == .idle)

        // In-flight gen 4 completion is now stale and ignored
        #expect(BlueprintWallpaperMachine.reduce(
            &state,
            event: .applyCompleted(generation: 4, succeeded: true, dateKey: "2026-11-23", style: .darkMonolith, capturedPreviousPath: nil, now: 1306.0)
        ).isEmpty)

        let eRestoreDone = BlueprintWallpaperMachine.reduce(&state, event: .restoreCompleted(succeeded: true, fileMissing: false))
        #expect(eRestoreDone == [.persistPreferences])
        #expect(state.previousWallpaperPath == nil)
        #expect(state.lastAppliedDateKey == nil)
        #expect(state.canRestorePrevious == false)

        // 5. Missing backup file also clears dead previousWallpaperPath
        state.previousWallpaperPath = "/deleted-file.png"
        let eMissing = BlueprintWallpaperMachine.reduce(&state, event: .restoreCompleted(succeeded: false, fileMissing: true))
        #expect(eMissing == [.persistPreferences])
        #expect(state.previousWallpaperPath == nil)

        // 6. styleChanged is ignored when daily disabled, applies when enabled
        #expect(BlueprintWallpaperMachine.reduce(
            &state,
            event: .styleChanged(enabled: false, todayKey: "2026-11-23", style: .lightGallery, hasYearCache: true, now: 1400.0)
        ).isEmpty)
        let eStyle = BlueprintWallpaperMachine.reduce(
            &state,
            event: .styleChanged(enabled: true, todayKey: "2026-11-23", style: .lightGallery, hasYearCache: true, now: 1401.0)
        )
        #expect(eStyle.count == 1)
        if case .renderAndApply(let styleGen, let style, let key) = eStyle[0] {
            #expect(style == .lightGallery)
            #expect(key == "2026-11-23")
            // Stale/deleted previousWallpaperPath gets replaced when shell captures a fresh valid path
            state.previousWallpaperPath = "/Users/me/Pictures/deleted-old.jpg"
            _ = BlueprintWallpaperMachine.reduce(
                &state,
                event: .applyCompleted(
                    generation: styleGen,
                    succeeded: true,
                    dateKey: "2026-11-23",
                    style: .lightGallery,
                    capturedPreviousPath: "/Users/me/Pictures/fresh-active.heic",
                    now: 1402.0
                )
            )
            #expect(state.previousWallpaperPath == "/Users/me/Pictures/fresh-active.heic")
        } else {
            Issue.record("Expected renderAndApply on enabled styleChanged")
        }
    }

    @Test("BlueprintWallpaperMachine cancels in-flight dailyAuto/styleChange renders when toggled OFF while preserving manualApply")
    func blueprintWallpaperToggleOffCancelsAutomaticApplies() {
        var state = BlueprintWallpaperState()

        // 1. In-flight .dailyAuto in .applying is cancelled when daily wallpaper is toggled OFF
        let eDaily = BlueprintWallpaperMachine.reduce(
            &state,
            event: .dailyCheck(enabled: true, todayKey: "2026-11-23", style: .darkMonolith, hasYearCache: true, now: 100.0)
        )
        #expect(eDaily == [.renderAndApply(generation: 1, style: .darkMonolith, dateKey: "2026-11-23")])
        guard case .applying(.dailyAuto, _, _, let dailyGen) = state.phase else {
            Issue.record("Expected .applying(.dailyAuto)")
            return
        }

        let eDisableDaily = BlueprintWallpaperMachine.reduce(
            &state,
            event: .styleChanged(enabled: false, todayKey: "2026-11-23", style: .darkMonolith, hasYearCache: true, now: 101.0)
        )
        #expect(eDisableDaily.isEmpty)
        #expect(state.phase == .idle)
        #expect(state.generationCounter > dailyGen)

        // Late completion from cancelled generation MUST be ignored and MUST NOT persist
        let eStaleDaily = BlueprintWallpaperMachine.reduce(
            &state,
            event: .applyCompleted(
                generation: dailyGen,
                succeeded: true,
                dateKey: "2026-11-23",
                style: .darkMonolith,
                capturedPreviousPath: "/orig.png",
                now: 102.0
            )
        )
        #expect(eStaleDaily.isEmpty)
        #expect(state.lastAppliedDateKey == nil)
        #expect(state.previousWallpaperPath == nil)

        // 2. In-flight .styleChange in .applying is also cancelled when toggled OFF
        let eStyle = BlueprintWallpaperMachine.reduce(
            &state,
            event: .styleChanged(enabled: true, todayKey: "2026-11-23", style: .lightGallery, hasYearCache: true, now: 110.0)
        )
        guard case .renderAndApply(let styleGen, .lightGallery, "2026-11-23") = eStyle.first else {
            Issue.record("Expected renderAndApply on enabled styleChanged")
            return
        }
        let eDisableStyle = BlueprintWallpaperMachine.reduce(
            &state,
            event: .styleChanged(enabled: false, todayKey: "2026-11-23", style: .lightGallery, hasYearCache: true, now: 111.0)
        )
        #expect(eDisableStyle.isEmpty)
        #expect(state.phase == .idle)
        #expect(state.generationCounter > styleGen)
        #expect(BlueprintWallpaperMachine.reduce(
            &state,
            event: .applyCompleted(
                generation: styleGen,
                succeeded: true,
                dateKey: "2026-11-23",
                style: .lightGallery,
                capturedPreviousPath: "/orig.png",
                now: 112.0
            )
        ).isEmpty)

        // 3. Explicit .manualApply in .applying is NOT cancelled when daily toggle is OFF
        let eManual = BlueprintWallpaperMachine.reduce(
            &state,
            event: .manualApply(todayKey: "2026-11-23", style: .darkMonolith, hasYearCache: true, now: 120.0)
        )
        guard case .renderAndApply(let manualGen, .darkMonolith, "2026-11-23") = eManual.first else {
            Issue.record("Expected renderAndApply on manualApply")
            return
        }
        _ = BlueprintWallpaperMachine.reduce(
            &state,
            event: .styleChanged(enabled: false, todayKey: "2026-11-23", style: .lightGallery, hasYearCache: true, now: 121.0)
        )
        #expect(state.phase == .applying(trigger: .manualApply, style: .darkMonolith, dateKey: "2026-11-23", generation: manualGen))
        let eManualDone = BlueprintWallpaperMachine.reduce(
            &state,
            event: .applyCompleted(
                generation: manualGen,
                succeeded: true,
                dateKey: "2026-11-23",
                style: .darkMonolith,
                capturedPreviousPath: "/orig.png",
                now: 122.0
            )
        )
        #expect(eManualDone == [.persistPreferences])
        #expect(state.lastAppliedDateKey == "2026-11-23")
    }

    // MARK: - SpecimenExporterMachine

    @Test("SpecimenExporterMachine preserves aspect/appearance on re-present, guards saving, and pairs feedback atomically")
    func specimenExporterMachineTransitions() {
        var state = SpecimenExporterState()

        #expect(SpecimenAppearanceChoice.system.resolvedIsDark(systemIsDark: true) == true)
        #expect(SpecimenAppearanceChoice.system.resolvedIsDark(systemIsDark: false) == false)
        #expect(SpecimenAppearanceChoice.light.resolvedIsDark(systemIsDark: true) == false)
        #expect(SpecimenAppearanceChoice.dark.resolvedIsDark(systemIsDark: false) == true)

        #expect(SpecimenExporterMachine.reduce(&state, event: .present).isEmpty)
        #expect(state.isPresented == true)

        _ = SpecimenExporterMachine.reduce(&state, event: .setAspect(.landscape16x9))
        _ = SpecimenExporterMachine.reduce(&state, event: .setAppearance(.dark))

        // Re-present while already presented MUST preserve aspect & appearance
        #expect(SpecimenExporterMachine.reduce(&state, event: .present).isEmpty)
        #expect(state.aspect == .landscape16x9)
        #expect(state.appearance == .dark)

        // Copy feedback paired atomically with TransientBannerState token
        let eCopy = SpecimenExporterMachine.reduce(&state, event: .copySucceeded)
        #expect(eCopy == [.scheduleFeedbackDismiss(token: 1, after: SpecimenExporterMachine.feedbackDuration)])
        #expect(state.feedbackKind == .copied)
        #expect(state.feedback.messageKey == "specimenCopied")

        // Second feedback cancels prior dismiss timer and invalidates token 1
        let eFail = SpecimenExporterMachine.reduce(&state, event: .copyFailed)
        #expect(eFail == [.cancelFeedbackDismiss, .scheduleFeedbackDismiss(token: 2, after: SpecimenExporterMachine.feedbackDuration)])
        #expect(state.feedbackKind == .renderFailed)

        // Stale dismiss token 1 is ignored; token 2 clears feedback atomically
        _ = SpecimenExporterMachine.reduce(&state, event: .dismissFeedback(token: 1))
        #expect(state.feedbackKind == .renderFailed)
        _ = SpecimenExporterMachine.reduce(&state, event: .dismissFeedback(token: 2))
        #expect(state.feedbackKind == nil)
        #expect(state.feedback.messageKey == nil)

        // beginSave transitions to .saving; duplicate beginSave is ignored
        #expect(SpecimenExporterMachine.reduce(&state, event: .beginSave) == [.showSavePanel])
        #expect(state.exportPhase == .saving)
        #expect(SpecimenExporterMachine.reduce(&state, event: .beginSave).isEmpty)

        // saveCancelled returns cleanly to .idle without feedback
        #expect(SpecimenExporterMachine.reduce(&state, event: .saveCancelled).isEmpty)
        #expect(state.exportPhase == .idle)
        #expect(state.feedbackKind == nil)

        // saveCompleted(succeeded: true) transitions to .idle and schedules .saved banner
        #expect(SpecimenExporterMachine.reduce(&state, event: .beginSave) == [.showSavePanel])
        let eSaved = SpecimenExporterMachine.reduce(&state, event: .saveCompleted(succeeded: true))
        #expect(state.exportPhase == .idle)
        #expect(state.feedbackKind == .saved)
        #expect(eSaved == [.scheduleFeedbackDismiss(token: 3, after: SpecimenExporterMachine.feedbackDuration)])

        // dismiss clears active banner and cancels pending timer
        #expect(SpecimenExporterMachine.reduce(&state, event: .dismiss) == [.cancelFeedbackDismiss])
        #expect(state.isPresented == false)
        #expect(state.feedbackKind == nil)
        #expect(state.feedback.messageKey == nil)
    }

    // MARK: - DailyWallpaperGate

    @Test("DailyWallpaperGate refreshes only when enabled and date key differs")
    func dailyWallpaperGatePolicy() {
        var prefs = CraftPreferences.default
        #expect(DailyWallpaperGate.shouldRefresh(todayKey: "2026-11-22", preferences: prefs) == false)

        prefs.dailyWallpaperEnabled = true
        #expect(DailyWallpaperGate.shouldRefresh(todayKey: "2026-11-22", preferences: prefs) == true)

        prefs.lastWallpaperDateKey = "2026-11-21"
        #expect(DailyWallpaperGate.shouldRefresh(todayKey: "2026-11-22", preferences: prefs) == true)

        prefs.lastWallpaperDateKey = "2026-11-22"
        #expect(DailyWallpaperGate.shouldRefresh(todayKey: "2026-11-22", preferences: prefs) == false)

        // Sentinel / empty day key never triggers refresh
        prefs.lastWallpaperDateKey = nil
        #expect(DailyWallpaperGate.shouldRefresh(todayKey: "", preferences: prefs) == false)
        #expect(DailyWallpaperGate.shouldRefresh(todayKey: "0001-01-01", preferences: prefs) == false)
    }

    // MARK: - SpecimenLogic.classifyArchetype

    @Test("Classifies all 5 operator archetypes and peak window labels")
    func specimenArchetypeClassification() {
        let bins48 = Array(repeating: 0.0, count: 48)

        // 1. Marathon Operator (>= 120h overrides nocturnal peak)
        let nocturnalProfile = MonthDiurnalProfile(
            bins: bins48,
            maxBinHours: 5.0,
            peakWindowStartBin: 45, // 22:30
            peakWindowEndBin: 49    // 00:30
        )
        let marathon = SpecimenLogic.classifyArchetype(
            diurnalProfile: nocturnalProfile,
            activeHours: 128.5,
            totalInputTokens: 100_000,
            totalCacheReadTokens: 900_000
        )
        #expect(marathon.kind == .marathonOperator)
        #expect(marathon.peakWindowLabel == "22:30–00:30")
        #expect(marathon.cacheGrade == "A+")
        #expect(marathon.cacheHitPercent == 90)

        // 2. Nocturnal Architect (late night >= 21:00 or early morning < 05:00)
        let nocturnalLate = SpecimenLogic.classifyArchetype(
            diurnalProfile: nocturnalProfile,
            activeHours: 48.0,
            totalInputTokens: 150_000,
            totalCacheReadTokens: 850_000
        )
        #expect(nocturnalLate.kind == .nocturnalArchitect)
        #expect(nocturnalLate.peakWindowLabel == "22:30–00:30")

        let afterMidnightProfile = MonthDiurnalProfile(
            bins: bins48,
            maxBinHours: 3.0,
            peakWindowStartBin: 2, // 01:00
            peakWindowEndBin: 6    // 03:00
        )
        let nocturnalEarly = SpecimenLogic.classifyArchetype(
            diurnalProfile: afterMidnightProfile,
            activeHours: 12.0,
            totalInputTokens: 0,
            totalCacheReadTokens: 0
        )
        #expect(nocturnalEarly.kind == .nocturnalArchitect)
        #expect(nocturnalEarly.peakWindowLabel == "01:00–03:00")
        #expect(nocturnalEarly.cacheGrade == "--")
        #expect(nocturnalEarly.cacheHitPercent == nil)

        // 3. Dawn Synthesizer (05:00..<09:00)
        let dawnProfile = MonthDiurnalProfile(
            bins: bins48,
            maxBinHours: 4.0,
            peakWindowStartBin: 12, // 06:00
            peakWindowEndBin: 16    // 08:00
        )
        let dawn = SpecimenLogic.classifyArchetype(
            diurnalProfile: dawnProfile,
            activeHours: 35.0,
            totalInputTokens: 200_000,
            totalCacheReadTokens: 800_000
        )
        #expect(dawn.kind == .dawnSynthesizer)
        #expect(dawn.peakWindowLabel == "06:00–08:00")
        #expect(dawn.cacheGrade == "A")
        #expect(dawn.cacheHitPercent == 80)

        // 4. Daylight Craftsman (09:00..<21:00 with >= 20h)
        let dayProfile = MonthDiurnalProfile(
            bins: bins48,
            maxBinHours: 6.0,
            peakWindowStartBin: 28, // 14:00
            peakWindowEndBin: 32    // 16:00
        )
        let craftsman = SpecimenLogic.classifyArchetype(
            diurnalProfile: dayProfile,
            activeHours: 42.0,
            totalInputTokens: 350_000,
            totalCacheReadTokens: 650_000
        )
        #expect(craftsman.kind == .daylightCraftsman)
        #expect(craftsman.peakWindowLabel == "14:00–16:00")
        #expect(craftsman.cacheGrade == "B+")
        #expect(craftsman.cacheHitPercent == 65)

        // 5. Steady Pilot (daytime < 20h, or empty diurnal profile < 20h)
        let steady = SpecimenLogic.classifyArchetype(
            diurnalProfile: dayProfile,
            activeHours: 14.0,
            totalInputTokens: 550_000,
            totalCacheReadTokens: 450_000
        )
        #expect(steady.kind == .steadyPilot)
        #expect(steady.cacheGrade == "B")
        #expect(steady.cacheHitPercent == 45)

        let emptyProfile = MonthDiurnalProfile(
            bins: bins48,
            maxBinHours: 0,
            peakWindowStartBin: nil,
            peakWindowEndBin: nil
        )
        let emptyPilot = SpecimenLogic.classifyArchetype(
            diurnalProfile: emptyProfile,
            activeHours: 5.0,
            totalInputTokens: 700_000,
            totalCacheReadTokens: 300_000
        )
        #expect(emptyPilot.kind == .steadyPilot)
        #expect(emptyPilot.peakWindowLabel == "--")
        #expect(emptyPilot.cacheGrade == "C")
        #expect(emptyPilot.cacheHitPercent == 30)

        // Rounding boundary: 0.8974 rounds to displayed 90% and must receive A+ (no A + 90% mismatch)
        let boundaryAPlus = SpecimenLogic.classifyArchetype(
            diurnalProfile: nocturnalProfile,
            activeHours: 40.0,
            totalInputTokens: 1_026,
            totalCacheReadTokens: 8_974
        )
        #expect(boundaryAPlus.cacheHitPercent == 90)
        #expect(boundaryAPlus.cacheGrade == "A+")
    }
}
