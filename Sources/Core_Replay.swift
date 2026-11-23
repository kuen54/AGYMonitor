import Foundation

// MARK: - Universal Session Black Box Replay — pure core
//
// Foundation-only (part of AGYCore): models, parsers, topology classifier,
// timeline builder (with overnight idle compression, human-wait forensics,
// retry-loop cost waste accounting, verify-track detection, and synthetic
// workflow stages), 5-topology radar layout engine, playhead frame evaluator,
// and deterministic playback state machine.
//
// Zero AppKit, zero SwiftUI, zero CoreGraphics, zero Combine, zero SQLite,
// zero Process, zero FileManager. All dates use `AppDate.gregorian` /
// `AppDate.parseISO8601`.

// MARK: - Enums & Core Value Types

public enum SessionTopologyKind: String, Codable, CaseIterable, Equatable, Sendable {
    case swarm
    case dynamicWorkflow
    case subagentTree
    case battle
    case solo

    public var badgeCode: String {
        switch self {
        case .swarm:           return "SWARM"
        case .dynamicWorkflow: return "WORKFLOW"
        case .subagentTree:    return "SUBAGENT"
        case .battle:          return "BATTLE"
        case .solo:            return "SOLO"
        }
    }
}

public enum ReplayTrackKind: String, Codable, Equatable, Sendable {
    case root
    case swarmWorker
    case workflowStage
    case subagent
    case battleBranch
}

public enum ReplaySegmentKind: String, Codable, Equatable, Sendable {
    case work
    case humanWait
    case retryLoop
    case verify
}

public enum ReplayBeamKind: String, Codable, Equatable, Sendable {
    case boardPost
    case spawn
    case subagentMessage
    case workflowStage
}

public enum ReplayTrackLiveState: String, Equatable, Sendable {
    case idle
    case working
    case waiting
    case retrying
    case verify
    case done
}

public struct ReplaySegment: Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: ReplaySegmentKind
    public let startSec: Double
    public let endSec: Double
    public let stepCount: Int
    public let errorCount: Int
    public let estimatedCostUSD: Double
    public let label: String?

    public var durationSec: Double { max(0, endSec - startSec) }

    public init(
        id: String,
        kind: ReplaySegmentKind,
        startSec: Double,
        endSec: Double,
        stepCount: Int,
        errorCount: Int = 0,
        estimatedCostUSD: Double = 0,
        label: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.startSec = startSec
        self.endSec = endSec
        self.stepCount = stepCount
        self.errorCount = errorCount
        self.estimatedCostUSD = estimatedCostUSD
        self.label = label
    }
}

public struct ReplayBeamEvent: Equatable, Identifiable, Sendable {
    public let id: String
    public let timestampSec: Double
    public let fromTrackId: String
    public let toTrackId: String
    public let kind: ReplayBeamKind
    public let summary: String

    public init(
        id: String,
        timestampSec: Double,
        fromTrackId: String,
        toTrackId: String,
        kind: ReplayBeamKind,
        summary: String
    ) {
        self.id = id
        self.timestampSec = timestampSec
        self.fromTrackId = fromTrackId
        self.toTrackId = toTrackId
        self.kind = kind
        self.summary = summary
    }
}

public struct ReplayTrack: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let roleLabel: String
    public let kind: ReplayTrackKind
    public let parentTrackId: String?
    public let depth: Int
    public let modelClass: ModelClass
    public let segments: [ReplaySegment]
    public let totalTokens: Int
    public let outputTokens: Int
    public let estimatedCostUSD: Double
    public let retryCount: Int
    public let retryWasteUSD: Double

    public init(
        id: String,
        name: String,
        roleLabel: String,
        kind: ReplayTrackKind,
        parentTrackId: String?,
        depth: Int,
        modelClass: ModelClass,
        segments: [ReplaySegment],
        totalTokens: Int,
        outputTokens: Int,
        estimatedCostUSD: Double,
        retryCount: Int,
        retryWasteUSD: Double
    ) {
        self.id = id
        self.name = name
        self.roleLabel = roleLabel
        self.kind = kind
        self.parentTrackId = parentTrackId
        self.depth = depth
        self.modelClass = modelClass
        self.segments = segments
        self.totalTokens = totalTokens
        self.outputTokens = outputTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.retryCount = retryCount
        self.retryWasteUSD = retryWasteUSD
    }
}

public struct ReplayMissionSummary: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let workspaceLabel: String
    public let topology: SessionTopologyKind
    public let startedAt: Double
    public let lastActiveAt: Double
    public let durationSec: Double
    public let trackCount: Int
    public let stepCount: Int
    public let isLive: Bool

    public init(
        id: String,
        title: String,
        workspaceLabel: String,
        topology: SessionTopologyKind,
        startedAt: Double,
        lastActiveAt: Double,
        durationSec: Double,
        trackCount: Int,
        stepCount: Int,
        isLive: Bool
    ) {
        self.id = id
        self.title = title
        self.workspaceLabel = workspaceLabel
        self.topology = topology
        self.startedAt = startedAt
        self.lastActiveAt = lastActiveAt
        self.durationSec = durationSec
        self.trackCount = trackCount
        self.stepCount = stepCount
        self.isLive = isLive
    }
}

public struct ReplayTimeline: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let workspaceLabel: String
    public let topology: SessionTopologyKind
    public let dateLabel: String
    public let totalDurationSec: Double
    public let tracks: [ReplayTrack]
    public let beams: [ReplayBeamEvent]
    public let totalCostUSD: Double
    public let totalTokens: Int
    public let retryWasteUSD: Double
    public let retryWastePercent: Int
    public let humanWaitSec: Double
    public let humanWaitPercent: Int
    public let totalRetryLoops: Int

    public init(
        id: String,
        title: String,
        workspaceLabel: String,
        topology: SessionTopologyKind,
        dateLabel: String,
        totalDurationSec: Double,
        tracks: [ReplayTrack],
        beams: [ReplayBeamEvent],
        totalCostUSD: Double,
        totalTokens: Int,
        retryWasteUSD: Double,
        retryWastePercent: Int,
        humanWaitSec: Double,
        humanWaitPercent: Int,
        totalRetryLoops: Int
    ) {
        self.id = id
        self.title = title
        self.workspaceLabel = workspaceLabel
        self.topology = topology
        self.dateLabel = dateLabel
        self.totalDurationSec = totalDurationSec
        self.tracks = tracks
        self.beams = beams
        self.totalCostUSD = totalCostUSD
        self.totalTokens = totalTokens
        self.retryWasteUSD = retryWasteUSD
        self.retryWastePercent = retryWastePercent
        self.humanWaitSec = humanWaitSec
        self.humanWaitPercent = humanWaitPercent
        self.totalRetryLoops = totalRetryLoops
    }
}

public struct ReplayRadarNode: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let kind: ReplayTrackKind
    public let depth: Int
    public let normX: Double
    public let normY: Double
    public let parentId: String?
    public let estimatedCostUSD: Double
    public let modelClass: ModelClass

    public init(
        id: String,
        name: String,
        kind: ReplayTrackKind,
        depth: Int,
        normX: Double,
        normY: Double,
        parentId: String?,
        estimatedCostUSD: Double,
        modelClass: ModelClass
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.depth = depth
        self.normX = normX
        self.normY = normY
        self.parentId = parentId
        self.estimatedCostUSD = estimatedCostUSD
        self.modelClass = modelClass
    }
}

public struct ReplayActiveBeam: Equatable, Identifiable, Sendable {
    public let id: String
    public let fromTrackId: String
    public let toTrackId: String
    public let kind: ReplayBeamKind
    public let progress: Double
    public let summary: String

    public init(
        id: String,
        fromTrackId: String,
        toTrackId: String,
        kind: ReplayBeamKind,
        progress: Double,
        summary: String
    ) {
        self.id = id
        self.fromTrackId = fromTrackId
        self.toTrackId = toTrackId
        self.kind = kind
        self.progress = progress
        self.summary = summary
    }
}

public struct ReplayFaultCallout: Equatable, Sendable {
    public let trackId: String
    public let trackName: String
    public let retryCount: Int
    public let wasteUSD: Double

    public init(
        trackId: String,
        trackName: String,
        retryCount: Int,
        wasteUSD: Double
    ) {
        self.trackId = trackId
        self.trackName = trackName
        self.retryCount = retryCount
        self.wasteUSD = wasteUSD
    }
}

public struct ReplayPlayheadSnapshot: Equatable, Sendable {
    public let progress: Double
    public let currentSec: Double
    public let trackStates: [String: ReplayTrackLiveState]
    public let activeBeams: [ReplayActiveBeam]
    public let activeFault: ReplayFaultCallout?
    public let sweepAngleDeg: Double

    public init(
        progress: Double,
        currentSec: Double,
        trackStates: [String: ReplayTrackLiveState],
        activeBeams: [ReplayActiveBeam],
        activeFault: ReplayFaultCallout?,
        sweepAngleDeg: Double
    ) {
        self.progress = progress
        self.currentSec = currentSec
        self.trackStates = trackStates
        self.activeBeams = activeBeams
        self.activeFault = activeFault
        self.sweepAngleDeg = sweepAngleDeg
    }
}

public enum ReplayKeyEventKind: String, Equatable, Sendable {
    case retryStart
    case workerSpawn
    case workflowWave
    case beamBurst
}

public struct ReplayKeyEvent: Equatable, Identifiable, Sendable {
    public let id: String
    public let progress: Double
    public let timestampSec: Double
    public let kind: ReplayKeyEventKind
    public let trackId: String
    public let label: String

    public init(
        id: String,
        progress: Double,
        timestampSec: Double,
        kind: ReplayKeyEventKind,
        trackId: String,
        label: String
    ) {
        self.id = id
        self.progress = progress
        self.timestampSec = timestampSec
        self.kind = kind
        self.trackId = trackId
        self.label = label
    }
}

// MARK: - Pure Input DTOs

public struct ReplayRawStep: Equatable, Sendable {
    public let stepIndex: Int
    public let timestamp: Double
    public let type: String
    public let status: String
    public let model: String?
    public let inputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let outputTokens: Int
    public let toolNames: [String]
    public let workflowDescriptions: [String]
    public let subagentTargets: [String]

    public init(
        stepIndex: Int,
        timestamp: Double,
        type: String,
        status: String,
        model: String? = nil,
        inputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        outputTokens: Int = 0,
        toolNames: [String] = [],
        workflowDescriptions: [String] = [],
        subagentTargets: [String] = []
    ) {
        self.stepIndex = stepIndex
        self.timestamp = timestamp
        self.type = type
        self.status = status
        self.model = model
        self.inputTokens = inputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.outputTokens = outputTokens
        self.toolNames = toolNames
        self.workflowDescriptions = workflowDescriptions
        self.subagentTargets = subagentTargets
    }
}

public struct ReplayChildInput: Equatable, Sendable {
    public let conversationId: String
    public let name: String
    public let roleLabel: String
    public let kind: ReplayTrackKind
    public let parentId: String
    public let depth: Int
    public let steps: [ReplayRawStep]

    public init(
        conversationId: String,
        name: String,
        roleLabel: String,
        kind: ReplayTrackKind,
        parentId: String,
        depth: Int,
        steps: [ReplayRawStep]
    ) {
        self.conversationId = conversationId
        self.name = name
        self.roleLabel = roleLabel
        self.kind = kind
        self.parentId = parentId
        self.depth = depth
        self.steps = steps
    }
}

public struct ReplayBoardInput: Equatable, Sendable {
    public let seq: Int
    public let agent: String
    public let text: String
    public let timestamp: Double

    public init(
        seq: Int,
        agent: String,
        text: String,
        timestamp: Double
    ) {
        self.seq = seq
        self.agent = agent
        self.text = text
        self.timestamp = timestamp
    }
}

public struct ReplayMissionMeta: Equatable, Sendable {
    public let conversationId: String
    public let title: String
    public let workspaceLabel: String
    public let battleId: String?
    public let hasSwarmDir: Bool

    public init(
        conversationId: String,
        title: String,
        workspaceLabel: String,
        battleId: String? = nil,
        hasSwarmDir: Bool = false
    ) {
        self.conversationId = conversationId
        self.title = title
        self.workspaceLabel = workspaceLabel
        self.battleId = battleId
        self.hasSwarmDir = hasSwarmDir
    }
}

