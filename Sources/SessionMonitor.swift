import Foundation
import CoreServices
import Darwin
import SQLite3

// MARK: - Live Antigravity Session Monitor (app layer)
//
// Detects live Google Antigravity conversations across CLI (`agy`), Desktop
// (`Antigravity.app`), and IDE (`Antigravity IDE.app`) by combining:
//   1. Live `agy` CLI processes holding `~/.gemini/antigravity-cli/presence/<id>.lock`
//      (resolved in one batched `ps` + `lsof -F pfn` pass for PID, TTY, cwd)
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

    static let empty = SessionScan(sessions: [], labels: [:])
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
    }
    private var swarmCache: [String: SwarmCacheEntry] = [:]

    private struct ConvMeta: Equatable {
        var id: String
        var title: String
        var preview: String
        var stepCount: Int
        var updatedAtMs: Double?
        var cwd: String
        var rawStatus: String
        var notFullyIdle: Bool
        var killed: Bool
        var isInternal: Bool
        var parentConversationId: String
        var appDataDir: String
    }

    private var cachedDBStamp: String = ""
    private var cachedDBRows: [String: ConvMeta] = [:]

    private var cachedJSONStamp: String = ""
    private var cachedJSONRows: [String: ConvMeta] = [:]

    private var targetCache: [String: (pid: Int, target: SessionTarget)] = [:]
    private var terminalInfoCache: [String: (bundleId: String?, name: String?)] = [:]

    // Done-unseen state (busy/waiting -> idle transition tracker)
    private var doneUnseenState = DoneUnseenState()

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
        if let s = fsStream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }

    private func syncPublishedLifecycleFlag() {
        runGenLock.lock()
        activeRunGeneration = lifecycle.runGeneration
        isMonitorRunning = lifecycle.isStarted
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
        queue.async { [weak self] in
            self?.dispatchLifecycle(.stop)
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

    private func dispatchLifecycle(_ event: SessionMonitorLifecycleEvent) {
        let wasStarted = lifecycle.isStarted
        let effects = SessionMonitorLifecycleMachine.reduce(&lifecycle, event: event)
        if wasStarted && !lifecycle.isStarted {
            doneUnseenState.reset()
            lastScan = nil
        }
        syncPublishedLifecycleFlag()
        for effect in effects {
            switch effect {
            case .startFSWatcher:
                startFSWatcher()
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

    private func startFSWatcher() {
        let attemptAt = Date()
        stopFSWatcher()
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
        let existingDirs = Array(Set(candidateDirs)).sorted().filter { path in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
        guard !existingDirs.isEmpty else {
            dispatchLifecycle(.fsWatcherAttempted(healthy: false, at: attemptAt))
            return
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            let monitor = Unmanaged<SessionMonitor>.fromOpaque(info).takeUnretainedValue()
            monitor.dispatchLifecycle(.fsEventReceived)
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            existingDirs as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)
        ) else {
            dispatchLifecycle(.fsWatcherAttempted(healthy: false, at: attemptAt))
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        if FSEventStreamStart(stream) {
            fsStream = stream
            lifecycle.watchedDirs = existingDirs
            // Any existing Antigravity surface root (CLI, Desktop, or IDE) gives a healthy
            // watcher — Desktop/IDE-only setups no longer thrash teardown/recreate every 30s.
            dispatchLifecycle(.fsWatcherAttempted(healthy: !existingDirs.isEmpty, at: attemptAt))
        } else {
            NSLog("AGYMonitor: session FSEventStreamStart failed; poll-only")
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            fsStream = nil
            lifecycle.watchedDirs = []
            dispatchLifecycle(.fsWatcherAttempted(healthy: false, at: attemptAt))
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

        // 1. Single `ps` snapshot for process discovery AND terminal ppid-walk
        let psOut = runProcess("/bin/ps", ["-Ao", "pid=,ppid=,tty=,comm="]) ?? ""
        let procTable = SessionLogic.parseProcTable(psOut)
        let running = discoverRunningProcesses(procTable: procTable)

        // 2. Single batched `lsof` over live `agy` CLI processes for cwd + open presence/*.lock
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

        // 4. Inspect swarm hierarchies so internal worker conversations are hidden
        //    and their working state rolls up into their coordinator session.
        var allSwarmWorkerIds = Set<String>()
        var swarmBusyCoordinators = Set<String>()
        var swarmTitles: [String: String] = [:]

        // Check swarm/members.json for any lock-held or metadata-known non-internal conversation
        var potentialCoordinators = Set(cliLockOwners.keys)
        for (id, meta) in metaById where !meta.isInternal && !meta.killed {
            potentialCoordinators.insert(id)
        }
        for coordId in potentialCoordinators {
            if let swarm = cachedSwarmInfo(sessionId: coordId) {
                allSwarmWorkerIds.formUnion(swarm.workerConversationIds)
                if swarm.anyWorkerBusy {
                    swarmBusyCoordinators.insert(coordId)
                }
                if let t = swarm.title, !t.isEmpty {
                    swarmTitles[coordId] = t
                }
            }
        }
        // Also roll up busy state from `parentConversationId` in conversation_summaries.db
        for (_, meta) in metaById where !meta.parentConversationId.isEmpty && !meta.killed {
            allSwarmWorkerIds.insert(meta.id)
            if meta.notFullyIdle || meta.rawStatus == "CASCADE_RUN_STATUS_RUNNING" {
                swarmBusyCoordinators.insert(meta.parentConversationId)
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

        // 6. Resolve transcript summaries, live statuses, titles, instructions, and targets
        var builtSessions: [SessionInfo] = []
        var titles: [String: String] = [:]
        var instructions: [String: String] = [:]
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

        // Prune per-session caches
        if !transcriptCache.isEmpty {
            transcriptCache = transcriptCache.filter { liveIds.contains($0.key) }
        }
        if !annotationCache.isEmpty {
            annotationCache = annotationCache.filter { liveIds.contains($0.key) }
        }
        if !swarmCache.isEmpty {
            swarmCache = swarmCache.filter { potentialCoordinators.contains($0.key) }
        }

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
            instructions: instructions
        )
    }

    // MARK: - Process & Lock Discovery

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

    /// Batched `lsof -n -P -F pcfn -p <pids>` parsed via `SessionLogic.parseLsofPresence`,
    /// supplemented by `SessionLogic.parseLsofCwds` for brand-new lockless processes.
    private func inspectCLIProcesses(pids: [Int]) -> [Int: CLILockFact] {
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

    // MARK: - Conversation Metadata (SQLite + JSON Cache)

    private func loadMergedConversationMetadata() -> [String: ConvMeta] {
        let jsonRows = loadJSONMetadataCached()
        let dbRows = loadSQLiteSummariesCached()
        if dbRows.isEmpty { return jsonRows }
        if jsonRows.isEmpty { return dbRows }

        var merged = jsonRows
        for (id, var dbItem) in dbRows {
            if let jItem = jsonRows[id] {
                if jItem.isInternal { dbItem.isInternal = true }
                if dbItem.title.isEmpty && !jItem.title.isEmpty { dbItem.title = jItem.title }
                if dbItem.preview.isEmpty && !jItem.preview.isEmpty { dbItem.preview = jItem.preview }
                if dbItem.cwd.isEmpty && !jItem.cwd.isEmpty { dbItem.cwd = jItem.cwd }
                if let ju = jItem.updatedAtMs, ju > (dbItem.updatedAtMs ?? 0) {
                    dbItem.updatedAtMs = ju
                }
            }
            merged[id] = dbItem
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
                appDataDir: agy.appDataDir ?? AGYSurface.cli.rawValue
            )
        }
        cachedJSONStamp = stamp
        cachedJSONRows = out
        return out
    }

    private func loadSQLiteSummariesCached() -> [String: ConvMeta] {
        let fm = FileManager.default
        let dbPath = usesCustomProjectsDir
            ? (cliRootDir as NSString).appendingPathComponent("conversation_summaries.db")
            : AGYLocator.conversationSummariesDBPath(home: homeDir)
        guard fm.fileExists(atPath: dbPath) else {
            cachedDBStamp = ""
            cachedDBRows.removeAll()
            return [:]
        }

        let dbAttrs = try? fm.attributesOfItem(atPath: dbPath)
        let dbMtime = (dbAttrs?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let dbSize = (dbAttrs?[.size] as? NSNumber)?.int64Value ?? 0

        let walPath = dbPath + "-wal"
        let walAttrs = try? fm.attributesOfItem(atPath: walPath)
        let walMtime = (walAttrs?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let walSize = (walAttrs?[.size] as? NSNumber)?.int64Value ?? 0

        let stamp = "\(dbMtime)|\(dbSize)|\(walMtime)|\(walSize)"
        if stamp == cachedDBStamp { return cachedDBRows }

        guard let db = Self.openReadOnlySQLite(at: dbPath) else {
            return cachedDBRows
        }
        defer { sqlite3_close_v2(db) }

        let sql = """
            SELECT conversation_id, title, preview, step_count, last_modified_time,
                   workspace_uris, status, parent_conversation_id, nesting_depth,
                   not_fully_idle, killed, app_data_dir
            FROM conversation_summaries
            """
        var stmt: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            sqlite3_finalize(stmt)
            return cachedDBRows
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
            let appDataDir = sqlite3_column_text(s, 11).map { String(cString: $0) } ?? "antigravity-cli"

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

            out[convId] = ConvMeta(
                id: convId,
                title: title,
                preview: preview,
                stepCount: stepCount,
                updatedAtMs: updatedMs,
                cwd: Self.firstWorkspacePath(from: uris),
                rawStatus: rawStatus,
                notFullyIdle: notFullyIdle,
                killed: killed,
                isInternal: !parentId.isEmpty || nestingDepth > 0,
                parentConversationId: parentId,
                appDataDir: appDataDir.isEmpty ? "antigravity-cli" : appDataDir
            )
        }

        cachedDBStamp = stamp
        cachedDBRows = out
        return out
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

    private static func firstWorkspacePath(from uris: [String]) -> String {
        for raw in uris {
            if let path = SessionLogic.workspacePath(fromURI: raw) {
                return path
            }
        }
        return ""
    }

    // MARK: - Stat-Gated Per-Session File Caches

    private func readCachedTranscript(sessionId: String) -> TranscriptCacheEntry? {
        let fm = FileManager.default
        let path = transcriptCache[sessionId]?.path
            ?? AITitleReader.transcriptPath(sessionId: sessionId, home: homeDir)
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
        let fm = FileManager.default
        // Check all 3 Antigravity surface annotation paths so Desktop & IDE sessions are stat-cached too.
        for surface in AGYSurface.allCases {
            let root = AGYLocator.surfaceRoot(home: homeDir, surface: surface)
            let path = ((root as NSString).appendingPathComponent("annotations") as NSString)
                .appendingPathComponent("\(sessionId).pbtxt")
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

    private func cachedSwarmInfo(sessionId: String) -> AITitleReader.SwarmCoordinatorInfo? {
        let fm = FileManager.default
        let candidatePaths = AGYLocator.brainDirs(home: homeDir).map {
            AGYLocator.swarmMembersPath(brainDir: $0, conversationId: sessionId)
        }
        guard let path = candidatePaths.first(where: { fm.fileExists(atPath: $0) }),
              let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int,
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate else {
            return nil
        }
        if let hit = swarmCache[sessionId], hit.size == size, hit.mtime == mtime {
            return hit.info
        }
        let info = AITitleReader.swarmInfo(sessionId: sessionId, home: homeDir)
        swarmCache[sessionId] = SwarmCacheEntry(size: size, mtime: mtime, info: info)
        return info
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
        var labels: [String: String] = [:]
        for cwd in Set(sessions.map { $0.cwd }) where !cwd.isEmpty {
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
            labelCache[cwd] = label
            labels[cwd] = label
        }
        return labels
    }

    private func runProcess(_ launchPath: String, _ args: [String],
                            timeout: TimeInterval = 5.0) -> String? {
        ProcessRunner.run(launchPath, args, timeout: timeout)?.output
    }
}
