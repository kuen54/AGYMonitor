import Foundation
import Combine

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

    // MARK: Universal Session Black Box Replay (On-Demand, 0% Idle Overhead)

    /// Recent Antigravity missions discovered across CLI, Desktop, and IDE.
    @Published var replayMissions: [ReplayMissionSummary] = []
    /// Currently selected mission conversation ID in the Black Box deck.
    @Published var selectedReplayMissionId: String? = nil
    /// Loaded multi-track timeline for `selectedReplayMissionId`.
    @Published var activeReplay: ReplayTimeline? = nil
    /// True while `loadReplayIndex` is scanning mission metadata off-main.
    @Published var isReplayIndexLoading: Bool = false
    /// True while `selectReplayMission` is parsing transcripts/board off-main.
    @Published var isReplayTimelineLoading: Bool = false

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
    }

    private let jumper = SessionJumper()
    private var jumpHintBanner = TransientBannerState()
    private var jumpHintClear: DispatchWorkItem?

    private lazy var replayService = SessionReplayService()
    private var replayIndexGeneration: Int = 0
    private var replayTimelineGeneration: Int = 0
    private var lastReplayIndexLoadedAt: Date? = nil
    private static let replayIndexFreshnessWindowSec: TimeInterval = 5.0

    // MARK: Lifecycle

    func startMonitoring() { monitor.start() }
    func setActive(_ active: Bool) {
        if !active {
            setJumpHint(nil)
        }
        monitor.setActive(active)
    }
    func stopMonitoring() { monitor.stop() }

    /// Clear a single session's green "finished, unseen" dot on user engagement.
    func markSeen(_ sessionId: String) { monitor.markSeen(sessionId: sessionId) }

    // MARK: Black Box Replay Actions

    /// Scans recent missions off-main (deduplicating concurrent calls).
    /// When `selectedReplayMissionId == nil` and missions are found, automatically selects `first.id`.
    func loadReplayIndex(force: Bool = false) {
        if !force {
            if isReplayIndexLoading { return }
            if !replayMissions.isEmpty,
               let loadedAt = lastReplayIndexLoadedAt,
               Date().timeIntervalSince(loadedAt) < Self.replayIndexFreshnessWindowSec {
                if selectedReplayMissionId == nil, let first = replayMissions.first {
                    selectReplayMission(first.id)
                }
                return
            }
        }

        replayIndexGeneration += 1
        let gen = replayIndexGeneration
        isReplayIndexLoading = true
        let liveIds = Set(sessions.map(\.sessionId))

        replayService.listRecentMissionsAsync(liveSessionIds: liveIds) { [weak self] missions in
            guard let self = self, self.replayIndexGeneration == gen else { return }
            self.isReplayIndexLoading = false
            self.lastReplayIndexLoadedAt = Date()
            if self.replayMissions != missions {
                self.replayMissions = missions
            }
            if self.selectedReplayMissionId == nil, let first = missions.first {
                self.selectReplayMission(first.id)
            } else if force, let currentId = self.selectedReplayMissionId {
                self.selectReplayMission(currentId)
            }
        }
    }

    /// Selects `id` and loads its `ReplayTimeline` asynchronously via `SessionReplayService`.
    /// Guarded by a monotonic generation counter so rapid stepping never overwrites newer selection.
    func selectReplayMission(_ id: String) {
        guard !id.isEmpty else { return }
        replayTimelineGeneration += 1
        let gen = replayTimelineGeneration
        if selectedReplayMissionId != id {
            selectedReplayMissionId = id
        }
        isReplayTimelineLoading = true

        replayService.loadTimelineAsync(missionId: id) { [weak self] timeline in
            guard let self = self,
                  self.replayTimelineGeneration == gen,
                  self.selectedReplayMissionId == id else {
                return
            }
            self.isReplayTimelineLoading = false
            if self.activeReplay != timeline {
                self.activeReplay = timeline
            }
        }
    }

    /// Clears the active replay selection and invalidates any in-flight timeline loads.
    func clearReplaySelection() {
        replayTimelineGeneration += 1
        selectedReplayMissionId = nil
        activeReplay = nil
        isReplayTimelineLoading = false
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
