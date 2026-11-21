# AGYMonitor State Machines — Canonical Architecture Map

Every non-trivial stateful lifecycle in AGYMonitor is modeled as a **pure, Foundation-only, `Equatable & Sendable` state machine** inside `AGYCore` (`Sources/Core_*.swift`) and driven by a thin AppKit / SwiftUI shell.

This document serves as the single reference for **UX invariants**, **DX maintenance**, and **AX (coding-agent) navigation**.

## Architectural Contract

1. **Pure Core (`Sources/Core_*.swift`)**: `import Foundation` only. No `AppKit`, `SwiftUI`, `Combine`, `Dispatch`, `FileManager`, `SQLite3`, or `Process`.
2. **Explicit Effects**: Reducers mutate `inout State` and return `[Effect]` (or a typed transition decision). Shells contain a single `dispatch(_ event)` switch executing effects.
3. **Zero Shadow Booleans**: Never introduce parallel `Bool` flags (`isStarted`, `isHovering`, `isPointingCursor`, `preventClose`, raw `fetchGeneration += 1`, raw `NSCursor.push/pop`, duplicate `displayedTab`/`displayedRange`, or dead `NotchViewModel.anyBusy`) in app shells when a state machine owns that domain.
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
  - A delayed `NSPopoverDelegate.popoverDidClose` arriving after switching to `.notch` NEVER clears an open notch's `isPanelVisible` or session-monitor cadence.
  - Switching surfaces always syncs `statusItem.isVisible`, `menuBarModel.isVisible`, `menuBarAnchor`, and `NotchController` start/stop atomically, and releases `PointingCursorCoordinator` synchronously on hide.
  - Global hotkey registration is idempotent; Carbon registration failures dispatch `.hotkeyRegistrationFailed` so `isHotkeyRegistered` stays truthful.

### 2. Notch Hover, Multi-Display Coordinator, Split Geometry, Fullscreen Edge-Reveal & Modal Locks
- **Core**: `Sources/Core_NotchState.swift` — `NotchMachine` (`NotchState`, `NotchPhase`, `NotchPointerSample`, `NotchEvent`, `NotchEffect`, `NotchPanelPresentation`, `NotchTiming`), `NotchGeometryState`, `NotchCoordinatorMachine` (`NotchCoordinatorState`, `NotchDisplayDescriptor`, `NotchScreenReconcilePlan`)
- **Shell**: `Sources/NotchController.swift`, `Sources/NotchView.swift`, `Sources/Views_Menus.swift`
- **Tests**: `Tests/AGYCoreTests/NotchStateTests.swift`
- **Phases**: `.hidden` ↔ `.closedPill` ↔ `.openingDwell` → `.open` ↔ `.closingGrace`
- **Key Invariants**:
  - `NotchState.lastPointerSample` deduplicates unchanged mouse moves inside the reducer AND auto-invalidates on every non-pointer transition (`explicitReveal`, `fullscreenChanged`, geometry/wing changes) so `⌥⇧A` open and Space switches NEVER swallow subsequent mouse movement.
  - `NotchGeometryState` strictly separates `closedWidth/closedHeight` from `openWidth/openHeight` and aligns initial `compactGapOffset` (`+8.5`), so closing the notch can NEVER feed expanded popover dimensions into `closedWingRect` click hit-testing.
  - `NotchCoordinatorMachine` owns `isStarted` (zero shadow bool), incrementally reconciles screens (preserving live open/modal state on surviving displays instead of destructive rebuild), enforces single-open display exclusivity across multi-monitor setups, selects primary display deterministically (cursor → builtin → main → lowest ID), and diffs visibility so mid-fade mouse moves never restart alpha animations.
  - Overlapping `NSMenu` / `NSAlert` modal locks (`Set<NotchModalLock>`) pin the panel open until the last lock releases, then immediately enter `.closingGrace` if the pointer is outside.
  - `panelPresentation(for:pointer:)` checks `!visible` FIRST — an invisible fullscreen panel (`alphaValue == 0`) NEVER intercepts clicks, even when a Live Wing alert is active (`inClickableWing == true`).

### 3. Notch Live Wing Priority & Auto-Retract
- **Core**: `Sources/Core_Telemetry.swift` — `NotchLiveWingMachine` (`NotchLiveWingState`, `NotchWingKind`, `NotchLiveWingEvent`, `NotchLiveWingEffect`)
- **Shell**: `Sources/NotchController.swift`, `Sources/NotchView.swift`
- **Tests**: `Tests/AGYCoreTests/TelemetryTests.swift`
- **Key Invariants**:
  - `.waiting` (preferring `needsConfirm`) always preempts `.done` and cancels pending done-retract timers.
  - `.done` banners announce once per unseen session (`announcedDoneIds`) and auto-retract after 5s.
  - Dismissing a waiting wing suppresses re-surfacing until that session leaves and re-enters waiting.
  - `NotchController.stop()` resets `wingState` cleanly alongside `wingTimer`.

