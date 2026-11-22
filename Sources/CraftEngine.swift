import AppKit
import AVFoundation
import Foundation
import SwiftUI

// MARK: - Haptics Environment Key

private struct CraftHapticsEnabledKey: EnvironmentKey {
    /// Fail-closed default so static `ImageRenderer` mockups and Classic mode
    /// never fire Force Touch haptics unless `PopoverView` explicitly enables them.
    static let defaultValue = false
}

extension EnvironmentValues {
    var craftHapticsEnabled: Bool {
        get { self[CraftHapticsEnabledKey.self] }
        set { self[CraftHapticsEnabledKey.self] = newValue }
    }
}

// MARK: - Bespoke 5-Tab Instrument Haptic Grammar

/// Tactile feedback cues bound strictly to the `Instrument` visual style.
/// Combines macOS's three native Taptic Engine patterns (`.alignment`, `.levelChange`, `.generic`)
/// with cancellable 2-beat micro-cadences so each of the 5 Instrument tabs has its own physical feel.
enum InstrumentHapticCue: Equatable, Sendable {
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

// MARK: - Craft Engine (Instrument Force Touch Grammar + Pure-Code Acoustic Chimes)

/// Tactile and acoustic craft feedback engine for AGYMonitor.
/// - Instrument Force Touch cues throttle per-cue and cancel any pending cadence beat on new input
///   so rapid scrubbing feels like precision horology rather than buzzing.
/// - Acoustic cockpit chimes synthesize whisper-quiet PCM buffers in pure code (zero
///   bundled audio files) and tear down AVAudioEngine after idle playback so idle CPU
///   and audio hardware usage remain 0%.
@MainActor
final class CraftEngine {
    static let shared = CraftEngine()

    private struct HapticRecipe {
        let primary: NSHapticFeedbackManager.FeedbackPattern
        let followUp: (pattern: NSHapticFeedbackManager.FeedbackPattern, delay: TimeInterval)?
        let minInterval: TimeInterval
        /// Landmarks (peaks, pins, alerts, explicit mode/tab actions) may cut through an
        /// active scrub cue after `salientInterruptFloor` so fast sweeps never miss summits.
        let isSalient: Bool
    }

    private static let salientInterruptFloor: TimeInterval = 0.018
    private static let sampleRate: Double = 44_100.0
    private static let idleTeardownDelay: TimeInterval = 0.50

    private var lastHapticUptime: TimeInterval = 0
    private var lastHapticCue: InstrumentHapticCue?
    private var pendingCadenceWorkItem: DispatchWorkItem?
    private var triggerState = AcousticTriggerState()

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var teardownWorkItem: DispatchWorkItem?

    private init() {}

    // MARK: Instrument Force Touch Grammar

    /// Compatibility wrapper forwarding to `.chronometerCrown`.
    func tickDetent(enabled: Bool) {
        perform(.chronometerCrown, enabled: enabled)
    }

    /// Cancels any queued second beat of a double-tap cadence immediately.
    func cancelPendingHapticCadence() {
        pendingCadenceWorkItem?.cancel()
        pendingCadenceWorkItem = nil
    }

