import Cocoa

// ╔══════════════════════════════════════════════════════════════╗
// ║  AGYMonitor — macOS Menu Bar & Notch App                     ║
// ║  Monitors Google Antigravity usage, sessions, time & quota   ║
// ╚══════════════════════════════════════════════════════════════╝

// MARK: - Entry Point

// Single-instance guard for `open -n` (force-new-instance) scenarios.
// Normal `open` is handled by applicationShouldHandleReopen in AppDelegate.
let fallbackBundleID = "com.kuen54.AGYMonitor"
let myBundleID = Bundle.main.bundleIdentifier ?? fallbackBundleID
let running = NSRunningApplication.runningApplications(withBundleIdentifier: myBundleID)
let isAlreadyRunning = running.contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
if isAlreadyRunning {
    let center = DistributedNotificationCenter.default()
    center.post(name: NSNotification.Name("\(myBundleID).show"), object: nil)
    if myBundleID != fallbackBundleID {
        center.post(name: NSNotification.Name("\(fallbackBundleID).show"), object: nil)
    }
    // Small delay so the notification is delivered before we exit
    Thread.sleep(forTimeInterval: 0.3)
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
