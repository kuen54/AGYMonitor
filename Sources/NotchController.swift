import AppKit
import SwiftUI
import Combine

// MARK: - Notch UI (AppKit layer)
//
// The AppKit layer for Notch display mode: screen/notch geometry, synthetic-notch
// fallback on external displays, one fixed-footprint NSPanel per display, screen-change
// and wake rebuild lifecycle, per-display fullscreen behavior, and the global+local
// mouse monitor that governs open/close (dwell + grace) and mouse passthrough.
//
// Main-thread only (plain NSObject, like AppDelegate). macOS 13 safe.

// MARK: - NSScreen geometry

extension NSScreen {
    /// True only on a REAL notched display (both the top safe-area inset and the two
    /// auxiliary top areas resolve).
    var hasNotch: Bool {
        safeAreaInsets.top > 0
            && auxiliaryTopLeftArea != nil
            && auxiliaryTopRightArea != nil
    }

    /// Physical notch size (points), or nil on a non-notched display.
    var notchSize: CGSize? {
        guard safeAreaInsets.top > 0,
              let left = auxiliaryTopLeftArea?.width,
              let right = auxiliaryTopRightArea?.width
        else { return nil }
        return CGSize(width: frame.width - left - right, height: safeAreaInsets.top)
    }

    /// Menu-bar height = full frame top minus the visible (menu-bar-excluded) top.
    var menubarHeight: CGFloat { frame.maxY - visibleFrame.maxY }

    /// Physical notch rect in GLOBAL (bottom-left origin) coordinates, centered and
    /// flush to the very top. nil on non-notch displays.
    var notchRect: NSRect? {
        guard let size = notchSize else { return nil }
        return NSRect(x: frame.midX - size.width / 2,
                      y: frame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    var displayID: CGDirectDisplayID? {
        guard let n = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        return CGDirectDisplayID(n.uint32Value)
    }

    /// Stable per-display UUID string matching SkyLight's "Display Identifier".
    var displayUUID: String? {
        guard let id = displayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// Is this the built-in (laptop) panel?
    var isBuiltin: Bool {
        guard let id = displayID else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }
}

// MARK: - Resolved target screen

/// The fully-resolved screen + geometry a single notch panel lives on.
struct NotchScreen {
    let screen: NSScreen
    /// true => drawn on a NON-notch display (synthetic pill).
    let isSynthetic: Bool
    /// Idle hover/hit rect: the real notch rect, or a synthetic top-center rect.
    let notchRect: NSRect
    /// Size of the closed pill the SwiftUI content draws at the top.
    let closedNotchSize: CGSize
}

/// Resolve EVERY connected screen to a NotchScreen: real geometry on a notched display,
/// a synthetic top-center pill everywhere else.
func resolveNotchScreens(syntheticWidth: CGFloat = 200) -> [NotchScreen] {
    NSScreen.screens.map { screen in
        if screen.hasNotch, let rect = screen.notchRect, let size = screen.notchSize {
            return NotchScreen(screen: screen, isSynthetic: false,
                               notchRect: rect, closedNotchSize: size)
        }
        let height = max(24, screen.menubarHeight)
        let rect = NSRect(x: screen.frame.midX - syntheticWidth / 2,
                          y: screen.frame.maxY - height,
                          width: syntheticWidth, height: height)
        return NotchScreen(screen: screen, isSynthetic: true,
                           notchRect: rect,
                           closedNotchSize: CGSize(width: syntheticWidth, height: height))
    }
}

// MARK: - NotchPanel (one canonical window PER display)

/// Borderless, non-activating, clear floating panel pinned above the menu bar so it
/// can overlap the physical notch.
final class NotchPanel: NSPanel {
    /// Drives canBecomeKey. false for the idle pill; true while expanded so
    /// PopoverView's controls receive key events.
    var isInteractive = false

    static let notchStyleMask: NSWindow.StyleMask =
        [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow]

    convenience init(contentRect: NSRect) {
        self.init(contentRect: contentRect, styleMask: NotchPanel.notchStyleMask,
                  backing: .buffered, defer: false)
    }

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask,
                  backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask,
                   backing: backing, defer: flag)
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        appearance = NSAppearance(named: .darkAqua)
        level = .screenSaver
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
    }

    override var canBecomeKey: Bool { isInteractive }
    override var canBecomeMain: Bool { false }

    func enableFullscreenFloat() { FullscreenSpace.shared.add(self) }
    func disableFullscreenFloat() { FullscreenSpace.shared.remove(self) }
}

// MARK: - FirstMouseHostingView

/// NSHostingView that responds to the FIRST click even while its window is non-key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - NotchInstance (everything that is per-display)

final class NotchInstance {
    let vm = NotchViewModel()
    let panel: NotchPanel
    let screen: NotchScreen
    var state: NotchState
    var openWork: DispatchWorkItem?
    var closeWork: DispatchWorkItem?
    var lastPointerSample: NotchPointerSample? = nil

