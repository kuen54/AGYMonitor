import Foundation
import Testing
@testable import AGYCore

@Suite("Core_MonitorState")
struct MonitorStateTests {

    @Test("SessionPollCadence computes backoff intervals and FSEvents retry gating")
    func pollCadenceAndRetry() {
        #expect(SessionPollCadence.interval(started: false, fsHealthy: true, isActive: true, liveCount: 2) == nil)
        #expect(SessionPollCadence.interval(started: true, fsHealthy: true, isActive: true, liveCount: 1) == 2.0)
        #expect(SessionPollCadence.interval(started: true, fsHealthy: true, isActive: false, liveCount: 1) == 6.0)
        #expect(SessionPollCadence.interval(started: true, fsHealthy: true, isActive: false, liveCount: 0) == 15.0)
        #expect(SessionPollCadence.interval(started: true, fsHealthy: false, isActive: false, liveCount: 0) == 6.0)

        let now = Date(timeIntervalSince1970: 1_000)
        #expect(SessionPollCadence.shouldRetryFSWatcher(started: true, fsHealthy: false, now: now, lastAttemptAt: nil))
        #expect(!SessionPollCadence.shouldRetryFSWatcher(started: true, fsHealthy: false, now: now, lastAttemptAt: now.addingTimeInterval(-10)))
        #expect(SessionPollCadence.shouldRetryFSWatcher(started: true, fsHealthy: false, now: now, lastAttemptAt: now.addingTimeInterval(-35)))
        #expect(!SessionPollCadence.shouldRetryFSWatcher(started: true, fsHealthy: true, now: now, lastAttemptAt: nil))
    }

    @Test("FSEventsThrottleState respects manual/wake refreshes in its 120s cooldown floor")
    func fsEventsThrottle() {
        var throttle = FSEventsThrottleState(debounceSeconds: 3.0, minGapSeconds: 120.0)
        let t0 = Date(timeIntervalSince1970: 5_000)
        #expect(throttle.delayForFSEvent(at: t0) == 3.0)

        throttle.noteRefreshTriggered(at: t0)
        #expect(throttle.delayForFSEvent(at: t0.addingTimeInterval(10)) == 110.0)
        #expect(throttle.delayForFSEvent(at: t0.addingTimeInterval(119)) == 3.0)
        #expect(throttle.delayForFSEvent(at: t0.addingTimeInterval(150)) == 3.0)
    }

    @Test("MenuBarAnchorState freezes width/text during popover open, flushes on close, and allows Sessions/Plan without month data")
    func menuBarAnchorAndPublishRules() {
        var anchor = MenuBarAnchorState(initialText: "$1.20", initialWidth: 48, isMenuBarVisible: true)

        anchor.popoverOpened()
        anchor.updateValue("$9.99")
        anchor.updateMeasuredWidth(84)
        #expect(anchor.displayedText == "$1.20")
        #expect(anchor.appliedWidth == 48)

        anchor.popoverClosed()
        #expect(anchor.displayedText == "$9.99")
        #expect(anchor.appliedWidth == 84)

        // Sessions tab (rawValue 4) and Plan tab (rawValue 2 with quota) do not stall on "..."
        #expect(MenuBarAnchorState.shouldPublishMenuBarValue(tabRawValue: 4, hasCurrentMonthData: false, hasSubscriptionQuota: false) == true)
        #expect(MenuBarAnchorState.shouldPublishMenuBarValue(tabRawValue: 2, hasCurrentMonthData: false, hasSubscriptionQuota: true) == true)
        #expect(MenuBarAnchorState.shouldPublishMenuBarValue(tabRawValue: 0, hasCurrentMonthData: false, hasSubscriptionQuota: true) == false)
    }

