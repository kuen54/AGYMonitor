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

public struct LiveGeneratingStep: Equatable, Sendable {
    public let stepIndex: Int
    public let startedAt: Double
    public let streamStartedAt: Double?
    public let streamedBytes: Int
    public let modelHint: String?
    public let lastObservedActivityAt: Double?

    public init(
        stepIndex: Int,
        startedAt: Double,
        streamStartedAt: Double? = nil,
        streamedBytes: Int = 0,
        modelHint: String? = nil,
        lastObservedActivityAt: Double? = nil
    ) {
        self.stepIndex = stepIndex
        self.startedAt = startedAt
        self.streamStartedAt = streamStartedAt
        self.streamedBytes = max(0, streamedBytes)
        let trimmed = modelHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelHint = (trimmed?.isEmpty == true) ? nil : trimmed
        self.lastObservedActivityAt = lastObservedActivityAt
    }
}

public struct ConversationDBStepRow: Equatable, Sendable {
    public let stepIndex: Int
    public let status: Int
    public let metadata: Data
    public let stepPayload: Data?

    public init(
        stepIndex: Int,
        status: Int,
        metadata: Data,
        stepPayload: Data? = nil
    ) {
        self.stepIndex = stepIndex
        self.status = status
        self.metadata = metadata
        self.stepPayload = stepPayload
    }
}

public struct ConversationDBTelemetry: Equatable, Sendable {
    public let completedSamples: [OutputTokenSample]
    public let activeGeneratingStep: LiveGeneratingStep?
    public let lastObservedActivityAt: Double?

    public static let empty = ConversationDBTelemetry(
        completedSamples: [],
        activeGeneratingStep: nil,
        lastObservedActivityAt: nil
    )

    public init(
        completedSamples: [OutputTokenSample],
        activeGeneratingStep: LiveGeneratingStep? = nil,
        lastObservedActivityAt: Double? = nil
    ) {
        self.completedSamples = completedSamples
        self.activeGeneratingStep = activeGeneratingStep
        self.lastObservedActivityAt = lastObservedActivityAt
    }
}

/// Pure Foundation, bounds-checked protobuf decoder for Antigravity per-conversation
/// SQLite `steps` rows (`step_type = 15`, `PLANNER_RESPONSE`).
public enum ConversationDBStepDecoder {
    public static let generatingStatusCode: Int = 8
    public static let maxPlausibleStreamTPS: Double = 450.0
    public static let maxValidStepDurationSeconds: Double = 3600.0
    private static let maxValidEpochSeconds: Int64 = 4_102_444_800 // 2100-01-01T00:00:00Z

    private struct ParsedMetadata {
        var createdAt: Double? = nil
        var streamStartedAt: Double? = nil
        var transitionGeneratingAt: Double? = nil
        var completedAt: Double? = nil
        var completedAtFallback: Double? = nil
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cacheReadTokens: Int = 0
        var thinkingTokens: Int = 0
        var responseTokens: Int = 0

        var effectiveStreamStartedAt: Double? {
            streamStartedAt ?? transitionGeneratingAt
        }

        var effectiveCompletedAt: Double? {
            completedAt ?? completedAtFallback
        }

        var effectiveOutputTokens: Int {
            outputTokens > 0
                ? outputTokens
                : ConversationDBStepDecoder.saturatingAdd(thinkingTokens, responseTokens)
        }
    }

