# AGYMonitor State Machines — Canonical Architecture Map

Every non-trivial stateful lifecycle in AGYMonitor is modeled as a **pure, Foundation-only, `Equatable & Sendable` state machine** inside `AGYCore` (`Sources/Core_*.swift`) and driven by a thin AppKit / SwiftUI shell.

This document serves as the single reference for **UX invariants**, **DX maintenance**, and **AX (coding-agent) navigation**.

## Architectural Contract

1. **Pure Core (`Sources/Core_*.swift`)**: `import Foundation` only. No `AppKit`, `SwiftUI`, `Combine`, `Dispatch`, `FileManager`, `SQLite3`, or `Process`. Use `Double` instead of `CGFloat`.
2. **Explicit Effects**: Reducers mutate `inout State` and return `[Effect]` (or a typed transition decision). Shells contain a single `dispatch(_ event)` switch executing effects.
3. **Zero Shadow Booleans**: Never introduce parallel `Bool` flags (`isStarted`, `isHovering`, `isPointingCursor`, `preventClose`, `isChecking`, raw `fetchGeneration += 1`, raw `NSCursor.push/pop`, duplicate `displayedTab`/`displayedRange`, or dead `NotchViewModel.anyBusy`) in app shells when a state machine owns that domain.
4. **Deterministic Tests**: Every invariant below is verified in milliseconds by `swift test` (`bash scripts/check.sh`).

---

## Complete State Machine Registry

### 1. App Presentation & Surface Lifecycle
- **Core**: `Sources/Core_AppState.swift` — `AppPresentationMachine` (`AppPresentationState`, `AppPresentationEvent`, `AppPresentationEffect`)
- **Shell**: `Sources/AppDelegate.swift`, `Sources/NotchController.swift`, `Sources/GlobalHotKey.swift`
- **Tests**: `Tests/AGYCoreTests/AppStateTests.swift`
- **Key Invariants**:
  - `AppPresentationState` initializes synchronously from persisted `store.displayMode` so launch-window reopen/hotkey events never misroute.
  - `isPanelVisible` is derived solely from the active surface (`menubar ? popoverOpen : notchOpen`).
  - `.closePopover` (panel dismissal) is strictly separated from `.setStatusItemVisible(Bool)` (status-item/anchor visibility only); legacy `.setPopoverAnimates(Bool)` is removed. `.displaySurfaceChanged(.notch)` emits `.closePopover` before `.setMenuBarLogoActive(false)` + `.setStatusItemVisible(false)` only when `popoverOpen == true`.
  - A delayed panel-close callback arriving after switching to `.notch` NEVER clears an open notch's `isPanelVisible` or session-monitor cadence.
  - Switching surfaces always syncs `statusItem.isVisible`, `menuBarModel.isVisible`, `menuBarAnchor`, and `NotchController` start/stop atomically, and releases `PointingCursorCoordinator` synchronously on hide.
  - Global hotkey registration is idempotent; Carbon registration failures dispatch `.hotkeyRegistrationFailed` so `isHotkeyRegistered` stays truthful.

