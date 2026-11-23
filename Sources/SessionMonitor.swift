import Foundation
import CoreServices
import Darwin
import SQLite3

// MARK: - Live Antigravity Session Monitor (app layer)
//
// Detects live Google Antigravity conversations across CLI (`agy`), Desktop
// (`Antigravity.app`), and IDE (`Antigravity IDE.app`) by combining:
//   1. Live `agy` CLI processes holding `~/.gemini/antigravity-cli/presence/<id>.lock`
//      (resolved natively via Darwin `libproc` syscalls for PID, TTY, cwd, and open
//      lock FDs with automatic `/bin/ps` + `/usr/sbin/lsof` fallback)
//      plus active Desktop/IDE app sessions (`not_fully_idle == 1` or recent activity).
//   2. Metadata from `conversation_summaries.db` (read-only SQLite with
//      `file:...?mode=ro&immutable=1` fallback when `-wal` is absent) and
//      `cache/conversation_metadata.json`, `annotations/<id>.pbtxt`, and
//      bounded tails of `brain/<id>/.system_generated/logs/transcript.jsonl`.
//   3. Swarm hierarchy awareness (`brain/<id>/.system_generated/swarm/members.json`):
//      filters out `killed` and `is_internal` helper workers while rolling
//      active worker busy state into the parent coordinator conversation.
//
// NOT part of AGYCore — never add this file to Package.swift.

/// Runtime targeting facts for ONE live session (terminal TTY or Desktop/IDE app).
struct SessionTarget: Equatable {
    let tty: String?
    let terminal: TerminalKind
    let appName: String?
    let bundleId: String?
    let appPid: Int?
    let multiplexed: Bool
    let cwd: String
    let surface: String?

    init(
        tty: String?,
        terminal: TerminalKind,
        appName: String?,
        bundleId: String?,
        appPid: Int?,
        multiplexed: Bool,
        cwd: String,
        surface: String? = nil
    ) {
        self.tty = tty
        self.terminal = terminal
        self.appName = appName
        self.bundleId = bundleId
        self.appPid = appPid
        self.multiplexed = multiplexed
        self.cwd = cwd
        self.surface = surface
    }
}

/// Complete Equatable scan snapshot published to SessionStore on changes only.
struct SessionScan: Equatable {
    var sessions: [SessionInfo]
    var labels: [String: String]
    var anyDoneUnseen: Bool = false
    var doneUnseenIds: Set<String> = []
    var targets: [String: SessionTarget] = [:]
    var titles: [String: String] = [:]
    var instructions: [String: String] = [:]
    var contextSnapshots: [String: SessionContextSnapshot] = [:]
    var liveTPS: LiveTPSSnapshot = .idle

    static let empty = SessionScan(sessions: [], labels: [:])
}

private final class WeakSessionMonitorBox {
    weak var monitor: SessionMonitor?
    init(_ monitor: SessionMonitor) {
        self.monitor = monitor
    }
}

final class SessionMonitor {
    private let onChange: (SessionScan) -> Void
    private let homeDir: String
    private let geminiDir: String
    private let cliRootDir: String
    private let presenceDir: String
    private let usesCustomProjectsDir: Bool

    private let queue = DispatchQueue(label: "com.kuen54.AGYMonitor.sessions", qos: .utility)

    private var fsStream: FSEventStreamRef?
    private var fsCoalesceWork: DispatchWorkItem?
    private var pollTimer: DispatchSourceTimer?
    private var lifecycle = SessionMonitorLifecycleState()
    private let runGenLock = NSLock()
    private var activeRunGeneration: Int = 0
    private var isMonitorRunning: Bool = false
    private var pendingStopCount: Int = 0

    // Queue-confined caches
    private var lastScan: SessionScan?
    private var labelCache: [String: String] = [:]

    private struct TranscriptCacheEntry {
        let path: String
        let size: Int
        let mtime: TimeInterval
        let title: String?
        let instruction: String?
        let tailSummary: TranscriptSummary
    }
    private var transcriptCache: [String: TranscriptCacheEntry] = [:]

    private struct AnnotationCacheEntry {
        let path: String
        let mtime: TimeInterval
        let title: String?
    }
    private var annotationCache: [String: AnnotationCacheEntry] = [:]

    private struct SwarmCacheEntry {
        let size: Int
        let mtime: TimeInterval
        let info: AITitleReader.SwarmCoordinatorInfo?
        let activeWorkerIds: Set<String>
        let liveWorkerIds: Set<String>
        let killedWorkerIds: Set<String>
    }
    private var swarmCache: [String: SwarmCacheEntry] = [:]

    private struct SubagentFileCacheEntry {
        let size: Int
        let mtime: TimeInterval
        let record: SubagentRecord?
    }

    private struct SubagentDirCacheEntry {
        let dirPath: String
        let dirMtime: TimeInterval
        let dirSize: Int64
        var files: [String: SubagentFileCacheEntry]
        var records: [SubagentRecord]
        var recheckFilenames: [String]
    }
    private var subagentDirCache: [String: SubagentDirCacheEntry] = [:]

    private struct SQLiteSurfaceCacheEntry {
        let stamp: String
        let rows: [String: ConvMeta]
    }
    private var cachedSQLiteByPath: [String: SQLiteSurfaceCacheEntry] = [:]

    private typealias ConvMeta = SessionLogic.SurfaceConversationSummary

    private var cachedDBStamp: String = ""
    private var cachedDBRows: [String: ConvMeta] = [:]

    private var cachedJSONStamp: String = ""
    private var cachedJSONRows: [String: ConvMeta] = [:]

    private var targetCache: [String: (pid: Int, target: SessionTarget)] = [:]
    private var terminalInfoCache: [String: (bundleId: String?, name: String?)] = [:]
    private var ttyDevCache: [dev_t: String] = [:]

    // Done-unseen state (busy/waiting -> idle transition tracker)
    private var doneUnseenState = DoneUnseenState()
    // Queue-confined live Output TPS tracker (pure AGYCore state machine)
    private var tpsTracker = LiveTPSTracker()

    init(sessionsDir: String? = nil, projectsDir: URL? = nil,
         onChange: @escaping (SessionScan) -> Void) {
        self.onChange = onChange
        let home = NSHomeDirectory()
        self.homeDir = home
        self.usesCustomProjectsDir = (projectsDir != nil)
        self.geminiDir = projectsDir?.path ?? AGYLocator.geminiRoot(home: home)
        self.cliRootDir = projectsDir != nil
            ? (self.geminiDir as NSString).appendingPathComponent(AGYSurface.cli.rawValue)
            : AGYLocator.surfaceRoot(home: home, surface: .cli)
        self.presenceDir = sessionsDir
            ?? (projectsDir != nil
                ? (self.cliRootDir as NSString).appendingPathComponent("presence")
                : AGYLocator.presenceDir(home: home))
    }

    deinit {
        fsCoalesceWork?.cancel()
        pollTimer?.cancel()
        if let stream = fsStream {
            fsStream = nil
            let cleanupQueue = queue
            cleanupQueue.async {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
        }
    }

    private func syncPublishedLifecycleFlag(completingStop: Bool = false) {
        runGenLock.lock()
        if completingStop {
            pendingStopCount = max(0, pendingStopCount - 1)
        }
        if lifecycle.runGeneration < activeRunGeneration {
            lifecycle.runGeneration = activeRunGeneration
        } else {
            activeRunGeneration = lifecycle.runGeneration
        }
        isMonitorRunning = (pendingStopCount == 0) && lifecycle.isStarted
        runGenLock.unlock()
    }

    private func canPublishOnMain(generation: Int) -> Bool {
        runGenLock.lock()
        defer { runGenLock.unlock() }
        return isMonitorRunning && activeRunGeneration == generation
    }

    // MARK: - Lifecycle (backed by SessionMonitorLifecycleMachine)

    func start() {
        queue.async { [weak self] in
            self?.dispatchLifecycle(.start(now: Date()))
        }
    }

    func stop() {
        // Bump runGeneration synchronously under runGenLock BEFORE dispatching queue.async
        // so any in-flight scan drops its publish immediately without waiting for `queue`.
        runGenLock.lock()
        activeRunGeneration += 1
        isMonitorRunning = false
        pendingStopCount += 1
        runGenLock.unlock()
        // Strongly capture `self` so `stopFSWatcher()` always completes on `queue` before `deinit`.
        queue.async {
            self.dispatchLifecycle(.stop, completingStop: true)
        }
    }

    func setActive(_ active: Bool) {
        queue.async { [weak self] in
            self?.dispatchLifecycle(.setActive(active, now: Date()))
        }
    }

    func markSeen(sessionId: String) {
        queue.async { [weak self] in
            guard let self = self,
                  self.lifecycle.isStarted,
                  self.doneUnseenState.markSeen(sessionId) else { return }
            guard var scan = self.lastScan else { return }
            scan.doneUnseenIds = self.doneUnseenState.ids
            scan.anyDoneUnseen = self.doneUnseenState.anyUnseen
            self.lastScan = scan
            let gen = self.lifecycle.runGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.canPublishOnMain(generation: gen) else { return }
                self.onChange(scan)
            }
        }
    }

