# AGYMonitor State Machines — Canonical Architecture Map

Every non-trivial stateful lifecycle in AGYMonitor is modeled as a **pure, Foundation-only, `Equatable & Sendable` state machine** inside `AGYCore` (`Sources/Core_*.swift`) and driven by a thin AppKit / SwiftUI shell.

This document serves as the single reference for **UX invariants**, **DX maintenance**, and **AX (coding-agent) navigation**.

## Architectural Contract

1. **Pure Core (`Sources/Core_*.swift`)**: `import Foundation` only. No `AppKit`, `SwiftUI`, `Combine`, `Dispatch`, `FileManager`, `SQLite3`, or `Process`.
2. **Explicit Effects**: Reducers mutate `inout State` and return `[Effect]` (or a typed transition decision). Shells contain a single `dispatch(_ event)` switch executing effects.
3. **Zero Shadow Booleans**: Never introduce parallel `Bool` flags (`isRunning`, `isHovering`, `preventClose`, raw `fetchGeneration += 1`, raw `NSCursor.push/pop`) in app shells when a state machine already owns that domain.
4. **Deterministic Tests**: Every invariant below is verified in milliseconds by `swift test` (`bash scripts/check.sh`).

---

## Complete State Machine Registry

### 1. App Presentation & Surface Lifecycle
- **Core**: `Sources/Core_AppState.swift` — `AppPresentationMachine` (`AppPresentationState`, `AppPresentationEvent`, `AppPresentationEffect`)
- **Shell**: `Sources/AppDelegate.swift`, `Sources/NotchController.swift`
- **Tests**: `Tests/AGYCoreTests/AppStateTests.swift`
- **Key Invariants**:
  - `isPanelVisible` is derived solely from the active surface (`menubar ? popoverOpen : notchOpen`).
  - A delayed `NSPopoverDelegate.popoverDidClose` arriving after switching to `.notch` NEVER clears an open notch's `isPanelVisible` or session-monitor cadence.
  - Switching surfaces always syncs `statusItem.isVisible`, `menuBarModel.isVisible`, `menuBarAnchor`, and `NotchController` start/stop atomically.
  - Global hotkey registration is idempotent.

### 2. Notch Hover, Fullscreen Edge-Reveal, Clickable Wing & Modal Locks
- **Core**: `Sources/Core_NotchState.swift` — `NotchMachine` (`NotchState`, `NotchPhase`, `NotchPointerSample`, `NotchEvent`, `NotchEffect`, `NotchPanelPresentation`)
- **Shell**: `Sources/NotchController.swift`, `Sources/NotchView.swift`, `Sources/Views_Menus.swift`
- **Tests**: `Tests/AGYCoreTests/NotchStateTests.swift`
- **Phases**: `.hidden` ↔ `.closedPill` ↔ `.openingDwell` → `.open` ↔ `.closingGrace`
- **Key Invariants**:
  - Overlapping `NSMenu` / `NSAlert` modal locks (`Set<NotchModalLock>`) pin the panel open until the last lock releases, then immediately enter `.closingGrace` if the pointer is outside.
  - Fullscreen hides the idle pill until the cursor touches the top 8pt edge (`revealArmed`).
  - `panelPresentation(for:pointer:)` checks `!visible` FIRST — an invisible fullscreen panel (`alphaValue == 0`) NEVER intercepts clicks, even when a Live Wing alert is active (`inClickableWing == true`).

### 3. Notch Live Wing Priority & Auto-Retract
- **Core**: `Sources/Core_Telemetry.swift` — `NotchLiveWingMachine` (`NotchLiveWingState`, `NotchWingKind`, `NotchLiveWingEvent`, `NotchLiveWingEffect`)
- **Shell**: `Sources/NotchController.swift`, `Sources/NotchView.swift`
- **Tests**: `Tests/AGYCoreTests/TelemetryTests.swift`
- **Key Invariants**:
  - `.waiting` (preferring `needsConfirm`) always preempts `.done` and cancels pending done-retract timers.
  - `.done` banners announce once per unseen session (`announcedDoneIds`) and auto-retract after 5s.
  - Dismissing a waiting wing suppresses re-surfacing until that session leaves and re-enters waiting.

### 4. Usage Loading, Navigation & Background Gates
- **Core**: `Sources/Core_UsageState.swift` — `LoadPhase<Value>`, `RefreshQueueState`, `MonthNavigationState`, `HistoricalMonthLoadGate`, `YearLoadGate`, `ArchiveSweepGate`
- **Shell**: `Sources/UsageStore.swift`, `Sources/Views.swift`, `Sources/Views_Time.swift`
- **Tests**: `Tests/AGYCoreTests/UsageStateTests.swift`
- **Key Invariants**:
  - Current-month, historical-month, and year scopes have isolated `LoadPhase`s so background scans never clobber historical views.
  - `RefreshQueueState` queues a forced follow-up when `⌘R` arrives during a non-forced scan.
  - `MonthNavigationState` auto-advances across midnight month boundaries ONLY when `followingCurrentMonth == true`.
  - `HistoricalMonthLoadGate` & `YearLoadGate` deduplicate overlapping non-forced requests and reject stale completions by monotonic generation.
  - `ArchiveSweepGate` only records `lastSucceededAt` on success so failures remain immediately retryable.

