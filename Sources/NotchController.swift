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
    var isFullscreen = false
    var revealArmed = false
    var openWork: DispatchWorkItem?
    var closeWork: DispatchWorkItem?
    var sizeObserver: AnyCancellable?

    init(panel: NotchPanel, screen: NotchScreen) {
        self.panel = panel
        self.screen = screen
    }
}

// MARK: - NotchController

final class NotchController: NSObject {
    private let store: UsageStore
    private let onQuit: () -> Void

    private let maxWindowSize = CGSize(width: 600, height: 860)
    private let syntheticWidth: CGFloat = 200
    private let hoverShoulder: CGFloat = 84
    private let revealEdge: CGFloat = 8

    private var instances: [CGDirectDisplayID: NotchInstance] = [:]

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var rebuildWork: DispatchWorkItem?

    init(store: UsageStore, onQuit: @escaping () -> Void) {
        self.store = store
        self.onQuit = onQuit
        super.init()
    }

    deinit { stop() }

    // MARK: Lifecycle

    func start() {
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
        rebuild()
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        rebuildWork?.cancel(); rebuildWork = nil
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
        refreshFullscreenStates()
        applyPanelState()
    }

    private func rebuild() {
        teardownAll()
        let resolved = resolveNotchScreens(syntheticWidth: syntheticWidth)
        guard !resolved.isEmpty else { return }

        for ns in resolved {
            guard let id = ns.screen.displayID else { continue }
            let frame = panelFrame(for: ns)
            let panel = NotchPanel(contentRect: frame)
            let inst = NotchInstance(panel: panel, screen: ns)
            inst.vm.closedNotchSize = ns.closedNotchSize
            inst.vm.isSynthetic = ns.isSynthetic
            inst.vm.isOpen = false
            inst.isFullscreen = ns.screen.displayUUID
                .map { FullscreenDetector.shared.isFullscreen(displayUUID: $0) } ?? false

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

            inst.sizeObserver = inst.vm.$contentSize
                .dropFirst()
                .removeDuplicates()
                .sink { [weak self] _ in self?.applyPanelState() }
        }
        applyPanelState()
    }

    private func teardownAll() {
        for inst in instances.values {
            inst.sizeObserver?.cancel(); inst.sizeObserver = nil
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

    // MARK: Fullscreen state

    private func refreshFullscreenStates() {
        for inst in instances.values {
            let wasFullscreen = inst.isFullscreen
            inst.isFullscreen = inst.screen.screen.displayUUID
                .map { FullscreenDetector.shared.isFullscreen(displayUUID: $0) } ?? false
            if inst.isFullscreen != wasFullscreen { inst.revealArmed = false }
        }
    }

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

    private func updateRevealArm(_ inst: NotchInstance, mouse: NSPoint, onThisScreen: Bool) {
        guard inst.isFullscreen else { inst.revealArmed = false; return }
        if hit(mouse, edgeRect(inst.screen)) {
            inst.revealArmed = true
        } else if onThisScreen, !inst.vm.isOpen, !hit(mouse, revealRect(inst.screen)) {
            inst.revealArmed = false
        }
    }

    private func hoverCanOpen(_ inst: NotchInstance) -> Bool {
        !inst.isFullscreen || inst.revealArmed
    }

    // MARK: Open / close (controller is the single authority)

    private func open(_ inst: NotchInstance) {
        guard !inst.vm.isOpen else { return }
        inst.vm.isOpen = true
        inst.panel.isInteractive = true
        applyPanelState()
        syncSessionMonitorActive()
        store.refresh()
    }

    private func close(_ inst: NotchInstance) {
        guard inst.vm.isOpen, !inst.vm.preventClose else { return }
        inst.vm.isOpen = false
        inst.panel.isInteractive = false
        if inst.panel.isKeyWindow { inst.panel.resignKey() }
        applyPanelState()
        syncSessionMonitorActive()
    }

    private func syncSessionMonitorActive() {
        store.setSessionMonitorActive(instances.values.contains { $0.vm.isOpen })
    }

    func reveal() { if let inst = primaryInstance() { open(inst) } }

    func toggle() {
        guard let inst = primaryInstance() else { return }
        inst.vm.isOpen ? close(inst) : open(inst)
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
            let onThisScreen = hit(mouse, inst.screen.screen.frame)
            updateRevealArm(inst, mouse: mouse, onThisScreen: onThisScreen)
            if inst.vm.isOpen {
                if !onThisScreen || !hit(mouse, contentRect(inst)) {
                    scheduleClose(inst)
                } else {
                    cancelClose(inst)
                }
            } else {
                if onThisScreen && hit(mouse, hoverRect(inst.screen)) && hoverCanOpen(inst) {
                    scheduleOpen(inst)
                } else {
                    cancelOpen(inst)
                }
            }
        }
        applyPanelState()
    }

    private func scheduleOpen(_ inst: NotchInstance) {
        guard inst.openWork == nil else { return }
        let work = DispatchWorkItem { [weak self, weak inst] in
            guard let self = self, let inst = inst else { return }
            inst.openWork = nil
            let mouse = NSEvent.mouseLocation
            if self.hit(mouse, inst.screen.screen.frame),
               self.hit(mouse, self.hoverRect(inst.screen)),
               self.hoverCanOpen(inst) {
                self.open(inst)
            }
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
            if !self.hit(NSEvent.mouseLocation, self.contentRect(inst)) {
                self.close(inst)
            }
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

    private func contentRect(_ inst: NotchInstance) -> NSRect {
        let f = inst.screen.screen.frame
        let size = inst.vm.contentSize
        guard size.width > 1, size.height > 1 else { return hoverRect(inst.screen) }
        return NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height,
                      width: size.width, height: size.height)
    }

    // MARK: Visibility + passthrough

    private func applyPanelState() {
        let mouse = NSEvent.mouseLocation
        for inst in instances.values {
            let visible = !inst.isFullscreen
                || inst.vm.isOpen
                || (inst.revealArmed && hit(mouse, revealRect(inst.screen)))
            setVisible(inst, visible)
            if !visible {
                inst.panel.ignoresMouseEvents = true
            } else if inst.vm.isOpen {
                inst.panel.ignoresMouseEvents = !hit(mouse, contentRect(inst))
            } else {
                inst.panel.ignoresMouseEvents = !hit(mouse, hoverRect(inst.screen))
            }
        }
    }

    private func setVisible(_ inst: NotchInstance, _ visible: Bool) {
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
