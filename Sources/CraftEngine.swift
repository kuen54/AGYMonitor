import AppKit
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

// MARK: - Craft Engine (Instrument Force Touch Grammar + Pure-Code Acoustic Chimes)

/// Tactile and acoustic craft feedback engine for AGYMonitor.
/// - Instrument Force Touch cues are governed by pure `HapticCadenceMachine` (`Core_CraftState.swift`)
///   for deterministic throttling, salient landmark interrupts, and generation-guarded 2-beat cadences.
/// - Acoustic cockpit chimes synthesize whisper-quiet 16-bit PCM RIFF/WAV waveforms in pure code
///   (zero bundled audio files, zero `AVAudioEngine` graph/route-change crash risk) played via
///   in-memory `NSSound(data:)` and governed by `AcousticEngineLifecycleMachine` (`Core_CraftState.swift`)
///   for multi-chime drain accumulation and idle teardown.
@MainActor
final class CraftEngine {
    static let shared = CraftEngine()

    private static let sampleRate: Double = 44_100.0

    private var hapticState = HapticCadenceState()
    private var pendingCadenceWorkItem: DispatchWorkItem?

    private var triggerState = AcousticTriggerState()
    private var acousticEngineState = AcousticEngineState()

    private var activeSounds: [NSSound] = []
    private var cachedCueWAVs: [AcousticCue: (data: Data, duration: Double)] = [:]
    private var teardownWorkItem: DispatchWorkItem?

    private init() {}

    // MARK: Instrument Force Touch Grammar

    /// Compatibility wrapper forwarding to `.chronometerCrown`.
    func tickDetent(enabled: Bool) {
        perform(.chronometerCrown, enabled: enabled)
    }

    /// Cancels any queued second beat of a double-tap cadence immediately.
    func cancelPendingHapticCadence() {
        dispatchHaptic(.cancel)
    }

    /// Performs a bespoke Force Touch cue with per-cue throttling and clean cadence cancellation.
    func perform(_ cue: InstrumentHapticCue, enabled: Bool) {
        dispatchHaptic(.perform(
            cue: cue,
            enabled: enabled,
            now: ProcessInfo.processInfo.systemUptime
        ))
    }

