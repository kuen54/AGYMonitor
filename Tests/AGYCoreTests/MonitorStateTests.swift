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
        let fsEffects = SessionMonitorLifecycleMachine.reduce(&state, event: .fsWatcherAttempted(healthy: true, at: t0))
        #expect(fsEffects == [.setPollTimer(15.0)])

        // Scan detects 2 live sessions while inactive -> tightens to 6s
        let scan1 = SessionMonitorLifecycleMachine.reduce(&state, event: .scanCompleted(liveCount: 2))
        #expect(scan1 == [.setPollTimer(6.0)])

        // Panel opens -> active scan -> tightens to 2s
        let activeEffects = SessionMonitorLifecycleMachine.reduce(&state, event: .setActive(true, now: t0.addingTimeInterval(5)))
        #expect(activeEffects == [.runScan])
        let scan2 = SessionMonitorLifecycleMachine.reduce(&state, event: .scanCompleted(liveCount: 2))
        #expect(scan2 == [.setPollTimer(2.0)])

        // Degraded watcher retries after 30s on next timer tick
        SessionMonitorLifecycleMachine.reduce(&state, event: .fsWatcherAttempted(healthy: false, at: t0.addingTimeInterval(10)))
        let retryTick = SessionMonitorLifecycleMachine.reduce(&state, event: .pollTimerFired(now: t0.addingTimeInterval(45)))
        #expect(retryTick == [.startFSWatcher, .runScan])

        // Stop tears down coalesce, timer, and FS watcher; late callbacks become no-ops
        let stopEffects = SessionMonitorLifecycleMachine.reduce(&state, event: .stop)
        #expect(!state.isStarted)
        #expect(state.runGeneration == 1)
        #expect(stopEffects == [.cancelFSCoalesce, .setPollTimer(nil), .stopFSWatcher])
        #expect(SessionMonitorLifecycleMachine.reduce(&state, event: .fsCoalesceFired(now: t0.addingTimeInterval(50))).isEmpty)

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
}
