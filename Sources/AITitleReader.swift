import Foundation

// MARK: - Antigravity Transcript & Metadata Reader (app layer, Foundation-only)
//
// Reads bounded tails of Antigravity `transcript.jsonl` files plus lightweight
// companion metadata (`annotations/<id>.pbtxt` and `.system_generated/swarm/members.json`).
// Pure JSONL line parsing lives in Core_Transcript.swift (TranscriptSummary /
// TranscriptParse); all file I/O stays here in the app layer.

enum AITitleReader {

    /// Raw transcript tail snapshot (pure summary + file mtime) so `SessionMonitor`
    /// can evaluate recency-sensitive status via `SessionLogic.resolveLiveSessionStatus`.
    struct TailSnapshot: Equatable {
        let summary: TranscriptSummary
        let fileMtime: TimeInterval
    }

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
        URL(fileURLWithPath: AGYLocator.geminiRoot(home: FileManager.default.homeDirectoryForCurrentUser.path))
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
        var bestPath: String? = nil
        var bestMtime: Date = .distantPast
        for p in AGYLocator.candidateTranscriptPaths(home: home, conversationId: sessionId) {
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

    /// Bounded 128 KB tail snapshot (`TranscriptSummary` + `fileMtime`) from `transcript.jsonl`.
    static func tailSnapshot(inFileAt path: String) -> TailSnapshot {
        let fm = FileManager.default
        let fileMtime = ((try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date)?
            .timeIntervalSince1970) ?? 0
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return TailSnapshot(summary: .empty, fileMtime: fileMtime)
        }
        defer { try? handle.close() }

        guard let end = try? handle.seekToEnd(), end > 0 else {
            return TailSnapshot(summary: .empty, fileMtime: fileMtime)
        }
        let readLen = Int(min(UInt64(128 * 1024), end))
        let offset = end - UInt64(readLen)
        do { try handle.seek(toOffset: offset) } catch {
            return TailSnapshot(summary: .empty, fileMtime: fileMtime)
        }
        let data = handle.readData(ofLength: readLen)
        return TailSnapshot(summary: TranscriptParse.scan(data), fileMtime: fileMtime)
    }

    /// Inspect the last JSONL step in `transcript.jsonl` via `SessionLogic.resolveLiveSessionStatus`.
    static func tailActivity(inFileAt path: String, now: TimeInterval = Date().timeIntervalSince1970) -> TailStepActivity {
        let snap = tailSnapshot(inFileAt: path)
        let createdAt: Double? = snap.summary.lastStepAt.flatMap { d in
            let sec = d.timeIntervalSince1970
            return sec > 946_684_800 ? sec * 1000.0 : nil
        }
        let resolved = SessionLogic.resolveLiveSessionStatus(
            swarmWorkerBusy: false,
            rawStatus: nil,
            notFullyIdle: false,
            transcriptSummary: snap.summary,
            transcriptFileMtime: snap.fileMtime,
            now: now
        )
        return TailStepActivity(
            status: resolved.status,
            waitingFor: resolved.waitingFor,
            createdAtMs: createdAt,
            fileMtime: snap.fileMtime
        )
    }

    // MARK: - Annotations (`annotations/<id>.pbtxt`) & Swarm (`swarm/members.json`)

    /// Read `title:"..."` from `~/.gemini/<surface>/annotations/<sessionId>.pbtxt` via `TranscriptParse`.
    static func annotationTitle(sessionId: String, home: String = NSHomeDirectory()) -> String? {
        guard !sessionId.isEmpty else { return nil }
        for surface in AGYSurface.allCases {
            let root = AGYLocator.surfaceRoot(home: home, surface: surface)
            let path = ((root as NSString).appendingPathComponent("annotations") as NSString)
                .appendingPathComponent("\(sessionId).pbtxt")
            guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            if let parsed = TranscriptParse.parseAnnotationTitle(raw), !parsed.isEmpty {
                return parsed
            }
        }
        return nil
    }

    /// Read swarm coordinator info from `brain/<sessionId>/.system_generated/swarm/members.json`
    /// via `SessionLogic.parseSwarmMembersJSON`.
    static func swarmInfo(sessionId: String, home: String = NSHomeDirectory()) -> SwarmCoordinatorInfo? {
        guard !sessionId.isEmpty else { return nil }
        let fm = FileManager.default
        for brainDir in AGYLocator.brainDirs(home: home) {
            let path = AGYLocator.swarmMembersPath(brainDir: brainDir, conversationId: sessionId)
            guard fm.fileExists(atPath: path),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let parsed = SessionLogic.parseSwarmMembersJSON(data) else {
                continue
            }
            let workers = parsed.members.filter { $0.role == "worker" && !$0.conversationId.isEmpty }
            let workerIds = Set(workers.map(\.conversationId))
            let nonMonitorWorkers = workers.filter { $0.name != "monitor" }
            let anyBusy = SessionLogic.anySwarmWorkerBusy(nonMonitorWorkers)
            return SwarmCoordinatorInfo(title: parsed.title, anyWorkerBusy: anyBusy, workerConversationIds: workerIds)
        }
        return nil
    }

    // MARK: - Helpers

    static func parseValidEpochMs(_ iso: String?) -> Double? {
        guard let d = AppDate.parseISO8601(iso) else { return nil }
        let sec = d.timeIntervalSince1970
        // Reject sentinel dates such as 0001-01-01T00:00:00Z
        guard sec > 946_684_800 else { return nil }
        return sec * 1000.0
    }
}
