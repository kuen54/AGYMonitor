import Foundation

// MARK: - Craft, Haptic Cadence, Acoustic Lifecycle, Blueprint Wallpaper & Specimen State — pure core
//
// Foundation-only (part of AGYCore):
//   - CraftPreferences / BlueprintWallpaperStyle / SpecimenAspect
//   - InstrumentHapticCue / HapticPatternKind / HapticRecipe / HapticCadenceMachine
//   - AcousticCue / AcousticTriggerState: startup-silent edge detector
//   - AcousticEngineLifecycleMachine: multi-chime drain accumulation & idle teardown
//   - DailyWallpaperGate / BlueprintWallpaperPath / BlueprintWallpaperMachine
//   - SpecimenExporterMachine / OperatorArchetypeKind / OperatorArchetype / SpecimenLogic
//
// Zero AppKit, SwiftUI, CoreGraphics, Combine, SQLite3, Process, or FileManager.

public enum BlueprintWallpaperStyle: String, Codable, CaseIterable, Sendable {
    case darkMonolith
    case lightGallery
}

public enum SpecimenAspect: String, Codable, CaseIterable, Sendable {
    case portrait4x5
    case landscape16x9
}

public struct CraftPreferences: Codable, Equatable, Sendable {
    public var hapticsEnabled: Bool
    public var acousticChimesEnabled: Bool
    public var dailyWallpaperEnabled: Bool
    public var wallpaperStyle: BlueprintWallpaperStyle
    public var lastWallpaperDateKey: String?
    public var previousWallpaperPath: String?

    public static let `default` = CraftPreferences()

    public init(
        hapticsEnabled: Bool = true,
        acousticChimesEnabled: Bool = false,
        dailyWallpaperEnabled: Bool = false,
        wallpaperStyle: BlueprintWallpaperStyle = .darkMonolith,
        lastWallpaperDateKey: String? = nil,
        previousWallpaperPath: String? = nil
    ) {
        self.hapticsEnabled = hapticsEnabled
        self.acousticChimesEnabled = acousticChimesEnabled
        self.dailyWallpaperEnabled = dailyWallpaperEnabled
        self.wallpaperStyle = wallpaperStyle
        self.lastWallpaperDateKey = lastWallpaperDateKey
        self.previousWallpaperPath = previousWallpaperPath
    }

    enum CodingKeys: String, CodingKey {
        case hapticsEnabled
        case acousticChimesEnabled
        case dailyWallpaperEnabled
        case wallpaperStyle
        case lastWallpaperDateKey
        case previousWallpaperPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.hapticsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .hapticsEnabled)) ?? true
        self.acousticChimesEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .acousticChimesEnabled)) ?? false
        self.dailyWallpaperEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .dailyWallpaperEnabled)) ?? false
        self.wallpaperStyle = (try? c.decodeIfPresent(BlueprintWallpaperStyle.self, forKey: .wallpaperStyle)) ?? .darkMonolith
        self.lastWallpaperDateKey = (try? c.decodeIfPresent(String.self, forKey: .lastWallpaperDateKey)) ?? nil
        self.previousWallpaperPath = (try? c.decodeIfPresent(String.self, forKey: .previousWallpaperPath)) ?? nil
    }
}

public enum AcousticCue: String, Equatable, Sendable {
    case waitingPing
    case turnDoneChord
}

// MARK: - 1. Instrument Haptic Grammar & Cadence State Machine

/// Tactile feedback cues bound strictly to the `Instrument` visual style.
/// Combines macOS's three native Taptic Engine patterns (`.alignment`, `.levelChange`, `.generic`)
/// with cancellable 2-beat micro-cadences so each of the 5 Instrument tabs has its own physical feel.
public enum InstrumentHapticCue: CaseIterable, Equatable, Sendable {
    // Global Instrument Chrome
    case tabDetent           // Crisp Swiss bezel tab / stepper click
    case modeEngage          // Engaging Instrument mode or cycling studio theme dial

    // Tab 01 Cost — Geological Strata & Ridge
    case costRidgeDay        // Traversing daily elevation points along the ridgeline
    case costRidgePeak       // Reaching the monthly peak summit
    case costStrataShift     // Locking onto a Borehole model stratum or switching scope

    // Tab 02 Tokens — Fluid Flow & Pulse Matrix
    case tokenStreamLock     // Soft fluid lock onto a Folded Token Stream model or channel
    case tokenMatrixCell     // Active (non-empty) cell in the throughput spectrogram
    case tokenMatrixPeak     // High-throughput peak cell

