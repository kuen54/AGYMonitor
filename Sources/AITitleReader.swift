import Foundation

// MARK: - Antigravity Transcript & Metadata Reader (app layer, Foundation-only)
//
// Reads bounded tails of Antigravity `transcript.jsonl` files plus lightweight
// companion metadata (`annotations/<id>.pbtxt` and `.system_generated/swarm/members.json`).
// Pure JSONL line parsing lives in Core_Transcript.swift (TranscriptSummary /
// TranscriptParse); all file I/O stays here in the app layer.

enum AITitleReader {

    /// Live step state inferred from the tail of `transcript.jsonl`.
    struct TailStepActivity: Equatable {
        let status: SessionStatus
        let waitingFor: String?
        let createdAtMs: Double?
        let fileMtime: TimeInterval

        static let idle = TailStepActivity(status: .idle, waitingFor: nil, createdAtMs: nil, fileMtime: 0)
    }

    /// Swarm coordinator summary read from `brain/<id>/.system_generated/swarm/members.json`.
    struct SwarmCoordinatorInfo: Equatable {
        let title: String?
        let anyWorkerBusy: Bool
        let workerConversationIds: Set<String>
    }

    /// Default Antigravity root directory (`~/.gemini`).
    static var defaultGeminiRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini")
    }

    /// Title + latest clean user instruction for an Antigravity session.
    static func summary(
        sessionId: String,
        projectsDir: URL = AITitleReader.defaultGeminiRoot,
        needInstruction: Bool = true
    ) -> TranscriptSummary {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let annTitle = annotationTitle(sessionId: sessionId, home: home)

        if !needInstruction, let annTitle = annTitle, !annTitle.isEmpty {
            return TranscriptSummary(title: annTitle, instruction: nil)
        }

        guard let path = transcriptPath(sessionId: sessionId, projectsDir: projectsDir) else {
            return TranscriptSummary(title: annTitle, instruction: nil)
        }
        let scanned = summary(inFileAt: path, needInstruction: needInstruction)
        let resolvedTitle = (annTitle?.isEmpty == false) ? annTitle : scanned.title
        return TranscriptSummary(
            title: resolvedTitle,
            instruction: scanned.instruction,
            lastStepType: scanned.lastStepType,
            lastStepStatus: scanned.lastStepStatus,
            lastStepAt: scanned.lastStepAt,
            lastModel: scanned.lastModel,
            pendingToolNames: scanned.pendingToolNames,
            isWaitingForQuestion: scanned.isWaitingForQuestion
        )
    }

    /// Latest session title for click-to-jump (Otty pane title matching).
    static func latestAITitle(
        sessionId: String,
        projectsDir: URL = AITitleReader.defaultGeminiRoot
    ) -> String? {
        return summary(sessionId: sessionId, projectsDir: projectsDir, needInstruction: false).title
    }

    /// Direct O(1) lookup across Antigravity's 3 brain roots, with fallback support
    /// for custom test/project directories.
    static func transcriptPath(sessionId: String, projectsDir: URL) -> String? {
        guard !sessionId.isEmpty else { return nil }
        let fm = FileManager.default

        // 1. Check if projectsDir is `~/.gemini` (default) or contains surface dirs
        let surfaceRelPaths = [
            "antigravity-cli/brain/\(sessionId)/.system_generated/logs/transcript.jsonl",
            "antigravity/brain/\(sessionId)/.system_generated/logs/transcript.jsonl",
            "antigravity-ide/brain/\(sessionId)/.system_generated/logs/transcript.jsonl",
            "\(sessionId)/.system_generated/logs/transcript.jsonl",
            "\(sessionId)/transcript.jsonl",
            "\(sessionId).jsonl",
        ]
        var bestPath: String? = nil
        var bestMtime: Date = .distantPast
        for rel in surfaceRelPaths {
            let candidate = projectsDir.appendingPathComponent(rel).path
            if fm.fileExists(atPath: candidate) {
                let mtime = (try? fm.attributesOfItem(atPath: candidate)[.modificationDate] as? Date) ?? .distantPast
                if bestPath == nil || mtime > bestMtime {
                    bestPath = candidate
                    bestMtime = mtime
                }
            }
        }
        if let bestPath = bestPath { return bestPath }

        // 2. Also check standard ~/.gemini surfaces if caller passed a different root
        if let direct = transcriptPath(sessionId: sessionId, home: fm.homeDirectoryForCurrentUser.path) {
            return direct
        }

        // 3. Bounded fallback walk for custom directory layouts (skips chunks & subagents)
        let target = "\(sessionId).jsonl"
        guard let en = fm.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return nil }

        var scanned = 0
        let maxEntries = 100_000
        for case let url as URL in en {
            scanned += 1
            if scanned > maxEntries { return nil }
            let name = url.lastPathComponent
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                if name == "chunks" || name == "subagents" || name == "steps" {
                    en.skipDescendants()
                }
                continue
            }
            if name == "transcript.jsonl" && url.path.contains("/\(sessionId)/") {
                return url.path
            }
            if name == target && !url.path.contains("/chunks/") && !url.path.contains("/subagents/") {
                return url.path
            }
        }
        return nil
    }

    /// Fast O(1) lookup across the 3 standard Antigravity brain directories.
    static func transcriptPath(sessionId: String, home: String = NSHomeDirectory()) -> String? {
        guard !sessionId.isEmpty else { return nil }
        let fm = FileManager.default
        let surfaces = ["antigravity-cli", "antigravity", "antigravity-ide"]
        var bestPath: String? = nil
        var bestMtime: Date = .distantPast
        for s in surfaces {
            let p = (home as NSString).appendingPathComponent(
                ".gemini/\(s)/brain/\(sessionId)/.system_generated/logs/transcript.jsonl"
            )
            if fm.fileExists(atPath: p) {
                let mtime = (try? fm.attributesOfItem(atPath: p)[.modificationDate] as? Date) ?? .distantPast
                if bestPath == nil || mtime > bestMtime {
                    bestPath = p
                    bestMtime = mtime
                }
            }
        }
        return bestPath
    }

    /// Bounded 256 KB-chunk backwards tail reader (4 MB cap) extracting title + latest user prompt.
    static func summary(inFileAt path: String, needInstruction: Bool = true) -> TranscriptSummary {
        guard let handle = FileHandle(forReadingAtPath: path) else { return .empty }
        defer { try? handle.close() }

        let chunk = 256 * 1024            // 256 KB per step
        let cap: UInt64 = 4 * 1024 * 1024 // 4 MB max tail read

        guard let end = try? handle.seekToEnd(), end > 0 else { return .empty }
        var pos = end
        var buffer = Data()
        var result = TranscriptSummary.empty
        while pos > 0 && UInt64(buffer.count) < cap {
            let step = Int(min(UInt64(chunk), pos))
            pos -= UInt64(step)
            do { try handle.seek(toOffset: pos) } catch { break }
            let data = handle.readData(ofLength: step)
            buffer = data + buffer
            result = TranscriptParse.scan(buffer)
            if (!needInstruction && result.title != nil)
                || (needInstruction && result.instruction != nil && (result.title != nil || pos == 0)) {
                break
            }
            // In AGY transcripts, titles usually live in annotations/*.pbtxt rather than
            // inside transcript.jsonl; once we found the latest instruction in the first
            // chunk(s), avoid scanning megabytes looking for an absent inline title.
            if needInstruction && result.instruction != nil && buffer.count >= 512 * 1024 {
                break
            }
        }
        return result
    }

    /// Inspect the last JSONL step in `transcript.jsonl` to determine whether the
    /// session is actively running tools/generating (`.busy`), waiting on `ask_question`
    /// (`.waiting`), or finished (`.idle`).
    static func tailActivity(inFileAt path: String) -> TailStepActivity {
        let fm = FileManager.default
        let fileMtime = ((try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date)?
            .timeIntervalSince1970) ?? 0
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return TailStepActivity(status: .idle, waitingFor: nil, createdAtMs: nil, fileMtime: fileMtime)
        }
        defer { try? handle.close() }

        guard let end = try? handle.seekToEnd(), end > 0 else {
            return TailStepActivity(status: .idle, waitingFor: nil, createdAtMs: nil, fileMtime: fileMtime)
        }
        let readLen = Int(min(UInt64(128 * 1024), end))
        let offset = end - UInt64(readLen)
        do { try handle.seek(toOffset: offset) } catch {
            return TailStepActivity(status: .idle, waitingFor: nil, createdAtMs: nil, fileMtime: fileMtime)
        }
        let data = handle.readData(ofLength: readLen)
        let text = String(decoding: data, as: UTF8.self)
        let scanned = TranscriptParse.scan(text: text)
        let createdAt: Double? = scanned.lastStepAt.flatMap { d in
            let sec = d.timeIntervalSince1970
            return sec > 946_684_800 ? sec * 1000.0 : nil
        }

        if scanned.isWaitingForQuestion {
            return TailStepActivity(
                status: .waiting,
                waitingFor: "input needed",
                createdAtMs: createdAt,
                fileMtime: fileMtime
            )
        }

        if scanned.lastStepStatus == .running {
            return TailStepActivity(
                status: .busy,
                waitingFor: nil,
                createdAtMs: createdAt,
                fileMtime: fileMtime
            )
        }

        let nonIdlePendingTools = scanned.pendingToolNames.filter { $0 != "swarm_wait" }
        if !nonIdlePendingTools.isEmpty {
            return TailStepActivity(
                status: .busy,
                waitingFor: nil,
                createdAtMs: createdAt,
                fileMtime: fileMtime
            )
        }
        if !scanned.pendingToolNames.isEmpty {
            // Only `swarm_wait` remains pending — worker is parked idle waiting on board.
            return TailStepActivity(
                status: .idle,
                waitingFor: nil,
                createdAtMs: createdAt,
                fileMtime: fileMtime
            )
        }

        if (scanned.lastStepType == .userInput || scanned.lastStepType == .generic),
           scanned.lastStepStatus != .error {
            return TailStepActivity(
                status: .busy,
                waitingFor: nil,
                createdAtMs: createdAt,
                fileMtime: fileMtime
            )
        }

        return TailStepActivity(
            status: .idle,
            waitingFor: nil,
            createdAtMs: createdAt,
            fileMtime: fileMtime
        )
    }

    // MARK: - Annotations (`annotations/<id>.pbtxt`) & Swarm (`swarm/members.json`)

    /// Read `title:"..."` from `~/.gemini/<surface>/annotations/<sessionId>.pbtxt`.
    static func annotationTitle(sessionId: String, home: String = NSHomeDirectory()) -> String? {
        guard !sessionId.isEmpty else { return nil }
        let surfaces = ["antigravity-cli", "antigravity", "antigravity-ide"]
        for s in surfaces {
            let path = (home as NSString)
                .appendingPathComponent(".gemini/\(s)/annotations/\(sessionId).pbtxt")
            guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            if let parsed = parsePbtxtTitle(raw), !parsed.isEmpty {
                return parsed
            }
        }
        return nil
    }

    /// Read swarm coordinator info from `brain/<sessionId>/.system_generated/swarm/members.json` if present.
    static func swarmInfo(sessionId: String, home: String = NSHomeDirectory()) -> SwarmCoordinatorInfo? {
        guard !sessionId.isEmpty else { return nil }
        let fm = FileManager.default
        let surfaces = ["antigravity-cli", "antigravity", "antigravity-ide"]
        for s in surfaces {
            let path = (home as NSString).appendingPathComponent(
                ".gemini/\(s)/brain/\(sessionId)/.system_generated/swarm/members.json"
            )
            guard fm.fileExists(atPath: path),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let rawTitle = (root["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (rawTitle?.isEmpty == false) ? rawTitle : nil
            var anyBusy = false
            var workerIds = Set<String>()
            if let members = root["members"] as? [String: [String: Any]] {
                for (memberName, info) in members {
                    let role = (info["role"] as? String) ?? ""
                    let convId = (info["conversation_id"] as? String) ?? ""
                    let killed = (info["killed"] as? Bool) ?? false
                    let phase = (info["phase"] as? String) ?? ""
                    let wakeMode = (info["wake_mode"] as? String) ?? ""
                    if role == "worker", !convId.isEmpty {
                        workerIds.insert(convId)
                        if !killed && phase != "KILLED" && memberName != "monitor" && wakeMode == "working" {
                            anyBusy = true
                        }
                    }
                }
            }
            return SwarmCoordinatorInfo(title: title, anyWorkerBusy: anyBusy, workerConversationIds: workerIds)
        }
        return nil
    }

    // MARK: - Helpers

    /// Parse `title:"..."` or `title: "..."` from protobuf TextFormat, decoding octal UTF-8 escapes.
    static func parsePbtxtTitle(_ text: String) -> String? {
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("title:") else { continue }
            var rest = line.dropFirst("title:".count).trimmingCharacters(in: .whitespaces)
            guard rest.first == "\"", rest.count >= 2 else { continue }
            rest.removeFirst()
            if rest.last == "\"" { rest.removeLast() }
            let decoded = unescapePbtxtString(rest).trimmingCharacters(in: .whitespacesAndNewlines)
            if !decoded.isEmpty { return decoded }
        }
        return nil
    }

    private static func unescapePbtxtString(_ s: String) -> String {
        var bytes: [UInt8] = []
        let utf8 = Array(s.utf8)
        var i = 0
        while i < utf8.count {
            let b = utf8[i]
            if b == 0x5C, i + 1 < utf8.count { // '\'
                let next = utf8[i + 1]
                // Octal escape \000 .. \377
                if next >= 0x30 && next <= 0x37 {
                    var val: UInt32 = 0
                    var consumed = 0
                    while consumed < 3 && (i + 1 + consumed) < utf8.count {
                        let d = utf8[i + 1 + consumed]
                        guard d >= 0x30 && d <= 0x37 else { break }
                        val = val * 8 + UInt32(d - 0x30)
                        consumed += 1
                    }
                    bytes.append(UInt8(truncatingIfNeeded: val))
                    i += 1 + consumed
                    continue
                }
                switch next {
                case 0x6E: bytes.append(0x0A); i += 2 // \n
                case 0x74: bytes.append(0x09); i += 2 // \t
                case 0x72: bytes.append(0x0D); i += 2 // \r
                case 0x22: bytes.append(0x22); i += 2 // \"
                case 0x27: bytes.append(0x27); i += 2 // \'
                case 0x5C: bytes.append(0x5C); i += 2 // \\
                default:
                    bytes.append(next)
                    i += 2
                }
            } else {
                bytes.append(b)
                i += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func parseValidEpochMs(_ iso: String?) -> Double? {
        guard let d = OAuthUsage.parseISO(iso) else { return nil }
        let sec = d.timeIntervalSince1970
        // Reject sentinel dates such as 0001-01-01T00:00:00Z
        guard sec > 946_684_800 else { return nil }
        return sec * 1000.0
    }
}
