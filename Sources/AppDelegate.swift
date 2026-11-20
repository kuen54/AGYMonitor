import Cocoa
import SwiftUI
import Combine
import CoreServices

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var store = UsageStore()
    private var refreshTimer: Timer?
    private var cancellable: AnyCancellable?
    // Brain FSEvents watcher + 30-min periodic timer + sleep/wake + 120s debounce floor,
    // governed by pure `BrainWatcherLifecycleMachine` (Core_MonitorState.swift).
    private var brainWatcher = BrainWatcherLifecycleState()
    private var fsEventStream: FSEventStreamRef?
    private var fsRefreshDebounce: DispatchWorkItem?
    private var wakeRefreshWork: DispatchWorkItem?
    // Menu-bar content is a SwiftUI hosting view inside the status button (so the
    // Antigravity mark can levitate/pulse while a session is busy and carry the attention dot —
    // the same behavior as the notch and popover header). `menuBarAnchor` coordinates
    // value/width freezing while the popover is open and flushing on close.
    private let menuBarModel = MenuBarModel(text: "…")
    private var menuBarAnchor = MenuBarAnchorState(initialText: "…", initialWidth: 40, isMenuBarVisible: true)

    // App presentation state machine: single source of truth for display surface
    // (menu bar vs notch), popover/notch visibility, statusItem visibility, and hotkey.
    private var presentation = AppPresentationState()
    private var notchController: NotchController?
    private var displayModeCancellable: AnyCancellable?
    private let hotKeyManager = GlobalHotKeyManager()
    private var hotkeyCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize presentation state synchronously from persisted preferences so zero
        // launch-window surface misrouting can occur before Combine sinks fire.
        let initialSurface: AppDisplaySurface = (store.displayMode == .notch) ? .notch : .menubar
        presentation = AppPresentationState(
            surface: initialSurface,
            hotkeyEnabled: store.globalHotkeyEnabled
        )
        menuBarModel.isVisible = presentation.isMenuBarLogoActive

        // Status bar item. Length is managed manually (updateMenuBarWidth) to track the
        // SwiftUI content's measured width — variableLength can't size to a hosted view.
        statusItem = NSStatusBar.system.statusItem(withLength: CGFloat(menuBarAnchor.appliedWidth))
        statusItem.autosaveName = AGYLocator.appName
        statusItem.isVisible = presentation.isStatusItemVisible
        menuBarAnchor.setMenuBarVisible(presentation.isStatusItemVisible)
        store.onRefreshTriggered = { [weak self] date in
            self?.dispatchBrainWatcher(.refreshTriggered(at: date))
        }
        if let button = statusItem.button {
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.action = #selector(handleStatusItemClick)
            button.target = self
            // Host [Antigravity mark + value] in SwiftUI so the mark can animate while a
            // session is busy and carry the attention dot (same view as notch/popover).
            // The hosting view passes mouse events through to the button so a click
            // still toggles the popover; its measured width drives status item length.
            let content = MenuBarContentView(
                sessionStore: store.sessionStore,
                model: menuBarModel,
                onWidth: { [weak self] w in self?.updateMenuBarWidth(w) })
            let hosting = PassthroughStatusHostingView(rootView: content)
            hosting.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: button.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
        }

        // Popover with SwiftUI content
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let hostingController = NSHostingController(
            rootView: PopoverView(
                store: store,
                onQuit: { NSApplication.shared.terminate(nil) },
                onClose: { [weak self] in self?.popover.performClose(nil) }
            )
        )
        hostingController.sizingOptions = .preferredContentSize
        popover.contentViewController = hostingController

        // Observe current month data + tab changes to update menu bar title.
        // Always shows current month regardless of which month is being viewed.
        // CombineLatest4 is Combine's max arity — extra signals are chained below.
        let sessionMenuSignal = store.sessionStore.$sessions
            .map { sessions -> String in
                "\(sessions.count)|\(sessions.contains { $0.status == .busy })|\(sessions.contains { $0.status == .waiting })"
            }
            .removeDuplicates()
        cancellable = Publishers.CombineLatest4(
            store.$currentMonthData, store.$selectedTab, store.$language, store.$subscriptionQuota)
            .combineLatest(store.$today, store.$menuBarMetric, store.$timeTodaySeconds)
            .combineLatest(sessionMenuSignal)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                guard let self = self, self.store.canDisplayMenuBarValue else { return }
                let value = self.store.menuBarValue
                self.menuBarAnchor.updateValue(value)
                if self.menuBarModel.text != self.menuBarAnchor.displayedText {
                    self.menuBarModel.text = self.menuBarAnchor.displayedText
                }
            }

        // Load cached data instantly, then refresh in background
        store.loadCacheForCurrentMonth()
        store.refresh()

        // Live session monitor (FSEvents + poll over Antigravity presence & metadata).
        // Runs in both menu-bar and notch modes; the poll bumps to active while the
        // popover is on screen (popoverDidShow/Close).
        store.startSessionMonitoring()

        // Brain FSEvents watcher + 30-min periodic fallback + sleep/wake refresh
        dispatchBrainWatcher(.start(candidatePaths: candidateBrainWatchPaths(), now: Date()))

        // Refresh on system wake
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(onWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )

        // Listen for "show popover" from a second instance launched via `open -n`
        // (normal `open` goes through applicationShouldHandleReopen instead)
        let fallbackBundleID = AGYLocator.bundleIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? fallbackBundleID
        let distCenter = DistributedNotificationCenter.default()
        distCenter.addObserver(
            self, selector: #selector(onShowRequest),
            name: NSNotification.Name("\(bundleID).show"),
            object: nil
        )
        if bundleID != fallbackBundleID {
            distCenter.addObserver(
                self, selector: #selector(onShowRequest),
                name: NSNotification.Name("\(fallbackBundleID).show"),
                object: nil
            )
        }

        // Display-mode lifecycle: AppPresentationMachine is the SINGLE authority for
        // statusItem visibility, notch controller lifecycle, panel visibility, and hotkey.
        displayModeCancellable = store.$displayMode
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in
                let surface: AppDisplaySurface = (mode == .notch) ? .notch : .menubar
                self?.dispatchPresentation(.displaySurfaceChanged(surface))
            }

        hotkeyCancellable = store.$globalHotkeyEnabled
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.dispatchPresentation(.hotkeyPreferenceChanged(enabled))
            }
    }

    private func dispatchPresentation(_ event: AppPresentationEvent) {
        let effects = AppPresentationMachine.reduce(&presentation, event: event)
        for effect in effects {
            switch effect {
            case .startNotchController:
                if notchController == nil {
                    let controller = NotchController(
                        store: store,
                        onQuit: { NSApplication.shared.terminate(nil) },
                        onOpenStateChanged: { [weak self] open in
                            self?.dispatchPresentation(.notchOpenChanged(open))
                        }
                    )
                    notchController = controller
                    controller.start()
                }
            case .stopNotchController:
                notchController?.stop()
                notchController = nil
            case .setStatusItemVisible(let visible):
                menuBarAnchor.setMenuBarVisible(visible)
                if visible {
                    menuBarModel.text = menuBarAnchor.displayedText
                    statusItem.length = CGFloat(menuBarAnchor.appliedWidth)
                }
                statusItem.isVisible = visible
            case .setMenuBarLogoActive(let active):
                if menuBarModel.isVisible != active {
                    menuBarModel.isVisible = active
                }
            case .setPopoverAnimates(let animates):
                popover.animates = animates
            case .openPopover:
                if let button = statusItem.button, !popover.isShown {
                    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                    popover.contentViewController?.view.window?.makeKey()
                    dispatchBrainWatcher(.reconcileWatchPaths(candidatePaths: candidateBrainWatchPaths(), now: Date()))
                    store.refresh()
                }
            case .closePopover:
                if popover.isShown { popover.performClose(nil) }
            case .showStatusContextMenu:
                if let button = statusItem.button {
                    showStatusContextMenu(anchorButton: button)
                }
            case .revealNotch:
                notchController?.reveal()
            case .toggleNotch:
                notchController?.toggle()
            case .syncPanelVisibility(let visible):
                if !visible {
                    MainActor.assumeIsolated {
                        PointingCursorCoordinator.shared.releaseAll()
                    }
                } else {
                    dispatchBrainWatcher(.reconcileWatchPaths(candidatePaths: candidateBrainWatchPaths(), now: Date()))
                }
                store.setSessionMonitorActive(visible)
            case .registerHotkey:
                let ok = hotKeyManager.register { [weak self] in
                    self?.dispatchPresentation(.globalHotkeyTriggered)
                }
                if !ok {
                    dispatchPresentation(.hotkeyRegistrationFailed)
                }
            case .unregisterHotkey:
                hotKeyManager.unregister()
            }
        }
    }

    /// The SwiftUI menu-bar content measured a new intrinsic width — size the status
    /// item to it. Frozen while the popover is open (a resizing anchor drifts the
    /// popover left); popoverDidClose restores appliedWidth.
    private func updateMenuBarWidth(_ w: CGFloat) {
        menuBarAnchor.updateMeasuredWidth(Double(w))
        guard presentation.isStatusItemVisible, !menuBarAnchor.isPopoverShown, !popover.isShown else { return }
        statusItem.length = CGFloat(menuBarAnchor.appliedWidth)
    }

    // Called when user opens the app again (double-click, Spotlight, Launchpad, etc.)
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        dispatchPresentation(.reopenRequested)
        return false
    }

    @objc private func onShowRequest(_ note: Notification) {
        // DistributedNotification may arrive on a non-main thread
        DispatchQueue.main.async { [weak self] in
            self?.dispatchPresentation(.reopenRequested)
        }
    }

    // NSPopoverDelegate: the title may have changed (data refresh or tab switch) while
    // the popover was open and we deferred it to keep the anchor stable. Apply it now.
    func popoverDidClose(_ notification: Notification) {
        menuBarAnchor.popoverClosed()
        menuBarModel.text = menuBarAnchor.displayedText
        if presentation.isStatusItemVisible {
            statusItem.length = CGFloat(menuBarAnchor.appliedWidth)
        }
        dispatchPresentation(.popoverClosed)
    }

    // Animate the open, but stop animating once shown so per-tab content-height
    // changes resize the popover instantly instead of jittering the rows above.
    func popoverDidShow(_ notification: Notification) {
        menuBarAnchor.popoverOpened()
        dispatchPresentation(.popoverShown)
    }

    // MARK: - Brain Watcher & Refresh Scheduler (backed by BrainWatcherLifecycleMachine)

    private func candidateBrainWatchPaths() -> [String] {
        let home = NSHomeDirectory()
        let geminiRoot = AGYLocator.geminiRoot(home: home)
        let candidateBrains = AGYLocator.brainDirs(home: home)

        let fm = FileManager.default
        var watchPaths: [String] = []
        for brainPath in candidateBrains {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: brainPath, isDirectory: &isDir), isDir.boolValue {
                watchPaths.append(brainPath)
            } else {
                // If an optional surface directory exists without a `brain/` subfolder yet
                // (e.g. `~/.gemini/antigravity-ide` before its first agent session), watch
                // the surface directory so we catch `brain/` creation without creating
                // empty directories on disk.
                let surfaceDir = (brainPath as NSString).deletingLastPathComponent
                if fm.fileExists(atPath: surfaceDir, isDirectory: &isDir), isDir.boolValue {
                    watchPaths.append(surfaceDir)
                }
            }
        }
        if watchPaths.isEmpty {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: geminiRoot, isDirectory: &isDir), isDir.boolValue {
                watchPaths.append(geminiRoot)
            }
        }
        return Array(Set(watchPaths)).sorted()
    }

    private func dispatchBrainWatcher(_ event: BrainWatcherLifecycleEvent) {
        let effects = BrainWatcherLifecycleMachine.reduce(&brainWatcher, event: event)
        for effect in effects {
            switch effect {
            case .startPeriodicTimer:
                refreshTimer?.invalidate()
                refreshTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    self.dispatchBrainWatcher(.periodicTimerFired(
                        candidatePaths: self.candidateBrainWatchPaths(),
                        now: Date()
                    ))
                }
            case .stopPeriodicTimer:
                refreshTimer?.invalidate()
                refreshTimer = nil
            case .startFSWatcher(let paths):
                startBrainWatcher(paths: paths)
            case .stopFSWatcher:
                stopBrainWatcher()
            case .scheduleDebounce(let generation, let delay):
                fsRefreshDebounce?.cancel()
                let item = DispatchWorkItem { [weak self] in
                    self?.dispatchBrainWatcher(.debounceFired(generation: generation))
                }
                fsRefreshDebounce = item
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            case .cancelDebounce:
                fsRefreshDebounce?.cancel()
                fsRefreshDebounce = nil
            case .scheduleWakeRefresh(let generation, let delay):
                wakeRefreshWork?.cancel()
                let item = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    self.dispatchBrainWatcher(.wakeTimerFired(
                        generation: generation,
                        candidatePaths: self.candidateBrainWatchPaths(),
                        now: Date()
                    ))
                }
                wakeRefreshWork = item
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            case .cancelWakeRefresh:
                wakeRefreshWork?.cancel()
                wakeRefreshWork = nil
            case .triggerRefresh:
                store.refresh()
            }
        }
    }

    private func stopBrainWatcher() {
        if let stream = fsEventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            fsEventStream = nil
        }
    }

    private func startBrainWatcher(paths watchPaths: [String]) {
        stopBrainWatcher()
        guard !watchPaths.isEmpty else {
            dispatchBrainWatcher(.fsWatcherResult(watchedPaths: [], at: Date()))
            return
        }

        var context = FSEventStreamContext(
            version: 0,
            // passUnretained is safe: AppDelegate lives for the whole app
            // lifetime, and applicationWillTerminate stops + invalidates the
            // stream before the process goes away.
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(info).takeUnretainedValue()
            delegate.dispatchBrainWatcher(.fsEventReceived(now: Date()))
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            watchPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            5.0,  // seconds of kernel-side coalescing
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)
        ) else {
            dispatchBrainWatcher(.fsWatcherResult(watchedPaths: [], at: Date()))
            return
        }
        fsEventStream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        if FSEventStreamStart(stream) {
            dispatchBrainWatcher(.fsWatcherResult(watchedPaths: watchPaths, at: Date()))
        } else {
            NSLog("AGYMonitor: FSEventStreamStart failed; falling back to timer-only refresh")
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            fsEventStream = nil
            dispatchBrainWatcher(.fsWatcherResult(watchedPaths: [], at: Date()))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        cancellable?.cancel(); cancellable = nil
        displayModeCancellable?.cancel(); displayModeCancellable = nil
        hotkeyCancellable?.cancel(); hotkeyCancellable = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        dispatchPresentation(.appWillTerminate)
        dispatchBrainWatcher(.terminate)
        store.stopSessionMonitoring()
    }

    @objc private func onWake(_ note: Notification) {
        dispatchBrainWatcher(.wakeReceived)
    }

    @objc private func handleStatusItemClick() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        dispatchPresentation(isRightClick ? .statusItemRightClicked : .statusItemLeftClicked)
    }

    private func showStatusContextMenu(anchorButton button: NSStatusBarButton) {
        let loc = Localizer(language: store.language)
        let menu = NSMenu()

        // 1. Direct jump items for waiting sessions
        let waitingSessions = store.sessionStore.sessions.filter { $0.status == .waiting }
        if !waitingSessions.isEmpty {
            for s in waitingSessions {
                let ws = store.sessionStore.labels[s.cwd] ?? SessionLogic.basename(s.cwd)
                let title = store.sessionStore.titles[s.sessionId] ?? ws
                let label = String(format: loc("jumpWaitingPrefix"), title)
                let item = NSMenuItem(title: "▲ \(label)", action: #selector(contextJumpWaiting(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = s.sessionId
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        // 2. Display location
        let modeHeader = NSMenuItem(title: loc("displayModeHeader"), action: nil, keyEquivalent: "")
        modeHeader.isEnabled = false
        menu.addItem(modeHeader)
        for mode in DisplayMode.allCases {
            let item = NSMenuItem(title: mode.label(loc), action: #selector(contextPickDisplayMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = store.displayMode == mode ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        // 3. Theme preset submenu
        let themeSubItem = NSMenuItem(title: loc("themeHeader"), action: nil, keyEquivalent: "")
        let themeMenu = NSMenu()
        for preset in TelemetryThemePreset.allCases {
            let item = NSMenuItem(title: preset.label(loc), action: #selector(contextPickThemePreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.rawValue
            item.state = store.themePreset == preset ? .on : .off
            themeMenu.addItem(item)
        }
        themeSubItem.submenu = themeMenu
        menu.addItem(themeSubItem)

        // 3.5. Visual style submenu (Instrument vs Classic)
        let visualSubItem = NSMenuItem(title: loc("visualModeHeader"), action: nil, keyEquivalent: "")
        let visualMenu = NSMenu()
        for vMode in TelemetryVisualMode.allCases {
            let item = NSMenuItem(title: vMode.label(loc), action: #selector(contextPickVisualMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = vMode.rawValue
            item.state = store.visualMode == vMode ? .on : .off
            visualMenu.addItem(item)
        }
        visualSubItem.submenu = visualMenu
        menu.addItem(visualSubItem)

        // 4. Status bar readout submenu
        let metricSubItem = NSMenuItem(title: loc("metricHeader"), action: nil, keyEquivalent: "")
        let metricMenu = NSMenu()
        for metric in MenuBarMetricPreference.allCases {
            let item = NSMenuItem(title: metric.label(loc), action: #selector(contextPickMetric(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = metric.rawValue
            item.state = store.menuBarMetric == metric ? .on : .off
            metricMenu.addItem(item)
        }
        metricSubItem.submenu = metricMenu
        menu.addItem(metricSubItem)
        menu.addItem(.separator())

        // 5. Hotkey, Refresh & Quit
        let hkItem = NSMenuItem(title: loc("hotkeyToggle"), action: #selector(contextToggleHotkey), keyEquivalent: "")
        hkItem.target = self
        hkItem.state = store.globalHotkeyEnabled ? .on : .off
        menu.addItem(hkItem)

        let refreshItem = NSMenuItem(title: loc("refresh"), action: #selector(contextRefresh), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let quitItem = NSMenuItem(title: loc("quit"), action: #selector(contextQuit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func contextJumpWaiting(_ sender: NSMenuItem) {
        guard let sid = sender.representedObject as? String,
              let s = store.sessionStore.sessions.first(where: { $0.sessionId == sid }) else { return }
        store.sessionStore.jump(s)
    }

    @objc private func contextPickDisplayMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = DisplayMode(rawValue: raw) else { return }
        store.setDisplayMode(mode)
    }

    @objc private func contextPickThemePreset(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let preset = TelemetryThemePreset(rawValue: raw) else { return }
        store.setThemePreset(preset)
    }

    @objc private func contextPickVisualMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let vMode = TelemetryVisualMode(rawValue: raw) else { return }
        store.setVisualMode(vMode)
    }

    @objc private func contextPickMetric(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let metric = MenuBarMetricPreference(rawValue: raw) else { return }
        store.setMenuBarMetric(metric)
    }

    @objc private func contextToggleHotkey() {
        store.setGlobalHotkeyEnabled(!store.globalHotkeyEnabled)
    }

    @objc private func contextRefresh() {
        store.refresh(force: true)
    }

    @objc private func contextQuit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Menu-bar status-item content (SwiftUI)

/// Holds the current menu-bar value string and visibility state. AppDelegate is the sole
/// writer (it defers updates while the popover is open); when hidden in Notch mode,
/// `isVisible = false` stops the menu-bar logo's TimelineView at 0 Hz.
final class MenuBarModel: ObservableObject {
    @Published var text: String
    @Published var isVisible: Bool
    init(text: String, isVisible: Bool = true) {
        self.text = text
        self.isVisible = isVisible
    }
}

/// Reports the intrinsic width of the menu-bar content up to AppDelegate so it can
/// size the (manually-lengthed) status item.
private struct MenuBarWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let n = nextValue()
        if n > 0 { value = n }
    }
}

/// The status-item content: the session-aware Antigravity mark (levitates + pulses while busy,
/// carries the amber/green attention dot) + the current value. Resolves a concrete value Color
/// from `@Environment(\.colorScheme)` so animation ticks never invoke dynamic NSColor/NSAppearance lookup.
struct MenuBarContentView: View {
    @ObservedObject var sessionStore: SessionStore
    @ObservedObject var model: MenuBarModel
    var onWidth: (CGFloat) -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var brandColor: Color {
        colorScheme == .dark
            ? Color(red: 0x4F / 255.0, green: 0x7C / 255.0, blue: 1.0)
            : Color(red: 0x26 / 255.0, green: 0x48 / 255.0, blue: 1.0)
    }

    var body: some View {
        HStack(spacing: 5) {
            SessionAwareLogo(sessionStore: sessionStore,
                             size: 15, color: brandColor, dotSize: 5,
                             isActive: model.isVisible)
            Text(model.text)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(sessionStore.anyWaiting ? .agyStatusWaiting : .primary)
                .fixedSize()
        }
        .padding(.horizontal, 6)
        .fixedSize()
        // Measure the intrinsic (fixedSize) content — NOT the button fill — so
        // resizing the status item to this width can't feed back into the measurement.
        .background(GeometryReader { geo in
            Color.clear.preference(key: MenuBarWidthKey.self, value: geo.size.width)
        })
        .onPreferenceChange(MenuBarWidthKey.self) { onWidth($0) }
    }
}

/// NSHostingView that lets every mouse event fall through to the status-bar button
/// beneath it, so clicks still toggle the popover (the content is presentational).
final class PassthroughStatusHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