    // Tab 03 Time — Chronometer & Topography
    case chronometerCrown    // Watch-crown sweep across Polar rings or Month Elevation bars
    case chronometerPin      // Solid bezel lock when pinning a Polar ring or hitting Month Peak
    case chronometerUnpin    // Gentle release when unpinning or scrubbing lower 24h diurnal bins
    case contourRidgeStep    // Crossing active cells/ridges on the Year Marching-Squares contour
    case contourPeakLock     // Reaching an [H] meteorological peak on the Year contour

    // Tab 04 Sessions — Tactical Agent Radar
    case radarBeaconLock     // Targeting a busy/idle radar beacon or keyboard ↑↓ selection
    case radarAlertLock      // Double-tap "beep-lock" on an amber WAITING beacon
    case radarJumpEngage     // Clicking a radar beacon to jump to its terminal/IDE

    // Tab 05 Plan — 270° Orbital Phase Dials
    case orbitalDialInspect  // Inspecting a healthy 270° orbital quota dial
    case orbitalDeficitWarn  // Double-tap tactile warning on a burn-pace deficit / critical dial
    case creditsTick         // Soft detent across 7D horizon / AI Credits pool strips
}

public enum HapticPatternKind: Equatable, Sendable {
    case alignment
    case levelChange
    case generic
}

public struct HapticFollowUp: Equatable, Sendable {
    public let pattern: HapticPatternKind
    public let delay: Double

    public init(pattern: HapticPatternKind, delay: Double) {
        self.pattern = pattern
        self.delay = delay
    }
}

public struct HapticRecipe: Equatable, Sendable {
    public let primary: HapticPatternKind
    public let followUp: HapticFollowUp?
    public let minInterval: Double
    /// Landmarks (peaks, pins, alerts, explicit mode/tab actions) may cut through an
    /// active scrub cue after `salientInterruptFloor` so fast sweeps never miss summits.
    public let isSalient: Bool

    public init(
        primary: HapticPatternKind,
        followUp: HapticFollowUp? = nil,
        minInterval: Double,
        isSalient: Bool
    ) {
        self.primary = primary
        self.followUp = followUp
        self.minInterval = minInterval
        self.isSalient = isSalient
    }
}

public struct HapticCadenceState: Equatable, Sendable {
    public var lastFiredAt: Double?
    public var lastCue: InstrumentHapticCue?
    public var cadenceGeneration: UInt64

    public init(
        lastFiredAt: Double? = nil,
        lastCue: InstrumentHapticCue? = nil,
        cadenceGeneration: UInt64 = 0
    ) {
        self.lastFiredAt = lastFiredAt
        self.lastCue = lastCue
        self.cadenceGeneration = cadenceGeneration
    }
}

public enum HapticCadenceEvent: Equatable, Sendable {
    case perform(cue: InstrumentHapticCue, enabled: Bool, now: Double)
    case followUpFired(generation: UInt64, pattern: HapticPatternKind)
    case cancel
}

public enum HapticCadenceEffect: Equatable, Sendable {
    case trigger(HapticPatternKind)
    case scheduleFollowUp(generation: UInt64, pattern: HapticPatternKind, delay: Double)
    case cancelFollowUp
}

public enum HapticCadenceMachine {
    public static let salientInterruptFloor: Double = 0.018