// MARK: - Replay Logic Engine

public enum ReplayLogic {

    // MARK: Constants

    private static let idleCompressionThresholdSec: Double = 1800.0
    private static let compressedIdleBreakSec: Double = 60.0
    private static let humanWaitMinSec: Double = 60.0
    private static let humanWaitMaxSec: Double = 1800.0
    private static let retryClusterGapSec: Double = 180.0
    private static let trackBurstSplitGapSec: Double = 180.0
    private static let minVisualSegmentSec: Double = 2.0
    private static let radarMinCoord: Double = 0.14
    private static let radarMaxCoord: Double = 0.86

    // MARK: 1. Transcript Parser

    /// Parses Antigravity `transcript.jsonl` lines into chronological `ReplayRawStep`s.
    /// Filters malformed lines and `0001-01-01` zero-time sentinels cleanly.
    public static func parseTranscriptSteps(jsonlText: String) -> [ReplayRawStep] {
        guard !jsonlText.isEmpty else { return [] }
        var steps: [ReplayRawStep] = []
        var fallbackIndex = 0

        for sub in jsonlText.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = sub.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let createdRaw = (obj["created_at"] as? String) ?? (obj["timestamp"] as? String)
            guard let date = AppDate.parseISO8601(createdRaw) else {
                continue
            }
            let ts = date.timeIntervalSince1970
            guard ts > 0 else { continue }

            let stepIndex = (obj["step_index"] as? Int) ?? fallbackIndex
            fallbackIndex += 1

            let rawType = (obj["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let typeStr = (rawType?.isEmpty == false) ? rawType! : "UNKNOWN"

            let rawStatus = (obj["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let statusStr = (rawStatus?.isEmpty == false) ? rawStatus! : "UNKNOWN"

            let rawModel = (obj["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = (rawModel?.isEmpty == false) ? rawModel : nil

            let inp = max(0, obj["input_tokens"] as? Int ?? 0)
            let cr  = max(0, (obj["cache_read_tokens"] as? Int) ?? (obj["cache_read"] as? Int) ?? 0)
            let cw  = max(0, (obj["cache_write_tokens"] as? Int) ?? (obj["cache_write"] as? Int) ?? 0)
            let out = max(0, obj["output_tokens"] as? Int ?? 0)

            var toolNames: [String] = []
            var workflowDescriptions: [String] = []
            var subagentTargets: [String] = []

            if let calls = obj["tool_calls"] as? [[String: Any]] {
                for call in calls {
                    guard let rawName = (call["name"] as? String) ?? (call["tool_name"] as? String) else {
                        continue
                    }
                    let cleanedName = normalizeToolName(rawName)
                    guard !cleanedName.isEmpty else { continue }
                    toolNames.append(cleanedName)

                    let argsDict = extractToolArguments(from: call)
                    if cleanedName == "run_workflow" {
                        if let desc = firstNonEmptyString(in: argsDict, keys: [
                            "Description", "description", "ScriptPath", "script_path"
                        ]) {
                            workflowDescriptions.append(desc)
                        }
                    } else if cleanedName == "invoke_subagent"
                                || cleanedName == "define_subagent"
                                || cleanedName == "send_message" {
                        if let target = firstNonEmptyString(in: argsDict, keys: [
                            "Role", "role",
                            "TypeName", "type_name",
                            "Name", "name",
                            "AgentName", "agent_name",
                            "Recipient", "recipient",
                            "Target", "target",
                            "ConversationId", "conversation_id"
                        ]) {
                            subagentTargets.append(target)
                        }
                    }
                }
            }

            steps.append(ReplayRawStep(
                stepIndex: stepIndex,
                timestamp: ts,
                type: typeStr,
                status: statusStr,
                model: model,
                inputTokens: inp,
                cacheReadTokens: cr,
                cacheWriteTokens: cw,
                outputTokens: out,
                toolNames: toolNames,
                workflowDescriptions: workflowDescriptions,
                subagentTargets: subagentTargets
            ))
        }

        steps.sort { a, b in
            if a.timestamp != b.timestamp { return a.timestamp < b.timestamp }
            return a.stepIndex < b.stepIndex
        }
        return steps
    }

    private static func normalizeToolName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("default_api:") {
            return String(trimmed.dropFirst("default_api:".count))
        }
        return trimmed
    }

    private static func extractToolArguments(from call: [String: Any]) -> [String: Any]? {
        if let dict = call["arguments"] as? [String: Any] { return dict }
        if let dict = call["args"] as? [String: Any] { return dict }
        if let rawStr = (call["arguments"] as? String) ?? (call["args"] as? String),
           let data = rawStr.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dict
        }
        return nil
    }

    private static func firstNonEmptyString(in dict: [String: Any]?, keys: [String]) -> String? {
        guard let dict = dict else { return nil }
        for key in keys {
            if let value = dict[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    // MARK: 2. Swarm Board Parser

    /// Parses `swarm/board.jsonl` lines (`seq`, `agent`, `text`, `time`).
    /// Accepts both ISO-8601 timestamps and local wall-clock `"yyyy-MM-dd HH:mm:ss"`
    /// parsed strictly via `AppDate.gregorian` (zero shared `DateFormatter`).
    public static func parseSwarmBoard(jsonlText: String) -> [ReplayBoardInput] {
        guard !jsonlText.isEmpty else { return [] }
        var events: [ReplayBoardInput] = []

        for sub in jsonlText.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = sub.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            guard let agentRaw = obj["agent"] as? String else { continue }
            let agent = agentRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !agent.isEmpty else { continue }

            let seq = (obj["seq"] as? Int) ?? (events.count + 1)
            let text = (obj["text"] as? String) ?? ""

            let timestamp: Double? = {
                if let timeStr = (obj["time"] as? String) ?? (obj["timestamp"] as? String) {
                    if let iso = AppDate.parseISO8601(timeStr) {
                        return iso.timeIntervalSince1970
                    }
                    if let local = parseLocalBoardTimestamp(timeStr) {
                        return local.timeIntervalSince1970
                    }
                }
                if let num = obj["timestamp"] as? Double, num > 0 {
                    return num
                }
                return nil
            }()

            guard let ts = timestamp, ts > 0 else { continue }

            events.append(ReplayBoardInput(
                seq: seq,
                agent: agent,
                text: text,
                timestamp: ts
            ))
        }

        events.sort { a, b in
            if a.timestamp != b.timestamp { return a.timestamp < b.timestamp }
            return a.seq < b.seq
        }
        return events
    }

    /// Thread-safe pure-ASCII parser for `"yyyy-MM-dd HH:mm:ss"` (with optional `.fff`)
    /// interpreted in `AppDate.gregorian` (local timezone, Gregorian calendar).
    private static func parseLocalBoardTimestamp(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !AppDate.isSentinelTimestamp(s) else { return nil }
        let bytes = Array(s.utf8)
        guard bytes.count >= 19 else { return nil }

        func digit(_ idx: Int) -> Int? {
            let b = bytes[idx]
            guard b >= 48 && b <= 57 else { return nil }
            return Int(b - 48)
        }
        func int2(_ idx: Int) -> Int? {
            guard let a = digit(idx), let b = digit(idx + 1) else { return nil }
            return a * 10 + b
        }
        func int4(_ idx: Int) -> Int? {
            guard let hi = int2(idx), let lo = int2(idx + 2) else { return nil }
            return hi * 100 + lo
        }

        guard bytes[4] == 45, bytes[7] == 45,                         // '-'
              (bytes[10] == 32 || bytes[10] == 84 || bytes[10] == 116), // ' ', 'T', 't'
              bytes[13] == 58, bytes[16] == 58,                       // ':'
              let year = int4(0), year >= 2,
              let month = int2(5), (1...12).contains(month),
              let day = int2(8), (1...31).contains(day),
              let hour = int2(11), (0...23).contains(hour),
              let minute = int2(14), (0...59).contains(minute),
              let second = int2(17), (0...59).contains(second) else {
            return nil
        }

        var fractional: TimeInterval = 0
        var i = 19
        if i < bytes.count {
            guard bytes[i] == 46 || bytes[i] == 44 else { return nil } // '.' or ','
            i += 1
            let fracStart = i
            var nanos: Int64 = 0
            var scaleDigits = 0
            while i < bytes.count, bytes[i] >= 48 && bytes[i] <= 57 {
                if scaleDigits < 9 {
                    nanos = nanos * 10 + Int64(bytes[i] - 48)
                    scaleDigits += 1
                }
                i += 1
            }
            guard i > fracStart, i == bytes.count else { return nil }
            while scaleDigits < 9 {
                nanos *= 10
                scaleDigits += 1
            }
            fractional = Double(nanos) / 1_000_000_000.0
        }

        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = second
        guard let base = AppDate.gregorian.date(from: comps) else { return nil }
        let check = AppDate.gregorian.dateComponents([.year, .month, .day], from: base)
        guard check.year == year, check.month == month, check.day == day else { return nil }
        return base.addingTimeInterval(fractional)
    }

    // MARK: 3. Offline List-Rate Cost Estimator

    /// Standard API-equivalent offline pricing estimator (USD per 1M tokens) by `ModelClass`.
    /// Matches `FALLBACK_PRICING` in `Resources/analyze_usage.py`.
    public static func estimateStepCostUSD(
        modelClass: ModelClass,
        inputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        outputTokens: Int
    ) -> Double {
        let inp = Double(max(0, inputTokens))
        let cr  = Double(max(0, cacheReadTokens))
        let cw  = Double(max(0, cacheWriteTokens))
        let out = Double(max(0, outputTokens))

        let rates: (input: Double, cacheRead: Double, cacheWrite: Double, output: Double)
        switch modelClass {
        case .carbon:   rates = (4.00, 0.20,   5.00,   20.00)
        case .argon:    rates = (4.00, 0.20,   5.00,   20.00)
        case .neon:     rates = (3.00, 0.15,   3.75,   15.00)
        case .hydrogen: rates = (1.50, 0.075,  1.875,   7.50)
        case .flash:    rates = (1.50, 0.15,   1.875,   7.50)
        case .claude:   rates = (3.00, 0.30,   3.75,   15.00)
        case .other:    rates = (0.15, 0.0375, 0.1875,  0.60)
        }

        return (inp * rates.input
            + cr * rates.cacheRead
            + cw * rates.cacheWrite
            + out * rates.output) / 1_000_000.0
    }

    // MARK: 4. Topology Classifier

    public static func classifyTopology(
        meta: ReplayMissionMeta,
        rootSteps: [ReplayRawStep],
        children: [ReplayChildInput],
        boardEvents: [ReplayBoardInput]
    ) -> SessionTopologyKind {
        if let bid = meta.battleId?.trimmingCharacters(in: .whitespacesAndNewlines), !bid.isEmpty {
            return .battle
        }
        if children.contains(where: { $0.kind == .battleBranch }) {
            return .battle
        }
        if meta.hasSwarmDir
            || !boardEvents.isEmpty
            || children.contains(where: { $0.kind == .swarmWorker }) {
            return .swarm
        }
        if rootSteps.contains(where: { $0.toolNames.contains("run_workflow") })
            || children.contains(where: { $0.kind == .workflowStage }) {
            return .dynamicWorkflow
        }
        if !children.isEmpty
            || rootSteps.contains(where: {
                $0.toolNames.contains("invoke_subagent") || $0.toolNames.contains("define_subagent")
            }) {
            return .subagentTree
        }
        return .solo
    }

    // MARK: 5. Timeline Builder

    private struct TimeWarp {
        let anchors: [(raw: Double, warped: Double)]

        init(rawTimestamps: [Double]) {
            let unique = Array(Set(rawTimestamps.filter { $0.isFinite && $0 > 0 })).sorted()
            guard let first = unique.first else {
                self.anchors = []
                return
            }
            var table: [(raw: Double, warped: Double)] = [(first, 0.0)]
            table.reserveCapacity(unique.count)
            var currentWarped = 0.0
            for i in 1..<unique.count {
                let gap = unique[i] - unique[i - 1]
                if gap > ReplayLogic.idleCompressionThresholdSec {
                    currentWarped += ReplayLogic.compressedIdleBreakSec
                } else {
                    currentWarped += gap
                }
                table.append((unique[i], currentWarped))
            }
            self.anchors = table
        }

        func map(_ raw: Double) -> Double {
            guard !anchors.isEmpty else { return 0.0 }
            if raw <= anchors[0].raw { return anchors[0].warped }
            let last = anchors[anchors.count - 1]
            if raw >= last.raw {
                let extra = raw - last.raw
                return last.warped + (extra > ReplayLogic.idleCompressionThresholdSec
                    ? ReplayLogic.compressedIdleBreakSec
                    : extra)
            }
            // Binary search for largest index lo with anchors[lo].raw <= raw
            var lo = 0
            var hi = anchors.count - 1
            while lo + 1 < hi {
                let mid = (lo + hi) / 2
                if anchors[mid].raw <= raw {
                    lo = mid
                } else {
                    hi = mid
                }
            }
            let a = anchors[lo]
            let b = anchors[hi]
            if raw == a.raw { return a.warped }
            if raw == b.raw { return b.warped }
            let span = b.raw - a.raw
            guard span > 0 else { return a.warped }
            let frac = (raw - a.raw) / span
            return a.warped + frac * (b.warped - a.warped)
        }
    }

    public static func buildTimeline(
        meta: ReplayMissionMeta,
        rootSteps: [ReplayRawStep],
        children: [ReplayChildInput],
        boardEvents: [ReplayBoardInput]
    ) -> ReplayTimeline {
        let topology = classifyTopology(
            meta: meta,
            rootSteps: rootSteps,
            children: children,
            boardEvents: boardEvents
        )

        let sortedRoot = sortSteps(rootSteps)
        let sortedBoard = boardEvents.sorted { a, b in
            if a.timestamp != b.timestamp { return a.timestamp < b.timestamp }
            return a.seq < b.seq
        }

        var allTimestamps: [Double] = []
        allTimestamps.reserveCapacity(sortedRoot.count + sortedBoard.count + children.reduce(0) { $0 + $1.steps.count })
        for s in sortedRoot where s.timestamp > 0 { allTimestamps.append(s.timestamp) }
        for c in children {
            for s in c.steps where s.timestamp > 0 { allTimestamps.append(s.timestamp) }
        }
        for b in sortedBoard where b.timestamp > 0 { allTimestamps.append(b.timestamp) }

        guard let minTs = allTimestamps.min() else {
            return ReplayTimeline(
                id: meta.conversationId,
                title: meta.title,
                workspaceLabel: meta.workspaceLabel,
                topology: topology,
                dateLabel: "",
                totalDurationSec: 0,
                tracks: [],
                beams: [],
                totalCostUSD: 0,
                totalTokens: 0,
                retryWasteUSD: 0,
                retryWastePercent: 0,
                humanWaitSec: 0,
                humanWaitPercent: 0,
                totalRetryLoops: 0
            )
        }

        let dateLabel = AppDate.dayKey(Date(timeIntervalSince1970: minTs))
        let warp = TimeWarp(rawTimestamps: allTimestamps)

        // 1. Build Root Track
        let rootName: String
        let rootRole: String
        switch topology {
        case .swarm:
            rootName = "coordinator"
            rootRole = "Coordinator"
        case .dynamicWorkflow:
            rootName = "orchestrator"
            rootRole = "Orchestrator"
        case .subagentTree:
            rootName = "root"
            rootRole = "Root Agent"
        case .battle:
            rootName = "arena"
            rootRole = "Battle Arena"
        case .solo:
            rootName = "session"
            rootRole = "Solo Agent"
        }

        let rootTrack = buildTrack(
            id: meta.conversationId,
            name: rootName,
            roleLabel: rootRole,
            kind: .root,
            parentTrackId: nil,
            depth: 0,
            steps: sortedRoot,
            warp: warp
        )

        var tracks: [ReplayTrack] = [rootTrack]

        // 2. Build Child Tracks (deterministically sorted)
        let sortedChildren = children.sorted { a, b in
            let at = a.steps.map(\.timestamp).min() ?? Double.greatestFiniteMagnitude
            let bt = b.steps.map(\.timestamp).min() ?? Double.greatestFiniteMagnitude
            if at != bt { return at < bt }
            if a.depth != b.depth { return a.depth < b.depth }
            if a.name != b.name { return a.name < b.name }
            return a.conversationId < b.conversationId
        }

        var childFirstRawTs: [String: Double] = [:]
        for child in sortedChildren {
            let childSortedSteps = sortSteps(child.steps)
            if let firstTs = childSortedSteps.first?.timestamp {
                childFirstRawTs[child.conversationId] = firstTs
            }
            let parentId = child.parentId.isEmpty ? meta.conversationId : child.parentId
            let track = buildTrack(
                id: child.conversationId,
                name: child.name,
                roleLabel: child.roleLabel,
                kind: child.kind,
                parentTrackId: parentId,
                depth: max(1, child.depth),
                steps: childSortedSteps,
                warp: warp
            )
            tracks.append(track)
        }

        // 3. Synthesize Workflow Stage Tracks when `run_workflow` calls exist without child workflow tracks
        var beams: [ReplayBeamEvent] = []
        let hasExplicitWorkflowChildren = sortedChildren.contains { $0.kind == .workflowStage }
        if !hasExplicitWorkflowChildren {
            var stageIndex = 0
            for (stepPos, step) in sortedRoot.enumerated() where step.toolNames.contains("run_workflow") {
                let descriptions = step.workflowDescriptions.isEmpty
                    ? ["Stage \(stageIndex + 1)"]
                    : step.workflowDescriptions
                for desc in descriptions {
                    let stageId = "\(meta.conversationId)::wf-\(stageIndex)"
                    let startSec = warp.map(step.timestamp)
                    let nextRawTs: Double = {
                        if stepPos + 1 < sortedRoot.count {
                            return sortedRoot[stepPos + 1].timestamp
                        }
                        return step.timestamp + 15.0
                    }()
                    let rawEndSec = warp.map(nextRawTs)
                    let endSec = max(startSec + 4.0, rawEndSec)

                    let stageModel: ModelClass = {
                        if let m = step.model { return ModelClass.classify(m) }
                        return rootTrack.modelClass
                    }()
                    let isVerify = isVerifyIdentity(name: desc, roleLabel: "Workflow Stage \(stageIndex + 1)")
                    let seg = ReplaySegment(
                        id: "\(stageId)::seg-0",
                        kind: isVerify ? .verify : .work,
                        startSec: startSec,
                        endSec: endSec,
                        stepCount: 1,
                        errorCount: 0,
                        estimatedCostUSD: 0,
                        label: desc
                    )
                    let stageName = shortLabel(desc, maxLen: 24)
                    tracks.append(ReplayTrack(
                        id: stageId,
                        name: stageName,
                        roleLabel: "Workflow Stage \(stageIndex + 1)",
                        kind: .workflowStage,
                        parentTrackId: meta.conversationId,
                        depth: 1,
                        modelClass: stageModel,
                        segments: [seg],
                        totalTokens: 0,
                        outputTokens: 0,
                        estimatedCostUSD: 0,
                        retryCount: 0,
                        retryWasteUSD: 0
                    ))
                    beams.append(ReplayBeamEvent(
                        id: "wf-synth-\(stageIndex)",
                        timestampSec: startSec,
                        fromTrackId: meta.conversationId,
                        toTrackId: stageId,
                        kind: .workflowStage,
                        summary: shortLabel(desc, maxLen: 96)
                    ))
                    stageIndex += 1
                }
            }
        }

        // Lookup tables for beam routing
        var trackById: [String: ReplayTrack] = [:]
        var trackIdByLowerName: [String: String] = [:]
        for t in tracks {
            trackById[t.id] = t
            let lowerName = t.name.lowercased()
            if trackIdByLowerName[lowerName] == nil {
                trackIdByLowerName[lowerName] = t.id
            }
        }
        trackIdByLowerName["coordinator"] = meta.conversationId
        trackIdByLowerName["root"] = meta.conversationId
        trackIdByLowerName["orchestrator"] = meta.conversationId

        // 4. Spawn / Workflow Dispatch Beams for explicit children
        var spawnTimestampsByTarget: [String: Double] = [:]
        for child in sortedChildren {
            let fromId = trackById[child.parentId] != nil ? child.parentId : meta.conversationId
            let toId = child.conversationId
            guard fromId != toId else { continue }
            let rawTs = childFirstRawTs[toId] ?? minTs
            let warpedTs = warp.map(rawTs)
            spawnTimestampsByTarget[toId] = warpedTs
            let beamKind: ReplayBeamKind = (child.kind == .workflowStage) ? .workflowStage : .spawn
            let summary = (child.kind == .workflowStage)
                ? "\(child.roleLabel): \(child.name)"
                : "Spawn \(child.name)"
            beams.append(ReplayBeamEvent(
                id: "spawn-\(toId)",
                timestampSec: warpedTs,
                fromTrackId: fromId,
                toTrackId: toId,
                kind: beamKind,
                summary: shortLabel(summary, maxLen: 96)
            ))
        }

        // 5. Swarm Board Beams (`board.jsonl`)
        for event in sortedBoard {
            let warpedTs = warp.map(event.timestamp)
            let fromId = resolveTrackId(
                token: event.agent,
                trackById: trackById,
                trackIdByLowerName: trackIdByLowerName
            ) ?? meta.conversationId

            let mentions = extractMentions(from: event.text)
            let summary = shortLabel(event.text, maxLen: 120)
            var targetIds: [String] = []
            var seenTargets = Set<String>()

            if mentions.contains("all") {
                for t in tracks where t.id != fromId {
                    if seenTargets.insert(t.id).inserted {
                        targetIds.append(t.id)
                    }
                }
            } else {
                for mention in mentions {
                    if let targetId = resolveTrackId(
                        token: mention,
                        trackById: trackById,
                        trackIdByLowerName: trackIdByLowerName
                    ), targetId != fromId, seenTargets.insert(targetId).inserted {
                        targetIds.append(targetId)
                    }
                }
            }

            if targetIds.isEmpty {
                if fromId != meta.conversationId {
                    targetIds.append(meta.conversationId)
                } else if let fallback = fallbackActiveTrack(
                    excluding: fromId,
                    atSec: warpedTs,
                    tracks: tracks
                ) {
                    targetIds.append(fallback)
                }
            }

            for targetId in targetIds {
                beams.append(ReplayBeamEvent(
                    id: "board-\(event.seq)-\(targetId)",
                    timestampSec: warpedTs,
                    fromTrackId: fromId,
                    toTrackId: targetId,
                    kind: .boardPost,
                    summary: summary
                ))
            }
        }

        // 6. Subagent / Message Tool Beams (`send_message` and non-duplicate `invoke_subagent`)
        var stepBeamIdx = 0
        let allTrackSteps: [(trackId: String, parentId: String?, steps: [ReplayRawStep])] =
            [(meta.conversationId, nil, sortedRoot)]
            + sortedChildren.map { ($0.conversationId, $0.parentId.isEmpty ? meta.conversationId : $0.parentId, sortSteps($0.steps)) }

        for entry in allTrackSteps {
            for step in entry.steps {
                let hasSend = step.toolNames.contains("send_message")
                let hasInvoke = step.toolNames.contains("invoke_subagent")
                guard hasSend || hasInvoke else { continue }

                let warpedTs = warp.map(step.timestamp)
                var resolvedTargets: [String] = []
                var seen = Set<String>()

                for rawTarget in step.subagentTargets {
                    if let tid = resolveTrackId(
                        token: rawTarget,
                        trackById: trackById,
                        trackIdByLowerName: trackIdByLowerName
                    ), tid != entry.trackId, seen.insert(tid).inserted {
                        resolvedTargets.append(tid)
                    }
                }

                if resolvedTargets.isEmpty && hasSend {
                    if let parent = entry.parentId, trackById[parent] != nil, parent != entry.trackId {
                        resolvedTargets.append(parent)
                    } else if let fallback = fallbackActiveTrack(
                        excluding: entry.trackId,
                        atSec: warpedTs,
                        tracks: tracks
                    ) {
                        resolvedTargets.append(fallback)
                    }
                }

                for targetId in resolvedTargets {
                    if hasSend {
                        let targetName = trackById[targetId]?.name ?? targetId
                        beams.append(ReplayBeamEvent(
                            id: "msg-\(entry.trackId)-\(step.stepIndex)-\(stepBeamIdx)",
                            timestampSec: warpedTs,
                            fromTrackId: entry.trackId,
                            toTrackId: targetId,
                            kind: .subagentMessage,
                            summary: "Message -> \(targetName)"
                        ))
                        stepBeamIdx += 1
                    } else if hasInvoke {
                        // Skip if a spawn beam for this target already fired within 5s
                        if let spawnTs = spawnTimestampsByTarget[targetId], abs(spawnTs - warpedTs) <= 5.0 {
                            continue
                        }
                        let targetName = trackById[targetId]?.name ?? targetId
                        beams.append(ReplayBeamEvent(
                            id: "invoke-\(entry.trackId)-\(step.stepIndex)-\(stepBeamIdx)",
                            timestampSec: warpedTs,
                            fromTrackId: entry.trackId,
                            toTrackId: targetId,
                            kind: .spawn,
                            summary: "Invoke \(targetName)"
                        ))
                        stepBeamIdx += 1
                    }
                }
            }
        }

        beams.sort { a, b in
            if a.timestampSec != b.timestampSec { return a.timestampSec < b.timestampSec }
            return a.id < b.id
        }

        // 7. Compute Aggregate Forensics
        let maxSegEnd = tracks.flatMap(\.segments).map(\.endSec).max() ?? 0.0
        let maxBeamTs = beams.map(\.timestampSec).max() ?? 0.0
        let totalDurationSec = max(0.0, max(maxSegEnd, maxBeamTs))

        let totalCostUSD = tracks.reduce(0.0) { $0 + $1.estimatedCostUSD }
        let totalTokens = tracks.reduce(0) { $0 + $1.totalTokens }
        let retryWasteUSD = tracks.reduce(0.0) { $0 + $1.retryWasteUSD }
        let retryWastePercent: Int = totalCostUSD > 0
            ? min(100, max(0, Int((retryWasteUSD / totalCostUSD * 100.0).rounded())))
            : 0

        let humanWaitIntervals: [(Double, Double)] = tracks
            .flatMap(\.segments)
            .filter { $0.kind == .humanWait && $0.endSec > $0.startSec }
            .map { ($0.startSec, $0.endSec) }
        let humanWaitSec = mergedIntervalDuration(humanWaitIntervals)
        let humanWaitPercent: Int = totalDurationSec > 0
            ? min(100, max(0, Int((humanWaitSec / totalDurationSec * 100.0).rounded())))
            : 0

        let totalRetryLoops = tracks.reduce(0) { acc, track in
            acc + track.segments.filter { $0.kind == .retryLoop }.count
        }

        return ReplayTimeline(
            id: meta.conversationId,
            title: meta.title,
            workspaceLabel: meta.workspaceLabel,
            topology: topology,
            dateLabel: dateLabel,
            totalDurationSec: totalDurationSec,
            tracks: tracks,
            beams: beams,
            totalCostUSD: totalCostUSD,
            totalTokens: totalTokens,
            retryWasteUSD: retryWasteUSD,
            retryWastePercent: retryWastePercent,
            humanWaitSec: humanWaitSec,
            humanWaitPercent: humanWaitPercent,
            totalRetryLoops: totalRetryLoops
        )
    }

    private static func sortSteps(_ steps: [ReplayRawStep]) -> [ReplayRawStep] {
        steps
            .filter { $0.timestamp.isFinite && $0.timestamp > 0 }
            .sorted { a, b in
                if a.timestamp != b.timestamp { return a.timestamp < b.timestamp }
                return a.stepIndex < b.stepIndex
            }
    }

    private static func dominantModelClass(for steps: [ReplayRawStep]) -> ModelClass {
        var tokensByClass: [ModelClass: Int] = [:]
        var countByClass: [ModelClass: Int] = [:]
        for step in steps {
            guard let model = step.model, !model.isEmpty else { continue }
            let mc = ModelClass.classify(model)
            let tok = max(0, step.inputTokens) + max(0, step.cacheReadTokens)
                + max(0, step.cacheWriteTokens) + max(0, step.outputTokens)
            tokensByClass[mc, default: 0] += tok
            countByClass[mc, default: 0] += 1
        }
        guard !countByClass.isEmpty else { return .other }
        return ModelClass.allCases.max { a, b in
            let ta = tokensByClass[a] ?? 0
            let tb = tokensByClass[b] ?? 0
            if ta != tb { return ta < tb }
            let ca = countByClass[a] ?? 0
            let cb = countByClass[b] ?? 0
            if ca != cb { return ca < cb }
            // Higher tier wins ties (earlier in ModelClass.allCases)
            let ia = ModelClass.allCases.firstIndex(of: a) ?? 99
            let ib = ModelClass.allCases.firstIndex(of: b) ?? 99
            return ia > ib
        } ?? .other
    }

    private static func isVerifyIdentity(name: String, roleLabel: String) -> Bool {
        let combined = "\(name) \(roleLabel)".lowercased()
        let keywords = ["qa", "verify", "verifier", "test", "audit", "review"]
        return keywords.contains { combined.contains($0) }
    }

    private static func isErrorStep(_ step: ReplayRawStep) -> Bool {
        let st = step.status.uppercased()
        let tp = step.type.uppercased()
        return st == "ERROR" || tp == "ERROR_MESSAGE" || tp == "ERROR"
    }

    private static func buildTrack(
        id: String,
        name: String,
        roleLabel: String,
        kind: ReplayTrackKind,
        parentTrackId: String?,
        depth: Int,
        steps: [ReplayRawStep],
        warp: TimeWarp
    ) -> ReplayTrack {
        let modelClass = dominantModelClass(for: steps)
        let isVerify = isVerifyIdentity(name: name, roleLabel: roleLabel)
        let baseWorkKind: ReplaySegmentKind = isVerify ? .verify : .work

        var totalTokens = 0
        var outputTokens = 0
        var totalCost = 0.0
        var stepCosts: [Double] = []
        stepCosts.reserveCapacity(steps.count)

        for step in steps {
            let inp = max(0, step.inputTokens)
            let cr  = max(0, step.cacheReadTokens)
            let cw  = max(0, step.cacheWriteTokens)
            let out = max(0, step.outputTokens)
            totalTokens += inp + cr + cw + out
            outputTokens += out
            let stepModel = step.model.map(ModelClass.classify) ?? modelClass
            let cost = estimateStepCostUSD(
                modelClass: stepModel,
                inputTokens: inp,
                cacheReadTokens: cr,
                cacheWriteTokens: cw,
                outputTokens: out
            )
            stepCosts.append(cost)
            totalCost += cost
        }

        // 1. Detect Retry Loop clusters: 2+ error steps within 180s on this track
        var errorIndices: [Int] = []
        for i in 0..<steps.count where isErrorStep(steps[i]) {
            errorIndices.append(i)
        }

        var retryRanges: [(startIdx: Int, endIdx: Int, errorCount: Int)] = []
        if !errorIndices.isEmpty {
            var clusterStart = errorIndices[0]
            var clusterEnd = errorIndices[0]
            var clusterCount = 1
            for k in 1..<errorIndices.count {
                let idx = errorIndices[k]
                let prevIdx = errorIndices[k - 1]
                if steps[idx].timestamp - steps[prevIdx].timestamp <= retryClusterGapSec {
                    clusterEnd = idx
                    clusterCount += 1
                } else {
                    if clusterCount >= 2 {
                        retryRanges.append((clusterStart, clusterEnd, clusterCount))
                    }
                    clusterStart = idx
                    clusterEnd = idx
                    clusterCount = 1
                }
            }
            if clusterCount >= 2 {
                retryRanges.append((clusterStart, clusterEnd, clusterCount))
            }
        }

        var retryClusterAtStep = Array<Int?>(repeating: nil, count: steps.count)
        for (cIdx, range) in retryRanges.enumerated() {
            for sIdx in range.startIdx...range.endIdx {
                retryClusterAtStep[sIdx] = cIdx
            }
        }

        // 2. Partition steps into segments (work/verify, humanWait, retryLoop)
        struct DraftSegment {
            var kind: ReplaySegmentKind
            var startSec: Double
            var endSec: Double
            var stepCount: Int
            var errorCount: Int
            var cost: Double
            var label: String?
        }

        var drafts: [DraftSegment] = []
        var openWork: DraftSegment? = nil

        func flushWork() {
            if let w = openWork {
                drafts.append(w)
                openWork = nil
            }
        }

        var i = 0
        while i < steps.count {
            // Check inter-step gap before step `i`
            if i > 0 {
                let prev = steps[i - 1]
                let curr = steps[i]
                let rawGap = curr.timestamp - prev.timestamp

                if curr.type.uppercased() == "USER_INPUT"
                    && prev.type.uppercased() != "USER_INPUT"
                    && rawGap >= humanWaitMinSec
                    && rawGap <= humanWaitMaxSec {
                    flushWork()
                    let wStart = warp.map(prev.timestamp)
                    let wEnd = warp.map(curr.timestamp)
                    if wEnd > wStart {
                        drafts.append(DraftSegment(
                            kind: .humanWait,
                            startSec: wStart,
                            endSec: wEnd,
                            stepCount: 0,
                            errorCount: 0,
                            cost: 0,
                            label: "Human Wait"
                        ))
                    }
                } else if rawGap > trackBurstSplitGapSec {
                    flushWork()
                }
            }

            if let cIdx = retryClusterAtStep[i] {
                flushWork()
                let range = retryRanges[cIdx]
                let startSec = warp.map(steps[range.startIdx].timestamp)
                let endSec = warp.map(steps[range.endIdx].timestamp)
                var costSum = 0.0
                for sIdx in range.startIdx...range.endIdx {
                    costSum += stepCosts[sIdx]
                }
                drafts.append(DraftSegment(
                    kind: .retryLoop,
                    startSec: startSec,
                    endSec: endSec,
                    stepCount: range.endIdx - range.startIdx + 1,
                    errorCount: range.errorCount,
                    cost: costSum,
                    label: "\(range.errorCount)x retry loop"
                ))
                i = range.endIdx + 1
            } else {
                let stepSec = warp.map(steps[i].timestamp)
                let errInc = isErrorStep(steps[i]) ? 1 : 0
                if var w = openWork {
                    w.endSec = max(w.endSec, stepSec)
                    w.stepCount += 1
                    w.errorCount += errInc
                    w.cost += stepCosts[i]
                    openWork = w
                } else {
                    openWork = DraftSegment(
                        kind: baseWorkKind,
                        startSec: stepSec,
                        endSec: stepSec,
                        stepCount: 1,
                        errorCount: errInc,
                        cost: stepCosts[i],
                        label: isVerify ? "Verify" : nil
                    )
                }
                i += 1
            }
        }
        flushWork()

        // 3. Ensure zero-duration non-wait segments get a visible span without overlapping next segment
        var segments: [ReplaySegment] = []
        segments.reserveCapacity(drafts.count)
        for idx in 0..<drafts.count {
            let d = drafts[idx]
            var endSec = d.endSec
            if d.kind != .humanWait && endSec - d.startSec < minVisualSegmentSec {
                let desired = d.startSec + minVisualSegmentSec
                if idx + 1 < drafts.count {
                    endSec = max(endSec, min(desired, drafts[idx + 1].startSec))
                } else {
                    endSec = desired
                }
            }
            segments.append(ReplaySegment(
                id: "\(id)::seg-\(idx)",
                kind: d.kind,
                startSec: d.startSec,
                endSec: endSec,
                stepCount: d.stepCount,
                errorCount: d.errorCount,
                estimatedCostUSD: d.cost,
                label: d.label
            ))
        }

        let retrySegments = segments.filter { $0.kind == .retryLoop }
        let retryCount = retrySegments.reduce(0) { $0 + $1.errorCount }
        let retryWasteUSD = retrySegments.reduce(0.0) { $0 + $1.estimatedCostUSD }

        return ReplayTrack(
            id: id,
            name: name,
            roleLabel: roleLabel,
            kind: kind,
            parentTrackId: parentTrackId,
            depth: depth,
            modelClass: modelClass,
            segments: segments,
            totalTokens: totalTokens,
            outputTokens: outputTokens,
            estimatedCostUSD: totalCost,
            retryCount: retryCount,
            retryWasteUSD: retryWasteUSD
        )
    }

    private static func resolveTrackId(
        token: String,
        trackById: [String: ReplayTrack],
        trackIdByLowerName: [String: String]
    ) -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trackById[trimmed] != nil { return trimmed }
        let lower = trimmed.lowercased()
        if let exact = trackIdByLowerName[lower] { return exact }
        // Prefix match for shortened IDs or role prefixes
        for (name, id) in trackIdByLowerName where name.hasPrefix(lower) || lower.hasPrefix(name) {
            return id
        }
        return nil
    }

    private static func extractMentions(from text: String) -> [String] {
        var result: [String] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == "@" {
                let prevIsBoundary: Bool = (i == 0) || !isMentionChar(chars[i - 1])
                if prevIsBoundary {
                    var j = i + 1
                    while j < chars.count && isMentionChar(chars[j]) {
                        j += 1
                    }
                    if j > i + 1 {
                        let token = String(chars[(i + 1)..<j]).lowercased()
                        result.append(token)
                    }
                    i = j
                    continue
                }
            }
            i += 1
        }
        return result
    }

    private static func isMentionChar(_ ch: Character) -> Bool {
        guard let ascii = ch.asciiValue else { return false }
        return (ascii >= 97 && ascii <= 122) // a-z
            || (ascii >= 65 && ascii <= 90)  // A-Z
            || (ascii >= 48 && ascii <= 57)  // 0-9
            || ascii == 45                   // -
            || ascii == 95                   // _
    }

    private static func fallbackActiveTrack(
        excluding senderId: String,
        atSec sec: Double,
        tracks: [ReplayTrack]
    ) -> String? {
        let candidates = tracks.filter { $0.id != senderId }
        guard !candidates.isEmpty else { return nil }
        if let active = candidates.first(where: { track in
            track.segments.contains { sec >= $0.startSec && sec <= $0.endSec }
        }) {
            return active.id
        }
        return candidates.first?.id
    }

    private static func shortLabel(_ raw: String, maxLen: Int) -> String {
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if collapsed.count <= maxLen { return collapsed }
        return String(collapsed.prefix(max(1, maxLen - 1))) + "…"
    }

    private static func mergedIntervalDuration(_ intervals: [(Double, Double)]) -> Double {
        let valid = intervals.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        guard let first = valid.first else { return 0.0 }
        var total = 0.0
        var curStart = first.0
        var curEnd = first.1
        for iv in valid.dropFirst() {
            if iv.0 <= curEnd {
                curEnd = max(curEnd, iv.1)
            } else {
                total += (curEnd - curStart)
                curStart = iv.0
                curEnd = iv.1
            }
        }
        total += (curEnd - curStart)
        return total
    }

    // MARK: 6. Five-Topology Radar Layout Engine

    /// Computes clean, overlap-free normalized coordinates strictly in `[0.14...0.86]`
    /// tailored to each of the 5 `SessionTopologyKind` topologies.
    public static func radarLayout(timeline: ReplayTimeline) -> [ReplayRadarNode] {
        let tracks = timeline.tracks
        guard !tracks.isEmpty else { return [] }

        var coords: [String: (x: Double, y: Double)] = [:]

        switch timeline.topology {
        case .solo:
            coords = layoutSolo(tracks: tracks)
        case .swarm:
            coords = layoutSwarm(tracks: tracks)
        case .dynamicWorkflow:
            coords = layoutDynamicWorkflow(tracks: tracks)
        case .subagentTree:
            coords = layoutSubagentTree(tracks: tracks)
        case .battle:
            coords = layoutBattle(tracks: tracks)
        }

        return tracks.map { track in
            let pt = coords[track.id] ?? (0.5, 0.5)
            return ReplayRadarNode(
                id: track.id,
                name: track.name,
                kind: track.kind,
                depth: track.depth,
                normX: clampRadar(pt.x),
                normY: clampRadar(pt.y),
                parentId: track.parentTrackId,
                estimatedCostUSD: track.estimatedCostUSD,
                modelClass: track.modelClass
            )
        }
    }

    private static func clampRadar(_ v: Double) -> Double {
        min(radarMaxCoord, max(radarMinCoord, v))
    }

    private static func layoutSolo(tracks: [ReplayTrack]) -> [String: (x: Double, y: Double)] {
        var out: [String: (x: Double, y: Double)] = [:]
        out[tracks[0].id] = (x: 0.50, y: 0.50)
        if tracks.count > 1 {
            let others = Array(tracks.dropFirst())
            placeOnRings(tracks: others, into: &out)
        }
        return out
    }

    private static func layoutSwarm(tracks: [ReplayTrack]) -> [String: (x: Double, y: Double)] {
        var out: [String: (x: Double, y: Double)] = [:]
        let root = tracks.first { $0.kind == .root } ?? tracks[0]
        out[root.id] = (x: 0.50, y: 0.50)
        let workers = tracks.filter { $0.id != root.id }
        placeOnRings(tracks: workers, into: &out)
        return out
    }

    private static func placeOnRings(
        tracks: [ReplayTrack],
        into out: inout [String: (x: Double, y: Double)]
    ) {
        let n = tracks.count
        guard n > 0 else { return }
        if n <= 8 {
            let radius = 0.32
            for (idx, track) in tracks.enumerated() {
                let angle = -Double.pi * 0.5 + (Double(idx) / Double(n)) * 2.0 * Double.pi
                out[track.id] = (x: 0.50 + radius * cos(angle), y: 0.50 + radius * sin(angle))
            }
        } else {
            // Concentric dual rings to guarantee generous separation for 9+ tracks
            let innerCount = min(6, n / 2)
            let outerCount = n - innerCount
            let innerRadius = 0.21
            let outerRadius = 0.35
            for idx in 0..<innerCount {
                let angle = -Double.pi * 0.5 + (Double(idx) / Double(innerCount)) * 2.0 * Double.pi
                out[tracks[idx].id] = (x: 0.50 + innerRadius * cos(angle), y: 0.50 + innerRadius * sin(angle))
            }
            let outerStep = (2.0 * Double.pi) / Double(max(1, outerCount))
            for j in 0..<outerCount {
                let angle = -Double.pi * 0.5 + (Double(j) + 0.5) * outerStep
                out[tracks[innerCount + j].id] = (x: 0.50 + outerRadius * cos(angle), y: 0.50 + outerRadius * sin(angle))
            }
        }
    }

    private static func layoutDynamicWorkflow(tracks: [ReplayTrack]) -> [String: (x: Double, y: Double)] {
        var out: [String: (x: Double, y: Double)] = [:]
        let root = tracks.first { $0.kind == .root } ?? tracks[0]
        let stages = tracks.filter { $0.id != root.id }
        guard !stages.isEmpty else {
            out[root.id] = (x: 0.50, y: 0.50)
            return out
        }

        out[root.id] = (x: 0.18, y: 0.50)

        // Group stages into temporal waves (stages starting within 10s of a wave's anchor share a wave)
        let orderedStages = stages.sorted { a, b in
            let sa = a.segments.map(\.startSec).min() ?? 0
            let sb = b.segments.map(\.startSec).min() ?? 0
            if sa != sb { return sa < sb }
            return a.id < b.id
        }

        var waves: [[ReplayTrack]] = []
        var waveAnchorSec: Double = -Double.greatestFiniteMagnitude
        for stage in orderedStages {
            let startSec = stage.segments.map(\.startSec).min() ?? 0
            if waves.isEmpty || (startSec - waveAnchorSec) > 10.0 {
                waves.append([stage])
                waveAnchorSec = startSec
            } else {
                waves[waves.count - 1].append(stage)
            }
        }

        let waveCount = waves.count
        for (wIdx, wave) in waves.enumerated() {
            let colX: Double
            if waveCount == 1 {
                colX = 0.72
            } else {
                let frac = Double(wIdx) / Double(waveCount - 1)
                colX = 0.36 + frac * 0.48
            }
            let k = wave.count
            for (rIdx, stage) in wave.enumerated() {
                let y: Double
                if k == 1 {
                    y = 0.50
                } else {
                    let frac = Double(rIdx) / Double(k - 1)
                    y = 0.18 + frac * 0.64
                }
                let xStagger = (k > 6) ? ((rIdx % 2 == 0) ? -0.025 : 0.025) : 0.0
                out[stage.id] = (x: clampRadar(colX + xStagger), y: clampRadar(y))
            }
        }
        return out
    }

    private static func layoutSubagentTree(tracks: [ReplayTrack]) -> [String: (x: Double, y: Double)] {
        var out: [String: (x: Double, y: Double)] = [:]
        var byDepth: [Int: [ReplayTrack]] = [:]
        for track in tracks {
            byDepth[max(0, track.depth), default: []].append(track)
        }
        let depths = byDepth.keys.sorted()
        let levelCount = depths.count

        for (levelIdx, depth) in depths.enumerated() {
            let baseY: Double
            if levelCount == 1 {
                baseY = 0.50
            } else {
                let frac = Double(levelIdx) / Double(levelCount - 1)
                baseY = 0.16 + frac * 0.68
            }

            // Order level nodes by parent's X to minimize edge crossings
            let levelTracks = (byDepth[depth] ?? []).sorted { a, b in
                let pxA = a.parentTrackId.flatMap { out[$0]?.x } ?? 0.50
                let pxB = b.parentTrackId.flatMap { out[$0]?.x } ?? 0.50
                if pxA != pxB { return pxA < pxB }
                return a.id < b.id
            }

            let count = levelTracks.count
            for (i, track) in levelTracks.enumerated() {
                let x: Double
                if count == 1 {
                    x = 0.50
                } else {
                    let frac = Double(i) / Double(count - 1)
                    x = 0.16 + frac * 0.68
                }
                let yStagger = (count > 6) ? ((i % 2 == 0) ? -0.025 : 0.025) : 0.0
                out[track.id] = (x: clampRadar(x), y: clampRadar(baseY + yStagger))
            }
        }
        return out
    }

    private static func layoutBattle(tracks: [ReplayTrack]) -> [String: (x: Double, y: Double)] {
        var out: [String: (x: Double, y: Double)] = [:]
        let root = tracks.first { $0.kind == .root } ?? tracks[0]
        let branches = tracks.filter { $0.id != root.id }
        guard !branches.isEmpty else {
            out[root.id] = (x: 0.50, y: 0.50)
            return out
        }

        out[root.id] = (x: 0.50, y: 0.18)

        let count = branches.count
        if count == 1 {
            out[branches[0].id] = (x: 0.50, y: 0.68)
        } else if count == 2 {
            out[branches[0].id] = (x: 0.24, y: 0.66)
            out[branches[1].id] = (x: 0.76, y: 0.66)
        } else if count <= 6 {
            for (i, branch) in branches.enumerated() {
                let t = Double(i) / Double(count - 1)
                let x = 0.16 + t * 0.68
                // Gentle downward arena arc
                let arcDip = sin(t * Double.pi) * 0.12
                let y = 0.60 + arcDip
                out[branch.id] = (x: clampRadar(x), y: clampRadar(y))
            }
        } else {
            let topCount = (count + 1) / 2
            let botCount = count - topCount
            for i in 0..<topCount {
                let frac = Double(i) / Double(max(1, topCount - 1))
                let x = 0.16 + frac * 0.68
                out[branches[i].id] = (x: clampRadar(x), y: 0.52)
            }
            for j in 0..<botCount {
                let x: Double
                if botCount == 1 {
                    x = 0.50
                } else {
                    let frac = Double(j) / Double(botCount - 1)
                    x = 0.20 + frac * 0.60
                }
                out[branches[topCount + j].id] = (x: clampRadar(x), y: 0.80)
            }
        }
        return out
    }

    // MARK: 7. Adaptive Pacing, Idle Forensics & Key Event Extraction

    /// Target wall-clock playback duration (at `1x`) for timelines longer than 20 seconds.
    public static let targetBasePlaybackSec: Double = 20.0

    /// Returns the effective `1x` wall-clock playback duration for a timeline:
    /// short sessions play 1:1 (clamped to >= 1s), while longer sessions normalize smoothly to 20s.
    public static func effectivePlaybackDurationSec(timelineDurationSec: Double) -> Double {
        guard timelineDurationSec.isFinite else { return 1.0 }
        return min(max(timelineDurationSec, 1.0), targetBasePlaybackSec)
    }

    /// Returns the effective real-time speed multiplier (e.g. `180.0` for a 1h timeline at `1x`).
    public static func effectiveRealTimeMultiplier(
        timelineDurationSec: Double,
        speed: ReplaySpeed
    ) -> Double {
        guard timelineDurationSec.isFinite, timelineDurationSec > 0 else { return 0.0 }
        let baseDur = effectivePlaybackDurationSec(timelineDurationSec: timelineDurationSec)
        return (timelineDurationSec / baseDur) * speed.rawValue
    }

    /// Playback-normalized beam visibility window in timeline seconds (~0.95s of `1x` playback).
    public static func beamWindowSec(timelineDurationSec: Double) -> Double {
        let totalDur = timelineDurationSec.isFinite ? max(0.0, timelineDurationSec) : 0.0
        let baseDur = effectivePlaybackDurationSec(timelineDurationSec: totalDur)
        return max(2.0, totalDur * (0.95 / max(1.0, baseDur)))
    }

    /// Returns `true` iff at `progress` NO track has an active `.work`, `.retryLoop`, or `.verify`
    /// segment covering `currentSec`, AND NO `ReplayBeamEvent` is within the active beam window.
    public static func isIdleDeadAir(timeline: ReplayTimeline, progress: Double) -> Bool {
        guard timeline.totalDurationSec.isFinite, timeline.totalDurationSec > 0 else {
            return false
        }
        let clamped = progress.isFinite ? min(1.0, max(0.0, progress)) : 0.0
        let currentSec = clamped * timeline.totalDurationSec

        for track in timeline.tracks {
            for seg in track.segments {
                switch seg.kind {
                case .work, .retryLoop, .verify:
                    if currentSec >= seg.startSec && currentSec <= seg.endSec {
                        return false
                    }
                case .humanWait:
                    break
                }
            }
        }

        let beamWindow = beamWindowSec(timelineDurationSec: timeline.totalDurationSec)
        for beam in timeline.beams {
            if currentSec >= beam.timestampSec && currentSec <= beam.timestampSec + beamWindow {
                return false
            }
        }

        return true
    }

    /// Smallest start timestamp strictly greater than `currentSec` among all non-idle segments
    /// (`.work`, `.retryLoop`, `.verify`) and beam events.
    internal static func nextNonIdleBoundarySec(
        after currentSec: Double,
        in timeline: ReplayTimeline
    ) -> Double? {
        var earliest: Double? = nil

        for track in timeline.tracks {
            for seg in track.segments where seg.kind != .humanWait {
                if seg.startSec > currentSec {
                    if let cur = earliest {
                        if seg.startSec < cur { earliest = seg.startSec }
                    } else {
                        earliest = seg.startSec
                    }
                }
            }
        }

        for beam in timeline.beams where beam.timestampSec > currentSec {
            if let cur = earliest {
                if beam.timestampSec < cur { earliest = beam.timestampSec }
            } else {
                earliest = beam.timestampSec
            }
        }

        return earliest
    }

    /// Extracts crisp, deduplicated key moments sorted ascending by `progress`:
    /// every `.retryLoop` start (highest priority), every non-root track's first segment start
    /// (`.workerSpawn` or `.workflowWave`), and beam events spaced at least `0.03` progress apart
    /// (dropping lower-priority events within `0.02` progress of a higher-priority event).
    public static func keyEvents(for timeline: ReplayTimeline) -> [ReplayKeyEvent] {
        guard timeline.totalDurationSec.isFinite, timeline.totalDurationSec > 0 else {
            return []
        }
        let totalDur = timeline.totalDurationSec

        // Tier 1 (highest priority): every .retryLoop start
        var retryEvents: [ReplayKeyEvent] = []
        for track in timeline.tracks {
            for seg in track.segments where seg.kind == .retryLoop {
                let p = min(1.0, max(0.0, seg.startSec / totalDur))
                let detail = seg.label ?? "\(max(1, seg.errorCount))x retry loop"
                retryEvents.append(ReplayKeyEvent(
                    id: "retry-\(seg.id)",
                    progress: p,
                    timestampSec: seg.startSec,
                    kind: .retryStart,
                    trackId: track.id,
                    label: "\(track.name) · \(detail)"
                ))
            }
        }

        // Tier 2: every non-root track's first segment start, excluding those within 0.02 of a retryStart
        var trackStartEvents: [ReplayKeyEvent] = []
        for track in timeline.tracks where track.kind != .root {
            guard let firstSeg = track.segments.min(by: { $0.startSec < $1.startSec }) else {
                continue
            }
            let p = min(1.0, max(0.0, firstSeg.startSec / totalDur))
            if retryEvents.contains(where: { abs($0.progress - p) <= 0.02 }) {
                continue
            }
            let kind: ReplayKeyEventKind = (track.kind == .workflowStage) ? .workflowWave : .workerSpawn
            trackStartEvents.append(ReplayKeyEvent(
                id: "track-\(track.id)",
                progress: p,
                timestampSec: firstSeg.startSec,
                kind: kind,
                trackId: track.id,
                label: track.name
            ))
        }

        let higherPriorityEvents = retryEvents + trackStartEvents

        // Tier 3: beam bursts spaced >= 0.03 apart, excluding those within 0.02 of any higher-priority event
        let sortedBeams = timeline.beams.sorted { a, b in
            if a.timestampSec != b.timestampSec { return a.timestampSec < b.timestampSec }
            return a.id < b.id
        }
        var beamEvents: [ReplayKeyEvent] = []
        var lastAcceptedBeamProgress: Double? = nil
        for beam in sortedBeams {
            let p = min(1.0, max(0.0, beam.timestampSec / totalDur))
            if higherPriorityEvents.contains(where: { abs($0.progress - p) <= 0.02 }) {
                continue
            }
            if let lastP = lastAcceptedBeamProgress, (p - lastP) < 0.03 {
                continue
            }
            lastAcceptedBeamProgress = p
            let label = beam.summary.isEmpty
                ? "\(beam.fromTrackId) → \(beam.toTrackId)"
                : beam.summary
            beamEvents.append(ReplayKeyEvent(
                id: "beam-\(beam.id)",
                progress: p,
                timestampSec: beam.timestampSec,
                kind: .beamBurst,
                trackId: beam.fromTrackId,
                label: label
            ))
        }

        return (higherPriorityEvents + beamEvents).sorted { a, b in
            if a.progress != b.progress { return a.progress < b.progress }
            let pa = keyEventPriority(a.kind)
            let pb = keyEventPriority(b.kind)
            if pa != pb { return pa > pb }
            if a.timestampSec != b.timestampSec { return a.timestampSec < b.timestampSec }
            return a.id < b.id
        }
    }

    private static func keyEventPriority(_ kind: ReplayKeyEventKind) -> Int {
        switch kind {
        case .retryStart:   return 4
        case .workerSpawn:  return 3
        case .workflowWave: return 3
        case .beamBurst:    return 1
        }
    }

    internal static func normalizeDegrees(_ deg: Double) -> Double {
        guard deg.isFinite else { return 0.0 }
        let rem = deg.truncatingRemainder(dividingBy: 360.0)
        let positive = rem < 0 ? rem + 360.0 : rem
        if positive >= 360.0 || positive == 0.0 { return 0.0 }
        return positive
    }

    // MARK: 8. Playhead Frame Evaluator

    public static func evaluateFrame(
        timeline: ReplayTimeline,
        progress: Double,
        sweepPhaseDeg: Double? = nil
    ) -> ReplayPlayheadSnapshot {
        let clampedProgress = progress.isFinite ? min(1.0, max(0.0, progress)) : 0.0
        let currentSec = clampedProgress * max(0.0, timeline.totalDurationSec)
        let sweepAngleDeg: Double
        if let phase = sweepPhaseDeg {
            sweepAngleDeg = normalizeDegrees(phase)
        } else {
            sweepAngleDeg = normalizeDegrees(clampedProgress * 720.0)
        }

        var trackStates: [String: ReplayTrackLiveState] = [:]
        var activeRetryCandidates: [(track: ReplayTrack, segment: ReplaySegment)] = []

        for track in timeline.tracks {
            guard !track.segments.isEmpty else {
                trackStates[track.id] = .idle
                continue
            }

            let matching = track.segments.filter { currentSec >= $0.startSec && currentSec <= $0.endSec }
            if !matching.isEmpty {
                let chosen = matching.max { segmentPriority($0.kind) < segmentPriority($1.kind) }!
                switch chosen.kind {
                case .retryLoop:
                    trackStates[track.id] = .retrying
                    activeRetryCandidates.append((track, chosen))
                case .verify:
                    trackStates[track.id] = .verify
                case .work:
                    trackStates[track.id] = .working
                case .humanWait:
                    trackStates[track.id] = .waiting
                }
            } else if let lastEnd = track.segments.map(\.endSec).max(), currentSec > lastEnd {
                trackStates[track.id] = .done
            } else {
                trackStates[track.id] = .idle
            }
        }

        let beamWindow = beamWindowSec(timelineDurationSec: timeline.totalDurationSec)
        var activeBeams: [ReplayActiveBeam] = []
        for beam in timeline.beams {
            if currentSec >= beam.timestampSec && currentSec <= beam.timestampSec + beamWindow {
                let p = min(1.0, max(0.0, (currentSec - beam.timestampSec) / beamWindow))
                activeBeams.append(ReplayActiveBeam(
                    id: beam.id,
                    fromTrackId: beam.fromTrackId,
                    toTrackId: beam.toTrackId,
                    kind: beam.kind,
                    progress: p,
                    summary: beam.summary
                ))
            }
        }

        let activeFault: ReplayFaultCallout? = activeRetryCandidates
            .max { a, b in
                if a.segment.estimatedCostUSD != b.segment.estimatedCostUSD {
                    return a.segment.estimatedCostUSD < b.segment.estimatedCostUSD
                }
                return a.segment.errorCount < b.segment.errorCount
            }
            .map { best in
                ReplayFaultCallout(
                    trackId: best.track.id,
                    trackName: best.track.name,
                    retryCount: max(best.segment.errorCount, best.track.retryCount > 0 ? best.segment.errorCount : 0),
                    wasteUSD: best.segment.estimatedCostUSD
                )
            }

        return ReplayPlayheadSnapshot(
            progress: clampedProgress,
            currentSec: currentSec,
            trackStates: trackStates,
            activeBeams: activeBeams,
            activeFault: activeFault,
            sweepAngleDeg: sweepAngleDeg
        )
    }

    private static func segmentPriority(_ kind: ReplaySegmentKind) -> Int {
        switch kind {
        case .retryLoop: return 4
        case .verify:    return 3
        case .work:      return 2
        case .humanWait: return 1
        }
    }

    // MARK: 9. Clock Formatter

    /// Formats seconds as `"MM:SS"` (under 1 hour) or `"H:MM:SS"` (1 hour and above).
    public static func formatClock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        }
        return String(format: "%02d:%02d", mins, secs)
    }
}

// MARK: - Pure Black Box Store State Machine (Anti-Split-Brain)

public enum ReplayIndexPhase: Equatable, Sendable {
    case idle
    case loading(cached: [ReplayMissionSummary], generation: Int)
    case loaded([ReplayMissionSummary], loadedAt: Date)

