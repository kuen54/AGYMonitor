import Foundation
import Combine

/// Atomic snapshot of acoustic-trigger session IDs published once per completed scan.
/// Remains `nil` until the first real scan completes (and resets to `nil` on `stopMonitoring()`),
/// preventing startup acoustic chime races or split Combine emissions.
struct AcousticSessionSnapshot: Equatable, Sendable {
    let waitingIds: Set<String>
    let doneUnseenIds: Set<String>
}

// MARK: - Live-session store (app layer)
//
// Holds live Antigravity session state (CLI + Desktop + IDE) in its own
// ObservableObject so ~2 s session scans only re-render views that observe
// sessions (Sessions tab, menu bar badge, notch spinner/dot), never the entire
// PopoverView.
final class SessionStore: ObservableObject {

    /// Live interactive Antigravity sessions (maintained by SessionMonitor).
    @Published var sessions: [SessionInfo] = []
    /// cwd → display label (git top-level basename when resolvable).
    @Published var labels: [String: String] = [:]
    /// sessionId → terminal or app targeting facts for click-to-jump.
    @Published var targets: [String: SessionTarget] = [:]
    /// sessionId → session title (annotation / summary / swarm / transcript).
    @Published var titles: [String: String] = [:]
    /// sessionId → latest clean user instruction (one line).
    @Published var instructions: [String: String] = [:]
    /// Transient, non-modal hint localization key after an app-only or failed jump.
    @Published var jumpHint: String? = nil
    /// Aggregate finished-unseen cue for the notch/menu-bar green dot.
    @Published var anyDoneUnseen: Bool = false
    /// Exact sessionIds that finished a turn unseen (cleared per-row on click).
    @Published var doneUnseen: Set<String> = []
    /// sessionId → live context window usage & remaining ratio snapshot.
    @Published var contextSnapshots: [String: SessionContextSnapshot] = [:]
    /// Aggregated live output throughput across all busy sessions (+ active swarm workers).
    @Published var liveTPS: LiveTPSSnapshot = .idle
    /// True once at least one real `SessionMonitor` scan has completed (reset on `stopMonitoring()`).
    @Published var hasCompletedInitialScan: Bool = false
    /// Atomic acoustic snapshot (`waitingIds` + `doneUnseenIds`), `nil` before initial scan completes.
    @Published var acousticSnapshot: AcousticSessionSnapshot? = nil

    // MARK: Universal Session Black Box Replay (On-Demand, 0% Idle Overhead)

    /// Active Sessions tab deck mode (`.live` vs `.blackBox`), shared across views & panel height keying.
    @Published var deckMode: SessionDeckMode = .live
    /// Single source of truth for Black Box mission index & timeline loading (driven by `ReplayStoreMachine`).
    @Published var replayState: ReplayStoreState = ReplayStoreState()

    /// Recent Antigravity missions discovered across CLI, Desktop, and IDE.
    var replayMissions: [ReplayMissionSummary] { replayState.missions }
    /// Currently selected mission conversation ID in the Black Box deck.
    var selectedReplayMissionId: String? { replayState.selectedMissionId }
    /// Loaded multi-track timeline for `selectedReplayMissionId`.
    var activeReplay: ReplayTimeline? { replayState.activeReplay }
    /// True while mission metadata index is scanning off-main.
    var isReplayIndexLoading: Bool { replayState.isIndexLoading }
    /// True while a timeline transcript/board parse is running off-main.
    var isReplayTimelineLoading: Bool { replayState.isTimelineLoading }
    /// True when the selected mission has no parseable timeline on disk.
    var isReplayTimelineUnavailable: Bool { replayState.isTimelineUnavailable }

    var liveCount: Int { sessions.count }
    var anyBusy: Bool { sessions.contains { $0.status == .busy } }
    var anyWaiting: Bool { sessions.contains { $0.status == .waiting } }

    /// Sessions grouped by cwd, with git-resolved repository labels overlaid.
    var groups: [SessionGroup] {
        SessionLogic.grouped(sessions).map { g in
            guard let refined = labels[g.cwd], refined != g.label else { return g }
            return SessionGroup(cwd: g.cwd, label: refined, sessions: g.sessions)
        }
    }

    private lazy var monitor = SessionMonitor { [weak self] scan in
        guard let self = self else { return }
        if self.sessions != scan.sessions { self.sessions = scan.sessions }
        if self.labels != scan.labels { self.labels = scan.labels }
        if self.targets != scan.targets { self.targets = scan.targets }
        if self.titles != scan.titles { self.titles = scan.titles }
        if self.instructions != scan.instructions { self.instructions = scan.instructions }
        if self.anyDoneUnseen != scan.anyDoneUnseen { self.anyDoneUnseen = scan.anyDoneUnseen }
        if self.doneUnseen != scan.doneUnseenIds { self.doneUnseen = scan.doneUnseenIds }
        if self.contextSnapshots != scan.contextSnapshots { self.contextSnapshots = scan.contextSnapshots }
        if self.liveTPS != scan.liveTPS { self.liveTPS = scan.liveTPS }
        if !self.hasCompletedInitialScan { self.hasCompletedInitialScan = true }
        let nextAcoustic = AcousticSessionSnapshot(
            waitingIds: Set(scan.sessions.filter { $0.status == .waiting }.map(\.sessionId)),
            doneUnseenIds: scan.doneUnseenIds
        )
        if self.acousticSnapshot != nextAcoustic {
            self.acousticSnapshot = nextAcoustic
        }
    }