    public static func recipe(for cue: InstrumentHapticCue) -> HapticRecipe {
        switch cue {
        // Global Instrument Chrome
        case .tabDetent:
            return HapticRecipe(primary: .alignment, followUp: nil, minInterval: 0.040, isSalient: true)
        case .modeEngage:
            return HapticRecipe(primary: .levelChange, followUp: nil, minInterval: 0.080, isSalient: true)

        // Tab 01 Cost
        case .costRidgeDay:
            return HapticRecipe(primary: .alignment, followUp: nil, minInterval: 0.038, isSalient: false)
        case .costRidgePeak:
            return HapticRecipe(primary: .levelChange, followUp: nil, minInterval: 0.075, isSalient: true)
        case .costStrataShift:
            return HapticRecipe(primary: .levelChange, followUp: nil, minInterval: 0.055, isSalient: true)

        // Tab 02 Tokens
        case .tokenStreamLock:
            return HapticRecipe(primary: .generic, followUp: nil, minInterval: 0.050, isSalient: false)
        case .tokenMatrixCell:
            return HapticRecipe(primary: .alignment, followUp: nil, minInterval: 0.042, isSalient: false)
        case .tokenMatrixPeak:
            return HapticRecipe(primary: .levelChange, followUp: nil, minInterval: 0.075, isSalient: true)

        // Tab 03 Time
        case .chronometerCrown:
            return HapticRecipe(primary: .alignment, followUp: nil, minInterval: 0.035, isSalient: false)
        case .chronometerPin:
            return HapticRecipe(primary: .levelChange, followUp: nil, minInterval: 0.065, isSalient: true)
        case .chronometerUnpin:
            return HapticRecipe(primary: .generic, followUp: nil, minInterval: 0.055, isSalient: false)
        case .contourRidgeStep:
            return HapticRecipe(primary: .alignment, followUp: nil, minInterval: 0.075, isSalient: false)
        case .contourPeakLock:
            return HapticRecipe(primary: .levelChange, followUp: nil, minInterval: 0.085, isSalient: true)

        // Tab 04 Sessions
        case .radarBeaconLock:
            return HapticRecipe(primary: .alignment, followUp: nil, minInterval: 0.045, isSalient: false)
        case .radarAlertLock:
            return HapticRecipe(
                primary: .alignment,
                followUp: HapticFollowUp(pattern: .levelChange, delay: 0.055),
                minInterval: 0.120,
                isSalient: true
            )
        case .radarJumpEngage:
            return HapticRecipe(primary: .levelChange, followUp: nil, minInterval: 0.080, isSalient: true)

        // Tab 05 Plan
        case .orbitalDialInspect:
            return HapticRecipe(primary: .alignment, followUp: nil, minInterval: 0.055, isSalient: false)
        case .orbitalDeficitWarn:
            return HapticRecipe(
                primary: .levelChange,
                followUp: HapticFollowUp(pattern: .alignment, delay: 0.060),
                minInterval: 0.140,
                isSalient: true
            )
        case .creditsTick:
            return HapticRecipe(primary: .generic, followUp: nil, minInterval: 0.050, isSalient: false)
        }
    }

    @discardableResult
    public static func reduce(
        _ state: inout HapticCadenceState,
        event: HapticCadenceEvent
    ) -> [HapticCadenceEffect] {
        switch event {
        case .perform(let cue, let enabled, let now):
            guard enabled else {
                state.cadenceGeneration &+= 1
                return [.cancelFollowUp]
            }
            guard now.isFinite else { return [] }

            let spec = recipe(for: cue)
            if let last = state.lastFiredAt {
                let elapsed = now - last
                let requiredInterval: Double = (spec.isSalient && state.lastCue != cue)
                    ? min(spec.minInterval, salientInterruptFloor)
                    : spec.minInterval
                guard elapsed >= requiredInterval else { return [] }
            }

            state.lastFiredAt = now
            state.lastCue = cue
            state.cadenceGeneration &+= 1
            let gen = state.cadenceGeneration

            var effects: [HapticCadenceEffect] = [.cancelFollowUp, .trigger(spec.primary)]
            if let followUp = spec.followUp {
                effects.append(.scheduleFollowUp(generation: gen, pattern: followUp.pattern, delay: followUp.delay))
            }
            return effects

        case .followUpFired(let generation, let pattern):
            guard generation > 0, generation == state.cadenceGeneration else { return [] }
            // Advance generation on consumption so duplicate deliveries cannot double-fire.
            state.cadenceGeneration &+= 1
            return [.trigger(pattern)]

        case .cancel:
            state.cadenceGeneration &+= 1
            return [.cancelFollowUp]
        }
    }
}

// MARK: - 2. Acoustic Edge Trigger & Engine Lifecycle State Machines

/// Pure edge-detector reducer for acoustic chimes.
/// The first post-scan `update` seeds the baseline silently so app launch never chimes;
/// subsequent updates fire `.waitingPing` (higher priority) or `.turnDoneChord`
/// only when newly added session IDs appear.
public struct AcousticTriggerState: Equatable, Sendable {
    public private(set) var hasBaseline: Bool
    public private(set) var lastWaitingIds: Set<String>
    public private(set) var lastDoneUnseenIds: Set<String>

    public init(
        hasBaseline: Bool = false,
        lastWaitingIds: Set<String> = [],
        lastDoneUnseenIds: Set<String> = []
    ) {
        self.hasBaseline = hasBaseline
        self.lastWaitingIds = lastWaitingIds
        self.lastDoneUnseenIds = lastDoneUnseenIds
    }

