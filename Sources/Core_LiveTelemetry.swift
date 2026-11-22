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
    /// Epoch seconds (UTC).
    public let timestamp: Double
    public let outputTokens: Int

    public init(stepIndex: Int, timestamp: Double, outputTokens: Int) {
        self.stepIndex = stepIndex
        self.timestamp = timestamp
        self.outputTokens = max(0, outputTokens)
    }
}

public struct LiveTPSSnapshot: Equatable, Sendable {
    public let currentTPS: Double
    public let peakTPS: Double
    public let perSessionTPS: [String: Double]
    public let sparkline: [Double]
    public let isWorking: Bool

    public static let idle = LiveTPSSnapshot(
        currentTPS: 0,
        peakTPS: 0,
        perSessionTPS: [:],
        sparkline: [],
        isWorking: false
    )

    public init(
        currentTPS: Double,
        peakTPS: Double,
        perSessionTPS: [String: Double],
        sparkline: [Double],
        isWorking: Bool
    ) {
        self.currentTPS = currentTPS
        self.peakTPS = peakTPS
        self.perSessionTPS = perSessionTPS
        self.sparkline = sparkline
        self.isWorking = isWorking
    }
}

public struct LiveTPSTracker: Equatable, Sendable {
    public let sparklineCapacity: Int
    public let windowSeconds: Double

    private var sparkline: [Double] = []
    private var lastKnownSessionTPS: [String: Double] = [:]
    private var lastSeenStepBySession: [String: Int] = [:]

    private static let maxSaneSessionTPS: Double = 1200.0
    private static let futureSkewAllowance: Double = 5.0
    private static let consecutiveFallbackMaxAge: Double = 90.0
    private static let singleSampleDecayThreshold: Double = 12.0
    private static let busyDecayFactor: Double = 0.88
    private static let decayFloor: Double = 0.25

    public init(sparklineCapacity: Int = 20, windowSeconds: Double = 30.0) {
        self.sparklineCapacity = max(1, sparklineCapacity)
        self.windowSeconds = max(1.0, windowSeconds)
    }

    public mutating func update(
        busySessionIds: Set<String>,
        samplesBySession: [String: [OutputTokenSample]],
        now: Double
    ) -> LiveTPSSnapshot {
        guard !busySessionIds.isEmpty else {
            sparkline.removeAll(keepingCapacity: false)
            lastKnownSessionTPS.removeAll(keepingCapacity: false)
            lastSeenStepBySession.removeAll(keepingCapacity: false)
            return .idle
        }

        // Prune sessions that are no longer busy.
        lastKnownSessionTPS = lastKnownSessionTPS.filter { busySessionIds.contains($0.key) }
        lastSeenStepBySession = lastSeenStepBySession.filter { busySessionIds.contains($0.key) }

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

            let tps = computeSessionTPS(sessionId: sid, sortedSamples: valid, now: now)
            perSession[sid] = tps
            lastKnownSessionTPS[sid] = tps
        }

        let currentTPS = perSession.values.reduce(0.0, +)
        sparkline.append(currentTPS)
        if sparkline.count > sparklineCapacity {
            sparkline.removeFirst(sparkline.count - sparklineCapacity)
        }
        let peakTPS = max(sparkline.max() ?? 0.0, currentTPS)

        return LiveTPSSnapshot(
            currentTPS: currentTPS,
            peakTPS: peakTPS,
            perSessionTPS: perSession,
            sparkline: sparkline,
            isWorking: true
        )
    }

    private mutating func computeSessionTPS(
        sessionId: String,
        sortedSamples: [OutputTokenSample],
        now: Double
    ) -> Double {
        let prevTPS = lastKnownSessionTPS[sessionId]
        let prevStep = lastSeenStepBySession[sessionId]
        let windowStart = now - windowSeconds
        let windowEnd = now + Self.futureSkewAllowance

        let inWindow = sortedSamples.filter {
            $0.timestamp >= windowStart && $0.timestamp <= windowEnd
        }

        let latestValid = sortedSamples.last(where: { $0.timestamp <= windowEnd })
        let hasNewStep: Bool = {
            guard let latest = latestValid else { return false }
            guard let seen = prevStep else { return true }
            return latest.stepIndex > seen
        }()

        // 1. >= 2 samples inside active window
        if inWindow.count >= 2, let earliest = inWindow.first, let latest = inWindow.last {
            let age = max(0.0, now - latest.timestamp)
            if !hasNewStep, let prev = prevTPS, age > Self.singleSampleDecayThreshold {
                return decayed(prev)
            }
            let tokensAfterEarliest = inWindow.dropFirst().reduce(0) { $0 + $1.outputTokens }
            let dt = max(1.0, latest.timestamp - earliest.timestamp)
            let rate = clampSessionTPS(Double(tokensAfterEarliest) / dt)
            lastSeenStepBySession[sessionId] = latest.stepIndex
            return rate
        }

        // 2. Fallback to last 2 consecutive samples if within 90s of `now`
        let recentUpToNow = sortedSamples.filter { $0.timestamp <= windowEnd }
        if recentUpToNow.count >= 2 {
            let secondLast = recentUpToNow[recentUpToNow.count - 2]
            let last = recentUpToNow[recentUpToNow.count - 1]
            let lastAge = max(0.0, now - last.timestamp)
            let pairSpan = last.timestamp - secondLast.timestamp
            if lastAge <= Self.consecutiveFallbackMaxAge
                && pairSpan >= 0
                && (now - secondLast.timestamp) <= Self.consecutiveFallbackMaxAge {
                // If we already observed this exact latest step and it has fallen out of
                // the primary window (or aged past singleSampleDecayThreshold), smoothly decay
                // instead of holding a flat stale plateau.
                if !hasNewStep, let prev = prevTPS,
                   inWindow.isEmpty || lastAge > Self.singleSampleDecayThreshold {
                    return decayed(prev)
                }
                let dt = max(1.0, pairSpan)
                let rate = clampSessionTPS(Double(last.outputTokens) / dt)
                lastSeenStepBySession[sessionId] = last.stepIndex
                return rate
            }
        }

        // 3. Single recent sample within active window
        if let sample = inWindow.last {
            let age = max(0.0, now - sample.timestamp)
            let denom = max(2.0, min(15.0, age + 2.0))
            var rate = Double(sample.outputTokens) / denom
            if age > Self.singleSampleDecayThreshold {
                let extra = age - Self.singleSampleDecayThreshold
                rate *= pow(Self.busyDecayFactor, extra / 4.0)
            }
            lastSeenStepBySession[sessionId] = sample.stepIndex
            let clamped = clampSessionTPS(rate)
            return clamped < Self.decayFloor ? 0.0 : clamped
        }

        // 4. Busy session generating next step with no fresh sample -> gentle exponential decay
        if let prev = prevTPS, prev > 0 {
            return decayed(prev)
        }

        return 0.0
    }

    private func clampSessionTPS(_ value: Double) -> Double {
        guard value.isFinite else { return 0.0 }
        return min(Self.maxSaneSessionTPS, max(0.0, value))
    }

    private func decayed(_ prev: Double) -> Double {
        let next = prev * Self.busyDecayFactor
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
