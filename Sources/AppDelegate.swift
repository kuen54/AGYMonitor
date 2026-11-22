import Cocoa
import SwiftUI
import Combine
import CoreServices

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menuBarPanel: MenuBarPanel!
    private var menuBarHostingView: FirstMouseHostingView<MenuBarPanelRootView>!
    private var menuBarPanelAnimates = true
    private var lastMeasuredPanelHeight: Double = 560.0
    private var panelAnimationToken = 0
    private var activeMenuTrackingCount = 0
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
    // value/width freezing while the panel is open and flushing on close.
    private let menuBarModel = MenuBarModel(text: "…")
    private var menuBarAnchor = MenuBarAnchorState(initialText: "…", initialWidth: 40, isMenuBarVisible: true)

    // App presentation state machine: single source of truth for display surface
    // (menu bar vs notch), panel/notch visibility, statusItem visibility, and hotkey.
    private var presentation = AppPresentationState()
    private var notchController: NotchController?
    private var displayModeCancellable: AnyCancellable?
    private let hotKeyManager = GlobalHotKeyManager()
    private var hotkeyCancellable: AnyCancellable?
    private var acousticCancellable: AnyCancellable?
    private var wallpaperRefreshCancellable: AnyCancellable?

    // Menu-bar floating panel anchor validation, placement, dismiss monitors, and host display
    // height metrics (backed by `MenuBarAnchorResolver` & `PopoverAnchorSessionState`).
    private let popoverHostMetrics = PopoverHostMetrics()
    private var popoverAnchorSession = PopoverAnchorSessionState()
    private var globalMouseMonitor: Any?
    private var panelDismissObservers: [NSObjectProtocol] = []
    private var menuTrackingObservers: [NSObjectProtocol] = []
    private var screenParametersObserver: NSObjectProtocol?
    private var calendarDayObserver: NSObjectProtocol?

    private struct AcousticSessionKey: Equatable {
        let waitingIds: Set<String>
        let doneUnseenIds: Set<String>
    }

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

        // Borderless Control-Center-style floating NSPanel with SwiftUI content.
        // Replaces arrowed NSPopover so multi-display anchoring, fullscreen menu-bar
        // retraction, and top-pinned tab height changes never jump or leave an orphaned arrow.
        let rootView = MenuBarPanelRootView(
            hostMetrics: popoverHostMetrics,
            store: store,
            onQuit: { NSApplication.shared.terminate(nil) },
            onClose: { [weak self] in self?.closeMenuBarPanel(animated: true) },
            onHeightChange: { [weak self] h in self?.updateMenuBarPanelHeight(h) }
        )
        let hostingView = FirstMouseHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        menuBarHostingView = hostingView

        let panel = MenuBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: AGYTheme.panelWidth, height: CGFloat(lastMeasuredPanelHeight))
        )
        panel.contentView = hostingView
        panel.onCancelOperation = { [weak self] in
            self?.closeMenuBarPanel(animated: true)
        }
        menuBarPanel = panel

        // Track active NSMenu dropdowns (OptionsMenu / LanguageSwitcher) so opening a
        // footer menu inside the floating panel never triggers outside-click or resign-key close.
        let center = NotificationCenter.default
        let beginMenuObs = center.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.activeMenuTrackingCount += 1
        }
        let endMenuObs = center.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.activeMenuTrackingCount = max(0, self.activeMenuTrackingCount - 1)
            }
        }
        menuTrackingObservers = [beginMenuObs, endMenuObs]

        screenParametersObserver = center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reconcileMenuBarPanelForScreenChange()
        }

        // Midnight calendar day change: refresh Daily Blueprint Wallpaper without polling timers.
        calendarDayObserver = center.addObserver(
            forName: .NSCalendarDayChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.store.checkDailyWallpaperIfNeeded()
        }

        // Observe current month data + tab changes + live working TPS to update menu bar title.
        // Always shows current month regardless of which month is being viewed.
        // CombineLatest4 is Combine's max arity — extra signals are chained below.
        let liveTPSSignal = store.sessionStore.$liveTPS
            .map { tps -> String? in
                guard tps.isWorking, tps.currentTPS >= 1.0 else { return nil }
                return LiveTPSTracker.formatCompactTPS(tps.currentTPS)
            }
            .removeDuplicates()
        let sessionMenuSignal = store.sessionStore.$sessions
            .map { sessions -> String in
                "\(sessions.count)|\(sessions.contains { $0.status == .busy })|\(sessions.contains { $0.status == .waiting })"
            }
            .removeDuplicates()
            .combineLatest(liveTPSSignal)
        cancellable = Publishers.CombineLatest4(
            store.$currentMonthData, store.$selectedTab, store.$language, store.$subscriptionQuota)
            .combineLatest(store.$today, store.$menuBarMetric, store.$timeTodaySeconds)
            .combineLatest(sessionMenuSignal)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, sessionPair in
                guard let self = self, self.store.canDisplayMenuBarValue else { return }
                let baseValue = self.store.menuBarValue
                let value = sessionPair.1.map { "\(baseValue) · \($0)" } ?? baseValue
                self.menuBarAnchor.updateValue(value)
                if self.menuBarModel.text != self.menuBarAnchor.displayedText {
                    self.menuBarModel.text = self.menuBarAnchor.displayedText
                }
            }

        // Acoustic cockpit chimes: edge-triggered on newly waiting or newly completed sessions.
        acousticCancellable = Publishers.CombineLatest(
            store.sessionStore.$sessions,
            store.sessionStore.$doneUnseen
        )
        .map { sessions, doneUnseen in
            AcousticSessionKey(
                waitingIds: Set(sessions.filter { $0.status == .waiting }.map(\.sessionId)),
                doneUnseenIds: doneUnseen
            )
        }
        .removeDuplicates()
        .receive(on: RunLoop.main)
        .sink { [weak self] key in
            guard let self = self else { return }
            let enabled = self.store.craftPreferences.acousticChimesEnabled
            MainActor.assumeIsolated {
                CraftEngine.shared.handleSessionTransition(
                    waitingIds: key.waitingIds,
                    doneUnseenIds: key.doneUnseenIds,
                    enabled: enabled
                )
            }
        }

        // Daily Blueprint Wallpaper: trigger once initial usage or year data lands (gated by
        // `DailyWallpaperGate.shouldRefresh` so repeat ticks on the same day are O(1) no-ops).
        wallpaperRefreshCancellable = Publishers.CombineLatest(
            store.$lastUpdate,
            store.$yearTimeDays.map { $0 != nil }.removeDuplicates()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] lastUpdate, hasYearData in
            guard let self = self, lastUpdate != nil || hasYearData else { return }
            self.store.checkDailyWallpaperIfNeeded()
        }

        // Load cached data instantly, then refresh in background
        store.loadCacheForCurrentMonth()
        store.refresh()

        // Live session monitor (FSEvents + poll over Antigravity presence & metadata).
        // Runs in both menu-bar and notch modes; the poll bumps to active while the
        // popover is on screen (popoverDidShow/Close).
        store.startSessionMonitoring()

        // GitHub Releases update checker (10s launch delay, 24h cadence, one-time system notification)
        store.startUpdateChecking()

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
                } else {
                    closeMenuBarPanel(animated: false)
                }
                statusItem.isVisible = visible
            case .setMenuBarLogoActive(let active):
                if menuBarModel.isVisible != active {
                    menuBarModel.isVisible = active
                }
            case .setPopoverAnimates(let animates):
                menuBarPanelAnimates = animates
            case .openPopover:
                if !presentation.popoverOpen || !menuBarPanel.isVisible {
                    openMenuBarPanel(animated: menuBarPanelAnimates)
                }
            case .closePopover:
                closeMenuBarPanel(animated: presentation.surface == .menubar && menuBarPanelAnimates)
            case .showStatusContextMenu:
                showStatusContextMenu()
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
    /// item to it. Frozen while the panel is open; closing restores appliedWidth.
    private func updateMenuBarWidth(_ w: CGFloat) {
        menuBarAnchor.updateMeasuredWidth(Double(w))
        guard presentation.isStatusItemVisible, !menuBarAnchor.isPopoverShown, !presentation.popoverOpen else { return }
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

    // MARK: - Control-Center Floating Menu Bar Panel (Validated Anchor + Top-Pinned Resize)

    private func currentDisplayDescriptors() -> (
        descriptors: [MenuBarDisplayDescriptor],
        byId: [UInt32: NSScreen],
        mouseDisplayId: UInt32?
    ) {
        let mainId = NSScreen.main?.displayID
        let mouse = NSEvent.mouseLocation
        var descriptors: [MenuBarDisplayDescriptor] = []
        var byId: [UInt32: NSScreen] = [:]
        var mouseDisplayId: UInt32? = nil

        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            byId[id] = screen
            if NSMouseInRect(mouse, screen.frame, false) {
                mouseDisplayId = id
            }
            let isFS = screen.displayUUID
                .map { FullscreenDetector.shared.isFullscreen(displayUUID: $0) } ?? false
            descriptors.append(MenuBarDisplayDescriptor(
                displayId: id,
                frame: ScreenRect(nsRect: screen.frame),
                visibleFrame: ScreenRect(nsRect: screen.visibleFrame),
                auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea.map(ScreenRect.init(nsRect:)),
                auxiliaryTopRightArea: screen.auxiliaryTopRightArea.map(ScreenRect.init(nsRect:)),
                safeAreaTop: Double(screen.safeAreaInsets.top),
                isBuiltin: screen.isBuiltin,
                isMain: id == mainId,
                isFullscreen: isFS
            ))
        }
        return (descriptors, byId, mouseDisplayId)
    }

    private func statusItemAnchorSnapshot() -> StatusItemAnchorSnapshot {
        guard let button = statusItem.button, let win = button.window else {
            return StatusItemAnchorSnapshot(
                statusItemVisible: statusItem.isVisible,
                hasWindow: false,
                windowVisible: false,
                windowAlpha: 0.0,
                buttonScreenRect: nil,
                windowScreenDisplayId: nil
            )
        }
        let rectInWindow = button.convert(button.bounds, to: nil)
        let rectOnScreen = win.convertToScreen(rectInWindow)
        return StatusItemAnchorSnapshot(
            statusItemVisible: statusItem.isVisible,
            hasWindow: true,
            windowVisible: win.isVisible,
            windowAlpha: Double(win.alphaValue),
            buttonScreenRect: ScreenRect(nsRect: rectOnScreen),
            windowScreenDisplayId: win.screen?.displayID
        )
    }

    private func openMenuBarPanel(animated: Bool) {
        let (descriptors, byId, mouseDisplayId) = currentDisplayDescriptors()
        let decision = MenuBarAnchorResolver.resolve(
            snapshot: statusItemAnchorSnapshot(),
            displays: descriptors,
            mouseDisplayId: mouseDisplayId,
            panelWidth: Double(AGYTheme.panelWidth)
        )

        let hostDisplayId: UInt32
        let anchorRect: ScreenRect
        let shouldHighlightButton: Bool

        switch decision {
        case .statusItem(let displayId, let buttonRect):
            hostDisplayId = displayId
            anchorRect = buttonRect
            shouldHighlightButton = true
        case .fallbackMenuBar(let displayId, let rect, _):
            hostDisplayId = displayId
            anchorRect = rect
            shouldHighlightButton = false
        case .unavailable:
            popoverAnchorSession.popoverClosed()
            return
        }

        guard let hostDisplay = descriptors.first(where: { $0.displayId == hostDisplayId }) else {
            popoverAnchorSession.popoverClosed()
            return
        }

        popoverHostMetrics.screenVisibleHeight = byId[hostDisplayId]?.visibleFrame.height
            ?? CGFloat(hostDisplay.visibleFrame.height)

        // Freeze status-item text/width BEFORE showing so synchronous refreshes never shift the anchor.
        menuBarAnchor.popoverOpened()
        popoverAnchorSession.beginSession(decision: decision)

        // Measure intrinsic SwiftUI height so the initial frame matches content on frame 0.
        menuBarHostingView.layoutSubtreeIfNeeded()
        let fittingH = ceil(Double(menuBarHostingView.fittingSize.height))
        let initialHeight = fittingH > 1.0 ? max(180.0, fittingH) : lastMeasuredPanelHeight
        lastMeasuredPanelHeight = initialHeight

        let targetFrame = MenuBarAnchorResolver.panelFrame(
            anchorRect: anchorRect,
            hostDisplay: hostDisplay,
            panelWidth: Double(AGYTheme.panelWidth),
            panelHeight: initialHeight
        )

        panelAnimationToken += 1
        detachPanelDismissMonitors()

        menuBarPanel.setFrame(targetFrame.nsRect, display: true)
        menuBarPanel.invalidateShadow()
        statusItem.button?.highlight(shouldHighlightButton)

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animated && !reduceMotion {
            menuBarPanel.alphaValue = 0.0
            menuBarPanel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.menuBarPanel.animator().alphaValue = 1.0
            }
        } else {
            menuBarPanel.alphaValue = 1.0
            menuBarPanel.makeKeyAndOrderFront(nil)
        }

        dispatchPresentation(.popoverShown)
        let openToken = panelAnimationToken
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  self.panelAnimationToken == openToken,
                  self.presentation.popoverOpen else { return }
            self.attachPanelDismissMonitors()
        }

        dispatchBrainWatcher(.reconcileWatchPaths(candidatePaths: candidateBrainWatchPaths(), now: Date()))
        store.refresh()
    }

    private func closeMenuBarPanel(animated: Bool) {
        let wasOpen = presentation.popoverOpen || menuBarPanel.isVisible
        detachPanelDismissMonitors()
        statusItem.button?.highlight(false)

        panelAnimationToken += 1
        let closeToken = panelAnimationToken

        popoverAnchorSession.popoverClosed()
        menuBarAnchor.popoverClosed()
        menuBarModel.text = menuBarAnchor.displayedText
        if presentation.isStatusItemVisible {
            statusItem.length = CGFloat(menuBarAnchor.appliedWidth)
        }

        if presentation.popoverOpen {
            dispatchPresentation(.popoverClosed)
        }

        guard wasOpen, menuBarPanel.isVisible else {
            menuBarPanel.orderOut(nil)
            menuBarPanel.alphaValue = 1.0
            return
        }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animated && !reduceMotion {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.10
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.menuBarPanel.animator().alphaValue = 0.0
            }, completionHandler: { [weak self] in
                guard let self = self, self.panelAnimationToken == closeToken else { return }
                self.menuBarPanel.orderOut(nil)
                self.menuBarPanel.alphaValue = 1.0
            })
        } else {
            menuBarPanel.orderOut(nil)
            menuBarPanel.alphaValue = 1.0
        }
    }

    private func updateMenuBarPanelHeight(_ rawHeight: CGFloat) {
        let h = max(180.0, ceil(Double(rawHeight)))
        let heightChanged = abs(h - lastMeasuredPanelHeight) > 0.5
        let frameNeedsSync = presentation.popoverOpen
            && menuBarPanel.isVisible
            && abs(Double(menuBarPanel.frame.height) - h) > 0.5
        guard heightChanged || frameNeedsSync else { return }
        lastMeasuredPanelHeight = h

        guard presentation.popoverOpen, menuBarPanel.isVisible else { return }
        let (descriptors, _, _) = currentDisplayDescriptors()
        let hostDisplay = popoverAnchorSession.mode.displayId.flatMap { id in
            descriptors.first(where: { $0.displayId == id })
        }
        let resized = MenuBarAnchorResolver.resizedPanelFrame(
            currentFrame: ScreenRect(nsRect: menuBarPanel.frame),
            newHeight: h,
            hostDisplay: hostDisplay
        )
        menuBarPanel.setFrame(resized.nsRect, display: true, animate: false)
        menuBarPanel.invalidateShadow()
    }

    private func reconcileMenuBarPanelForScreenChange() {
        guard presentation.popoverOpen, menuBarPanel.isVisible else { return }
        let (descriptors, byId, _) = currentDisplayDescriptors()
        guard let hostId = popoverAnchorSession.mode.displayId,
              let host = descriptors.first(where: { $0.displayId == hostId }) else {
            closeMenuBarPanel(animated: false)
            return
        }
        popoverHostMetrics.screenVisibleHeight = byId[hostId]?.visibleFrame.height
            ?? CGFloat(host.visibleFrame.height)
        if let anchor = popoverAnchorSession.mode.anchorRect {
            let clamped = MenuBarAnchorResolver.panelFrame(
                anchorRect: anchor,
                hostDisplay: host,
                panelWidth: Double(AGYTheme.panelWidth),
                panelHeight: lastMeasuredPanelHeight
            )
            menuBarPanel.setFrame(clamped.nsRect, display: true, animate: false)
            menuBarPanel.invalidateShadow()
        }
    }

    private func attachPanelDismissMonitors() {
        detachPanelDismissMonitors()

        // Outside clicks in any other application or desktop immediately dismiss the panel.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self = self else { return }
            guard self.presentation.popoverOpen,
                  self.activeMenuTrackingCount == 0,
                  NSApp.modalWindow == nil else { return }
            self.closeMenuBarPanel(animated: true)
        }

        let center = NotificationCenter.default
        let resignKeyObs = center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: menuBarPanel,
            queue: .main
        ) { [weak self] _ in
            guard let self = self,
                  self.presentation.popoverOpen,
                  self.activeMenuTrackingCount == 0,
                  NSApp.modalWindow == nil else { return }
            // If resign-key was caused by clicking our own statusItem button, suppress the
            // matching `leftMouseUp` toggle so clicking the icon closes cleanly without bouncing.
            if NSApp.currentEvent?.type == .leftMouseDown,
               let buttonRect = self.statusItemAnchorSnapshot().buttonScreenRect {
                let mouse = NSEvent.mouseLocation
                if buttonRect.contains(x: Double(mouse.x), y: Double(mouse.y)) {
                    self.popoverAnchorSession.noteTransientCloseFromStatusItemClick(at: Date())
                }
            }
            self.closeMenuBarPanel(animated: true)
        }

        let spaceObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.presentation.popoverOpen else { return }
            self.closeMenuBarPanel(animated: false)
        }

        panelDismissObservers = [resignKeyObs, spaceObs]
    }

    private func detachPanelDismissMonitors() {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
        guard !panelDismissObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let wsCenter = NSWorkspace.shared.notificationCenter
        for token in panelDismissObservers {
            center.removeObserver(token)
            wsCenter.removeObserver(token)
        }
        panelDismissObservers.removeAll()
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
        acousticCancellable?.cancel(); acousticCancellable = nil
        wallpaperRefreshCancellable?.cancel(); wallpaperRefreshCancellable = nil
        closeMenuBarPanel(animated: false)
        for obs in menuTrackingObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        menuTrackingObservers.removeAll()
        if let obs = screenParametersObserver {
            NotificationCenter.default.removeObserver(obs)
            screenParametersObserver = nil
        }
        if let obs = calendarDayObserver {
            NotificationCenter.default.removeObserver(obs)
            calendarDayObserver = nil
        }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        dispatchPresentation(.appWillTerminate)
        dispatchBrainWatcher(.terminate)
        store.stopUpdateChecking()
        store.stopSessionMonitoring()
    }

    @objc private func onWake(_ note: Notification) {
        dispatchBrainWatcher(.wakeReceived)
        store.handleSystemWakeForUpdates()
        store.checkDailyWallpaperIfNeeded()
    }

    @objc private func handleStatusItemClick() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if !isRightClick, popoverAnchorSession.consumeSuppressedStatusItemClick(at: Date()) {
            return
        }
        dispatchPresentation(isRightClick ? .statusItemRightClicked : .statusItemLeftClicked)
    }

    private func showStatusContextMenu() {
        let (descriptors, _, mouseDisplayId) = currentDisplayDescriptors()
        let decision = MenuBarAnchorResolver.resolve(
            snapshot: statusItemAnchorSnapshot(),
            displays: descriptors,
            mouseDisplayId: mouseDisplayId,
            panelWidth: Double(AGYTheme.panelWidth)
        )
        guard decision != .unavailable else { return }

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

        // 5. Specimen Export, Hotkey, Updates, Refresh & Quit
        let specimenItem = NSMenuItem(
            title: loc("menuExportSpecimen"),
            action: #selector(contextExportSpecimen),
            keyEquivalent: "e"
        )
        specimenItem.keyEquivalentModifierMask = [.command]
        specimenItem.target = self
        menu.addItem(specimenItem)
        menu.addItem(.separator())

        let hkItem = NSMenuItem(title: loc("hotkeyToggle"), action: #selector(contextToggleHotkey), keyEquivalent: "")
        hkItem.target = self
        hkItem.state = store.globalHotkeyEnabled ? .on : .off
        menu.addItem(hkItem)

        if let available = store.updateService.state.availableUpdate {
            let updateItem = NSMenuItem(
                title: String(format: loc("updateMenuAvailableFmt"), available.version.displayTag),
                action: #selector(contextOpenAvailableUpdate),
                keyEquivalent: ""
            )
            updateItem.target = self
            menu.addItem(updateItem)
        }

        let isCheckingUpdates = store.updateService.state.isChecking
        let checkTitle = isCheckingUpdates
            ? loc("updateMenuChecking")
            : loc("updateMenuCheck")
        let checkUpdatesItem = NSMenuItem(
            title: checkTitle,
            action: isCheckingUpdates ? nil : #selector(contextCheckForUpdates),
            keyEquivalent: ""
        )
        checkUpdatesItem.target = isCheckingUpdates ? nil : self
        checkUpdatesItem.isEnabled = !isCheckingUpdates
        menu.addItem(checkUpdatesItem)

        let refreshItem = NSMenuItem(title: loc("refresh"), action: #selector(contextRefresh), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let quitItem = NSMenuItem(title: loc("quit"), action: #selector(contextQuit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        switch decision {
        case .statusItem:
            if let button = statusItem.button {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
            }
        case .fallbackMenuBar(_, let anchorRect, _):
            menu.popUp(positioning: nil, at: NSPoint(x: anchorRect.midX, y: anchorRect.minY), in: nil)
        case .unavailable:
            break
        }
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

    @objc private func contextExportSpecimen() {
        MainActor.assumeIsolated {
            SpecimenWindowController.shared.present(store: store)
        }
    }

    @objc private func contextToggleHotkey() {
        store.setGlobalHotkeyEnabled(!store.globalHotkeyEnabled)
    }

    @objc private func contextOpenAvailableUpdate() {
        store.updateService.openReleasePage()
    }

    @objc private func contextCheckForUpdates() {
        dispatchPresentation(.reopenRequested)
        store.checkForUpdatesManually()
    }

    @objc private func contextRefresh() {
        store.refresh(force: true)
    }

    @objc private func contextQuit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Popover Host Metrics & ScreenRect Bridge

private extension ScreenRect {
    init(nsRect: NSRect) {
        self.init(
            x: Double(nsRect.origin.x),
            y: Double(nsRect.origin.y),
            width: Double(nsRect.size.width),
            height: Double(nsRect.size.height)
        )
    }

    var nsRect: NSRect {
        NSRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
    }
}

/// Borderless Control-Center-style floating panel for Menu Bar mode.
/// Non-activating so opening over native Fullscreen apps never switches Spaces, yet
/// accepts key focus for keyboard shortcuts (`⌘1`–`⌘5`, `↑`/`↓`/`Return`, `Esc`).
private final class MenuBarPanel: NSPanel {
    var onCancelOperation: (() -> Void)?

    convenience init(contentRect: NSRect) {
        self.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }

    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isMovableByWindowBackground = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        level = .statusBar
        collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancelOperation?()
    }
}

/// Holds the resolved host display's visible height for the Menu Bar panel so
/// `PopoverView.maxContentHeight` clamps against the actual host display instead of `NSScreen.main`.
final class PopoverHostMetrics: ObservableObject {
    @Published var screenVisibleHeight: CGFloat? = nil
}

private struct MenuBarPanelRootView: View {
    @ObservedObject var hostMetrics: PopoverHostMetrics
    @ObservedObject var store: UsageStore
    let onQuit: () -> Void
    let onClose: () -> Void
    let onHeightChange: (CGFloat) -> Void

    @Environment(\.colorScheme) private var colorScheme

    private let cornerRadius: CGFloat = 12

    private var borderColor: Color {
        let theme = AGYTheme(preset: store.themePreset, colorScheme: colorScheme, isNotch: false)
        return theme.isDark
            ? Color.white.opacity(0.14)
            : Color.black.opacity(0.12)
    }

    var body: some View {
        PopoverView(store: store, onQuit: onQuit, onClose: onClose)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { onHeightChange(geo.size.height) }
                        .onChange(of: geo.size.height) { h in onHeightChange(h) }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.popoverHostScreenHeight, hostMetrics.screenVisibleHeight)
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