    public mutating func reset() {
        hasBaseline = false
        lastWaitingIds.removeAll()
        lastDoneUnseenIds.removeAll()
    }

    public mutating func update(
        waitingIds: Set<String>,
        doneUnseenIds: Set<String>,
        hasCompletedInitialScan: Bool = true
    ) -> AcousticCue? {
        guard hasCompletedInitialScan else {
            return nil
        }

        if !hasBaseline {
            hasBaseline = true
            lastWaitingIds = waitingIds
            lastDoneUnseenIds = doneUnseenIds
            return nil
        }

        let newWaiting = waitingIds.subtracting(lastWaitingIds)
        let newDone = doneUnseenIds.subtracting(lastDoneUnseenIds)

        lastWaitingIds = waitingIds
        lastDoneUnseenIds = doneUnseenIds

        if !newWaiting.isEmpty {
            return .waitingPing
        }
        if !newDone.isEmpty {
            return .turnDoneChord
        }
        return nil
    }
}

public enum AcousticEnginePhase: Equatable, Sendable {
    case idle
    case active(drainUntil: Double, generation: UInt64)
}

public struct AcousticEngineState: Equatable, Sendable {
    public var phase: AcousticEnginePhase
    public var generationCounter: UInt64

    public init(
        phase: AcousticEnginePhase = .idle,
        generationCounter: UInt64 = 0
    ) {
        self.phase = phase
        self.generationCounter = generationCounter
    }
}

public enum AcousticEngineEvent: Equatable, Sendable {
    case play(cue: AcousticCue, bufferDuration: Double, now: Double)
    case configurationChanged
    case disabled
    case teardownFired(generation: UInt64)
    case terminate
}

public enum AcousticEngineEffect: Equatable, Sendable {
    case ensureGraphAndPlay(AcousticCue)
    case scheduleTeardown(generation: UInt64, after: Double)
    case cancelTeardown
    case teardownGraph
}

public enum AcousticEngineLifecycleMachine {
    public static let idleHoldSec: Double = 0.50

    @discardableResult
    public static func reduce(
        _ state: inout AcousticEngineState,
        event: AcousticEngineEvent
    ) -> [AcousticEngineEffect] {
        switch event {
        case .play(let cue, let bufferDuration, let now):
            guard now.isFinite else { return [] }
            let safeDuration = (bufferDuration.isFinite && bufferDuration > 0.0) ? bufferDuration : 0.0

            let currentDrainUntil: Double
            let wasActive: Bool
            switch state.phase {
            case .idle:
                currentDrainUntil = now
                wasActive = false
            case .active(let existingDrainUntil, _):
                currentDrainUntil = existingDrainUntil
                wasActive = true
            }

            let newDrainUntil = max(currentDrainUntil, now) + safeDuration
            state.generationCounter &+= 1
            let gen = state.generationCounter
            state.phase = .active(drainUntil: newDrainUntil, generation: gen)

            let teardownDelay = max(0.0, newDrainUntil - now) + idleHoldSec
            var effects: [AcousticEngineEffect] = []
            if wasActive {
                effects.append(.cancelTeardown)
            }
            effects.append(.ensureGraphAndPlay(cue))
            effects.append(.scheduleTeardown(generation: gen, after: teardownDelay))
            return effects

        case .teardownFired(let generation):
            guard case .active(_, let activeGen) = state.phase, activeGen == generation else {
                return []
            }
            state.phase = .idle
            return [.teardownGraph]

        case .configurationChanged, .disabled, .terminate:
            state.generationCounter &+= 1
            state.phase = .idle
            return [.cancelTeardown, .teardownGraph]
        }
    }
}

// MARK: - 3. Blueprint Wallpaper Gate, Path Guard & Lifecycle State Machine

public enum DailyWallpaperGate {
    /// True iff daily blueprint wallpaper is enabled and has not yet rendered for `todayKey`.
    public static func shouldRefresh(todayKey: String, preferences: CraftPreferences) -> Bool {
        let trimmed = todayKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !AppDate.isSentinelDayKey(trimmed) else { return false }
        return preferences.dailyWallpaperEnabled && preferences.lastWallpaperDateKey != trimmed
    }
}

