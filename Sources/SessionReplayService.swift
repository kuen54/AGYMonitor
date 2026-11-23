import Foundation
import SQLite3

// MARK: - Universal Session Black Box Disk Indexing & Loading Service (app layer)
//
// On-demand, 0% idle overhead service that discovers recent Antigravity missions
// across all surfaces (CLI, Desktop, IDE via `AGYLocator`), resolves multi-topology
// hierarchies (Swarm, Dynamic Workflow, Subagent Tree, Battle, Solo), parses
// bounded transcript/board files through `ReplayLogic`, and caches loaded
// `ReplayTimeline` instances in a `BoundedLRUState` (capacity 8).
//
// Zero background timers, zero FSEvents, zero work at init — disk I/O runs ONLY
// when the user opens Black Box and invokes `listRecentMissions*` / `loadTimeline*`.
//
// NOT part of AGYCore — never add this file to Package.swift.

final class SessionReplayService {

    // MARK: - Tuning Constants

    static let defaultMissionLimit: Int = 30
    static let maxChildTracks: Int = 16
    static let maxNestingDepth: Int = 3
    static let maxTranscriptBytes: UInt64 = 8 * 1024 * 1024
    static let maxBoardBytes: UInt64 = 4 * 1024 * 1024
    static let timelineCacheCapacity: Int = 8

    private static let peekHeadBytes: Int = 8 * 1024
    private static let peekTailBytes: Int = 8 * 1024
    private static let workflowPeekBytes: Int = 128 * 1024
    private static let minValidEpochSec: Double = 946_684_800.0 // 2000-01-01T00:00:00Z

    // MARK: - State (Queue-Confined)

    private let homeDir: String
    private let envDataDir: String?
    private let queue = DispatchQueue(label: "com.kuen54.AGYMonitor.replay", qos: .userInitiated)
    private var timelineCache = BoundedLRUState<String, ReplayTimeline>(maxEntries: timelineCacheCapacity)

    init(
        homeDir: String = NSHomeDirectory(),
        envDataDir: String? = ProcessInfo.processInfo.environment["ANTIGRAVITY_DATA_DIR"]
    ) {
        self.homeDir = homeDir
        self.envDataDir = envDataDir
    }

    // MARK: - Public API (On-Demand Only)

    /// Synchronously lists up to `limit` recent root missions across all Antigravity surfaces.
    func listRecentMissions(
        liveSessionIds: Set<String> = [],
        limit: Int = defaultMissionLimit
    ) -> [ReplayMissionSummary] {
        queue.sync {
            scanRecentMissions(liveSessionIds: liveSessionIds, limit: max(1, limit))
        }
    }

    /// Asynchronously lists up to `limit` recent root missions off-main and delivers on main thread.
    func listRecentMissionsAsync(
        liveSessionIds: Set<String> = [],
        limit: Int = defaultMissionLimit,
        completion: @escaping ([ReplayMissionSummary]) -> Void
    ) {
        let clampedLimit = max(1, limit)
        queue.async { [weak self] in
            let missions = self?.scanRecentMissions(
                liveSessionIds: liveSessionIds,
                limit: clampedLimit
            ) ?? []
            DispatchQueue.main.async {
                completion(missions)
            }
        }
    }

    /// Synchronously loads and builds a full `ReplayTimeline` for `missionId` (LRU-cached by mtime stamp).
    /// When `isCurrent` is supplied and returns `false`, bails out before SQLite/JSONL reads and returns `nil`.
    func loadTimeline(
        missionId: String,
        isCurrent: (@Sendable () -> Bool)? = nil
    ) -> ReplayTimeline? {
        guard AGYLocator.isSafeConversationId(missionId), isCurrent?() ?? true else { return nil }
        return queue.sync {
            buildAndCacheTimeline(missionId: missionId, isCurrent: isCurrent)
        }
    }

    /// Asynchronously loads a full `ReplayTimeline` off-main and delivers on main thread.
    /// When `isCurrent` is supplied and returns `false`, superseded parses bail out early and return `nil`.
    func loadTimelineAsync(
        missionId: String,
        isCurrent: (@Sendable () -> Bool)? = nil,
        completion: @escaping (ReplayTimeline?) -> Void
    ) {
        guard AGYLocator.isSafeConversationId(missionId), isCurrent?() ?? true else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        queue.async { [weak self] in
            guard let self = self, isCurrent?() ?? true else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let timeline = self.buildAndCacheTimeline(missionId: missionId, isCurrent: isCurrent)
            DispatchQueue.main.async {
                completion(timeline)
            }
        }
    }

    /// Clears the in-memory `BoundedLRUState` timeline cache.
    func clearCache() {
        queue.async { [weak self] in
            self?.timelineCache.removeAll()
        }
    }

    // MARK: - Internal Models

    private struct ConversationRecord {
        var id: String
        var title: String
        var preview: String
        var stepCount: Int
        var lastModifiedSec: Double
        var workspacePath: String
        var agentName: String
        var parentConversationId: String
        var nestingDepth: Int
        var battleId: String
        var winningConversationId: String
        var killed: Bool
        var isInternal: Bool
        var appDataDir: String
    }

    private struct SubagentManifest {
        let conversationId: String
        let typeName: String
        let role: String
        let spawnStepIndex: Int?
        let workspacePath: String
    }

    private struct DiscoveredChild {
        var conversationId: String
        var name: String
        var roleLabel: String
        var kind: ReplayTrackKind
        var parentId: String
        var depth: Int
        var hasRosterName: Bool
        var stepCount: Int
        var lastModifiedSec: Double
    }

    private struct FileStatStamp {
        let mtimeSec: Double
        let size: Int64
    }

    private struct TranscriptPeek {
        let firstTimestampSec: Double?
        let lastTimestampSec: Double?
        let firstUserPrompt: String?
    }

    // MARK: - 1. Multi-Surface Metadata Indexing