    public static func decode(
        rows: [ConversationDBStepRow],
        modelHint: String? = nil,
        lastObservedActivityAt: Double? = nil
    ) -> ConversationDBTelemetry {
        guard !rows.isEmpty else {
            return ConversationDBTelemetry(
                completedSamples: [],
                activeGeneratingStep: nil,
                lastObservedActivityAt: lastObservedActivityAt
            )
        }

        var samplesByStep: [Int: OutputTokenSample] = [:]
        var activeGenerating: LiveGeneratingStep? = nil

        for row in rows {
            let meta = parseMetadata(row.metadata)

            if row.status == Self.generatingStatusCode {
                if let startedAt = meta.createdAt ?? meta.effectiveStreamStartedAt ?? lastObservedActivityAt,
                   startedAt.isFinite, startedAt > 0 {
                    let streamedBytes = row.stepPayload.map(parseStreamedBytes(_:)) ?? 0
                    let candidate = LiveGeneratingStep(
                        stepIndex: row.stepIndex,
                        startedAt: startedAt,
                        streamStartedAt: meta.effectiveStreamStartedAt,
                        streamedBytes: streamedBytes,
                        modelHint: modelHint,
                        lastObservedActivityAt: lastObservedActivityAt
                    )
                    if let existing = activeGenerating {
                        if candidate.stepIndex >= existing.stepIndex {
                            activeGenerating = candidate
                        }
                    } else {
                        activeGenerating = candidate
                    }
                }
                continue
            }

            let outTokens = meta.effectiveOutputTokens
            guard outTokens > 0 else { continue }

            if let completedAt = meta.effectiveCompletedAt, completedAt.isFinite, completedAt > 0 {
                let dTotal: Double? = {
                    guard let created = meta.createdAt else { return nil }
                    let d = completedAt - created
                    return (d.isFinite && d > 0 && d <= Self.maxValidStepDurationSeconds) ? d : nil
                }()
                let dStream: Double? = {
                    guard let streamStart = meta.effectiveStreamStartedAt else { return nil }
                    if let created = meta.createdAt, streamStart < created {
                        return nil
                    }
                    let d = completedAt - streamStart
                    return (d.isFinite && d > 0 && d <= Self.maxValidStepDurationSeconds) ? d : nil
                }()

                let duration: Double
                if let ds = dStream,
                   ds >= 1.0,
                   (Double(outTokens) / ds) <= Self.maxPlausibleStreamTPS {
                    duration = ds
                } else if let dt = dTotal, dt >= 1.0 {
                    duration = dt
                } else {
                    duration = max(1.0, dTotal ?? dStream ?? 1.0)
                }

                samplesByStep[row.stepIndex] = OutputTokenSample(
                    stepIndex: row.stepIndex,
                    timestamp: completedAt,
                    outputTokens: outTokens,
                    durationSeconds: duration
                )
            } else if let createdAt = meta.createdAt, createdAt.isFinite, createdAt > 0 {
                samplesByStep[row.stepIndex] = OutputTokenSample(
                    stepIndex: row.stepIndex,
                    timestamp: createdAt,
                    outputTokens: outTokens,
                    durationSeconds: nil
                )
            }
        }

        let sortedSamples = samplesByStep.values.sorted { a, b in
            if a.stepIndex != b.stepIndex { return a.stepIndex < b.stepIndex }
            return a.timestamp < b.timestamp
        }

        return ConversationDBTelemetry(
            completedSamples: Array(sortedSamples.suffix(12)),
            activeGeneratingStep: activeGenerating,
            lastObservedActivityAt: lastObservedActivityAt
        )
    }

    // MARK: - Bounds-checked pure protobuf wire helpers