    init(panel: NotchPanel, screen: NotchScreen, isFullscreen: Bool = false) {
        self.panel = panel
        self.screen = screen
        self.state = NotchState(
            phase: isFullscreen ? .hidden : .closedPill,
            isFullscreen: isFullscreen
        )
    }
}

// MARK: - NotchController

final class NotchController: NSObject {
    private let store: UsageStore
    private let onQuit: () -> Void
    private let onOpenStateChanged: ((Bool) -> Void)?

    private let maxWindowSize = CGSize(width: 600, height: 860)
    private let syntheticWidth: CGFloat = 200
    private let hoverShoulder: CGFloat = 84
    private let revealEdge: CGFloat = 8

    private var isStarted = false
    private var instances: [CGDirectDisplayID: NotchInstance] = [:]

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var rebuildWork: DispatchWorkItem?
    private var wingState = NotchLiveWingState()
    private var wingTimer: DispatchWorkItem?
    private var sessionWingObserver: AnyCancellable?

    init(
        store: UsageStore,
        onQuit: @escaping () -> Void,
        onOpenStateChanged: ((Bool) -> Void)? = nil
    ) {
        self.store = store
        self.onQuit = onQuit
        self.onOpenStateChanged = onOpenStateChanged
        super.init()
    }

    deinit { stop() }

    // MARK: Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        installMouseMonitor()
        installSessionWingObserver()
        rebuild()
    }

    func stop() {
        guard isStarted || !instances.isEmpty || globalMonitor != nil || localMonitor != nil else { return }
        isStarted = false
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        rebuildWork?.cancel(); rebuildWork = nil
        wingTimer?.cancel(); wingTimer = nil
        sessionWingObserver?.cancel(); sessionWingObserver = nil
        removeMouseMonitor()
        teardownAll()
    }

    @objc private func screenParametersChanged() {
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild() }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    @objc private func activeSpaceChanged() {
        let mouse = NSEvent.mouseLocation
        for inst in instances.values {
            let isFS = inst.screen.screen.displayUUID
                .map { FullscreenDetector.shared.isFullscreen(displayUUID: $0) } ?? false
            let sample = pointerSample(for: inst, mouse: mouse)
            dispatch(inst, event: .fullscreenChanged(isFS), pointer: sample)
        }
    }

    private func rebuild() {
        teardownAll()
        let resolved = resolveNotchScreens(syntheticWidth: syntheticWidth)
        guard !resolved.isEmpty else { return }

        for ns in resolved {
            guard let id = ns.screen.displayID else { continue }
            let frame = panelFrame(for: ns)
            let panel = NotchPanel(contentRect: frame)
            let isFS = ns.screen.displayUUID
                .map { FullscreenDetector.shared.isFullscreen(displayUUID: $0) } ?? false
            let inst = NotchInstance(panel: panel, screen: ns, isFullscreen: isFS)
            inst.vm.closedNotchSize = ns.closedNotchSize
            inst.vm.isSynthetic = ns.isSynthetic
            inst.vm.isOpen = inst.state.isOpen
            inst.vm.activeWing = wingState.activeWing
            inst.vm.anyBusy = store.sessionStore.anyBusy
            inst.vm.anyWaiting = store.sessionStore.anyWaiting
            inst.vm.onAcquireModalLock = { [weak self, weak inst] lock in
                guard let self = self, let inst = inst else { return }
                self.dispatch(inst, event: .modalLockAcquired(lock))
            }
            inst.vm.onReleaseModalLock = { [weak self, weak inst] lock in
                guard let self = self, let inst = inst else { return }
                let sample = self.pointerSample(for: inst)
                self.dispatch(inst, event: .modalLockReleased(lock, pointer: sample), pointer: sample)
            }
            inst.vm.onTapWing = { [weak self] sessionId in
                self?.handleTapWing(sessionId: sessionId)
            }
            inst.vm.onRequestClose = { [weak self, weak inst] in
                guard let self = self, let inst = inst else { return }
                self.dispatch(inst, event: .explicitClose)
            }
            inst.vm.onContentSizeChanged = { [weak self] in
                self?.applyPanelState()
            }

            let host = FirstMouseHostingView(rootView: NotchRootView(store: store, sessionStore: store.sessionStore, vm: inst.vm, onQuit: onQuit))
            host.translatesAutoresizingMaskIntoConstraints = true
            host.frame = NSRect(origin: .zero, size: frame.size)
            host.autoresizingMask = [.width, .height]
            panel.contentView = host
            panel.setFrame(frame, display: true)

            panel.alphaValue = 0
            panel.orderFrontRegardless()
            panel.enableFullscreenFloat()

            instances[id] = inst
        }
        applyPanelState()
    }