### 2. Notch Hover, Multi-Display Coordinator, Split Geometry, Fullscreen Edge-Reveal & Modal Locks
- **Core**: `Sources/Core_NotchState.swift` — `NotchMachine` (`NotchState`, `NotchPhase`, `NotchPointerSample`, `NotchEvent`, `NotchEffect`, `NotchPanelPresentation`, `NotchTiming`, `NotchPanelBackingMode`), `NotchGeometryState`, `NotchCoordinatorMachine` (`NotchCoordinatorState`, `NotchDisplayDescriptor`, `NotchScreenReconcilePlan`)
- **Shell**: `Sources/NotchController.swift`, `Sources/NotchView.swift`, `Sources/Views_Menus.swift`
- **Tests**: `Tests/AGYCoreTests/NotchStateTests.swift`
- **Phases**: `.hidden` ↔ `.closedPill` ↔ `.openingDwell` → `.open` ↔ `.closingGrace`
- **Key Invariants**:
  - `NotchState.lastPointerSample` deduplicates unchanged mouse moves inside the reducer AND auto-invalidates on every non-pointer transition (`explicitReveal`, `fullscreenChanged`, geometry/wing changes, and explicit `.invalidatePointerSample`) so `⌥⇧A` open and Space switches NEVER swallow subsequent mouse movement.
  - Explicit-reveal pointer hold & keyboard focus: `.explicitReveal` / `.explicitToggle` open sets `NotchState.awaitingPointerEntry = true` and emits `.focusPanel` (NEVER emitted on passive `.openDwellFired`), so `NotchController` calls `panel.makeKey()` once `isInteractive = true` (making `Esc`, `⌘1–5`, `↑/↓/Return`, and `Space/←/→` work immediately without clicking first) and holds `.open` while the pointer moves outside `contentRect` until the cursor first enters `contentRect` (preventing 120ms premature close). `awaitingPointerEntry` clears on inside-content entry, `.explicitClose`, `.outsideClick`, `.escapePressed`, `.fullscreenChanged`, display-mode stop, or whenever `phase` leaves `.open`.
  - `NotchGeometryState` strictly separates `closedWidth/closedHeight` from `openWidth/openHeight` and aligns initial `compactGapOffset` (`+8.5`), so closing the notch can NEVER feed expanded popover dimensions into `closedWingRect` click hit-testing.
  - `NotchCoordinatorMachine` owns `isStarted` (zero shadow bool), incrementally reconciles screens (preserving live open/modal state on surviving displays instead of destructive rebuild), reconciles `isFullscreen` changes on kept displays via `NotchScreenReconcilePlan.keptEffects` while invalidating `lastPointerSample` across kept displays, enforces single-open display exclusivity across multi-monitor setups, selects primary display deterministically (cursor → builtin → main → lowest ID), and diffs visibility so mid-fade mouse moves never restart alpha animations.
  - Overlapping `NSMenu` / `NSAlert` modal locks (`Set<NotchModalLock>`) pin the panel open until the last lock releases, then immediately enter `.closingGrace` if the pointer is outside.
  - `panelPresentation(for:pointer:)` checks `!visible` FIRST — an invisible fullscreen panel (`alphaValue == 0`) NEVER intercepts clicks, even when a Live Wing alert is active (`inClickableWing == true`).
  - `NotchPanelBackingMode` (`.compact` ↔ `.expanded`) + `NotchGeometryState.compactWindowSize(...)` keep collapsed per-display `NotchPanel` windows top-pinned at `(f.midX, f.maxY)` inside a tight wing-aware envelope (`~440–460 × 60 pt`, growing immediately for Live Wing / TPS pills) instead of holding a `600 × 860 pt` Retina GPU backing store 24/7; opening synchronously expands before `vm.isOpen = true`, while closing waits `NotchTiming.panelShrinkDelay` (`0.42s`) before shrinking back to `.compact` so the collapse spring never clips.

### 3. Notch Live Wing Priority & Auto-Retract
- **Core**: `Sources/Core_Telemetry.swift` — `NotchLiveWingMachine` (`NotchLiveWingState`, `NotchWingKind`, `NotchLiveWingEvent`, `NotchLiveWingEffect`)
- **Shell**: `Sources/NotchController.swift`, `Sources/NotchView.swift`
- **Tests**: `Tests/AGYCoreTests/TelemetryTests.swift`
- **Key Invariants**:
  - `.waiting` (preferring `needsConfirm`) always preempts `.done` and cancels pending done-retract timers.
  - `.done` banners announce once per unseen session (`announcedDoneIds`) and auto-retract after 5s.
  - `.dismissed(sessionId)` inserts `sessionId` into `dismissedWaitingIds` ONLY when `activeWing` is `.waiting(sessionId: ...)` matching `sessionId` — tapping/dismissing a `.done` wing or unrelated ID NEVER suppresses future `.waiting` alerts for that session.
  - `NotchController.stop()` resets `wingState` cleanly alongside `wingTimer`.