    private static func parseMetadata(_ data: Data) -> ParsedMetadata {
        var out = ParsedMetadata()
        guard !data.isEmpty else { return out }
        data.withUnsafeBytes { buf in
            var cursor = 0
            let end = buf.count
            while cursor < end {
                guard let tag = readVarint(buf, cursor: &cursor, end: end) else { break }
                let fieldNumber = tag >> 3
                let wireType = tag & 0x07
                guard fieldNumber > 0 else { break }

                switch (fieldNumber, wireType) {
                case (1, 2):
                    guard let (s, e) = readLengthDelimitedRange(buf, cursor: &cursor, end: end) else { return }
                    if let ts = parseTimestamp(buf, start: s, end: e) {
                        out.createdAt = ts
                    }
                case (6, 2):
                    guard let (s, e) = readLengthDelimitedRange(buf, cursor: &cursor, end: end) else { return }
                    if let ts = parseTimestamp(buf, start: s, end: e) {
                        out.streamStartedAt = ts
                    }
                case (7, 2):
                    guard let (s, e) = readLengthDelimitedRange(buf, cursor: &cursor, end: end) else { return }
                    if let ts = parseTimestamp(buf, start: s, end: e) {
                        out.completedAt = ts
                    }
                case (8, 2):
                    guard let (s, e) = readLengthDelimitedRange(buf, cursor: &cursor, end: end) else { return }
                    if let ts = parseTimestamp(buf, start: s, end: e) {
                        out.completedAtFallback = ts
                    }
                case (9, 2):
                    guard let (s, e) = readLengthDelimitedRange(buf, cursor: &cursor, end: end) else { return }
                    parseTokenUsage(buf, start: s, end: e, into: &out)
                case (26, 2):
                    guard let (s, e) = readLengthDelimitedRange(buf, cursor: &cursor, end: end) else { return }
                    parseTransitionsWrapper(buf, start: s, end: e, into: &out)
                default:
                    if !skipField(wireType: wireType, buf, cursor: &cursor, end: end) {
                        return
                    }
                }
            }
        }
        return out
    }

    private static func parseTimestamp(
        _ buf: UnsafeRawBufferPointer,
        start: Int,
        end: Int
    ) -> Double? {
        var cursor = start
        var seconds: Int64 = 0
        var nanos: Int64 = 0
        var sawSeconds = false
        while cursor < end {
            guard let tag = readVarint(buf, cursor: &cursor, end: end) else { return nil }
            let fieldNumber = tag >> 3
            let wireType = tag & 0x07
            guard fieldNumber > 0 else { return nil }
            switch (fieldNumber, wireType) {
            case (1, 0):
                guard let v = readVarint(buf, cursor: &cursor, end: end) else { return nil }
                seconds = Int64(bitPattern: v)
                sawSeconds = true
            case (2, 0):
                guard let v = readVarint(buf, cursor: &cursor, end: end) else { return nil }
                nanos = Int64(bitPattern: v)
            default:
                if !skipField(wireType: wireType, buf, cursor: &cursor, end: end) {
                    return nil
                }
            }
        }
        guard sawSeconds,
              seconds > 0,
              seconds < Self.maxValidEpochSeconds,
              nanos >= 0,
              nanos < 1_000_000_000 else {
            return nil
        }
        let ts = Double(seconds) + Double(nanos) / 1_000_000_000.0
        return ts.isFinite ? ts : nil
    }

    private static func parseTokenUsage(
        _ buf: UnsafeRawBufferPointer,
        start: Int,
        end: Int,
        into out: inout ParsedMetadata
    ) {
        var cursor = start
        while cursor < end {
            guard let tag = readVarint(buf, cursor: &cursor, end: end) else { break }
            let fieldNumber = tag >> 3
            let wireType = tag & 0x07
            guard fieldNumber > 0 else { break }
            if wireType == 0 {
                guard let v = readVarint(buf, cursor: &cursor, end: end) else { break }
                let clamped = clampVarintToNonNegativeInt(v)
                switch fieldNumber {
                case 2: out.inputTokens = clamped
                case 3: out.outputTokens = clamped
                case 5: out.cacheReadTokens = clamped
                case 9: out.thinkingTokens = clamped
                case 10: out.responseTokens = clamped
                default: break
                }
            } else {
                if !skipField(wireType: wireType, buf, cursor: &cursor, end: end) {
                    break
                }
            }
        }
    }

    private static func parseTransitionsWrapper(
        _ buf: UnsafeRawBufferPointer,
        start: Int,
        end: Int,
        into out: inout ParsedMetadata
    ) {
        var cursor = start
        while cursor < end {
            guard let tag = readVarint(buf, cursor: &cursor, end: end) else { break }
            let fieldNumber = tag >> 3
            let wireType = tag & 0x07
            guard fieldNumber > 0 else { break }
            if fieldNumber == 1 && wireType == 2 {
                guard let (tsStart, tsEnd) = readLengthDelimitedRange(buf, cursor: &cursor, end: end) else { break }
                if let genTs = parseSingleTransition(buf, start: tsStart, end: tsEnd) {
                    out.transitionGeneratingAt = genTs
                }
            } else {
                if !skipField(wireType: wireType, buf, cursor: &cursor, end: end) {
                    break
                }
            }
        }
    }