    private let jumper = SessionJumper()
    private var jumpHintBanner = TransientBannerState()
    private var jumpHintClear: DispatchWorkItem?

    private final class AtomicGenerationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Int = 0

        func set(_ generation: Int) {
            lock.lock()
            current = generation
            lock.unlock()
        }

        func matches(_ expected: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return current == expected
        }
    }

    private lazy var replayService = SessionReplayService()
    private let replayTimelineGenerationBox = AtomicGenerationBox()

    // MARK: Lifecycle

    func startMonitoring() { monitor.start() }
    func setActive(_ active: Bool) {
        if !active {
            setJumpHint(nil)
        }
        monitor.setActive(active)
    }
    func stopMonitoring() {
        monitor.stop()
        if hasCompletedInitialScan { hasCompletedInitialScan = false }
        if acousticSnapshot != nil { acousticSnapshot = nil }
    }

    /// Clear a single session's green "finished, unseen" dot on user engagement.
    func markSeen(_ sessionId: String) { monitor.markSeen(sessionId: sessionId) }

    // MARK: Black Box Replay Actions

    /// Opens Black Box (optionally pinning a preferred mission ID) and executes index/timeline effects
    /// through `ReplayStoreMachine` without duplicate parses.
    func openBlackBox(preferredMissionId: String? = nil, force: Bool = false) {
        dispatchReplayEvent(.openBlackBox(
            preferredMissionId: preferredMissionId,
            force: force,
            now: Date()
        ))
    }

    /// Scans recent missions off-main via `ReplayStoreMachine` (deduplicating concurrent calls).
    func loadReplayIndex(force: Bool = false) {
        openBlackBox(preferredMissionId: nil, force: force)
    }

    /// Selects `id` and loads its `ReplayTimeline` asynchronously via `SessionReplayService`.
    /// Superseded background parses bail out early via `replayTimelineGenerationBox`.
    func selectReplayMission(_ id: String, force: Bool = false) {
        guard !id.isEmpty else { return }
        dispatchReplayEvent(.selectMission(id: id, force: force))
    }

    /// Clears the active replay selection and invalidates any in-flight timeline loads.
    func clearReplaySelection() {
        dispatchReplayEvent(.clearSelection)
    }

    private func dispatchReplayEvent(_ event: ReplayStoreEvent) {
        let effects = ReplayStoreMachine.reduce(&replayState, event: event)
        replayTimelineGenerationBox.set(replayState.timelineGeneration)

        for effect in effects {
            switch effect {
            case .scanIndex(let generation):
                let liveIds = Set(sessions.map(\.sessionId))
                replayService.listRecentMissionsAsync(liveSessionIds: liveIds) { [weak self] missions in
                    self?.dispatchReplayEvent(.indexLoaded(
                        generation: generation,
                        missions: missions,
                        now: Date()
                    ))
                }

            case .loadTimeline(let missionId, let generation):
                let genBox = replayTimelineGenerationBox
                replayService.loadTimelineAsync(
                    missionId: missionId,
                    isCurrent: { genBox.matches(generation) }
                ) { [weak self] timeline in
                    self?.dispatchReplayEvent(.timelineLoaded(
                        generation: generation,
                        missionId: missionId,
                        timeline: timeline
                    ))
                }
            }
        }
    }

    /// Click-to-jump: focus/raise the terminal pane or Antigravity Desktop/IDE window.
    func jump(_ session: SessionInfo) {
        markSeen(session.sessionId)
        let target = targets[session.sessionId]
            ?? SessionTarget(tty: nil, terminal: .unknown, appName: nil,
                             bundleId: nil, appPid: nil, multiplexed: false,
                             cwd: session.cwd, surface: session.entrypoint)
        let knownTitle = titles[session.sessionId]
        jumper.jump(session: session, target: target, knownTitle: knownTitle) { [weak self] outcome in
            self?.handleJumpOutcome(outcome)
        }
    }

    private func handleJumpOutcome(_ outcome: JumpOutcome) {
        switch outcome {
        case .focusedPane:
            setJumpHint(nil)
        case .appOnly(let reason):
            setJumpHint(reason == .permissionDenied
                ? "sessionJumpNeedsPermission" : "sessionJumpAppOnly")
        case .failed:
            setJumpHint("sessionJumpFailed")
        }
    }

    private func setJumpHint(_ key: String?) {
        jumpHintClear?.cancel()
        jumpHintClear = nil
        let token = jumpHintBanner.show(key)
        if jumpHint != jumpHintBanner.messageKey {
            jumpHint = jumpHintBanner.messageKey
        }
        guard let token = token else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if self.jumpHintBanner.expire(generation: token) {
                self.jumpHint = self.jumpHintBanner.messageKey
            }
        }
        jumpHintClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: work)
    }
}
