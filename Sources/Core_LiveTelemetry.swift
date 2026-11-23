import Foundation

// MARK: - Live Session Telemetry (Context Window & Output TPS) — pure core
//
// Foundation-only (part of AGYCore):
//   - ContextWindowCatalog: maps raw model IDs to context window limits
//   - SessionContextSnapshot: per-session remaining context & pressure level
//   - OutputTokenSample: per-step timestamped output token observation
//   - LiveTPSSnapshot / LiveTPSTracker: deterministic multi-session Output TPS
//     aggregator with smooth busy-step exponential decay and zero-CPU idle reset.
//
// Zero AppKit, SwiftUI, CoreGraphics, Combine, SQLite3, Process, or FileManager.

public enum ContextPressureLevel: String, Codable, Equatable, Sendable {
    case nominal
    case warning
    case critical
}

public enum ContextWindowCatalog {
    /// Context window capacity (in tokens) for a raw Antigravity / partner model ID.
    public static func windowTokens(for rawModel: String) -> Int {
        let lower = rawModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty {
            return 128_000
        }
        if lower.contains("claude")
            || lower.contains("opus")
            || lower.contains("sonnet")
            || lower.contains("haiku") {
            return lower.contains("1m") ? 1_000_000 : 200_000
        }
        if lower.contains("carbon")
            || lower.contains("argon")
            || lower.contains("neon")
            || lower.contains("hydrogen")
            || lower.contains("flash")
            || lower.contains("gemini")
            || lower.contains("orchestrator") {
            return 1_000_000
        }
        return 128_000
    }
}

public struct SessionContextSnapshot: Equatable, Sendable {
    public let modelId: String
    public let modelClass: ModelClass
    public let usedTokens: Int
    public let windowTokens: Int
    public let cacheHitRatio: Double?

    public var remainingTokens: Int {
        max(0, windowTokens - usedTokens)
    }

    public var remainingRatio: Double {
        min(1.0, max(0.0, Double(remainingTokens) / Double(max(1, windowTokens))))
    }

    public var remainingPercent: Int {
        min(100, max(0, Int((remainingRatio * 100.0).rounded())))
    }

    public var pressureLevel: ContextPressureLevel {
        if remainingRatio < 0.10 {
            return .critical
        }
        if remainingRatio < 0.25 {
            return .warning
        }
        return .nominal
    }

    public var needsCompactHint: Bool {
        pressureLevel == .critical
    }

    public init(
        modelId: String,
        modelClass: ModelClass,
        usedTokens: Int,
        windowTokens: Int,
        cacheHitRatio: Double? = nil
    ) {
        self.modelId = modelId
        self.modelClass = modelClass
        self.usedTokens = max(0, usedTokens)
        self.windowTokens = max(1, windowTokens)
        if let ratio = cacheHitRatio, ratio.isFinite {
            self.cacheHitRatio = min(1.0, max(0.0, ratio))
        } else {
            self.cacheHitRatio = nil
        }
    }

    public static func make(
        model: String,
        usedTokens: Int,
        cacheHitRatio: Double? = nil
    ) -> SessionContextSnapshot {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return SessionContextSnapshot(
            modelId: trimmed,
            modelClass: ModelClass.classify(trimmed),
            usedTokens: usedTokens,
            windowTokens: ContextWindowCatalog.windowTokens(for: trimmed),
            cacheHitRatio: cacheHitRatio
        )
    }
}

public struct OutputTokenSample: Equatable, Sendable {
    public let stepIndex: Int
    /// Effective observation timestamp (epoch seconds UTC): step completion time when
    /// inferred from a subsequent step or transcript file mtime, falling back to `created_at`.
    public let timestamp: Double
    public let outputTokens: Int
    /// Explicit step generation duration (`completedAt - createdAt`) when known from
    /// `PLANNER_RESPONSE` start -> completion bounds. Nil for legacy/synthetic samples.
    public let durationSeconds: Double?

