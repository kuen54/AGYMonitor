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

    @Test("Decays busy session TPS by wall-clock time (0.88x per 2s) and resets cleanly on idle")
    func liveTPSSmoothDecayAndIdleReset() {
        var tracker = LiveTPSTracker(sparklineCapacity: 20, windowSeconds: 30.0)

        // Initial measurement: 800 / 8s = 100 t/s
        let samples = [
            OutputTokenSample(stepIndex: 1, timestamp: 100.0, outputTokens: 300),
            OutputTokenSample(stepIndex: 2, timestamp: 108.0, outputTokens: 800),
        ]
        let t1 = tracker.update(busySessionIds: ["s1"], samplesBySession: ["s1": samples], now: 110.0)
        #expect(abs(t1.currentTPS - 100.0) < 1e-6)

        // Duplicate same-timestamp scan (dt == 0) does NOT over-decay
        let tSame = tracker.update(busySessionIds: ["s1"], samplesBySession: [:], now: 110.0)
        #expect(abs(tSame.currentTPS - 100.0) < 1e-6)

        // 2.0s elapsed -> exact 0.88x decay (88.0 t/s)
        let t2 = tracker.update(busySessionIds: ["s1"], samplesBySession: [:], now: 112.0)
        #expect(t2.isWorking == true)
        #expect(abs(t2.currentTPS - 88.0) < 1e-6)

        // Another 2.0s via 10 rapid 0.2s FSEvents bursts matches a single 2.0s step (88.0 * 0.88)
        var burstSnap = t2
        for i in 1...10 {
            burstSnap = tracker.update(
                busySessionIds: ["s1"],
                samplesBySession: [:],
                now: 112.0 + Double(i) * 0.2
            )
        }
        #expect(abs(burstSnap.currentTPS - (88.0 * 0.88)) < 1e-5)

        // 6.0s closed-panel poll interval decays by 0.88^3
        let t6 = tracker.update(busySessionIds: ["s1"], samplesBySession: [:], now: 120.0)
        #expect(abs(t6.currentTPS - (88.0 * 0.88 * pow(0.88, 3.0))) < 1e-4)

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
        #expect(idle.shouldShowInNotch == false)
        #expect(idle.shouldShowInMenuBar == false)
    }

    @Test("Detects in-place streaming outputTokens growth on same stepIndex as fresh output")
    func liveTPSInPlaceStreamingStepDetection() {
        var tracker = LiveTPSTracker(sparklineCapacity: 20, windowSeconds: 30.0)

        let initial = [
            OutputTokenSample(stepIndex: 1, timestamp: 100.0, outputTokens: 100),
            OutputTokenSample(stepIndex: 2, timestamp: 104.0, outputTokens: 200),
        ]
        // Initial scan at t=105 -> 200 / 4.0 = 50 t/s
        let s1 = tracker.update(busySessionIds: ["s1"], samplesBySession: ["s1": initial], now: 105.0)
        #expect(abs(s1.currentTPS - 50.0) < 1e-6)

        // Same stepIndex=2 streams to 600 tokens even when created_at age > 12s (t=120) -> fresh output!
        let streamed = [
            OutputTokenSample(stepIndex: 1, timestamp: 100.0, outputTokens: 100),
            OutputTokenSample(stepIndex: 2, timestamp: 104.0, outputTokens: 600),
        ]
        let s2 = tracker.update(busySessionIds: ["s1"], samplesBySession: ["s1": streamed], now: 120.0)
        #expect(abs(s2.currentTPS - 150.0) < 1e-6)

        // Once streaming stops (same stepIndex & same outputTokens at t=122), decays cleanly
        let s3 = tracker.update(busySessionIds: ["s1"], samplesBySession: ["s1": streamed], now: 122.0)
        #expect(abs(s3.currentTPS - (150.0 * 0.88)) < 1e-6)
    }

    @Test("Throttles sparkline appends below 1.5s and applies age decay on Branch 2 cold start")
    func liveTPSSparklineThrottleAndBranch2ColdStart() {
        var tracker = LiveTPSTracker(sparklineCapacity: 5, windowSeconds: 30.0)
        let samples1 = [
            OutputTokenSample(stepIndex: 1, timestamp: 100.0, outputTokens: 100),
            OutputTokenSample(stepIndex: 2, timestamp: 104.0, outputTokens: 400),
        ]
        let samples2 = [
            OutputTokenSample(stepIndex: 1, timestamp: 100.0, outputTokens: 100),
            OutputTokenSample(stepIndex: 2, timestamp: 104.0, outputTokens: 800),
        ]

        // t=105 -> appends point #1 (100 t/s)
        let a = tracker.update(busySessionIds: ["s1"], samplesBySession: ["s1": samples1], now: 105.0)
        #expect(a.sparkline.count == 1)
        #expect(abs(a.sparkline[0] - 100.0) < 1e-6)

        // Rapid burst within <1.5s updates last point in place instead of appending
        let b = tracker.update(busySessionIds: ["s1"], samplesBySession: ["s1": samples2], now: 105.4)
        let c = tracker.update(busySessionIds: ["s1"], samplesBySession: ["s1": samples2], now: 106.2)
        #expect(b.sparkline.count == 1)
        #expect(c.sparkline.count == 1)
        #expect(abs(c.sparkline[0] - 200.0) < 1e-6)

        // At dt >= 1.5s (t=106.5), appends point #2
        let d = tracker.update(busySessionIds: ["s1"], samplesBySession: ["s1": samples2], now: 106.5)
        #expect(d.sparkline.count == 2)

        // Branch 2 cold start: 80s-old pair (raw rate 100 t/s) must be strongly age-decayed, not spiked
        var coldTracker = LiveTPSTracker(sparklineCapacity: 20, windowSeconds: 30.0)
        let oldPair = [
            OutputTokenSample(stepIndex: 1, timestamp: 112.0, outputTokens: 200),
            OutputTokenSample(stepIndex: 2, timestamp: 120.0, outputTokens: 800), // raw = 100 t/s
        ]
        let coldSnap = coldTracker.update(busySessionIds: ["old"], samplesBySession: ["old": oldPair], now: 200.0)
        // age = 80s -> extraAge = 68s -> 100 * pow(decayPerSecond, 68) ~= 1.297 t/s (far below 100 t/s)
        #expect(coldSnap.currentTPS > 0.5 && coldSnap.currentTPS < 5.0)
    }

    @Test("Applies display visibility hysteresis for notch and menu bar without jitter")
    func liveTPSVisibilityHysteresis() {
        var tracker = LiveTPSTracker(sparklineCapacity: 20, windowSeconds: 30.0)

        // 0.6 t/s -> below both enter thresholds (0.8 notch, 1.0 menu bar)
        let low = [
            OutputTokenSample(stepIndex: 1, timestamp: 90.0, outputTokens: 10),
            OutputTokenSample(stepIndex: 2, timestamp: 100.0, outputTokens: 6), // 0.6 t/s
        ]
        let sLow = tracker.update(busySessionIds: ["s1"], samplesBySession: ["s1": low], now: 101.0)
        #expect(abs(sLow.currentTPS - 0.6) < 1e-6)
        #expect(sLow.shouldShowInNotch == false)
        #expect(sLow.shouldShowInMenuBar == false)

        // 0.9 t/s -> enters notch (>= 0.8), stays hidden in menu bar (< 1.0)
        let mid = [
            OutputTokenSample(stepIndex: 1, timestamp: 90.0, outputTokens: 10),
            OutputTokenSample(stepIndex: 2, timestamp: 100.0, outputTokens: 9), // 0.9 t/s
        ]
        let sMid = tracker.update(busySessionIds: ["s1"], samplesBySession: ["s1": mid], now: 102.0)
        #expect(sMid.shouldShowInNotch == true)
        #expect(sMid.shouldShowInMenuBar == false)

        // 1.2 t/s -> enters menu bar (>= 1.0), notch stays true
        let high = [
            OutputTokenSample(stepIndex: 1, timestamp: 90.0, outputTokens: 10),
            OutputTokenSample(stepIndex: 2, timestamp: 100.0, outputTokens: 12), // 1.2 t/s
        ]
        let sHigh = tracker.update(busySessionIds: ["s1"], samplesBySession: ["s1": high], now: 103.0)
        #expect(sHigh.shouldShowInNotch == true)
        #expect(sHigh.shouldShowInMenuBar == true)

        // Decays to ~0.70 t/s (dt=8.4s -> 1.2 * pow(0.938083, 8.4) ~= 0.70): BOTH hold true!
        let sHoldBoth = tracker.update(busySessionIds: ["s1"], samplesBySession: [:], now: 111.4)
        #expect(sHoldBoth.currentTPS > 0.5 && sHoldBoth.currentTPS < 0.8)
        #expect(sHoldBoth.shouldShowInNotch == true)
        #expect(sHoldBoth.shouldShowInMenuBar == true)

        // Decays to ~0.42 t/s -> menu bar hides (< 0.5), notch holds (>= 0.35)!
        let sHoldNotchOnly = tracker.update(busySessionIds: ["s1"], samplesBySession: [:], now: 119.5)
        #expect(sHoldNotchOnly.currentTPS >= 0.35 && sHoldNotchOnly.currentTPS < 0.5)
        #expect(sHoldNotchOnly.shouldShowInNotch == true)
        #expect(sHoldNotchOnly.shouldShowInMenuBar == false)

        // Decays below 0.35 -> notch hides too
        let sHideAll = tracker.update(busySessionIds: ["s1"], samplesBySession: [:], now: 126.0)
        #expect(sHideAll.currentTPS < 0.35)
        #expect(sHideAll.shouldShowInNotch == false)
        #expect(sHideAll.shouldShowInMenuBar == false)
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

    @Test("Tracks activeSubagentCount via intersection of busySessionIds and subagentIds")
    func liveTPSActiveSubagentCount() {
        #expect(LiveTPSSnapshot.idle.activeSubagentCount == 0)

        var tracker = LiveTPSTracker()
        let parentSamples = [
            OutputTokenSample(stepIndex: 1, timestamp: 100.0, outputTokens: 100),
            OutputTokenSample(stepIndex: 2, timestamp: 105.0, outputTokens: 250), // 50 t/s
        ]
        let sub1Samples = [
            OutputTokenSample(stepIndex: 1, timestamp: 100.0, outputTokens: 100),
            OutputTokenSample(stepIndex: 2, timestamp: 105.0, outputTokens: 150), // 30 t/s
        ]
        let sub2Samples = [
            OutputTokenSample(stepIndex: 1, timestamp: 101.0, outputTokens: 200), // single sample
        ]

        // 1 parent + 2 active subagents + 1 inactive subagent ID in subagentIds
        let snap = tracker.update(
            busySessionIds: ["parent", "sub-1", "sub-2"],
            subagentIds: ["sub-1", "sub-2", "sub-idle"],
            samplesBySession: [
                "parent": parentSamples,
                "sub-1": sub1Samples,
                "sub-2": sub2Samples,
            ],
            now: 106.0
        )
        #expect(snap.isWorking == true)
        #expect(snap.activeSubagentCount == 2)
        #expect(snap.currentTPS > 80.0)

        // Idle reset clears activeSubagentCount back to 0
        let idle = tracker.update(
            busySessionIds: [],
            subagentIds: ["sub-1", "sub-2"],
            samplesBySession: [:],
            now: 110.0
        )
        #expect(idle == .idle)
        #expect(idle.activeSubagentCount == 0)
    }

    @Test("Computes accurate TPS for long 67s-150s subagent turns without Branch 3 spikes or drops")
    func liveTPSLongTurnSubagentBranch2() {
        var tracker = LiveTPSTracker(sparklineCapacity: 20, windowSeconds: 30.0)

        // 120s turn: step 1 at t=100, step 2 at t=220 with 6000 output tokens -> true rate = 50.0 t/s
        let longTurn120 = [
            OutputTokenSample(stepIndex: 1, timestamp: 100.0, outputTokens: 200),
            OutputTokenSample(stepIndex: 2, timestamp: 220.0, outputTokens: 6_000),
        ]
        let snap1 = tracker.update(
            busySessionIds: ["sub-long"],
            subagentIds: ["sub-long"],
            samplesBySession: ["sub-long": longTurn120],
            now: 222.0
        )
        #expect(snap1.activeSubagentCount == 1)
        #expect(abs(snap1.currentTPS - 50.0) < 1e-6)

        // Decays smoothly past 12s when no fresh output arrives
        let snapAged = tracker.update(
            busySessionIds: ["sub-long"],
            subagentIds: ["sub-long"],
            samplesBySession: ["sub-long": longTurn120],
            now: 234.0 // lastAge = 14s > 12s, dt = 12s -> 50 * pow(0.88, 6)
        )
        #expect(abs(snapAged.currentTPS - (50.0 * pow(0.88, 6.0))) < 1e-4)

        // Cold start on 150s turn (within 180s pairSpan, lastAge = 20s > 12s -> smooth cold-start age decay)
        var cold150 = LiveTPSTracker(sparklineCapacity: 20, windowSeconds: 30.0)
        let longTurn150 = [
            OutputTokenSample(stepIndex: 1, timestamp: 100.0, outputTokens: 300),
            OutputTokenSample(stepIndex: 2, timestamp: 250.0, outputTokens: 7_500), // raw = 50.0 t/s
        ]
        let snap150 = cold150.update(
            busySessionIds: ["sub-150"],
            subagentIds: ["sub-150"],
            samplesBySession: ["sub-150": longTurn150],
            now: 270.0 // lastAge = 20s -> extraAge = 8s -> 50 * pow(0.88, 4)
        )
        #expect(abs(snap150.currentTPS - (50.0 * pow(0.88, 4.0))) < 1e-4)

        // Pair span > 180s (idle gap of 250s before fresh step 2s ago) skips Branch 2 and uses Branch 3
        var gapTracker = LiveTPSTracker(sparklineCapacity: 20, windowSeconds: 30.0)
        let hugeGap = [
            OutputTokenSample(stepIndex: 1, timestamp: 100.0, outputTokens: 200),
            OutputTokenSample(stepIndex: 2, timestamp: 350.0, outputTokens: 400),
        ]
        let gapSnap = gapTracker.update(
            busySessionIds: ["sub-gap"],
            subagentIds: ["sub-gap"],
            samplesBySession: ["sub-gap": hugeGap],
            now: 352.0 // age = 2s -> Branch 3 denom = 4.0 -> 400 / 4.0 = 100.0 t/s
        )
        #expect(abs(gapSnap.currentTPS - 100.0) < 1e-6)
    }

    @Test("Handles 1-turn subagent single-sample estimation cleanly through 35s active window")
    func liveTPSSingleTurnSubagentWindow() {
        let singleSample = [
            OutputTokenSample(stepIndex: 1, timestamp: 500.0, outputTokens: 450),
        ]

        // Cold start at age = 32s (beyond 30s windowSeconds, within 35s active window)
        var cold32 = LiveTPSTracker(sparklineCapacity: 20, windowSeconds: 30.0)
        let snap32 = cold32.update(
            busySessionIds: ["img-gen"],
            subagentIds: ["img-gen"],
            samplesBySession: ["img-gen": singleSample],
            now: 532.0
        )
        #expect(snap32.activeSubagentCount == 1)
        // denom = 15.0, base = 30.0, extra = 20.0 -> 30 * pow(decayPerSecond, 10) = 30 * 0.88^5 ~= 15.832
        #expect(abs(snap32.currentTPS - (30.0 * pow(0.88, 5.0))) < 1e-4)

        // Exact 35s boundary still returns decayed positive rate
        var cold35 = LiveTPSTracker(sparklineCapacity: 20, windowSeconds: 30.0)
        let snap35 = cold35.update(
            busySessionIds: ["research"],
            subagentIds: ["research"],
            samplesBySession: ["research": singleSample],
            now: 535.0
        )
        #expect(snap35.currentTPS > 10.0 && snap35.currentTPS < snap32.currentTPS)

        // Warm transition from 35s -> 37s smoothly decays via Branch 4
        let snap37Warm = cold35.update(
            busySessionIds: ["research"],
            subagentIds: ["research"],
            samplesBySession: ["research": singleSample],
            now: 537.0
        )
        #expect(abs(snap37Warm.currentTPS - (snap35.currentTPS * 0.88)) < 1e-4)

        // Cold start past 35s (age = 36s) returns 0.0
        var cold36 = LiveTPSTracker(sparklineCapacity: 20, windowSeconds: 30.0)
        let snap36 = cold36.update(
            busySessionIds: ["stale-sub"],
            subagentIds: ["stale-sub"],
            samplesBySession: ["stale-sub": singleSample],
            now: 536.0
        )
        #expect(snap36.currentTPS == 0.0)
    }

    @Test("Infers step completion time and real duration for long 48s-276s subagent turns and trailing mtime")
    func transcriptInfersCompletionTimeAndDurationForLongTurns() throws {
        // 1. Long 125s tool-calling subagent turn (created_at = 03:24:30Z, completed when GENERIC step starts at 03:26:35Z)
        let longSubagentTranscript = """
        {"step_index":152,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-23T03:24:24Z","model":"claude-opus-4-6","output_tokens":10}
        {"step_index":154,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-23T03:24:30Z","model":"claude-opus-4-6","output_tokens":10828,"tool_calls":[{"name":"write_file"}]}
        {"step_index":155,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"2026-11-23T03:26:35Z","content":"ok"}
        """
        let summary1 = TranscriptParse.scan(text: longSubagentTranscript)
        let last1 = try #require(summary1.recentOutputSamples.last)
        let expectedEnd1 = try #require(AppDate.parseISO8601("2026-11-23T03:26:35Z")).timeIntervalSince1970
        #expect(last1.stepIndex == 154)
        #expect(abs(last1.timestamp - expectedEnd1) < 1e-6)
        #expect(abs((last1.durationSeconds ?? 0) - 125.0) < 1e-6)

        // Immediately after flush (now = completedAt + 2s), TPS must be exact 10828 / 125 = 86.624 t/s
        // (NOT 0.0 t/s from 127s-old created_at, and NOT 1200 t/s spike from previous step's 6s span!)
        var tracker1 = LiveTPSTracker()
        let snap1 = tracker1.update(
            busySessionIds: ["opus-qa"],
            subagentIds: ["opus-qa"],
            samplesBySession: ["opus-qa": summary1.recentOutputSamples],
            now: expectedEnd1 + 2.0
        )
        #expect(snap1.activeSubagentCount == 1)
        #expect(abs(snap1.currentTPS - (10_828.0 / 125.0)) < 1e-4)

        // 2. Ultra-long 276s turn (>180s pairSpan) with 35,673 tokens computes exact 129.25 t/s (no Branch 3 spike)
        let ultraLongSample = [
            OutputTokenSample(stepIndex: 204, timestamp: 1000.0, outputTokens: 200, durationSeconds: 10.0),
            OutputTokenSample(stepIndex: 290, timestamp: 1276.0, outputTokens: 35_673, durationSeconds: 276.0),
        ]
        var tracker2 = LiveTPSTracker()
        let snap2 = tracker2.update(
            busySessionIds: ["film-b-plates"],
            subagentIds: ["film-b-plates"],
            samplesBySession: ["film-b-plates": ultraLongSample],
            now: 1278.0
        )
        #expect(abs(snap2.currentTPS - (35_673.0 / 276.0)) < 1e-4)

        // 3. Trailing PLANNER_RESPONSE at EOF resolves completion time & duration from fileMtime (71s turn)
        let trailingStart = try #require(AppDate.parseISO8601("2026-11-23T03:31:41Z")).timeIntervalSince1970
        let trailingMtime = trailingStart + 71.0
        let trailingTranscript = """
        {"step_index":667,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-23T03:31:41Z","model":"gemini-4-neon-xhigh","output_tokens":5731}
        """
        let summary3 = TranscriptParse.scan(text: trailingTranscript, fileMtime: trailingMtime)
        let last3 = try #require(summary3.recentOutputSamples.last)
        #expect(abs(last3.timestamp - trailingMtime) < 1e-6)
        #expect(abs((last3.durationSeconds ?? 0) - 71.0) < 1e-6)

        var tracker3 = LiveTPSTracker()
        let snap3 = tracker3.update(
            busySessionIds: ["coord"],
            samplesBySession: ["coord": summary3.recentOutputSamples],
            now: trailingMtime + 1.0
        )
        #expect(abs(snap3.currentTPS - (5_731.0 / 71.0)) < 1e-4)

        // 4. Tool-less PLANNER_RESPONSE followed 20 minutes later by USER_INPUT must NOT adopt human reply time
        let idleGapTranscript = """
        {"step_index":10,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-23T03:00:00Z","model":"gemini-4-neon-high","output_tokens":300}
        {"step_index":11,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-11-23T03:20:00Z","content":"<USER_REQUEST>Next task</USER_REQUEST>"}
        """
        let summary4 = TranscriptParse.scan(text: idleGapTranscript)
        let s10 = try #require(summary4.recentOutputSamples.last)
        let expectedStart4 = try #require(AppDate.parseISO8601("2026-11-23T03:00:00Z")).timeIntervalSince1970
        #expect(abs(s10.timestamp - expectedStart4) < 1e-6)
        #expect(s10.durationSeconds == nil)
    }

    @Test("Covers Branch 1 explicitDur, Branch 2a warm decay past 12s, same-step streaming refresh, and >90s expiry")
    func liveTPSBranch1AndBranch2aEdgeCases() {
        // 1. Branch 1: inWindow.count == 2 with explicitDur > span uses max(span, explicitDur)
        let twoInWindowWithLongDur = [
            OutputTokenSample(stepIndex: 10, timestamp: 1000.0, outputTokens: 200),
            OutputTokenSample(stepIndex: 11, timestamp: 1005.0, outputTokens: 4000, durationSeconds: 40.0),
        ]
        var b1Tracker = LiveTPSTracker(sparklineCapacity: 20, windowSeconds: 30.0)
        let b1Snap = b1Tracker.update(
            busySessionIds: ["s1"],
            samplesBySession: ["s1": twoInWindowWithLongDur],
            now: 1007.0 // both samples inside [977, 1012], span=5s < explicitDur=40s -> 4000 / 40 = 100.0 t/s
        )
        #expect(abs(b1Snap.currentTPS - 100.0) < 1e-6)

        // Branch 1: when span > explicitDur, uses span
        let twoInWindowLongSpan = [
            OutputTokenSample(stepIndex: 10, timestamp: 1000.0, outputTokens: 200),
            OutputTokenSample(stepIndex: 11, timestamp: 1020.0, outputTokens: 1000, durationSeconds: 5.0),
        ]
        var b1SpanTracker = LiveTPSTracker(sparklineCapacity: 20, windowSeconds: 30.0)
        let b1SpanSnap = b1SpanTracker.update(
            busySessionIds: ["s1"],
            samplesBySession: ["s1": twoInWindowLongSpan],
            now: 1022.0 // span=20s > explicitDur=5s -> 1000 / 20 = 50.0 t/s
        )
        #expect(abs(b1SpanSnap.currentTPS - 50.0) < 1e-6)

        // 2. Branch 2a: warm decay past 12s (single sample with explicitDur, no fresh output)
        let singleExplicit = [
            OutputTokenSample(stepIndex: 5, timestamp: 2000.0, outputTokens: 1000, durationSeconds: 10.0),
        ]
        var b2aTracker = LiveTPSTracker(sparklineCapacity: 20, windowSeconds: 30.0)
        let warmInitial = b2aTracker.update(
            busySessionIds: ["sub"],
            subagentIds: ["sub"],
            samplesBySession: ["sub": singleExplicit],
            now: 2010.0 // lastAge=10s <= 12s -> 1000 / 10 = 100.0 t/s
        )
        #expect(abs(warmInitial.currentTPS - 100.0) < 1e-6)

        let warmDecay1 = b2aTracker.update(
            busySessionIds: ["sub"],
            subagentIds: ["sub"],
            samplesBySession: ["sub": singleExplicit],
            now: 2014.0 // lastAge=14s > 12s, dt=4s -> 100 * 0.88^2 = 77.44 t/s
        )
        #expect(abs(warmDecay1.currentTPS - (100.0 * pow(0.88, 2.0))) < 1e-4)

        // 3. Branch 2a: same-step streaming refresh (same stepIndex, outputTokens increased) even at lastAge > 12s
        let streamedUpdate = [
            OutputTokenSample(stepIndex: 5, timestamp: 2000.0, outputTokens: 1500, durationSeconds: 10.0),
        ]
        let streamSnap = b2aTracker.update(
            busySessionIds: ["sub"],
            subagentIds: ["sub"],
            samplesBySession: ["sub": streamedUpdate],
            now: 2016.0 // same stepIndex=5 with higher outputTokens=1500 -> refreshes to 150.0 t/s without age penalty
        )
        #expect(abs(streamSnap.currentTPS - 150.0) < 1e-6)

        // 4. Branch 2a: > 90s expiry
        // Cold start at age = 91s -> expires out of Branch 2a (and Branch 3 35s window) -> 0.0 t/s
        var coldExpired = LiveTPSTracker(sparklineCapacity: 20, windowSeconds: 30.0)
        let expiredColdSnap = coldExpired.update(
            busySessionIds: ["old-sub"],
            samplesBySession: ["old-sub": singleExplicit],
            now: 2091.0
        )
        #expect(expiredColdSnap.currentTPS == 0.0)

        // Warm tracker crossing from age = 89s to age = 91s smoothly decays via Branch 4
        var warmExpiry = LiveTPSTracker(sparklineCapacity: 20, windowSeconds: 30.0)
        let beforeExpiry = warmExpiry.update(
            busySessionIds: ["exp-sub"],
            samplesBySession: ["exp-sub": singleExplicit],
            now: 2089.0 // age = 89s <= 90s -> Branch 2a active (decayed for 77s past 12s threshold)
        )
        #expect(beforeExpiry.currentTPS > 0.5)
        let afterExpiry = warmExpiry.update(
            busySessionIds: ["exp-sub"],
            samplesBySession: ["exp-sub": singleExplicit],
            now: 2091.0 // age = 91s > 90s -> Branch 4 decays prevTPS by dt = 2s (0.88x)
        )
        #expect(abs(afterExpiry.currentTPS - (beforeExpiry.currentTPS * 0.88)) < 1e-4)
    }

    // MARK: - Multi-tool Transcript Turn Completion

    @Test("Extends multi-tool PLANNER_RESPONSE completion across consecutive GENERIC steps up to 1800s without overwriting on later non-GENERIC")
    func transcriptMultiToolCompletionAndExtendedMtimeCap() throws {
        // 1. 6-tool PLANNER_RESPONSE spanning 793s: must advance across all 6 GENERIC steps
        let t0 = try #require(AppDate.parseISO8601("2026-11-26T08:00:00Z")).timeIntervalSince1970
        let multiToolTranscript = """
        {"step_index":10,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-26T08:00:00Z","model":"gemini-4-carbon-high","output_tokens":39650,"tool_calls":[{"name":"update_steps"},{"name":"edit_file"},{"name":"edit_file"},{"name":"edit_file"},{"name":"edit_file"},{"name":"edit_file"}]}
        {"step_index":11,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"2026-11-26T08:00:12Z","content":"ok"}
        {"step_index":12,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"2026-11-26T08:02:00Z","content":"ok"}
        {"step_index":13,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"2026-11-26T08:05:30Z","content":"ok"}
        {"step_index":14,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"2026-11-26T08:09:10Z","content":"ok"}
        {"step_index":15,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"2026-11-26T08:11:45Z","content":"ok"}
        {"step_index":16,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"2026-11-26T08:13:13Z","content":"ok"}
        {"step_index":17,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"2026-11-26T08:15:00Z","content":"extra unrelated"}
        """
        let summary1 = TranscriptParse.scan(text: multiToolTranscript)
        let s10 = try #require(summary1.recentOutputSamples.first(where: { $0.stepIndex == 10 }))
        #expect(abs(s10.timestamp - (t0 + 793.0)) < 1e-6)
        #expect(abs((s10.durationSeconds ?? 0) - 793.0) < 1e-6)

        // Immediately after last tool finishes (now = t0 + 795s), TPS is exact 39650 / 793 = 50.0 t/s!
        var tracker = LiveTPSTracker()
        let snap = tracker.update(
            busySessionIds: ["multi"],
            samplesBySession: ["multi": summary1.recentOutputSamples],
            now: t0 + 795.0
        )
        #expect(abs(snap.currentTPS - 50.0) < 1e-4)

        // 2. Partial GENERICs (2 of 4 tools) followed by next PLANNER_RESPONSE:
        //    must keep 2nd GENERIC timestamp (t0 + 80s), NOT overwrite with later PLANNER_RESPONSE (t0 + 180s)!
        let partialGenericTranscript = """
        {"step_index":20,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-26T08:00:00Z","model":"gemini-4-neon-high","output_tokens":4000,"tool_calls":[{"name":"read_file"},{"name":"write_file"},{"name":"edit_file"},{"name":"run_command"}]}
        {"step_index":21,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"2026-11-26T08:00:15Z","content":"ok"}
        {"step_index":22,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"2026-11-26T08:01:20Z","content":"ok"}
        {"step_index":23,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-26T08:03:00Z","model":"gemini-4-neon-high","output_tokens":500}
        """
        let summary2 = TranscriptParse.scan(text: partialGenericTranscript)
        let s20 = try #require(summary2.recentOutputSamples.first(where: { $0.stepIndex == 20 }))
        #expect(abs(s20.timestamp - (t0 + 80.0)) < 1e-6)
        #expect(abs((s20.durationSeconds ?? 0) - 80.0) < 1e-6)

        // 3. Tool-calling turn with ZERO GENERIC steps followed by SYSTEM_MESSAGE adopts SYSTEM_MESSAGE timestamp
        let sysFollowupTranscript = """
        {"step_index":30,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-26T08:00:00Z","model":"claude-opus-4-6","output_tokens":2000,"tool_calls":[{"name":"run_command"}]}
        {"step_index":31,"source":"SYSTEM","type":"SYSTEM_MESSAGE","status":"DONE","created_at":"2026-11-26T08:00:40Z","content":"tool completed"}
        """
        let summary3 = TranscriptParse.scan(text: sysFollowupTranscript)
        let s30 = try #require(summary3.recentOutputSamples.first(where: { $0.stepIndex == 30 }))
        #expect(abs(s30.timestamp - (t0 + 40.0)) < 1e-6)
        #expect(abs((s30.durationSeconds ?? 0) - 40.0) < 1e-6)

        // 4. Trailing EOF fileMtime accepts up to 1800s (e.g. 900s) and rejects > 1800s
        let eofTranscript = """
        {"step_index":40,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-26T08:00:00Z","model":"gemini-4-carbon-high","output_tokens":45000}
        """
        let eof900 = TranscriptParse.scan(text: eofTranscript, fileMtime: t0 + 900.0)
        let s40a = try #require(eof900.recentOutputSamples.last)
        #expect(abs(s40a.timestamp - (t0 + 900.0)) < 1e-6)
        #expect(abs((s40a.durationSeconds ?? 0) - 900.0) < 1e-6)

        let eofTooOld = TranscriptParse.scan(text: eofTranscript, fileMtime: t0 + 1850.0)
        let s40b = try #require(eofTooOld.recentOutputSamples.last)
        #expect(abs(s40b.timestamp - t0) < 1e-6)
        #expect(s40b.durationSeconds == nil)
    }

    // MARK: - Protobuf Wire Test Helpers

    private static func encodeVarint(_ value: UInt64) -> Data {
        var v = value
        var out = Data()
        while true {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 {
                byte |= 0x80
                out.append(byte)
            } else {
                out.append(byte)
                break
            }
        }
        return out
    }

    private static func encodeTag(field: UInt64, wire: UInt64) -> Data {
        encodeVarint((field << 3) | wire)
    }

    private static func encodeLengthDelimited(field: UInt64, payload: Data) -> Data {
        var out = encodeTag(field: field, wire: 2)
        out.append(encodeVarint(UInt64(payload.count)))
        out.append(payload)
        return out
    }

    private static func encodeVarintField(field: UInt64, value: UInt64) -> Data {
        var out = encodeTag(field: field, wire: 0)
        out.append(encodeVarint(value))
        return out
    }

    private static func encodeTimestamp(seconds: Int64, nanos: Int32 = 0) -> Data {
        var msg = Data()
        msg.append(encodeVarintField(field: 1, value: UInt64(bitPattern: seconds)))
        if nanos != 0 {
            msg.append(encodeVarintField(field: 2, value: UInt64(bitPattern: Int64(nanos))))
        }
        return msg
    }

    private static func encodeTokenUsage(
        input: Int = 0,
        output: Int = 0,
        cacheRead: Int = 0,
        thinking: Int = 0,
        response: Int = 0
    ) -> Data {
        var msg = Data()
        if input > 0 { msg.append(encodeVarintField(field: 2, value: UInt64(input))) }
        if output > 0 { msg.append(encodeVarintField(field: 3, value: UInt64(output))) }
        if cacheRead > 0 { msg.append(encodeVarintField(field: 5, value: UInt64(cacheRead))) }
        if thinking > 0 { msg.append(encodeVarintField(field: 9, value: UInt64(thinking))) }
        if response > 0 { msg.append(encodeVarintField(field: 10, value: UInt64(response))) }
        return msg
    }

    private static func encodeMetadata(
        createdAt: (Int64, Int32)? = nil,
        streamStartedAt: (Int64, Int32)? = nil,
        completedAt: (Int64, Int32)? = nil,
        completedAtFallback: (Int64, Int32)? = nil,
        usage: Data? = nil,
        transitions: [(status: Int, ts: (Int64, Int32))] = []
    ) -> Data {
        var msg = Data()
        if let c = createdAt {
            msg.append(encodeLengthDelimited(field: 1, payload: encodeTimestamp(seconds: c.0, nanos: c.1)))
        }
        if let s = streamStartedAt {
            msg.append(encodeLengthDelimited(field: 6, payload: encodeTimestamp(seconds: s.0, nanos: s.1)))
        }
        if let done = completedAt {
            msg.append(encodeLengthDelimited(field: 7, payload: encodeTimestamp(seconds: done.0, nanos: done.1)))
        }
        if let fb = completedAtFallback {
            msg.append(encodeLengthDelimited(field: 8, payload: encodeTimestamp(seconds: fb.0, nanos: fb.1)))
        }
        if let u = usage {
            msg.append(encodeLengthDelimited(field: 9, payload: u))
        }
        if !transitions.isEmpty {
            var wrapper = Data()
            for tr in transitions {
                var item = Data()
                item.append(encodeVarintField(field: 1, value: UInt64(tr.status)))
                item.append(encodeLengthDelimited(field: 2, payload: encodeTimestamp(seconds: tr.ts.0, nanos: tr.ts.1)))
                wrapper.append(encodeLengthDelimited(field: 1, payload: item))
            }
            msg.append(encodeLengthDelimited(field: 26, payload: wrapper))
        }
        return msg
    }

    private static func encodePlannerStepPayload(
        thinkingBytes: Int = 0,
        responseBytes: Int = 0,
        ignoredIdBytes: Int = 0
    ) -> Data {
        var planner = Data()
        if thinkingBytes > 0 {
            planner.append(encodeLengthDelimited(field: 3, payload: Data(repeating: 0x61, count: thinkingBytes)))
        }
        if ignoredIdBytes > 0 {
            planner.append(encodeLengthDelimited(field: 6, payload: Data(repeating: 0x39, count: ignoredIdBytes)))
            planner.append(encodeLengthDelimited(field: 15, payload: Data(repeating: 0x38, count: ignoredIdBytes)))
        }
        if responseBytes > 0 {
            planner.append(encodeLengthDelimited(field: 7, payload: Data(repeating: 0x62, count: responseBytes)))
        }
        return encodeLengthDelimited(field: 20, payload: planner)
    }

    // MARK: - ConversationDBStepDecoder & Sample Merging

    @Test("Decodes DB protobuf completed steps with f6->f7 duration guard, f8/f26 fallbacks, status=8 streamedBytes, and malformed safety")
    func conversationDBStepDecoderCompleteMatrix() throws {
        let baseSec: Int64 = 1_795_000_000

        // Row 1: Normal TTFT + decode: out=593, d17=32.9s, d67=5.7s -> uses dStream = 5.7s (104.0 t/s)
        let meta1 = Self.encodeMetadata(
            createdAt: (baseSec, 0),
            streamStartedAt: (baseSec + 27, 200_000_000),
            completedAt: (baseSec + 32, 900_000_000),
            usage: Self.encodeTokenUsage(input: 5000, output: 593, cacheRead: 12000)
        )

        // Row 2: Buffered/late f6 real capture: out=19110, d17=265.2s, d67=0.184s -> falls back to dTotal = 265.2s!
        let meta2 = Self.encodeMetadata(
            createdAt: (baseSec + 100, 0),
            streamStartedAt: (baseSec + 365, 16_000_000),
            completedAt: (baseSec + 365, 200_000_000),
            usage: Self.encodeTokenUsage(output: 19_110)
        )

        // Row 3: Late f6 with dStream >= 1.0s BUT implausible rate (>450 t/s): out=10000, d17=120s, d67=2.0s -> falls back to dTotal = 120s!
        let meta3 = Self.encodeMetadata(
            createdAt: (baseSec + 500, 0),
            streamStartedAt: (baseSec + 618, 0),
            completedAt: (baseSec + 620, 0),
            usage: Self.encodeTokenUsage(output: 10_000)
        )

        // Row 4: f6 absent -> uses f26 transition (status=8) fallback, f7 absent -> uses f8 fallback, f3=0 -> uses f9+f10!
        let meta4 = Self.encodeMetadata(
            createdAt: (baseSec + 700, 0),
            completedAtFallback: (baseSec + 740, 0),
            usage: Self.encodeTokenUsage(thinking: 600, response: 200),
            transitions: [
                (status: 2, ts: (baseSec + 701, 0)),
                (status: 8, ts: (baseSec + 730, 0)),
            ]
        )

        // Row 5: Ultra-fast short reply: out=40, d17=0.6s, d67=0.4s -> clamps duration to 1.0s
        let meta5 = Self.encodeMetadata(
            createdAt: (baseSec + 800, 0),
            streamStartedAt: (baseSec + 800, 200_000_000),
            completedAt: (baseSec + 800, 600_000_000),
            usage: Self.encodeTokenUsage(output: 40)
        )

        // Row 6: Active GENERATING (status=8) step with streamedBytes in f20.(f3 + f7) ignoring f6/f15 IDs
        let metaGen = Self.encodeMetadata(
            createdAt: (baseSec + 900, 0),
            streamStartedAt: (baseSec + 904, 500_000_000)
        )
        let payloadGen = Self.encodePlannerStepPayload(thinkingBytes: 1200, responseBytes: 800, ignoredIdBytes: 500)

        // Pass in DESC order like SQL `ORDER BY idx DESC LIMIT 8`
        let rows = [
            ConversationDBStepRow(stepIndex: 6, status: 8, metadata: metaGen, stepPayload: payloadGen),
            ConversationDBStepRow(stepIndex: 5, status: 4, metadata: meta5),
            ConversationDBStepRow(stepIndex: 4, status: 4, metadata: meta4),
            ConversationDBStepRow(stepIndex: 3, status: 4, metadata: meta3),
            ConversationDBStepRow(stepIndex: 2, status: 4, metadata: meta2),
            ConversationDBStepRow(stepIndex: 1, status: 4, metadata: meta1),
        ]

        let telemetry = ConversationDBStepDecoder.decode(
            rows: rows,
            modelHint: "gemini-4-neon-high",
            lastObservedActivityAt: Double(baseSec + 910)
        )

        #expect(telemetry.completedSamples.count == 5)
        #expect(telemetry.completedSamples.map(\.stepIndex) == [1, 2, 3, 4, 5])

        let r1 = telemetry.completedSamples[0]
        #expect(r1.outputTokens == 593)
        #expect(abs((r1.durationSeconds ?? 0) - 5.7) < 1e-4)

        let r2 = telemetry.completedSamples[1]
        #expect(r2.outputTokens == 19_110)
        #expect(abs((r2.durationSeconds ?? 0) - 265.2) < 1e-4)

        let r3 = telemetry.completedSamples[2]
        #expect(r3.outputTokens == 10_000)
        #expect(abs((r3.durationSeconds ?? 0) - 120.0) < 1e-4)

        let r4 = telemetry.completedSamples[3]
        #expect(r4.outputTokens == 800)
        #expect(abs((r4.durationSeconds ?? 0) - 10.0) < 1e-4)

        let r5 = telemetry.completedSamples[4]
        #expect(r5.outputTokens == 40)
        #expect(abs((r5.durationSeconds ?? 0) - 1.0) < 1e-4)

        let gen = try #require(telemetry.activeGeneratingStep)
        #expect(gen.stepIndex == 6)
        #expect(abs(gen.startedAt - Double(baseSec + 900)) < 1e-6)
        #expect(abs((gen.streamStartedAt ?? 0) - (Double(baseSec + 904) + 0.5)) < 1e-6)
        #expect(gen.streamedBytes == 2000) // 1200 + 800, excludes 500+500 ignored IDs
        #expect(gen.modelHint == "gemini-4-neon-high")
        #expect(gen.lastObservedActivityAt == Double(baseSec + 910))

        // Corrupt/truncated/overflow protobuf blobs never crash
        let corruptRows = [
            ConversationDBStepRow(stepIndex: 1, status: 4, metadata: Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])),
            ConversationDBStepRow(stepIndex: 2, status: 4, metadata: Data([0x0A, 0x7F, 0x01, 0x02])), // length > remaining
            ConversationDBStepRow(stepIndex: 3, status: 8, metadata: Data([0x00, 0x07, 0x03]), stepPayload: Data([0xA2, 0x01, 0xFF, 0xFF, 0xFF, 0x0F])),
        ]
        let corruptTelemetry = ConversationDBStepDecoder.decode(rows: corruptRows)
        #expect(corruptTelemetry.completedSamples.isEmpty)
        #expect(corruptTelemetry.activeGeneratingStep == nil)
    }

    @Test("LiveTPSTracker.mergeSamples lets DB override matching stepIndex, preserves transcript-only steps, and caps to last 12")
    func liveTPSMergeSamples() {
        var transcript: [OutputTokenSample] = []
        for i in 1...14 {
            transcript.append(OutputTokenSample(stepIndex: i, timestamp: Double(1000 + i * 10), outputTokens: 100 * i, durationSeconds: 20.0))
        }
        let db = [
            OutputTokenSample(stepIndex: 10, timestamp: 1105.0, outputTokens: 1000, durationSeconds: 10.0), // overrides step 10
            OutputTokenSample(stepIndex: 15, timestamp: 1200.0, outputTokens: 2000, durationSeconds: 15.0), // brand new step 15
        ]
        let merged = LiveTPSTracker.mergeSamples(transcript: transcript, db: db)
        #expect(merged.count == 12)
        #expect(merged.map(\.stepIndex) == Array(4...15))
        let step10 = merged.first(where: { $0.stepIndex == 10 })
        #expect(step10?.durationSeconds == 10.0)
        #expect(step10?.timestamp == 1105.0)
        let step14 = merged.first(where: { $0.stepIndex == 14 })
        #expect(step14?.durationSeconds == 20.0)
        let step15 = merged.last
        #expect(step15?.stepIndex == 15)
        #expect(step15?.outputTokens == 2000)
    }

    // MARK: - Live In-Flight status==8 Generation & Branch 1 Explicit-Duration Fix

    @Test("Tracks live status==8 byte deltas, blends with session baseline, holds baseline during silent tool streaming, and enforces hung-stream guard")
    func liveTPSInFlightGeneratingAndHungGuard() {
        var tracker = LiveTPSTracker(sparklineCapacity: 20, windowSeconds: 30.0)

        // Session has 2 completed samples with baseline = (800 + 1200) / (10 + 15) = 80.0 t/s
        let completed = [
            OutputTokenSample(stepIndex: 1, timestamp: 900.0, outputTokens: 800, durationSeconds: 10.0),
            OutputTokenSample(stepIndex: 2, timestamp: 950.0, outputTokens: 1200, durationSeconds: 15.0),
        ]

        // Tick 1 (t=1000): status=8 starts streaming -> zero phase lag, immediately holds session baseline 80.0 t/s!
        let gen1 = LiveGeneratingStep(
            stepIndex: 3,
            startedAt: 996.0,
            streamStartedAt: 1000.0,
            streamedBytes: 0,
            modelHint: "gemini-4-carbon-high",
            lastObservedActivityAt: 1000.0
        )
        let s1 = tracker.update(
            busySessionIds: ["s1"],
            samplesBySession: ["s1": completed],
            generatingBySession: ["s1": gen1],
            now: 1000.0
        )
        #expect(abs(s1.currentTPS - 80.0) < 1e-6)

        // Tick 2 (t=1002): streamedBytes grew by 720 bytes in 2.0s -> byteRate = 720 / 3.6 / 2.0 = 100.0 t/s
        // Blended cleanly with baseline 80.0 -> 0.65 * 100 + 0.35 * 80 = 93.0 t/s
        let gen2 = LiveGeneratingStep(
            stepIndex: 3,
            startedAt: 996.0,
            streamStartedAt: 1000.0,
            streamedBytes: 720,
            modelHint: "gemini-4-carbon-high",
            lastObservedActivityAt: 1002.0
        )
        let s2 = tracker.update(
            busySessionIds: ["s1"],
            samplesBySession: ["s1": completed],
            generatingBySession: ["s1": gen2],
            now: 1002.0
        )
        #expect(abs(s2.currentTPS - 93.0) < 1e-6)

        // Tick 3 (t=1200, 200s later): silent 5-min write_file tool streaming (bytes plateaued at 720, DB still active)
        // Must NOT decay to 0 after 12s -> holds session's own decode baseline 80.0 t/s!
        let genPlateau = LiveGeneratingStep(
            stepIndex: 3,
            startedAt: 996.0,
            streamStartedAt: 1000.0,
            streamedBytes: 720,
            modelHint: "gemini-4-carbon-high",
            lastObservedActivityAt: 1190.0
        )
        let s3 = tracker.update(
            busySessionIds: ["s1"],
            samplesBySession: ["s1": completed],
            generatingBySession: ["s1": genPlateau],
            now: 1200.0
        )
        #expect(abs(s3.currentTPS - 80.0) < 1e-6)

        // Tick 4 (t=1650): hung-stream soft guard (streamElapsed=650s > 600s AND activityAge=460s > 300s) -> decays smoothly!
        let sHung = tracker.update(
            busySessionIds: ["s1"],
            samplesBySession: ["s1": completed],
            generatingBySession: ["s1": genPlateau],
            now: 1650.0
        )
        #expect(sHung.currentTPS < 80.0)

        // Cold start on hard-limit hung stream (streamElapsed = 1900s > 1800s) -> returns 0.0
        var coldHungTracker = LiveTPSTracker()
        let genVeryHung = LiveGeneratingStep(
            stepIndex: 1,
            startedAt: 100.0,
            streamStartedAt: 100.0,
            streamedBytes: 500,
            modelHint: "gemini-4-neon-high",
            lastObservedActivityAt: 1995.0
        )
        let sColdHung = coldHungTracker.update(
            busySessionIds: ["hung"],
            samplesBySession: [:],
            generatingBySession: ["hung": genVeryHung],
            now: 2000.0
        )
        #expect(sColdHung.currentTPS == 0.0)

        // 1st turn with zero completed samples: cumulative byte rate <= 45s, then model-family decode prior
        var firstTurnTracker = LiveTPSTracker()
        let firstGenCum = LiveGeneratingStep(
            stepIndex: 1,
            startedAt: 100.0,
            streamStartedAt: 100.0,
            streamedBytes: 1800, // 1800 / 3.6 / 10s = 50.0 t/s
            modelHint: "gemini-4-neon-high",
            lastObservedActivityAt: 110.0
        )
        let f1 = firstTurnTracker.update(
            busySessionIds: ["first"],
            samplesBySession: [:],
            generatingBySession: ["first": firstGenCum],
            now: 110.0
        )
        #expect(abs(f1.currentTPS - 50.0) < 1e-6)

        // Past 45s with plateaued bytes on 1st turn -> model-family decode prior (neon = 95.0 t/s)
        let f2 = firstTurnTracker.update(
            busySessionIds: ["first"],
            samplesBySession: [:],
            generatingBySession: ["first": firstGenCum],
            now: 150.0
        )
        #expect(abs(f2.currentTPS - 95.0) < 1e-6)

        // Model prior lookup via modelHintBySession when gen.modelHint == nil
        var priorTracker = LiveTPSTracker()
        let silentGen = LiveGeneratingStep(stepIndex: 1, startedAt: 200.0, streamStartedAt: 200.0, streamedBytes: 0)
        let pSnap = priorTracker.update(
            busySessionIds: ["h", "c", "o"],
            samplesBySession: [:],
            generatingBySession: ["h": silentGen, "c": silentGen, "o": silentGen],
            modelHintBySession: [
                "h": "gemini-4-hydrogen-tiered-high",
                "c": "claude-opus-4-6",
                "o": "unknown-model",
            ],
            now: 202.0
        )
        #expect(abs((pSnap.perSessionTPS["h"] ?? 0) - 90.0) < 1e-6)
        #expect(abs((pSnap.perSessionTPS["c"] ?? 0) - 65.0) < 1e-6)
        #expect(abs((pSnap.perSessionTPS["o"] ?? 0) - 55.0) < 1e-6)
        #expect(abs(pSnap.currentTPS - 210.0) < 1e-6)

        // When status == 8 ends, immediately switches to completed sample / decay mode, and idle resets to 0
        let finishedSamples = [
            OutputTokenSample(stepIndex: 1, timestamp: 210.0, outputTokens: 1000, durationSeconds: 10.0),
        ]
        let afterDone = priorTracker.update(
            busySessionIds: ["h"],
            samplesBySession: ["h": finishedSamples],
            generatingBySession: [:],
            now: 211.0
        )
        #expect(abs(afterDone.currentTPS - 100.0) < 1e-6)

        let afterIdle = priorTracker.update(
            busySessionIds: [],
            samplesBySession: ["h": finishedSamples],
            generatingBySession: [:],
            now: 212.0
        )
        #expect(afterIdle == .idle)
    }

    @Test("Branch 1 uses sum(outputTokens)/sum(durationSeconds) when all in-window samples have explicit durationSeconds, eliminating tool-gap pollution")
    func liveTPSBranch1ExplicitDurationNoToolGapPollution() {
        var tracker = LiveTPSTracker(sparklineCapacity: 20, windowSeconds: 30.0)

        // Two fast 100 t/s turns separated by a 15s tool-execution gap inside the 30s window:
        // Step 1: 500 tok / 5s at t=100; Step 2: 500 tok / 5s at t=120 (wall span=20s, true decode=10s)
        let samples = [
            OutputTokenSample(stepIndex: 1, timestamp: 100.0, outputTokens: 500, durationSeconds: 5.0),
            OutputTokenSample(stepIndex: 2, timestamp: 120.0, outputTokens: 500, durationSeconds: 5.0),
        ]
        let snap = tracker.update(
            busySessionIds: ["tool-heavy"],
            samplesBySession: ["tool-heavy": samples],
            now: 122.0
        )
        // Must be (500 + 500) / (5 + 5) = 100.0 t/s, NOT polluted 500 / 20 = 25.0 t/s!
        #expect(abs(snap.currentTPS - 100.0) < 1e-6)
    }

    @Test("Holds live byte rate cleanly across rapid 0.5s FSEvents polls between 2s WAL flushes without spikes, then transitions to baseline after >6s plateau")
    func liveTPSFSEventsPollingBetweenWALFlushesAndPlateauTransition() {
        var tracker = LiveTPSTracker(sparklineCapacity: 20, windowSeconds: 30.0)
        let completed = [
            OutputTokenSample(stepIndex: 1, timestamp: 950.0, outputTokens: 800, durationSeconds: 10.0), // baseline = 80 t/s
        ]

        func gen(bytes: Int, activityAt: Double) -> LiveGeneratingStep {
            LiveGeneratingStep(
                stepIndex: 2,
                startedAt: 998.0,
                streamStartedAt: 1000.0,
                streamedBytes: bytes,
                modelHint: "gemini-4-carbon-high",
                lastObservedActivityAt: activityAt
            )
        }

        // t=1000.0: initial observation (0 bytes) -> baseline 80.0
        let t0 = tracker.update(
            busySessionIds: ["s1"],
            samplesBySession: ["s1": completed],
            generatingBySession: ["s1": gen(bytes: 0, activityAt: 1000.0)],
            now: 1000.0
        )
        #expect(abs(t0.currentTPS - 80.0) < 1e-6)

        // t=1002.0: first 2.0s WAL flush (+720 bytes -> 100 t/s byte rate -> blended 0.65*100 + 0.35*80 = 93.0)
        let t2 = tracker.update(
            busySessionIds: ["s1"],
            samplesBySession: ["s1": completed],
            generatingBySession: ["s1": gen(bytes: 720, activityAt: 1002.0)],
            now: 1002.0
        )
        #expect(abs(t2.currentTPS - 93.0) < 1e-6)

        // Rapid 0.5s FSEvents polls with unchanged bytes before next WAL flush at t=1004.0:
        // Must hold 93.0 smoothly (no sawtooth flicker) and NOT advance anchor timestamp!
        for pollTime in [1002.5, 1003.0, 1003.5] {
            let mid = tracker.update(
                busySessionIds: ["s1"],
                samplesBySession: ["s1": completed],
                generatingBySession: ["s1": gen(bytes: 720, activityAt: 1002.0)],
                now: pollTime
            )
            #expect(abs(mid.currentTPS - 93.0) < 1e-6)
        }

        // t=1004.0: next 2.0s WAL flush (+720 bytes = 1440 total):
        // Must divide by full 2.0s flush span (100 t/s -> 93.0 blended), NOT 0.5s (which would spike to 400 t/s)!
        let t4 = tracker.update(
            busySessionIds: ["s1"],
            samplesBySession: ["s1": completed],
            generatingBySession: ["s1": gen(bytes: 1440, activityAt: 1004.0)],
            now: 1004.0
        )
        #expect(abs(t4.currentTPS - 93.0) < 1e-6)

        // t=1010.5 (dt = 6.5s > 6.0s plateau grace): genuine silent tool-call plateau -> transitions cleanly to sessionBaseline 80.0
        let tPlateau = tracker.update(
            busySessionIds: ["s1"],
            samplesBySession: ["s1": completed],
            generatingBySession: ["s1": gen(bytes: 1440, activityAt: 1010.0)],
            now: 1010.5
        )
        #expect(abs(tPlateau.currentTPS - 80.0) < 1e-6)
    }

    @Test("Guards malformed protobuf TokenUsage overflow (f9=Int.max, f10=1), invalid wire types inside Timestamp, and large multi-sample token sums")
    func conversationDBDecoderOverflowAndCorruptTimestampSafety() {
        let baseSec: Int64 = 1_795_000_000

        // 1. TokenUsage with f3=0, f9=Int.max, f10=1 must saturate cleanly without integer overflow trap
        var overflowUsage = Data()
        overflowUsage.append(Self.encodeVarintField(field: 9, value: UInt64(Int.max)))
        overflowUsage.append(Self.encodeVarintField(field: 10, value: 1))
        let overflowMeta = Self.encodeMetadata(
            createdAt: (baseSec, 0),
            completedAt: (baseSec + 10, 0),
            usage: overflowUsage
        )
        let decodedOverflow = ConversationDBStepDecoder.decode(rows: [
            ConversationDBStepRow(stepIndex: 1, status: 4, metadata: overflowMeta),
        ])
        #expect(decodedOverflow.completedSamples.count == 1)
        #expect(decodedOverflow.completedSamples[0].outputTokens == Int.max)

        // Multi-sample accumulation in LiveTPSTracker with Int.max tokens must not trap either
        var tracker = LiveTPSTracker()
        let hugeSamples = [
            OutputTokenSample(stepIndex: 1, timestamp: 100.0, outputTokens: Int.max, durationSeconds: 10.0),
            OutputTokenSample(stepIndex: 2, timestamp: 110.0, outputTokens: Int.max, durationSeconds: 10.0),
        ]
        let hugeSnap = tracker.update(
            busySessionIds: ["huge"],
            samplesBySession: ["huge": hugeSamples],
            now: 112.0
        )
        #expect(hugeSnap.currentTPS == 1200.0)

        // 2. Timestamp containing an invalid wire type (wireType 6) must reject and return nil instead of looping/misparsing
        var corruptTs = Data()
        corruptTs.append(Self.encodeTag(field: 3, wire: 6)) // invalid wire type 6
        corruptTs.append(Self.encodeVarintField(field: 1, value: UInt64(baseSec))) // trailing bytes must NOT be misparsed
        let corruptTsMeta = Self.encodeLengthDelimited(field: 1, payload: corruptTs)
            + Self.encodeLengthDelimited(field: 7, payload: corruptTs)
            + Self.encodeLengthDelimited(field: 9, payload: Self.encodeTokenUsage(output: 500))
        let decodedCorruptTs = ConversationDBStepDecoder.decode(rows: [
            ConversationDBStepRow(stepIndex: 1, status: 4, metadata: corruptTsMeta),
        ])
        #expect(decodedCorruptTs.completedSamples.isEmpty)
    }
}
