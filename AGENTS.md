# AGYMonitor — Developer & Agent Guide

Native macOS (13+) menu bar & notch app monitoring Google Antigravity (`agy` CLI, Desktop, and IDE) usage, active time, live sessions, and plan quota.

## Two-Target Build Architecture

- **App binary (`build.sh`)**: Compiled directly via `swiftc` into a universal macOS binary (`arm64` + `x86_64`), signed, and packaged into `dist/AGYMonitor.dmg` (no `.xcodeproj`). Temporary `build/dmg-staging` is removed automatically so duplicate `.app` bundles are never left behind.
- **Test harness (`Package.swift`)**: Exists **solely** for `swift test` (`AGYCoreTests` using Swift Testing). App files never enter `Package.swift`.
  - Every `Sources/Core_*.swift` file MUST appear in `Package.swift` `sources:`.
  - Every non-`Core_*.swift` file in `Sources/` MUST appear in `Package.swift` `exclude:`.

## Core Purity Rules (`Sources/Core_*.swift`)

1. **`import Foundation` only** — NEVER import `AppKit`, `SwiftUI`, `CoreGraphics`, `Combine`, `SQLite3`, or spawn `Process` / touch `FileManager`. Use `Double` instead of `CGFloat`.
2. **All data-path dates use `AppDate.gregorian`** — never bare `Calendar.current` or shared `DateFormatter`s, so non-Gregorian system locales still match `analyze_usage.py` `"yyyy-MM-dd"` keys.
3. **Sendable & Equatable** — state and value models in `AGYCore` must remain `Equatable` and `Sendable`.

## Explicit State Machines (No Shadow Booleans)

All non-trivial UI/lifecycle transitions are modeled as pure `AGYCore` state machines with thin app-layer shells:

| Domain | Pure Reducer / State | App-Layer Shell |
|---|---|---|
| Notch hover, fullscreen gate & modal locks | `Core_NotchState.swift` (`NotchMachine`) | `NotchController.swift`, `NotchView.swift`, `Views_Menus.swift` |
| Usage scopes, month nav, refresh queue, gates | `Core_UsageState.swift` (`LoadPhase`, `RefreshQueueState`, `MonthNavigationState`, `YearLoadGate`, `ArchiveSweepGate`) | `UsageStore.swift`, `Views.swift`, `Views_Time.swift` |
| Plan quota, auth & 429 cooldown | `Core_QuotaState.swift` (`QuotaPhase`, `QuotaCooldownState`, `LiveQuotaHTTPOutcome`, `QuotaStateReducer`) | `QuotaService.swift`, `Views_Plan.swift` |
| Poll cadence, FSEvents throttle, menu anchor, logo & live status | `Core_MonitorState.swift` (`SessionPollCadence`, `FSEventsThrottleState`, `MenuBarAnchorState`, `LogoVisualState`, `SessionLogic.resolveLiveSessionStatus`) | `SessionMonitor.swift`, `AITitleReader.swift`, `AppDelegate.swift`, `Views_Common.swift`, `Views_Session.swift` |

Never add raw parallel booleans (like `preventClose` or shared `isLoading`) in app shells when a state-machine transition belongs in `Core_*State.swift`.

## Single Source of Truth (Anti-Split-Brain Rule)

- **Paths & SQLite URIs**: Always call `AGYLocator` (`Core_AGYLocator.swift`), never hardcode `~/.gemini/...` or `state.vscdb` paths in app files.
- **Session / Transcript / Swarm / Annotation parsing**: Always call `SessionLogic` (`Core_Sessions.swift`, `Core_MonitorState.swift`) and `TranscriptParse` (`Core_Transcript.swift`). Never duplicate `lsof`, `.pbtxt`, `swarm/members.json`, or status inference in `SessionMonitor.swift` or `AITitleReader.swift`.

## Cross-Language & Version Lockstep

- **Model tier order & classification**: `ModelClass.allCases` and `ModelClass.classify(_:)` in `Sources/Core_ModelClass.swift` MUST match `MODEL_CLASSES` and `classify_model(raw)` in `Resources/analyze_usage.py`:
  - Tier order (high → low): `carbon`, `argon`, `neon`, `hydrogen`, `flash`, `claude`, `other`.
  - Classification precedence: `hydrogen` / `flash-worker-agy` → `argon` → `neon` (BEFORE `orchestrator`!) → `carbon` / `orchestrator` / `gemini+pro` / `ultra` → `flash` / `lite` → `claude` / `opus` / `sonnet` / `haiku` → `other`.
- **Version lockstep**: `Info.plist` (`CFBundleShortVersionString`), `Resources/analyze_usage.py` (`__version__`), and `Sources/QuotaService.swift` (`appVersion` fallback) must stay identical.
- **Archive schema (`UsageArchiveData.currentSchema`)**: Bump whenever `ModelClass` keys or daily aggregation semantics change so stale shards and `scan-cache.json` cleanly rebuild.
- **Compatibility floors**: macOS 13+ for Swift; macOS system Python 3.9+ for `Resources/analyze_usage.py` (`from __future__ import annotations`, no `match`/`case`).

## Verification Commands

```bash
# Fast daily check (plist + py_compile + Python unit/parity tests + swift test)
bash scripts/check.sh

# Full CI-equivalent check including universal app build + strict codesign verify
bash scripts/check.sh --build
```