### 4. Usage Loading, Navigation, Snapshot Completeness & Background Gates
- **Core**: `Sources/Core_UsageState.swift` — `LoadPhase<Value>`, `RefreshQueueState`, `RefreshQueueCompletion`, `MonthNavigationState`, `HistoricalMonthLoadGate`, `YearLoadGate`, `ArchiveSweepGate`, `SnapshotFreshnessPolicy`
- **Shell**: `Sources/UsageStore.swift`, `Sources/UsageArchive.swift`, `Sources/Views.swift`, `Sources/Views_Time.swift`
- **Tests**: `Tests/AGYCoreTests/UsageStateTests.swift`
- **Key Invariants**:
  - Current-month, historical-month, year, and Plan quota scopes have isolated phases; `UsageStore.isLoading` reflects the active tab (including `.subscription`).
  - `SnapshotFreshnessPolicy.isCompleteHistoricalSnapshot` requires `lastUpdated >= startOfNextMonth(year, month)` so mid-month disk caches (e.g. Oct 15) never permanently truncate a historical month when viewed later; `yearMonthKey(year:month:)`, `currentYearMonthKey(now:)`, and `isFreshCurrentMonthFetch(...)` reject stale pre-midnight fetches after month rollover; disk writes are `.atomic`.
  - `RefreshQueueState` queues a forced follow-up when `⌘R` arrives during a non-forced scan, exposes `hasPendingFollowUp` and `phaseForIntermediateResult(_:)` to keep `.loading(cached:)` truthful while the follow-up executes, and completes atomically via `completeAction() -> RefreshQueueCompletion` (`.idle | .runFollowUp(force:)`).
  - `MonthNavigationState` auto-advances across midnight month boundaries ONLY when `followingCurrentMonth == true` (with `isCurrentMonth(year:month:now:)`); `SnapshotFreshnessPolicy.clampedYear` bounds year navigation to `[1970, currentYear]`.
  - `HistoricalMonthLoadGate` & `YearLoadGate` deduplicate overlapping non-forced requests, reject stale completions by monotonic generation, and cancel `activeYear` when switching back to a cached year (eliminating `2026 → 2025 → 2026 → 2025` stuck-year display).
  - `ArchiveSweepGate` is generation-stamped (`beginSweep` / `finish(generation:)` / `reset()`) so `clearArchive()` or disabling `archiveHistoryLocally` invalidates in-flight sweeps, clears `archiveSweptThrough`, and invalidates `yearTimeCache`.
  - `UsageArchive` enqueues `ioQueue.async` while holding `lock` so `clear()` and concurrent `merge()` disk writes strictly preserve lock order.

### 5. Plan Quota, Auth, 429 Cooldown, Fetch Coalescing, Generation Guard & SWR Probe
- **Core**: `Sources/Core_QuotaState.swift` — `QuotaPhase<Snapshot>`, `QuotaCooldownState`, `LiveQuotaHTTPOutcome`, `QuotaStateReducer`, `QuotaFetchGenerationState`, `QuotaFetchGate`, `TokenPresenceProbeState`
- **Shell**: `Sources/QuotaService.swift`, `Sources/UsageStore.swift`, `Sources/Views_Plan.swift`
- **Tests**: `Tests/AGYCoreTests/QuotaStateTests.swift`
- **Key Invariants**:
  - `QuotaFetchGate` checks active HTTP `429` cooldown **before** fresh TTL cache so non-forced refreshes within 60s NEVER wipe an active 429 banner; cached offline fallbacks preserve their `liveError` + `retryAt` notice across TTL hits.
  - `SubscriptionQuotaService` runs blocking Keychain/SQLite/CLI probes on an off-gate `probeQueue` so `workQueue` gate serialization never stalls behind 16s subprocess timeouts.
  - HTTP `401`/`403` transitions to `.failed(.unauthorized)` while keeping `hasAccountSurface == true` so the Plan tab remains accessible to show the re-auth hint.
  - `QuotaPhase.ready(snapshot:source:updatedAt:notice:isRefreshing:)` carries explicit in-flight refresh state (`isLoading` / `isRefreshing`): `.beginFetch` transitions `.noAccount`/`.failed` → `.loading` and `.ready(..., isRefreshing: false)` → `.ready(..., isRefreshing: true)` so clicking Retry on an offline/stale/expired-429 banner gives immediate refreshing feedback (disabled Retry + spinner) while keeping cached quota visible; `.fetched`, `.fetchFailed`, and `.tokenPresenceChanged(false)` clear `isRefreshing`. `.cooldownExpired(now:)` clears expired 429 notices and unlocks Retry when `retryAt` passes while viewing Plan.
  - `QuotaFetchGenerationState` (`beginFetch() -> UInt64`, `invalidate()`, `isCurrent(_:)`, `complete(_:)`) stamps in-flight quota fetches with monotonic generations so account logout or a superseding refresh NEVER resurrects stale quota snapshots.
  - `TokenPresenceProbeState` stamps background SWR probes with a monotonic `generation` so a slow async probe can NEVER overwrite a newer forced `probeTokenPresenceNow()`.