    public var missions: [ReplayMissionSummary] {
        switch self {
        case .idle:
            return []
        case .loading(let cached, _):
            return cached
        case .loaded(let missions, _):
            return missions
        }
    }

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    public func isFresh(
        now: Date,
        ttl: TimeInterval = ReplayStoreMachine.indexFreshnessTTL
    ) -> Bool {
        guard case .loaded(let missions, let loadedAt) = self, !missions.isEmpty else {
            return false
        }
        let elapsed = now.timeIntervalSince(loadedAt)
        return elapsed >= 0 && elapsed < ttl
    }
}

public enum ReplayTimelinePhase: Equatable, Sendable {
    case idle
    case loading(missionId: String, generation: Int)
    case loaded(ReplayTimeline)
    case unavailable(missionId: String)

    public var timeline: ReplayTimeline? {
        if case .loaded(let tl) = self { return tl }
        return nil
    }

    public var missionId: String? {
        switch self {
        case .idle:
            return nil
        case .loading(let id, _):
            return id
        case .loaded(let tl):
            return tl.id
        case .unavailable(let id):
            return id
        }
    }

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    public var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

public struct ReplayStoreState: Equatable, Sendable {
    public var indexPhase: ReplayIndexPhase
    public var timelinePhase: ReplayTimelinePhase
    public var selectedMissionId: String?
    public var indexGeneration: Int
    public var timelineGeneration: Int
    public var pendingPreferredMissionId: String?

