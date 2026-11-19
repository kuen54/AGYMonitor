import Foundation

// MARK: - Antigravity transcript & annotation parsing — pure core
//
// Pure half of AITitleReader / SessionMonitor: given a tail buffer of
// `<conv-id>/.system_generated/logs/transcript.jsonl` (or one JSONL step line,
// or an `annotations/<conv-id>.pbtxt` string), extract:
//   - user instruction (`USER_INPUT` with `<USER_REQUEST>...</USER_REQUEST>` unwrapped)
//   - session title (if embedded, or from `annotations/<id>.pbtxt`)
//   - step liveness & waiting state (`RUNNING` / `DONE` / `ERROR`, pending
//     `ask_question` tool call detection, sentinel `0001-01-01` filtering)
//   - per-step token / model metadata (`PLANNER_RESPONSE`)
//
// Foundation-only (part of AGYCore): all file I/O stays app-side.

public enum TranscriptStepType: String, Codable, Equatable, Sendable {
    case userInput       = "USER_INPUT"
    case plannerResponse = "PLANNER_RESPONSE"
    case systemMessage   = "SYSTEM_MESSAGE"
    case generic         = "GENERIC"
    case unknown         = "UNKNOWN"

    public init(rawStepType: String?) {
        guard let raw = rawStepType?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() else {
            self = .unknown
            return
        }
        self = TranscriptStepType(rawValue: raw) ?? .unknown
    }
}

public enum TranscriptStepStatus: String, Codable, Equatable, Sendable {
    case running = "RUNNING"
    case done    = "DONE"
    case error   = "ERROR"
    case unknown = "UNKNOWN"

    public init(rawStatus: String?) {
        guard let raw = rawStatus?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() else {
            self = .unknown
            return
        }
        self = TranscriptStepStatus(rawValue: raw) ?? .unknown
    }
}

/// One parsed JSONL step line from Antigravity's `transcript.jsonl`.
public struct TranscriptStep: Equatable, Sendable {
    public let stepIndex: Int
    public let source: String?
    public let type: TranscriptStepType
    public let status: TranscriptStepStatus
    /// nil when absent or when `created_at` is the `0001-01-01` zero-time sentinel.
    public let createdAt: Date?
    public let model: String?
    /// Uncached new input tokens on `PLANNER_RESPONSE`.
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    /// Cleaned user prompt when `type == .userInput`.
    public let userInstruction: String?
    /// Tool names invoked in `tool_calls` on `PLANNER_RESPONSE`.
    public let toolNames: [String]
    /// True when `tool_calls` includes `ask_question` (session waits for user answer).
    public let hasAskQuestion: Bool
    /// True when `tool_calls` spawns/coordinates subagents (`invoke_subagent` or `swarm`).
    public let invokesSubagent: Bool

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
    }

    public init(
        stepIndex: Int,
        source: String? = nil,
        type: TranscriptStepType,
        status: TranscriptStepStatus,
        createdAt: Date? = nil,
        model: String? = nil,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        userInstruction: String? = nil,
        toolNames: [String] = [],
        hasAskQuestion: Bool = false,
        invokesSubagent: Bool = false
    ) {
        self.stepIndex = stepIndex
        self.source = source
        self.type = type
        self.status = status
        self.createdAt = createdAt
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.userInstruction = userInstruction
        self.toolNames = toolNames
        self.hasAskQuestion = hasAskQuestion
        self.invokesSubagent = invokesSubagent
    }
}

/// Tail-scan summary for a conversation's transcript: preserves the `(title, instruction)`
/// contract expected by `AITitleReader` / `SessionMonitor` while exposing Antigravity's
/// step-level status and `ask_question` waiting signals with defaulted parameters.
public struct TranscriptSummary: Equatable, Sendable {
    public let title: String?
    public let instruction: String?
    public let lastStepType: TranscriptStepType?
    public let lastStepStatus: TranscriptStepStatus?
    public let lastStepAt: Date?
    public let lastModel: String?
    public let pendingToolNames: [String]
    public let isWaitingForQuestion: Bool

    public static let empty = TranscriptSummary(title: nil, instruction: nil)

    public init(
        title: String?,
        instruction: String?,
        lastStepType: TranscriptStepType? = nil,
        lastStepStatus: TranscriptStepStatus? = nil,
        lastStepAt: Date? = nil,
        lastModel: String? = nil,
        pendingToolNames: [String] = [],
        isWaitingForQuestion: Bool = false
    ) {
        self.title = title
        self.instruction = instruction
        self.lastStepType = lastStepType
        self.lastStepStatus = lastStepStatus
        self.lastStepAt = lastStepAt
        self.lastModel = lastModel
        self.pendingToolNames = pendingToolNames
        self.isWaitingForQuestion = isWaitingForQuestion
    }

