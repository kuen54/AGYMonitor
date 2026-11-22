import Foundation
import Testing
@testable import AGYCore

@Suite("Core_LiveTelemetry")
struct LiveTelemetryTests {

    // MARK: - ContextWindowCatalog

    @Test("Maps Gemini, Claude, Claude-1M, and fallback models to expected context windows")
    func contextWindowCatalogLookup() {
        #expect(ContextWindowCatalog.windowTokens(for: "gemini-4-carbon-high") == 1_000_000)
        #expect(ContextWindowCatalog.windowTokens(for: "gemini-pro-orchestrator-argon") == 1_000_000)
        #expect(ContextWindowCatalog.windowTokens(for: "gemini-pro-orchestrator-neon") == 1_000_000)
        #expect(ContextWindowCatalog.windowTokens(for: "gemini-4-hydrogen-tiered-high") == 1_000_000)
        #expect(ContextWindowCatalog.windowTokens(for: "gemini-2.5-flash") == 1_000_000)
        #expect(ContextWindowCatalog.windowTokens(for: "gemini-2.5-pro") == 1_000_000)
        #expect(ContextWindowCatalog.windowTokens(for: "orchestrator") == 1_000_000)

        #expect(ContextWindowCatalog.windowTokens(for: "claude-sonnet-4-5") == 200_000)
        #expect(ContextWindowCatalog.windowTokens(for: "claude-opus-4-6") == 200_000)
        #expect(ContextWindowCatalog.windowTokens(for: "haiku-4.5") == 200_000)
        #expect(ContextWindowCatalog.windowTokens(for: "claude-sonnet-4-1m") == 1_000_000)
        #expect(ContextWindowCatalog.windowTokens(for: "Claude Opus 4 (1M)") == 1_000_000)

        #expect(ContextWindowCatalog.windowTokens(for: "gpt-oss-120b") == 128_000)
        #expect(ContextWindowCatalog.windowTokens(for: "unknown-model") == 128_000)
        #expect(ContextWindowCatalog.windowTokens(for: "") == 128_000)
    }

    // MARK: - SessionContextSnapshot

    @Test("Computes nominal, warning, critical pressure levels and clamping accurately")
    func sessionContextPressureAndClamping() {
        // Nominal: 75% remaining (exact boundary >= 0.25)
        let nominal = SessionContextSnapshot.make(
            model: "gemini-4-carbon-high",
            usedTokens: 250_000,
            cacheHitRatio: 0.91
        )
        #expect(nominal.modelClass == .carbon)
        #expect(nominal.windowTokens == 1_000_000)
        #expect(nominal.remainingTokens == 750_000)
        #expect(nominal.remainingPercent == 75)
        #expect(nominal.pressureLevel == .nominal)
        #expect(nominal.needsCompactHint == false)
        #expect(nominal.cacheHitRatio == 0.91)

        // Boundary: exactly 25% remaining is nominal
        let boundaryNominal = SessionContextSnapshot.make(
            model: "claude-sonnet-4",
            usedTokens: 150_000,
            cacheHitRatio: 0.5
        )
        #expect(boundaryNominal.remainingPercent == 25)
        #expect(boundaryNominal.pressureLevel == .nominal)
        #expect(boundaryNominal.needsCompactHint == false)

        // Warning: 18% remaining (< 25% and >= 10%)
        let warning = SessionContextSnapshot.make(
            model: "claude-opus-4",
            usedTokens: 164_000,
            cacheHitRatio: 0.80
        )
        #expect(warning.modelClass == .claude)
        #expect(warning.windowTokens == 200_000)
        #expect(warning.remainingTokens == 36_000)
        #expect(warning.remainingPercent == 18)
        #expect(warning.pressureLevel == .warning)
        #expect(warning.needsCompactHint == false)

        // Critical: 8% remaining (< 10%)
        let critical = SessionContextSnapshot.make(
            model: "claude-opus-4",
            usedTokens: 184_000,
            cacheHitRatio: nil
        )
        #expect(critical.remainingTokens == 16_000)
        #expect(critical.remainingPercent == 8)
        #expect(critical.pressureLevel == .critical)
        #expect(critical.needsCompactHint == true)
        #expect(critical.cacheHitRatio == nil)

        // Over-window clamping: usedTokens > windowTokens -> 0 remaining, 0%, critical
        let overflow = SessionContextSnapshot.make(
            model: "gpt-oss-120b",
            usedTokens: 150_000,
            cacheHitRatio: 1.5
        )
        #expect(overflow.windowTokens == 128_000)
        #expect(overflow.remainingTokens == 0)
        #expect(overflow.remainingRatio == 0.0)
        #expect(overflow.remainingPercent == 0)
        #expect(overflow.pressureLevel == .critical)
        #expect(overflow.needsCompactHint == true)
        #expect(overflow.cacheHitRatio == 1.0)

        // Negative input clamping
        let negative = SessionContextSnapshot.make(
            model: "gemini-4-carbon-high",
            usedTokens: -500,
            cacheHitRatio: -0.2
        )
        #expect(negative.usedTokens == 0)
        #expect(negative.remainingTokens == 1_000_000)
        #expect(negative.remainingPercent == 100)
        #expect(negative.pressureLevel == .nominal)
        #expect(negative.cacheHitRatio == 0.0)
    }