### 6. Brain Watcher, Session Monitor Lifecycle, Cadence, Done-Unseen, Jump Gate, Menu Bar Panel & Anchor
- **Core**: `Sources/Core_MonitorState.swift` (`BrainWatcherLifecycleMachine`, `SessionMonitorLifecycleMachine`, `SessionPollCadence`, `FSEventsThrottleState`, `DoneUnseenState`, `MenuBarAnchorState`, `MenuBarAnchorResolver`, `MenuBarPanelMachine`, `MenuBarPanelPhase`, `MenuBarPanelState`, `MenuBarPanelEvent`, `MenuBarPanelEffect`, `PopoverAnchorSessionMode`, `LogoVisualState`, `SessionLogic.resolveLiveSessionStatus`) & `Sources/Core_Sessions.swift` (`SubagentRecord`, `SessionLogic.SurfaceConversationSummary`, `SessionLogic.extractPresenceLockId`, `SessionLogic.mergeConversationSummaryRows`, `SessionLogic.parseSubagentRecordJSON`, `SessionLogic.isSubagentActivelyGenerating`, `SessionLogic.shouldProbeRunningSubagentMeta`, `SessionLogic.isOrphanSubagentFresh`, `SessionLogic.stepDoneUnseen`, `SessionLogic.matchWeztermPaneId`, `JumpRequestGate`)
- **Shell**: `Sources/AppDelegate.swift`, `Sources/SessionMonitor.swift`, `Sources/SessionStore.swift`, `Sources/SessionJumper.swift`, `Sources/AITitleReader.swift`, `Sources/Views_Common.swift` (`CoreAnimationLogoView`)
- **Tests**: `Tests/AGYCoreTests/MonitorStateTests.swift`, `Tests/AGYCoreTests/SessionsTests.swift`
- **Key Invariants**:
  - `BrainWatcherLifecycleMachine` owns `AppDelegate`'s FSEvents watcher, 30m periodic timer, wake debounce, and `FSEventsThrottleState`. Every `.refreshTriggered` cancels pending FSEvent debounces (protecting the 120s minimum floor), `.reconcileWatchPaths` picks up newly installed Antigravity surfaces, and `.terminate` cleans up all timers & streams.
  - `SessionMonitorLifecycleMachine` owns `watchedDirs` and `lastAttemptedDirs` (`fileprivate(set)`), preserves `setActive(true)` even before `start()`, bumps `runGeneration` on `stop()` so post-`stop()` async `onChange`/`markSeen` callbacks are strict no-ops, reconciles newly added or removed watched directories via `.reconcileWatchedDirs([String])` → `.restartFSEvents(dirs:)` (even while `fsHealthy == true`, without thrashing on identical failed directory sets), relaxes poll cadence on `.setActive(false, now:)` (`2s → 6s` / `6s → 15s`) with zero redundant close-scan, and cleans up `FSEventStream` safely on `queue`.
  - Native Darwin `libproc` FD/CWD discovery in `SessionMonitor.swift` shares `SessionLogic.extractPresenceLockId(fromPath:)` with `parseLsofPresence(_:)` (zero `lsof` subprocess spawns).
  - Multi-surface `conversation_summaries.db` rows (CLI, Desktop, IDE) decode into `SessionLogic.SurfaceConversationSummary` and combine symmetrically via `SessionLogic.mergeConversationSummaryRows(_:_:)`, so passive cross-surface mirrors (`isCrossSurfaceMirror`) NEVER overwrite authoritative `RUNNING` / `not_fully_idle` / `killed` owner state.
  - Subagent descriptors (`SubagentRecord` via `SessionLogic.parseSubagentRecordJSON(_:)`) and SQLite subagent rows are strictly gated through `SessionLogic.shouldProbeRunningSubagentMeta(...)`, `SessionLogic.isSubagentActivelyGenerating(...)`, and `SessionLogic.isOrphanSubagentFresh(...)` so freshly spawned `0001-01-01` subagents are tracked immediately while crashed/abandoned rows never keep `liveTPS.isWorking` stuck.
  - `LogoVisualState` drives `CoreAnimationLogoView` (`Sources/Views_Common.swift`, rendering `AGYLogo.cgPath(in:flippedForCoreAnimation:)`) entirely on the WindowServer GPU (`0` main-thread frame ticks and `0` AppKit layout passes during `.levitate` / `.breatheOpacity`).
  - `DoneUnseenState` encapsulates `prevStatuses` + `doneUnseen` and resets cleanly on `stop()`.
  - `JumpRequestGate` enforces latest-wins jump generation so rapid clicks supersede slow queued `osascript` jumps and suppress stale hints.
  - `MenuBarAnchorState` freezes status-item text & width before panel presentation so synchronous refreshes never shift the anchor mid-open, flushing atomically on close.
  - `MenuBarAnchorResolver` validates `statusItem.button` against every connected display's usable menu-bar region (accepting negative-coordinate secondary displays and RTL `auxiliaryTopLeftArea`, rejecting off-screen parked windows, notch-occluded icons, hidden/alpha-0 windows, and degenerate rects), pins coordinates directly below the clicked icon on ephemeral menu bars (native Fullscreen Space via `FullscreenDetector` or auto-hidden menu bar), computes deterministic top-right fallback coordinates when the icon is hidden/off-screen, and positions/resizes the borderless Control-Center-style floating `MenuBarPanel` (`panelFrame` / top-pinned `resizedPanelFrame`, returning `.unavailable` when zero displays exist) and right-click `NSMenu`.
  - `MenuBarPanelMachine` (`.closed | .opening(token:) | .open | .closing(token:)`) replaces ad-hoc popover flags with monotonic animation tokens, tracks nested `NSMenu` tracking depth (`activeMenuTrackingDepth`) so outside clicks / deactivation never dismiss the panel mid-menu, suppresses status-item double-bounce clicks (`suppressedStatusItemClickUntil`), and drives `.presentPanel` / `.dismissPanel` / `.orderOutPanel` / dismiss monitors deterministically.