    private func teardownAll() {
        for inst in instances.values {
            inst.vm.onContentSizeChanged = nil
            inst.openWork?.cancel()
            inst.closeWork?.cancel()
            inst.panel.disableFullscreenFloat()
            inst.panel.orderOut(nil)
            inst.panel.close()
        }
        instances.removeAll()
        syncSessionMonitorActive()
    }

    private func panelFrame(for ns: NotchScreen) -> NSRect {
        let f = ns.screen.frame
        let h = min(maxWindowSize.height, ns.screen.visibleFrame.height - 8)
        let w = min(maxWindowSize.width, f.width)
        return NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
    }

    // MARK: State-machine dispatch (backed by Core_NotchState.NotchMachine)

    private func revealRect(_ ns: NotchScreen) -> NSRect {
        let f = ns.screen.frame
        let band = max(ns.closedNotchSize.height, 24)
        return NSRect(x: f.minX, y: f.maxY - band, width: f.width, height: band)
    }

    private func edgeRect(_ ns: NotchScreen) -> NSRect {
        let f = ns.screen.frame
        return NSRect(x: f.minX, y: f.maxY - revealEdge, width: f.width, height: revealEdge)
    }

    /// Mouse hit-test counting a rect's TOP edge as inside (`minY < y <= maxY`).
    private func hit(_ p: NSPoint, _ r: NSRect) -> Bool { NSMouseInRect(p, r, false) }

    private func pointerSample(for inst: NotchInstance,
                               mouse: NSPoint = NSEvent.mouseLocation) -> NotchPointerSample {
        let onScreen = hit(mouse, inst.screen.screen.frame)
        let inClickableWing = !inst.state.isOpen
            && inst.vm.activeWing != nil
            && onScreen
            && hit(mouse, closedWingRect(inst))
        return NotchPointerSample(
            onScreen: onScreen,
            inHoverBand: onScreen && hit(mouse, hoverRect(inst)),
            inContentRect: onScreen && hit(mouse, contentRect(inst)),
            inRevealEdge: onScreen && hit(mouse, edgeRect(inst.screen)),
            inRevealBand: onScreen && hit(mouse, revealRect(inst.screen)),
            inClickableWing: inClickableWing
        )
    }

    private func dispatch(_ inst: NotchInstance, event: NotchEvent,
                          pointer: NotchPointerSample? = nil,
                          mouse: NSPoint = NSEvent.mouseLocation) {
        let effects = NotchMachine.reduce(&inst.state, event: event)
        if inst.vm.isOpen != inst.state.isOpen {
            inst.vm.isOpen = inst.state.isOpen
        }
        let sample = pointer ?? pointerSample(for: inst, mouse: mouse)
        for effect in effects {
            switch effect {
            case .scheduleOpenDwell:
                scheduleOpen(inst)
            case .cancelOpenDwell:
                cancelOpen(inst)
            case .scheduleCloseGrace:
                scheduleClose(inst)
            case .cancelCloseGrace:
                cancelClose(inst)
            case .setInteractive(let interactive):
                inst.panel.isInteractive = interactive
            case .resignKeyIfNeeded:
                if inst.panel.isKeyWindow { inst.panel.resignKey() }
            case .syncSessionMonitor:
                syncSessionMonitorActive()
            case .refreshUsage:
                store.refresh()
            case .applyPanelPresentation:
                applyPresentation(inst, pointer: sample)
            }
        }
    }

