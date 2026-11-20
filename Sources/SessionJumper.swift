import Foundation
import AppKit

// MARK: - Session Jumper (app layer)
//
// Click-to-jump: focus/raise the terminal window & tab/pane owning an `agy` CLI
// session (Otty via `otty-cli`, Apple Terminal & iTerm2 via TTY AppleScript,
// WezTerm via `wezterm cli`, Ghostty/Kitty/Alacritty via app activation), OR
// activate `Antigravity` / `Antigravity IDE` for Desktop & IDE conversations.
// App-only — NEVER part of AGYCore.

enum JumpOutcome: Equatable {
    case focusedPane               // landed on the exact pane/tab or GUI app
    case appOnly(JumpReason)       // could only bring the terminal app forward
    case failed(JumpReason)        // couldn't activate target
}

enum JumpReason: String, Equatable {
    case ambiguous
    case permissionDenied
    case unsupported
    case noTarget
    case launchFailed
}

final class SessionJumper {
    private let queue = DispatchQueue(label: "com.kuen54.AGYMonitor.jump", qos: .userInitiated)
    private let gateLock = NSLock()
    private var requestGate = JumpRequestGate()

    func jump(
        session: SessionInfo,
        target: SessionTarget,
        knownTitle: String? = nil,
        completion: ((JumpOutcome) -> Void)? = nil
    ) {
        gateLock.lock()
        let generation = requestGate.beginRequest()
        gateLock.unlock()

        queue.async { [weak self] in
            guard let self = self else { return }
            guard self.isLatestRequest(generation) else { return }
            let outcome = self.perform(session: session, target: target, knownTitle: knownTitle)
            guard self.isLatestRequest(generation) else { return }
            if let completion = completion {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.isLatestRequest(generation) else { return }
                    completion(outcome)
                }
            }
        }
    }

    private func isLatestRequest(_ generation: Int) -> Bool {
        gateLock.lock()
        defer { gateLock.unlock() }
        return requestGate.isLatest(generation)
    }

    // MARK: - Dispatch by surface / terminal

    private func perform(session: SessionInfo, target: SessionTarget, knownTitle: String?) -> JumpOutcome {
        if isDesktopOrIDESession(session: session, target: target) {
            return jumpAntigravityApp(session: session, target: target)
        }

        switch target.terminal {
        case .otty:          return jumpOtty(session: session, target: target, knownTitle: knownTitle)
        case .appleTerminal: return jumpAppleScript(target: target, kind: .appleTerminal)
        case .iterm2:        return jumpAppleScript(target: target, kind: .iterm2)
        case .ghostty:       return jumpGhostty(target: target)
        case .wezterm:       return jumpWezterm(target: target)
        case .kitty:         return jumpKitty(target: target)
        case .alacritty:     return activateApp(target, reason: .unsupported)
        case .antigravity:   return jumpAntigravityApp(session: session, target: target)
        case .unknown:
            // Also handle CLI inside Antigravity IDE's integrated terminal cleanly
            if let appName = target.appName?.lowercased(), appName.contains("antigravity") {
                return jumpAntigravityApp(session: session, target: target)
            }
            return activateApp(target, reason: target.multiplexed ? .ambiguous : .unsupported)
        }
    }

    private func isDesktopOrIDESession(session: SessionInfo, target: SessionTarget) -> Bool {
        let surface = target.surface ?? session.entrypoint ?? ""
        return surface == "antigravity" || surface == "antigravity-ide"
    }

    // MARK: - Antigravity Desktop & Antigravity IDE Activation

    private func jumpAntigravityApp(session: SessionInfo, target: SessionTarget) -> JumpOutcome {
        // 1. Running PID activation
        if activateAppPid(target) {
            return .focusedPane
        }

        let surface = target.surface ?? session.entrypoint ?? ""
        let preferIDE = surface == "antigravity-ide"
            || (target.appName?.lowercased().contains("ide") == true)

        // 2. Running application lookup by bundle ID or localized name
        let candidateBundleIds: [String] = [
            target.bundleId,
            preferIDE ? "com.google.antigravity.ide" : "com.google.antigravity",
            preferIDE ? "com.google.antigravity-ide" : nil,
        ].compactMap { $0 }

        var activatedByWorkspace = false
        DispatchQueue.main.sync {
            for bid in candidateBundleIds {
                if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first,
                   running.activate(options: [.activateIgnoringOtherApps]) {
                    activatedByWorkspace = true
                    return
                }
            }
            let targetNames = preferIDE
                ? ["Antigravity IDE", "Antigravity"]
                : ["Antigravity", "Antigravity IDE"]
            for want in targetNames {
                if let running = NSWorkspace.shared.runningApplications.first(where: {
                    $0.localizedName?.caseInsensitiveCompare(want) == .orderedSame
                }), running.activate(options: [.activateIgnoringOtherApps]) {
                    activatedByWorkspace = true
                    return
                }
            }
        }
        if activatedByWorkspace {
            return .focusedPane
        }

        // 3. Launch / bring forward app bundle via `open` (if cwd exists, open workspace in app, or plain app raise)
        let appPaths = preferIDE
            ? ["/Applications/Antigravity IDE.app", "/Applications/Antigravity.app"]
            : ["/Applications/Antigravity.app", "/Applications/Antigravity IDE.app"]

        for appPath in appPaths where FileManager.default.fileExists(atPath: appPath) {
            if let (s, _) = run("/usr/bin/open", ["-a", appPath]), s == 0 {
                return .focusedPane
            }
        }
        if let bid = target.bundleId, let (s, _) = run("/usr/bin/open", ["-b", bid]), s == 0 {
            return .focusedPane
        }
        if let name = target.appName, let (s, _) = run("/usr/bin/open", ["-a", name]), s == 0 {
            return .focusedPane
        }
        return .failed(.launchFailed)
    }

    // MARK: - Otty (zero TCC)

    private func jumpOtty(session: SessionInfo, target: SessionTarget, knownTitle: String?) -> JumpOutcome {
        guard let cli = ottyCliPath(target) else {
            return activateApp(target, reason: .unsupported)
        }
        guard let (_, listOut) = run(cli, ["pane", "list", "--json"]),
              let panes = SessionLogic.parseOttyPanes(listOut) else {
            return activateApp(target, reason: .ambiguous)
        }
        let aiTitle = (knownTitle?.isEmpty == false)
            ? knownTitle
            : AITitleReader.latestAITitle(sessionId: session.sessionId)
        switch SessionLogic.matchOttyPane(cwd: session.cwd, title: aiTitle, panes: panes) {
        case .exact(let paneId):
            _ = run(cli, ["pane", "focus", paneId, "--json"])
            _ = activateAppPid(target)
            return .focusedPane
        case .ambiguous, .none:
            return activateApp(target, reason: .ambiguous)
        }
    }

    private func ottyCliPath(_ target: SessionTarget) -> String? {
        var candidates: [String] = []
        if let id = target.bundleId,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            candidates.append(url.appendingPathComponent("Contents/MacOS/otty-cli").path)
        }
        candidates.append("/Applications/Otty.app/Contents/MacOS/otty-cli")
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Apple Terminal / iTerm2 (AppleScript, exact by TTY)

    private func jumpAppleScript(target: SessionTarget, kind: TerminalKind) -> JumpOutcome {
        guard let dev = SessionLogic.devTTY(target.tty) else {
            return activateApp(target, reason: .noTarget)
        }
        let script = kind == .iterm2
            ? SessionLogic.itermFocusScript(devTTY: dev)
            : SessionLogic.appleTerminalFocusScript(devTTY: dev)
        guard let res = ProcessRunner.runDetailed("/usr/bin/osascript", ["-e", script], timeout: 30.0) else {
            return activateApp(target, reason: .unsupported)
        }
        if res.timedOut {
            return activateApp(target, reason: .ambiguous)
        }
        let out = res.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if res.status == 0 {
            if out == "ok" { return .focusedPane }
            return activateApp(target, reason: .ambiguous)
        }
        return activateApp(target, reason: .permissionDenied)
    }

    // MARK: - Ghostty / WezTerm / Kitty

    private func jumpGhostty(target: SessionTarget) -> JumpOutcome {
        return activateApp(target, reason: .ambiguous)
    }

    private func jumpWezterm(target: SessionTarget) -> JumpOutcome {
        guard let dev = SessionLogic.devTTY(target.tty), let cli = which("wezterm") else {
            return activateApp(target, reason: target.tty == nil ? .noTarget : .unsupported)
        }
        guard let (_, listJSON) = run(cli, ["cli", "list", "--format", "json"]) else {
            return activateApp(target, reason: .ambiguous)
        }
        if let paneId = SessionLogic.matchWeztermPaneId(devTTY: dev, jsonString: listJSON) {
            _ = run(cli, ["cli", "activate-pane", "--pane-id", paneId])
            _ = activateAppPid(target)
            return .focusedPane
        }
        return activateApp(target, reason: .ambiguous)
    }

    private func jumpKitty(target: SessionTarget) -> JumpOutcome {
        return activateApp(target, reason: .ambiguous)
    }

    // MARK: - Universal Fallback: Raise Owning App

    private func activateApp(_ target: SessionTarget, reason: JumpReason) -> JumpOutcome {
        if activateAppPid(target) { return .appOnly(reason) }
        if let id = target.bundleId, let (s, _) = run("/usr/bin/open", ["-b", id]), s == 0 {
            return .appOnly(reason)
        }
        if let name = target.appName, let (s, _) = run("/usr/bin/open", ["-a", name]), s == 0 {
            return .appOnly(reason)
        }
        return .failed(.launchFailed)
    }

    private func activateAppPid(_ target: SessionTarget) -> Bool {
        guard let pid = target.appPid, pid > 0 else { return false }
        var ok = false
        DispatchQueue.main.sync {
            if let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
                ok = app.activate(options: [.activateIgnoringOtherApps])
            }
        }
        return ok
    }

    // MARK: - Process Helpers

    private func which(_ name: String) -> String? {
        let common = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        if let direct = common.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return direct
        }
        guard let (status, out) = run("/usr/bin/which", [name]), status == 0 else { return nil }
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    @discardableResult
    private func run(_ launchPath: String, _ args: [String],
                     timeout: TimeInterval = 5.0) -> (Int32, String)? {
        guard let r = ProcessRunner.run(launchPath, args, timeout: timeout) else { return nil }
        return (r.status, r.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
