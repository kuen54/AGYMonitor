import Foundation

// MARK: - Short-lived process runner (app layer)
//
// Shared spawn-with-watchdog helper used by SessionMonitor, SessionJumper, and
// QuotaService: run a short-lived command off the main thread, terminate it if
// it hangs so the caller's serial queue can't wedge, and discard stderr to
// /dev/null so an undrained pipe (>64 KB) can never deadlock.
// NOT part of AGYCore — this is impure process I/O.
enum ProcessRunner {
    static func run(
        _ launchPath: String,
        _ args: [String],
        timeout: TimeInterval = 5.0,
        environment: [String: String]? = nil
    ) -> (status: Int32, output: String)? {
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
        let watchdog = DispatchWorkItem {
            if task.isRunning { task.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        watchdog.cancel()
        guard let out = String(data: data, encoding: .utf8) else { return nil }
        return (task.terminationStatus, out)
    }
}