    public init(
        indexPhase: ReplayIndexPhase = .idle,
        timelinePhase: ReplayTimelinePhase = .idle,
        selectedMissionId: String? = nil,
        indexGeneration: Int = 0,
        timelineGeneration: Int = 0,
        pendingPreferredMissionId: String? = nil
    ) {
        self.indexPhase = indexPhase
        self.timelinePhase = timelinePhase
        self.selectedMissionId = selectedMissionId
        self.indexGeneration = indexGeneration
        self.timelineGeneration = timelineGeneration
        self.pendingPreferredMissionId = pendingPreferredMissionId
    }

    public var missions: [ReplayMissionSummary] { indexPhase.missions }
    public var activeReplay: ReplayTimeline? { timelinePhase.timeline }
    public var isIndexLoading: Bool { indexPhase.isLoading }
    public var isTimelineLoading: Bool { timelinePhase.isLoading }
    public var isTimelineUnavailable: Bool { timelinePhase.isUnavailable }
}

public enum ReplayStoreEvent: Equatable, Sendable {
    case openBlackBox(preferredMissionId: String? = nil, force: Bool = false, now: Date)
    case indexLoaded(generation: Int, missions: [ReplayMissionSummary], now: Date)
    case selectMission(id: String, force: Bool = false)
    case timelineLoaded(generation: Int, missionId: String, timeline: ReplayTimeline?)
    case clearSelection
}

public enum ReplayStoreEffect: Equatable, Sendable {
    case scanIndex(generation: Int)
    case loadTimeline(missionId: String, generation: Int)
}

public enum ReplayStoreMachine {