### 4. Usage Loading, Navigation, Snapshot Completeness & Background Gates
- **Core**: `Sources/Core_UsageState.swift` — `LoadPhase<Value>`, `RefreshQueueState`, `MonthNavigationState`, `HistoricalMonthLoadGate`, `YearLoadGate`, `ArchiveSweepGate`, `SnapshotFreshnessPolicy`
- **Shell**: `Sources/UsageStore.swift`, `Sources/UsageArchive.swift`, `Sources/Views.swift`, `Sources/Views_Time.swift`
- **Tests**: `Tests/AGYCoreTests/UsageStateTests.swift`
- **Key Invariants**:
  - Current-month, historical-month, year, and Plan quota scopes have isolated phases; `UsageStore.isLoading` reflects the active tab (including `.subscription`).
  - `SnapshotFreshnessPolicy.isCompleteHistoricalSnapshot` requires `lastUpdated >= startOfNextMonth(year, month)` so mid-month disk caches (e.g. Oct 15) never permanently truncate a historical month when viewed later; disk writes are `.atomic`.
  - `RefreshQueueState` queues a forced follow-up when `⌘R` arrives during a non-forced scan, re-entering `.loading(cached:)` while the follow-up executes.
  - `MonthNavigationState` auto-advances across midnight month boundaries ONLY when `followingCurrentMonth == true`; `SnapshotFreshnessPolicy.clampedYear` bounds year navigation to `[1970, currentYear]`.
  - `HistoricalMonthLoadGate` & `YearLoadGate` deduplicate overlapping non-forced requests, reject stale completions by monotonic generation, and cancel `activeYear` when switching back to a cached year (eliminating `2026 → 2025 → 2026 → 2025` stuck-year display).
  - `ArchiveSweepGate` is generation-stamped (`beginSweep` / `finish(generation:)` / `reset()`) so `clearArchive()` or disabling `archiveHistoryLocally` invalidates in-flight sweeps, clears `archiveSweptThrough`, and invalidates `yearTimeCache`.
  - `UsageArchive` enqueues `ioQueue.async` while holding `lock` so `clear()` and concurrent `merge()` disk writes strictly preserve lock order.

### 5. Plan Quota, Auth, 429 Cooldown, Fetch Coalescing & Generation-Stamped SWR Probe
- **Core**: `Sources/Core_QuotaState.swift` — `QuotaPhase<Snapshot>`, `QuotaCooldownState`, `LiveQuotaHTTPOutcome`, `QuotaStateReducer`, `QuotaFetchGate`, `TokenPresenceProbeState`
- **Shell**: `Sources/QuotaService.swift`, `Sources/UsageStore.swift`, `Sources/Views_Plan.swift`
- **Tests**: `Tests/AGYCoreTests/QuotaStateTests.swift`
- **Key Invariants**:
  - `QuotaFetchGate` checks active HTTP `429` cooldown **before** fresh TTL cache so non-forced refreshes within 60s NEVER wipe an active 429 banner; cached offline fallbacks preserve their `liveError` + `retryAt` notice across TTL hits.
  - `SubscriptionQuotaService` runs blocking Keychain/SQLite/CLI probes on an off-gate `probeQueue` so `workQueue` gate serialization never stalls behind 16s subprocess timeouts.
  - HTTP `401`/`403` transitions to `.failed(.unauthorized)` while keeping `hasAccountSurface == true` so the Plan tab remains accessible to show the re-auth hint.
  - `.beginFetch` transitions both `.noAccount` and `.failed` to `.loading` so clicking Retry immediately gives loading feedback; `.cooldownExpired(now:)` clears expired 429 notices and unlocks Retry when `retryAt` passes while viewing Plan.
  - `TokenPresenceProbeState` stamps background SWR probes with a monotonic `generation` so a slow async probe can NEVER overwrite a newer forced `probeTokenPresenceNow()`.

