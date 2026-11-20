import Foundation
import Darwin

// MARK: - analyze_usage.py invocation
//
// Owns script/interpreter discovery and Process spawning (including the
// 120s SIGTERM -> +10s SIGKILL timeout escalation). Deliberately does NOT own
// queueing: UsageStore's serial scriptQueue + coalescing/generation logic remain
// the single concurrency authority.
struct UsageScriptClient {
    let scriptPath: String
    let pythonPath: String

    init() {
        if let bundled = Bundle.main.path(forResource: "analyze_usage", ofType: "py") {
            scriptPath = bundled
        } else {
            let fm = FileManager.default
            let cwdCandidate = URL(fileURLWithPath: fm.currentDirectoryPath)
                .appendingPathComponent("Resources/analyze_usage.py").path
            let execRelativeCandidate = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
                .deletingLastPathComponent()
                .appendingPathComponent("../Resources/analyze_usage.py")
                .standardized.path
            let devCandidate = (NSHomeDirectory() as NSString)
                .appendingPathComponent("Developer/AGYMonitor/Resources/analyze_usage.py")

            if fm.fileExists(atPath: cwdCandidate) {
                scriptPath = cwdCandidate
            } else if fm.fileExists(atPath: execRelativeCandidate) {
                scriptPath = execRelativeCandidate
            } else {
                scriptPath = devCandidate
            }
        }
        let candidates = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        pythonPath = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
    }

    func runScript(_ args: [String]) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptPath] + args
        process.environment = ProcessInfo.processInfo.environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let pid = process.processIdentifier
            let stateLock = NSLock()
            var finished = false
            var killItem: DispatchWorkItem?

            let timeoutItem = DispatchWorkItem {
                stateLock.lock()
                let done = finished
                stateLock.unlock()
                guard !done, pid > 0 else { return }
                kill(pid, SIGTERM)
                let escalate = DispatchWorkItem {
                    stateLock.lock()
                    let isDone = finished
                    stateLock.unlock()
                    if !isDone && pid > 0 { kill(pid, SIGKILL) }
                }
                stateLock.lock()
                if !finished {
                    killItem = escalate
                    stateLock.unlock()
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: escalate)
                } else {
                    stateLock.unlock()
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120, execute: timeoutItem)
            // Read pipe BEFORE waitUntilExit to avoid deadlock when output > 64KB
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            stateLock.lock()
            finished = true
            let pendingKill = killItem
            killItem = nil
            stateLock.unlock()

            timeoutItem.cancel()
            pendingKill?.cancel()
            guard process.terminationStatus == 0 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }
}