    /// Performs a bespoke Force Touch cue with per-cue throttling and clean cadence cancellation.
    func perform(_ cue: InstrumentHapticCue, enabled: Bool) {
        guard enabled else {
            cancelPendingHapticCadence()
            return
        }

        let recipe = Self.recipe(for: cue)
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastHapticUptime
        let requiredInterval: TimeInterval = (recipe.isSalient && lastHapticCue != cue)
            ? min(recipe.minInterval, Self.salientInterruptFloor)
            : recipe.minInterval

        guard elapsed >= requiredInterval else { return }

        cancelPendingHapticCadence()
        lastHapticUptime = now
        lastHapticCue = cue

        NSHapticFeedbackManager.defaultPerformer.perform(recipe.primary, performanceTime: .now)

        if let followUp = recipe.followUp {
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.pendingCadenceWorkItem = nil
                NSHapticFeedbackManager.defaultPerformer.perform(followUp.pattern, performanceTime: .now)
            }
            pendingCadenceWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + followUp.delay, execute: work)
        }
    }

    private static func recipe(for cue: InstrumentHapticCue) -> HapticRecipe {
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
                followUp: (pattern: .levelChange, delay: 0.055),
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
                followUp: (pattern: .alignment, delay: 0.060),
                minInterval: 0.140,
                isSalient: true
            )
        case .creditsTick:
            return HapticRecipe(primary: .generic, followUp: nil, minInterval: 0.050, isSalient: false)
        }
    }

    // MARK: Session Acoustic Edge Transitions

    /// Feeds live session transition sets into the pure `AcousticTriggerState` edge detector
    /// and plays a whisper-quiet synthesized cue only on newly triggered edge events.
    func handleSessionTransition(
        waitingIds: Set<String>,
        doneUnseenIds: Set<String>,
        enabled: Bool
    ) {
        // Always advance the pure baseline state so enabling chimes later never fires stale sessions.
        let cue = triggerState.update(waitingIds: waitingIds, doneUnseenIds: doneUnseenIds)
        guard enabled, let cue = cue else { return }
        playCue(cue, enabled: true)
    }

    // MARK: Pure-Code Synthesized Acoustic Chimes

    /// Plays a whisper-quiet, click-free synthesized chime and tears down the audio engine
    /// cleanly once playback finishes. Gracefully no-ops in headless / no-audio environments.
    func playCue(_ cue: AcousticCue, enabled: Bool) {
        guard enabled else { return }
        guard let buffer = makeCueBuffer(for: cue) else { return }

        teardownWorkItem?.cancel()
        teardownWorkItem = nil

        guard let (engine, player) = ensureAudioGraph(format: buffer.format) else {
            teardownAudioGraph()
            return
        }

        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                teardownAudioGraph()
                return
            }
        }

        player.scheduleBuffer(buffer, at: nil, options: [])
        if !player.isPlaying {
            player.play()
        }

        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        let work = DispatchWorkItem { [weak self] in
            self?.teardownAudioGraph()
        }
        teardownWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + Self.idleTeardownDelay, execute: work)
    }

    private func ensureAudioGraph(format: AVAudioFormat) -> (AVAudioEngine, AVAudioPlayerNode)? {
        if let engine = audioEngine, let player = playerNode {
            return (engine, player)
        }

        let engine = AVAudioEngine()
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        guard outputFormat.sampleRate > 0, outputFormat.channelCount > 0 else {
            return nil
        }

        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()

        self.audioEngine = engine
        self.playerNode = player
        return (engine, player)
    }

    private func teardownAudioGraph() {
        teardownWorkItem?.cancel()
        teardownWorkItem = nil
        playerNode?.stop()
        audioEngine?.stop()
        audioEngine?.reset()
        playerNode = nil
        audioEngine = nil
    }

    private func makeCueBuffer(for cue: AcousticCue) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1) else {
            return nil
        }

        let duration: Double
        switch cue {
        case .waitingPing:   duration = 0.18
        case .turnDoneChord: duration = 0.24
        }

        let frameCount = AVAudioFrameCount((duration * Self.sampleRate).rounded())
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let samples = buffer.floatChannelData?[0] else {
            return nil
        }
        buffer.frameLength = frameCount

        let n = Int(frameCount)
        let twoPi = 2.0 * Double.pi

        switch cue {
        case .waitingPing:
            // Soft damped 440Hz (A4) + 880Hz (A5) brass chime (~180ms, peak ~0.08)
            let peak = 0.08
            let attack = 0.0045
            let releaseTail = 0.014
            for i in 0..<n {
                let t = Double(i) / Self.sampleRate
                let attackEnv = t < attack ? 0.5 * (1.0 - cos(Double.pi * t / attack)) : 1.0
                let decayEnv = exp(-t / 0.056)
                let rem = duration - t
                let tailEnv = rem < releaseTail ? 0.5 * (1.0 - cos(Double.pi * max(0.0, rem) / releaseTail)) : 1.0
                let env = attackEnv * decayEnv * tailEnv

                let fundamental = sin(twoPi * 440.0 * t)
                let overtone = sin(twoPi * 880.0 * t) * exp(-t / 0.036)
                let sample = peak * env * (0.72 * fundamental + 0.28 * overtone)
                samples[i] = Float(sample)
            }

        case .turnDoneChord:
            // Soft damped two-tone harmonic chord (523.25Hz C5 + 659.25Hz E5, ~240ms, peak ~0.07)
            let peak = 0.07
            let attack = 0.005
            let secondOnset = 0.018
            let releaseTail = 0.018
            for i in 0..<n {
                let t = Double(i) / Self.sampleRate
                let rem = duration - t
                let tailEnv = rem < releaseTail ? 0.5 * (1.0 - cos(Double.pi * max(0.0, rem) / releaseTail)) : 1.0

                let a1 = t < attack ? 0.5 * (1.0 - cos(Double.pi * t / attack)) : 1.0
                let d1 = exp(-t / 0.078)
                let voice1 = a1 * d1 * sin(twoPi * 523.25 * t)

                let voice2: Double
                if t > secondOnset {
                    let t2 = t - secondOnset
                    let a2 = t2 < attack ? 0.5 * (1.0 - cos(Double.pi * t2 / attack)) : 1.0
                    let d2 = exp(-t2 / 0.085)
                    voice2 = a2 * d2 * sin(twoPi * 659.25 * t2)
                } else {
                    voice2 = 0.0
                }

                let sample = peak * tailEnv * (0.56 * voice1 + 0.44 * voice2)
                samples[i] = Float(sample)
            }
        }

        // Guarantee exact zero boundary samples to prevent any hardware click/pop.
        samples[0] = 0
        samples[n - 1] = 0
        return buffer
    }
}