    public init(
        stepIndex: Int,
        timestamp: Double,
        outputTokens: Int,
        durationSeconds: Double? = nil
    ) {
        self.stepIndex = stepIndex
        self.timestamp = timestamp
        self.outputTokens = max(0, outputTokens)
        if let d = durationSeconds, d.isFinite, d > 0 {
            self.durationSeconds = d
        } else {
            self.durationSeconds = nil
        }
    }
}

public struct LiveTPSSnapshot: Equatable, Sendable {
    public let currentTPS: Double
    public let peakTPS: Double
    public let perSessionTPS: [String: Double]
    public let sparkline: [Double]
    public let isWorking: Bool
    public let shouldShowInNotch: Bool
    public let shouldShowInMenuBar: Bool
    public let activeSubagentCount: Int

    public static let idle = LiveTPSSnapshot(
        currentTPS: 0,
        peakTPS: 0,
        perSessionTPS: [:],
        sparkline: [],
        isWorking: false,
        shouldShowInNotch: false,
        shouldShowInMenuBar: false,
        activeSubagentCount: 0
    )

    public init(
        currentTPS: Double,
        peakTPS: Double,
        perSessionTPS: [String: Double],
        sparkline: [Double],
        isWorking: Bool,
        shouldShowInNotch: Bool? = nil,
        shouldShowInMenuBar: Bool? = nil,
        activeSubagentCount: Int = 0
    ) {
        self.currentTPS = currentTPS
        self.peakTPS = peakTPS
        self.perSessionTPS = perSessionTPS
        self.sparkline = sparkline
        self.isWorking = isWorking
        self.shouldShowInNotch = shouldShowInNotch ?? (isWorking && currentTPS >= LiveTPSTracker.notchShowThreshold)
        self.shouldShowInMenuBar = shouldShowInMenuBar ?? (isWorking && currentTPS >= LiveTPSTracker.menuBarShowThreshold)
        self.activeSubagentCount = max(0, activeSubagentCount)
    }
}

public struct LiveTPSTracker: Equatable, Sendable {
    private struct SeenStepSignature: Equatable, Sendable {
        let stepIndex: Int
        let outputTokens: Int
    }

    public let sparklineCapacity: Int
    public let windowSeconds: Double

    /// Wall-clock per-second exponential decay factor calibrated so a 2.0s interval decays by 0.88x.
    public static let decayPerSecond: Double = pow(0.88, 0.5)
    /// Minimum wall-clock spacing between sparkline ring-buffer appends (shorter bursts update last point in place).
    public static let sparklineMinAppendInterval: Double = 1.5

    /// Canonical display visibility hysteresis thresholds shared by NotchView and AppDelegate.
    public static let notchShowThreshold: Double = 0.8
    public static let notchHideThreshold: Double = 0.35
    public static let menuBarShowThreshold: Double = 1.0
    public static let menuBarHideThreshold: Double = 0.5

    private var sparkline: [Double] = []
    private var lastSparklineAppendAt: Double? = nil
    private var lastKnownSessionTPS: [String: Double] = [:]
    private var lastSeenStepBySession: [String: SeenStepSignature] = [:]
    private var lastUpdateAtBySession: [String: Double] = [:]
    private var isShowingInNotch: Bool = false
    private var isShowingInMenuBar: Bool = false

    private static let maxSaneSessionTPS: Double = 1200.0
    private static let futureSkewAllowance: Double = 5.0
    private static let consecutiveFallbackMaxAge: Double = 90.0
    private static let consecutiveFallbackMaxPairSpan: Double = 180.0
    private static let singleSampleMaxAge: Double = 35.0
    private static let singleSampleDecayThreshold: Double = 12.0
    private static let decayFloor: Double = 0.25

    public init(sparklineCapacity: Int = 20, windowSeconds: Double = 30.0) {
        self.sparklineCapacity = max(1, sparklineCapacity)
        self.windowSeconds = max(1.0, windowSeconds)
    }

