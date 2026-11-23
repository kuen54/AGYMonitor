import Foundation
import Darwin

// MARK: - Short-lived process runner (app layer)
//
// Shared spawn-with-watchdog helper used by SessionMonitor, SessionJumper, and
// QuotaService: run a short-lived command off the main thread, escalate SIGTERM
// -> SIGKILL if it hangs so serial queues can never wedge, and discard stderr to
// /dev/null so an undrained pipe (>64 KB) can never deadlock.
// NOT part of AGYCore — this is impure process I/O.
enum ProcessRunner {
    static func run(
        _ launchPath: String,
        _ args: [String],
        timeout: TimeInterval = 5.0,
        environment: [String: String]? = nil
    ) -> (status: Int32, output: String)? {
        guard let result = runDetailed(launchPath, args, timeout: timeout, environment: environment) else {
            return nil
        }
        return (result.status, result.output)
    }

    static func runDetailed(
        _ launchPath: String,
        _ args: [String],
        timeout: TimeInterval = 5.0,
        environment: [String: String]? = nil
    ) -> (status: Int32, output: String, timedOut: Bool)? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        if let environment = environment {
            task.environment = environment
        }
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return nil
        }

        let pid = task.processIdentifier
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

        guard let out = String(data: data, encoding: .utf8) else { return nil }
        return (task.terminationStatus, out, didTimeout)
    }
}