    /// Default freshness window for cached mission index scans.
    public static let indexFreshnessTTL: TimeInterval = 5.0

    @discardableResult
    public static func reduce(
        _ state: inout ReplayStoreState,
        event: ReplayStoreEvent,
        indexTTL: TimeInterval = indexFreshnessTTL
    ) -> [ReplayStoreEffect] {
        switch event {
        case .openBlackBox(let rawPreferred, let force, let now):
            let preferred = (rawPreferred?.isEmpty == false) ? rawPreferred : nil
            var effects: [ReplayStoreEffect] = []

            if !force && state.indexPhase.isFresh(now: now, ttl: indexTTL) {
                state.pendingPreferredMissionId = nil
                if let sid = preferred {
                    if let eff = startTimelineLoad(&state, missionId: sid, force: false) {
                        effects.append(eff)
                    }
                } else if let current = state.selectedMissionId,
                          state.missions.contains(where: { $0.id == current }) {
                    if state.timelinePhase == .idle || state.timelinePhase.missionId != current {
                        if let eff = startTimelineLoad(&state, missionId: current, force: false) {
                            effects.append(eff)
                        }
                    }
                } else if let first = state.missions.first {
                    if let eff = startTimelineLoad(&state, missionId: first.id, force: false) {
                        effects.append(eff)
                    }
                } else {
                    clearTimelineSelection(&state)
                }
                return effects
            }

            // Index is not fresh (or force == true): deduplicate concurrent non-forced scans.
            if force || !state.indexPhase.isLoading {
                state.indexGeneration += 1
                let gen = state.indexGeneration
                state.indexPhase = .loading(cached: state.missions, generation: gen)
                effects.append(.scanIndex(generation: gen))
            }

            if let sid = preferred {
                state.pendingPreferredMissionId = sid
                if let eff = startTimelineLoad(&state, missionId: sid, force: force) {
                    effects.append(eff)
                }
            } else {
                state.pendingPreferredMissionId = nil
                if force, let current = state.selectedMissionId {
                    if let eff = startTimelineLoad(&state, missionId: current, force: true) {
                        effects.append(eff)
                    }
                }
            }
            return effects

        case .indexLoaded(let generation, let missions, let now):
            guard generation == state.indexGeneration else { return [] }
            state.indexPhase = .loaded(missions, loadedAt: now)
            let preferred = state.pendingPreferredMissionId
            state.pendingPreferredMissionId = nil

            guard let first = missions.first else {
                clearTimelineSelection(&state)
                return []
            }

            if let pref = preferred {
                if missions.contains(where: { $0.id == pref }) {
                    if let eff = startTimelineLoad(&state, missionId: pref, force: false) {
                        return [eff]
                    }
                    return []
                } else {
                    if let eff = startTimelineLoad(&state, missionId: first.id, force: false) {
                        return [eff]
                    }
                    return []
                }
            }

            if let current = state.selectedMissionId,
               missions.contains(where: { $0.id == current }) {
                if state.timelinePhase == .idle || state.timelinePhase.missionId != current {
                    if let eff = startTimelineLoad(&state, missionId: current, force: false) {
                        return [eff]
                    }
                }
                return []
            }

            if let eff = startTimelineLoad(&state, missionId: first.id, force: false) {
                return [eff]
            }
            return []

        case .selectMission(let id, let force):
            guard !id.isEmpty else { return [] }
            state.pendingPreferredMissionId = nil
            if let eff = startTimelineLoad(&state, missionId: id, force: force) {
                return [eff]
            }
            return []

        case .timelineLoaded(let generation, let missionId, let timeline):
            guard generation == state.timelineGeneration,
                  state.selectedMissionId == missionId else {
                return []
            }
            if let tl = timeline {
                guard tl.id == missionId else { return [] }
                state.timelinePhase = .loaded(tl)
            } else {
                state.timelinePhase = .unavailable(missionId: missionId)
            }
            return []

        case .clearSelection:
            state.pendingPreferredMissionId = nil
            clearTimelineSelection(&state)
            return []
        }
    }