### 7. Live Output Telemetry (TPS Tracker, Turn Duration Inference, EMA Decay & Display Hysteresis)
- **Core**: `Sources/Core_LiveTelemetry.swift` (`LiveTPSTracker`, `LiveTPSSnapshot`, `OutputTokenSample`, `ContextWindowCatalog`, `SessionContextSnapshot`, `ContextPressureLevel`) & `Sources/Core_Transcript.swift` (`TranscriptParse.scan(_:fileMtime:)`, `TranscriptParse.scan(text:fileMtime:)`)
- **Shell**: `Sources/SessionMonitor.swift`, `Sources/SessionStore.swift`, `Sources/AITitleReader.swift`, `Sources/AppDelegate.swift`, `Sources/NotchView.swift`, `Sources/Views_Session.swift`, `Sources/Views_InstrumentSession.swift`
- **Tests**: `Tests/AGYCoreTests/LiveTelemetryTests.swift`, `Tests/AGYCoreTests/TranscriptTests.swift`
- **Key Invariants**:
  - `TranscriptParse.scan(..., fileMtime:)` resolves each `PLANNER_RESPONSE` turn's completion bound (`completedAt`, from the subsequent automated continuation step or `fileMtime` for a trailing response, bounded by `maxInferredTurnDuration = 600s`) and attaches explicit `OutputTokenSample.durationSeconds` (`>= 1.0s`) so long coding/subagent turns compute true token throughput instead of artificial spikes.
  - `LiveTPSTracker.update(busySessionIds:subagentIds:samplesBySession:now:)` aggregates main sessions plus active CLI/Desktop/IDE/nested/workflow/swarm subagents (`LiveTPSSnapshot.activeSubagentCount`) across 4 deterministic branches:
    - **Branch 1** (`inWindow.count >= 2`): uses `max(span, explicitDur)` when `inWindow.count == 2` and `durationSeconds` is present.
    - **Branch 2a** (explicit `durationSeconds` on the latest sample within `90s`): accurate for long `45s–300s` and 1-turn subagents without dividing by a prior turn's span, decaying smoothly past `12s` staleness.
    - **Branch 2b** (legacy 2-sample consecutive fallback within `90s` age & `180s` pair span): covers samples without `durationSeconds`.
    - **Branch 3** (single-sample window up to `max(windowSeconds, 35s)`): covers 1-turn subagents without explicit duration, decaying past `12s`; **Branch 4** decays idle gaps during active turns via wall-clock EMA (`pow(decayPerSecond, dt)` with `decayPerSecond = pow(0.88, 0.5)`) consistently regardless of poll cadence (`2s` active vs `6s`/`15s` idle).
  - Tracks `(stepIndex, outputTokens)` tuples so in-place streaming updates on the same step measure exact incremental output deltas without double-counting, and throttles sparkline appends to `sparklineMinAppendInterval = 1.5s` (updating the trailing point in place within the window).
  - `LiveTPSSnapshot` exposes Schmitt-trigger display hysteresis (`shouldShowInNotch`: show ≥ `0.8`, hide < `0.35`; `shouldShowInMenuBar`: show ≥ `1.0`, hide < `0.5`) so live TPS readouts never flicker near idle.