public enum BlueprintWallpaperPath {
    /// Pure boundary-safe check verifying `path` is a managed blueprint wallpaper file
    /// directly inside `directoryPath` (strict trailing `/` boundary prevents sibling-prefix matches).
    public static func isManagedPath(_ path: String, directoryPath: String) -> Bool {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDir = directoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty, !trimmedDir.isEmpty else { return false }

        let normPath = URL(fileURLWithPath: trimmedPath).standardized.path
        let normDir = URL(fileURLWithPath: trimmedDir).standardized.path
        let dirPrefix = normDir.hasSuffix("/") ? normDir : (normDir + "/")
        guard normPath.hasPrefix(dirPrefix) else { return false }

        let relative = normPath.dropFirst(dirPrefix.count)
        guard !relative.isEmpty, !relative.contains("/") else { return false }
        return relative.hasPrefix("agy-blueprint-")
    }
}

public enum BlueprintWallpaperTrigger: Equatable, Sendable {
    case dailyAuto
    case manualApply
    case styleChange
}

public enum BlueprintWallpaperPhase: Equatable, Sendable {
    case idle
    case awaitingYearData(
        trigger: BlueprintWallpaperTrigger,
        style: BlueprintWallpaperStyle,
        dateKey: String,
        generation: UInt64
    )
    case applying(
        trigger: BlueprintWallpaperTrigger,
        style: BlueprintWallpaperStyle,
        dateKey: String,
        generation: UInt64
    )
}

public struct BlueprintWallpaperState: Equatable, Sendable {
    public var phase: BlueprintWallpaperPhase
    public var lastAppliedDateKey: String?
    public var lastAppliedStyle: BlueprintWallpaperStyle?
    public var lastFailureAt: Double?
    public var previousWallpaperPath: String?
    public var generationCounter: UInt64

    public init(
        phase: BlueprintWallpaperPhase = .idle,
        lastAppliedDateKey: String? = nil,
        lastAppliedStyle: BlueprintWallpaperStyle? = nil,
        lastFailureAt: Double? = nil,
        previousWallpaperPath: String? = nil,
        generationCounter: UInt64 = 0
    ) {
        self.phase = phase
        self.lastAppliedDateKey = lastAppliedDateKey
        self.lastAppliedStyle = lastAppliedStyle
        self.lastFailureAt = lastFailureAt
        self.previousWallpaperPath = previousWallpaperPath
        self.generationCounter = generationCounter
    }

    public var isBusy: Bool {
        phase != .idle
    }