### 6. Brain Watcher, Session Monitor Lifecycle, Cadence, Done-Unseen, Jump Gate & Menu Anchor
- **Core**: `Sources/Core_MonitorState.swift` (`BrainWatcherLifecycleMachine`, `SessionMonitorLifecycleMachine`, `SessionPollCadence`, `FSEventsThrottleState`, `DoneUnseenState`, `MenuBarAnchorState`, `MenuBarAnchorResolver`, `PopoverAnchorSessionState`, `LogoVisualState`) & `Sources/Core_Sessions.swift` (`SessionLogic.stepDoneUnseen`, `SessionLogic.resolveLiveSessionStatus`, `SessionLogic.matchWeztermPaneId`, `JumpRequestGate`)
- **Shell**: `Sources/AppDelegate.swift`, `Sources/SessionMonitor.swift`, `Sources/SessionStore.swift`, `Sources/SessionJumper.swift`, `Sources/Views_Common.swift`
- **Tests**: `Tests/AGYCoreTests/MonitorStateTests.swift`, `Tests/AGYCoreTests/SessionsTests.swift`
- **Key Invariants**:
  - `BrainWatcherLifecycleMachine` owns `AppDelegate`'s FSEvents watcher, 30m periodic timer, wake debounce, and `FSEventsThrottleState`. Every `.refreshTriggered` cancels pending FSEvent debounces (protecting the 120s minimum floor), `.reconcileWatchPaths` picks up newly installed Antigravity surfaces, and `.terminate` cleans up all timers & streams.
  - `SessionMonitorLifecycleMachine` preserves `setActive(true)` even before `start()`, bumps `runGeneration` on `stop()` so post-`stop()` async `onChange`/`markSeen` callbacks are strict no-ops, avoids Desktop/IDE-only 30s watcher thrash, and cleans up `FSEventStream` in `deinit`.
  - `DoneUnseenState` encapsulates `prevStatuses` + `doneUnseen` and resets cleanly on `stop()`.
  - `JumpRequestGate` enforces latest-wins jump generation so rapid clicks supersede slow queued `osascript` jumps and suppress stale hints.
  - `MenuBarAnchorState` freezes status-item text & width in `popoverWillShow` (before open animation) so synchronous refreshes never shift the anchor mid-open, flushing atomically on close.
  - `MenuBarAnchorResolver` validates `statusItem.button` against every connected display's usable menu-bar region (accepting negative-coordinate secondary displays and RTL `auxiliaryTopLeftArea`, rejecting off-screen parked windows, notch-occluded icons, hidden/alpha-0 windows, and degenerate rects), pins coordinates directly below the clicked icon on ephemeral menu bars (native Fullscreen Space via `FullscreenDetector` or auto-hidden menu bar), computes deterministic top-right fallback coordinates when the icon is hidden/off-screen, and positions/resizes the borderless Control-Center-style floating `MenuBarPanel` (`panelFrame` / top-pinned `resizedPanelFrame`, returning `.unavailable` when zero displays exist) and right-click `NSMenu`.
  - `PopoverAnchorSessionState` tracks active anchor mode, suppresses click-to-toggle double-bounce when closing via `statusItem.button`, and resets cleanly on close/surface-switch/terminate.

### 7. Interactive UI State Machines (Sessions Deck & Keys, Cursor Stack, Dual-Axis Focus, Scope-Bound Chart Inspection, Keyed Panel Height, Bounded LRU, Animation Gate & Tab Transitions)
- **Core**: `Sources/Core_UIState.swift` — `SessionDeckMachine`, `SessionKeyRouter`, `CursorStackState`, `ModelFocusState`, `TokenFlowFocus<Channel>`, `ChartInspectionState<Scope, Target>`, `PanelHeightState<Key>`, `BoundedLRUState<Key, Value>`, `TransientBannerState`, `TabTransitionState<ID>`, `TelemetryAnimationGate`
- **Shell**: `Sources/Views.swift`, `Sources/Views_Time.swift`, `Sources/Views_Session.swift`, `Sources/Views_InstrumentSession.swift`, `Sources/Views_InstrumentCost.swift`, `Sources/Views_InstrumentTokens.swift`, `Sources/Views_InstrumentTime.swift`, `Sources/Views_InstrumentPlan.swift`, `Sources/Views_Cards.swift`, `Sources/Views_Common.swift` (`PointingCursorCoordinator`, `TelemetryArtworkCache`), `Sources/SessionStore.swift`
- **Tests**: `Tests/AGYCoreTests/UIStateTests.swift`
- **Key Invariants**:
  - `SessionDeckMachine` reconciles `selectedSessionId` & `hoveredSessionId` on every filter switch or session-list update; `AgentTelemetryRadarView` hit-tests strictly against `visibleSessionIds` so filtered-out dimmed nodes never jump or push a pointing cursor.
  - `SessionKeyRouter` strips macOS's combined `[.numericPad, .function]` arrow-key flags (so ↑/↓ navigation always works) and gates strictly on `isPanelVisible && isSessionTabActive` so outgoing tabs and hidden popovers never hijack `Return`.
  - `CursorStackState` + `PointingCursorCoordinator` reference-count hover tokens (`0 → 1` pushes `pointingHand`, `1 → 0` pops, `releaseAll()` resets synchronously on panel close) with zero view-local `isPointingCursor` shadow booleans.
  - `ModelFocusState` arbitrates borehole core-column vs callout-row hover and clears parent focus on unmount; `TokenFlowFocus<TokenChannel>` makes simultaneous `(model, channel)` hover unrepresentable so header, columns, and ribbons always agree.
  - `ChartInspectionState<Scope, Target>` clears stale hovers atomically whenever month/week/year/`visualMode` or panel visibility changes (preventing `"02/31 NO DATA"` or ghost week arcs).
  - `PanelHeightState<PanelHeightKey>` keys height memory by `(tab, visualMode, timeRange, isCurrentMonth, sessionBucket, monthWeekRows)`, always latches `.unmeasured → .measured` on the first valid measurement `> 1pt` even when within `0.5pt` of default, and enforces surface-aware `allowsAnimation`: Notch mode keeps smooth spring height transitions inside fixed-size `NotchPanel`, while Menu Bar mode (`allowsAnimation: false`) applies non-animated integer-ceiling (`ceil`) sizing so `VStack.height == NSPopover.height` on every frame with zero vertical bounce or AppKit resize-storm drift. `TimeTabView` emits per-range `ContentHeightsKey` from inside `.id(activeRange)` so outgoing ranges never pollute incoming heights.
  - `BoundedLRUState` unifies all 6 LRU caches across artwork and instrument math (fixing FIFO hit eviction), while `PolarSweepArtworkCache` (2-entry dedicated LRU) and quantized `ProtractorArtworkKey` prevent live time overlays from thrashing the global 24-entry `TelemetryArtworkCache`.
  - `TelemetryAnimationGate` + root `@Environment(\.telemetryReduceMotion)` enforce 0 Hz idle CPU across all `TimelineView`s with a single root `NSWorkspace` observer instead of per-row NotificationCenter fan-out.
  - `TabTransitionState` is the single source of truth for active tab / Time sub-tab (zero shadow `displayedTab`/`displayedRange`), using canonical full tab order so hiding `.subscription` slides `.backward` to `.cost`.

