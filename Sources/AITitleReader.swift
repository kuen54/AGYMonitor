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
            isWaitingForQuestion: scanned.isWaitingForQuestion,
            latestModel: scanned.latestModel,
            latestContextUsedTokens: scanned.latestContextUsedTokens,
            latestCacheHitRatio: scanned.latestCacheHitRatio,
            recentOutputSamples: scanned.recentOutputSamples
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
        guard AGYLocator.isSafeConversationId(sessionId) else { return nil }
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
        guard AGYLocator.isSafeConversationId(sessionId) else { return nil }
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

    /// Exponentially widening bounded tail reader (256 KB -> 1 MB -> 4 MB cap)
    /// extracting title + latest user prompt without O(N²) chunk re-scanning.
    static func summary(inFileAt path: String, needInstruction: Bool = true) -> TranscriptSummary {
        let fileMtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?
            .timeIntervalSince1970
        guard let handle = FileHandle(forReadingAtPath: path) else { return .empty }
        defer { try? handle.close() }

        guard let end = try? handle.seekToEnd(), end > 0 else { return .empty }
        let windowSizes: [UInt64] = [256 * 1024, 1024 * 1024, 4 * 1024 * 1024]
        var result = TranscriptSummary.empty
        var scannedBytes: UInt64 = 0

        for targetWindow in windowSizes {
            let readLen = min(targetWindow, end)
            if readLen <= scannedBytes { break }
            let offset = end - readLen
            do { try handle.seek(toOffset: offset) } catch { break }
            let data = (try? handle.read(upToCount: Int(readLen))) ?? Data()
            scannedBytes = readLen
            result = TranscriptParse.scan(data, fileMtime: fileMtime)

            if !needInstruction && result.title != nil {
                break
            }
            if needInstruction && result.instruction != nil {
                break
            }
            if readLen >= end {
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
        let data = (try? handle.read(upToCount: readLen)) ?? Data()
        return TailSnapshot(
            summary: TranscriptParse.scan(data, fileMtime: fileMtime > 0 ? fileMtime : nil),
            fileMtime: fileMtime
        )
    }

    // MARK: - Annotations (`annotations/<id>.pbtxt`)

    /// Read `title:"..."` from `~/.gemini/<surface>/annotations/<sessionId>.pbtxt` via `TranscriptParse`.
    static func annotationTitle(sessionId: String, home: String = NSHomeDirectory()) -> String? {
        guard AGYLocator.isSafeConversationId(sessionId) else { return nil }
        for path in AGYLocator.candidateAnnotationPaths(home: home, conversationId: sessionId) {
            guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            if let parsed = TranscriptParse.parseAnnotationTitle(raw), !parsed.isEmpty {
                return parsed
            }
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