    public mutating func update(
        busySessionIds: Set<String>,
        subagentIds: Set<String> = [],
        samplesBySession: [String: [OutputTokenSample]],
        now: Double
    ) -> LiveTPSSnapshot {
        guard !busySessionIds.isEmpty else {
            sparkline.removeAll(keepingCapacity: false)
            lastSparklineAppendAt = nil
            lastKnownSessionTPS.removeAll(keepingCapacity: false)
            lastSeenStepBySession.removeAll(keepingCapacity: false)
            lastUpdateAtBySession.removeAll(keepingCapacity: false)
            isShowingInNotch = false
            isShowingInMenuBar = false
            return .idle
        }

        // Prune sessions that are no longer busy.
        lastKnownSessionTPS = lastKnownSessionTPS.filter { busySessionIds.contains($0.key) }
        lastSeenStepBySession = lastSeenStepBySession.filter { busySessionIds.contains($0.key) }
        lastUpdateAtBySession = lastUpdateAtBySession.filter { busySessionIds.contains($0.key) }

        var perSession: [String: Double] = [:]
        perSession.reserveCapacity(busySessionIds.count)

        for sid in busySessionIds.sorted() {
            let rawSamples = samplesBySession[sid] ?? []
            let valid = rawSamples
                .filter { $0.outputTokens > 0 && $0.timestamp.isFinite }
                .sorted { a, b in
                    if a.stepIndex != b.stepIndex { return a.stepIndex < b.stepIndex }
                    return a.timestamp < b.timestamp
                }

            let dtSinceLastUpdate: Double
            if now.isFinite, let prevAt = lastUpdateAtBySession[sid] {
                dtSinceLastUpdate = max(0.0, now - prevAt)
            } else {
                dtSinceLastUpdate = 0.0
            }

            let tps = computeSessionTPS(
                sessionId: sid,
                sortedSamples: valid,
                now: now,
                dtSinceLastUpdate: dtSinceLastUpdate
            )
            perSession[sid] = tps
            lastKnownSessionTPS[sid] = tps
            if now.isFinite {
                lastUpdateAtBySession[sid] = now
            }
        }

        let currentTPS = perSession.values.reduce(0.0, +)
        if sparkline.isEmpty {
            sparkline.append(currentTPS)
            lastSparklineAppendAt = now.isFinite ? now : nil
        } else if now.isFinite,
                  let lastAppend = lastSparklineAppendAt,
                  (now - lastAppend) < Self.sparklineMinAppendInterval {
            sparkline[sparkline.count - 1] = currentTPS
        } else {
            sparkline.append(currentTPS)
            lastSparklineAppendAt = now.isFinite ? now : lastSparklineAppendAt
            if sparkline.count > sparklineCapacity {
                sparkline.removeFirst(sparkline.count - sparklineCapacity)
            }
        }
        let peakTPS = max(sparkline.max() ?? 0.0, currentTPS)

        // Hysteresis visibility predicates (busySessionIds is non-empty here).
        if isShowingInNotch {
            isShowingInNotch = currentTPS >= Self.notchHideThreshold
        } else {
            isShowingInNotch = currentTPS >= Self.notchShowThreshold
        }

        if isShowingInMenuBar {
            isShowingInMenuBar = currentTPS >= Self.menuBarHideThreshold
        } else {
            isShowingInMenuBar = currentTPS >= Self.menuBarShowThreshold
        }

        let activeSubagentCount = busySessionIds.intersection(subagentIds).count

        return LiveTPSSnapshot(
            currentTPS: currentTPS,
            peakTPS: peakTPS,
            perSessionTPS: perSession,
            sparkline: sparkline,
            isWorking: true,
            shouldShowInNotch: isShowingInNotch,
            shouldShowInMenuBar: isShowingInMenuBar,
            activeSubagentCount: activeSubagentCount
        )
    }

