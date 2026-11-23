import AppKit
import SwiftUI
import Combine

// MARK: - Notch UI (AppKit layer)
//
// The AppKit layer for Notch display mode: screen/notch geometry, synthetic-notch
// fallback on external displays, one top-pinned compact/expanded NSPanel per display,
// screen-change and wake rebuild lifecycle, per-display fullscreen behavior, and the
// global+local mouse monitor that governs open/close (dwell + grace) and mouse passthrough.
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
    var onCancelOperation: (() -> Void)?

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

    override func cancelOperation(_ sender: Any?) {
        onCancelOperation?()
    }

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
    let displayId: CGDirectDisplayID
    let vm = NotchViewModel()
    let panel: NotchPanel
    var screen: NotchScreen
    var backingMode: NotchPanelBackingMode = .compact
    var openWork: DispatchWorkItem?
    var closeWork: DispatchWorkItem?
    var shrinkWork: DispatchWorkItem?

    init(
        displayId: CGDirectDisplayID,
        panel: NotchPanel,
        screen: NotchScreen,
        backingMode: NotchPanelBackingMode = .compact
    ) {
        self.displayId = displayId
        self.panel = panel
        self.screen = screen
        self.backingMode = backingMode
    }
}

// MARK: - NotchController

final class NotchController: NSObject {
    private let store: UsageStore
    private let onQuit: () -> Void
    private let onOpenStateChanged: ((Bool) -> Void)?

    private let maxWindowSize = CGSize(width: 600, height: CGFloat(PanelHeightBudget.notchMaxWindowHeight))
    private let syntheticWidth: CGFloat = 200
    private let hoverShoulder: CGFloat = 84
    private let revealEdge: CGFloat = 8