    private func syncSessionMonitorActive() {
        let anyOpen = instances.values.contains { $0.state.isOpen }
        if let onOpenStateChanged = onOpenStateChanged {
            onOpenStateChanged(anyOpen)
        } else {
            store.setSessionMonitorActive(anyOpen)
        }
    }

    func reveal() {
        if let inst = primaryInstance() {
            dispatch(inst, event: .explicitReveal)
        }
    }

    func toggle() {
        guard let inst = primaryInstance() else { return }
        dispatch(inst, event: .explicitToggle)
    }

    private func primaryInstance() -> NotchInstance? {
        let mouse = NSEvent.mouseLocation
        if let under = instances.values.first(where: { hit(mouse, $0.screen.screen.frame) }) { return under }
        if let builtin = instances.values.first(where: { $0.screen.screen.isBuiltin }) { return builtin }
        if let mainID = NSScreen.main?.displayID, let onMain = instances[mainID] { return onMain }
        return instances.values.first
    }

    // MARK: Mouse monitor

    private func installMouseMonitor() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) {
            [weak self] _ in self?.handleMouseMoved()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) {
            [weak self] event in self?.handleMouseMoved(); return event
        }
    }

    private func removeMouseMonitor() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    private func handleMouseMoved() {
        let mouse = NSEvent.mouseLocation
        for inst in instances.values {
            let sample = pointerSample(for: inst, mouse: mouse)
            if sample == inst.lastPointerSample {
                continue
            }
            inst.lastPointerSample = sample
            dispatch(inst, event: .pointerMoved(sample), pointer: sample, mouse: mouse)
        }
    }

    private func scheduleOpen(_ inst: NotchInstance) {
        guard inst.openWork == nil else { return }
        let work = DispatchWorkItem { [weak self, weak inst] in
            guard let self = self, let inst = inst else { return }
            inst.openWork = nil
            let sample = self.pointerSample(for: inst)
            self.dispatch(inst, event: .openDwellFired(sample), pointer: sample)
        }
        inst.openWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchTiming.openDwell, execute: work)
    }

    private func cancelOpen(_ inst: NotchInstance) { inst.openWork?.cancel(); inst.openWork = nil }

    private func scheduleClose(_ inst: NotchInstance) {
        guard inst.closeWork == nil else { return }
        let work = DispatchWorkItem { [weak self, weak inst] in
            guard let self = self, let inst = inst else { return }
            inst.closeWork = nil
            let sample = self.pointerSample(for: inst)
            self.dispatch(inst, event: .closeGraceFired(sample), pointer: sample)
        }
        inst.closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchTiming.closeGrace, execute: work)
    }

    private func cancelClose(_ inst: NotchInstance) { inst.closeWork?.cancel(); inst.closeWork = nil }

    private func hoverRect(_ ns: NotchScreen) -> NSRect {
        let f = ns.screen.frame
        let w = ns.closedNotchSize.width + 2 * hoverShoulder
        let h = ns.closedNotchSize.height
        return NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
    }

    /// When Live Wing is active on the right shoulder, restrict hover-to-open to
    /// the left wing + physical notch so clicking the right action pill never
    /// races with openDwell expanding the whole panel.
    private func hoverRect(_ inst: NotchInstance) -> NSRect {
        let base = hoverRect(inst.screen)
        guard inst.vm.activeWing != nil, !inst.state.isOpen else { return base }
        let wingMinX = min(base.minX, closedWingRect(inst).minX)
        let rightLimit = inst.screen.screen.frame.midX + inst.screen.closedNotchSize.width / 2 + 8
        let trimmedWidth = max(40, rightLimit - wingMinX)
        return NSRect(x: wingMinX, y: base.minY, width: trimmedWidth, height: base.height)
    }

    private func closedWingRect(_ inst: NotchInstance) -> NSRect {
        let f = inst.screen.screen.frame
        let size = inst.vm.contentSize
        guard size.width > 1, size.height > 1 else { return hoverRect(inst.screen) }
        let centerX = f.midX + inst.vm.compactGapOffset
        return NSRect(x: centerX - size.width / 2, y: f.maxY - size.height,
                      width: size.width, height: size.height)
    }

    private func contentRect(_ inst: NotchInstance) -> NSRect {
        let f = inst.screen.screen.frame
        let size = inst.vm.contentSize
        guard size.width > 1, size.height > 1 else { return hoverRect(inst.screen) }
        return NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height,
                      width: size.width, height: size.height)
    }

    // MARK: Live Wing State Machine Sync

    private func installSessionWingObserver() {
        sessionWingObserver?.cancel()
        sessionWingObserver = Publishers.CombineLatest3(
            store.sessionStore.$sessions,
            store.sessionStore.$doneUnseen,
            store.sessionStore.$labels
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] sessions, doneUnseen, labels in
            self?.syncLiveWing(sessions: sessions, doneUnseen: doneUnseen, labels: labels)
        }
    }

    private func syncLiveWing(sessions: [SessionInfo], doneUnseen: Set<String>, labels: [String: String]) {
        let snapshots = sessions.map { s in
            let ws = labels[s.cwd] ?? SessionLogic.basename(s.cwd)
            let badge = SessionSurfaceBadge.from(entrypoint: s.entrypoint, surface: s.surface)?.rawValue
            return NotchWingSessionSnapshot(
                sessionId: s.sessionId,
                workspace: ws.isEmpty ? "session" : ws,
                surface: badge,
                isWaiting: s.status == .waiting,
                needsConfirm: s.waitReason == .needsConfirmation,
                isDoneUnseen: doneUnseen.contains(s.sessionId)
            )
        }
        let effects = NotchLiveWingMachine.reduce(&wingState, event: .sessionsUpdated(snapshots, now: Date()))
        applyWingEffects(effects)
        pushWingStateToViewModels()
    }

    private func handleTapWing(sessionId: String) {
        if let match = store.sessionStore.sessions.first(where: { $0.sessionId == sessionId }) {
            store.sessionStore.jump(match)
        }
        let effects = NotchLiveWingMachine.reduce(&wingState, event: .dismissed(sessionId: sessionId))
        applyWingEffects(effects)
        pushWingStateToViewModels()
    }

    private func applyWingEffects(_ effects: [NotchLiveWingEffect]) {
        for effect in effects {
            switch effect {
            case .scheduleDoneRetract(let delay):
                wingTimer?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    self.wingTimer = nil
                    let follow = NotchLiveWingMachine.reduce(&self.wingState, event: .doneTimerFired(now: Date()))
                    self.applyWingEffects(follow)
                    self.pushWingStateToViewModels()
                }
                wingTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            case .cancelDoneRetract:
                wingTimer?.cancel()
                wingTimer = nil
            }
        }
    }

    private func pushWingStateToViewModels() {
        let busy = store.sessionStore.anyBusy
        let waiting = store.sessionStore.anyWaiting
        var changed = false
        for inst in instances.values {
            if inst.vm.activeWing != wingState.activeWing {
                inst.vm.activeWing = wingState.activeWing
                changed = true
            }
            if inst.vm.anyBusy != busy { inst.vm.anyBusy = busy }
            if inst.vm.anyWaiting != waiting { inst.vm.anyWaiting = waiting }
        }
        if changed { applyPanelState() }
    }

    // MARK: Visibility + passthrough

    private func applyPanelState() {
        let mouse = NSEvent.mouseLocation
        for inst in instances.values {
            applyPresentation(inst, pointer: pointerSample(for: inst, mouse: mouse))
        }
    }

    private func applyPresentation(_ inst: NotchInstance, pointer: NotchPointerSample) {
        let pres = NotchMachine.panelPresentation(for: inst.state, pointer: pointer)
        setVisible(inst, pres.visible)
        if inst.panel.ignoresMouseEvents != pres.ignoresMouseEvents {
            inst.panel.ignoresMouseEvents = pres.ignoresMouseEvents
        }
    }

    private func setVisible(_ inst: NotchInstance, _ visible: Bool) {
        if inst.vm.isPanelShown != visible {
            inst.vm.isPanelShown = visible
        }
        let target: CGFloat = visible ? 1 : 0
        guard abs(inst.panel.alphaValue - target) > 0.001 else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            inst.panel.alphaValue = target
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                inst.panel.animator().alphaValue = target
            }
        }
    }
}