    private static func startTimelineLoad(
        _ state: inout ReplayStoreState,
        missionId: String,
        force: Bool
    ) -> ReplayStoreEffect? {
        guard !missionId.isEmpty else { return nil }
        if !force && state.selectedMissionId == missionId {
            switch state.timelinePhase {
            case .loading(let loadingId, _) where loadingId == missionId:
                return nil
            case .loaded(let tl) where tl.id == missionId:
                return nil
            case .idle, .loading, .loaded, .unavailable:
                break
            }
        }
        state.timelineGeneration += 1
        let gen = state.timelineGeneration
        state.selectedMissionId = missionId
        state.timelinePhase = .loading(missionId: missionId, generation: gen)
        return .loadTimeline(missionId: missionId, generation: gen)
    }

    private static func clearTimelineSelection(_ state: inout ReplayStoreState) {
        if state.selectedMissionId != nil || state.timelinePhase != .idle {
            state.timelineGeneration += 1
        }
        state.selectedMissionId = nil
        state.timelinePhase = .idle
    }
}

// MARK: - Pure Playback State Machine

public enum ReplaySpeed: Double, CaseIterable, Equatable, Sendable {
    case x0_5 = 0.5
    case x1   = 1.0
    case x2   = 2.0
    case x4   = 4.0