    private func loadAllConversationRecords(
        isCurrent: (@Sendable () -> Bool)? = nil
    ) -> [String: ConversationRecord] {
        guard isCurrent?() ?? true else { return [:] }
        let fm = FileManager.default
        let dbEntries = AGYLocator.conversationSummariesDBPaths(home: homeDir, envDataDir: envDataDir)
        var merged: [String: ConversationRecord] = [:]

        for entry in dbEntries {
            guard isCurrent?() ?? true else { return [:] }
            let root = (entry.path as NSString).deletingLastPathComponent
            let surfaceName = (root as NSString).lastPathComponent
            let dbRows = loadSQLiteRows(at: entry.path, defaultSurface: surfaceName)

            for (_, row) in dbRows {
                mergeRecord(row, into: &merged)
            }

            let metaJSONPath = ((root as NSString).appendingPathComponent("cache") as NSString)
                .appendingPathComponent("conversation_metadata.json")
            if fm.fileExists(atPath: metaJSONPath),
               let data = try? Data(contentsOf: URL(fileURLWithPath: metaJSONPath)) {
                let parsed = SessionLogic.parseConversationMetadataJSON(data)
                for (_, agy) in parsed {
                    guard AGYLocator.isSafeConversationId(agy.conversationId) else { continue }
                    let row = ConversationRecord(
                        id: agy.conversationId,
                        title: agy.title ?? "",
                        preview: agy.preview ?? "",
                        stepCount: agy.stepCount,
                        lastModifiedSec: (agy.effectiveUpdatedAtMs ?? 0) / 1000.0,
                        workspacePath: agy.primaryWorkspace ?? "",
                        agentName: agy.agentName ?? "",
                        parentConversationId: agy.parentConversationId ?? "",
                        nestingDepth: agy.nestingDepth,
                        battleId: "",
                        winningConversationId: "",
                        killed: agy.isKilled,
                        isInternal: SessionLogic.isSubagentOrInternal(agy),
                        appDataDir: agy.appDataDir ?? surfaceName
                    )
                    mergeRecord(row, into: &merged)
                }
            }

            // Graceful fallback for roots without `conversation_summaries.db`:
            // discover sessions directly from `brain/<conv-id>/.system_generated/logs/transcript.jsonl`.
            if dbRows.isEmpty {
                let brainDir = (root as NSString).appendingPathComponent("brain")
                scanBrainFallback(brainDir: brainDir, surfaceName: surfaceName, into: &merged)
            }
        }

        // Handle custom `envDataDir` pointing directly at a `brain` folder
        if merged.isEmpty {
            for brainDir in AGYLocator.brainDirs(home: homeDir, envDataDir: envDataDir) {
                let surfaceName = ((brainDir as NSString).deletingLastPathComponent as NSString).lastPathComponent
                scanBrainFallback(brainDir: brainDir, surfaceName: surfaceName, into: &merged)
            }
        }

        return merged
    }

    private func mergeRecord(_ incoming: ConversationRecord, into table: inout [String: ConversationRecord]) {
        guard !incoming.id.isEmpty else { return }
        guard var existing = table[incoming.id] else {
            table[incoming.id] = incoming
            return
        }
        if incoming.lastModifiedSec > existing.lastModifiedSec {
            existing.lastModifiedSec = incoming.lastModifiedSec
            if !incoming.appDataDir.isEmpty {
                existing.appDataDir = incoming.appDataDir
            }
        }
        if incoming.stepCount > existing.stepCount {
            existing.stepCount = incoming.stepCount
        }
        if existing.title.isEmpty && !incoming.title.isEmpty {
            existing.title = incoming.title
        }
        if existing.preview.isEmpty && !incoming.preview.isEmpty {
            existing.preview = incoming.preview
        }
        if existing.workspacePath.isEmpty && !incoming.workspacePath.isEmpty {
            existing.workspacePath = incoming.workspacePath
        }
        if existing.agentName.isEmpty && !incoming.agentName.isEmpty {
            existing.agentName = incoming.agentName
        }
        if existing.parentConversationId.isEmpty && !incoming.parentConversationId.isEmpty {
            existing.parentConversationId = incoming.parentConversationId
        }
        if incoming.nestingDepth > existing.nestingDepth {
            existing.nestingDepth = incoming.nestingDepth
        }
        if existing.battleId.isEmpty && !incoming.battleId.isEmpty {
            existing.battleId = incoming.battleId
        }
        if existing.winningConversationId.isEmpty && !incoming.winningConversationId.isEmpty {
            existing.winningConversationId = incoming.winningConversationId
        }
        if incoming.killed {
            existing.killed = true
        }
        if incoming.isInternal {
            existing.isInternal = true
        }
        table[incoming.id] = existing
    }

    /// Reads `conversation_summaries.db` using `SessionMonitor.openReadOnlySQLite(at:)`
    /// (`AGYLocator.sqliteReadOnlyURIs` WAL-safe + `immutable=1` fallback).
    /// Schema-resilient via `PRAGMA table_info` so older/newer Antigravity DBs all work cleanly.
    private func loadSQLiteRows(at dbPath: String, defaultSurface: String) -> [String: ConversationRecord] {
        guard let db = SessionMonitor.openReadOnlySQLite(at: dbPath) else { return [:] }
        defer { sqlite3_close_v2(db) }

        let columns = tableColumns(in: db, table: "conversation_summaries")
        guard columns.contains("conversation_id") else { return [:] }

        func col(_ name: String, fallback: String) -> String {
            columns.contains(name) ? name : fallback
        }

        let sql = """
            SELECT
                conversation_id,
                \(col("title", fallback: "''")),
                \(col("preview", fallback: "''")),
                \(col("step_count", fallback: "0")),
                \(col("last_modified_time", fallback: "''")),
                \(col("workspace_uris", fallback: "''")),
                \(col("agent_name", fallback: "''")),
                \(col("parent_conversation_id", fallback: "''")),
                \(col("nesting_depth", fallback: "0")),
                \(col("battle_id", fallback: "''")),
                \(col("winning_conversation_id", fallback: "''")),
                \(col("killed", fallback: "0")),
                \(col("app_data_dir", fallback: "''"))
            FROM conversation_summaries
            """

        var stmt: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            sqlite3_finalize(stmt)
            return [:]
        }
        defer { sqlite3_finalize(s) }