### 5. Plan Quota, Auth, 429 Cooldown, Fetch Coalescing & SWR Token Probe
- **Core**: `Sources/Core_QuotaState.swift` — `QuotaPhase<Snapshot>`, `QuotaCooldownState`, `LiveQuotaHTTPOutcome`, `QuotaStateReducer`, `QuotaFetchGate`, `TokenPresenceProbeState`
- **Shell**: `Sources/QuotaService.swift`, `Sources/UsageStore.swift`, `Sources/Views_Plan.swift`
- **Tests**: `Tests/AGYCoreTests/QuotaStateTests.swift`
- **Key Invariants**:
  - HTTP `401`/`403` transitions to `.failed(.unauthorized)` while keeping `hasAccountSurface == true` so the Plan tab remains accessible to show the re-auth hint.
  - Offline desktop fallback during HTTP `429` preserves `QuotaCooldownState.rateLimitedUntil` and surfaces the rate-limit notice banner.
  - `QuotaFetchGate` serves TTL cache, enforces 429 cooldowns, coalesces overlapping fetches, and upgrades an in-flight non-forced fetch with a single forced follow-up on `⌘R` (still honoring any newly recorded 429 cooldown).
  - `TokenPresenceProbeState` performs non-overlapping stale-while-revalidate probes (`60s` TTL).
  - `QuotaStateReducer.shouldAutoRefreshOnTabEntry` suppresses redundant probes while `.loading` or actively cooling down from a 429.

### 6. Session Monitor Lifecycle, Cadence, Throttle, Menu Anchor & Done-Unseen
- **Core**: `Sources/Core_MonitorState.swift` (`SessionMonitorLifecycleMachine`, `SessionPollCadence`, `FSEventsThrottleState`, `MenuBarAnchorState`, `LogoVisualState`) & `Sources/Core_Sessions.swift` (`SessionLogic.stepDoneUnseen`)
- **Shell**: `Sources/SessionMonitor.swift`, `Sources/AppDelegate.swift`, `Sources/Views_Common.swift`
- **Tests**: `Tests/AGYCoreTests/MonitorStateTests.swift`, `Tests/AGYCoreTests/SessionsTests.swift`
- **Key Invariants**:
  - `SessionMonitorLifecycleMachine` guarantees `start()`/`stop()` idempotency and makes post-`stop()` FS-coalesce or timer callbacks strict no-ops (cannot spawn `ps`/`lsof` or emit `onChange`).
  - `FSEventsThrottleState` enforces a 120s minimum floor across ALL refresh sources (`⌘R`, wake, timer, popover open, FSEvents).
  - `MenuBarAnchorState` freezes status-item text & width while `NSPopover` is open so the anchor never drifts horizontally, flushing atomically on close.
  - `SessionLogic.stepDoneUnseen` tracks `busy/waiting → idle` transitions and decays unseen badges cleanly.

### 7. Interactive UI State Machines (Sessions Deck, Cursor Stack, Model Focus, Transient Banners)
- **Core**: `Sources/Core_UIState.swift` — `SessionDeckMachine`, `CursorStackState`, `ModelFocusState`, `TransientBannerState`
- **Shell**: `Sources/Views_Session.swift`, `Sources/Views_InstrumentSession.swift`, `Sources/Views_InstrumentCost.swift`, `Sources/Views_Cards.swift`, `Sources/Views_Common.swift` (`PointingCursorCoordinator`), `Sources/SessionStore.swift`
- **Tests**: `Tests/AGYCoreTests/UIStateTests.swift`
- **Key Invariants**:
  - `SessionDeckMachine` reconciles `selectedSessionId` & `hoveredSessionId` on every filter switch or session-list update so pressing `Return` NEVER jumps to a hidden/filtered-out session.
  - `CursorStackState` + `PointingCursorCoordinator` reference-count hover tokens (`0 → 1` pushes `pointingHand`, `1 → 0` pops, `releaseAll()` resets on panel close), preventing global `NSCursor` stack corruption.
  - `ModelFocusState` arbitrates borehole core-column vs callout-row hover and reconciles removed model IDs so charts never get stuck dimmed.
  - `TransientBannerState` stamps each banner with a monotonic generation token so an expired timer from an older jump hint can NEVER clear a newer hint.