### 8. Black Box Mission Replay (Index/Timeline Store & Playback Transport)
- **Core**: `Sources/Core_Replay.swift` — `ReplayStoreMachine` (`ReplayIndexPhase`, `ReplayTimelinePhase`, `ReplayStoreState`, `ReplayStoreEvent`, `ReplayStoreEffect`), `ReplayPlaybackMachine` (`ReplayPlayPhase`, `ReplayHapticCue`, `ReplayPlaybackState`, `ReplayPlaybackEvent`, `ReplayPlaybackEffect`, `ReplaySpeed`), `ReplayLogic`
- **Shell**: `Sources/SessionStore.swift`, `Sources/SessionReplayService.swift`, `Sources/Views_Session.swift`, `Sources/Views_SessionReplay.swift`
- **Tests**: `Tests/AGYCoreTests/ReplayTests.swift`
- **Key Invariants**:
  - `ReplayStoreMachine` guards both index scans (`indexGeneration`) and timeline loads (`timelineGeneration`) with monotonic generations so rapid mission switches or background refreshes never overwrite the active selection; `indexFreshnessTTL = 5.0s` prevents redundant disk scans when re-entering Black Box while honoring `force: true` and `pendingPreferredMissionId`.
  - `ReplayPlaybackMachine` models `.paused | .playing | .scrubbing(wasPlaying:)` with integrated radar `sweepAngleDeg` (90°/s while playing with motion enabled; stationary when `reduceMotion == true` while `progress` still advances normally), emits `.startTimer` / `.stopTimer` strictly gated on `isActive` (0 Hz idle CPU when paused/hidden), and emits typed `.haptic(ReplayHapticCue)` cues on play toggle, scrub detents, anomaly entry, event stepping, and speed changes.

### 9. Craft & Archival Export Lifecycles (Haptics, Acoustics, Blueprint Wallpaper & Specimen Exporter)
- **Core**: `Sources/Core_CraftState.swift` — `HapticCadenceMachine` (`InstrumentHapticCue`, `HapticPatternKind`, `HapticFollowUp`, `HapticRecipe`, `HapticCadenceState`, `HapticCadenceEvent`, `HapticCadenceEffect`), `AcousticTriggerState`, `AcousticEngineLifecycleMachine` (`AcousticEnginePhase`, `AcousticEngineState`, `AcousticEngineEvent`, `AcousticEngineEffect`), `BlueprintWallpaperMachine` (`DailyWallpaperGate`, `BlueprintWallpaperPath`, `BlueprintWallpaperTrigger`, `BlueprintWallpaperPhase`, `BlueprintWallpaperState`, `BlueprintWallpaperEvent`, `BlueprintWallpaperEffect`), `SpecimenExporterMachine` (`SpecimenAppearanceChoice`, `SpecimenExportPhase`, `SpecimenFeedbackKind`, `SpecimenExporterState`, `SpecimenExporterEvent`, `SpecimenExporterEffect`)
- **Shell**: `Sources/CraftEngine.swift`, `Sources/WallpaperGenerator.swift`, `Sources/SpecimenExporter.swift`, `Sources/Views_Specimen.swift`, `Sources/Views_Menus.swift`, `Sources/AppDelegate.swift`
- **Tests**: `Tests/AGYCoreTests/CraftStateTests.swift`
- **Key Invariants**:
  - `HapticCadenceMachine` owns all 19 `InstrumentHapticCue` recipes, rate-limiting, `salientInterruptFloor = 0.018s`, nullable `lastFiredAt` (so initial fires at `now == 0` succeed), and monotonic `cadenceGeneration` so cancelled or superseded secondary follow-up taps never fire late.
  - `AcousticTriggerState` requires `hasCompletedInitialScan == true` before arming baselines (eliminating false boot chimes) and supports clean `reset()` on monitor stop.
  - `AcousticEngineLifecycleMachine` owns in-memory 44-byte RIFF/WAVE PCM16 `NSSound(data:)` playback retention and teardown (`idleHoldSec = 0.50s`), accumulating `drainUntil = max(currentDrainUntil, now) + bufferDuration` across rapid consecutive chimes with monotonic teardown generation guards and clean `.configurationChanged` / `.disabled` / `.terminate` handling (zero `AVAudioEngine` / CoreAudio graph crash risk on audio route switches).
  - `BlueprintWallpaperMachine` models `.idle | .awaitingYearData | .applying` with monotonic generation guards, 5-minute failure backoff (`failureBackoffSeconds = 300.0`), atomic preference persistence, toggle-OFF cancellation (`.styleChanged(enabled: false, ...)` increments `generationCounter` and resets `.awaitingYearData`/`.applying` to `.idle` for `.dailyAuto`/`.styleChange` while preserving `.manualApply`), and strict managed-path detection (`BlueprintWallpaperPath.isManagedPath` requiring trailing `/` boundary + `agy-blueprint-` prefix) so restoring the user's original desktop wallpaper never loops onto a generated blueprint.
  - `SpecimenExporterMachine` owns presentation, aspect ratio, appearance choice, `.idle | .saving` re-entrancy guard, and generation-stamped `TransientBannerState` feedback (`feedbackDuration = 1.8s`).