    public var canRestorePrevious: Bool {
        guard let path = previousWallpaperPath else { return false }
        return !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum BlueprintWallpaperEvent: Equatable, Sendable {
    case dailyCheck(
        enabled: Bool,
        todayKey: String,
        style: BlueprintWallpaperStyle,
        hasYearCache: Bool,
        now: Double
    )
    case manualApply(
        todayKey: String,
        style: BlueprintWallpaperStyle,
        hasYearCache: Bool,
        now: Double
    )
    case styleChanged(
        enabled: Bool,
        todayKey: String,
        style: BlueprintWallpaperStyle,
        hasYearCache: Bool,
        now: Double
    )
    case yearDataReady(todayKey: String)
    case yearDataFailed(now: Double)
    case applyCompleted(
        generation: UInt64,
        succeeded: Bool,
        dateKey: String,
        style: BlueprintWallpaperStyle,
        capturedPreviousPath: String?,
        now: Double
    )
    case restoreRequested
    case restoreCompleted(succeeded: Bool, fileMissing: Bool)
}

public enum BlueprintWallpaperEffect: Equatable, Sendable {
    case fetchYearDataSilently
    case renderAndApply(generation: UInt64, style: BlueprintWallpaperStyle, dateKey: String)
    case restoreDesktop(path: String)
    case persistPreferences
}

public enum BlueprintWallpaperMachine {
    public static let failureBackoffSeconds: Double = 300.0

    @discardableResult
    public static func reduce(
        _ state: inout BlueprintWallpaperState,
        event: BlueprintWallpaperEvent
    ) -> [BlueprintWallpaperEffect] {
        switch event {
        case .dailyCheck(let enabled, let todayKey, let style, let hasYearCache, let now):
            guard enabled,
                  let dayKey = normalizedDayKey(todayKey),
                  now.isFinite,
                  state.phase == .idle else {
                return []
            }
            if state.lastAppliedDateKey == dayKey,
               (state.lastAppliedStyle == nil || state.lastAppliedStyle == style) {
                return []
            }
            if let failedAt = state.lastFailureAt, now >= failedAt, (now - failedAt) < failureBackoffSeconds {
                return []
            }
            return beginPipeline(
                &state,
                trigger: .dailyAuto,
                style: style,
                dayKey: dayKey,
                hasYearCache: hasYearCache
            )

        case .manualApply(let todayKey, let style, let hasYearCache, let now):
            guard let dayKey = normalizedDayKey(todayKey), now.isFinite else {
                return []
            }
            state.lastFailureAt = nil
            return beginPipeline(
                &state,
                trigger: .manualApply,
                style: style,
                dayKey: dayKey,
                hasYearCache: hasYearCache
            )

        case .styleChanged(let enabled, let todayKey, let style, let hasYearCache, let now):
            guard enabled else {
                switch state.phase {
                case .awaitingYearData(let trigger, _, _, _)
                    where trigger == .dailyAuto || trigger == .styleChange:
                    state.generationCounter &+= 1
                    state.phase = .idle
                case .applying(let trigger, _, _, _)
                    where trigger == .dailyAuto || trigger == .styleChange:
                    state.generationCounter &+= 1
                    state.phase = .idle
                default:
                    break
                }
                return []
            }
            guard let dayKey = normalizedDayKey(todayKey), now.isFinite else {
                return []
            }
            state.lastFailureAt = nil
            return beginPipeline(
                &state,
                trigger: .styleChange,
                style: style,
                dayKey: dayKey,
                hasYearCache: hasYearCache
            )

        case .yearDataReady(let todayKey):
            guard case .awaitingYearData(let trigger, let style, let pendingDateKey, _) = state.phase else {
                return []
            }
            let resolvedDateKey = normalizedDayKey(todayKey) ?? pendingDateKey
            state.generationCounter &+= 1
            let gen = state.generationCounter
            state.phase = .applying(
                trigger: trigger,
                style: style,
                dateKey: resolvedDateKey,
                generation: gen
            )
            return [.renderAndApply(generation: gen, style: style, dateKey: resolvedDateKey)]

        case .yearDataFailed(let now):
            guard case .awaitingYearData = state.phase else {
                return []
            }
            state.phase = .idle
            if now.isFinite {
                state.lastFailureAt = now
            }
            return []

        case .applyCompleted(let generation, let succeeded, let dateKey, let style, let capturedPreviousPath, let now):
            guard case .applying(_, _, _, let activeGen) = state.phase, activeGen == generation else {
                return []
            }
            state.phase = .idle
            if succeeded {
                if let normalized = normalizedDayKey(dateKey) {
                    state.lastAppliedDateKey = normalized
                }
                state.lastAppliedStyle = style
                state.lastFailureAt = nil
                if let captured = capturedPreviousPath,
                   !captured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    state.previousWallpaperPath = captured
                }
                return [.persistPreferences]
            } else {
                if now.isFinite {
                    state.lastFailureAt = now
                }
                return []
            }

        case .restoreRequested:
            guard let path = state.previousWallpaperPath,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return []
            }
            // Cancel any in-flight wallpaper generation so it cannot overwrite the restored desktop.
            if state.phase != .idle {
                state.generationCounter &+= 1
                state.phase = .idle
            }
            return [.restoreDesktop(path: path)]

        case .restoreCompleted(let succeeded, let fileMissing):
            if succeeded {
                state.previousWallpaperPath = nil
                state.lastAppliedDateKey = nil
                state.lastAppliedStyle = nil
                state.lastFailureAt = nil
                state.phase = .idle
                return [.persistPreferences]
            }
            if fileMissing {
                state.previousWallpaperPath = nil
                return [.persistPreferences]
            }
            return []
        }
    }

    private static func beginPipeline(
        _ state: inout BlueprintWallpaperState,
        trigger: BlueprintWallpaperTrigger,
        style: BlueprintWallpaperStyle,
        dayKey: String,
        hasYearCache: Bool
    ) -> [BlueprintWallpaperEffect] {
        let alreadyAwaitingYearData: Bool
        if case .awaitingYearData = state.phase {
            alreadyAwaitingYearData = true
        } else {
            alreadyAwaitingYearData = false
        }

        state.generationCounter &+= 1
        let gen = state.generationCounter

        if hasYearCache {
            state.phase = .applying(
                trigger: trigger,
                style: style,
                dateKey: dayKey,
                generation: gen
            )
            return [.renderAndApply(generation: gen, style: style, dateKey: dayKey)]
        } else {
            state.phase = .awaitingYearData(
                trigger: trigger,
                style: style,
                dateKey: dayKey,
                generation: gen
            )
            return alreadyAwaitingYearData ? [] : [.fetchYearDataSilently]
        }
    }