    private static func parseSingleTransition(
        _ buf: UnsafeRawBufferPointer,
        start: Int,
        end: Int
    ) -> Double? {
        var cursor = start
        var statusCode: Int? = nil
        var ts: Double? = nil
        while cursor < end {
            guard let tag = readVarint(buf, cursor: &cursor, end: end) else { break }
            let fieldNumber = tag >> 3
            let wireType = tag & 0x07
            guard fieldNumber > 0 else { break }
            switch (fieldNumber, wireType) {
            case (1, 0):
                guard let v = readVarint(buf, cursor: &cursor, end: end) else { return nil }
                statusCode = clampVarintToNonNegativeInt(v)
            case (2, 2):
                guard let (s, e) = readLengthDelimitedRange(buf, cursor: &cursor, end: end) else { return nil }
                ts = parseTimestamp(buf, start: s, end: e)
            default:
                if !skipField(wireType: wireType, buf, cursor: &cursor, end: end) {
                    return nil
                }
            }
        }
        return statusCode == Self.generatingStatusCode ? ts : nil
    }

    private static func parseStreamedBytes(_ data: Data) -> Int {
        guard !data.isEmpty else { return 0 }
        var totalBytes = 0
        data.withUnsafeBytes { buf in
            var cursor = 0
            let end = buf.count
            while cursor < end {
                guard let tag = readVarint(buf, cursor: &cursor, end: end) else { break }
                let fieldNumber = tag >> 3
                let wireType = tag & 0x07
                guard fieldNumber > 0 else { break }
                if fieldNumber == 20 && wireType == 2 {
                    guard let (pStart, pEnd) = readLengthDelimitedRange(buf, cursor: &cursor, end: end) else { break }
                    totalBytes = saturatingAdd(totalBytes, parsePlannerResponseStreamedBytes(buf, start: pStart, end: pEnd))
                } else {
                    if !skipField(wireType: wireType, buf, cursor: &cursor, end: end) {
                        break
                    }
                }
            }
        }
        return totalBytes
    }

    private static func parsePlannerResponseStreamedBytes(
        _ buf: UnsafeRawBufferPointer,
        start: Int,
        end: Int
    ) -> Int {
        var cursor = start
        var total = 0
        while cursor < end {
            guard let tag = readVarint(buf, cursor: &cursor, end: end) else { break }
            let fieldNumber = tag >> 3
            let wireType = tag & 0x07
            guard fieldNumber > 0 else { break }
            if (fieldNumber == 3 || fieldNumber == 7) && wireType == 2 {
                guard let (s, e) = readLengthDelimitedRange(buf, cursor: &cursor, end: end) else { break }
                total = saturatingAdd(total, e - s)
            } else {
                if !skipField(wireType: wireType, buf, cursor: &cursor, end: end) {
                    break
                }
            }
        }
        return total
    }