    private var coordinator = NotchCoordinatorState()
    private var instances: [CGDirectDisplayID: NotchInstance] = [:]

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var rebuildWork: DispatchWorkItem?
    private var idleCacheTrimWork: DispatchWorkItem?
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
        guard NotchCoordinatorMachine.start(&coordinator) else { return }
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
        reconcileScreens()
    }

    func stop() {
        let removedIds = NotchCoordinatorMachine.stop(&coordinator)
        guard !removedIds.isEmpty || !instances.isEmpty || globalMonitor != nil || localMonitor != nil else { return }
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        rebuildWork?.cancel(); rebuildWork = nil
        cancelIdleCacheTrim()
        wingTimer?.cancel(); wingTimer = nil
        wingState = NotchLiveWingState()
        sessionWingObserver?.cancel(); sessionWingObserver = nil
        removeMouseMonitor()
        teardownAll()
    }

    @objc private func screenParametersChanged() {
        guard let gen = NotchCoordinatorMachine.scheduleRebuild(&coordinator) else { return }
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self,
                  NotchCoordinatorMachine.isCurrentRebuild(self.coordinator, generation: gen) else { return }
            self.reconcileScreens()
        }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchTiming.rebuildDebounce, execute: work)
    }

    @objc private func activeSpaceChanged() {
        guard coordinator.isStarted else { return }
        let mouse = NSEvent.mouseLocation
        for inst in instances.values {
            let isFS = inst.screen.screen.displayUUID
                .map { FullscreenDetector.shared.isFullscreen(displayUUID: $0) } ?? false
            let sample = pointerSample(for: inst, mouse: mouse)
            dispatch(inst, event: .fullscreenChanged(isFS), pointer: sample)
        }
    }

    private func reconcileScreens() {
        guard coordinator.isStarted else { return }
        let wasAnyOpen = coordinator.anyOpen
        let resolved = resolveNotchScreens(syntheticWidth: syntheticWidth)
        let mainDisplayId = NSScreen.main?.displayID
        var byId: [CGDirectDisplayID: NotchScreen] = [:]
        var descriptors: [NotchDisplayDescriptor] = []
        for ns in resolved {
            guard let id = ns.screen.displayID else { continue }
            byId[id] = ns
            let isFS = ns.screen.displayUUID
                .map { FullscreenDetector.shared.isFullscreen(displayUUID: $0) } ?? false
            descriptors.append(NotchDisplayDescriptor(
                displayId: id,
                isBuiltin: ns.screen.isBuiltin,
                isMain: id == mainDisplayId,
                isFullscreen: isFS
            ))
        }

        let plan = NotchCoordinatorMachine.reconcileScreens(&coordinator, descriptors: descriptors)

        for id in plan.removed {
            if let inst = instances.removeValue(forKey: id) {
                teardownInstance(inst)
            }
        }

        // Preserve live open/modal state on surviving displays; refresh frame, notch metrics,
        // and apply any fullscreen-change effects produced during screen reconciliation.
        let mouse = NSEvent.mouseLocation
        for id in plan.kept {
            guard let inst = instances[id], let ns = byId[id] else { continue }
            inst.screen = ns
            if inst.vm.closedNotchSize != ns.closedNotchSize {
                inst.vm.closedNotchSize = ns.closedNotchSize
            }
            if inst.vm.isSynthetic != ns.isSynthetic {
                inst.vm.isSynthetic = ns.isSynthetic
            }
            let maxHostH = expandedPanelFrame(for: ns).height
            if inst.vm.screenVisibleHeight != maxHostH {
                inst.vm.screenVisibleHeight = maxHostH
            }
            let current = coordinator.displays[id]
            let shouldBeOpen = current?.isOpen ?? false
            if shouldBeOpen {
                cancelPanelShrink(inst)
                ensurePanelBackingMode(.expanded, for: inst, display: true)
            } else {
                // Keep `.expanded` while a close-spring shrink timer is in flight;
                // otherwise re-anchor the `.compact` envelope to the updated screen geometry.
                ensurePanelBackingMode(inst.backingMode, for: inst, display: true)
            }
            NotchCoordinatorMachine.invalidatePointerSample(&coordinator, displayId: id)
            if let effects = plan.keptEffects[id], !effects.isEmpty {
                if let current = current, inst.vm.isOpen != current.isOpen {
                    if current.isOpen {
                        cancelPanelShrink(inst)
                        ensurePanelBackingMode(.expanded, for: inst, display: false)
                    }
                    inst.vm.isOpen = current.isOpen
                    if !current.isOpen {
                        schedulePanelShrink(inst)
                    }
                }
                applyEffects(effects, to: inst, pointer: pointerSample(for: inst, mouse: mouse), mouse: mouse)
            }
        }

        for desc in plan.added {
            guard let ns = byId[desc.displayId] else { continue }
            let isOpen = coordinator.displays[desc.displayId]?.isOpen ?? false
            let initialMode: NotchPanelBackingMode = isOpen ? .expanded : .compact
            let frame = (initialMode == .expanded)
                ? expandedPanelFrame(for: ns)
                : compactPanelFrame(for: ns, geometry: NotchGeometryState(), hasActiveWing: wingState.activeWing != nil)
            let panel = NotchPanel(contentRect: frame)
            let inst = NotchInstance(displayId: desc.displayId, panel: panel, screen: ns, backingMode: initialMode)
            inst.vm.closedNotchSize = ns.closedNotchSize
            inst.vm.isSynthetic = ns.isSynthetic
            inst.vm.screenVisibleHeight = expandedPanelFrame(for: ns).height
            inst.vm.isOpen = isOpen
            inst.vm.activeWing = wingState.activeWing
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
            panel.onCancelOperation = { [weak self, weak inst] in
                guard let self = self, let inst = inst else { return }
                self.dispatch(inst, event: .escapePressed)
            }
            inst.vm.onGeometryChanged = { [weak self, weak inst] in
                guard let self = self, let inst = inst else { return }
                self.syncCompactFrameIfNeeded(for: inst)
                NotchCoordinatorMachine.invalidatePointerSample(&self.coordinator, displayId: inst.displayId)
                self.applyPanelState()
            }

            let host = FirstMouseHostingView(rootView: NotchRootView(store: store, sessionStore: store.sessionStore, vm: inst.vm, onQuit: onQuit))
            host.sizingOptions = []
            host.translatesAutoresizingMaskIntoConstraints = true
            host.frame = NSRect(origin: .zero, size: frame.size)
            host.autoresizingMask = [.width, .height]
            panel.contentView = host
            panel.setFrame(frame, display: true)

            panel.alphaValue = 0
            panel.orderFrontRegardless()
            panel.enableFullscreenFloat()

            instances[desc.displayId] = inst
        }

        if coordinator.anyOpen {
            cancelIdleCacheTrim()
        } else if wasAnyOpen {
            scheduleIdleCacheTrim()
        }

        syncSessionMonitorActive()
        applyPanelState()
    }

    private func teardownInstance(_ inst: NotchInstance) {
        inst.vm.onGeometryChanged = nil
        inst.vm.onAcquireModalLock = nil
        inst.vm.onReleaseModalLock = nil
        inst.vm.onTapWing = nil
        inst.vm.onRequestClose = nil
        inst.panel.onCancelOperation = nil
        inst.vm.isOpen = false
        inst.vm.isPanelShown = false
        inst.openWork?.cancel(); inst.openWork = nil
        inst.closeWork?.cancel(); inst.closeWork = nil
        inst.shrinkWork?.cancel(); inst.shrinkWork = nil
        inst.panel.disableFullscreenFloat()
        inst.panel.contentView = nil
        inst.panel.orderOut(nil)
        inst.panel.close()
    }

    private func teardownAll() {
        for inst in instances.values {
            teardownInstance(inst)
        }
        instances.removeAll()
        syncSessionMonitorActive()
    }

    private func expandedPanelFrame(for ns: NotchScreen) -> NSRect {
        let f = ns.screen.frame
        let h = min(maxWindowSize.height, ns.screen.visibleFrame.height - 8)
        let w = min(maxWindowSize.width, f.width)
        return NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
    }

    private func compactPanelFrame(
        for ns: NotchScreen,
        geometry: NotchGeometryState,
        hasActiveWing: Bool
    ) -> NSRect {
        let f = ns.screen.frame
        let maxW = Double(min(maxWindowSize.width, f.width))
        let compact = NotchGeometryState.compactWindowSize(
            maxWidth: maxW,
            closedNotchWidth: Double(ns.closedNotchSize.width),
            closedNotchHeight: Double(ns.closedNotchSize.height),
            leftWingWidth: geometry.leftWingWidth,
            rightWingWidth: geometry.rightWingWidth,
            hasActiveWing: hasActiveWing
        )
        let maxH = max(60, min(maxWindowSize.height, ns.screen.visibleFrame.height - 8))
        let w = CGFloat(compact.width)
        let h = min(maxH, CGFloat(compact.height))
        return NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
    }

    private func compactPanelFrame(for inst: NotchInstance) -> NSRect {
        compactPanelFrame(
            for: inst.screen,
            geometry: inst.vm.geometry,
            hasActiveWing: inst.vm.activeWing != nil
        )
    }

    private func ensurePanelBackingMode(
        _ mode: NotchPanelBackingMode,
        for inst: NotchInstance,
        display: Bool = true
    ) {
        let targetFrame = (mode == .expanded)
            ? expandedPanelFrame(for: inst.screen)
            : compactPanelFrame(for: inst)
        inst.backingMode = mode
        if inst.panel.frame != targetFrame {
            inst.panel.setFrame(targetFrame, display: display)
        }
    }

    private func cancelPanelShrink(_ inst: NotchInstance) {
        inst.shrinkWork?.cancel()
        inst.shrinkWork = nil
    }

    private func schedulePanelShrink(_ inst: NotchInstance) {
        cancelPanelShrink(inst)
        let displayId = inst.displayId
        let work = DispatchWorkItem { [weak self, weak inst] in
            guard let self = self,
                  let inst = inst,
                  self.coordinator.isStarted,
                  self.coordinator.displays[displayId]?.isOpen == false else { return }
            inst.shrinkWork = nil
            self.ensurePanelBackingMode(.compact, for: inst, display: true)
        }
        inst.shrinkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchTiming.panelShrinkDelay, execute: work)
    }

    /// Keeps the closed `.compact` window envelope comfortably wide enough whenever a Live Wing
    /// or TPS sparkline expands the pill; grows immediately to prevent clipping and trims lazily
    /// after `NotchTiming.panelShrinkDelay` once a retracting wing finishes its spring.
    private func syncCompactFrameIfNeeded(for inst: NotchInstance) {
        guard inst.backingMode == .compact,
              !inst.vm.isOpen,
              coordinator.displays[inst.displayId]?.isOpen == false else { return }
        let target = compactPanelFrame(for: inst)
        let current = inst.panel.frame
        if target.width > current.width + 0.5
            || target.height > current.height + 0.5
            || abs(target.midX - current.midX) > 0.5
            || abs(target.maxY - current.maxY) > 0.5 {
            cancelPanelShrink(inst)
            inst.panel.setFrame(target, display: true)
        } else if target.width < current.width - 1.0 || target.height < current.height - 1.0 {
            schedulePanelShrink(inst)
        }
    }

    private func cancelIdleCacheTrim() {
        idleCacheTrimWork?.cancel()
        idleCacheTrimWork = nil
    }

    private func scheduleIdleCacheTrim() {
        cancelIdleCacheTrim()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.coordinator.isStarted, !self.coordinator.anyOpen else { return }
            self.idleCacheTrimWork = nil
            MainActor.assumeIsolated {
                TelemetryArtworkCache.shared.trim(to: 6)
            }
        }
        idleCacheTrimWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0, execute: work)
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

    private func state(for inst: NotchInstance) -> NotchState {
        coordinator.displays[inst.displayId] ?? NotchState()
    }

    private func pointerSample(for inst: NotchInstance,
                               mouse: NSPoint = NSEvent.mouseLocation) -> NotchPointerSample {
        let currentState = state(for: inst)
        let onScreen = hit(mouse, inst.screen.screen.frame)
        let inClickableWing = !currentState.isOpen
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
        guard coordinator.isStarted, var currentState = coordinator.displays[inst.displayId] else { return }
        let wasOpen = currentState.isOpen
        let effects = NotchMachine.reduce(&currentState, event: event)
        coordinator.displays[inst.displayId] = currentState
        if effects.isEmpty { return }

        if currentState.isOpen && (!wasOpen || inst.backingMode != .expanded) {
            cancelIdleCacheTrim()
            cancelPanelShrink(inst)
            ensurePanelBackingMode(.expanded, for: inst, display: false)
        }

        if inst.vm.isOpen != currentState.isOpen {
            inst.vm.isOpen = currentState.isOpen
        }

        if wasOpen && !currentState.isOpen {
            schedulePanelShrink(inst)
            if !coordinator.anyOpen {
                scheduleIdleCacheTrim()
            }
        }

        // Single-open exclusivity across displays: opening Display B closes Display A.
        if !wasOpen && currentState.isOpen {
            let others = NotchCoordinatorMachine.displaysToCloseForExclusivity(
                coordinator,
                openingDisplayId: inst.displayId
            )
            for otherId in others {
                if let otherInst = instances[otherId] {
                    dispatch(otherInst, event: .explicitClose, mouse: mouse)
                }
            }
        }

        applyEffects(effects, to: inst, pointer: pointer, mouse: mouse)
    }

    private func applyEffects(_ effects: [NotchEffect],
                              to inst: NotchInstance,
                              pointer: NotchPointerSample? = nil,
                              mouse: NSPoint = NSEvent.mouseLocation) {
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
            case .focusPanel:
                if inst.panel.isInteractive {
                    inst.panel.makeKey()
                }
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
        let anyOpen = coordinator.anyOpen
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
        let mainId = NSScreen.main?.displayID
        var mouseDisplayId: UInt32? = nil
        let descriptors: [NotchDisplayDescriptor] = instances.values.map { inst in
            if hit(mouse, inst.screen.screen.frame) {
                mouseDisplayId = inst.displayId
            }
            return NotchDisplayDescriptor(
                displayId: inst.displayId,
                isBuiltin: inst.screen.screen.isBuiltin,
                isMain: inst.displayId == mainId,
                isFullscreen: state(for: inst).isFullscreen
            )
        }
        guard let chosenId = NotchCoordinatorMachine.selectPrimaryDisplay(
            descriptors: descriptors,
            mouseDisplayId: mouseDisplayId
        ) else { return nil }
        return instances[chosenId]
    }

    // MARK: Mouse monitor

    private func installMouseMonitor() {
        removeMouseMonitor()
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleMouseEvent(event.type)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleMouseEvent(event.type)
            return event
        }
    }

    private func removeMouseMonitor() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    private func handleMouseEvent(_ type: NSEvent.EventType) {
        if type == .mouseMoved {
            handleMouseMoved()
        } else {
            handleMouseDown()
        }
    }

    private func handleMouseMoved() {
        guard coordinator.isStarted else { return }
        let mouse = NSEvent.mouseLocation
        for inst in instances.values {
            let sample = pointerSample(for: inst, mouse: mouse)
            dispatch(inst, event: .pointerMoved(sample), pointer: sample, mouse: mouse)
        }
    }

    private func handleMouseDown() {
        guard coordinator.isStarted, coordinator.anyOpen, NSApp.modalWindow == nil else { return }
        let mouse = NSEvent.mouseLocation
        for inst in instances.values {
            guard state(for: inst).isOpen else { continue }
            let sample = pointerSample(for: inst, mouse: mouse)
            if !sample.onScreen || !sample.inContentRect {
                dispatch(inst, event: .outsideClick, pointer: sample, mouse: mouse)
            }
        }
    }

    private func scheduleOpen(_ inst: NotchInstance) {
        guard inst.openWork == nil else { return }
        let work = DispatchWorkItem { [weak self, weak inst] in
            guard let self = self, let inst = inst, self.coordinator.isStarted else { return }
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
            guard let self = self, let inst = inst, self.coordinator.isStarted else { return }
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
    /// When idle or showing the working Output TPS wing (`activeWing == nil`),
    /// expand the hover band to include the full compact pill width so hovering
    /// over the widened TPS sparkline + readout reliably opens the notch.
    private func hoverRect(_ inst: NotchInstance) -> NSRect {
        let base = hoverRect(inst.screen)
        guard !state(for: inst).isOpen else { return base }
        let pillRect = closedWingRect(inst)
        if inst.vm.activeWing != nil {
            let wingMinX = min(base.minX, pillRect.minX)
            let rightLimit = inst.screen.screen.frame.midX + inst.screen.closedNotchSize.width / 2 + 8
            let trimmedWidth = max(40, rightLimit - wingMinX)
            return NSRect(x: wingMinX, y: base.minY, width: trimmedWidth, height: base.height)
        }
        let screenFrame = inst.screen.screen.frame
        let minX = max(screenFrame.minX, min(base.minX, pillRect.minX))
        let maxX = min(screenFrame.maxX, max(base.maxX, pillRect.maxX))
        return NSRect(x: minX, y: base.minY, width: max(base.width, maxX - minX), height: base.height)
    }

    private func closedWingRect(_ inst: NotchInstance) -> NSRect {
        let f = inst.screen.screen.frame
        let measured = inst.vm.geometry.contentSize(isOpen: false)
        guard measured.width > 1, measured.height > 1 else { return hoverRect(inst.screen) }
        let notchW = max(8, inst.screen.closedNotchSize.width)
        let pillH = max(24, inst.screen.closedNotchSize.height)
        let leftW = CGFloat(inst.vm.geometry.leftWingWidth)
        let rightW = CGFloat(inst.vm.geometry.rightWingWidth)
        let width = leftW + notchW + rightW
        let minX = f.midX - notchW / 2 - leftW
        return NSRect(x: minX, y: f.maxY - pillH, width: width, height: pillH)
    }

    private func contentRect(_ inst: NotchInstance) -> NSRect {
        let f = inst.screen.screen.frame
        let size = inst.vm.geometry.contentSize(isOpen: true)
        guard size.width > 1, size.height > 1 else { return hoverRect(inst.screen) }
        return NSRect(x: f.midX - CGFloat(size.width) / 2, y: f.maxY - CGFloat(size.height),
                      width: CGFloat(size.width), height: CGFloat(size.height))
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
        guard coordinator.isStarted else { return }
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
        guard coordinator.isStarted else { return }
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
                    guard let self = self, self.coordinator.isStarted else { return }
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
        var changed = false
        for inst in instances.values {
            if inst.vm.activeWing != wingState.activeWing {
                inst.vm.activeWing = wingState.activeWing
                syncCompactFrameIfNeeded(for: inst)
                NotchCoordinatorMachine.invalidatePointerSample(&coordinator, displayId: inst.displayId)
                changed = true
            }
        }
        if changed { applyPanelState() }
    }

    // MARK: Visibility + passthrough

    private func applyPanelState() {
        guard coordinator.isStarted else { return }
        let mouse = NSEvent.mouseLocation
        for inst in instances.values {
            applyPresentation(inst, pointer: pointerSample(for: inst, mouse: mouse))
        }
    }

    private func applyPresentation(_ inst: NotchInstance, pointer: NotchPointerSample) {
        let pres = NotchMachine.panelPresentation(for: state(for: inst), pointer: pointer)
        setVisible(inst, pres.visible)
        if inst.panel.ignoresMouseEvents != pres.ignoresMouseEvents {
            inst.panel.ignoresMouseEvents = pres.ignoresMouseEvents
        }
    }

    private func setVisible(_ inst: NotchInstance, _ visible: Bool) {
        if inst.vm.isPanelShown != visible {
            inst.vm.isPanelShown = visible
        }
        let transition = NotchCoordinatorMachine.updateVisibility(
            &coordinator,
            displayId: inst.displayId,
            visible: visible
        )
        guard transition.changed else { return }
        let target: CGFloat = visible ? 1 : 0
        if !transition.shouldAnimate || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            inst.panel.alphaValue = target
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                inst.panel.animator().alphaValue = target
            }
        }
    }
}
