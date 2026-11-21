import AppKit
import Foundation
import UserNotifications

// MARK: - Update Service (Thin App-Layer Shell for UpdateCheckerMachine)

/// Checks GitHub Releases for newer AGYMonitor builds, drives the in-app update
/// status strip, and posts a one-time macOS system notification the first time a
/// new version is discovered.
final class UpdateService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    private enum DefaultsKey {
        static let autoCheckEnabled = "updateAutoCheckEnabled"
        static let lastCheckAt = "updateLastCheckAt"
        static let latestReleaseTag = "updateLatestReleaseTag"
        static let skippedVersion = "updateSkippedVersion"
        static let notifiedVersion = "updateNotifiedVersion"
    }

    private enum NotificationMeta {
        static let identifierPrefix = "com.kuen54.AGYMonitor.update."
        static let releaseURLKey = "releaseURL"
    }

    @Published private(set) var state: UpdateCheckerState

    /// Resolves the active UI language when formatting macOS system notifications.
    var languageProvider: () -> AppLanguage = { .en }

    private let defaults: UserDefaults
    private var autoCheckTimer: Timer?
    private var transientClearTimer: Timer?
    private var activeTask: URLSessionDataTask?
    private var activeFallbackTask: URLSessionDataTask?
    private var notificationDelegateInstalled = false

    static var currentAppVersionString: String {
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return v
        }
        return appVersion
    }

    private var canUseUserNotifications: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
            && Bundle.main.bundleIdentifier != nil
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let current = SemanticVersion.parse(Self.currentAppVersionString)
            ?? SemanticVersion(major: 1, minor: 0, patch: 0)
        let autoEnabled = defaults.object(forKey: DefaultsKey.autoCheckEnabled) == nil
            ? true
            : defaults.bool(forKey: DefaultsKey.autoCheckEnabled)
        let lastCheckAt = defaults.object(forKey: DefaultsKey.lastCheckAt) as? Date
        let skipped = defaults.string(forKey: DefaultsKey.skippedVersion)
        let notified = defaults.string(forKey: DefaultsKey.notifiedVersion)
        let cachedTag = defaults.string(forKey: DefaultsKey.latestReleaseTag)

        self.state = UpdateCheckerState(
            currentVersion: current,
            autoCheckEnabled: autoEnabled,
            lastCheckAt: lastCheckAt,
            skippedVersion: skipped,
            notifiedVersion: notified,
            cachedLatestTag: cachedTag
        )
        super.init()
    }

    deinit {
        autoCheckTimer?.invalidate()
        transientClearTimer?.invalidate()
        activeTask?.cancel()
        activeFallbackTask?.cancel()
    }

    // MARK: - Public Actions

    func start() {
        installNotificationDelegateIfPossible()
        dispatch(.start(now: Date()))
    }

    func stop() {
        dispatch(.stop)
        activeTask?.cancel()
        activeTask = nil
        activeFallbackTask?.cancel()
        activeFallbackTask = nil
    }

    func handleWake() {
        dispatch(.wake(now: Date()))
    }

    func checkForUpdatesManually() {
        installNotificationDelegateIfPossible()
        dispatch(.manualCheckRequested(now: Date()))
    }

    func dismissAvailableUpdate() {
        dispatch(.dismissAvailableUpdate)
    }

    func setAutoCheckEnabled(_ enabled: Bool) {
        dispatch(.setAutoCheckEnabled(enabled, now: Date()))
    }

    func openReleasePage() {
        guard let info = state.availableUpdate,
              UpdateReleaseParser.isAllowedReleaseURL(info.releasePageURLString),
              let url = URL(string: info.releasePageURLString) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Used by `docs/render_mockups.swift` to render static visual previews without I/O.
    func setPreviewState(_ preview: UpdateCheckerState) {
        state = preview
    }

    // MARK: - Reducer Dispatch

    private func dispatch(_ event: UpdateCheckerEvent) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.dispatch(event)
            }
            return
        }

        var next = state
        let effects = UpdateCheckerMachine.reduce(&next, event: event)
        if next != state {
            state = next
        }

        for effect in effects {
            execute(effect)
        }
    }

    private func execute(_ effect: UpdateCheckerEffect) {
        switch effect {
        case .scheduleAutoCheck(let delay):
            autoCheckTimer?.invalidate()
            let clamped = max(1.0, delay)
            let timer = Timer(timeInterval: clamped, repeats: false) { [weak self] _ in
                self?.dispatch(.periodicTick(now: Date()))
            }
            timer.tolerance = min(60.0, clamped * 0.1)
            RunLoop.main.add(timer, forMode: .common)
            autoCheckTimer = timer

        case .cancelAutoCheck:
            autoCheckTimer?.invalidate()
            autoCheckTimer = nil

        case .performFetch(let generation, _):
            performReleaseFetch(generation: generation)

        case .persistLastCheckAt(let date):
            defaults.set(date, forKey: DefaultsKey.lastCheckAt)

        case .persistLatestReleaseTag(let tag):
            if let tag = tag {
                defaults.set(tag, forKey: DefaultsKey.latestReleaseTag)
            } else {
                defaults.removeObject(forKey: DefaultsKey.latestReleaseTag)
            }

        case .persistSkippedVersion(let version):
            if let version = version {
                defaults.set(version, forKey: DefaultsKey.skippedVersion)
            } else {
                defaults.removeObject(forKey: DefaultsKey.skippedVersion)
            }

        case .persistNotifiedVersion(let version):
            defaults.set(version, forKey: DefaultsKey.notifiedVersion)

        case .persistAutoCheckEnabled(let enabled):
            defaults.set(enabled, forKey: DefaultsKey.autoCheckEnabled)

        case .postSystemNotification(let release):
            postSystemNotification(for: release)

        case .scheduleTransientFeedbackClear(let delay):
            transientClearTimer?.invalidate()
            let timer = Timer(timeInterval: max(0.5, delay), repeats: false) { [weak self] _ in
                self?.dispatch(.clearTransientFeedback)
            }
            RunLoop.main.add(timer, forMode: .common)
            transientClearTimer = timer

        case .cancelTransientFeedbackClear:
            transientClearTimer?.invalidate()
            transientClearTimer = nil
        }
    }

    // MARK: - Network Fetch (Zero-Quota GitHub Redirect + API Fallback)

    private func performReleaseFetch(generation: UInt64) {
        activeTask?.cancel()
        activeTask = nil
        activeFallbackTask?.cancel()
        activeFallbackTask = nil

        guard let url = URL(string: UpdateReleaseParser.latestReleaseRedirectURLString()) else {
            dispatch(.checkCompleted(generation: generation, result: .failure("Invalid release URL"), now: Date()))
            return
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData

        let redirectDelegate = RedirectStoppingSessionDelegate()
        let session = URLSession(configuration: config, delegate: redirectDelegate, delegateQueue: nil)

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue("AGYMonitor/\(state.currentVersion.canonical)", forHTTPHeaderField: "User-Agent")

        let task = session.dataTask(with: request) { [weak self] _, response, error in
            defer { session.finishTasksAndInvalidate() }
            guard let self = self else { return }

            if let error = error as NSError?, error.code == NSURLErrorCancelled {
                return
            }

            if let http = response as? HTTPURLResponse {
                // 1. Direct 302 Location header from github.com/.../releases/latest
                if let location = http.value(forHTTPHeaderField: "Location"),
                   let info = UpdateReleaseParser.parseRedirectURL(location) {
                    self.dispatch(.checkCompleted(generation: generation, result: .release(info), now: Date()))
                    return
                }
                // 2. Proxy transparently followed redirect to /releases/tag/vX.Y.Z
                if let finalURL = http.url?.absoluteString,
                   let info = UpdateReleaseParser.parseRedirectURL(finalURL) {
                    self.dispatch(.checkCompleted(generation: generation, result: .release(info), now: Date()))
                    return
                }
                // 3. Redirected to /releases (repo has no published releases yet)
                if let location = http.value(forHTTPHeaderField: "Location"),
                   location.lowercased().hasSuffix("/releases") {
                    self.dispatch(.checkCompleted(generation: generation, result: .noReleaseFound, now: Date()))
                    return
                }
            }

            // Fallback to GitHub REST API if HEAD redirect didn't yield a tag
            DispatchQueue.main.async { [weak self] in
                self?.performAPIFallbackFetch(generation: generation, primaryError: error?.localizedDescription)
            }
        }
        activeTask = task
        task.resume()
    }

    private func performAPIFallbackFetch(generation: UInt64, primaryError: String?) {
        guard generation == state.checkGeneration else { return }
        guard let url = URL(string: UpdateReleaseParser.latestReleaseAPIURLString()) else {
            dispatch(.checkCompleted(
                generation: generation,
                result: .failure(primaryError ?? "Invalid API URL"),
                now: Date()
            ))
            return
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AGYMonitor/\(state.currentVersion.canonical)", forHTTPHeaderField: "User-Agent")

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            defer { session.finishTasksAndInvalidate() }
            guard let self = self else { return }

            if let error = error as NSError?, error.code == NSURLErrorCancelled {
                return
            }

            guard let http = response as? HTTPURLResponse else {
                self.dispatch(.checkCompleted(
                    generation: generation,
                    result: .failure(error?.localizedDescription ?? primaryError ?? "Network error"),
                    now: Date()
                ))
                return
            }

            if http.statusCode == 404 {
                self.dispatch(.checkCompleted(generation: generation, result: .noReleaseFound, now: Date()))
                return
            }

            guard (200...299).contains(http.statusCode), let data = data else {
                self.dispatch(.checkCompleted(
                    generation: generation,
                    result: .failure("HTTP \(http.statusCode)"),
                    now: Date()
                ))
                return
            }

            if let info = UpdateReleaseParser.parseGitHubReleaseJSON(data) {
                self.dispatch(.checkCompleted(generation: generation, result: .release(info), now: Date()))
            } else {
                self.dispatch(.checkCompleted(generation: generation, result: .noReleaseFound, now: Date()))
            }
        }
        activeFallbackTask = task
        task.resume()
    }

    // MARK: - macOS System Notification (One-Time per Version)

    private func installNotificationDelegateIfPossible() {
        guard canUseUserNotifications, !notificationDelegateInstalled else { return }
        UNUserNotificationCenter.current().delegate = self
        notificationDelegateInstalled = true
    }

    private func postSystemNotification(for release: ReleaseInfo) {
        guard canUseUserNotifications else { return }
        installNotificationDelegateIfPossible()

        let center = UNUserNotificationCenter.current()
        let loc = Localizer(language: languageProvider())
        let title = String(format: loc("updateNotifTitleFmt"), release.version.displayTag)
        let body = release.summary ?? loc("updateNotifBody")
        let identifier = "\(NotificationMeta.identifierPrefix)\(release.version.canonical)"
        let urlString = release.releasePageURLString

        func enqueue() {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = [NotificationMeta.releaseURLKey: urlString]

            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            center.add(request) { error in
                if let error = error {
                    NSLog("AGYMonitor: failed to post update notification: %@", error.localizedDescription)
                }
            }
        }

        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                enqueue()
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted {
                        enqueue()
                    }
                }
            default:
                break
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let urlString = response.notification.request.content.userInfo[NotificationMeta.releaseURLKey] as? String,
              UpdateReleaseParser.isAllowedReleaseURL(urlString),
              let url = URL(string: urlString) else {
            return
        }
        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Captures GitHub's 302 redirect on `HEAD /releases/latest` without following to the HTML tag page.
private final class RedirectStoppingSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