    public var label: String {
        switch self {
        case .x0_5: return "0.5x"
        case .x1:   return "1x"
        case .x2:   return "2x"
        case .x4:   return "4x"
        }
    }
}

public enum ReplayPlayPhase: Equatable, Sendable {
    case paused
    case playing
    case scrubbing(wasPlaying: Bool)
}

public enum ReplayHapticCue: Equatable, Sendable {
    case playToggle
    case scrubDetent
    case anomalyEnter
    case stepEvent
    case speedChange
}

public enum ReplayPlaybackEvent: Equatable, Sendable {
    case syncTimeline(id: String, durationSec: Double, suggestedProgress: Double, pinnedMissionId: String? = nil)
    case togglePlay(durationSec: Double, isActive: Bool, reduceMotion: Bool)
    case beginScrub
    case scrub(progress: Double, timeline: ReplayTimeline)
    case endScrub(isActive: Bool, reduceMotion: Bool)
    case tick(dt: Double, timeline: ReplayTimeline, isActive: Bool, reduceMotion: Bool)
    case stepPrev(timeline: ReplayTimeline)
    case stepNext(timeline: ReplayTimeline)
    case cycleSpeed
    case setSpeed(ReplaySpeed)
    case setActive(Bool, reduceMotion: Bool)
}

public enum ReplayPlaybackEffect: Equatable, Sendable {
    case startTimer
    case stopTimer
    case haptic(ReplayHapticCue)
}

public struct ReplayPlaybackState: Equatable, Sendable {
    public var progress: Double
    public var speed: ReplaySpeed
    public var isSkippingIdle: Bool
    public var playPhase: ReplayPlayPhase
    public var sweepAngleDeg: Double
    public var loadedTimelineId: String?
    public var loadedDurationSec: Double
    public var lastScrubBucket: Int
    public var wasInsideAnomaly: Bool
    public var isTimerRunning: Bool

    /// Derived strictly from `playPhase` so shadow playing booleans are impossible.
    public var isPlaying: Bool {
        playPhase == .playing
    }

    public init(
        progress: Double = 0.0,
        isPlaying: Bool = false,
        speed: ReplaySpeed = .x1,
        isSkippingIdle: Bool = false,
        playPhase: ReplayPlayPhase? = nil,
        sweepAngleDeg: Double? = nil,
        loadedTimelineId: String? = nil,
        loadedDurationSec: Double = 0.0,
        lastScrubBucket: Int = -1,
        wasInsideAnomaly: Bool = false,
        isTimerRunning: Bool? = nil
    ) {
        let clamped = progress.isFinite ? min(1.0, max(0.0, progress)) : 0.0
        let resolvedPhase = playPhase ?? (isPlaying ? .playing : .paused)
        self.progress = clamped
        self.speed = speed
        self.isSkippingIdle = isSkippingIdle
        self.playPhase = resolvedPhase
        self.sweepAngleDeg = sweepAngleDeg.map(ReplayLogic.normalizeDegrees)
            ?? ReplayLogic.normalizeDegrees(clamped * 720.0)
        self.loadedTimelineId = loadedTimelineId
        self.loadedDurationSec = loadedDurationSec.isFinite ? max(0.0, loadedDurationSec) : 0.0
        self.lastScrubBucket = lastScrubBucket
        self.wasInsideAnomaly = wasInsideAnomaly
        self.isTimerRunning = isTimerRunning ?? (resolvedPhase == .playing)
    }

    public mutating func togglePlay() {
        if playPhase == .playing {
            playPhase = .paused
            isSkippingIdle = false
        } else {
            if progress >= 1.0 {
                progress = 0.0
            }
            isSkippingIdle = false
            playPhase = .playing
        }
    }

    public mutating func pause() {
        playPhase = .paused
        isSkippingIdle = false
    }

    public mutating func step(deltaWallSec: Double, timelineDurationSec: Double) {
        guard playPhase == .playing,
              deltaWallSec.isFinite, deltaWallSec > 0,
              timelineDurationSec.isFinite, timelineDurationSec > 0 else {
            return
        }
        isSkippingIdle = false
        let baseDur = ReplayLogic.effectivePlaybackDurationSec(timelineDurationSec: timelineDurationSec)
        let delta = (deltaWallSec * speed.rawValue) / baseDur
        let next = progress + delta
        if next >= 1.0 {
            progress = 1.0
            playPhase = .paused
            isSkippingIdle = false
        } else {
            progress = max(0.0, next)
        }
    }