    private static func readVarint(
        _ buf: UnsafeRawBufferPointer,
        cursor: inout Int,
        end: Int
    ) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while cursor < end {
            let byte = buf[cursor]
            cursor += 1
            if shift == 63 && byte > 1 {
                return nil
            }
            result |= UInt64(byte & 0x7F) << shift
            if (byte & 0x80) == 0 {
                return result
            }
            shift += 7
            if shift >= 64 {
                return nil
            }
        }
        return nil
    }

    private static func readLengthDelimitedRange(
        _ buf: UnsafeRawBufferPointer,
        cursor: inout Int,
        end: Int
    ) -> (Int, Int)? {
        guard let len = readVarint(buf, cursor: &cursor, end: end),
              len <= UInt64(end - cursor) else {
            return nil
        }
        let start = cursor
        let subEnd = cursor + Int(len)
        cursor = subEnd
        return (start, subEnd)
    }

    private static func skipField(
        wireType: UInt64,
        _ buf: UnsafeRawBufferPointer,
        cursor: inout Int,
        end: Int
    ) -> Bool {
        switch wireType {
        case 0:
            return readVarint(buf, cursor: &cursor, end: end) != nil
        case 1:
            guard end - cursor >= 8 else { return false }
            cursor += 8
            return true
        case 2:
            guard let len = readVarint(buf, cursor: &cursor, end: end),
                  len <= UInt64(end - cursor) else { return false }
            cursor += Int(len)
            return true
        case 5:
            guard end - cursor >= 4 else { return false }
            cursor += 4
            return true
        default:
            return false
        }
    }

    private static func clampVarintToNonNegativeInt(_ raw: UInt64) -> Int {
        let signed = Int64(bitPattern: raw)
        if signed <= 0 { return 0 }
        if signed >= Int64(Int.max) { return Int.max }
        return Int(signed)
    }

    private static func saturatingAdd(_ a: Int, _ b: Int) -> Int {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? Int.max : sum
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

    private struct GeneratingObservation: Equatable, Sendable {
        let stepIndex: Int
        let streamedBytes: Int
        let observedAt: Double
        let lastLiveByteRate: Double?
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
    private var generatingObsBySession: [String: GeneratingObservation] = [:]
    private var isShowingInNotch: Bool = false
    private var isShowingInMenuBar: Bool = false

    private static let maxSaneSessionTPS: Double = 1200.0
    private static let minLiveByteTPS: Double = 10.0
    private static let bytesPerTokenEstimate: Double = 3.6
    private static let minByteDeltaForRate: Int = 120
    private static let minDtForByteRate: Double = 0.5
    private static let bytePlateauGraceSeconds: Double = 6.0
    private static let liveByteBlendWeight: Double = 0.65
    private static let firstTurnCumulativeMaxElapsed: Double = 45.0
    private static let hungStreamHardLimitSeconds: Double = 1800.0
    private static let hungStreamSoftLimitSeconds: Double = 600.0
    private static let hungStreamStaleActivitySeconds: Double = 300.0
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

    /// Merge transcript-derived and DB-derived completed samples. DB completed samples
    /// override same-`stepIndex` transcript samples while preserving transcript-only steps,
    /// sorted ascending by `(stepIndex, timestamp)` and capped to the last 12 entries.
    public static func mergeSamples(
        transcript: [OutputTokenSample],
        db: [OutputTokenSample]
    ) -> [OutputTokenSample] {
        var byStep: [Int: OutputTokenSample] = [:]
        byStep.reserveCapacity(transcript.count + db.count)
        for sample in transcript where sample.outputTokens > 0 && sample.timestamp.isFinite {
            byStep[sample.stepIndex] = sample
        }
        for sample in db where sample.outputTokens > 0 && sample.timestamp.isFinite {
            byStep[sample.stepIndex] = sample
        }
        let sorted = byStep.values.sorted { a, b in
            if a.stepIndex != b.stepIndex { return a.stepIndex < b.stepIndex }
            return a.timestamp < b.timestamp
        }
        return Array(sorted.suffix(12))
    }

    /// Conservative model-family decode prior (tokens/sec) used only on a 1st turn
    /// while `status == 8` is streaming silently with no completed baseline yet.
    public static func decodePriorTPS(for modelHint: String?) -> Double {
        switch ModelClass.classify(modelHint ?? "") {
        case .neon:     return 95.0
        case .hydrogen: return 90.0
        case .flash:    return 90.0
        case .carbon:   return 65.0
        case .argon:    return 65.0
        case .claude:   return 65.0
        case .other:    return 55.0
        }
    }

    public mutating func update(
        busySessionIds: Set<String>,
        subagentIds: Set<String> = [],
        samplesBySession: [String: [OutputTokenSample]],
        generatingBySession: [String: LiveGeneratingStep] = [:],
        modelHintBySession: [String: String] = [:],
        now: Double
    ) -> LiveTPSSnapshot {
        guard !busySessionIds.isEmpty else {
            sparkline.removeAll(keepingCapacity: false)
            lastSparklineAppendAt = nil
            lastKnownSessionTPS.removeAll(keepingCapacity: false)
            lastSeenStepBySession.removeAll(keepingCapacity: false)
            lastUpdateAtBySession.removeAll(keepingCapacity: false)
            generatingObsBySession.removeAll(keepingCapacity: false)
            isShowingInNotch = false
            isShowingInMenuBar = false
            return .idle
        }

        // Prune sessions that are no longer busy.
        lastKnownSessionTPS = lastKnownSessionTPS.filter { busySessionIds.contains($0.key) }
        lastSeenStepBySession = lastSeenStepBySession.filter { busySessionIds.contains($0.key) }
        lastUpdateAtBySession = lastUpdateAtBySession.filter { busySessionIds.contains($0.key) }
        generatingObsBySession = generatingObsBySession.filter { busySessionIds.contains($0.key) }

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
                generatingStep: generatingBySession[sid],
                modelHint: modelHintBySession[sid],
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
        generatingStep: LiveGeneratingStep?,
        modelHint: String?,
        now: Double,
        dtSinceLastUpdate: Double
    ) -> Double {
        let prevTPS = lastKnownSessionTPS[sessionId]
        let prevStep = lastSeenStepBySession[sessionId]
        let windowStart = now - windowSeconds
        let windowEnd = now + Self.futureSkewAllowance

        // 0. Live in-flight `status == 8` generation from per-conversation DB
        if let gen = generatingStep {
            let streamOrigin = gen.streamStartedAt ?? gen.startedAt
            let streamElapsed = (now.isFinite && streamOrigin.isFinite) ? max(0.0, now - streamOrigin) : 0.0
            let activityAge: Double? = {
                guard now.isFinite, let act = gen.lastObservedActivityAt, act.isFinite else { return nil }
                return max(0.0, now - act)
            }()
            let isHungStream = streamElapsed > Self.hungStreamHardLimitSeconds
                || (streamElapsed > Self.hungStreamSoftLimitSeconds
                    && (activityAge ?? streamElapsed) > Self.hungStreamStaleActivitySeconds)

            if isHungStream {
                generatingObsBySession.removeValue(forKey: sessionId)
                if let prev = prevTPS, prev > 0 {
                    return decayed(prev, dt: dtSinceLastUpdate)
                }
                return 0.0
            }

            if gen.streamStartedAt != nil || gen.streamedBytes > 0 {
                // Compute session's own decode baseline from recent completed samples with durationSeconds
                let completedWithDuration = sortedSamples
                    .filter { $0.durationSeconds != nil && $0.timestamp <= windowEnd }
                    .suffix(3)
                let sessionBaseline: Double? = {
                    guard !completedWithDuration.isEmpty else { return nil }
                    let totalTokens = completedWithDuration.reduce(0.0) { $0 + Double($1.outputTokens) }
                    let totalDur = completedWithDuration.reduce(0.0) { $0 + ($1.durationSeconds ?? 0.0) }
                    guard totalTokens > 0, totalDur > 0 else { return nil }
                    return clampSessionTPS(totalTokens / max(1.0, totalDur))
                }()

                var liveByteRate: Double? = nil
                if now.isFinite {
                    if let prevObs = generatingObsBySession[sessionId],
                       prevObs.stepIndex == gen.stepIndex {
                        let deltaBytes = gen.streamedBytes - prevObs.streamedBytes
                        let dt = now - prevObs.observedAt
                        if deltaBytes >= Self.minByteDeltaForRate && dt >= Self.minDtForByteRate {
                            let rawRate = (Double(deltaBytes) / Self.bytesPerTokenEstimate) / dt
                            let clamped = min(Self.maxSaneSessionTPS, max(Self.minLiveByteTPS, rawRate))
                            liveByteRate = clamped
                            generatingObsBySession[sessionId] = GeneratingObservation(
                                stepIndex: gen.stepIndex,
                                streamedBytes: gen.streamedBytes,
                                observedAt: now,
                                lastLiveByteRate: clamped
                            )
                        } else if deltaBytes > 0 {
                            // Accumulating bytes across rapid sub-0.5s polls: keep anchor intact
                            // and preserve the most recent live byte rate to prevent brief dips.
                            liveByteRate = prevObs.lastLiveByteRate
                        } else if deltaBytes == 0 {
                            if dt <= Self.bytePlateauGraceSeconds {
                                // Intermediate FSEvents poll between WAL flushes (<= 6s): keep anchor
                                // and live rate intact so the next flush divides by the real flush span
                                // without sawtooth flicker or 3x-4x TPS spikes.
                                liveByteRate = prevObs.lastLiveByteRate
                            } else {
                                // Genuine silent plateau (> 6s, e.g. tool-call argument streaming):
                                // clear live byte rate and advance anchor timestamp for clean resumption.
                                generatingObsBySession[sessionId] = GeneratingObservation(
                                    stepIndex: gen.stepIndex,
                                    streamedBytes: gen.streamedBytes,
                                    observedAt: now,
                                    lastLiveByteRate: nil
                                )
                            }
                        } else {
                            // Unexpected byte count regression: reset anchor cleanly.
                            generatingObsBySession[sessionId] = GeneratingObservation(
                                stepIndex: gen.stepIndex,
                                streamedBytes: gen.streamedBytes,
                                observedAt: now,
                                lastLiveByteRate: nil
                            )
                        }
                    } else {
                        generatingObsBySession[sessionId] = GeneratingObservation(
                            stepIndex: gen.stepIndex,
                            streamedBytes: gen.streamedBytes,
                            observedAt: now,
                            lastLiveByteRate: nil
                        )
                    }
                }

                let resolvedRate: Double
                if let byteRate = liveByteRate {
                    if let baseline = sessionBaseline {
                        resolvedRate = clampSessionTPS(
                            Self.liveByteBlendWeight * byteRate
                                + (1.0 - Self.liveByteBlendWeight) * baseline
                        )
                    } else {
                        resolvedRate = clampSessionTPS(byteRate)
                    }
                } else if let baseline = sessionBaseline {
                    resolvedRate = baseline
                } else if gen.streamedBytes >= Self.minByteDeltaForRate
                            && streamElapsed <= Self.firstTurnCumulativeMaxElapsed {
                    let denom = max(1.0, streamElapsed)
                    resolvedRate = clampSessionTPS((Double(gen.streamedBytes) / Self.bytesPerTokenEstimate) / denom)
                } else {
                    resolvedRate = clampSessionTPS(Self.decodePriorTPS(for: gen.modelHint ?? modelHint))
                }
                return resolvedRate < Self.decayFloor ? 0.0 : resolvedRate
            }
        } else {
            generatingObsBySession.removeValue(forKey: sessionId)
        }

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
            let rawRate: Double
            if inWindow.allSatisfy({ $0.durationSeconds != nil }) {
                let totalTokens = inWindow.reduce(0.0) { $0 + Double($1.outputTokens) }
                let totalDuration = inWindow.reduce(0.0) { $0 + ($1.durationSeconds ?? 0.0) }
                rawRate = totalTokens / max(1.0, totalDuration)
            } else {
                let tokensAfterEarliest = inWindow.dropFirst().reduce(0.0) { $0 + Double($1.outputTokens) }
                let span = latest.timestamp - earliest.timestamp
                let effectiveSpan: Double
                if inWindow.count == 2, let explicitDur = latest.durationSeconds {
                    effectiveSpan = max(span, explicitDur)
                } else {
                    effectiveSpan = span
                }
                let dt = max(1.0, effectiveSpan)
                rawRate = tokensAfterEarliest / dt
            }
            var rate = clampSessionTPS(rawRate)
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
