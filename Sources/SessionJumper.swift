import Foundation
import AppKit
import Darwin

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
    /// Concurrent queue so rapid clicks genuinely supersede a blocked 30s `osascript`
    /// TCC prompt via `JumpRequestGate` without queueing behind the stalled request.
    private let queue = DispatchQueue(
        label: "com.kuen54.AGYMonitor.jump",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let gateLock = NSLock()
    private var requestGate = JumpRequestGate()
    private var activeOsascriptPid: pid_t = 0

    func jump(
        session: SessionInfo,
        target: SessionTarget,
        knownTitle: String? = nil,
        completion: ((JumpOutcome) -> Void)? = nil
    ) {
        gateLock.lock()
        let generation = requestGate.beginRequest()
        let stalePid = activeOsascriptPid
        activeOsascriptPid = 0
        gateLock.unlock()

        if stalePid > 0 {
            kill(stalePid, SIGTERM)
        }

        queue.async { [weak self] in
            guard let self = self else { return }
            guard self.isLatestRequest(generation) else { return }
            self.perform(
                session: session,
                target: target,
                knownTitle: knownTitle,
                generation: generation
            ) { [weak self] outcome in
                guard let self = self, self.isLatestRequest(generation) else { return }
                guard let completion = completion else { return }
                if Thread.isMainThread {
                    completion(outcome)
                } else {
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, self.isLatestRequest(generation) else { return }
                        completion(outcome)
                    }
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

    private func perform(
        session: SessionInfo,
        target: SessionTarget,
        knownTitle: String?,
        generation: Int,
        completion: @escaping (JumpOutcome) -> Void
    ) {
        guard isLatestRequest(generation) else { return }

        if isDesktopOrIDESession(session: session, target: target) {
            jumpAntigravityApp(
                session: session,
                target: target,
                generation: generation,
                completion: completion
            )
            return
        }

        switch target.terminal {
        case .otty:
            jumpOtty(
                session: session,
                target: target,
                knownTitle: knownTitle,
                generation: generation,
                completion: completion
            )
        case .appleTerminal:
            jumpAppleScript(target: target, kind: .appleTerminal, generation: generation, completion: completion)
        case .iterm2:
            jumpAppleScript(target: target, kind: .iterm2, generation: generation, completion: completion)
        case .ghostty:
            jumpGhostty(target: target, generation: generation, completion: completion)
        case .wezterm:
            jumpWezterm(target: target, generation: generation, completion: completion)
        case .kitty:
            jumpKitty(target: target, generation: generation, completion: completion)
        case .alacritty:
            activateApp(target, reason: .unsupported, generation: generation, completion: completion)
        case .antigravity:
            jumpAntigravityApp(
                session: session,
                target: target,
                generation: generation,
                completion: completion
            )
        case .unknown:
            // Also handle CLI inside Antigravity IDE's integrated terminal cleanly
            if let appName = target.appName?.lowercased(), appName.contains("antigravity") {
                jumpAntigravityApp(
                    session: session,
                    target: target,
                    generation: generation,
                    completion: completion
                )
                return
            }
            activateApp(
                target,
                reason: target.multiplexed ? .ambiguous : .unsupported,
                generation: generation,
                completion: completion
            )
        }
    }

    private func isDesktopOrIDESession(session: SessionInfo, target: SessionTarget) -> Bool {
        let surface = target.surface ?? session.entrypoint ?? ""
        return surface == "antigravity" || surface == "antigravity-ide"
    }

    // MARK: - Antigravity Desktop & Antigravity IDE Activation

    private func jumpAntigravityApp(
        session: SessionInfo,
        target: SessionTarget,
        generation: Int,
        completion: @escaping (JumpOutcome) -> Void
    ) {
        let surface = target.surface ?? session.entrypoint ?? ""
        let preferIDE = surface == "antigravity-ide"
            || (target.appName?.lowercased().contains("ide") == true)

        let candidateBundleIds: [String] = [
            target.bundleId,
            preferIDE ? "com.google.antigravity.ide" : "com.google.antigravity",
            preferIDE ? "com.google.antigravity-ide" : nil,
        ].compactMap { $0 }

        let targetNames = preferIDE
            ? ["Antigravity IDE", "Antigravity"]
            : ["Antigravity", "Antigravity IDE"]

        // 1 & 2. Activate running PID, bundle ID, or localized name asynchronously on main (never `main.sync`).
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isLatestRequest(generation) else { return }

            if let pid = target.appPid, pid > 0,
               let running = NSRunningApplication(processIdentifier: pid_t(pid)),
               self.activateRunningApp(running) {
                completion(.focusedPane)
                return
            }

            for bid in candidateBundleIds {
                if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first,
                   self.activateRunningApp(running) {
                    completion(.focusedPane)
                    return
                }
            }

            for want in targetNames {
                if let running = NSWorkspace.shared.runningApplications.first(where: {
                    $0.localizedName?.caseInsensitiveCompare(want) == .orderedSame
                }), self.activateRunningApp(running) {
                    completion(.focusedPane)
                    return
                }
            }

            // 3. Launch / bring forward app bundle via `/usr/bin/open` off-main
            self.queue.async { [weak self] in
                guard let self = self, self.isLatestRequest(generation) else { return }
                let appPaths = preferIDE
                    ? ["/Applications/Antigravity IDE.app", "/Applications/Antigravity.app"]
                    : ["/Applications/Antigravity.app", "/Applications/Antigravity IDE.app"]

                for appPath in appPaths where FileManager.default.fileExists(atPath: appPath) {
                    guard self.isLatestRequest(generation) else { return }
                    if let (s, _) = self.run("/usr/bin/open", ["-a", appPath]), s == 0 {
                        completion(.focusedPane)
                        return
                    }
                }
                if let bid = target.bundleId, self.isLatestRequest(generation),
                   let (s, _) = self.run("/usr/bin/open", ["-b", bid]), s == 0 {
                    completion(.focusedPane)
                    return
                }
                if let name = target.appName, self.isLatestRequest(generation),
                   let (s, _) = self.run("/usr/bin/open", ["-a", name]), s == 0 {
                    completion(.focusedPane)
                    return
                }
                completion(.failed(.launchFailed))
            }
        }
    }

    // MARK: - Otty (zero TCC)

    private func jumpOtty(
        session: SessionInfo,
        target: SessionTarget,
        knownTitle: String?,
        generation: Int,
        completion: @escaping (JumpOutcome) -> Void
    ) {
        guard let cli = ottyCliPath(target) else {
            activateApp(target, reason: .unsupported, generation: generation, completion: completion)
            return
        }
        guard isLatestRequest(generation),
              let (_, listOut) = run(cli, ["pane", "list", "--json"]),
              let panes = SessionLogic.parseOttyPanes(listOut) else {
            guard isLatestRequest(generation) else { return }
            activateApp(target, reason: .ambiguous, generation: generation, completion: completion)
            return
        }
        guard isLatestRequest(generation) else { return }
        let aiTitle = (knownTitle?.isEmpty == false)
            ? knownTitle
            : AITitleReader.latestAITitle(sessionId: session.sessionId)
        switch SessionLogic.matchOttyPane(cwd: session.cwd, title: aiTitle, panes: panes) {
        case .exact(let paneId):
            guard isLatestRequest(generation) else { return }
            _ = run(cli, ["pane", "focus", paneId, "--json"])
            activatePidAsync(target, generation: generation)
            completion(.focusedPane)
        case .ambiguous, .none:
            activateApp(target, reason: .ambiguous, generation: generation, completion: completion)
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

    private func jumpAppleScript(
        target: SessionTarget,
        kind: TerminalKind,
        generation: Int,
        completion: @escaping (JumpOutcome) -> Void
    ) {
        guard let dev = SessionLogic.devTTY(target.tty) else {
            activateApp(target, reason: .noTarget, generation: generation, completion: completion)
            return
        }
        let script = kind == .iterm2
            ? SessionLogic.itermFocusScript(devTTY: dev)
            : SessionLogic.appleTerminalFocusScript(devTTY: dev)
        guard let res = runCancellableOsascript(script, generation: generation, timeout: 30.0) else {
            guard isLatestRequest(generation) else { return }
            activateApp(target, reason: .unsupported, generation: generation, completion: completion)
            return
        }
        guard isLatestRequest(generation) else { return }
        if res.timedOut {
            activateApp(target, reason: .ambiguous, generation: generation, completion: completion)
            return
        }
        let out = res.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if res.status == 0 {
            if out == "ok" {
                completion(.focusedPane)
                return
            }
            activateApp(target, reason: .ambiguous, generation: generation, completion: completion)
            return
        }
        activateApp(target, reason: .permissionDenied, generation: generation, completion: completion)
    }

    /// Runs `/usr/bin/osascript -e <script>` while registering its PID under `gateLock`
    /// so a newer click immediately sends `SIGTERM` and supersedes a blocked TCC prompt.
    private func runCancellableOsascript(
        _ script: String,
        generation: Int,
        timeout: TimeInterval
    ) -> (status: Int32, output: String, timedOut: Bool)? {
        guard isLatestRequest(generation) else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return nil
        }

        let pid = task.processIdentifier
        gateLock.lock()
        let stillLatest = requestGate.isLatest(generation)
        if stillLatest {
            activeOsascriptPid = pid
        }
        gateLock.unlock()

        if !stillLatest {
            if pid > 0 { kill(pid, SIGTERM) }
            _ = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
            task.waitUntilExit()
            return nil
        }

        let stateLock = NSLock()
        var finished = false
        var timedOut = false
        var killWork: DispatchWorkItem?

        let watchdog = DispatchWorkItem {
            stateLock.lock()
            let alreadyDone = finished
            if !alreadyDone { timedOut = true }
            stateLock.unlock()
            guard !alreadyDone, pid > 0 else { return }

            kill(pid, SIGTERM)
            let escalator = DispatchWorkItem {
                stateLock.lock()
                let done = finished
                stateLock.unlock()
                if !done && pid > 0 {
                    kill(pid, SIGKILL)
                }
            }
            stateLock.lock()
            if !finished {
                killWork = escalator
                stateLock.unlock()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0, execute: escalator)
            } else {
                stateLock.unlock()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let data = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        task.waitUntilExit()

        stateLock.lock()
        finished = true
        let didTimeout = timedOut
        let pendingKill = killWork
        killWork = nil
        stateLock.unlock()

        watchdog.cancel()
        pendingKill?.cancel()

        gateLock.lock()
        if activeOsascriptPid == pid {
            activeOsascriptPid = 0
        }
        gateLock.unlock()

        guard let out = String(data: data, encoding: .utf8) else { return nil }
        return (task.terminationStatus, out, didTimeout)
    }

    // MARK: - Ghostty / WezTerm / Kitty

    private func jumpGhostty(
        target: SessionTarget,
        generation: Int,
        completion: @escaping (JumpOutcome) -> Void
    ) {
        activateApp(target, reason: .ambiguous, generation: generation, completion: completion)
    }

    private func jumpWezterm(
        target: SessionTarget,
        generation: Int,
        completion: @escaping (JumpOutcome) -> Void
    ) {
        guard let dev = SessionLogic.devTTY(target.tty), let cli = which("wezterm") else {
            activateApp(
                target,
                reason: target.tty == nil ? .noTarget : .unsupported,
                generation: generation,
                completion: completion
            )
            return
        }
        guard isLatestRequest(generation),
              let (_, listJSON) = run(cli, ["cli", "list", "--format", "json"]) else {
            guard isLatestRequest(generation) else { return }
            activateApp(target, reason: .ambiguous, generation: generation, completion: completion)
            return
        }
        guard isLatestRequest(generation) else { return }
        if let paneId = SessionLogic.matchWeztermPaneId(devTTY: dev, jsonString: listJSON) {
            _ = run(cli, ["cli", "activate-pane", "--pane-id", paneId])
            activatePidAsync(target, generation: generation)
            completion(.focusedPane)
            return
        }
        activateApp(target, reason: .ambiguous, generation: generation, completion: completion)
    }

    private func jumpKitty(
        target: SessionTarget,
        generation: Int,
        completion: @escaping (JumpOutcome) -> Void
    ) {
        activateApp(target, reason: .ambiguous, generation: generation, completion: completion)
    }

    // MARK: - Universal Fallback: Raise Owning App

    private func activateApp(
        _ target: SessionTarget,
        reason: JumpReason,
        generation: Int,
        completion: @escaping (JumpOutcome) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isLatestRequest(generation) else { return }
            if let pid = target.appPid, pid > 0,
               let app = NSRunningApplication(processIdentifier: pid_t(pid)),
               self.activateRunningApp(app) {
                completion(.appOnly(reason))
                return
            }
            self.queue.async { [weak self] in
                guard let self = self, self.isLatestRequest(generation) else { return }
                if let id = target.bundleId, let (s, _) = self.run("/usr/bin/open", ["-b", id]), s == 0 {
                    completion(.appOnly(reason))
                    return
                }
                if let name = target.appName, self.isLatestRequest(generation),
                   let (s, _) = self.run("/usr/bin/open", ["-a", name]), s == 0 {
                    completion(.appOnly(reason))
                    return
                }
                completion(.failed(.launchFailed))
            }
        }
    }

    private func activatePidAsync(_ target: SessionTarget, generation: Int) {
        guard let pid = target.appPid, pid > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isLatestRequest(generation) else { return }
            if let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
                self.activateRunningApp(app)
            }
        }
    }

    @discardableResult
    private func activateRunningApp(_ app: NSRunningApplication) -> Bool {
        if #available(macOS 14.0, *) {
            return app.activate()
        } else {
            return app.activate(options: .activateIgnoringOtherApps)
        }
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