    /// Derive `(SessionStatus, waitingFor)` from the transcript tail plus optional
    /// DB `notFullyIdle` flag and an injected `now` clock (guards against a long-ago
    /// interrupted turn appearing `.busy` forever).
    public func inferredStatus(
        notFullyIdle: Bool? = nil,
        now: Date? = nil,
        busyRecencySeconds: TimeInterval = 180
    ) -> (status: SessionStatus, waitingFor: String?) {
        if isWaitingForQuestion {
            return (.waiting, "input needed")
        }
        if lastStepStatus == .running {
            return (.busy, nil)
        }
        if notFullyIdle == true {
            return (.busy, nil)
        }
        if notFullyIdle == false {
            return (.idle, nil)
        }
        let isRecent: Bool = {
            guard let now = now, let at = lastStepAt else { return true }
            return now.timeIntervalSince(at) <= busyRecencySeconds
        }()
        if !pendingToolNames.isEmpty && isRecent {
            return (.busy, nil)
        }
        if lastStepType == .userInput && lastStepStatus == .done && isRecent {
            return (.busy, nil)
        }
        return (.idle, nil)
    }
}

public enum TranscriptParse {

    /// Fast pure-UTF8 literal ASCII substring check (avoids Foundation's expensive
    /// locale/grapheme-cluster `String.contains` on large JSONL lines).
    @inline(__always)
    private static func fastContains(_ s: String, _ asciiNeedle: String) -> Bool {
        s.range(of: asciiNeedle, options: .literal) != nil
    }

    /// One in-order pass over a tail buffer's lines, last qualifying entry winning.
    public static func scan(_ buffer: Data) -> TranscriptSummary {
        scan(text: String(decoding: buffer, as: UTF8.self))
    }

    /// String overload — handles both Antigravity `transcript.jsonl` step records
    /// (`USER_INPUT`, `PLANNER_RESPONSE`, `SYSTEM_MESSAGE`, `GENERIC`) and legacy
    /// `ai-title` / `last-prompt` / `user` records.
    public static func scan(text: String) -> TranscriptSummary {
        var title: String? = nil
        var instruction: String? = nil
        var lastStep: TranscriptStep? = nil
        var lastSeenModel: String? = nil
        var activePlannerTools: [String] = []
        var activePlannerHasQuestion = false
        var completedToolOutputsAfterPlanner = 0

        for sub in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(sub)

            if fastContains(line, "\"ai-title\""), let t = parseAITitle(line) {
                title = t
            }
            if fastContains(line, "\"last-prompt\""), let lp = parseLastPrompt(line) {
                instruction = lp
            }

            if let step = parseStep(line) {
                lastStep = step
                if let model = step.model, !model.isEmpty {
                    lastSeenModel = model
                }
                switch step.type {
                case .userInput:
                    if let prompt = step.userInstruction {
                        instruction = prompt
                    }
                    activePlannerTools = []
                    activePlannerHasQuestion = false
                    completedToolOutputsAfterPlanner = 0
                case .plannerResponse:
                    if step.status == .error {
                        activePlannerTools = []
                        activePlannerHasQuestion = false
                    } else {
                        activePlannerTools = step.toolNames
                        activePlannerHasQuestion = step.hasAskQuestion
                    }
                    completedToolOutputsAfterPlanner = 0
                case .generic:
                    if step.status == .done || step.status == .error {
                        completedToolOutputsAfterPlanner += 1
                    }
                case .systemMessage, .unknown:
                    break
                }
            } else if fastContains(line, "\"type\":\"user\"") || fastContains(line, "\"type\": \"user\"") {
                if let txt = parseUserInstruction(line) {
                    instruction = txt
                }
            }
        }

        // Compute remaining pending tools from the latest PLANNER_RESPONSE after
        // subtracting GENERIC tool-result steps that already completed.
        let pendingTools: [String]
        if activePlannerTools.isEmpty {
            pendingTools = []
        } else if completedToolOutputsAfterPlanner >= activePlannerTools.count {
            pendingTools = []
        } else {
            pendingTools = Array(activePlannerTools.dropFirst(completedToolOutputsAfterPlanner))
        }

        let waitingForQuestion = activePlannerHasQuestion
            && completedToolOutputsAfterPlanner < activePlannerTools.count

        let lastModel = lastStep?.model ?? lastSeenModel