    // MARK: - TranscriptParse Telemetry Extraction

    @Test("Extracts latestModel, context tokens (with cache_write), cache hit ratio, and last 12 output samples")
    func transcriptTailTelemetryExtraction() throws {
        var lines: [String] = [
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-11-22T09:00:00Z","content":"<USER_REQUEST>Build telemetry</USER_REQUEST>"}"#
        ]

        // Emit 15 PLANNER_RESPONSE steps to verify cap at last 12 sorted ascending by stepIndex
        for i in 1...15 {
            let sec = String(format: "%02d", i * 3)
            let input = 1_000 + i * 100
            let cacheRead = 10_000 + i * 500
            let cacheWrite = (i == 15) ? 400 : 0
            let output = 100 + i * 20
            lines.append(
                #"{"step_index":\#(i),"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-22T09:00:\#(sec)Z","model":"gemini-4-carbon-high","input_tokens":\#(input),"cache_read_tokens":\#(cacheRead),"cache_write_tokens":\#(cacheWrite),"output_tokens":\#(output)}"#
            )
        }

        // Trailing RUNNING step with sentinel timestamp and no tokens must NOT clobber latestContextUsedTokens
        lines.append(
            #"{"step_index":16,"source":"MODEL","type":"PLANNER_RESPONSE","status":"RUNNING","created_at":"0001-01-01T00:00:00Z","model":"gemini-4-carbon-high"}"#
        )

        let summary = TranscriptParse.scan(text: lines.joined(separator: "\n"))
        #expect(summary.latestModel == "gemini-4-carbon-high")
        #expect(summary.lastModel == "gemini-4-carbon-high")

        // Step 15: input=2500, cache_read=17500, cache_write=400, output=400 => 20800
        #expect(summary.latestContextUsedTokens == 20_800)
        let ratio = try #require(summary.latestCacheHitRatio)
        #expect(abs(ratio - (17_500.0 / 20_000.0)) < 1e-9)

        // Only last 12 valid steps (4...15) kept, sorted ascending by stepIndex
        #expect(summary.recentOutputSamples.count == 12)
        #expect(summary.recentOutputSamples.first?.stepIndex == 4)
        #expect(summary.recentOutputSamples.last?.stepIndex == 15)
        #expect(summary.recentOutputSamples.last?.outputTokens == 400)

        let stepIndices = summary.recentOutputSamples.map(\.stepIndex)
        #expect(stepIndices == Array(4...15))
    }

    @Test("TranscriptParse leaves context tokens and cache ratio nil when absent")
    func transcriptWithoutTokenCounts() {
        let transcript = """
        {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-11-22T09:00:00Z","content":"<USER_REQUEST>Hello</USER_REQUEST>"}
        {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"RUNNING","created_at":"2026-11-22T09:00:02Z","model":"gemini-pro-orchestrator-neon"}
        """
        let summary = TranscriptParse.scan(text: transcript)
        #expect(summary.latestModel == "gemini-pro-orchestrator-neon")
        #expect(summary.latestContextUsedTokens == nil)
        #expect(summary.latestCacheHitRatio == nil)
        #expect(summary.recentOutputSamples.isEmpty)
    }

    // MARK: - LiveTPSTracker