    private func dispatchLifecycle(
        _ event: SessionMonitorLifecycleEvent,
        completingStop: Bool = false
    ) {
        let wasStarted = lifecycle.isStarted
        let effects = SessionMonitorLifecycleMachine.reduce(&lifecycle, event: event)
        if wasStarted && !lifecycle.isStarted {
            doneUnseenState.reset()
            tpsTracker = LiveTPSTracker()
            lastScan = nil
        }
        syncPublishedLifecycleFlag(completingStop: completingStop)
        for effect in effects {
            switch effect {
            case .startFSWatcher:
                startFSWatcher()
            case .restartFSEvents(let dirs):
                startFSWatcher(dirs: dirs)
            case .stopFSWatcher:
                stopFSWatcher()
            case .scheduleFSCoalesce:
                scheduleFSCoalesce()
            case .cancelFSCoalesce:
                fsCoalesceWork?.cancel()
                fsCoalesceWork = nil
            case .setPollTimer(let interval):
                if let interval = interval {
                    startPollTimer(interval: interval)
                } else {
                    cancelPoll()
                }
            case .runScan:
                performScan()
            }
        }
    }

    // MARK: - FSEvents (sub-second reactivity)

    private func stopFSWatcher() {
        if let s = fsStream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            fsStream = nil
        }
    }

    private func existingWatchCandidateDirs() -> [String] {
        let fm = FileManager.default
        var candidateDirs = usesCustomProjectsDir
            ? [
                cliRootDir,
                (geminiDir as NSString).appendingPathComponent("antigravity/brain"),
                (geminiDir as NSString).appendingPathComponent("antigravity-ide/brain"),
            ]
            : [cliRootDir] + AGYLocator.brainDirs(home: homeDir)
        if !candidateDirs.contains(cliRootDir) {
            candidateDirs.insert(cliRootDir, at: 0)
        }
        return Array(Set(candidateDirs)).sorted().filter { path in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    private func startFSWatcher(dirs explicitDirs: [String]? = nil) {
        let attemptAt = Date()
        stopFSWatcher()
        let existingDirs = explicitDirs ?? existingWatchCandidateDirs()
        guard !existingDirs.isEmpty else {
            dispatchLifecycle(.fsWatcherAttempted(healthy: false, watchedDirs: [], at: attemptAt))
            return
        }

        let box = WeakSessionMonitorBox(self)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { ptr in
                guard let ptr = ptr else { return nil }
                _ = Unmanaged<WeakSessionMonitorBox>.fromOpaque(ptr).retain()
                return ptr
            },
            release: { ptr in
                guard let ptr = ptr else { return }
                Unmanaged<WeakSessionMonitorBox>.fromOpaque(ptr).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            let box = Unmanaged<WeakSessionMonitorBox>.fromOpaque(info).takeUnretainedValue()
            box.monitor?.dispatchLifecycle(.fsEventReceived)
        }
        let createdStream: FSEventStreamRef? = withExtendedLifetime(box) {
            FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &context,
                existingDirs as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.3,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)
            )
        }
        guard let stream = createdStream else {
            dispatchLifecycle(.fsWatcherAttempted(healthy: false, watchedDirs: existingDirs, at: attemptAt))
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        if FSEventStreamStart(stream) {
            fsStream = stream
            // Any existing Antigravity surface root (CLI, Desktop, or IDE) gives a healthy
            // watcher — Desktop/IDE-only setups no longer thrash teardown/recreate every 30s.
            dispatchLifecycle(.fsWatcherAttempted(healthy: true, watchedDirs: existingDirs, at: attemptAt))
        } else {
            NSLog("AGYMonitor: session FSEventStreamStart failed; poll-only")
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            fsStream = nil
            dispatchLifecycle(.fsWatcherAttempted(healthy: false, watchedDirs: existingDirs, at: attemptAt))
        }
    }

    private func scheduleFSCoalesce() {
        fsCoalesceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.dispatchLifecycle(.fsCoalesceFired(now: Date()))
        }
        fsCoalesceWork = work
        queue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: - Backstop Poll

    private func startPollTimer(interval: TimeInterval) {
        pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            self?.dispatchLifecycle(.pollTimerFired(now: Date()))
        }
        pollTimer = timer
        timer.resume()
    }

    private func cancelPoll() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    // MARK: - Main Scan Pipeline (queue only)

    private func performScan(now: Double = Date().timeIntervalSince1970) {
        guard lifecycle.isStarted else { return }
        let gen = lifecycle.runGeneration
        guard canPublishOnMain(generation: gen) else { return }
        var scan = computeScan(now: now)
        doneUnseenState.step(sessions: scan.sessions, now: now)
        scan.doneUnseenIds = doneUnseenState.ids
        scan.anyDoneUnseen = doneUnseenState.anyUnseen

        if scan != lastScan {
            lastScan = scan
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.canPublishOnMain(generation: gen) else { return }
                self.onChange(scan)
            }
        }
        dispatchLifecycle(.scanCompleted(liveCount: scan.sessions.count))
        dispatchLifecycle(.reconcileWatchedDirs(existingWatchCandidateDirs()))
    }

    private struct RunningSurfaceApps {
        var agyPids: [Int] = []
        var desktopApp: (pid: Int, bundlePath: String)? = nil
        var ideApp: (pid: Int, bundlePath: String)? = nil
    }

    private struct CLILockFact {
        let pid: Int
        let cwd: String
        let lockIds: [String]
    }

    private func computeScan(now: Double) -> SessionScan {
        let nowMs = now * 1000.0

        // 1. Native Darwin `libproc` process snapshot for discovery AND terminal ppid-walk
        //    (falls back to `/bin/ps` only if native discovery returns empty).
        let nativeProcTable = snapshotProcTableNative()
        let procTable: [Int: SessionLogic.ProcRow]
        if !nativeProcTable.isEmpty {
            procTable = nativeProcTable
        } else {
            let psOut = runProcess("/bin/ps", ["-Ao", "pid=,ppid=,tty=,comm="]) ?? ""
            procTable = SessionLogic.parseProcTable(psOut)
        }
        let running = discoverRunningProcesses(procTable: procTable)

        // 2. Native Darwin `libproc` inspection over live `agy` CLI processes for cwd + open presence/*.lock
        let cliFacts = inspectCLIProcesses(pids: running.agyPids)
        var cliLockOwners: [String: (pid: Int, cwd: String)] = [:]
        var locklessInteractiveCLIs: [(pid: Int, cwd: String)] = []

        for pid in running.agyPids.sorted() {
            guard let fact = cliFacts[pid] else { continue }
            if !fact.lockIds.isEmpty {
                for convId in fact.lockIds {
                    cliLockOwners[convId] = (pid: pid, cwd: fact.cwd)
                }
            } else if let row = procTable[pid], SessionLogic.devTTY(row.tty) != nil, !fact.cwd.isEmpty {
                // Brand-new interactive TUI process that hasn't opened presence/<id>.lock yet
                locklessInteractiveCLIs.append((pid: pid, cwd: fact.cwd))
            }
        }

        // 3. Load conversation metadata (SQLite + JSON cache merged)
        let metaById = loadMergedConversationMetadata()

        // 4. Inspect swarm & subagent hierarchies (multi-depth D0 -> D1 -> D2+) so internal
        //    worker/subagent conversations are hidden as top-level rows while their active
        //    work and live output token samples roll up transitively to their root ancestor.
        var allSwarmWorkerIds = Set<String>()
        var swarmBusyCoordinators = Set<String>()
        var busyWorkersByCoordinator: [String: Set<String>] = [:]
        var swarmTitles: [String: String] = [:]
        var parentById: [String: String] = [:]
        var swarmActiveWorkerIds = Set<String>()
        var liveSwarmWorkerIds = Set<String>()
        var swarmKilledWorkerIds = Set<String>()
        var aliveSubagentIds = Set<String>()

        // 4a. Parent edges from conversation metadata (SQLite + JSON cache)
        for (_, meta) in metaById where !meta.parentConversationId.isEmpty && meta.parentConversationId != meta.id {
            parentById[meta.id] = meta.parentConversationId
            if !meta.killed {
                allSwarmWorkerIds.insert(meta.id)
            }
        }

        // 4b. Identify live/recent root sessions ONCE so neither swarm roster scanning nor
        //     subagent BFS walks hundreds of historical closed conversations on every 2s poll.
        var liveOrRecentRootIds = Set<String>()
        for convId in cliLockOwners.keys where metaById[convId]?.killed != true {
            liveOrRecentRootIds.insert(convId)
        }
        for (convId, meta) in metaById where !meta.killed && !meta.isInternal {
            let isRunningNow = meta.notFullyIdle || meta.rawStatus == "CASCADE_RUN_STATUS_RUNNING"
            let ageMs = nowMs - (meta.updatedAtMs ?? 0)
            let surface = meta.appDataDir
            if surface == "antigravity" {
                let desktopOpen = running.desktopApp != nil
                let recentlyActiveInOpenApp = desktopOpen && meta.stepCount > 0 && ageMs >= 0 && ageMs < 2 * 3600 * 1000
                let activelyRunning = isRunningNow && ageMs < 15 * 60 * 1000
                if activelyRunning || recentlyActiveInOpenApp {
                    liveOrRecentRootIds.insert(convId)
                }
            } else if surface == "antigravity-ide" {
                let ideOpen = running.ideApp != nil
                let recentlyActiveInOpenApp = ideOpen && meta.stepCount > 0 && ageMs >= 0 && ageMs < 2 * 3600 * 1000
                let activelyRunning = isRunningNow && ageMs < 15 * 60 * 1000
                if activelyRunning || recentlyActiveInOpenApp {
                    liveOrRecentRootIds.insert(convId)
                }
            } else if isRunningNow, let updatedAtMs = meta.updatedAtMs, (nowMs - updatedAtMs) < 15 * 60 * 1000 {
                liveOrRecentRootIds.insert(convId)
            }
        }

        // Swarm roster (`swarm/members.json`) for live/recent root sessions only
        let potentialCoordinators = liveOrRecentRootIds
        for coordId in potentialCoordinators {
            if let swarm = cachedSwarmInfo(sessionId: coordId) {
                allSwarmWorkerIds.formUnion(swarm.info.workerConversationIds)
                for workerId in swarm.info.workerConversationIds where workerId != coordId {
                    if parentById[workerId] == nil {
                        parentById[workerId] = coordId
                    }
                }
                swarmActiveWorkerIds.formUnion(swarm.activeWorkerIds)
                liveSwarmWorkerIds.formUnion(swarm.liveWorkerIds)
                swarmKilledWorkerIds.formUnion(swarm.killedWorkerIds)
                if let t = swarm.info.title, !t.isEmpty {
                    swarmTitles[coordId] = t
                }
            }
        }

        func isConversationKilled(_ id: String) -> Bool {
            metaById[id]?.killed == true || swarmKilledWorkerIds.contains(id)
        }

        // 4c. Bounded stat-cached BFS discovery over `.system_generated/subagents/*.json`
        //     Seeded from live/recent roots (+ non-killed swarm roster workers / fresh running meta children)
        //     up to depth 4, cycle-guarded — never walk ancient dead/killed workers on 2s polls.
        var scannedSubagentParents = Set<String>()
        var bfsQueue: [(id: String, depth: Int)] = []
        var enqueuedParents = Set<String>()
        func enqueueSubagentParent(_ id: String, depth: Int) {
            guard !id.isEmpty, depth <= 4, enqueuedParents.insert(id).inserted else { return }
            bfsQueue.append((id: id, depth: depth))
        }

        for convId in liveOrRecentRootIds {
            enqueueSubagentParent(convId, depth: 0)
        }
        // Enqueue non-killed swarm roster workers of live coordinators (even if parked/waiting)
        // so helper subagents spawned by a worker remain discovered without polling dead/historical rows.
        for workerId in liveSwarmWorkerIds where !isConversationKilled(workerId) {
            enqueueSubagentParent(workerId, depth: 1)
        }
        for (_, meta) in metaById where !meta.parentConversationId.isEmpty && !isConversationKilled(meta.id) {
            guard meta.notFullyIdle || meta.rawStatus == "CASCADE_RUN_STATUS_RUNNING" else { continue }
            let rootId = SessionLogic.resolveRootAncestor(for: meta.id, parentById: parentById)
            let metaFresh = SessionLogic.shouldProbeRunningSubagentMeta(updatedAtMs: meta.updatedAtMs, nowMs: nowMs)
            if liveOrRecentRootIds.contains(rootId) || metaFresh {
                enqueueSubagentParent(meta.id, depth: 1)
            }
        }

        var bfsIndex = 0
        while bfsIndex < bfsQueue.count {
            let (parentId, depth) = bfsQueue[bfsIndex]
            bfsIndex += 1
            scannedSubagentParents.insert(parentId)

            let records = cachedSubagentRecords(parentId: parentId)
            for rec in records {
                guard !rec.conversationId.isEmpty, rec.conversationId != parentId else { continue }
                if parentById[rec.conversationId] == nil {
                    parentById[rec.conversationId] = parentId
                }
                allSwarmWorkerIds.insert(rec.conversationId)
                if rec.isAlive && !isConversationKilled(rec.conversationId) {
                    aliveSubagentIds.insert(rec.conversationId)
                    if depth < 4 {
                        enqueueSubagentParent(rec.conversationId, depth: depth + 1)
                    }
                } else if depth < 4,
                          let childMeta = metaById[rec.conversationId],
                          !isConversationKilled(rec.conversationId),
                          (childMeta.notFullyIdle || childMeta.rawStatus == "CASCADE_RUN_STATUS_RUNNING") {
                    enqueueSubagentParent(rec.conversationId, depth: depth + 1)
                }
            }
        }

        // 4d. Unified transitive roll-up across all active children (D1, D2, D3+ -> D0 root)
        var candidateActiveChildren = Set<String>()
        for childId in parentById.keys {
            if isConversationKilled(childId) { continue }
            let meta = metaById[childId]
            let metaRunning = (meta?.notFullyIdle == true) || (meta?.rawStatus == "CASCADE_RUN_STATUS_RUNNING")
            if swarmActiveWorkerIds.contains(childId) || aliveSubagentIds.contains(childId) {
                candidateActiveChildren.insert(childId)
            } else if metaRunning {
                let rootId = SessionLogic.resolveRootAncestor(for: childId, parentById: parentById)
                let metaFresh = SessionLogic.shouldProbeRunningSubagentMeta(updatedAtMs: meta?.updatedAtMs, nowMs: nowMs)
                if liveOrRecentRootIds.contains(rootId) || metaFresh {
                    candidateActiveChildren.insert(childId)
                }
            }
        }
        // Also include fresh or sentinel-timestamp detached running internal agents (e.g. nestingDepth > 0 with no parent link)
        for (convId, meta) in metaById where meta.isInternal && !isConversationKilled(convId) && parentById[convId] == nil {
            if meta.notFullyIdle || meta.rawStatus == "CASCADE_RUN_STATUS_RUNNING" {
                if SessionLogic.shouldProbeRunningSubagentMeta(updatedAtMs: meta.updatedAtMs, nowMs: nowMs) {
                    candidateActiveChildren.insert(convId)
                }
            }
        }

        var allActiveSubagentIds = Set<String>()
        var childTranscriptEntries: [String: TranscriptCacheEntry] = [:]
        for childId in candidateActiveChildren {
            let meta = metaById[childId]
            let killed = isConversationKilled(childId)
            let isSwarmActive = !killed && swarmActiveWorkerIds.contains(childId)
            let isAliveDesc = !killed && aliveSubagentIds.contains(childId)
            let rootId = parentById[childId] != nil
                ? SessionLogic.resolveRootAncestor(for: childId, parentById: parentById)
                : nil
            let hasLiveRoot = rootId.map { liveOrRecentRootIds.contains($0) } ?? false
            let childTx = readCachedTranscript(sessionId: childId)
            if let childTx = childTx {
                childTranscriptEntries[childId] = childTx
            }

            let isActive = isSwarmActive || SessionLogic.isSubagentActivelyGenerating(
                rawStatus: meta?.rawStatus,
                notFullyIdle: meta?.notFullyIdle ?? false,
                killed: killed,
                isAliveDescriptor: isAliveDesc,
                transcriptSummary: childTx?.tailSummary,
                transcriptFileMtime: childTx?.mtime,
                now: now,
                hasLiveRoot: hasLiveRoot,
                metaUpdatedAt: meta?.updatedAtMs.map { $0 / 1000.0 }
            )

            if isActive {
                if let rootId = rootId {
                    swarmBusyCoordinators.insert(rootId)
                    busyWorkersByCoordinator[rootId, default: []].insert(childId)
                }
                allActiveSubagentIds.insert(childId)
            }
        }

        // 5. Build candidate live user conversations (CLI + Desktop + IDE)
        struct Candidate {
            let sessionId: String
            let pid: Int
            let cwd: String
            let surface: String
            let meta: ConvMeta?
        }
        var candidates: [Candidate] = []
        var seenIds = Set<String>()

        // 5a. Live `agy` CLI sessions holding `presence/<id>.lock`
        for (convId, owner) in cliLockOwners {
            let meta = metaById[convId]
            if meta?.killed == true { continue }
            if meta?.isInternal == true || allSwarmWorkerIds.contains(convId) { continue }
            let resolvedCwd = !owner.cwd.isEmpty ? owner.cwd : (meta?.cwd ?? homeDir)
            candidates.append(Candidate(
                sessionId: convId,
                pid: owner.pid,
                cwd: resolvedCwd,
                surface: "antigravity-cli",
                meta: meta
            ))
            seenIds.insert(convId)
        }

        // 5b. Active Antigravity Desktop & Antigravity IDE conversations
        for (convId, meta) in metaById {
            guard !seenIds.contains(convId),
                  !meta.killed,
                  !meta.isInternal,
                  !allSwarmWorkerIds.contains(convId) else { continue }

            let surface = meta.appDataDir
            let isRunningNow = meta.notFullyIdle || meta.rawStatus == "CASCADE_RUN_STATUS_RUNNING"
            let ageMs = nowMs - (meta.updatedAtMs ?? 0)

            if surface == "antigravity" {
                let desktopOpen = running.desktopApp != nil
                let recentlyActiveInOpenApp = desktopOpen && meta.stepCount > 0 && ageMs >= 0 && ageMs < 2 * 3600 * 1000
                let activelyRunning = isRunningNow && ageMs < 15 * 60 * 1000
                if activelyRunning || recentlyActiveInOpenApp {
                    candidates.append(Candidate(
                        sessionId: convId,
                        pid: running.desktopApp?.pid ?? 0,
                        cwd: meta.cwd.isEmpty ? homeDir : meta.cwd,
                        surface: "antigravity",
                        meta: meta
                    ))
                    seenIds.insert(convId)
                }
            } else if surface == "antigravity-ide" {
                let ideOpen = running.ideApp != nil
                let recentlyActiveInOpenApp = ideOpen && meta.stepCount > 0 && ageMs >= 0 && ageMs < 2 * 3600 * 1000
                let activelyRunning = isRunningNow && ageMs < 15 * 60 * 1000
                if activelyRunning || recentlyActiveInOpenApp {
                    candidates.append(Candidate(
                        sessionId: convId,
                        pid: running.ideApp?.pid ?? 0,
                        cwd: meta.cwd.isEmpty ? homeDir : meta.cwd,
                        surface: "antigravity-ide",
                        meta: meta
                    ))
                    seenIds.insert(convId)
                }
            }
        }

        // 5c. Lockless brand-new interactive `agy` CLI processes (at prompt before first turn)
        for item in locklessInteractiveCLIs {
            let synthId = "proc-\(item.pid)"
            guard !seenIds.contains(synthId) else { continue }
            candidates.append(Candidate(
                sessionId: synthId,
                pid: item.pid,
                cwd: item.cwd,
                surface: "antigravity-cli",
                meta: nil
            ))
            seenIds.insert(synthId)
        }

        // 6. Resolve transcript summaries, live statuses, titles, instructions, telemetry, and targets
        var builtSessions: [SessionInfo] = []
        var titles: [String: String] = [:]
        var instructions: [String: String] = [:]
        var contextSnapshots: [String: SessionContextSnapshot] = [:]
        var busyForTPS = Set<String>()
        var samplesBySession: [String: [OutputTokenSample]] = [:]
        var activeBusyWorkerIds = Set<String>()
        var liveIds = Set<String>()

        for c in candidates {
            liveIds.insert(c.sessionId)
            let txEntry = c.sessionId.hasPrefix("proc-")
                ? nil
                : readCachedTranscript(sessionId: c.sessionId)

            // Canonical status resolution shared with AITitleReader
            let (status, waitingFor) = SessionLogic.resolveLiveSessionStatus(
                swarmWorkerBusy: swarmBusyCoordinators.contains(c.sessionId),
                rawStatus: c.meta?.rawStatus,
                notFullyIdle: c.meta?.notFullyIdle ?? false,
                transcriptSummary: txEntry?.tailSummary,
                transcriptFileMtime: txEntry?.mtime,
                now: now
            )

            // Live context window remaining % telemetry (from latest PLANNER_RESPONSE)
            if let tailSummary = txEntry?.tailSummary,
               let usedTokens = tailSummary.latestContextUsedTokens {
                contextSnapshots[c.sessionId] = SessionContextSnapshot.make(
                    model: tailSummary.latestModel ?? "",
                    usedTokens: usedTokens,
                    cacheHitRatio: tailSummary.latestCacheHitRatio
                )
            }

            // Live output TPS samples for busy parent sessions
            if status == .busy {
                busyForTPS.insert(c.sessionId)
                if let samples = txEntry?.tailSummary.recentOutputSamples, !samples.isEmpty {
                    samplesBySession[c.sessionId] = samples
                }
            }

            // Unconditionally include active subagents/workers under this root even when the
            // parent itself is `.waiting` (e.g. asking a user question while subagents run) or `.idle`.
            if let workerIds = busyWorkersByCoordinator[c.sessionId], !workerIds.isEmpty {
                for workerId in workerIds where !isConversationKilled(workerId) {
                    activeBusyWorkerIds.insert(workerId)
                    busyForTPS.insert(workerId)
                    let workerTx = childTranscriptEntries[workerId]
                        ?? readCachedTranscript(sessionId: workerId)
                    if let samples = workerTx?.tailSummary.recentOutputSamples, !samples.isEmpty {
                        samplesBySession[workerId] = samples
                    }
                }
            }

            // Title priority: annotation .pbtxt > summary Title (unless generic w/ swarm title) > swarm title > transcript title
            let annTitle = c.sessionId.hasPrefix("proc-") ? nil : cachedAnnotationTitle(sessionId: c.sessionId)
            let metaTitle = c.meta?.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let swarmTitle = swarmTitles[c.sessionId]

            let chosenTitle: String?
            if let a = annTitle, !a.isEmpty {
                chosenTitle = a
            } else if let st = swarmTitle, !st.isEmpty,
                      (metaTitle == nil || metaTitle!.isEmpty || metaTitle == "Casual Greeting") {
                chosenTitle = st
            } else if let mt = metaTitle, !mt.isEmpty {
                chosenTitle = mt
            } else if let st = swarmTitle, !st.isEmpty {
                chosenTitle = st
            } else {
                chosenTitle = txEntry?.title
            }
            if let t = chosenTitle, !t.isEmpty {
                titles[c.sessionId] = t
            }

            // Latest clean user prompt: transcript tail instruction > cleaned summary preview
            if let inst = txEntry?.instruction, !inst.isEmpty {
                instructions[c.sessionId] = inst
            } else if let preview = TranscriptParse.cleaned(c.meta?.preview), !preview.isEmpty {
                instructions[c.sessionId] = preview
            }

            // Timestamp (ms): reject 0001-01-01 sentinels
            let txMs = txEntry?.tailSummary.lastStepAt.flatMap { d -> Double? in
                let sec = d.timeIntervalSince1970
                return sec > 946_684_800 ? sec * 1000.0 : nil
            }
                ?? txEntry.map { $0.mtime > 946_684_800 ? $0.mtime * 1000.0 : 0 }
                ?? 0
            let bestUpdatedMs = max(c.meta?.updatedAtMs ?? 0, txMs)
            let validUpdatedMs: Double? = bestUpdatedMs > 946_684_800_000 ? bestUpdatedMs : nil

            builtSessions.append(SessionInfo(
                pid: c.pid,
                sessionId: c.sessionId,
                cwd: c.cwd,
                status: status,
                waitingFor: waitingFor,
                startedAt: validUpdatedMs,
                updatedAt: validUpdatedMs,
                statusUpdatedAt: validUpdatedMs,
                version: nil,
                kind: "interactive",
                entrypoint: c.surface == AGYSurface.cli.rawValue ? "cli" : c.surface,
                surface: c.surface
            ))
        }

        // Include any active subagents whose root was not in `candidates` (e.g. detached
        // workflow agents or orphaned subagent trees), gated strictly on fresh transcript
        // activity so crashed/abandoned SQLite rows never stick `liveTPS.isWorking == true`.
        for childId in allActiveSubagentIds where !activeBusyWorkerIds.contains(childId) {
            guard !isConversationKilled(childId) else { continue }
            let childTx = childTranscriptEntries[childId]
                ?? readCachedTranscript(sessionId: childId)
            guard SessionLogic.isOrphanSubagentFresh(
                transcriptSummary: childTx?.tailSummary,
                transcriptFileMtime: childTx?.mtime,
                now: now
            ) else { continue }
            activeBusyWorkerIds.insert(childId)
            busyForTPS.insert(childId)
            if let samples = childTx?.tailSummary.recentOutputSamples, !samples.isEmpty {
                samplesBySession[childId] = samples
            }
        }

        // Prune per-session caches (retain active/candidate subagent transcripts for stat-cache hits)
        let retainedTranscriptIds = liveIds
            .union(activeBusyWorkerIds)
            .union(candidateActiveChildren)
        if !transcriptCache.isEmpty {
            transcriptCache = transcriptCache.filter { retainedTranscriptIds.contains($0.key) }
        }
        if !annotationCache.isEmpty {
            annotationCache = annotationCache.filter { liveIds.contains($0.key) }
        }
        if !swarmCache.isEmpty {
            swarmCache = swarmCache.filter { potentialCoordinators.contains($0.key) }
        }
        if !subagentDirCache.isEmpty {
            subagentDirCache = subagentDirCache.filter { scannedSubagentParents.contains($0.key) }
        }

        let liveTPS = tpsTracker.update(
            busySessionIds: busyForTPS,
            subagentIds: activeBusyWorkerIds,
            samplesBySession: samplesBySession,
            now: now
        )

        let unique = SessionLogic.dedupBySessionId(builtSessions)
        let ordered = unique.sorted { a, b in
            a.cwd != b.cwd ? a.cwd < b.cwd : a.sessionId < b.sessionId
        }
        let labels = resolveLabels(for: ordered)
        let targets = gatherTargets(for: ordered, procTable: procTable, running: running)

        return SessionScan(
            sessions: ordered,
            labels: labels,
            targets: targets,
            titles: titles,
            instructions: instructions,
            contextSnapshots: contextSnapshots,
            liveTPS: liveTPS
        )
    }

    // MARK: - Process & Lock Discovery

    /// Native Darwin `libproc` process table snapshot (zero `fork/exec`, ~1-2ms steady-state).
    /// Populates `ppid`, controlling `tty` (`"ttys003"` or `"??"`), and executable path/name
    /// for all visible processes. Falls back to `PROC_PIDT_SHORTBSDINFO` for cross-UID
    /// ancestors (such as setuid-root `/usr/bin/login`) so `ppid`-walks still reach parent
    /// terminal `.app` bundles.
    private func snapshotProcTableNative() -> [Int: SessionLogic.ProcRow] {
        let estCount = proc_listallpids(nil, 0)
        guard estCount > 0 else { return [:] }

        let capacity = max(256, Int(estCount) + Int(estCount) / 2)
        var pids = [pid_t](repeating: 0, count: capacity)
        let byteSize = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let actualCount = proc_listallpids(&pids, byteSize)
        guard actualCount > 0 else { return [:] }

        let limit = min(Int(actualCount), pids.count)
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let shortSize = Int32(MemoryLayout<proc_bsdshortinfo>.stride)
        // `PROC_PIDPATHINFO_MAXSIZE` is `(4 * MAXPATHLEN)` in `<sys/proc_info.h>`.
        var pathBuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var ttyBuf = [CChar](repeating: 0, count: 64)

        var table: [Int: SessionLogic.ProcRow] = [:]
        table.reserveCapacity(limit)

        for i in 0..<limit {
            let pid = pids[i]
            guard pid > 0 else { continue }

            var bsdInfo = proc_bsdinfo()
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, bsdSize) == bsdSize {
                let ppid = Int(bsdInfo.pbi_ppid)
                let tty = resolveTTYName(rawDev: bsdInfo.e_tdev, buffer: &ttyBuf)
                let pathLen = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
                let comm: String
                if pathLen > 0 {
                    comm = Self.cString(fromPathBuffer: pathBuf, byteCount: Int(pathLen))
                } else {
                    let name = Self.cString(fromFixedBuffer: &bsdInfo.pbi_name)
                    comm = !name.isEmpty ? name : Self.cString(fromFixedBuffer: &bsdInfo.pbi_comm)
                }
                table[Int(pid)] = SessionLogic.ProcRow(ppid: ppid, tty: tty, comm: comm)
            } else {
                var shortInfo = proc_bsdshortinfo()
                guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &shortInfo, shortSize) == shortSize else {
                    continue
                }
                let ppid = Int(shortInfo.pbsi_ppid)
                let pathLen = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
                let comm: String
                if pathLen > 0 {
                    comm = Self.cString(fromPathBuffer: pathBuf, byteCount: Int(pathLen))
                } else {
                    comm = Self.cString(fromFixedBuffer: &shortInfo.pbsi_comm)
                }
                table[Int(pid)] = SessionLogic.ProcRow(ppid: ppid, tty: "??", comm: comm)
            }
        }
        return table
    }

    /// Format a `proc_bsdinfo.e_tdev` controlling terminal device number to `"ttys003"` or `"??"`.
    /// Caches resolved `dev_t -> String` on `queue` to avoid repeated `/dev` scans by `devname_r`.
    private func resolveTTYName(rawDev: UInt32, buffer: inout [CChar]) -> String {
        let signedDev = Int32(bitPattern: rawDev)
        guard rawDev != 0, rawDev != UInt32.max, signedDev != -1 else {
            return "??"
        }
        let dev = dev_t(signedDev)
        if let cached = ttyDevCache[dev] {
            return cached
        }
        guard let namePtr = devname_r(dev, mode_t(S_IFCHR), &buffer, Int32(buffer.count)) else {
            return "??"
        }
        let name = String(cString: namePtr)
        guard !name.isEmpty, name != "??" else {
            return "??"
        }
        if ttyDevCache.count >= 256 {
            ttyDevCache.removeAll(keepingCapacity: true)
        }
        ttyDevCache[dev] = name
        return name
    }

    private func discoverRunningProcesses(procTable: [Int: SessionLogic.ProcRow]) -> RunningSurfaceApps {
        var out = RunningSurfaceApps()
        for (pid, row) in procTable {
            let comm = row.comm
            let base = (comm as NSString).lastPathComponent
            if base == "agy" || comm.hasSuffix("/agy") {
                if processExists(pid) {
                    out.agyPids.append(pid)
                }
                continue
            }
            // Main Electron app executables (skip renderer/GPU Helper processes under Frameworks/)
            if !comm.contains(".app/Contents/Frameworks/"),
               let bundle = SessionLogic.appBundlePath(fromExecPath: comm) {
                let lower = bundle.lowercased()
                if lower.hasSuffix("/antigravity ide.app") {
                    out.ideApp = (pid: pid, bundlePath: bundle)
                } else if lower.hasSuffix("/antigravity.app") {
                    out.desktopApp = (pid: pid, bundlePath: bundle)
                }
            }
        }
        return out
    }

    private func processExists(_ pid: Int) -> Bool {
        guard pid > 0 else { return false }
        let r = kill(pid_t(pid), 0)
        return r == 0 || (r == -1 && errno == EPERM)
    }

    /// Inspect live `agy` CLI processes for `cwd` and open `presence/<convId>.lock` FDs.
    /// Uses native Darwin `libproc` syscalls and only falls back to `/usr/sbin/lsof` for
    /// any still-alive PID whose `proc_pidinfo` unexpectedly failed.
    private func inspectCLIProcesses(pids: [Int]) -> [Int: CLILockFact] {
        guard !pids.isEmpty else { return [:] }
        var facts = inspectCLIProcessesNative(pids: pids)
        let fallbackPids = pids.filter { facts[$0] == nil && processExists($0) }
        if !fallbackPids.isEmpty {
            for (pid, fact) in inspectCLIProcessesViaLsof(pids: fallbackPids) {
                facts[pid] = fact
            }
        }
        return facts
    }

    /// Native Darwin `libproc` inspection of `cwd` (`PROC_PIDVNODEPATHINFO`) and open
    /// `presence/*.lock` VNODE descriptors (`PROC_PIDLISTFDS` + `PROC_PIDFDVNODEPATHINFO`).
    private func inspectCLIProcessesNative(pids: [Int]) -> [Int: CLILockFact] {
        guard !pids.isEmpty else { return [:] }

        let vnodeSize = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        let fdStride = MemoryLayout<proc_fdinfo>.stride
        let vfdSize = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)

        var result: [Int: CLILockFact] = [:]
        result.reserveCapacity(pids.count)

        for pid in pids {
            let cPid = pid_t(pid)

            // 1. Resolve current working directory via PROC_PIDVNODEPATHINFO.
            var vnodeInfo = proc_vnodepathinfo()
            guard proc_pidinfo(cPid, PROC_PIDVNODEPATHINFO, 0, &vnodeInfo, vnodeSize) == vnodeSize else {
                continue
            }
            let cwd = Self.cString(fromFixedBuffer: &vnodeInfo.pvi_cdir.vip_path)

            // 2. Enumerate open file descriptors and inspect VNODE paths for `presence/<id>.lock`.
            let fdBufSize = proc_pidinfo(cPid, PROC_PIDLISTFDS, 0, nil, 0)
            guard fdBufSize > 0 else {
                continue
            }
            let estFdCount = Int(fdBufSize) / fdStride
            let capacity = max(64, estFdCount + max(32, estFdCount / 2))
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
            let gotBytes = proc_pidinfo(cPid, PROC_PIDLISTFDS, 0, &fds, Int32(capacity * fdStride))
            guard gotBytes > 0 else {
                continue
            }

            let fdCount = min(Int(gotBytes) / fdStride, fds.count)
            var lockIds: [String] = []
            var seenLockIds = Set<String>()

            for i in 0..<fdCount {
                let fd = fds[i]
                guard fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { continue }
                var vfd = vnode_fdinfowithpath()
                guard proc_pidfdinfo(cPid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vfd, vfdSize) == vfdSize else {
                    continue
                }
                let path = Self.cString(fromFixedBuffer: &vfd.pvip.vip_path)
                if let convId = SessionLogic.extractPresenceLockId(fromPath: path),
                   seenLockIds.insert(convId).inserted {
                    lockIds.append(convId)
                }
            }

            result[pid] = CLILockFact(pid: pid, cwd: cwd, lockIds: lockIds)
        }
        return result
    }

    /// Fallback: batched `lsof -n -P -F pcfn -p <pids>` parsed via `SessionLogic.parseLsofPresence`,
    /// supplemented by `SessionLogic.parseLsofCwds` for brand-new lockless processes.
    private func inspectCLIProcessesViaLsof(pids: [Int]) -> [Int: CLILockFact] {
        guard !pids.isEmpty else { return [:] }
        let arg = pids.map(String.init).joined(separator: ",")
        guard let out = runProcess("/usr/sbin/lsof", ["-n", "-P", "-F", "pcfn", "-p", arg]) else {
            return [:]
        }

        let parsedLocks = SessionLogic.parseLsofPresence(out)
        var cwds: [Int: String] = [:]
        var locks: [Int: [String]] = [:]
        for item in parsedLocks {
            if let cwd = item.cwd, !cwd.isEmpty {
                cwds[item.pid] = cwd
            }
            locks[item.pid, default: []].append(item.conversationId)
        }

        let locklessPids = pids.filter { locks[$0] == nil }
        if !locklessPids.isEmpty {
            let locklessArg = locklessPids.map(String.init).joined(separator: ",")
            if let cwdOut = runProcess("/usr/sbin/lsof", ["-a", "-p", locklessArg, "-d", "cwd", "-Fpn"]) {
                for (pid, cwd) in SessionLogic.parseLsofCwds(cwdOut) {
                    cwds[pid] = cwd
                }
            }
        }

        var result: [Int: CLILockFact] = [:]
        for pid in pids {
            result[pid] = CLILockFact(
                pid: pid,
                cwd: cwds[pid] ?? "",
                lockIds: locks[pid] ?? []
            )
        }
        return result
    }

    /// Safely decode a NUL-terminated UTF-8 string from a fixed-size C `char[N]` struct field tuple.
    private static func cString<T>(fromFixedBuffer tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { raw in
            let len = raw.firstIndex(of: 0) ?? raw.count
            return String(decoding: raw.prefix(len), as: UTF8.self)
        }
    }

    /// Safely decode a UTF-8 path string from a `proc_pidpath` output buffer bounded by `byteCount`.
    private static func cString(fromPathBuffer buffer: [CChar], byteCount: Int) -> String {
        guard byteCount > 0 else { return "" }
        return buffer.withUnsafeBytes { raw in
            let limit = min(byteCount, raw.count)
            let slice = raw.prefix(limit)
            let len = slice.firstIndex(of: 0) ?? limit
            return String(decoding: slice.prefix(len), as: UTF8.self)
        }
    }

    // MARK: - Conversation Metadata (SQLite + JSON Cache)

    private func loadMergedConversationMetadata() -> [String: ConvMeta] {
        let jsonRows = loadJSONMetadataCached()
        let dbRows = loadSQLiteSummariesCached()
        if dbRows.isEmpty { return jsonRows }
        if jsonRows.isEmpty { return dbRows }

        var merged = jsonRows
        for (id, dbItem) in dbRows {
            if let jItem = jsonRows[id] {
                merged[id] = Self.mergeConvMeta(jItem, dbItem)
            } else {
                merged[id] = dbItem
            }
        }
        return merged
    }

    private func loadJSONMetadataCached() -> [String: ConvMeta] {
        let fm = FileManager.default
        let path = usesCustomProjectsDir
            ? (cliRootDir as NSString).appendingPathComponent("cache/conversation_metadata.json")
            : AGYLocator.conversationMetadataJSONPath(home: homeDir)
        guard fm.fileExists(atPath: path),
              let attrs = try? fm.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? NSNumber else {
            cachedJSONStamp = ""
            cachedJSONRows.removeAll()
            return [:]
        }
        let stamp = "\(mtime.timeIntervalSinceReferenceDate)|\(size.int64Value)"
        if stamp == cachedJSONStamp { return cachedJSONRows }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) != nil else {
            return cachedJSONRows
        }
        let parsed = SessionLogic.parseConversationMetadataJSON(data)

        var out: [String: ConvMeta] = [:]
        for (convId, agy) in parsed {
            out[convId] = ConvMeta(
                id: agy.conversationId,
                title: agy.title ?? "",
                preview: agy.preview ?? "",
                stepCount: agy.stepCount,
                updatedAtMs: agy.effectiveUpdatedAtMs,
                cwd: agy.primaryWorkspace ?? "",
                rawStatus: agy.status ?? "",
                notFullyIdle: agy.notFullyIdle,
                killed: agy.isKilled,
                isInternal: SessionLogic.isSubagentOrInternal(agy),
                parentConversationId: agy.parentConversationId ?? "",
                appDataDir: agy.appDataDir ?? AGYSurface.cli.rawValue,
                source: "",
                dbSurface: AGYSurface.cli.rawValue
            )
        }
        cachedJSONStamp = stamp
        cachedJSONRows = out
        return out
    }

    private func loadSQLiteSummariesCached() -> [String: ConvMeta] {
        let fm = FileManager.default
        let candidateDBs: [(surface: AGYSurface, path: String)]
        if usesCustomProjectsDir {
            candidateDBs = AGYSurface.allCases.map { surface in
                let root = (geminiDir as NSString).appendingPathComponent(surface.rawValue)
                return (surface: surface, path: (root as NSString).appendingPathComponent("conversation_summaries.db"))
            }
        } else {
            candidateDBs = AGYLocator.conversationSummariesDBPaths(home: homeDir)
        }

        let existingDBs = candidateDBs.filter { fm.fileExists(atPath: $0.path) }
        guard !existingDBs.isEmpty else {
            cachedDBStamp = ""
            cachedDBRows.removeAll()
            cachedSQLiteByPath.removeAll()
            return [:]
        }

        let existingPathSet = Set(existingDBs.map(\.path))
        if !cachedSQLiteByPath.isEmpty {
            cachedSQLiteByPath = cachedSQLiteByPath.filter { existingPathSet.contains($0.key) }
        }

        // Per-DB stat stamp across every existing surface (db + wal) so unchanged surfaces stay ~0ms
        // and a transient open failure on one surface never overwrites another surface or caches partial rows.
        var stampParts: [String] = []
        stampParts.reserveCapacity(existingDBs.count)
        var perPathStamps: [String: String] = [:]
        perPathStamps.reserveCapacity(existingDBs.count)
        for item in existingDBs {
            let dbAttrs = try? fm.attributesOfItem(atPath: item.path)
            let dbMtime = (dbAttrs?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
            let dbSize = (dbAttrs?[.size] as? NSNumber)?.int64Value ?? 0

            let walPath = item.path + "-wal"
            let walAttrs = try? fm.attributesOfItem(atPath: walPath)
            let walMtime = (walAttrs?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
            let walSize = (walAttrs?[.size] as? NSNumber)?.int64Value ?? 0

            let part = "\(item.surface.rawValue)|\(item.path)|\(dbMtime)|\(dbSize)|\(walMtime)|\(walSize)"
            perPathStamps[item.path] = part
            stampParts.append(part)
        }
        let stamp = stampParts.joined(separator: ";")
        if stamp == cachedDBStamp { return cachedDBRows }

        var allHealthy = true
        var anyData = false
        for item in existingDBs {
            let part = perPathStamps[item.path] ?? ""
            if let hit = cachedSQLiteByPath[item.path], hit.stamp == part {
                anyData = true
                continue
            }
            if let rows = Self.readSQLiteSummaries(at: item.path, defaultSurface: item.surface) {
                cachedSQLiteByPath[item.path] = SQLiteSurfaceCacheEntry(stamp: part, rows: rows)
                anyData = true
            } else {
                // Transient open failure: retain previous good rows for this surface and retry next poll.
                allHealthy = false
                if cachedSQLiteByPath[item.path] != nil {
                    anyData = true
                }
            }
        }
        guard anyData else { return cachedDBRows }

        var out: [String: ConvMeta] = [:]
        for item in existingDBs {
            guard let rows = cachedSQLiteByPath[item.path]?.rows else { continue }
            for (convId, incoming) in rows {
                if let existing = out[convId] {
                    out[convId] = Self.mergeConvMeta(existing, incoming)
                } else {
                    out[convId] = incoming
                }
            }
        }

        cachedDBRows = out
        cachedDBStamp = allHealthy ? stamp : ""
        return out
    }

    private static func readSQLiteSummaries(
        at dbPath: String,
        defaultSurface: AGYSurface
    ) -> [String: ConvMeta]? {
        guard let db = openReadOnlySQLite(at: dbPath) else {
            return nil
        }
        defer { sqlite3_close_v2(db) }

        let columns = tableColumns(in: db, table: "conversation_summaries")
        guard columns.contains("conversation_id") else {
            return nil
        }
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
                \(col("status", fallback: "''")),
                \(col("parent_conversation_id", fallback: "''")),
                \(col("nesting_depth", fallback: "0")),
                \(col("not_fully_idle", fallback: "0")),
                \(col("killed", fallback: "0")),
                \(col("app_data_dir", fallback: "''")),
                \(col("source", fallback: "''"))
            FROM conversation_summaries
            """
        var stmt: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            sqlite3_finalize(stmt)
            return nil
        }
        defer { sqlite3_finalize(s) }

        var out: [String: ConvMeta] = [:]
        while sqlite3_step(s) == SQLITE_ROW {
            guard let idC = sqlite3_column_text(s, 0) else { continue }
            let convId = String(cString: idC)
            guard !convId.isEmpty else { continue }

            let title = sqlite3_column_text(s, 1).map { String(cString: $0) } ?? ""
            let preview = sqlite3_column_text(s, 2).map { String(cString: $0) } ?? ""
            let stepCount = Int(sqlite3_column_int(s, 3))
            let lastModStr = sqlite3_column_text(s, 4).map { String(cString: $0) }
            let workspaceURIsJSON = sqlite3_column_text(s, 5).map { String(cString: $0) } ?? ""
            let rawStatus = sqlite3_column_text(s, 6).map { String(cString: $0) } ?? ""
            let parentId = sqlite3_column_text(s, 7).map { String(cString: $0) } ?? ""
            let nestingDepth = Int(sqlite3_column_int(s, 8))
            let notFullyIdle = sqlite3_column_int(s, 9) != 0
            let killed = sqlite3_column_int(s, 10) != 0
            let rawAppDataDir = sqlite3_column_text(s, 11).map { String(cString: $0) } ?? ""
            let rawSource = sqlite3_column_text(s, 12).map { String(cString: $0) } ?? ""

            var uris: [String] = []
            if !workspaceURIsJSON.isEmpty,
               let data = workspaceURIsJSON.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
                uris = arr
            }

            let updatedMs: Double?
            if let isoMs = AITitleReader.parseValidEpochMs(lastModStr) {
                updatedMs = isoMs
            } else if let raw = lastModStr, let num = Double(raw), num > 946_684_800 {
                updatedMs = num > 10_000_000_000 ? num : num * 1000.0
            } else {
                updatedMs = nil
            }

            let isCLIMirror = defaultSurface != .cli && rawSource.uppercased().contains("CLI")
            let resolvedAppDataDir: String
            if isCLIMirror {
                resolvedAppDataDir = AGYSurface.cli.rawValue
            } else {
                resolvedAppDataDir = rawAppDataDir.isEmpty ? defaultSurface.rawValue : rawAppDataDir
            }

            out[convId] = ConvMeta(
                id: convId,
                title: title,
                preview: preview,
                stepCount: stepCount,
                updatedAtMs: updatedMs,
                cwd: firstWorkspacePath(from: uris),
                rawStatus: rawStatus,
                notFullyIdle: notFullyIdle,
                killed: killed,
                isInternal: !parentId.isEmpty || nestingDepth > 0,
                parentConversationId: parentId,
                appDataDir: resolvedAppDataDir,
                source: rawSource,
                dbSurface: defaultSurface.rawValue
            )
        }
        return out
    }

    private static func mergeConvMeta(_ lhs: ConvMeta, _ rhs: ConvMeta) -> ConvMeta {
        SessionLogic.mergeConversationSummaryRows(lhs, rhs)
    }

    /// Read-only SQLite open that handles WAL databases both while a writer is active
    /// AND after the writer exited cleanly and removed `-shm`/`-wal` (`immutable=1` fallback).
    static func openReadOnlySQLite(at path: String) -> OpaquePointer? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let uris = AGYLocator.sqliteReadOnlyURIs(forPath: path)
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX

        for (index, uri) in uris.enumerated() {
            var db: OpaquePointer? = nil
            if sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, let opened = db {
                if index == 0 {
                    sqlite3_busy_timeout(opened, 200)
                }
                var probe: OpaquePointer? = nil
                if sqlite3_prepare_v2(opened, "SELECT 1 FROM sqlite_master LIMIT 1", -1, &probe, nil) == SQLITE_OK {
                    sqlite3_finalize(probe)
                    return opened
                }
                sqlite3_finalize(probe)
                sqlite3_close_v2(opened)
            } else if let opened = db {
                sqlite3_close_v2(opened)
            }
        }
        return nil
    }

    private static func tableColumns(in db: OpaquePointer, table: String) -> Set<String> {
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

    private static func firstWorkspacePath(from uris: [String]) -> String {
        for raw in uris {
            if let path = SessionLogic.workspacePath(fromURI: raw) {
                return path
            }
        }
        return ""
    }

    // MARK: - Stat-Gated Per-Session File Caches

    private func brainDirs() -> [String] {
        if usesCustomProjectsDir {
            return AGYSurface.allCases.map { surface in
                ((geminiDir as NSString).appendingPathComponent(surface.rawValue) as NSString)
                    .appendingPathComponent("brain")
            }
        }
        return AGYLocator.brainDirs(home: homeDir)
    }

    private func readCachedTranscript(sessionId: String) -> TranscriptCacheEntry? {
        let fm = FileManager.default
        let path: String?
        if let cachedPath = transcriptCache[sessionId]?.path {
            path = cachedPath
        } else if usesCustomProjectsDir {
            path = AITitleReader.transcriptPath(
                sessionId: sessionId,
                projectsDir: URL(fileURLWithPath: geminiDir)
            )
        } else {
            path = AITitleReader.transcriptPath(sessionId: sessionId, home: homeDir)
        }
        guard let p = path, fm.fileExists(atPath: p) else { return nil }

        let attrs = try? fm.attributesOfItem(atPath: p)
        let size = (attrs?[.size] as? Int) ?? -1
        // Use 1970 Unix epoch consistently to match `SessionLogic.resolveLiveSessionStatus` (`now`)
        // and prevent epoch-mismatch cache misses on every 2s poll.
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1

        if let hit = transcriptCache[sessionId],
           hit.path == p, hit.size == size, hit.mtime == mtime {
            return hit
        }

        // Single bounded tail read (>= 256 KB) produces title, instruction, and tail step status together.
        let sum = AITitleReader.summary(inFileAt: p, needInstruction: true)
        let entry = TranscriptCacheEntry(
            path: p,
            size: size,
            mtime: mtime,
            title: sum.title,
            instruction: sum.instruction,
            tailSummary: sum
        )
        transcriptCache[sessionId] = entry
        return entry
    }

    private func cachedAnnotationTitle(sessionId: String) -> String? {
        guard AGYLocator.isSafeConversationId(sessionId) else { return nil }
        let fm = FileManager.default
        // Check all Antigravity surface annotation paths so Desktop & IDE sessions are stat-cached too.
        let candidatePaths: [String]
        if usesCustomProjectsDir {
            candidatePaths = AGYSurface.allCases.map { surface in
                let root = (geminiDir as NSString).appendingPathComponent(surface.rawValue)
                return ((root as NSString).appendingPathComponent("annotations") as NSString)
                    .appendingPathComponent("\(sessionId).pbtxt")
            }
        } else {
            candidatePaths = AGYLocator.candidateAnnotationPaths(home: homeDir, conversationId: sessionId)
        }
        for path in candidatePaths {
            guard fm.fileExists(atPath: path),
                  let mtime = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date)?
                      .timeIntervalSince1970 else {
                continue
            }
            if let hit = annotationCache[sessionId], hit.path == path, hit.mtime == mtime {
                return hit.title
            }
            let title = (try? String(contentsOfFile: path, encoding: .utf8))
                .flatMap { TranscriptParse.parseAnnotationTitle($0) }
                .flatMap { $0.isEmpty ? nil : $0 }
            annotationCache[sessionId] = AnnotationCacheEntry(path: path, mtime: mtime, title: title)
            return title
        }
        annotationCache.removeValue(forKey: sessionId)
        return nil
    }

    private func cachedSwarmInfo(
        sessionId: String
    ) -> (
        info: AITitleReader.SwarmCoordinatorInfo,
        activeWorkerIds: Set<String>,
        liveWorkerIds: Set<String>,
        killedWorkerIds: Set<String>
    )? {
        let fm = FileManager.default
        let candidatePaths = brainDirs().map {
            AGYLocator.swarmMembersPath(brainDir: $0, conversationId: sessionId)
        }
        guard let path = candidatePaths.first(where: { fm.fileExists(atPath: $0) }),
              let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int,
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate else {
            return nil
        }
        if let hit = swarmCache[sessionId], hit.size == size, hit.mtime == mtime {
            guard let info = hit.info else { return nil }
            return (info, hit.activeWorkerIds, hit.liveWorkerIds, hit.killedWorkerIds)
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let parsed = SessionLogic.parseSwarmMembersJSON(data) else {
            swarmCache[sessionId] = SwarmCacheEntry(
                size: size,
                mtime: mtime,
                info: nil,
                activeWorkerIds: [],
                liveWorkerIds: [],
                killedWorkerIds: []
            )
            return nil
        }
        let workers = parsed.members.filter { $0.role == "worker" && !$0.conversationId.isEmpty }
        let workerIds = Set(workers.map(\.conversationId))
        let nonMonitorWorkers = workers.filter { $0.name != "monitor" }
        let anyBusy = SessionLogic.anySwarmWorkerBusy(nonMonitorWorkers)
        let activeWorkerIds = Set(nonMonitorWorkers.filter { $0.isActivelyWorking }.map(\.conversationId))
        let liveWorkerIds = Set(workers.filter { !$0.killed }.map(\.conversationId))
        let killedWorkerIds = Set(workers.filter { $0.killed }.map(\.conversationId))
        let info = AITitleReader.SwarmCoordinatorInfo(
            title: parsed.title,
            anyWorkerBusy: anyBusy,
            workerConversationIds: workerIds
        )
        swarmCache[sessionId] = SwarmCacheEntry(
            size: size,
            mtime: mtime,
            info: info,
            activeWorkerIds: activeWorkerIds,
            liveWorkerIds: liveWorkerIds,
            killedWorkerIds: killedWorkerIds
        )
        return (info, activeWorkerIds, liveWorkerIds, killedWorkerIds)
    }

    /// Stat-cached reader for `brain/<parentId>/.system_generated/subagents/*.json`.
    /// Steady-state polls perform a single `stat` on the directory (+ stats on currently alive
    /// descriptors to detect in-place completion flips) with zero JSON reads when unchanged.
    private func cachedSubagentRecords(parentId: String) -> [SubagentRecord] {
        let fm = FileManager.default

        var resolvedDir: String? = nil
        var resolvedAttrs: [FileAttributeKey: Any]? = nil

        if let cached = subagentDirCache[parentId] {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: cached.dirPath, isDirectory: &isDir),
               isDir.boolValue,
               let attrs = try? fm.attributesOfItem(atPath: cached.dirPath) {
                resolvedDir = cached.dirPath
                resolvedAttrs = attrs
            }
        }
        if resolvedDir == nil {
            for brainDir in brainDirs() {
                let candidate = AGYLocator.subagentsDir(brainDir: brainDir, conversationId: parentId)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: candidate, isDirectory: &isDir),
                   isDir.boolValue,
                   let attrs = try? fm.attributesOfItem(atPath: candidate) {
                    resolvedDir = candidate
                    resolvedAttrs = attrs
                    break
                }
            }
        }

        guard let dirPath = resolvedDir, let attrs = resolvedAttrs else {
            subagentDirCache.removeValue(forKey: parentId)
            return []
        }

        let dirMtime = (attrs[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let dirSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0

        if var hit = subagentDirCache[parentId],
           hit.dirPath == dirPath,
           hit.dirMtime == dirMtime,
           hit.dirSize == dirSize {
            if hit.recheckFilenames.isEmpty {
                return hit.records
            }
            // Re-stat currently alive descriptors and any previously torn/unparsed JSON files
            // so in-place state flips or finalized writes are observed without a dir mtime bump.
            var anyRecheckChanged = false
            for filename in hit.recheckFilenames {
                let filePath = (dirPath as NSString).appendingPathComponent(filename)
                let fAttrs = try? fm.attributesOfItem(atPath: filePath)
                let fSize = (fAttrs?[.size] as? Int) ?? -1
                let fMtime = (fAttrs?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? -1
                if let prev = hit.files[filename], prev.size == fSize, prev.mtime == fMtime {
                    continue
                }
                anyRecheckChanged = true
                if fSize >= 0,
                   let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) {
                    let parsed = SessionLogic.parseSubagentRecordJSON(data)
                    hit.files[filename] = SubagentFileCacheEntry(size: fSize, mtime: fMtime, record: parsed)
                } else {
                    hit.files.removeValue(forKey: filename)
                }
            }
            if !anyRecheckChanged {
                return hit.records
            }
            var rebuiltRecords: [SubagentRecord] = []
            var rebuiltRecheck: [String] = []
            rebuiltRecords.reserveCapacity(hit.files.count)
            for filename in hit.files.keys.sorted() {
                if let rec = hit.files[filename]?.record {
                    rebuiltRecords.append(rec)
                    if rec.isAlive {
                        rebuiltRecheck.append(filename)
                    }
                } else {
                    rebuiltRecheck.append(filename)
                }
            }
            hit.records = rebuiltRecords
            hit.recheckFilenames = rebuiltRecheck
            subagentDirCache[parentId] = hit
            return rebuiltRecords
        }

        guard let entries = try? fm.contentsOfDirectory(atPath: dirPath) else {
            return subagentDirCache[parentId]?.records ?? []
        }
        let jsonNames = entries.filter { $0.hasSuffix(".json") }.sorted()
        let prevFiles = (subagentDirCache[parentId]?.dirPath == dirPath)
            ? (subagentDirCache[parentId]?.files ?? [:])
            : [:]

        var nextFiles: [String: SubagentFileCacheEntry] = [:]
        nextFiles.reserveCapacity(jsonNames.count)
        var records: [SubagentRecord] = []
        records.reserveCapacity(jsonNames.count)
        var recheckFilenames: [String] = []

        for filename in jsonNames {
            let filePath = (dirPath as NSString).appendingPathComponent(filename)
            guard let fAttrs = try? fm.attributesOfItem(atPath: filePath),
                  let fSize = fAttrs[.size] as? Int,
                  let fMtime = (fAttrs[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate else {
                continue
            }
            let entry: SubagentFileCacheEntry
            if let prev = prevFiles[filename], prev.size == fSize, prev.mtime == fMtime {
                entry = prev
            } else if let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) {
                let parsed = SessionLogic.parseSubagentRecordJSON(data)
                entry = SubagentFileCacheEntry(size: fSize, mtime: fMtime, record: parsed)
            } else {
                entry = SubagentFileCacheEntry(size: fSize, mtime: fMtime, record: nil)
            }
            nextFiles[filename] = entry
            if let rec = entry.record {
                records.append(rec)
                if rec.isAlive {
                    recheckFilenames.append(filename)
                }
            } else {
                recheckFilenames.append(filename)
            }
        }

        subagentDirCache[parentId] = SubagentDirCacheEntry(
            dirPath: dirPath,
            dirMtime: dirMtime,
            dirSize: dirSize,
            files: nextFiles,
            records: records,
            recheckFilenames: recheckFilenames
        )
        return records
    }

    // MARK: - Jump Targeting

    private func gatherTargets(
        for sessions: [SessionInfo],
        procTable: [Int: SessionLogic.ProcRow],
        running: RunningSurfaceApps
    ) -> [String: SessionTarget] {
        guard !sessions.isEmpty else { targetCache.removeAll(); return [:] }
        let live = Set(sessions.map { $0.sessionId })
        var result: [String: SessionTarget] = [:]

        for s in sessions {
            let surface = s.entrypoint ?? "cli"
            if surface == "antigravity" || surface == "antigravity-ide" {
                let appTuple = (surface == "antigravity-ide") ? running.ideApp : running.desktopApp
                let defaultBundlePath = (surface == "antigravity-ide")
                    ? "/Applications/Antigravity IDE.app"
                    : "/Applications/Antigravity.app"
                let bundlePath = appTuple?.bundlePath ?? defaultBundlePath
                let info = terminalAppInfo(bundlePath: bundlePath)
                let fallbackName = (surface == "antigravity-ide") ? "Antigravity IDE" : "Antigravity"
                let target = SessionTarget(
                    tty: nil,
                    terminal: .unknown,
                    appName: info.name ?? fallbackName,
                    bundleId: info.bundleId,
                    appPid: appTuple?.pid,
                    multiplexed: false,
                    cwd: s.cwd,
                    surface: surface
                )
                result[s.sessionId] = target
                continue
            }

            if let hit = targetCache[s.sessionId], hit.pid == s.pid {
                result[s.sessionId] = hit.target
                continue
            }

            let pt = SessionLogic.resolveTarget(table: procTable, pid: s.pid)
            let info = pt.appBundlePath.map { terminalAppInfo(bundlePath: $0) }
            let target = SessionTarget(
                tty: pt.tty,
                terminal: pt.terminal,
                appName: info?.name,
                bundleId: info?.bundleId,
                appPid: pt.appPid,
                multiplexed: pt.multiplexed,
                cwd: s.cwd,
                surface: "antigravity-cli"
            )
            result[s.sessionId] = target
            if pt.pidPresent {
                targetCache[s.sessionId] = (s.pid, target)
            }
        }

        if !targetCache.isEmpty {
            targetCache = targetCache.filter { live.contains($0.key) }
        }
        return result
    }

    private func terminalAppInfo(bundlePath: String) -> (bundleId: String?, name: String?) {
        if let hit = terminalInfoCache[bundlePath] { return hit }
        let bundle = Bundle(path: bundlePath)
        let bundleId = bundle?.bundleIdentifier
        let name = (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle?.infoDictionary?["CFBundleName"] as? String)
            ?? {
                let base = (bundlePath as NSString).lastPathComponent
                return base.hasSuffix(".app") ? String(base.dropLast(4)) : base
            }()
        let info = (bundleId, name)
        terminalInfoCache[bundlePath] = info
        return info
    }

    // MARK: - Display Labels (git top-level)

    private func resolveLabels(for sessions: [SessionInfo]) -> [String: String] {
        let activeCwds = Set(sessions.map(\.cwd).filter { !$0.isEmpty })
        if labelCache.count > 64 {
            labelCache = labelCache.filter { activeCwds.contains($0.key) }
        }
        var labels: [String: String] = [:]
        for cwd in activeCwds {
            if let cached = labelCache[cwd] {
                labels[cwd] = cached
                continue
            }
            let label: String
            if cwd != homeDir,
               let top = runProcess("/usr/bin/git", ["-C", cwd, "rev-parse", "--show-toplevel"])?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               !top.isEmpty {
                label = SessionLogic.basename(top)
            } else {
                label = SessionLogic.basename(cwd)
            }
            if labelCache.count >= 64 {
                labelCache = labelCache.filter { activeCwds.contains($0.key) }
            }
            if labelCache.count < 64 {
                labelCache[cwd] = label
            }
            labels[cwd] = label
        }
        return labels
    }

    private func runProcess(_ launchPath: String, _ args: [String],
                            timeout: TimeInterval = 5.0) -> String? {
        ProcessRunner.run(launchPath, args, timeout: timeout)?.output
    }
}