        return TranscriptSummary(
            title: cleaned(title),
            instruction: cleaned(instruction),
            lastStepType: lastStep?.type,
            lastStepStatus: lastStep?.status,
            lastStepAt: lastStep?.createdAt,
            lastModel: lastModel,
            pendingToolNames: pendingTools,
            isWaitingForQuestion: waitingForQuestion
        )
    }

    // MARK: - Antigravity step parser

    private static let questionToolNames: Set<String> = [
        "ask_question", "ask_user", "ask_followup_question"
    ]

    private static let subagentToolNames: Set<String> = [
        "invoke_subagent", "define_subagent", "swarm", "run_workflow"
    ]

    /// Parse one Antigravity `transcript.jsonl` step line. Returns nil if `line`
    /// is malformed JSON or not an Antigravity step object.
    public static func parseStep(_ line: String) -> TranscriptStep? {
        guard fastContains(line, "\"step_index\"") || fastContains(line, "\"PLANNER_RESPONSE\"")
                || fastContains(line, "\"USER_INPUT\"") || fastContains(line, "\"SYSTEM_MESSAGE\"")
                || fastContains(line, "\"GENERIC\"") else {
            return nil
        }
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let rawType = obj["type"] as? String
        let stepType = TranscriptStepType(rawStepType: rawType)
        let hasStepIndex = obj["step_index"] != nil
        guard hasStepIndex || stepType != .unknown else { return nil }

        let stepIndex = (obj["step_index"] as? Int) ?? 0
        let source = obj["source"] as? String
        let status = TranscriptStepStatus(rawStatus: obj["status"] as? String)
        let createdAt = AppDate.parseISO8601(obj["created_at"] as? String)
        let model = (obj["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        let inp = obj["input_tokens"] as? Int ?? 0
        let out = obj["output_tokens"] as? Int ?? 0
        let cr  = (obj["cache_read_tokens"] as? Int) ?? (obj["cache_read"] as? Int) ?? 0
        let cw  = (obj["cache_write_tokens"] as? Int) ?? (obj["cache_write"] as? Int) ?? 0

        var toolNames: [String] = []
        if let calls = obj["tool_calls"] as? [[String: Any]] {
            for call in calls {
                if let name = (call["name"] as? String) ?? (call["tool_name"] as? String),
                   !name.isEmpty {
                    toolNames.append(name)
                }
            }
        }

        let hasQuestion = toolNames.contains { questionToolNames.contains($0) }
        let invokesSub  = toolNames.contains { subagentToolNames.contains($0) }

        var userPrompt: String? = nil
        if stepType == .userInput, let content = obj["content"] as? String {
            userPrompt = extractUserRequest(content)
        }

        return TranscriptStep(
            stepIndex: stepIndex,
            source: source,
            type: stepType,
            status: status,
            createdAt: createdAt,
            model: (model?.isEmpty == true) ? nil : model,
            inputTokens: inp,
            outputTokens: out,
            cacheReadTokens: cr,
            cacheWriteTokens: cw,
            userInstruction: userPrompt,
            toolNames: toolNames,
            hasAskQuestion: hasQuestion,
            invokesSubagent: invokesSub
        )
    }

    /// Extract the clean human prompt from an Antigravity `USER_INPUT` `content` field.
    ///
    /// Antigravity wraps user prompts in `<USER_REQUEST>\n...\n</USER_REQUEST>` followed
    /// by `<ADDITIONAL_METADATA>...</ADDITIONAL_METADATA>` and `<USER_SETTINGS_CHANGE>...`.
    /// When `content` was truncated in `transcript.jsonl` (`truncated_fields: ["content"]`),
    /// `</USER_REQUEST>` may be cut off — in that case we take everything after
    /// `<USER_REQUEST>` with metadata blocks stripped.
    public static func extractUserRequest(_ rawContent: String) -> String? {
        var candidate: String
        if let openRange = rawContent.range(of: "<USER_REQUEST>") {
            let afterOpen = rawContent[openRange.upperBound...]
            if let closeRange = afterOpen.range(of: "</USER_REQUEST>") {
                candidate = String(afterOpen[..<closeRange.lowerBound])
            } else {
                candidate = String(afterOpen)
            }
        } else {
            candidate = rawContent
        }

        candidate = stripXMLBlock(candidate, tag: "ADDITIONAL_METADATA")
        candidate = stripXMLBlock(candidate, tag: "USER_SETTINGS_CHANGE")
        candidate = stripXMLBlock(candidate, tag: "SYSTEM_MESSAGE")

        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isJunk(trimmed) else { return nil }
        return cleaned(trimmed)
    }

    private static func stripXMLBlock(_ text: String, tag: String) -> String {
        var out = text
        let openTag = "<\(tag)>"
        let closeTag = "</\(tag)>"
        while let open = out.range(of: openTag) {
            if let close = out.range(of: closeTag, range: open.upperBound..<out.endIndex) {
                out.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                // Truncated before closing tag — drop through end of string.
                out.removeSubrange(open.lowerBound..<out.endIndex)
                break
            }
        }
        return out
    }

    /// Parse `~/.gemini/antigravity-cli/annotations/<conv-id>.pbtxt` (`title:"..."`).
    /// Unescapes protobuf text-format quotes (`\"`), backslashes (`\\`), and octal/UTF-8
    /// byte escapes (`\344\270\255`) when present.
    public static func parseAnnotationTitle(_ pbtxt: String) -> String? {
        for rawLine in pbtxt.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("title:") else { continue }
            var rest = line.dropFirst("title:".count).trimmingCharacters(in: .whitespaces)
            guard rest.first == "\"" else { continue }
            rest.removeFirst()
            let decoded = unescapeProtobufTextString(Substring(rest))
            if let clean = cleaned(decoded) {
                return clean
            }
        }
        return nil
    }

    private static func unescapeProtobufTextString(_ slice: Substring) -> String {
        var bytes: [UInt8] = []
        var idx = slice.startIndex
        while idx < slice.endIndex {
            let ch = slice[idx]
            if ch == "\"" {
                break // closing quote
            }
            if ch == "\\" {
                idx = slice.index(after: idx)
                guard idx < slice.endIndex else { break }
                let esc = slice[idx]
                switch esc {
                case "n":  bytes.append(0x0A); idx = slice.index(after: idx)
                case "r":  bytes.append(0x0D); idx = slice.index(after: idx)
                case "t":  bytes.append(0x09); idx = slice.index(after: idx)
                case "\"": bytes.append(0x22); idx = slice.index(after: idx)
                case "'":  bytes.append(0x27); idx = slice.index(after: idx)
                case "\\": bytes.append(0x5C); idx = slice.index(after: idx)
                case "0"..."7":
                    // Up to 3 octal digits (pbtxt encodes non-ASCII UTF-8 bytes as \ooo)
                    var octVal: UInt8 = 0
                    var count = 0
                    while idx < slice.endIndex, count < 3,
                          let ascii = slice[idx].asciiValue, ascii >= 48 && ascii <= 55 {
                        octVal = octVal &* 8 &+ (ascii - 48)
                        idx = slice.index(after: idx)
                        count += 1
                    }
                    bytes.append(octVal)
                case "x", "X":
                    idx = slice.index(after: idx)
                    var hexStr = ""
                    var count = 0
                    while idx < slice.endIndex, count < 2, slice[idx].isHexDigit {
                        hexStr.append(slice[idx])
                        idx = slice.index(after: idx)
                        count += 1
                    }
                    if let v = UInt8(hexStr, radix: 16) { bytes.append(v) }
                default:
                    bytes.append(contentsOf: String(esc).utf8)
                    idx = slice.index(after: idx)
                }
            } else {
                bytes.append(contentsOf: String(ch).utf8)
                idx = slice.index(after: idx)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Preserved compatibility parsers

    public static func parseAITitle(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "ai-title",
              let title = obj["aiTitle"] as? String,
              !title.isEmpty else { return nil }
        return title
    }

    public static func parseLastPrompt(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "last-prompt",
              let lp = obj["lastPrompt"] as? String,
              !lp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return lp
    }

    public static func parseUserInstruction(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "user" else { return nil }
        if (obj["isMeta"] as? Bool) == true { return nil }
        guard let msg = obj["message"] as? [String: Any] else { return nil }
        let text: String
        if let s = msg["content"] as? String {
            text = s
        } else if let arr = msg["content"] as? [[String: Any]] {
            text = arr.compactMap { block -> String? in
                guard (block["type"] as? String) == "text",
                      let t = block["text"] as? String else { return nil }
                return t
            }.joined(separator: "\n")
        } else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || isJunk(trimmed) { return nil }
        return text
    }

    /// Injected-noise prefixes that are not user instructions.
    public static let junkPrefixes = [
        "<task-notification", "<local-command", "<command-name", "<command-message",
        "<system-reminder", "<SYSTEM_MESSAGE>", "[Request interrupted", "Caveat:",
        "The following is a <SYSTEM_MESSAGE>",
    ]

    public static func isJunk(_ trimmed: String) -> Bool {
        for p in junkPrefixes where trimmed.hasPrefix(p) { return true }
        return false
    }

    /// Collapse all whitespace/newlines to single spaces, trim, and cap at 300 chars.
    public static func cleaned(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        var s = raw.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if s.isEmpty { return nil }
        if s.hasPrefix("@") && !s.dropFirst().contains(" "), s.count > 60 {
            let path = s.dropFirst().trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let base = (path as NSString).lastPathComponent
            if !base.isEmpty { s = "@" + base }
        }
        if s.count > 300 { s = String(s.prefix(300)) }
        return s
    }
}