    private mutating func computeSessionTPS(
        sessionId: String,
        sortedSamples: [OutputTokenSample],
        now: Double,
        dtSinceLastUpdate: Double
    ) -> Double {
        let prevTPS = lastKnownSessionTPS[sessionId]
        let prevStep = lastSeenStepBySession[sessionId]
        let windowStart = now - windowSeconds
        let windowEnd = now + Self.futureSkewAllowance

        let inWindow = sortedSamples.filter {
            $0.timestamp >= windowStart && $0.timestamp <= windowEnd
        }

        let latestValid = sortedSamples.last(where: { $0.timestamp <= windowEnd })
        let hasFreshOutput: Bool = {
            guard let latest = latestValid else { return false }
            guard let seen = prevStep else { return true }
            return latest.stepIndex > seen.stepIndex
                || (latest.stepIndex == seen.stepIndex && latest.outputTokens > seen.outputTokens)
        }()

        // 1. >= 2 samples inside active window
        if inWindow.count >= 2, let earliest = inWindow.first, let latest = inWindow.last {
            let age = max(0.0, now - latest.timestamp)
            if !hasFreshOutput, let prev = prevTPS, age > Self.singleSampleDecayThreshold {
                return decayed(prev, dt: dtSinceLastUpdate)
            }
            let tokensAfterEarliest = inWindow.dropFirst().reduce(0) { $0 + $1.outputTokens }
            let span = latest.timestamp - earliest.timestamp
            let effectiveSpan: Double
            if inWindow.count == 2, let explicitDur = latest.durationSeconds {
                effectiveSpan = max(span, explicitDur)
            } else {
                effectiveSpan = span
            }
            let dt = max(1.0, effectiveSpan)
            var rate = clampSessionTPS(Double(tokensAfterEarliest) / dt)
            if prevTPS == nil, age > Self.singleSampleDecayThreshold {
                let extraAge = age - Self.singleSampleDecayThreshold
                rate *= pow(Self.decayPerSecond, extraAge)
            }
            lastSeenStepBySession[sessionId] = SeenStepSignature(
                stepIndex: latest.stepIndex,
                outputTokens: latest.outputTokens
            )
            return rate < Self.decayFloor ? 0.0 : rate
        }

        // 2a. Explicit step generation duration on latest sample (accurate for long 45s-300s
        //     subagent turns and 1-turn subagents without dividing by the previous step's span
        //     or hitting single-sample spikes).
        let recentUpToNow = sortedSamples.filter { $0.timestamp <= windowEnd }
        if let last = recentUpToNow.last, let explicitDur = last.durationSeconds {
            let lastAge = max(0.0, now - last.timestamp)
            if lastAge <= Self.consecutiveFallbackMaxAge {
                if !hasFreshOutput, let prev = prevTPS,
                   inWindow.isEmpty || lastAge > Self.singleSampleDecayThreshold {
                    return decayed(prev, dt: dtSinceLastUpdate)
                }
                let dt = max(1.0, explicitDur)
                var rate = clampSessionTPS(Double(last.outputTokens) / dt)
                let isSameStepStreaming: Bool = {
                    guard let seen = prevStep else { return false }
                    return last.stepIndex == seen.stepIndex && last.outputTokens > seen.outputTokens
                }()
                if (prevTPS == nil || !isSameStepStreaming), lastAge > Self.singleSampleDecayThreshold {
                    let extraAge = lastAge - Self.singleSampleDecayThreshold
                    rate *= pow(Self.decayPerSecond, extraAge)
                }
                lastSeenStepBySession[sessionId] = SeenStepSignature(
                    stepIndex: last.stepIndex,
                    outputTokens: last.outputTokens
                )
                return rate < Self.decayFloor ? 0.0 : rate
            }
        }

        // 2b. Fallback to last 2 consecutive samples if latest is within 90s of `now`
        //     and the step-to-step span is within 180s (covers legacy samples without durationSeconds).
        if recentUpToNow.count >= 2 {
            let secondLast = recentUpToNow[recentUpToNow.count - 2]
            let last = recentUpToNow[recentUpToNow.count - 1]
            let lastAge = max(0.0, now - last.timestamp)
            let pairSpan = last.timestamp - secondLast.timestamp
            if lastAge <= Self.consecutiveFallbackMaxAge
                && pairSpan >= 0
                && pairSpan <= Self.consecutiveFallbackMaxPairSpan {
                // If we already observed this exact latest step & token count and it has fallen out of
                // the primary window (or aged past singleSampleDecayThreshold), smoothly decay
                // instead of holding a flat stale plateau.
                if !hasFreshOutput, let prev = prevTPS,
                   inWindow.isEmpty || lastAge > Self.singleSampleDecayThreshold {
                    return decayed(prev, dt: dtSinceLastUpdate)
                }
                let dt = max(1.0, pairSpan)
                var rate = clampSessionTPS(Double(last.outputTokens) / dt)
                let isSameStepStreaming: Bool = {
                    guard let seen = prevStep else { return false }
                    return last.stepIndex == seen.stepIndex && last.outputTokens > seen.outputTokens
                }()
                if (prevTPS == nil || !isSameStepStreaming), lastAge > Self.singleSampleDecayThreshold {
                    let extraAge = lastAge - Self.singleSampleDecayThreshold
                    rate *= pow(Self.decayPerSecond, extraAge)
                }
                lastSeenStepBySession[sessionId] = SeenStepSignature(
                    stepIndex: last.stepIndex,
                    outputTokens: last.outputTokens
                )
                return rate < Self.decayFloor ? 0.0 : rate
            }
        }

        // 3. Single recent sample within active window (up to max(windowSeconds, 35s) for 1-turn subagents)
        let singleSampleWindow = max(windowSeconds, Self.singleSampleMaxAge)
        if let sample = inWindow.last ?? recentUpToNow.last,
           max(0.0, now - sample.timestamp) <= singleSampleWindow {
            let age = max(0.0, now - sample.timestamp)
            let denom = max(2.0, min(15.0, age + 2.0))
            var rate = Double(sample.outputTokens) / denom
            if age > Self.singleSampleDecayThreshold {
                let extra = age - Self.singleSampleDecayThreshold
                rate *= pow(Self.decayPerSecond, extra * 0.5)
            }
            lastSeenStepBySession[sessionId] = SeenStepSignature(
                stepIndex: sample.stepIndex,
                outputTokens: sample.outputTokens
            )
            let clamped = clampSessionTPS(rate)
            return clamped < Self.decayFloor ? 0.0 : clamped
        }

        // 4. Busy session generating next step with no fresh sample -> wall-clock exponential decay
        if let prev = prevTPS, prev > 0 {
            return decayed(prev, dt: dtSinceLastUpdate)
        }

        return 0.0
    }

    private func clampSessionTPS(_ value: Double) -> Double {
        guard value.isFinite else { return 0.0 }
        return min(Self.maxSaneSessionTPS, max(0.0, value))
    }

    private func decayed(_ prev: Double, dt: Double) -> Double {
        guard prev.isFinite, prev > 0 else { return 0.0 }
        let safeDt = dt.isFinite ? max(0.0, dt) : 0.0
        let next = prev * pow(Self.decayPerSecond, safeDt)
        return next < Self.decayFloor ? 0.0 : next
    }

    /// Compact human-readable throughput badge (e.g. `"--"`, `"84 t/s"`, `"1.2k/s"`).
    public static func formatCompactTPS(_ tps: Double) -> String {
        guard tps.isFinite, tps >= 0.5 else { return "--" }
        if tps < 999.5 {
            return "\(Int(tps.rounded())) t/s"
        }
        return String(format: "%.1fk/s", locale: Locale(identifier: "en_US_POSIX"), tps / 1000.0)
    }
}