    private static func normalizedDayKey(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !AppDate.isSentinelDayKey(trimmed) else { return nil }
        return trimmed
    }
}

// MARK: - 4. Specimen Exporter State Machine

public enum SpecimenAppearanceChoice: String, CaseIterable, Equatable, Sendable {
    case system
    case light
    case dark

    public func resolvedIsDark(systemIsDark: Bool) -> Bool {
        switch self {
        case .system: return systemIsDark
        case .light:  return false
        case .dark:   return true
        }
    }
}

public enum SpecimenExportPhase: Equatable, Sendable {
    case idle
    case saving
}

public enum SpecimenFeedbackKind: Equatable, Sendable {
    case copied
    case saved
    case renderFailed
    case saveFailed

    public var bannerKey: String {
        switch self {
        case .copied:       return "specimenCopied"
        case .saved:        return "specimenSaved"
        case .renderFailed: return "specimenRenderFailed"
        case .saveFailed:   return "specimenSaveFailed"
        }
    }
}

public struct SpecimenExporterState: Equatable, Sendable {
    public var isPresented: Bool
    public var aspect: SpecimenAspect
    public var appearance: SpecimenAppearanceChoice
    public var exportPhase: SpecimenExportPhase
    public var feedback: TransientBannerState
    public var feedbackKind: SpecimenFeedbackKind?

    public init(
        isPresented: Bool = false,
        aspect: SpecimenAspect = .portrait4x5,
        appearance: SpecimenAppearanceChoice = .system,
        exportPhase: SpecimenExportPhase = .idle,
        feedback: TransientBannerState = TransientBannerState(),
        feedbackKind: SpecimenFeedbackKind? = nil
    ) {
        self.isPresented = isPresented
        self.aspect = aspect
        self.appearance = appearance
        self.exportPhase = exportPhase
        self.feedback = feedback
        self.feedbackKind = feedbackKind
    }
}

public enum SpecimenExporterEvent: Equatable, Sendable {
    case present
    case dismiss
    case setAspect(SpecimenAspect)
    case setAppearance(SpecimenAppearanceChoice)
    case copySucceeded
    case copyFailed
    case beginSave
    case saveCompleted(succeeded: Bool)
    case saveCancelled
    case dismissFeedback(token: UInt64)
}

public enum SpecimenExporterEffect: Equatable, Sendable {
    case scheduleFeedbackDismiss(token: UInt64, after: Double)
    case cancelFeedbackDismiss
    case showSavePanel
}

public enum SpecimenExporterMachine {
    public static let feedbackDuration: Double = 1.8

    @discardableResult
    public static func reduce(
        _ state: inout SpecimenExporterState,
        event: SpecimenExporterEvent
    ) -> [SpecimenExporterEffect] {
        switch event {
        case .present:
            if !state.isPresented {
                state.isPresented = true
                state.exportPhase = .idle
            }
            return []

        case .dismiss:
            state.isPresented = false
            state.exportPhase = .idle
            let hadFeedback = (state.feedbackKind != nil || state.feedback.messageKey != nil)
            _ = state.feedback.show(nil)
            state.feedbackKind = nil
            return hadFeedback ? [.cancelFeedbackDismiss] : []

        case .setAspect(let aspect):
            state.aspect = aspect
            return []

        case .setAppearance(let appearance):
            state.appearance = appearance
            return []

        case .copySucceeded:
            return presentFeedback(&state, kind: .copied)

        case .copyFailed:
            return presentFeedback(&state, kind: .renderFailed)

        case .beginSave:
            guard state.exportPhase == .idle else { return [] }
            state.exportPhase = .saving
            return [.showSavePanel]

        case .saveCompleted(let succeeded):
            guard state.exportPhase == .saving else { return [] }
            state.exportPhase = .idle
            return presentFeedback(&state, kind: succeeded ? .saved : .saveFailed)

        case .saveCancelled:
            guard state.exportPhase == .saving else { return [] }
            state.exportPhase = .idle
            return []

        case .dismissFeedback(let token):
            guard let intToken = Int(exactly: token) else { return [] }
            if state.feedback.expire(generation: intToken) {
                state.feedbackKind = nil
            }
            return []
        }
    }