### 10. Interactive UI State Machines (Sessions Deck & Keys, Cursor Stack, Dual-Axis Focus, Time/Chart Inspection, Keyed Panel Height, Bounded LRU, Animation Gate & Tab Transitions)
- **Core**: `Sources/Core_UIState.swift` — `SessionDeckMachine` (`SessionDeckMode`, `SessionDeckState`, `SessionDeckEvent`, `SessionDeckEffect`), `SessionKeyRouter`, `CursorStackState`, `ModelFocusState`, `TokenFlowFocus<Channel>`, `ChartInspectionState<Scope, Target>`, `PolarHoverTarget`, `PolarChronometerInspectionState`, `MonthElevationFocus`, `YearContourHoverTarget`, `PanelHeightState<Key>`, `BoundedLRUState<Key, Value>`, `TransientBannerState`, `TabTransitionState<ID>`, `TelemetryAnimationGate`
- **Shell**: `Sources/Views.swift`, `Sources/Views_Time.swift`, `Sources/Views_Session.swift`, `Sources/Views_SessionReplay.swift`, `Sources/Views_InstrumentSession.swift`, `Sources/Views_InstrumentCost.swift`, `Sources/Views_InstrumentTokens.swift`, `Sources/Views_InstrumentTime.swift`, `Sources/Views_InstrumentPlan.swift`, `Sources/Views_Cards.swift`, `Sources/Views_Common.swift` (`PointingCursorCoordinator`, `TelemetryArtworkCache`), `Sources/SessionStore.swift`
- **Tests**: `Tests/AGYCoreTests/UIStateTests.swift`
- **Key Invariants**:
  - `SessionDeckMachine` owns `SessionDeckMode` (`.live | .blackBox`), filter, keyboard selection, and hover reconciliation; `AgentTelemetryRadarView` hit-tests strictly against `visibleSessionIds` so filtered-out dimmed nodes never jump or push a pointing cursor.
  - `SessionKeyRouter` strips macOS's combined `[.numericPad, .function]` arrow-key flags, gates strictly on `isPanelVisible && isSessionTabActive`, and routes Up/Down/Return in `.live` mode and Space/Left/Right replay transport in `.blackBox` mode.
  - `CursorStackState` + `PointingCursorCoordinator` reference-count hover tokens (`0 → 1` pushes `pointingHand`, `1 → 0` pops, `releaseAll()` resets synchronously on panel close) with zero view-local `isPointingCursor` shadow booleans and full token release on `isPanelVisible == false` and `.onDisappear`.
  - `ModelFocusState` arbitrates borehole core-column vs callout-row hover and clears parent focus on unmount; `TokenFlowFocus<TokenChannel>` makes simultaneous `(model, channel)` hover unrepresentable in `FoldedTokenFlowChart`, reading `activeFocusedModelId` consistently and syncing on `focusedModelId`, period/month `scopeKey`, node updates, hide, and `.onDisappear` so channel hover never persists across `TODAY`/`7D`/`MONTH` or month switches.
  - `PolarChronometerInspectionState` unifies dial-arc hover, ledger-day hover (symmetrically mutually exclusive via `PolarHoverTarget`), and click-to-pin (`togglePin` / `tapDial`) with week-scope reconciliation and full `"polar-dial-arc"` + `"polar-ledger-0..6"` cursor release on hide/disappear.
  - `ChartInspectionState<Scope, Target>` enforces zero-frame-lag scope guards across Cost, Tokens, and all Time charts (`MonthElevationInteractiveDeck` via `MonthElevationFocus`, `YearContourInteractiveStage` via `YearContourHoverTarget` rejecting adjacent-year padding cells so the crosshair reticle never orphans, plus classic `WeekTimeChart`, `MonthTimeChart`, and `YearHeatmap`), clearing atomically on scope change, hide, and `.onDisappear`.
  - `PanelHeightState<PanelHeightKey>` + `PanelHeightBudget` key height memory by 11 dimensions `(tab, visualMode, periodScope, timeRange, isCurrentMonth, contentPhase, sessionBucket, sessionDeckMode, sessionFilter, replayBucket, monthWeekRows)`, skip `PopoverHeightMemory` persistence for transient/filtered states (`shouldPersistToMemory`), retain the previous loaded `replayBucket` during transient Black Box `.loading` (suppressing height collapse while stepping missions), consume emitted `@Published` Combine values directly rather than reading stale `willSet` store properties, clamp scrollable tab content strictly inside `NotchPanel`'s 860pt cap and `MenuBarPanel`'s 820pt cap (so Header, Tab Bar, and Footer stay pinned even with 13+ live sessions), always latch `.unmeasured → .measured` on the first valid measurement `> 1pt`, and enforce surface-aware `allowsAnimation`. `TimeTabView` emits per-range `ContentHeightsKey` from inside `.id(activeRange)` so outgoing ranges never pollute incoming heights.
  - `BoundedLRUState` unifies all 6 LRU caches across artwork and instrument math (fixing FIFO hit eviction and supporting `trim(to:)`), while `PolarSweepArtworkCache` (2-entry dedicated LRU) and quantized `ProtractorArtworkKey` prevent live time overlays from thrashing the global 16-entry `TelemetryArtworkCache` (which trims to 6 after 15s of closed idle and to 4/0 under macOS memory pressure).
  - `TelemetryAnimationGate` + root `@Environment(\.telemetryReduceMotion)` enforce 0 Hz idle CPU across all `TimelineView`s with a single root `NSWorkspace` observer instead of per-row NotificationCenter fan-out.
  - `TabTransitionState` is the single source of truth for active tab / Time sub-tab (zero shadow `displayedTab`/`displayedRange`), using canonical full tab order so hiding `.subscription` slides `.backward` to `.cost`.