        var rows: [String: ConversationRecord] = [:]
        while sqlite3_step(s) == SQLITE_ROW {
            guard let idPtr = sqlite3_column_text(s, 0) else { continue }
            let convId = String(cString: idPtr).trimmingCharacters(in: .whitespacesAndNewlines)
            guard AGYLocator.isSafeConversationId(convId) else { continue }

            let title = sqliteText(s, 1)
            let preview = sqliteText(s, 2)
            let stepCount = max(0, Int(sqlite3_column_int(s, 3)))
            let lastModRaw = sqliteText(s, 4)
            let workspaceURIsJSON = sqliteText(s, 5)
            let agentName = sqliteText(s, 6)
            let parentId = sqliteText(s, 7)
            let nestingDepth = max(0, Int(sqlite3_column_int(s, 8)))
            let battleId = sqliteText(s, 9)
            let winningId = sqliteText(s, 10)
            let killed = sqlite3_column_int(s, 11) != 0
            let appDataDirRaw = sqliteText(s, 12)
            let appDataDir = appDataDirRaw.isEmpty ? defaultSurface : appDataDirRaw

            let workspacePaths = SessionLogic.parseWorkspaceURIsJSON(workspaceURIsJSON)
            let lastModSec = Self.parseTimestampSec(lastModRaw) ?? 0

            rows[convId] = ConversationRecord(
                id: convId,
                title: title,
                preview: preview,
                stepCount: stepCount,
                lastModifiedSec: lastModSec,
                workspacePath: workspacePaths.first ?? "",
                agentName: agentName,
                parentConversationId: parentId,
                nestingDepth: nestingDepth,
                battleId: battleId,
                winningConversationId: winningId,
                killed: killed,
                isInternal: !parentId.isEmpty || nestingDepth > 0,
                appDataDir: appDataDir
            )
        }
        return rows
    }

    private func tableColumns(in db: OpaquePointer, table: String) -> Set<String> {
        var stmt: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK,
              let s = stmt else {
            sqlite3_finalize(stmt)
            return []
        }
        defer { sqlite3_finalize(s) }
        var cols = Set<String>()
        while sqlite3_step(s) == SQLITE_ROW {
            if let ptr = sqlite3_column_text(s, 1) {
                cols.insert(String(cString: ptr))
            }
        }
        return cols
    }

    private func sqliteText(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let ptr = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: ptr)
    }

    private func scanBrainFallback(
        brainDir: String,
        surfaceName: String,
        into table: inout [String: ConversationRecord]
    ) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: brainDir, isDirectory: &isDir), isDir.boolValue,
              let entries = try? fm.contentsOfDirectory(atPath: brainDir) else {
            return
        }

        var discoveredIds: [String] = []
        for convId in entries where AGYLocator.isSafeConversationId(convId) {
            let txPath = AGYLocator.transcriptPath(brainDir: brainDir, conversationId: convId)
            guard let stat = Self.statFile(at: txPath), stat.size > 0 else { continue }
            discoveredIds.append(convId)
            let row = ConversationRecord(
                id: convId,
                title: "",
                preview: "",
                stepCount: 0,
                lastModifiedSec: stat.mtimeSec,
                workspacePath: "",
                agentName: "",
                parentConversationId: "",
                nestingDepth: 0,
                battleId: "",
                winningConversationId: "",
                killed: false,
                isInternal: false,
                appDataDir: surfaceName
            )
            mergeRecord(row, into: &table)
        }

        // Infer parent -> child edges from disk manifests (`subagents/*.json` & `swarm/members.json`)
        // so fallback roots without `conversation_summaries.db` still hide child tracks properly.
        var inferredParents: [String: [String]] = [:]
        for parentId in discoveredIds {
            if let swarm = inspectSwarmDir(brainDir: brainDir, conversationId: parentId) {
                for member in swarm.members where member.role.lowercased() != "coordinator"
                    && !member.conversationId.isEmpty
                    && member.conversationId != parentId {
                    inferredParents[member.conversationId, default: []].append(parentId)
                }
            }
            let subDir = AGYLocator.subagentsDir(brainDir: brainDir, conversationId: parentId)
            if let subFiles = try? fm.contentsOfDirectory(atPath: subDir) {
                for file in subFiles where file.hasSuffix(".json") {
                    let childId = String(file.dropLast(".json".count))
                    if AGYLocator.isSafeConversationId(childId) && childId != parentId {
                        inferredParents[childId, default: []].append(parentId)
                    }
                }
            }
        }

        for (childId, parents) in inferredParents {
            guard var childRec = table[childId], childRec.parentConversationId.isEmpty else { continue }
            // Prefer a parent that is not itself a child (root), else the earliest-starting parent
            // so even cyclic manifests never misclassify the true root as a child.
            let childFirstTs = Self.peekTranscriptHeadAndTail(
                at: AGYLocator.transcriptPath(brainDir: brainDir, conversationId: childId)
            ).firstTimestampSec ?? Double.greatestFiniteMagnitude

            let validParent = parents.first { pid in
                let parentFirstTs = Self.peekTranscriptHeadAndTail(
                    at: AGYLocator.transcriptPath(brainDir: brainDir, conversationId: pid)
                ).firstTimestampSec ?? Double.greatestFiniteMagnitude
                return parentFirstTs <= childFirstTs
            }
            if let pid = validParent {
                childRec.parentConversationId = pid
                childRec.nestingDepth = max(childRec.nestingDepth, 1)
                childRec.isInternal = true
                table[childId] = childRec
            }
        }
    }

    // MARK: - 2. Fast Mission List Indexing (<150ms)

    private func scanRecentMissions(
        liveSessionIds: Set<String>,
        limit: Int
    ) -> [ReplayMissionSummary] {
        let records = loadAllConversationRecords()
        guard !records.isEmpty else { return [] }

        var childrenByParent: [String: [ConversationRecord]] = [:]
        var battleGroups: [String: [ConversationRecord]] = [:]

        for rec in records.values {
            if !rec.parentConversationId.isEmpty {
                childrenByParent[rec.parentConversationId, default: []].append(rec)
            }
            if !rec.battleId.isEmpty {
                battleGroups[rec.battleId, default: []].append(rec)
            }
        }

        // Collapse each battle group to a single representative root so battle branches
        // appear together in one mission rather than duplicating entries in the picker.
        var skippedBattleBranchIds = Set<String>()
        for (_, group) in battleGroups where group.count > 1 {
            let winnerId = group.first(where: { !$0.winningConversationId.isEmpty })?.winningConversationId
            let primary: ConversationRecord
            if let wid = winnerId, let found = group.first(where: { $0.id == wid }) {
                primary = found
            } else {
                primary = group.max { a, b in
                    if a.lastModifiedSec != b.lastModifiedSec { return a.lastModifiedSec < b.lastModifiedSec }
                    if a.stepCount != b.stepCount { return a.stepCount < b.stepCount }
                    return a.id > b.id
                }!
            }
            for item in group where item.id != primary.id {
                skippedBattleBranchIds.insert(item.id)
            }
        }

        // Filter out internal children whose parent exists (or marked internal / nested)
        let rootCandidates: [ConversationRecord] = records.values.filter { rec in
            if skippedBattleBranchIds.contains(rec.id) { return false }
            if liveSessionIds.contains(rec.id) { return true }
            if !rec.parentConversationId.isEmpty {
                if records[rec.parentConversationId] != nil
                    || locateBrainDir(for: rec.parentConversationId, preferredSurface: rec.appDataDir) != nil {
                    return false
                }
            }
            if rec.nestingDepth > 0 || rec.isInternal {
                return false
            }
            return true
        }.sorted { a, b in
            if a.lastModifiedSec != b.lastModifiedSec { return a.lastModifiedSec > b.lastModifiedSec }
            if a.stepCount != b.stepCount { return a.stepCount > b.stepCount }
            return a.id < b.id
        }

        var missions: [ReplayMissionSummary] = []
        missions.reserveCapacity(min(limit, rootCandidates.count))
        var claimedChildIds = Set<String>()

        for rec in rootCandidates {
            guard missions.count < limit else { break }
            if claimedChildIds.contains(rec.id) && !liveSessionIds.contains(rec.id) {
                continue
            }

            let brainDir = locateBrainDir(for: rec.id, preferredSurface: rec.appDataDir)
            let txPath = brainDir.map { AGYLocator.transcriptPath(brainDir: $0, conversationId: rec.id) }
            let txStat = txPath.flatMap(Self.statFile(at:))
            let hasRootTranscript = (txStat?.size ?? 0) > 0

            let isLive = liveSessionIds.contains(rec.id)

            // Fast multi-topology discovery (lightweight metadata only; no full JSONL parse)
            let swarmResult = brainDir.flatMap { inspectSwarmDir(brainDir: $0, conversationId: rec.id) }
            let hasSwarmDir = swarmResult?.exists ?? false
            let swarmTitle = swarmResult?.title

            let discoveredChildren = discoverChildren(
                rootId: rec.id,
                rootBrainDir: brainDir,
                rootRecord: rec,
                records: records,
                childrenByParent: childrenByParent,
                battleGroups: battleGroups,
                preloadedSwarmMembers: swarmResult?.members
            )

            for child in discoveredChildren {
                claimedChildIds.insert(child.conversationId)
            }

            // Skip empty/abandoned placeholder rows that have no transcript and no children
            if !hasRootTranscript && discoveredChildren.isEmpty && !isLive {
                continue
            }

            // Fast head/tail peek (<=16KB) for accurate startedAt, lastActiveAt, and fallback prompt
            let peek: TranscriptPeek = hasRootTranscript && txPath != nil
                ? Self.peekTranscriptHeadAndTail(at: txPath!)
                : TranscriptPeek(firstTimestampSec: nil, lastTimestampSec: nil, firstUserPrompt: nil)

            let lastActiveAt = max(
                rec.lastModifiedSec,
                peek.lastTimestampSec ?? 0,
                txStat?.mtimeSec ?? 0
            )
            let startedAt: Double = {
                if let first = peek.firstTimestampSec, first > Self.minValidEpochSec {
                    return min(first, lastActiveAt > 0 ? lastActiveAt : first)
                }
                if let txPath = txPath, let created = Self.creationDateSec(at: txPath),
                   created > Self.minValidEpochSec {
                    return min(created, lastActiveAt > 0 ? lastActiveAt : created)
                }
                return lastActiveAt
            }()
            let durationSec = max(0.0, lastActiveAt - startedAt)

            // Determine topology matching ReplayLogic.classifyTopology priority:
            // battle > swarm > dynamicWorkflow > subagentTree > solo
            let topology = classifySummaryTopology(
                record: rec,
                hasSwarmDir: hasSwarmDir,
                children: discoveredChildren,
                rootTranscriptPath: hasRootTranscript ? txPath : nil
            )

            let title = resolveMissionTitle(
                conversationId: rec.id,
                dbTitle: rec.title,
                dbPreview: rec.preview,
                swarmTitle: swarmTitle,
                transcriptPrompt: peek.firstUserPrompt
            )

            let workspaceLabel = resolveWorkspaceLabel(
                primaryPath: rec.workspacePath,
                brainDir: brainDir,
                conversationId: rec.id
            )

            let trackCount = 1 + discoveredChildren.count
            let stepCount = rec.stepCount > 0 ? rec.stepCount : (hasRootTranscript ? 1 : 0)

            missions.append(ReplayMissionSummary(
                id: rec.id,
                title: title,
                workspaceLabel: workspaceLabel,
                topology: topology,
                startedAt: startedAt,
                lastActiveAt: lastActiveAt,
                durationSec: durationSec,
                trackCount: trackCount,
                stepCount: stepCount,
                isLive: isLive
            ))
        }

        return missions
    }

    private func classifySummaryTopology(
        record: ConversationRecord,
        hasSwarmDir: Bool,
        children: [DiscoveredChild],
        rootTranscriptPath: String?
    ) -> SessionTopologyKind {
        if !record.battleId.isEmpty || children.contains(where: { $0.kind == .battleBranch }) {
            return .battle
        }
        if hasSwarmDir || children.contains(where: { $0.kind == .swarmWorker }) {
            return .swarm
        }
        if children.contains(where: { $0.kind == .workflowStage }) {
            return .dynamicWorkflow
        }
        // Lightweight bounded tool-name peek for `run_workflow` / `invoke_subagent`
        if let txPath = rootTranscriptPath {
            let hints = Self.peekTopologyToolHints(at: txPath)
            if hints.hasRunWorkflow {
                return .dynamicWorkflow
            }
            if !children.isEmpty || hints.hasSubagentTool {
                return .subagentTree
            }
            return .solo
        }
        return children.isEmpty ? .solo : .subagentTree
    }

    // MARK: - 3. Full Timeline Loading (LRU-Cached + Bounded I/O)

    private func buildAndCacheTimeline(
        missionId: String,
        isCurrent: (@Sendable () -> Bool)? = nil
    ) -> ReplayTimeline? {
        guard isCurrent?() ?? true else { return nil }
        let records = loadAllConversationRecords(isCurrent: isCurrent)
        guard isCurrent?() ?? true else { return nil }
        let rootRecord = records[missionId]
        let preferredSurface = rootRecord?.appDataDir

        let rootBrainDir = locateBrainDir(for: missionId, preferredSurface: preferredSurface)
        let rootTranscriptPath = rootBrainDir.map {
            AGYLocator.transcriptPath(brainDir: $0, conversationId: missionId)
        }
        let rootStat = rootTranscriptPath.flatMap(Self.statFile(at:))

        guard rootRecord != nil || rootBrainDir != nil else {
            return nil
        }

        var childrenByParent: [String: [ConversationRecord]] = [:]
        var battleGroups: [String: [ConversationRecord]] = [:]
        for rec in records.values {
            if !rec.parentConversationId.isEmpty {
                childrenByParent[rec.parentConversationId, default: []].append(rec)
            }
            if !rec.battleId.isEmpty {
                battleGroups[rec.battleId, default: []].append(rec)
            }
        }

        guard isCurrent?() ?? true else { return nil }
        let swarmResult = rootBrainDir.flatMap { inspectSwarmDir(brainDir: $0, conversationId: missionId) }
        let hasSwarmDir = swarmResult?.exists ?? false
        let swarmTitle = swarmResult?.title
        let boardPath = rootBrainDir.map { Self.swarmBoardPath(brainDir: $0, conversationId: missionId) }
        let boardStat = boardPath.flatMap(Self.statFile(at:))
        let membersPath = rootBrainDir.map { AGYLocator.swarmMembersPath(brainDir: $0, conversationId: missionId) }
        let membersStat = membersPath.flatMap(Self.statFile(at:))

        let allChildren = discoverChildren(
            rootId: missionId,
            rootBrainDir: rootBrainDir,
            rootRecord: rootRecord,
            records: records,
            childrenByParent: childrenByParent,
            battleGroups: battleGroups,
            preloadedSwarmMembers: swarmResult?.members
        )

        guard isCurrent?() ?? true else { return nil }

        // Resolve transcript paths for discovered children and cap to `maxChildTracks` (16),
        // keeping shallower depth first so parent chains remain intact, then most recently active.
        var childCandidates: [(child: DiscoveredChild, txPath: String, stat: FileStatStamp)] = []
        for child in allChildren {
            let childSurface = records[child.conversationId]?.appDataDir ?? preferredSurface
            guard let txPath = locateTranscriptPath(
                for: child.conversationId,
                preferredSurface: childSurface
            ), let stat = Self.statFile(at: txPath), stat.size > 0 else {
                continue
            }
            childCandidates.append((child, txPath, stat))
        }

        childCandidates.sort { a, b in
            if a.child.depth != b.child.depth { return a.child.depth < b.child.depth }
            let aTime = max(a.child.lastModifiedSec, a.stat.mtimeSec)
            let bTime = max(b.child.lastModifiedSec, b.stat.mtimeSec)
            if aTime != bTime { return aTime > bTime }
            if a.child.stepCount != b.child.stepCount { return a.child.stepCount > b.child.stepCount }
            if a.child.name != b.child.name { return a.child.name < b.child.name }
            return a.child.conversationId < b.child.conversationId
        }

        let selectedChildren = Array(childCandidates.prefix(Self.maxChildTracks))

        // Build composite mtimeStamp cache key (`missionId + mtimeStamp`)
        let cacheKey = Self.buildCacheKey(
            missionId: missionId,
            rootStat: rootStat,
            membersStat: membersStat,
            boardStat: boardStat,
            childStats: selectedChildren.map { ($0.child.conversationId, $0.stat) }
        )

        if let cached = timelineCache.get(cacheKey) {
            return (isCurrent?() ?? true) ? cached : nil
        }

        guard isCurrent?() ?? true else { return nil }

        // Parse root transcript (bounded <= 8 MB tail on clean line boundary)
        let rootSteps: [ReplayRawStep]
        if let txPath = rootTranscriptPath,
           let text = Self.readBoundedTailText(at: txPath, maxBytes: Self.maxTranscriptBytes) {
            guard isCurrent?() ?? true else { return nil }
            rootSteps = ReplayLogic.parseTranscriptSteps(jsonlText: text)
        } else {
            rootSteps = []
        }

        guard isCurrent?() ?? true else { return nil }

        // Parse swarm board (bounded <= 4 MB tail on clean line boundary)
        let boardEvents: [ReplayBoardInput]
        if let bPath = boardPath,
           (boardStat?.size ?? 0) > 0,
           let text = Self.readBoundedTailText(at: bPath, maxBytes: Self.maxBoardBytes) {
            guard isCurrent?() ?? true else { return nil }
            boardEvents = ReplayLogic.parseSwarmBoard(jsonlText: text)
        } else {
            boardEvents = []
        }

        // Parse up to 16 child transcripts (each bounded <= 8 MB tail on clean line boundary)
        var childInputs: [ReplayChildInput] = []
        childInputs.reserveCapacity(selectedChildren.count)
        for item in selectedChildren {
            guard isCurrent?() ?? true else { return nil }
            guard let text = Self.readBoundedTailText(at: item.txPath, maxBytes: Self.maxTranscriptBytes) else {
                continue
            }
            guard isCurrent?() ?? true else { return nil }
            let steps = ReplayLogic.parseTranscriptSteps(jsonlText: text)
            guard !steps.isEmpty else { continue }
            childInputs.append(ReplayChildInput(
                conversationId: item.child.conversationId,
                name: item.child.name,
                roleLabel: item.child.roleLabel,
                kind: item.child.kind,
                parentId: item.child.parentId,
                depth: item.child.depth,
                steps: steps
            ))
        }

        guard isCurrent?() ?? true else { return nil }

        guard !rootSteps.isEmpty || !childInputs.isEmpty || !boardEvents.isEmpty else {
            return nil
        }

        let firstUserPrompt: String? = rootTranscriptPath.flatMap {
            Self.peekTranscriptHeadAndTail(at: $0).firstUserPrompt
        }
        let title = resolveMissionTitle(
            conversationId: missionId,
            dbTitle: rootRecord?.title ?? "",
            dbPreview: rootRecord?.preview ?? "",
            swarmTitle: swarmTitle,
            transcriptPrompt: firstUserPrompt
        )
        let workspaceLabel = resolveWorkspaceLabel(
            primaryPath: rootRecord?.workspacePath ?? "",
            brainDir: rootBrainDir,
            conversationId: missionId
        )
        let battleId: String? = {
            let raw = rootRecord?.battleId.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return raw.isEmpty ? nil : raw
        }()

        let meta = ReplayMissionMeta(
            conversationId: missionId,
            title: title,
            workspaceLabel: workspaceLabel,
            battleId: battleId,
            hasSwarmDir: hasSwarmDir
        )

        let timeline = ReplayLogic.buildTimeline(
            meta: meta,
            rootSteps: rootSteps,
            children: childInputs,
            boardEvents: boardEvents
        )

        timelineCache.set(timeline, for: cacheKey)
        return timeline
    }

    // MARK: - 4. Multi-Topology Hierarchy Discovery (BFS up to depth 3, cycle-guarded)

    private func discoverChildren(
        rootId: String,
        rootBrainDir: String?,
        rootRecord: ConversationRecord?,
        records: [String: ConversationRecord],
        childrenByParent: [String: [ConversationRecord]],
        battleGroups: [String: [ConversationRecord]],
        preloadedSwarmMembers: [AGYSwarmMember]?
    ) -> [DiscoveredChild] {
        var visited = Set<String>([rootId])
        var byId: [String: DiscoveredChild] = [:]
        var insertionOrder: [String] = []

        func upsertChild(
            id: String,
            name: String,
            roleLabel: String,
            kind: ReplayTrackKind,
            parentId: String,
            depth: Int,
            isRosterName: Bool
        ) -> Bool {
            guard AGYLocator.isSafeConversationId(id), id != rootId else { return false }
            let dbRec = records[id]
            let stepCount = dbRec?.stepCount ?? 0
            let lastMod = dbRec?.lastModifiedSec ?? 0

            if var existing = byId[id] {
                if isRosterName && !name.isEmpty {
                    existing.name = name
                    existing.hasRosterName = true
                } else if existing.name.isEmpty && !name.isEmpty {
                    existing.name = name
                }
                if existing.kind == .subagent && kind != .subagent {
                    existing.kind = kind
                }
                if !roleLabel.isEmpty && (existing.roleLabel.isEmpty || existing.roleLabel == "Subagent") {
                    existing.roleLabel = roleLabel
                }
                if depth < existing.depth {
                    existing.depth = depth
                    existing.parentId = parentId
                }
                byId[id] = existing
                return false
            }

            let resolvedName = !name.isEmpty
                ? name
                : (dbRec?.agentName.isEmpty == false ? dbRec!.agentName : String(id.prefix(8)))
            let resolvedRole = !roleLabel.isEmpty ? roleLabel : Self.defaultRoleLabel(for: kind)

            byId[id] = DiscoveredChild(
                conversationId: id,
                name: resolvedName,
                roleLabel: resolvedRole,
                kind: kind,
                parentId: parentId,
                depth: depth,
                hasRosterName: isRosterName,
                stepCount: stepCount,
                lastModifiedSec: lastMod
            )
            insertionOrder.append(id)
            return visited.insert(id).inserted
        }

        // Source A: Battle siblings sharing the same non-empty `battle_id`
        if let battleId = rootRecord?.battleId, !battleId.isEmpty,
           let siblings = battleGroups[battleId] {
            let orderedSiblings = siblings
                .filter { $0.id != rootId }
                .sorted { a, b in
                    if a.lastModifiedSec != b.lastModifiedSec { return a.lastModifiedSec < b.lastModifiedSec }
                    return a.id < b.id
                }
            for (idx, sib) in orderedSiblings.enumerated() {
                let label = !sib.agentName.isEmpty
                    ? sib.agentName
                    : (!sib.title.isEmpty ? sib.title : "branch-\(idx + 1)")
                let role = !sib.title.isEmpty ? sib.title : "Battle Branch \(idx + 1)"
                _ = upsertChild(
                    id: sib.id,
                    name: label,
                    roleLabel: role,
                    kind: .battleBranch,
                    parentId: rootId,
                    depth: 1,
                    isRosterName: false
                )
            }
        }

        // BFS queue for recursive child discovery up to `maxNestingDepth` (3)
        var bfsQueue: [(parentId: String, brainDir: String?, depth: Int)] = [
            (rootId, rootBrainDir, 1)
        ]
        var cursor = 0

        while cursor < bfsQueue.count {
            let current = bfsQueue[cursor]
            cursor += 1
            guard current.depth <= Self.maxNestingDepth else { continue }

            // Source B: Swarm `members.json` roster
            let swarmMembers: [AGYSwarmMember]
            if current.parentId == rootId, let preloaded = preloadedSwarmMembers {
                swarmMembers = preloaded
            } else if let bDir = current.brainDir,
                      let info = inspectSwarmDir(brainDir: bDir, conversationId: current.parentId) {
                swarmMembers = info.members
            } else {
                swarmMembers = []
            }

            for member in swarmMembers {
                guard !member.conversationId.isEmpty,
                      member.conversationId != current.parentId,
                      member.role.lowercased() != "coordinator" else {
                    continue
                }
                let inserted = upsertChild(
                    id: member.conversationId,
                    name: member.name,
                    roleLabel: "Swarm Worker",
                    kind: .swarmWorker,
                    parentId: current.parentId,
                    depth: current.depth,
                    isRosterName: true
                )
                if inserted && current.depth < Self.maxNestingDepth {
                    let childSurface = records[member.conversationId]?.appDataDir ?? rootRecord?.appDataDir
                    let childBrain = locateBrainDir(for: member.conversationId, preferredSurface: childSurface)
                    bfsQueue.append((member.conversationId, childBrain, current.depth + 1))
                }
            }

            // Source C: `.system_generated/subagents/*.json` manifests
            if let bDir = current.brainDir {
                let manifests = readSubagentManifests(brainDir: bDir, conversationId: current.parentId)
                for manifest in manifests {
                    let kind = Self.classifySubagentKind(
                        typeName: manifest.typeName,
                        role: manifest.role
                    )
                    let dbAgentName = records[manifest.conversationId]?.agentName ?? ""
                    let bestName: String = {
                        if !dbAgentName.isEmpty { return dbAgentName }
                        if !manifest.typeName.isEmpty && manifest.typeName.lowercased() != "worker" {
                            return manifest.typeName
                        }
                        if !manifest.role.isEmpty {
                            return Self.compactName(from: manifest.role)
                        }
                        return String(manifest.conversationId.prefix(8))
                    }()
                    let roleLabel = !manifest.role.isEmpty
                        ? manifest.role
                        : (!manifest.typeName.isEmpty ? manifest.typeName : Self.defaultRoleLabel(for: kind))
                    let inserted = upsertChild(
                        id: manifest.conversationId,
                        name: bestName,
                        roleLabel: roleLabel,
                        kind: kind,
                        parentId: current.parentId,
                        depth: current.depth,
                        isRosterName: false
                    )
                    if inserted && current.depth < Self.maxNestingDepth {
                        let childSurface = records[manifest.conversationId]?.appDataDir ?? rootRecord?.appDataDir
                        let childBrain = locateBrainDir(for: manifest.conversationId, preferredSurface: childSurface)
                        bfsQueue.append((manifest.conversationId, childBrain, current.depth + 1))
                    }
                }
            }

            // Source D: `conversation_summaries.db` `parent_conversation_id` rows
            if let dbChildren = childrenByParent[current.parentId] {
                for childRec in dbChildren {
                    let inferredKind = Self.classifyDBChildKind(
                        agentName: childRec.agentName,
                        parentHasSwarm: (current.parentId == rootId && !swarmMembers.isEmpty)
                    )
                    let name = !childRec.agentName.isEmpty
                        ? childRec.agentName
                        : (!childRec.title.isEmpty ? childRec.title : String(childRec.id.prefix(8)))
                    let roleLabel = !childRec.title.isEmpty
                        ? childRec.title
                        : Self.defaultRoleLabel(for: inferredKind)
                    let inserted = upsertChild(
                        id: childRec.id,
                        name: name,
                        roleLabel: roleLabel,
                        kind: inferredKind,
                        parentId: current.parentId,
                        depth: current.depth,
                        isRosterName: false
                    )
                    if inserted && current.depth < Self.maxNestingDepth {
                        let childBrain = locateBrainDir(for: childRec.id, preferredSurface: childRec.appDataDir)
                        bfsQueue.append((childRec.id, childBrain, current.depth + 1))
                    }
                }
            }
        }

        return insertionOrder.compactMap { byId[$0] }
    }

    private static func classifySubagentKind(typeName: String, role: String) -> ReplayTrackKind {
        let lowerType = typeName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lowerRole = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowerType == "worker" || lowerType == "swarm-worker" || lowerType == "swarm_worker" {
            return .swarmWorker
        }
        if lowerType.contains("workflow")
            || lowerType.contains("stage")
            || lowerType.contains("pipeline")
            || lowerRole.hasPrefix("workflow stage") {
            return .workflowStage
        }
        return .subagent
    }

    private static func classifyDBChildKind(agentName: String, parentHasSwarm: Bool) -> ReplayTrackKind {
        let lower = agentName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.contains("workflow") || lower.contains("stage") || lower.contains("pipeline") {
            return .workflowStage
        }
        if parentHasSwarm {
            return .swarmWorker
        }
        return .subagent
    }

    private static func defaultRoleLabel(for kind: ReplayTrackKind) -> String {
        switch kind {
        case .root:          return "Root Agent"
        case .swarmWorker:   return "Swarm Worker"
        case .workflowStage: return "Workflow Stage"
        case .subagent:      return "Subagent"
        case .battleBranch:  return "Battle Branch"
        }
    }

    private static func compactName(from raw: String) -> String {
        let words = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        let joined = words.prefix(3).joined(separator: " ")
        if joined.count <= 20 { return joined }
        return String(joined.prefix(19)) + "…"
    }

    // MARK: - 5. Swarm & Subagent Filesystem Readers

    private struct SwarmDirInspection {
        let exists: Bool
        let title: String?
        let members: [AGYSwarmMember]
    }

    private func inspectSwarmDir(brainDir: String, conversationId: String) -> SwarmDirInspection? {
        guard AGYLocator.isSafeConversationId(conversationId) else { return nil }
        let fm = FileManager.default
        let membersPath = AGYLocator.swarmMembersPath(brainDir: brainDir, conversationId: conversationId)
        let boardPath = Self.swarmBoardPath(brainDir: brainDir, conversationId: conversationId)

        let hasMembers = fm.fileExists(atPath: membersPath)
        let hasBoard = fm.fileExists(atPath: boardPath)
        guard hasMembers || hasBoard else { return nil }

        if hasMembers,
           let data = try? Data(contentsOf: URL(fileURLWithPath: membersPath)),
           let parsed = SessionLogic.parseSwarmMembersJSON(data) {
            return SwarmDirInspection(exists: true, title: parsed.title, members: parsed.members)
        }
        return SwarmDirInspection(exists: true, title: nil, members: [])
    }

    private func readSubagentManifests(brainDir: String, conversationId: String) -> [SubagentManifest] {
        guard AGYLocator.isSafeConversationId(conversationId) else { return [] }
        let fm = FileManager.default
        let subagentsDir = AGYLocator.subagentsDir(brainDir: brainDir, conversationId: conversationId)
        guard let files = try? fm.contentsOfDirectory(atPath: subagentsDir) else { return [] }

        var manifests: [SubagentManifest] = []
        for file in files.sorted() where file.hasSuffix(".json") {
            let fullPath = (subagentsDir as NSString).appendingPathComponent(file)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: fullPath)),
                  let record = SessionLogic.parseSubagentRecordJSON(data),
                  AGYLocator.isSafeConversationId(record.conversationId) else {
                continue
            }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let spawnStep = obj?["spawnStepIndex"] as? Int
            let workspacePath: String = {
                if let uris = obj?["workspaceUris"] as? [String] {
                    for u in uris {
                        if let p = SessionLogic.workspacePath(fromURI: u) { return p }
                    }
                }
                return ""
            }()
            manifests.append(SubagentManifest(
                conversationId: record.conversationId,
                typeName: record.typeName ?? "",
                role: record.role ?? "",
                spawnStepIndex: spawnStep,
                workspacePath: workspacePath
            ))
        }
        return manifests
    }

    // MARK: - 6. Path Resolution Helpers (Strictly via `AGYLocator`)

    private func orderedBrainDirs(preferredSurface: String?) -> [String] {
        var ordered: [String] = []
        if let pref = preferredSurface?.trimmingCharacters(in: .whitespacesAndNewlines),
           let surface = AGYSurface(rawValue: pref) {
            let prefRoot = AGYLocator.surfaceRoot(home: homeDir, surface: surface)
            ordered.append((prefRoot as NSString).appendingPathComponent("brain"))
        }
        for dir in AGYLocator.brainDirs(home: homeDir, envDataDir: envDataDir) {
            if !ordered.contains(dir) {
                ordered.append(dir)
            }
        }
        return ordered
    }

    private func locateBrainDir(for conversationId: String, preferredSurface: String?) -> String? {
        guard AGYLocator.isSafeConversationId(conversationId) else { return nil }
        let fm = FileManager.default
        var bestDir: String? = nil
        var bestMtime: Double = -1

        for brainDir in orderedBrainDirs(preferredSurface: preferredSurface) {
            let txPath = AGYLocator.transcriptPath(brainDir: brainDir, conversationId: conversationId)
            if let stat = Self.statFile(at: txPath) {
                if stat.mtimeSec > bestMtime {
                    bestMtime = stat.mtimeSec
                    bestDir = brainDir
                }
                continue
            }
            if bestDir == nil {
                let convDir = (brainDir as NSString).appendingPathComponent(conversationId)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: convDir, isDirectory: &isDir), isDir.boolValue {
                    bestDir = brainDir
                }
            }
        }
        return bestDir
    }

    private func locateTranscriptPath(for conversationId: String, preferredSurface: String?) -> String? {
        guard AGYLocator.isSafeConversationId(conversationId) else { return nil }
        let candidates = AGYLocator.candidateTranscriptPaths(
            home: homeDir,
            conversationId: conversationId,
            preferredSurface: preferredSurface,
            envDataDir: envDataDir
        )
        var bestPath: String? = nil
        var bestMtime: Double = -1
        for path in candidates {
            if let stat = Self.statFile(at: path), stat.size > 0, stat.mtimeSec > bestMtime {
                bestMtime = stat.mtimeSec
                bestPath = path
            }
        }
        return bestPath
    }

    private static func swarmBoardPath(brainDir: String, conversationId: String) -> String {
        let membersPath = AGYLocator.swarmMembersPath(brainDir: brainDir, conversationId: conversationId)
        let swarmDir = (membersPath as NSString).deletingLastPathComponent
        return (swarmDir as NSString).appendingPathComponent("board.jsonl")
    }

    // MARK: - 7. Title & Workspace Resolution

    private func resolveMissionTitle(
        conversationId: String,
        dbTitle: String,
        dbPreview: String,
        swarmTitle: String?,
        transcriptPrompt: String?
    ) -> String {
        let annTitle = readAnnotationTitle(conversationId: conversationId)
        let cleanedDB = TranscriptParse.cleaned(dbTitle)
        let cleanedSwarm = TranscriptParse.cleaned(swarmTitle)
        let cleanedPreview = TranscriptParse.cleaned(dbPreview)
        let cleanedPrompt = TranscriptParse.cleaned(transcriptPrompt)

        if let a = annTitle, !a.isEmpty {
            return a
        }
        if let st = cleanedSwarm, !st.isEmpty,
           (cleanedDB == nil || cleanedDB == "Casual Greeting") {
            return st
        }
        if let mt = cleanedDB, !mt.isEmpty {
            return mt
        }
        if let st = cleanedSwarm, !st.isEmpty {
            return st
        }
        if let tp = cleanedPrompt, !tp.isEmpty {
            return tp
        }
        if let pv = cleanedPreview, !pv.isEmpty {
            return pv
        }
        return "Session \(conversationId.prefix(8))"
    }

    private func readAnnotationTitle(conversationId: String) -> String? {
        guard AGYLocator.isSafeConversationId(conversationId) else { return nil }
        let fm = FileManager.default
        for path in AGYLocator.candidateAnnotationPaths(
            home: homeDir,
            conversationId: conversationId,
            envDataDir: envDataDir
        ) {
            guard fm.fileExists(atPath: path),
                  let raw = try? String(contentsOfFile: path, encoding: .utf8),
                  let parsed = TranscriptParse.parseAnnotationTitle(raw),
                  !parsed.isEmpty else {
                continue
            }
            return parsed
        }
        return nil
    }

    private func resolveWorkspaceLabel(
        primaryPath: String,
        brainDir: String?,
        conversationId: String
    ) -> String {
        if !primaryPath.isEmpty {
            return SessionLogic.basename(primaryPath)
        }
        if let bDir = brainDir {
            for manifest in readSubagentManifests(brainDir: bDir, conversationId: conversationId) {
                if !manifest.workspacePath.isEmpty {
                    return SessionLogic.basename(manifest.workspacePath)
                }
            }
        }
        return ""
    }

    // MARK: - 8. Bounded File Reading & Fast Peeking

    /// Reads up to `maxBytes` from the tail of a JSONL file cleanly aligned on a newline boundary
    /// so huge transcripts (>8 MB) never spike memory or break JSON decoding on a split line.
    private static func readBoundedTailText(at path: String, maxBytes: UInt64) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd(), fileSize > 0 else { return nil }

        let truncated: Bool
        let offset: UInt64
        let length: Int
        if fileSize > maxBytes {
            truncated = true
            offset = fileSize - maxBytes
            length = Int(maxBytes)
        } else {
            truncated = false
            offset = 0
            length = Int(fileSize)
        }

        do {
            try handle.seek(toOffset: offset)
        } catch {
            return nil
        }

        let data = (try? handle.read(upToCount: length)) ?? Data()
        guard !data.isEmpty else { return nil }

        if truncated, let firstNL = data.firstIndex(of: 0x0A) {
            let nextIdx = data.index(after: firstNL)
            guard nextIdx < data.endIndex else { return nil }
            return String(decoding: data[nextIdx...], as: UTF8.self)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads at most 8 KB from the head and 8 KB from the tail of `transcript.jsonl` to extract
    /// `startedAt`, `lastActiveAt`, and fallback user prompt in <0.2ms per file.
    private static func peekTranscriptHeadAndTail(at path: String) -> TranscriptPeek {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return TranscriptPeek(firstTimestampSec: nil, lastTimestampSec: nil, firstUserPrompt: nil)
        }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd(), fileSize > 0 else {
            return TranscriptPeek(firstTimestampSec: nil, lastTimestampSec: nil, firstUserPrompt: nil)
        }

        var firstTs: Double? = nil
        var firstPrompt: String? = nil

        // Head read
        if (try? handle.seek(toOffset: 0)) != nil {
            let headLen = Int(min(UInt64(peekHeadBytes), fileSize))
            let headData = (try? handle.read(upToCount: headLen)) ?? Data()
            let headText = String(decoding: headData, as: UTF8.self)
            for rawLine in headText.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let lineData = rawLine.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    continue
                }
                if firstTs == nil,
                   let ts = parseTimestampSec((obj["created_at"] as? String) ?? (obj["timestamp"] as? String)) {
                    firstTs = ts
                }
                if firstPrompt == nil,
                   (obj["type"] as? String)?.uppercased() == "USER_INPUT",
                   let content = obj["content"] as? String,
                   let cleaned = TranscriptParse.cleaned(content), !cleaned.isEmpty {
                    firstPrompt = cleaned
                }
                if firstTs != nil && firstPrompt != nil { break }
            }
        }

        // Tail read
        var lastTs: Double? = nil
        let tailLen = Int(min(UInt64(peekTailBytes), fileSize))
        let tailOffset = fileSize - UInt64(tailLen)
        if (try? handle.seek(toOffset: tailOffset)) != nil {
            let tailData = (try? handle.read(upToCount: tailLen)) ?? Data()
            let tailText = String(decoding: tailData, as: UTF8.self)
            for rawLine in tailText.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
                guard let lineData = rawLine.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    continue
                }
                if let ts = parseTimestampSec((obj["created_at"] as? String) ?? (obj["timestamp"] as? String)) {
                    lastTs = ts
                    break
                }
            }
        }

        return TranscriptPeek(
            firstTimestampSec: firstTs,
            lastTimestampSec: lastTs ?? firstTs,
            firstUserPrompt: firstPrompt
        )
    }

    private struct ToolHints {
        let hasRunWorkflow: Bool
        let hasSubagentTool: Bool
    }

    /// Lightweight bounded check (head 128 KB + tail 128 KB) for `run_workflow` / `invoke_subagent`
    /// used only when classifying non-swarm, non-battle missions during fast index listing.
    private static func peekTopologyToolHints(at path: String) -> ToolHints {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return ToolHints(hasRunWorkflow: false, hasSubagentTool: false)
        }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize > 0 else {
            return ToolHints(hasRunWorkflow: false, hasSubagentTool: false)
        }

        let wfToken = Data("\"run_workflow\"".utf8)
        let wfPrefixedToken = Data("default_api:run_workflow".utf8)
        let subInvokeToken = Data("\"invoke_subagent\"".utf8)
        let subDefineToken = Data("\"define_subagent\"".utf8)

        var foundWorkflow = false
        var foundSubagent = false

        func scan(_ data: Data) {
            if !foundWorkflow,
               data.range(of: wfToken) != nil || data.range(of: wfPrefixedToken) != nil {
                foundWorkflow = true
            }
            if !foundSubagent,
               data.range(of: subInvokeToken) != nil || data.range(of: subDefineToken) != nil {
                foundSubagent = true
            }
        }

        let headLen = Int(min(UInt64(workflowPeekBytes), fileSize))
        if (try? handle.seek(toOffset: 0)) != nil {
            scan((try? handle.read(upToCount: headLen)) ?? Data())
        }
        if !foundWorkflow && fileSize > UInt64(headLen) {
            let tailLen = Int(min(UInt64(workflowPeekBytes), fileSize - UInt64(headLen)))
            let tailOffset = fileSize - UInt64(tailLen)
            if (try? handle.seek(toOffset: tailOffset)) != nil {
                scan((try? handle.read(upToCount: tailLen)) ?? Data())
            }
        }

        return ToolHints(hasRunWorkflow: foundWorkflow, hasSubagentTool: foundSubagent)
    }

    // MARK: - 9. Stat, Timestamp & Cache Key Helpers

    private static func statFile(at path: String) -> FileStatStamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return FileStatStamp(mtimeSec: mtime, size: size)
    }

    private static func creationDateSec(at path: String) -> Double? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let created = attrs[.creationDate] as? Date else {
            return nil
        }
        return created.timeIntervalSince1970
    }

    private static func parseTimestampSec(_ raw: String?) -> Double? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let date = AppDate.parseISO8601(raw) {
            let sec = date.timeIntervalSince1970
            return sec > minValidEpochSec ? sec : nil
        }
        if let num = Double(raw), num.isFinite, num > minValidEpochSec {
            return num > 10_000_000_000 ? num / 1000.0 : num
        }
        return nil
    }

    private static func buildCacheKey(
        missionId: String,
        rootStat: FileStatStamp?,
        membersStat: FileStatStamp?,
        boardStat: FileStatStamp?,
        childStats: [(String, FileStatStamp)]
    ) -> String {
        var parts: [String] = [missionId]
        parts.reserveCapacity(4 + childStats.count)
        func safeMs(_ sec: Double) -> Int64 {
            let ms = sec * 1000.0
            guard ms.isFinite else { return 0 }
            let clamped = min(max(ms, -Double(Int64.max / 2)), Double(Int64.max / 2))
            return Int64(clamped)
        }
        if let r = rootStat {
            parts.append("r:\(safeMs(r.mtimeSec)):\(r.size)")
        }
        if let m = membersStat {
            parts.append("m:\(safeMs(m.mtimeSec)):\(m.size)")
        }
        if let b = boardStat {
            parts.append("b:\(safeMs(b.mtimeSec)):\(b.size)")
        }
        for (cid, st) in childStats {
            parts.append("\(cid):\(safeMs(st.mtimeSec)):\(st.size)")
        }
        return parts.joined(separator: "|")
    }
}