    @Test("LogoVisualState resolves animation mode and priority dot")
    func logoVisualMatrix() {
        #expect(LogoVisualState.resolve(anyBusy: false, anyWaiting: false, anyDoneUnseen: false, reduceMotion: false)
            == LogoVisualState(animation: .idle, dot: .none))
        #expect(LogoVisualState.resolve(anyBusy: true, anyWaiting: false, anyDoneUnseen: true, reduceMotion: false)
            == LogoVisualState(animation: .levitate, dot: .doneUnseenGreen))
        #expect(LogoVisualState.resolve(anyBusy: true, anyWaiting: true, anyDoneUnseen: true, reduceMotion: true)
            == LogoVisualState(animation: .breatheOpacity, dot: .waitingAmber))
    }

    @Test("SessionSurfaceBadge maps AGY entrypoints cleanly")
    func surfaceBadges() {
        #expect(SessionSurfaceBadge.from(entrypoint: "cli") == .cli)
        #expect(SessionSurfaceBadge.from(entrypoint: "antigravity-cli") == .cli)
        #expect(SessionSurfaceBadge.from(entrypoint: "antigravity") == .desktop)
        #expect(SessionSurfaceBadge.from(entrypoint: "antigravity-ide") == .ide)
        #expect(SessionSurfaceBadge.from(entrypoint: "sdk-cli") == nil)
    }

    @Test("SessionLogic.resolveLiveSessionStatus unifies swarm rollup, swarm_wait idle, ask_question, and recency")
    func canonicalLiveStatus() {
        let now: TimeInterval = 1_700_000_000

        // Coordinator stays busy when swarm worker is busy even if parent transcript is idle
        #expect(SessionLogic.resolveLiveSessionStatus(
            swarmWorkerBusy: true,
            rawStatus: "CASCADE_RUN_STATUS_IDLE",
            notFullyIdle: false,
            transcriptSummary: nil,
            transcriptFileMtime: now - 500,
            now: now
        ) == (.busy, nil))

        // Worker parked on `swarm_wait` only is idle
        let swarmWaitSummary = TranscriptSummary(
            title: "Worker",
            instruction: "Wait",
            lastStepType: .plannerResponse,
            lastStepStatus: .done,
            lastStepAt: Date(timeIntervalSince1970: now - 5),
            pendingToolNames: ["swarm_wait"],
            isWaitingForQuestion: false
        )
        #expect(SessionLogic.resolveLiveSessionStatus(
            swarmWorkerBusy: false,
            rawStatus: nil,
            notFullyIdle: false,
            transcriptSummary: swarmWaitSummary,
            transcriptFileMtime: now - 5,
            now: now
        ) == (.idle, nil))

        // Active ask_question yields .waiting
        let questionSummary = TranscriptSummary(
            title: "Plan",
            instruction: "Choose",
            lastStepType: .plannerResponse,
            lastStepStatus: .done,
            lastStepAt: Date(timeIntervalSince1970: now - 20),
            pendingToolNames: ["ask_question"],
            isWaitingForQuestion: true
        )
        #expect(SessionLogic.resolveLiveSessionStatus(
            swarmWorkerBusy: false,
            rawStatus: nil,
            notFullyIdle: false,
            transcriptSummary: questionSummary,
            transcriptFileMtime: now - 20,
            now: now
        ) == (.waiting, "input needed"))

        // Stale pending tool (>180s) decays cleanly to .idle
        let staleToolSummary = TranscriptSummary(
            title: "Old",
            instruction: "Run",
            lastStepType: .plannerResponse,
            lastStepStatus: .done,
            lastStepAt: Date(timeIntervalSince1970: now - 500),
            pendingToolNames: ["run_command"],
            isWaitingForQuestion: false
        )
        #expect(SessionLogic.resolveLiveSessionStatus(
            swarmWorkerBusy: false,
            rawStatus: nil,
            notFullyIdle: false,
            transcriptSummary: staleToolSummary,
            transcriptFileMtime: now - 500,
            now: now
        ) == (.idle, nil))
    }

    @Test("SessionMonitorLifecycleMachine enforces start/stop idempotency, post-stop scan safety, and poll cadence")
    func sessionMonitorLifecycleReducer() {
        var state = SessionMonitorLifecycleState()
        let t0 = Date(timeIntervalSince1970: 10_000)

        // Events while stopped are strictly no-ops (cannot spawn ps/lsof after stop)
        #expect(SessionMonitorLifecycleMachine.reduce(&state, event: .fsEventReceived).isEmpty)
        #expect(SessionMonitorLifecycleMachine.reduce(&state, event: .fsCoalesceFired(now: t0)).isEmpty)
        #expect(SessionMonitorLifecycleMachine.reduce(&state, event: .pollTimerFired(now: t0)).isEmpty)

        // Start once emits watcher start + initial scan; duplicate start is a no-op
        let startEffects = SessionMonitorLifecycleMachine.reduce(&state, event: .start(now: t0))
        #expect(state.isStarted)
        #expect(startEffects == [.startFSWatcher, .runScan])
        #expect(SessionMonitorLifecycleMachine.reduce(&state, event: .start(now: t0)).isEmpty)

        // Healthy watcher + 0 live sessions + inactive -> 15s poll
        let fsEffects = SessionMonitorLifecycleMachine.reduce(
            &state,
            event: .fsWatcherAttempted(healthy: true, watchedDirs: ["/cli"], at: t0)
        )
        #expect(fsEffects == [.setPollTimer(15.0)])
        #expect(state.watchedDirs == ["/cli"])

        // Scan detects 2 live sessions while inactive -> tightens to 6s
        let scan1 = SessionMonitorLifecycleMachine.reduce(&state, event: .scanCompleted(liveCount: 2))
        #expect(scan1 == [.setPollTimer(6.0)])

        // Panel opens -> active scan -> tightens to 2s
        let activeEffects = SessionMonitorLifecycleMachine.reduce(&state, event: .setActive(true, now: t0.addingTimeInterval(5)))
        #expect(activeEffects == [.runScan])
        let scan2 = SessionMonitorLifecycleMachine.reduce(&state, event: .scanCompleted(liveCount: 2))
        #expect(scan2 == [.setPollTimer(2.0)])

        // Panel closes -> relaxes poll timer (2s -> 6s) WITHOUT emitting a redundant .runScan!
        let inactiveEffects = SessionMonitorLifecycleMachine.reduce(&state, event: .setActive(false, now: t0.addingTimeInterval(6)))
        #expect(inactiveEffects == [.setPollTimer(6.0)])
        #expect(!inactiveEffects.contains(.runScan))

        // Newly added directory triggers .restartFSEvents EVEN when fsHealthy == true (e.g. CLI -> CLI+Desktop)
        let sameDirs = SessionMonitorLifecycleMachine.reduce(&state, event: .reconcileWatchedDirs(["/cli", "/cli"]))
        #expect(sameDirs.isEmpty)
        let addedDir = SessionMonitorLifecycleMachine.reduce(
            &state,
            event: .reconcileWatchedDirs(["/desktop/brain", "/cli"])
        )
        #expect(addedDir == [.restartFSEvents(dirs: ["/cli", "/desktop/brain"])])
        _ = SessionMonitorLifecycleMachine.reduce(
            &state,
            event: .fsWatcherAttempted(healthy: true, watchedDirs: ["/cli", "/desktop/brain"], at: t0.addingTimeInterval(8))
        )
        #expect(state.watchedDirs == ["/cli", "/desktop/brain"])

        // Degraded watcher does not thrash on the exact same failed dir set, and retries after 30s on next timer tick
        _ = SessionMonitorLifecycleMachine.reduce(
            &state,
            event: .fsWatcherAttempted(healthy: false, watchedDirs: ["/cli", "/desktop/brain"], at: t0.addingTimeInterval(10))
        )
        #expect(!state.fsHealthy)
        #expect(state.watchedDirs.isEmpty)
        #expect(SessionMonitorLifecycleMachine.reduce(&state, event: .reconcileWatchedDirs(["/cli", "/desktop/brain"])).isEmpty)
        // Brand-new IDE dir appearing while unhealthy attaches immediately
        #expect(
            SessionMonitorLifecycleMachine.reduce(&state, event: .reconcileWatchedDirs(["/cli", "/desktop/brain", "/ide/brain"]))
                == [.restartFSEvents(dirs: ["/cli", "/desktop/brain", "/ide/brain"])]
        )
        let retryTick = SessionMonitorLifecycleMachine.reduce(&state, event: .pollTimerFired(now: t0.addingTimeInterval(45)))
        #expect(retryTick == [.startFSWatcher, .runScan])

        // All directories disappearing stops watcher cleanly
        _ = SessionMonitorLifecycleMachine.reduce(
            &state,
            event: .fsWatcherAttempted(healthy: true, watchedDirs: ["/cli"], at: t0.addingTimeInterval(46))
        )
        _ = SessionMonitorLifecycleMachine.reduce(&state, event: .scanCompleted(liveCount: 0))
        let emptyDirs = SessionMonitorLifecycleMachine.reduce(&state, event: .reconcileWatchedDirs([]))
        #expect(emptyDirs == [.stopFSWatcher, .setPollTimer(6.0)])
        #expect(state.watchedDirs.isEmpty)

        // Stop tears down coalesce, timer, and FS watcher; late callbacks become no-ops
        let stopEffects = SessionMonitorLifecycleMachine.reduce(&state, event: .stop)
        #expect(!state.isStarted)
        #expect(state.runGeneration == 1)
        #expect(state.watchedDirs.isEmpty)
        #expect(stopEffects == [.cancelFSCoalesce, .setPollTimer(nil), .stopFSWatcher])
        #expect(SessionMonitorLifecycleMachine.reduce(&state, event: .fsCoalesceFired(now: t0.addingTimeInterval(50))).isEmpty)
        #expect(SessionMonitorLifecycleMachine.reduce(&state, event: .reconcileWatchedDirs(["/cli"])).isEmpty)

        // setActive(true) before start() is preserved instead of dropped
        var cold = SessionMonitorLifecycleState()
        #expect(SessionMonitorLifecycleMachine.reduce(&cold, event: .setActive(true, now: t0)).isEmpty)
        #expect(cold.isActive)
        _ = SessionMonitorLifecycleMachine.reduce(&cold, event: .start(now: t0))
        _ = SessionMonitorLifecycleMachine.reduce(&cold, event: .scanCompleted(liveCount: 1))
        #expect(cold.pollInterval == 2.0)
    }

    @Test("BrainWatcherLifecycleMachine cancels pending debounce on manual refresh, reconciles new surfaces, and cleans up on terminate")
    func brainWatcherLifecycleInvariants() {
        var state = BrainWatcherLifecycleState()
        let t0 = Date(timeIntervalSince1970: 20_000)

        let startEff = BrainWatcherLifecycleMachine.reduce(&state, event: .start(candidatePaths: ["/cli/brain"], now: t0))
        #expect(startEff == [.startPeriodicTimer, .startFSWatcher(paths: ["/cli/brain"])])
        _ = BrainWatcherLifecycleMachine.reduce(&state, event: .fsWatcherResult(watchedPaths: ["/cli/brain"], at: t0))
        #expect(state.isWatcherHealthy)

        // FSEvent schedules debounce with generation 1
        let fsEff = BrainWatcherLifecycleMachine.reduce(&state, event: .fsEventReceived(now: t0.addingTimeInterval(10)))
        #expect(fsEff == [.scheduleDebounce(generation: 1, delay: 3.0)])

        // Manual refresh at t0+11 cancels pending debounce AND invalidates generation 1!
        let refEff = BrainWatcherLifecycleMachine.reduce(&state, event: .refreshTriggered(at: t0.addingTimeInterval(11)))
        #expect(refEff == [.cancelDebounce])
        // Stale debounce generation 1 firing MUST be a strict no-op (120s floor protected!)
        #expect(BrainWatcherLifecycleMachine.reduce(&state, event: .debounceFired(generation: 1)).isEmpty)

        // Newly created Desktop/IDE surface reconciles and restarts FSEventStream
        let recEff = BrainWatcherLifecycleMachine.reduce(
            &state,
            event: .reconcileWatchPaths(candidatePaths: ["/cli/brain", "/ide/brain"], now: t0.addingTimeInterval(20))
        )
        #expect(recEff == [.startFSWatcher(paths: ["/cli/brain", "/ide/brain"])])

        // Rapid wake coalesces by generation
        let w1 = BrainWatcherLifecycleMachine.reduce(&state, event: .wakeReceived)
        let w2 = BrainWatcherLifecycleMachine.reduce(&state, event: .wakeReceived)
        #expect(w1 == [.scheduleWakeRefresh(generation: 1, delay: 5.0)])
        #expect(w2 == [.scheduleWakeRefresh(generation: 2, delay: 5.0)])
        #expect(BrainWatcherLifecycleMachine.reduce(&state, event: .wakeTimerFired(generation: 1, candidatePaths: [], now: t0)).isEmpty)

        // Terminate stops periodic timer, wake, debounce, and FS watcher
        let termEff = BrainWatcherLifecycleMachine.reduce(&state, event: .terminate)
        #expect(termEff == [.cancelDebounce, .cancelWakeRefresh, .stopPeriodicTimer, .stopFSWatcher])
        #expect(BrainWatcherLifecycleMachine.reduce(&state, event: .wakeTimerFired(generation: 2, candidatePaths: [], now: t0)).isEmpty)
    }

    @Test("DoneUnseenState tracks finish transitions, clears on markSeen, and resets on stop")
    func doneUnseenStateLifecycle() {
        var du = DoneUnseenState()
        let busy = SessionInfo(pid: 1, sessionId: "s1", cwd: "/tmp", status: .busy, startedAt: nil, entrypoint: "cli")
        let idle = SessionInfo(pid: 1, sessionId: "s1", cwd: "/tmp", status: .idle, startedAt: nil, entrypoint: "cli")

        du.step(sessions: [busy], now: 100)
        #expect(!du.anyUnseen)
        du.step(sessions: [idle], now: 120)
        #expect(du.ids == ["s1"])
        let cleared = du.markSeen("s1")
        #expect(cleared)
        #expect(!du.anyUnseen)

        du.step(sessions: [busy], now: 130)
        du.step(sessions: [idle], now: 140)
        #expect(du.anyUnseen)
        du.reset()
        #expect(!du.anyUnseen)
        #expect(du.prevStatuses.isEmpty)
    }

    // MARK: - MenuBarAnchorResolver & PopoverAnchorSessionState (Issue #2)

    private static let builtinNotchedDisplay = MenuBarDisplayDescriptor(
        displayId: 1,
        frame: ScreenRect(x: 0, y: 0, width: 1728, height: 1117),
        visibleFrame: ScreenRect(x: 0, y: 0, width: 1728, height: 1080),
        auxiliaryTopLeftArea: ScreenRect(x: 0, y: 1080, width: 764, height: 37),
        auxiliaryTopRightArea: ScreenRect(x: 964, y: 1080, width: 764, height: 37),
        safeAreaTop: 37,
        isBuiltin: true,
        isMain: false
    )

    private static let externalRightDisplay = MenuBarDisplayDescriptor(
        displayId: 2,
        frame: ScreenRect(x: 1728, y: 0, width: 2560, height: 1440),
        visibleFrame: ScreenRect(x: 1728, y: 0, width: 2560, height: 1415),
        auxiliaryTopLeftArea: nil,
        auxiliaryTopRightArea: nil,
        safeAreaTop: 0,
        isBuiltin: false,
        isMain: true
    )

    @Test("MenuBarAnchorResolver accepts valid status items on notched display (LTR and RTL)")
    func anchorValidNotchedLTRAndRTL() {
        let ltrRect = ScreenRect(x: 1420, y: 1086, width: 64, height: 24)
        let ltrSnap = StatusItemAnchorSnapshot(
            statusItemVisible: true,
            hasWindow: true,
            windowVisible: true,
            windowAlpha: 1.0,
            buttonScreenRect: ltrRect,
            windowScreenDisplayId: 1
        )
        #expect(
            MenuBarAnchorResolver.resolve(snapshot: ltrSnap, displays: [Self.builtinNotchedDisplay])
                == .statusItem(displayId: 1, buttonRect: ltrRect)
        )

        // RTL menu bar places status items in auxiliaryTopLeftArea
        let rtlRect = ScreenRect(x: 120, y: 1086, width: 64, height: 24)
        let rtlSnap = StatusItemAnchorSnapshot(
            statusItemVisible: true,
            hasWindow: true,
            windowVisible: true,
            windowAlpha: 1.0,
            buttonScreenRect: rtlRect,
            windowScreenDisplayId: 1
        )
        #expect(
            MenuBarAnchorResolver.resolve(snapshot: rtlSnap, displays: [Self.builtinNotchedDisplay])
                == .statusItem(displayId: 1, buttonRect: rtlRect)
        )
    }

    @Test("MenuBarAnchorResolver accepts valid status items on negative-X (left) and negative-Y (bottom) displays")
    func anchorValidNegativeCoordinateDisplays() {
        let leftDisplay = MenuBarDisplayDescriptor(
            displayId: 10,
            frame: ScreenRect(x: -2560, y: 0, width: 2560, height: 1440),
            visibleFrame: ScreenRect(x: -2560, y: 0, width: 2560, height: 1415),
            isBuiltin: false,
            isMain: false
        )
        let leftButton = ScreenRect(x: -180, y: 1416, width: 64, height: 24)
        let leftSnap = StatusItemAnchorSnapshot(
            statusItemVisible: true,
            hasWindow: true,
            windowVisible: true,
            windowAlpha: 1.0,
            buttonScreenRect: leftButton,
            windowScreenDisplayId: 10
        )
        #expect(
            MenuBarAnchorResolver.resolve(
                snapshot: leftSnap,
                displays: [Self.builtinNotchedDisplay, leftDisplay]
            ) == .statusItem(displayId: 10, buttonRect: leftButton)
        )

        let bottomDisplay = MenuBarDisplayDescriptor(
            displayId: 11,
            frame: ScreenRect(x: 0, y: -1080, width: 1920, height: 1080),
            visibleFrame: ScreenRect(x: 0, y: -1080, width: 1920, height: 1055),
            isBuiltin: false,
            isMain: false
        )
        let bottomButton = ScreenRect(x: 1680, y: -24, width: 64, height: 24)
        let bottomSnap = StatusItemAnchorSnapshot(
            statusItemVisible: true,
            hasWindow: true,
            windowVisible: true,
            windowAlpha: 1.0,
            buttonScreenRect: bottomButton,
            windowScreenDisplayId: 11
        )
        #expect(
            MenuBarAnchorResolver.resolve(
                snapshot: bottomSnap,
                displays: [Self.builtinNotchedDisplay, bottomDisplay]
            ) == .statusItem(displayId: 11, buttonRect: bottomButton)
        )
    }

    @Test("MenuBarAnchorResolver catches Issue #2 off-screen parked button (x = -1724) and anchors cleanly to top-right")
    func anchorIssue2OffScreenParkedFallback() {
        let parkedSnap = StatusItemAnchorSnapshot(
            statusItemVisible: true,
            hasWindow: true,
            windowVisible: true,
            windowAlpha: 1.0,
            buttonScreenRect: ScreenRect(x: -1724, y: 1086, width: 64, height: 24),
            windowScreenDisplayId: 1
        )
        let decision = MenuBarAnchorResolver.resolve(
            snapshot: parkedSnap,
            displays: [Self.builtinNotchedDisplay, Self.externalRightDisplay],
            mouseDisplayId: 2,
            panelWidth: 420
        )
        guard case .fallbackMenuBar(let displayId, let anchorRect, let reason) = decision else {
            Issue.record("Expected .fallbackMenuBar, got \(decision)")
            return
        }
        #expect(displayId == 2)
        #expect(reason == .offScreen)
        // Must sit in the external display's top-right menu-bar band, NEVER clamped to left edge x = 1728!
        #expect(anchorRect.minY == 1415.0)
        #expect(anchorRect.midX > 3800.0 && anchorRect.midX < 4288.0)
    }

    @Test("MenuBarAnchorResolver rejects buttons fully or >50% inside the MacBook notch cutout")
    func anchorNotchOcclusion() {
        // Completely inside notch cutout [764, 964]
        let insideNotch = StatusItemAnchorSnapshot(
            statusItemVisible: true,
            hasWindow: true,
            windowVisible: true,
            windowAlpha: 1.0,
            buttonScreenRect: ScreenRect(x: 830, y: 1086, width: 60, height: 24),
            windowScreenDisplayId: 1
        )
        if case .fallbackMenuBar(let id, let anchorRect, let reason) = MenuBarAnchorResolver.resolve(
            snapshot: insideNotch,
            displays: [Self.builtinNotchedDisplay]
        ) {
            #expect(id == 1)
            #expect(reason == .notchOccluded)
            // Fallback rect must sit inside auxiliaryTopRightArea, not inside the notch
            #expect(anchorRect.midX >= 980.0 && anchorRect.midX <= 1712.0)
        } else {
            Issue.record("Expected .notchOccluded fallback for button inside notch")
        }

        // Partially clipped (>50% inside notch: [924, 964] = 40pt occluded, [964, 984] = 20pt visible)
        let clippedNotch = StatusItemAnchorSnapshot(
            statusItemVisible: true,
            hasWindow: true,
            windowVisible: true,
            windowAlpha: 1.0,
            buttonScreenRect: ScreenRect(x: 924, y: 1086, width: 60, height: 24),
            windowScreenDisplayId: 1
        )
        if case .fallbackMenuBar(_, _, let reason) = MenuBarAnchorResolver.resolve(
            snapshot: clippedNotch,
            displays: [Self.builtinNotchedDisplay]
        ) {
            #expect(reason == .notchOccluded)
        } else {
            Issue.record("Expected .notchOccluded fallback for >50% notch-clipped button")
        }
    }

    @Test("MenuBarAnchorResolver pins stationary anchor under revealed auto-hide/fullscreen menu bar and rejects hidden button above frame.maxY")
    func anchorAutoHideAndFullscreenMenuBar() {
        let autoHideDisplay = MenuBarDisplayDescriptor(
            displayId: 3,
            frame: ScreenRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: ScreenRect(x: 0, y: 0, width: 2560, height: 1440),
            isBuiltin: false,
            isMain: true
        )
        #expect(autoHideDisplay.hasEphemeralMenuBar)

        let revealedRect = ScreenRect(x: 2300, y: 1416, width: 64, height: 24)
        let revealedSnap = StatusItemAnchorSnapshot(
            statusItemVisible: true,
            hasWindow: true,
            windowVisible: true,
            windowAlpha: 1.0,
            buttonScreenRect: revealedRect,
            windowScreenDisplayId: 3
        )
        // Revealed auto-hide menu bar pins stationary anchor directly under the clicked icon
        // so the popover never rides NSStatusBarWindow upward when the menu bar retracts.
        #expect(
            MenuBarAnchorResolver.resolve(snapshot: revealedSnap, displays: [autoHideDisplay])
                == .fallbackMenuBar(
                    displayId: 3,
                    anchorRect: MenuBarAnchorResolver.pinnedAnchorRect(for: revealedRect),
                    reason: .ephemeralMenuBar
                )
        )

        // Native Fullscreen Space on a notched MacBook (even when visibleFrame.maxY < frame.maxY)
        let notchedFullscreen = MenuBarDisplayDescriptor(
            displayId: 1,
            frame: ScreenRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: ScreenRect(x: 0, y: 0, width: 1728, height: 1080),
            auxiliaryTopLeftArea: ScreenRect(x: 0, y: 1080, width: 760, height: 37),
            auxiliaryTopRightArea: ScreenRect(x: 968, y: 1080, width: 760, height: 37),
            safeAreaTop: 37,
            isBuiltin: true,
            isMain: true,
            isFullscreen: true
        )
        #expect(notchedFullscreen.hasEphemeralMenuBar)

        let fsIconRect = ScreenRect(x: 1380, y: 1086, width: 64, height: 24)
        let fsSnap = StatusItemAnchorSnapshot(
            statusItemVisible: true,
            hasWindow: true,
            windowVisible: true,
            windowAlpha: 1.0,
            buttonScreenRect: fsIconRect,
            windowScreenDisplayId: 1
        )
        #expect(
            MenuBarAnchorResolver.resolve(snapshot: fsSnap, displays: [notchedFullscreen])
                == .fallbackMenuBar(
                    displayId: 1,
                    anchorRect: MenuBarAnchorResolver.pinnedAnchorRect(for: fsIconRect),
                    reason: .ephemeralMenuBar
                )
        )

        // Fullscreen overlay menu bar revealed slightly below auxiliaryTopRightArea on notched MacBook
        let fsOverlayRect = ScreenRect(x: 1380, y: 1056, width: 64, height: 24)
        let fsOverlaySnap = StatusItemAnchorSnapshot(
            statusItemVisible: true,
            hasWindow: true,
            windowVisible: true,
            windowAlpha: 1.0,
            buttonScreenRect: fsOverlayRect,
            windowScreenDisplayId: 1
        )
        #expect(
            MenuBarAnchorResolver.resolve(snapshot: fsOverlaySnap, displays: [notchedFullscreen])
                == .fallbackMenuBar(
                    displayId: 1,
                    anchorRect: MenuBarAnchorResolver.pinnedAnchorRect(for: fsOverlayRect),
                    reason: .ephemeralMenuBar
                )
        )

        let hiddenAboveTop = StatusItemAnchorSnapshot(
            statusItemVisible: true,
            hasWindow: true,
            windowVisible: true,
            windowAlpha: 1.0,
            buttonScreenRect: ScreenRect(x: 2300, y: 1441, width: 64, height: 24),
            windowScreenDisplayId: 3
        )
        if case .fallbackMenuBar(let id, let anchorRect, let reason) = MenuBarAnchorResolver.resolve(
            snapshot: hiddenAboveTop,
            displays: [autoHideDisplay]
        ) {
            #expect(id == 3)
            #expect(reason == .offScreen)
            #expect(anchorRect.minY == 1416.0)
        } else {
            Issue.record("Expected .offScreen fallback when auto-hide status window is slid above frame.maxY")
        }
    }

    @Test("MenuBarAnchorResolver rejects hidden, missing-window, alpha-0, degenerate, mid-screen, and empty-display states")
    func anchorHiddenAndDegenerateStates() {
        let displays = [Self.externalRightDisplay]
        let validRect = ScreenRect(x: 4000, y: 1416, width: 64, height: 24)

        func reasonFor(_ snap: StatusItemAnchorSnapshot) -> AnchorFallbackReason? {
            if case .fallbackMenuBar(_, _, let reason) = MenuBarAnchorResolver.resolve(snapshot: snap, displays: displays) {
                return reason
            }
            return nil
        }

        #expect(reasonFor(StatusItemAnchorSnapshot(
            statusItemVisible: false, hasWindow: true, windowVisible: true, windowAlpha: 1, buttonScreenRect: validRect, windowScreenDisplayId: 2
        )) == .statusItemHidden)

        #expect(reasonFor(StatusItemAnchorSnapshot(
            statusItemVisible: true, hasWindow: false, windowVisible: false, windowAlpha: 0, buttonScreenRect: nil, windowScreenDisplayId: nil
        )) == .missingWindow)

        #expect(reasonFor(StatusItemAnchorSnapshot(
            statusItemVisible: true, hasWindow: true, windowVisible: false, windowAlpha: 1, buttonScreenRect: validRect, windowScreenDisplayId: 2
        )) == .windowNotVisible)

        #expect(reasonFor(StatusItemAnchorSnapshot(
            statusItemVisible: true, hasWindow: true, windowVisible: true, windowAlpha: 0.0, buttonScreenRect: validRect, windowScreenDisplayId: 2
        )) == .windowNotVisible)

        #expect(reasonFor(StatusItemAnchorSnapshot(
            statusItemVisible: true, hasWindow: true, windowVisible: true, windowAlpha: 1.0, buttonScreenRect: ScreenRect(x: 4000, y: 1416, width: 0, height: 24), windowScreenDisplayId: 2
        )) == .degenerateRect)

        #expect(reasonFor(StatusItemAnchorSnapshot(
            statusItemVisible: true, hasWindow: true, windowVisible: true, windowAlpha: 1.0, buttonScreenRect: ScreenRect(x: 2400, y: 600, width: 64, height: 24), windowScreenDisplayId: 2
        )) == .outsideMenuBarBand)

        // Zero connected displays -> .unavailable (never fabricates coordinates)
        #expect(MenuBarAnchorResolver.resolve(
            snapshot: StatusItemAnchorSnapshot(
                statusItemVisible: true, hasWindow: true, windowVisible: true, windowAlpha: 1.0, buttonScreenRect: validRect, windowScreenDisplayId: 2
            ),
            displays: []
        ) == .unavailable)
    }

    @Test("MenuBarAnchorResolver enforces fallback display priority and narrow-screen X clamping")
    func anchorFallbackDisplayPriorityAndClamping() {
        let dLowest = MenuBarDisplayDescriptor(
            displayId: 1,
            frame: ScreenRect(x: 0, y: 0, width: 1280, height: 800),
            visibleFrame: ScreenRect(x: 0, y: 0, width: 1280, height: 776),
            isBuiltin: false,
            isMain: false
        )
        let dBuiltin = MenuBarDisplayDescriptor(
            displayId: 2,
            frame: ScreenRect(x: 1280, y: 0, width: 1512, height: 982),
            visibleFrame: ScreenRect(x: 1280, y: 0, width: 1512, height: 945),
            isBuiltin: true,
            isMain: false
        )
        let dMain = MenuBarDisplayDescriptor(
            displayId: 3,
            frame: ScreenRect(x: 2792, y: 0, width: 2560, height: 1440),
            visibleFrame: ScreenRect(x: 2792, y: 0, width: 2560, height: 1415),
            isBuiltin: false,
            isMain: true
        )

        #expect(MenuBarAnchorResolver.selectFallbackDisplay(displays: [], mouseDisplayId: nil) == nil)
        #expect(MenuBarAnchorResolver.selectFallbackDisplay(displays: [dLowest, dBuiltin, dMain], mouseDisplayId: 1)?.displayId == 1)
        #expect(MenuBarAnchorResolver.selectFallbackDisplay(displays: [dLowest, dBuiltin, dMain], mouseDisplayId: nil)?.displayId == 3)
        #expect(MenuBarAnchorResolver.selectFallbackDisplay(displays: [dLowest, dBuiltin], mouseDisplayId: nil)?.displayId == 2)
        #expect(MenuBarAnchorResolver.selectFallbackDisplay(displays: [dLowest], mouseDisplayId: nil)?.displayId == 1)

        // Synthetic descriptor with zero-sized auxiliary areas must not be treated as notched
        let degenerateAux = MenuBarDisplayDescriptor(
            displayId: 8,
            frame: ScreenRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: ScreenRect(x: 0, y: 0, width: 1440, height: 876),
            auxiliaryTopLeftArea: ScreenRect(x: 0, y: 876, width: 0, height: 24),
            auxiliaryTopRightArea: ScreenRect(x: 1440, y: 876, width: 0, height: 24),
            safeAreaTop: 24
        )
        #expect(degenerateAux.hasNotch == false)

        // Narrow notched auxiliaryTopRightArea (width 200 < panelWidth 420) clamps X inside usable area
        let narrowNotched = MenuBarDisplayDescriptor(
            displayId: 9,
            frame: ScreenRect(x: 0, y: 0, width: 600, height: 800),
            visibleFrame: ScreenRect(x: 0, y: 0, width: 600, height: 763),
            auxiliaryTopLeftArea: ScreenRect(x: 0, y: 763, width: 200, height: 37),
            auxiliaryTopRightArea: ScreenRect(x: 400, y: 763, width: 200, height: 37),
            safeAreaTop: 37,
            isBuiltin: true,
            isMain: true
        )
        let clampedRect = MenuBarAnchorResolver.fallbackAnchorRect(on: narrowNotched, panelWidth: 420)
        #expect(clampedRect.midX >= 416.0 && clampedRect.midX <= 584.0)
        #expect(clampedRect.minY == 763.0)
    }

    @Test("MenuBarPanelMachine manages animated open/close tokens, prevents stale close orderOut on rapid reopen, and handles terminate")
    func menuBarPanelAnimatedLifecycleAndTokenSafety() {
        var state = MenuBarPanelState()
        let btnRect = ScreenRect(x: 1420, y: 1086, width: 64, height: 24)
        let anchorMode = PopoverAnchorSessionMode(decision: .statusItem(displayId: 1, buttonRect: btnRect))

        // Invalid .none anchor is a safe no-op
        #expect(MenuBarPanelMachine.reduce(
            &state,
            event: .openRequested(anchorMode: .none, height: 500, animated: true)
        ).isEmpty)
        #expect(state.phase == .closed)

        // Animated open -> .opening(token: 1)
        let openEff = MenuBarPanelMachine.reduce(
            &state,
            event: .openRequested(anchorMode: anchorMode, height: 520.4, animated: true)
        )
        #expect(state.phase == .opening(token: 1))
        #expect(state.measuredHeight == 521.0)
        #expect(state.anchorMode == anchorMode)
        #expect(openEff == [
            .presentPanel(animated: true, token: 1),
            .syncAppPresentationShown,
            .attachDismissMonitors,
        ])

        // Stale openAnimationFinished token is ignored; matching token transitions to .open
        #expect(MenuBarPanelMachine.reduce(&state, event: .openAnimationFinished(token: 99)).isEmpty)
        #expect(state.phase == .opening(token: 1))
        #expect(MenuBarPanelMachine.reduce(&state, event: .openAnimationFinished(token: 1)).isEmpty)
        #expect(state.phase == .open)

        // Animated close -> .closing(token: 2)
        let closeEff = MenuBarPanelMachine.reduce(
            &state,
            event: .closeRequested(animated: true, suppressStatusItemClickUntil: nil)
        )
        #expect(state.phase == .closing(token: 2))
        #expect(state.anchorMode == .none)
        #expect(closeEff == [
            .detachDismissMonitors,
            .syncAppPresentationClosed,
            .dismissPanel(animated: true, token: 2),
        ])

        // Rapid re-open while close animation (token 2) is still running -> .opening(token: 3)
        let reopenEff = MenuBarPanelMachine.reduce(
            &state,
            event: .openRequested(anchorMode: anchorMode, height: 520, animated: true)
        )
        #expect(state.phase == .opening(token: 3))
        #expect(reopenEff == [
            .presentPanel(animated: true, token: 3),
            .syncAppPresentationShown,
            .attachDismissMonitors,
        ])

        // Late close completion for stale token 2 MUST NOT emit .orderOutPanel or close the reopened panel!
        #expect(MenuBarPanelMachine.reduce(&state, event: .closeAnimationFinished(token: 2)).isEmpty)
        #expect(state.phase == .opening(token: 3))

        // Normal close + matching completion emits .orderOutPanel and settles in .closed
        _ = MenuBarPanelMachine.reduce(&state, event: .closeRequested(animated: true, suppressStatusItemClickUntil: nil))
        #expect(state.phase == .closing(token: 4))
        let finishEff = MenuBarPanelMachine.reduce(&state, event: .closeAnimationFinished(token: 4))
        #expect(finishEff == [.orderOutPanel])
        #expect(state.phase == .closed)

        // Non-animated open jumps straight to .open; non-animated close interrupting .closing snaps immediately
        let instantOpen = MenuBarPanelMachine.reduce(
            &state,
            event: .openRequested(anchorMode: anchorMode, height: 480, animated: false)
        )
        #expect(state.phase == .open)
        #expect(instantOpen == [
            .presentPanel(animated: false, token: 5),
            .syncAppPresentationShown,
            .attachDismissMonitors,
        ])
        _ = MenuBarPanelMachine.reduce(&state, event: .closeRequested(animated: true, suppressStatusItemClickUntil: nil))
        #expect(state.phase == .closing(token: 6))
        // Duplicate animated close while closing is a no-op
        #expect(MenuBarPanelMachine.reduce(&state, event: .closeRequested(animated: true, suppressStatusItemClickUntil: nil)).isEmpty)
        // Immediate close (e.g. Space switch) snaps to .closed
        let snapClose = MenuBarPanelMachine.reduce(&state, event: .closeRequested(animated: false, suppressStatusItemClickUntil: nil))
        #expect(state.phase == .closed)
        #expect(snapClose == [.dismissPanel(animated: false, token: 7)])
    }

    @Test("MenuBarPanelMachine guards dismiss events during nested menu tracking, syncs height, and suppresses status-item click bounce")
    func menuBarPanelMenuTrackingHeightAndClickSuppression() {
        var state = MenuBarPanelState()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let pinnedRect = ScreenRect(x: 1411, y: 1086, width: 2, height: 2)
        let fallbackMode = PopoverAnchorSessionMode(
            decision: .fallbackMenuBar(displayId: 1, anchorRect: pinnedRect, reason: .ephemeralMenuBar)
        )

        // Height measured while closed updates stored height without emitting .updatePanelHeight
        #expect(MenuBarPanelMachine.reduce(&state, event: .heightMeasured(440.2)).isEmpty)
        #expect(state.measuredHeight == 441.0)
        // Invalid/NaN/tiny height is ignored
        #expect(MenuBarPanelMachine.reduce(&state, event: .heightMeasured(.nan)).isEmpty)
        #expect(state.measuredHeight == 441.0)

        _ = MenuBarPanelMachine.reduce(
            &state,
            event: .openRequested(anchorMode: fallbackMode, height: 441, animated: false)
        )
        // Height change while open emits .updatePanelHeight (clamped to >= 180)
        #expect(MenuBarPanelMachine.reduce(&state, event: .heightMeasured(120)) == [.updatePanelHeight(180.0)])
        #expect(MenuBarPanelMachine.reduce(&state, event: .heightMeasured(179.7)).isEmpty) // ceil(179.7) == 180.0
        #expect(MenuBarPanelMachine.reduce(&state, event: .heightMeasured(512.2)) == [.updatePanelHeight(513.0)])

        // Nested NSMenu tracking (depth 2) blocks outsideClick, appDeactivated, and escapePressed
        _ = MenuBarPanelMachine.reduce(&state, event: .menuTrackingBegan)
        _ = MenuBarPanelMachine.reduce(&state, event: .menuTrackingBegan)
        #expect(state.activeMenuTrackingDepth == 2)
        #expect(state.isMenuTrackingActive)
        #expect(MenuBarPanelMachine.reduce(&state, event: .outsideClick).isEmpty)
        #expect(MenuBarPanelMachine.reduce(&state, event: .appDeactivated).isEmpty)
        #expect(MenuBarPanelMachine.reduce(&state, event: .escapePressed).isEmpty)

        // Ending one menu still keeps depth == 1 -> still guarded
        _ = MenuBarPanelMachine.reduce(&state, event: .menuTrackingEnded)
        #expect(state.activeMenuTrackingDepth == 1)
        #expect(MenuBarPanelMachine.reduce(&state, event: .outsideClick).isEmpty)

        // Ending second menu unlocks dismiss; extra end clamps safely at 0
        _ = MenuBarPanelMachine.reduce(&state, event: .menuTrackingEnded)
        _ = MenuBarPanelMachine.reduce(&state, event: .menuTrackingEnded)
        #expect(state.activeMenuTrackingDepth == 0)

        let escEff = MenuBarPanelMachine.reduce(&state, event: .escapePressed)
        #expect(escEff.contains(.detachDismissMonitors))
        #expect(escEff.contains(.syncAppPresentationClosed))
        #expect(state.phase == .closing(token: 2))

        // Re-open and close with status-item click suppression window (e.g. resign-key on leftMouseDown)
        _ = MenuBarPanelMachine.reduce(
            &state,
            event: .openRequested(anchorMode: fallbackMode, height: 500, animated: false)
        )
        _ = MenuBarPanelMachine.reduce(
            &state,
            event: .closeRequested(animated: true, suppressStatusItemClickUntil: t0.addingTimeInterval(0.5))
        )
        // Matching closeAnimationFinished preserves suppression window until leftMouseUp arrives
        _ = MenuBarPanelMachine.reduce(&state, event: .closeAnimationFinished(token: 4))
        #expect(state.consumeSuppressedStatusItemClick(at: t0.addingTimeInterval(0.08)) == true)
        // One-shot: second click opens normally
        #expect(state.consumeSuppressedStatusItemClick(at: t0.addingTimeInterval(0.12)) == false)

        // Terminate forces immediate cleanup even if a menu is tracking
        _ = MenuBarPanelMachine.reduce(
            &state,
            event: .openRequested(anchorMode: fallbackMode, height: 500, animated: false)
        )
        _ = MenuBarPanelMachine.reduce(&state, event: .menuTrackingBegan)
        let termEff = MenuBarPanelMachine.reduce(&state, event: .terminate)
        #expect(state.phase == .closed)
        #expect(state.activeMenuTrackingDepth == 0)
        #expect(state.anchorMode == .none)
        #expect(termEff == [
            .detachDismissMonitors,
            .syncAppPresentationClosed,
            .dismissPanel(animated: false, token: 6),
        ])
    }

    @Test("MenuBarAnchorResolver.panelFrame centers under icon, clamps edges/Dock/negative-X, and resizedPanelFrame locks topY & minX")
    func menuBarPanelPlacementAndTopPinnedResize() {
        // 1. Centered under status item vertically centered inside notched 37pt menu bar
        //    (button.minY = 1089.5 is 9.5pt ABOVE visibleFrame.maxY = 1080; panel must clear notch!)
        let anchor = ScreenRect(x: 1180, y: 1089.5, width: 64, height: 22) // midX = 1212
        let frame = MenuBarAnchorResolver.panelFrame(
            anchorRect: anchor,
            hostDisplay: Self.builtinNotchedDisplay,
            panelWidth: 420,
            panelHeight: 540,
            topGap: 6,
            edgeMargin: 8
        )
        #expect(abs(frame.minX - (1212.0 - 210.0)) < 0.01)
        #expect(abs(frame.maxY - (1080.0 - 6.0)) < 0.01) // strictly 6pt below notch/menu bar bottom, not 1089.5 - 6
        #expect(abs(frame.width - 420.0) < 0.01)
        #expect(abs(frame.height - 540.0) < 0.01)

        // 2. Far-right status item clamps cleanly to right edge margin (1728 - 8 - 420 = 1300)
        let farRight = ScreenRect(x: 1680, y: 1080, width: 44, height: 37)
        let clampedRight = MenuBarAnchorResolver.panelFrame(
            anchorRect: farRight,
            hostDisplay: Self.builtinNotchedDisplay,
            panelWidth: 420,
            panelHeight: 500
        )
        #expect(abs(clampedRight.maxX - (1728.0 - 8.0)) < 0.01)
        #expect(abs(clampedRight.maxY - 1074.0) < 0.01)

        // 3. Secondary display on the left (negative X) with left-side Dock (visibleFrame.minX = -1850)
        let leftWithDock = MenuBarDisplayDescriptor(
            displayId: 7,
            frame: ScreenRect(x: -1920, y: 0, width: 1920, height: 1080),
            visibleFrame: ScreenRect(x: -1850, y: 0, width: 1850, height: 1055),
            isBuiltin: false,
            isMain: false
        )
        let leftEdgeAnchor = ScreenRect(x: -1880, y: 1055, width: 40, height: 25)
        let clampedLeft = MenuBarAnchorResolver.panelFrame(
            anchorRect: leftEdgeAnchor,
            hostDisplay: leftWithDock,
            panelWidth: 420,
            panelHeight: 460
        )
        #expect(abs(clampedLeft.minX - (-1850.0 + 8.0)) < 0.01)
        #expect(abs(clampedLeft.maxY - 1049.0) < 0.01)

        // 4. Top-pinned tab resize: minX, width, and maxY stay mathematically invariant across shrink & grow
        let shrunk = MenuBarAnchorResolver.resizedPanelFrame(
            currentFrame: frame,
            newHeight: 380,
            hostDisplay: Self.builtinNotchedDisplay
        )
        #expect(abs(shrunk.minX - frame.minX) < 0.001)
        #expect(abs(shrunk.width - frame.width) < 0.001)
        #expect(abs(shrunk.maxY - frame.maxY) < 0.001)
        #expect(abs(shrunk.height - 380.0) < 0.001)

        let grown = MenuBarAnchorResolver.resizedPanelFrame(
            currentFrame: shrunk,
            newHeight: 620,
            hostDisplay: Self.builtinNotchedDisplay
        )
        #expect(abs(grown.minX - frame.minX) < 0.001)
        #expect(abs(grown.maxY - frame.maxY) < 0.001)
        #expect(abs(grown.height - 620.0) < 0.001)
    }
}