### 8. GitHub Releases Update Checker & One-Time System Notification
- **Core**: `Sources/Core_UpdateState.swift` — `UpdateCheckerMachine` (`UpdateCheckerState`, `UpdateCheckerEvent`, `UpdateCheckerEffect`, `UpdateCheckPhase`, `UpdateBannerDisplay`, `UpdateTiming`, `SemanticVersion`, `ReleaseInfo`, `UpdateReleaseParser`)
- **Shell**: `Sources/UpdateService.swift`, `Sources/UsageStore.swift`, `Sources/AppDelegate.swift`, `Sources/Views.swift` (`UpdateBannerStrip`), `Sources/Views_Menus.swift`
- **Tests**: `Tests/AGYCoreTests/UpdateStateTests.swift`
- **Key Invariants**:
  - Primary check uses a zero-API-quota `HEAD https://github.com/kuen54/AGYMonitor/releases/latest` 302 redirect capture (falling back to the GitHub REST API only if needed) and validates that all release & download URLs strictly match `https://github.com/kuen54/AGYMonitor/releases/...`.
  - Automatic checks wait 10s after launch/wake and run at most once every 24h (retrying in 2h on transient failure without advancing `lastCheckAt`); automatic checking, up-to-date, and failures stay completely silent in-app.
  - Each newly discovered version (`remote > current`, non-prerelease) posts a macOS `UNUserNotificationCenter` notification **at most once** across restarts (`notifiedVersion` persisted atomically in the reducer), while storing `knownRelease` orthogonally to transient check phases (and restoring from `cachedLatestTag` across restarts) so offline retries or manual check failures never flicker or wipe a known update banner until upgraded or skipped.
  - Skipping a version hides the banner until either a newer version ships or the user manually triggers "Check for Updates…" (which un-skips that version). `UNUserNotificationCenter.current()` is strictly guarded to `.app` bundles with a `CFBundleIdentifier` so `docs/render_mockups.swift` and CLI runs never crash.

---

## Intentionally Stateless / Local Boundaries (Do NOT Extract to `AGYCore`)

To preserve crisp DX and prevent over-abstraction, the following components are intentionally kept out of `Core_*State.swift`:
- **Impure OS / FFI Boundaries**: `NotchFullscreen.swift` (one-shot `dlopen`/`dlsym` SkyLight wrappers), `ProcessRunner.swift` & `UsageScriptClient.swift` (locked `SIGTERM → SIGKILL` subprocess watchdogs), `AITitleReader.swift` (stateless Foundation file reader).
- **Stateless Geometry / Rendering**: `AGYLogo.swift`, `ArchivalGrainOverlay` (immutable pre-baked static tiles).
- **Single-Control Local Visual Hover**: Isolated `@State private var hovering = false` highlights on single toolbar buttons (`ToolbarIconButton`, `TelemetryStepper`) that have no cross-view coupling or global side effects.
- **Locale Memoization**: `UsageStore.monthLabelFormatters` & `TimeDateFormatters` (small `NSLock` caches bounded by `AppLanguage.allCases.count`).