### 11. GitHub Releases Update Checker & One-Time System Notification
- **Core**: `Sources/Core_UpdateState.swift` — `UpdateCheckerMachine` (`UpdateCheckerState`, `UpdateCheckerEvent`, `UpdateCheckerEffect`, `UpdateCheckPhase`, `UpdateBannerDisplay`, `UpdateTiming`, `SemanticVersion`, `ReleaseInfo`, `UpdateReleaseParser`)
- **Shell**: `Sources/UpdateService.swift`, `Sources/UsageStore.swift`, `Sources/AppDelegate.swift`, `Sources/Views.swift` (`UpdateBannerStrip`), `Sources/Views_Menus.swift`
- **Tests**: `Tests/AGYCoreTests/UpdateStateTests.swift`
- **Key Invariants**:
  - Primary check uses a zero-API-quota `HEAD https://github.com/kuen54/AGYMonitor/releases/latest` 302 redirect capture (falling back to the GitHub REST API only if needed) and validates that all release & download URLs strictly match `https://github.com/kuen54/AGYMonitor/releases/...`.
  - Automatic checks wait 10s after launch/wake and run at most once every 24h (retrying in 2h on transient failure without advancing `lastCheckAt`); automatic checking, up-to-date, and failures stay completely silent in-app.
  - `UpdateCheckerState.isManualChecking` (`case .checking(.manual) = phase`) drives manual-check menu/button state directly from the reducer with zero shell shadow booleans.
  - Each newly discovered version (`remote > current`, non-prerelease) posts a macOS `UNUserNotificationCenter` notification **at most once** across restarts (`notifiedVersion` persisted atomically in the reducer), while storing `knownRelease` orthogonally to transient check phases (and restoring from `cachedLatestTag` across restarts) so offline retries or manual check failures never flicker or wipe a known update banner until upgraded or skipped.
  - Skipping a version hides the banner until either a newer version ships or the user manually triggers "Check for Updates…" (which un-skips that version). `UNUserNotificationCenter.current()` is strictly guarded to `.app` bundles with a `CFBundleIdentifier` so `docs/render_mockups.swift` and CLI runs never crash.

---

## Intentionally Stateless / Local Boundaries (Do NOT Extract to `AGYCore`)

To preserve crisp DX and prevent over-abstraction, the following components are intentionally kept out of `Core_*State.swift`:
- **Impure OS / FFI / Hardware Bridges**: `NotchFullscreen.swift` (one-shot `dlopen`/`dlsym` SkyLight wrappers), `ProcessRunner.swift` & `UsageScriptClient.swift` (locked `SIGTERM → SIGKILL` subprocess watchdogs), `AITitleReader.swift` (stateless Foundation file reader), `SessionReplayService.swift` (stateless disk/transcript reader shell feeding `ReplayLogic` & `ReplayStoreMachine`), and the AppKit/`NSSound`/`NSHapticFeedbackManager`/`NSWorkspace`/`NSSavePanel` I/O edges inside `CraftEngine.swift`, `WallpaperGenerator.swift`, and `SpecimenExporter.swift` (whose lifecycles live in `Core_CraftState.swift`).
- **Stateless Geometry / Rendering**: `AGYLogo.swift`, `ArchivalGrainOverlay` (immutable pre-baked static tiles), `Core_Instruments.swift` pure math, and stateless `Canvas` drawing layers.
- **Single-Control Local Visual Hover**: Isolated `@State private var hovering = false` highlights on single buttons (`ToolbarIconButton`, `TelemetryStepper`) or single-strip hover highlight (`TokensInstrumentView.hoveredScope`, cleared on `.onDisappear`) that have no cross-view coupling or global side effects.
- **Locale Memoization**: `UsageStore.monthLabelFormatters` & `TimeDateFormatters` (small `NSLock` caches bounded by `AppLanguage.allCases.count`).