    @Test("Aggregates multi-session TPS, caps sparkline, clamps extreme bursts, and tracks peak")
    func liveTPSMultiSessionAggregation() {
        var tracker = LiveTPSTracker(sparklineCapacity: 4, windowSeconds: 30.0)

        // Session A: 2 samples in window -> 600 / (108 - 100) = 75 t/s
        // Session B: 3 samples in window -> (200 + 300) / (109 - 99) = 50 t/s
        let samplesA = [
            OutputTokenSample(stepIndex: 1, timestamp: 100.0, outputTokens: 250),
            OutputTokenSample(stepIndex: 2, timestamp: 108.0, outputTokens: 600),
        ]
        let samplesB = [
            OutputTokenSample(stepIndex: 1, timestamp: 99.0, outputTokens: 150),
            OutputTokenSample(stepIndex: 2, timestamp: 104.0, outputTokens: 200),
            OutputTokenSample(stepIndex: 3, timestamp: 109.0, outputTokens: 300),
        ]

        let snap1 = tracker.update(
            busySessionIds: ["a", "b"],
            samplesBySession: ["a": samplesA, "b": samplesB],
            now: 110.0
        )
        #expect(snap1.isWorking == true)
        #expect(abs((snap1.perSessionTPS["a"] ?? 0) - 75.0) < 1e-6)
        #expect(abs((snap1.perSessionTPS["b"] ?? 0) - 50.0) < 1e-6)
        #expect(abs(snap1.currentTPS - 125.0) < 1e-6)
        #expect(abs(snap1.peakTPS - 125.0) < 1e-6)
        #expect(snap1.sparkline.count == 1)

        // Test clamping ceiling (1200 per session) on sub-second burst
        let burst = [
            OutputTokenSample(stepIndex: 1, timestamp: 111.0, outputTokens: 100),
            OutputTokenSample(stepIndex: 2, timestamp: 111.2, outputTokens: 9_999),
        ]
        let snap2 = tracker.update(
            busySessionIds: ["burst"],
            samplesBySession: ["burst": burst],
            now: 112.0
        )
        #expect(abs((snap2.perSessionTPS["burst"] ?? 0) - 1200.0) < 1e-6)
        #expect(abs(snap2.peakTPS - 1200.0) < 1e-6)

        // Push 4 more updates to verify sparklineCapacity == 4 trimming
        for i in 1...4 {
            let s = tracker.update(
                busySessionIds: ["a"],
                samplesBySession: ["a": samplesA],
                now: 112.0 + Double(i)
            )
            #expect(s.sparkline.count <= 4)
        }
    }

    @Test("Smoothly decays busy session TPS when generating next step and resets cleanly on idle")
    func liveTPSSmoothDecayAndIdleReset() {
        var tracker = LiveTPSTracker(sparklineCapacity: 20, windowSeconds: 30.0)

        // Initial measurement: 800 / 8s = 100 t/s
        let samples = [
            OutputTokenSample(stepIndex: 1, timestamp: 100.0, outputTokens: 300),
            OutputTokenSample(stepIndex: 2, timestamp: 108.0, outputTokens: 800),
        ]
        let t1 = tracker.update(busySessionIds: ["s1"], samplesBySession: ["s1": samples], now: 110.0)
        #expect(abs(t1.currentTPS - 100.0) < 1e-6)

        // Busy session with no fresh sample (empty samples) decays smoothly by 0.88x per tick
        let t2 = tracker.update(busySessionIds: ["s1"], samplesBySession: [:], now: 115.0)
        let t3 = tracker.update(busySessionIds: ["s1"], samplesBySession: [:], now: 120.0)
        #expect(t2.isWorking == true)
        #expect(abs(t2.currentTPS - 88.0) < 1e-6)
        #expect(abs(t3.currentTPS - (88.0 * 0.88)) < 1e-6)
        #expect(t3.currentTPS < t2.currentTPS && t3.currentTPS > 0)

        // Also verify single-sample estimation + gentle decay past 12s
        var singleTracker = LiveTPSTracker()
        let singleSample = [OutputTokenSample(stepIndex: 1, timestamp: 200.0, outputTokens: 300)]
        let fresh = singleTracker.update(busySessionIds: ["s2"], samplesBySession: ["s2": singleSample], now: 202.0)
        let aged = singleTracker.update(busySessionIds: ["s2"], samplesBySession: ["s2": singleSample], now: 220.0)
        #expect(fresh.currentTPS > 0)
        #expect(aged.currentTPS > 0 && aged.currentTPS < fresh.currentTPS)

        // Idle reset clears history and returns .idle
        let idle = tracker.update(busySessionIds: [], samplesBySession: [:], now: 125.0)
        #expect(idle == .idle)
        #expect(idle.isWorking == false)
        #expect(idle.currentTPS == 0)
        #expect(idle.peakTPS == 0)
        #expect(idle.sparkline.isEmpty)
        #expect(idle.perSessionTPS.isEmpty)
    }

    @Test("Formats compact TPS strings cleanly across thresholds")
    func compactTPSFormatting() {
        #expect(LiveTPSTracker.formatCompactTPS(-10.0) == "--")
        #expect(LiveTPSTracker.formatCompactTPS(0.0) == "--")
        #expect(LiveTPSTracker.formatCompactTPS(0.49) == "--")
        #expect(LiveTPSTracker.formatCompactTPS(.nan) == "--")
        #expect(LiveTPSTracker.formatCompactTPS(0.5) == "1 t/s")
        #expect(LiveTPSTracker.formatCompactTPS(84.4) == "84 t/s")
        #expect(LiveTPSTracker.formatCompactTPS(999.0) == "999 t/s")
        #expect(LiveTPSTracker.formatCompactTPS(1000.0) == "1.0k/s")
        #expect(LiveTPSTracker.formatCompactTPS(1240.0) == "1.2k/s")
    }
}