    private func dispatchHaptic(_ event: HapticCadenceEvent) {
        let effects = HapticCadenceMachine.reduce(&hapticState, event: event)
        for effect in effects {
            switch effect {
            case .trigger(let pattern):
                NSHapticFeedbackManager.defaultPerformer.perform(
                    Self.nsPattern(for: pattern),
                    performanceTime: .now
                )

            case .scheduleFollowUp(let generation, let pattern, let delay):
                pendingCadenceWorkItem?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    self.pendingCadenceWorkItem = nil
                    self.dispatchHaptic(.followUpFired(generation: generation, pattern: pattern))
                }
                pendingCadenceWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)

            case .cancelFollowUp:
                pendingCadenceWorkItem?.cancel()
                pendingCadenceWorkItem = nil
            }
        }
    }

    private static func nsPattern(for kind: HapticPatternKind) -> NSHapticFeedbackManager.FeedbackPattern {
        switch kind {
        case .alignment:   return .alignment
        case .levelChange: return .levelChange
        case .generic:     return .generic
        }
    }

    // MARK: Session Acoustic Edge Transitions

    /// Clears the acoustic edge-detector baseline (e.g. before initial scan or after monitoring stops).
    func resetAcousticBaseline() {
        triggerState.reset()
    }

    /// Feeds live session transition sets into the pure `AcousticTriggerState` edge detector
    /// and plays a whisper-quiet synthesized cue only on newly triggered post-scan edge events.
    func handleSessionTransition(
        waitingIds: Set<String>,
        doneUnseenIds: Set<String>,
        hasCompletedInitialScan: Bool = true,
        enabled: Bool
    ) {
        // Always advance the pure baseline state once initial scan completes so enabling
        // chimes later never fires stale sessions.
        let cue = triggerState.update(
            waitingIds: waitingIds,
            doneUnseenIds: doneUnseenIds,
            hasCompletedInitialScan: hasCompletedInitialScan
        )
        guard enabled, let cue = cue else { return }
        playAcoustic(cue, enabled: true)
    }

    // MARK: Pure-Code Synthesized Acoustic Chimes

    /// Plays a whisper-quiet, click-free synthesized WAV chime via `NSSound(data:)` and clears
    /// active sound handles once all queued chimes drain. Gracefully no-ops in headless / no-audio environments.
    func playAcoustic(_ cue: AcousticCue, enabled: Bool) {
        guard enabled else { return }
        dispatchAcousticEngine(.play(
            cue: cue,
            bufferDuration: Self.cueDuration(for: cue),
            now: ProcessInfo.processInfo.systemUptime
        ))
    }

    /// Compatibility alias forwarding to `playAcoustic(_:enabled:)`.
    func playCue(_ cue: AcousticCue, enabled: Bool) {
        playAcoustic(cue, enabled: enabled)
    }

    /// Stops and releases active acoustic chimes immediately when chimes are disabled in preferences.
    func teardownAudioEngine() {
        dispatchAcousticEngine(.disabled)
    }

    /// Cleanly cancels pending haptic cadences and stops active acoustic chimes on app termination.
    func shutdown() {
        cancelPendingHapticCadence()
        dispatchAcousticEngine(.terminate)
    }

    private func dispatchAcousticEngine(_ event: AcousticEngineEvent) {
        let effects = AcousticEngineLifecycleMachine.reduce(&acousticEngineState, event: event)
        var playFailed = false
        for effect in effects {
            switch effect {
            case .cancelTeardown:
                teardownWorkItem?.cancel()
                teardownWorkItem = nil

            case .ensureGraphAndPlay(let cue):
                if !playCueWAV(for: cue) {
                    playFailed = true
                }

            case .scheduleTeardown(let generation, let delay):
                guard !playFailed else { continue }
                teardownWorkItem?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    self.teardownWorkItem = nil
                    self.dispatchAcousticEngine(.teardownFired(generation: generation))
                }
                teardownWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)

            case .teardownGraph:
                teardownAudioGraph()
            }
        }
        if playFailed {
            dispatchAcousticEngine(.configurationChanged)
        }
    }

    private func playCueWAV(for cue: AcousticCue) -> Bool {
        let wav: (data: Data, duration: Double)
        if let cached = cachedCueWAVs[cue] {
            wav = cached
        } else {
            let synthesized = Self.synthesizePCM16WAV(for: cue)
            guard !synthesized.data.isEmpty else { return false }
            cachedCueWAVs[cue] = synthesized
            wav = synthesized
        }
        guard let sound = NSSound(data: wav.data) else { return false }
        activeSounds.removeAll { !$0.isPlaying }
        guard sound.play() else { return false }
        activeSounds.append(sound)
        return true
    }

    private func teardownAudioGraph() {
        teardownWorkItem?.cancel()
        teardownWorkItem = nil
        for sound in activeSounds {
            sound.stop()
        }
        activeSounds.removeAll()
    }

    private static func cueDuration(for cue: AcousticCue) -> Double {
        switch cue {
        case .waitingPing:   return 0.18
        case .turnDoneChord: return 0.24
        }
    }

    /// Synthesizes a canonical 44-byte RIFF/WAVE header + 16-bit signed mono PCM waveform
    /// in memory with exact zero start/end samples to guarantee click-free playback.
    static func synthesizePCM16WAV(for cue: AcousticCue) -> (data: Data, duration: Double) {
        let duration = cueDuration(for: cue)
        let n = Int((duration * sampleRate).rounded())
        guard n > 1 else { return (Data(), 0.0) }

        let twoPi = 2.0 * Double.pi
        var floatSamples = [Double](repeating: 0.0, count: n)

        switch cue {
        case .waitingPing:
            // Soft damped 440Hz (A4) + 880Hz (A5) brass chime (~180ms, peak ~0.08)
            let peak = 0.08
            let attack = 0.0045
            let releaseTail = 0.014
            for i in 0..<n {
                let t = Double(i) / sampleRate
                let attackEnv = t < attack ? 0.5 * (1.0 - cos(Double.pi * t / attack)) : 1.0
                let decayEnv = exp(-t / 0.056)
                let rem = duration - t
                let tailEnv = rem < releaseTail ? 0.5 * (1.0 - cos(Double.pi * max(0.0, rem) / releaseTail)) : 1.0
                let env = attackEnv * decayEnv * tailEnv

                let fundamental = sin(twoPi * 440.0 * t)
                let overtone = sin(twoPi * 880.0 * t) * exp(-t / 0.036)
                floatSamples[i] = peak * env * (0.72 * fundamental + 0.28 * overtone)
            }

        case .turnDoneChord:
            // Soft damped two-tone harmonic chord (523.25Hz C5 + 659.25Hz E5, ~240ms, peak ~0.07)
            let peak = 0.07
            let attack = 0.005
            let secondOnset = 0.018
            let releaseTail = 0.018
            for i in 0..<n {
                let t = Double(i) / sampleRate
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

                floatSamples[i] = peak * tailEnv * (0.56 * voice1 + 0.44 * voice2)
            }
        }

        // Guarantee exact zero boundary samples to prevent any hardware click/pop.
        floatSamples[0] = 0.0
        floatSamples[n - 1] = 0.0

        let sampleRateU32 = UInt32(sampleRate)
        let channelsU16: UInt16 = 1
        let bitsPerSampleU16: UInt16 = 16
        let blockAlignU16 = channelsU16 * (bitsPerSampleU16 / 8)
        let byteRateU32 = sampleRateU32 * UInt32(blockAlignU16)
        let dataByteCount = UInt32(n * Int(blockAlignU16))
        let riffChunkSize = 36 + dataByteCount

        var wav = Data(capacity: 44 + Int(dataByteCount))
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { wav.append(contentsOf: $0) }
        }

        // 44-byte RIFF/WAVE PCM header
        wav.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        appendLE(riffChunkSize)
        wav.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        wav.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        appendLE(UInt32(16))                             // PCM fmt chunk size
        appendLE(UInt16(1))                              // AudioFormat = 1 (Linear PCM)
        appendLE(channelsU16)                            // NumChannels = 1
        appendLE(sampleRateU32)                          // SampleRate = 44100
        appendLE(byteRateU32)                            // ByteRate = 88200
        appendLE(blockAlignU16)                          // BlockAlign = 2
        appendLE(bitsPerSampleU16)                       // BitsPerSample = 16
        wav.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        appendLE(dataByteCount)

        for sample in floatSamples {
            let clamped = sample.isFinite ? max(-1.0, min(1.0, sample)) : 0.0
            let pcm = Int16((clamped * 32767.0).rounded())
            appendLE(pcm)
        }

        return (wav, duration)
    }
}