    /// Advances playback with adaptive target-duration pacing and optional 3.2× Smart Idle Skip.
    /// When skipping dead air, clamps cleanly to the start of the very next non-idle segment
    /// or beam event so Retry Loops, Worker Spawns, and Beams are never overshot.
    public mutating func step(
        deltaWallSec: Double,
        timeline: ReplayTimeline,
        smartSkipIdle: Bool = true
    ) {
        guard playPhase == .playing,
              deltaWallSec.isFinite, deltaWallSec > 0,
              timeline.totalDurationSec.isFinite, timeline.totalDurationSec > 0 else {
            return
        }

        let totalDur = timeline.totalDurationSec
        let baseDur = ReplayLogic.effectivePlaybackDurationSec(timelineDurationSec: totalDur)
        let baseDelta = (deltaWallSec * speed.rawValue) / baseDur

        let next: Double
        if smartSkipIdle && ReplayLogic.isIdleDeadAir(timeline: timeline, progress: progress) {
            isSkippingIdle = true
            let acceleratedDelta = baseDelta * 3.2
            var candidate = progress + acceleratedDelta
            let currentSec = progress * totalDur
            if let nextBoundarySec = ReplayLogic.nextNonIdleBoundarySec(after: currentSec, in: timeline) {
                var boundaryProgress = min(1.0, max(0.0, nextBoundarySec / totalDur))
                if boundaryProgress < 1.0 && boundaryProgress * totalDur < nextBoundarySec {
                    boundaryProgress = min(1.0, boundaryProgress.nextUp)
                }
                if boundaryProgress > progress && candidate > boundaryProgress {
                    candidate = boundaryProgress
                }
            }
            next = candidate
        } else {
            isSkippingIdle = false
            next = progress + baseDelta
        }

        if next >= 1.0 {
            progress = 1.0
            playPhase = .paused
            isSkippingIdle = false
        } else {
            progress = max(0.0, next)
        }
    }

    public mutating func scrub(to newProgress: Double) {
        guard newProgress.isFinite else { return }
        isSkippingIdle = false
        progress = min(1.0, max(0.0, newProgress))
        if progress >= 1.0 && playPhase == .playing {
            playPhase = .paused
        }
    }

    public mutating func cycleSpeed() {
        switch speed {
        case .x0_5: speed = .x1
        case .x1:   speed = .x2
        case .x2:   speed = .x4
        case .x4:   speed = .x0_5
        }
    }

    public mutating func jumpToStart() {
        progress = 0.0
        isSkippingIdle = false
    }

    public mutating func reset(initialProgress: Double = 0.0) {
        let clamped = initialProgress.isFinite ? min(1.0, max(0.0, initialProgress)) : 0.0
        progress = clamped
        playPhase = .paused
        isSkippingIdle = false
        sweepAngleDeg = ReplayLogic.normalizeDegrees(clamped * 720.0)
        lastScrubBucket = -1
        wasInsideAnomaly = false
        isTimerRunning = false
    }

    /// Jumps to the first key event strictly ahead of `progress + 0.005`, or jumps to `1.0` and pauses if none remain.
    @discardableResult
    public mutating func stepToNextEvent(in timeline: ReplayTimeline) -> ReplayKeyEvent? {
        let events = ReplayLogic.keyEvents(for: timeline)
        isSkippingIdle = false
        if let next = events.first(where: { $0.progress > progress + 0.005 }) {
            progress = min(1.0, max(0.0, next.progress))
            if progress >= 1.0 && playPhase == .playing {
                playPhase = .paused
            }
            return next
        }
        progress = 1.0
        if playPhase == .playing {
            playPhase = .paused
        }
        return nil
    }

    /// Jumps to the last key event strictly behind `progress - 0.005`, or jumps to `0.0` if none earlier.
    @discardableResult
    public mutating func stepToPreviousEvent(in timeline: ReplayTimeline) -> ReplayKeyEvent? {
        let events = ReplayLogic.keyEvents(for: timeline)
        isSkippingIdle = false
        if let prev = events.last(where: { $0.progress < progress - 0.005 }) {
            progress = min(1.0, max(0.0, prev.progress))
            return prev
        }
        progress = 0.0
        return nil
    }

    /// Suggests an engaging initial progress on a timeline (midpoint of first retry loop,
    /// else first active beam timestamp, else `0.0`).
    public static func suggestedInitialProgress(for timeline: ReplayTimeline) -> Double {
        guard timeline.totalDurationSec > 0 else { return 0.0 }
        if let retrySeg = timeline.tracks
            .flatMap(\.segments)
            .filter({ $0.kind == .retryLoop })
            .min(by: { $0.startSec < $1.startSec }) {
            let mid = (retrySeg.startSec + retrySeg.endSec) * 0.5
            return min(1.0, max(0.0, mid / timeline.totalDurationSec))
        }
        if let firstBeam = timeline.beams.first {
            let p = firstBeam.timestampSec / timeline.totalDurationSec
            if p >= 0.02 && p <= 0.98 {
                return p
            }
        }
        return 0.0
    }
}

public enum ReplayPlaybackMachine {

    /// Radar sweep rotation speed while playing (degrees per wall-clock second).
    public static let sweepDegreesPerSecond: Double = 90.0

    @discardableResult
    public static func reduce(
        _ state: inout ReplayPlaybackState,
        event: ReplayPlaybackEvent
    ) -> [ReplayPlaybackEffect] {
        switch event {
        case .syncTimeline(let id, let durationSec, let suggestedProgress, let pinnedMissionId):
            if let pinned = pinnedMissionId, pinned != id {
                return []
            }
            let cleanDur = durationSec.isFinite ? max(0.0, durationSec) : 0.0
            let cleanProg = suggestedProgress.isFinite ? min(1.0, max(0.0, suggestedProgress)) : 0.0
            state.lastScrubBucket = -1
            state.wasInsideAnomaly = false

            if id.isEmpty {
                state.loadedTimelineId = nil
                state.loadedDurationSec = 0.0
                state.progress = 0.0
                state.sweepAngleDeg = 0.0
                state.playPhase = .paused
                state.isSkippingIdle = false
                return stopTimerIfRunning(&state)
            }

            if state.loadedTimelineId == id {
                state.loadedDurationSec = cleanDur
                if cleanDur <= 0 {
                    state.playPhase = .paused
                    state.isSkippingIdle = false
                    return stopTimerIfRunning(&state)
                }
                return []
            }

            state.loadedTimelineId = id
            state.loadedDurationSec = cleanDur
            state.progress = cleanProg
            state.sweepAngleDeg = ReplayLogic.normalizeDegrees(cleanProg * 720.0)
            state.playPhase = .paused
            state.isSkippingIdle = false
            return stopTimerIfRunning(&state)

        case .togglePlay(let durationSec, let isActive, _):
            let cleanDur = durationSec.isFinite ? max(0.0, durationSec) : 0.0
            state.loadedDurationSec = cleanDur
            var effects: [ReplayPlaybackEffect] = []

            switch state.playPhase {
            case .playing:
                state.playPhase = .paused
                state.isSkippingIdle = false
                effects.append(contentsOf: stopTimerIfRunning(&state))
                effects.append(.haptic(.playToggle))
                return effects

            case .paused, .scrubbing:
                guard cleanDur > 0, isActive else {
                    state.playPhase = .paused
                    state.isSkippingIdle = false
                    effects.append(contentsOf: stopTimerIfRunning(&state))
                    return effects
                }
                if state.progress >= 1.0 {
                    state.progress = 0.0
                }
                state.playPhase = .playing
                state.isSkippingIdle = false
                if !state.isTimerRunning {
                    state.isTimerRunning = true
                    effects.append(.startTimer)
                }
                effects.append(.haptic(.playToggle))
                return effects
            }

        case .beginScrub:
            switch state.playPhase {
            case .playing:
                state.playPhase = .scrubbing(wasPlaying: true)
                state.isSkippingIdle = false
                return stopTimerIfRunning(&state)
            case .paused:
                state.playPhase = .scrubbing(wasPlaying: false)
                state.isSkippingIdle = false
                return stopTimerIfRunning(&state)
            case .scrubbing:
                return []
            }

        case .scrub(let rawProgress, let timeline):
            guard rawProgress.isFinite else { return [] }
            let clamped = min(1.0, max(0.0, rawProgress))
            let cleanDur = timeline.totalDurationSec.isFinite ? max(0.0, timeline.totalDurationSec) : 0.0
            state.loadedDurationSec = cleanDur
            var effects: [ReplayPlaybackEffect] = []

            state.progress = clamped
            state.isSkippingIdle = false
            if clamped >= 1.0 && state.playPhase == .playing {
                state.playPhase = .paused
                effects.append(contentsOf: stopTimerIfRunning(&state))
            }

            let bucket = Int((clamped * 20.0).rounded(.down))
            let sec = clamped * cleanDur
            let inAnomaly = cleanDur > 0 && timeline.tracks.contains { track in
                track.segments.contains { seg in
                    (seg.kind == .retryLoop || seg.kind == .humanWait)
                        && sec >= seg.startSec && sec <= seg.endSec
                }
            }

            if inAnomaly && !state.wasInsideAnomaly {
                state.wasInsideAnomaly = true
                state.lastScrubBucket = bucket
                effects.append(.haptic(.anomalyEnter))
            } else {
                state.wasInsideAnomaly = inAnomaly
                if bucket != state.lastScrubBucket {
                    state.lastScrubBucket = bucket
                    effects.append(.haptic(.scrubDetent))
                }
            }
            return effects

        case .endScrub(let isActive, _):
            state.lastScrubBucket = -1
            state.wasInsideAnomaly = false
            guard case .scrubbing(let wasPlaying) = state.playPhase else {
                return []
            }
            if wasPlaying && isActive && state.loadedDurationSec > 0 && state.progress < 1.0 {
                state.playPhase = .playing
                if !state.isTimerRunning {
                    state.isTimerRunning = true
                    return [.startTimer]
                }
                return []
            } else {
                state.playPhase = .paused
                state.isSkippingIdle = false
                return stopTimerIfRunning(&state)
            }

        case .tick(let dt, let timeline, let isActive, let reduceMotion):
            let cleanDur = timeline.totalDurationSec.isFinite ? max(0.0, timeline.totalDurationSec) : 0.0
            state.loadedDurationSec = cleanDur

            guard isActive, cleanDur > 0 else {
                if state.playPhase == .playing {
                    state.playPhase = .paused
                    state.isSkippingIdle = false
                }
                return stopTimerIfRunning(&state)
            }

            guard state.playPhase == .playing else {
                return stopTimerIfRunning(&state)
            }

            guard dt.isFinite, dt > 0 else { return [] }

            state.step(deltaWallSec: dt, timeline: timeline, smartSkipIdle: true)
            if state.playPhase == .playing {
                if !reduceMotion {
                    state.sweepAngleDeg = ReplayLogic.normalizeDegrees(
                        state.sweepAngleDeg + dt * sweepDegreesPerSecond
                    )
                }
                return []
            } else {
                return stopTimerIfRunning(&state)
            }

        case .stepPrev(let timeline):
            state.loadedDurationSec = timeline.totalDurationSec.isFinite ? max(0.0, timeline.totalDurationSec) : 0.0
            _ = state.stepToPreviousEvent(in: timeline)
            return [.haptic(.stepEvent)]

        case .stepNext(let timeline):
            state.loadedDurationSec = timeline.totalDurationSec.isFinite ? max(0.0, timeline.totalDurationSec) : 0.0
            var effects: [ReplayPlaybackEffect] = []
            _ = state.stepToNextEvent(in: timeline)
            if state.playPhase != .playing {
                effects.append(contentsOf: stopTimerIfRunning(&state))
            }
            effects.append(.haptic(.stepEvent))
            return effects

        case .cycleSpeed:
            state.cycleSpeed()
            return [.haptic(.speedChange)]

        case .setSpeed(let nextSpeed):
            guard state.speed != nextSpeed else { return [] }
            state.speed = nextSpeed
            return [.haptic(.speedChange)]

        case .setActive(let isActive, _):
            guard !isActive else {
                return []
            }
            state.playPhase = .paused
            state.isSkippingIdle = false
            state.lastScrubBucket = -1
            state.wasInsideAnomaly = false
            return stopTimerIfRunning(&state)
        }
    }

    private static func stopTimerIfRunning(_ state: inout ReplayPlaybackState) -> [ReplayPlaybackEffect] {
        guard state.isTimerRunning else { return [] }
        state.isTimerRunning = false
        return [.stopTimer]
    }
}