    private static func presentFeedback(
        _ state: inout SpecimenExporterState,
        kind: SpecimenFeedbackKind
    ) -> [SpecimenExporterEffect] {
        let hadFeedback = (state.feedbackKind != nil || state.feedback.messageKey != nil)
        state.feedbackKind = kind
        guard let gen = state.feedback.show(kind.bannerKey) else { return [] }
        var effects: [SpecimenExporterEffect] = []
        if hadFeedback {
            effects.append(.cancelFeedbackDismiss)
        }
        effects.append(.scheduleFeedbackDismiss(token: UInt64(gen), after: feedbackDuration))
        return effects
    }
}

// MARK: - 5. Specimen Operator Archetype Classifier

public enum OperatorArchetypeKind: String, Codable, Equatable, Sendable {
    case nocturnalArchitect
    case dawnSynthesizer
    case daylightCraftsman
    case marathonOperator
    case steadyPilot
}

public struct OperatorArchetype: Equatable, Sendable {
    public let kind: OperatorArchetypeKind
    public let peakWindowLabel: String
    public let cacheGrade: String
    public let cacheHitPercent: Int?

    public init(
        kind: OperatorArchetypeKind,
        peakWindowLabel: String,
        cacheGrade: String,
        cacheHitPercent: Int?
    ) {
        self.kind = kind
        self.peakWindowLabel = peakWindowLabel
        self.cacheGrade = cacheGrade
        self.cacheHitPercent = cacheHitPercent
    }
}

public enum SpecimenLogic {
    /// Classify operator archetype, diurnal peak window label, and cache efficiency grade.
    public static func classifyArchetype(
        diurnalProfile: MonthDiurnalProfile,
        activeHours: Double,
        totalInputTokens: Int,
        totalCacheReadTokens: Int
    ) -> OperatorArchetype {
        let safeHours = activeHours.isFinite ? max(0.0, activeHours) : 0.0
        let binCount = diurnalProfile.bins.isEmpty ? 48 : diurnalProfile.bins.count

        let peakWindowLabel: String
        let peakStartHour: Int?

        if let rawStart = diurnalProfile.peakWindowStartBin, binCount > 0 {
            let startBin = ((rawStart % binCount) + binCount) % binCount
            let defaultSpan = max(1, binCount / 12)
            let endBin = diurnalProfile.peakWindowEndBin ?? (startBin + defaultSpan)

            let startMinutes = minutesOfDay(forBin: startBin, binCount: binCount)
            let endMinutes = minutesOfDay(forBin: endBin, binCount: binCount)
            peakStartHour = startMinutes / 60
            peakWindowLabel = "\(formatHHMM(startMinutes))–\(formatHHMM(endMinutes))"
        } else {
            peakStartHour = nil
            peakWindowLabel = "--"
        }

        let kind: OperatorArchetypeKind
        if safeHours >= 120.0 {
            kind = .marathonOperator
        } else if let h = peakStartHour, (h >= 21 || h < 5) {
            kind = .nocturnalArchitect
        } else if let h = peakStartHour, (5..<9).contains(h) {
            kind = .dawnSynthesizer
        } else if safeHours >= 20.0 {
            kind = .daylightCraftsman
        } else {
            kind = .steadyPilot
        }

        let safeInput = max(0, totalInputTokens)
        let safeCacheRead = max(0, totalCacheReadTokens)
        let denom = safeInput + safeCacheRead
        let cacheGrade: String
        let cacheHitPercent: Int?

        if denom > 0 {
            let ratio = Double(safeCacheRead) / Double(denom)
            let hitPct = min(100, max(0, Int((ratio * 100.0).rounded())))
            cacheHitPercent = hitPct
            if hitPct >= 90 {
                cacheGrade = "A+"
            } else if hitPct >= 80 {
                cacheGrade = "A"
            } else if hitPct >= 65 {
                cacheGrade = "B+"
            } else if hitPct >= 45 {
                cacheGrade = "B"
            } else {
                cacheGrade = "C"
            }
        } else {
            cacheGrade = "--"
            cacheHitPercent = nil
        }

        return OperatorArchetype(
            kind: kind,
            peakWindowLabel: peakWindowLabel,
            cacheGrade: cacheGrade,
            cacheHitPercent: cacheHitPercent
        )
    }

    private static func minutesOfDay(forBin bin: Int, binCount: Int) -> Int {
        let raw = Int((Double(bin) * 1440.0 / Double(max(1, binCount))).rounded())
        return ((raw % 1440) + 1440) % 1440
    }

    private static func formatHHMM(_ minutes: Int) -> String {
        let clamped = ((minutes % 1440) + 1440) % 1440
        let h = clamped / 60
        let m = clamped % 60
        return String(format: "%02d:%02d", h, m)
    }
}
