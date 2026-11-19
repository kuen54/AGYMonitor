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
    }

    private let jumper = SessionJumper()
    private var jumpHintBanner = TransientBannerState()
    private var jumpHintClear: DispatchWorkItem?

    // MARK: Lifecycle

    func startMonitoring() { monitor.start() }
    func setActive(_ active: Bool) { monitor.setActive(active) }
    func stopMonitoring() { monitor.stop() }

    /// Clear a single session's green "finished, unseen" dot on user engagement.
    func markSeen(_ sessionId: String) { monitor.markSeen(sessionId: sessionId) }

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
