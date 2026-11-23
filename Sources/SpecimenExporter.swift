import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Specimen PNG Renderer (@2x ImageRenderer)

enum SpecimenPNGExporter {
    /// Renders `ArchivalSpecimenCardView` at Retina `@2x` scale (`1200×1500` or `1600×900` px)
    /// into crisp PNG bytes and an `NSImage`.
    @MainActor
    static func render(
        snapshot: SpecimenCardSnapshot,
        aspect: SpecimenAspect
    ) -> (pngData: Data, image: NSImage)? {
        let card = ArchivalSpecimenCardView(snapshot: snapshot, aspect: aspect)
            .environment(\.telemetryStaticRender, true)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2.0
        guard let cgImage = renderer.cgImage else { return nil }

        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = rep.representation(using: .png, properties: [:]) else { return nil }
        let logical = aspect.logicalSize
        let image = NSImage(cgImage: cgImage, size: NSSize(width: logical.width, height: logical.height))
        return (pngData, image)
    }
}

// MARK: - Specimen Exporter Controller Model (backed by SpecimenExporterMachine)

@MainActor
private final class SpecimenExporterModel: ObservableObject {
    @Published private(set) var state = SpecimenExporterState()

    weak var hostWindow: NSWindow?

    private var feedbackClearWork: DispatchWorkItem?
    private var pendingSaveSnapshot: SpecimenCardSnapshot?
    private var pendingSaveHapticsEnabled: Bool = false

    static let cursorTokens: [String] = [
        "specimen-aspect",
        "specimen-appearance",
        "specimen-copy",
        "specimen-save",
        "specimen-close",
    ]

    func releaseCursorTokens() {
        for token in Self.cursorTokens {
            PointingCursorCoordinator.shared.setPointing(false, token: token)
        }
    }

    func dispatch(_ event: SpecimenExporterEvent) {
        let effects = SpecimenExporterMachine.reduce(&state, event: event)
        for effect in effects {
            switch effect {
            case .cancelFeedbackDismiss:
                feedbackClearWork?.cancel()
                feedbackClearWork = nil

            case .scheduleFeedbackDismiss(let token, let delay):
                feedbackClearWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    self.feedbackClearWork = nil
                    self.dispatch(.dismissFeedback(token: token))
                }
                feedbackClearWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)

            case .showSavePanel:
                presentSavePanel()
            }
        }
    }

    func copyPNG(snapshot: SpecimenCardSnapshot, hapticsEnabled: Bool) {
        guard let rendered = SpecimenPNGExporter.render(snapshot: snapshot, aspect: state.aspect) else {
            dispatch(.copyFailed)
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(rendered.pngData, forType: .png)
        if let tiff = rendered.image.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        if pb.writeObjects([item]) {
            CraftEngine.shared.tickDetent(enabled: hapticsEnabled)
            dispatch(.copySucceeded)
        } else {
            dispatch(.copyFailed)
        }
    }

    func requestSave(snapshot: SpecimenCardSnapshot, hapticsEnabled: Bool) {
        guard state.exportPhase == .idle else { return }
        pendingSaveSnapshot = snapshot
        pendingSaveHapticsEnabled = hapticsEnabled
        dispatch(.beginSave)
    }

    private func presentSavePanel() {
        guard let snapshot = pendingSaveSnapshot else {
            dispatch(.saveCancelled)
            return
        }
        let hapticsEnabled = pendingSaveHapticsEnabled
        pendingSaveSnapshot = nil
        pendingSaveHapticsEnabled = false

        guard let rendered = SpecimenPNGExporter.render(snapshot: snapshot, aspect: state.aspect) else {
            dispatch(.saveCompleted(succeeded: false))
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = String(
            format: "AGY-Specimen-%04d-%02d.png",
            snapshot.year,
            snapshot.month
        )

        PointingCursorCoordinator.shared.setPointing(false, token: "specimen-save")

        let pngData = rendered.pngData
        let handleCompletion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            let destURL = panel.url
            Task { @MainActor [weak self] in
                self?.handleSaveResponse(
                    response,
                    url: destURL,
                    pngData: pngData,
                    hapticsEnabled: hapticsEnabled
                )
            }
        }

        if let hostWindow = hostWindow, hostWindow.isVisible {
            panel.beginSheetModal(for: hostWindow, completionHandler: handleCompletion)
        } else {
            panel.level = .modalPanel
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.begin(completionHandler: handleCompletion)
        }
    }

    private func handleSaveResponse(
        _ response: NSApplication.ModalResponse,
        url: URL?,
        pngData: Data,
        hapticsEnabled: Bool
    ) {
        guard response == .OK, let destURL = url else {
            dispatch(.saveCancelled)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let succeeded: Bool
            do {
                try pngData.write(to: destURL, options: .atomic)
                succeeded = true
            } catch {
                succeeded = false
            }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if succeeded {
                    CraftEngine.shared.tickDetent(enabled: hapticsEnabled)
                }
                self.dispatch(.saveCompleted(succeeded: succeeded))
            }
        }
    }
}

// MARK: - Floating Swiss Telemetry Specimen Window Controller

@MainActor
final class SpecimenWindowController: NSObject, NSWindowDelegate {
    static let shared = SpecimenWindowController()

    private let model = SpecimenExporterModel()
    private var window: NSWindow?
    private weak var observedStore: UsageStore?

    private override init() {
        super.init()
    }

    /// Opens or brings forward the floating Archival Specimen Exporter window.
    /// Re-pressing `⌘E` while already open dispatches `.present` without replacing
    /// `existing.contentView` or resetting the user's chosen aspect/appearance.
    func present(store: UsageStore) {
        let storeChanged = (observedStore !== store)
        observedStore = store
        if store.viewingTimeYear != store.viewingYear || store.yearTimeDays == nil {
            store.loadYearTime(store.viewingYear)
        }

        model.dispatch(.present)

        if let existing = window {
            model.hostWindow = existing
            if storeChanged {
                existing.contentView = NSHostingView(
                    rootView: SpecimenExporterHostView(store: store, model: model) { [weak self] in
                        self?.window?.close()
                    }
                )
            }
            if #available(macOS 14.0, *) {
                NSApp.activate()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
            if existing.isMiniaturized {
                existing.deminiaturize(nil)
            }
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let hostView = SpecimenExporterHostView(store: store, model: model) { [weak self] in
            self?.window?.close()
        }
        let hosting = NSHostingView(rootView: hostView)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 690),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        win.backgroundColor = .clear
        win.contentView = hosting
        win.delegate = self
        win.center()

        self.window = win
        model.hostWindow = win
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        win.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.hostWindow = nil
        model.dispatch(.dismiss)
        model.releaseCursorTokens()
    }
}

// MARK: - Specimen Exporter Utility Window Content

private struct SpecimenExporterHostView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var model: SpecimenExporterModel
    let onClose: () -> Void

    @Environment(\.colorScheme) private var systemScheme

    private var loc: Localizer { Localizer(language: store.language) }
    private var aspect: SpecimenAspect { model.state.aspect }
    private var resolvedIsDark: Bool {
        model.state.appearance.resolvedIsDark(systemIsDark: systemScheme == .dark)
    }
    private var isSaving: Bool { model.state.exportPhase == .saving }
    private var instrumentHapticsEnabled: Bool {
        store.visualMode == .instrument && store.craftPreferences.hapticsEnabled
    }
    private var theme: AGYTheme {
        AGYTheme(preset: store.themePreset, colorScheme: resolvedIsDark ? .dark : .light, isNotch: false)
    }

    private var feedbackDisplay: (text: String, isError: Bool)? {
        guard let kind = model.state.feedbackKind else { return nil }
        switch kind {
        case .copied:
            return (loc("specimenCopied"), false)
        case .saved:
            return (loc("specimenSaved"), false)
        case .renderFailed:
            return (loc("specimenRenderFailed"), true)
        case .saveFailed:
            return (loc("specimenSaveFailed"), true)
        }
    }

    var body: some View {
        let isLoadingYear = ((store.yearTimeDays == nil || store.viewingTimeYear != store.viewingYear) && store.yearLoadPhase.isLoading)
        let snapshot: SpecimenCardSnapshot? = isLoadingYear
            ? nil
            : SpecimenCardSnapshot.from(store: store, isDark: resolvedIsDark)
        let cardSize = aspect.logicalSize
        let previewBox = CGSize(width: 512, height: 520)
        let previewScale = min(previewBox.width / cardSize.width, previewBox.height / cardSize.height)

        VStack(spacing: 0) {
            // Sleek Swiss Telemetry utility titlebar
            HStack(spacing: 10) {
                Spacer()
                    .frame(width: 62)

                HStack(spacing: 6) {
                    LogoShape()
                        .fill(theme.accent)
                        .frame(width: 11, height: 11)
                    Text(loc("specimenWindowTitle").uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.3)
                        .foregroundColor(theme.inkPrimary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                // Aspect switcher (4:5 Portrait / 16:9 Wide)
                HStack(spacing: 0) {
                    ForEach(SpecimenAspect.allCases, id: \.self) { option in
                        let selected = (aspect == option)
                        let optionLabel = option.label(loc)
                        Text(optionLabel.uppercased())
                            .font(.system(size: 8.5, weight: selected ? .bold : .medium, design: .monospaced))
                            .tracking(0.5)
                            .foregroundColor(selected ? theme.invertedInk : theme.inkSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(selected ? theme.invertedBg : Color.clear)
                            .contentShape(Rectangle())
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(optionLabel)
                            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                            .onTapGesture {
                                guard aspect != option else { return }
                                model.dispatch(.setAspect(option))
                                CraftEngine.shared.tickDetent(enabled: instrumentHapticsEnabled)
                            }
                    }
                }
                .overlay(Rectangle().stroke(theme.hairlineStrong, lineWidth: 0.75))
                .onHover { inside in
                    PointingCursorCoordinator.shared.setPointing(inside, token: "specimen-aspect")
                }

                // Light / Dark card appearance switch
                HStack(spacing: 0) {
                    appearanceChip(title: loc("specimenLightMode"), choice: .light)
                    appearanceChip(title: loc("specimenDarkMode"), choice: .dark)
                }
                .overlay(Rectangle().stroke(theme.hairlineStrong, lineWidth: 0.75))
                .onHover { inside in
                    PointingCursorCoordinator.shared.setPointing(inside, token: "specimen-appearance")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 11)
            .padding(.bottom, 10)
            .background(theme.canvas)

            Rectangle()
                .fill(theme.hairline)
                .frame(height: 1)

            // Live Specimen Preview Stage
            ZStack {
                theme.surface
                if let snapshot = snapshot {
                    ArchivalSpecimenCardView(snapshot: snapshot, aspect: aspect)
                        .scaleEffect(previewScale)
                        .frame(width: cardSize.width * previewScale, height: cardSize.height * previewScale)
                        .shadow(color: Color.black.opacity(resolvedIsDark ? 0.55 : 0.16), radius: 18, x: 0, y: 8)
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        HStack(spacing: 6) {
                            Rectangle()
                                .fill(theme.accent)
                                .frame(width: 4, height: 4)
                            Text(loc("timeLoadingYear").uppercased())
                                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                .tracking(0.9)
                                .foregroundColor(theme.inkSecondary)
                        }
                    }
                    .frame(width: cardSize.width * previewScale, height: cardSize.height * previewScale)
                    .background(theme.canvas)
                    .overlay(Rectangle().stroke(theme.hairlineStrong, lineWidth: 0.85))
                    .shadow(color: Color.black.opacity(resolvedIsDark ? 0.40 : 0.10), radius: 14, x: 0, y: 6)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 556)

            Rectangle()
                .fill(theme.hairline)
                .frame(height: 1)

            // Action Footer
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(aspect.exportPixelLabel)
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .tracking(0.7)
                        .foregroundColor(theme.inkSecondary)
                    if let feedback = feedbackDisplay {
                        Text(feedback.text.uppercased())
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .tracking(0.6)
                            .foregroundColor(feedback.isError ? theme.signalRed : theme.accent)
                    } else if let snapshot = snapshot {
                        Text("\(snapshot.periodLabel) · \(snapshot.archetype.kind.localizedTitle(loc).uppercased())")
                            .font(.system(size: 8.0, weight: .regular, design: .monospaced))
                            .foregroundColor(theme.inkMuted)
                            .lineLimit(1)
                    } else {
                        Text(loc("timeLoadingYear").uppercased())
                            .font(.system(size: 8.0, weight: .regular, design: .monospaced))
                            .foregroundColor(theme.inkMuted)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                actionButton(
                    title: model.state.feedbackKind == .copied ? loc("specimenCopied") : loc("specimenCopyPng"),
                    primary: false,
                    enabled: snapshot != nil,
                    cursorToken: "specimen-copy"
                ) {
                    guard let snapshot = snapshot else { return }
                    model.copyPNG(snapshot: snapshot, hapticsEnabled: instrumentHapticsEnabled)
                }

                actionButton(
                    title: loc("specimenSavePng"),
                    primary: true,
                    enabled: !isSaving && snapshot != nil,
                    cursorToken: "specimen-save"
                ) {
                    guard let snapshot = snapshot else { return }
                    model.requestSave(snapshot: snapshot, hapticsEnabled: instrumentHapticsEnabled)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(theme.canvas)
        }
        .frame(width: 560, height: 690)
        .background(theme.canvas)
        .onChange(of: model.state.exportPhase) { phase in
            if phase == .saving {
                PointingCursorCoordinator.shared.setPointing(false, token: "specimen-save")
            }
        }
        .onChange(of: store.viewingYear) { nextYear in
            guard model.state.isPresented else { return }
            if store.viewingTimeYear != nextYear || store.yearTimeDays == nil {
                store.loadYearTime(nextYear)
            }
        }
        .onDisappear {
            model.releaseCursorTokens()
        }
        .overlay(
            Group {
                Button(loc("specimenCopyPng")) {
                    guard let snapshot = snapshot else { return }
                    model.copyPNG(snapshot: snapshot, hapticsEnabled: instrumentHapticsEnabled)
                }
                .accessibilityLabel(loc("specimenCopyPng"))
                .accessibilityAddTraits(.isButton)
                .keyboardShortcut("c", modifiers: .command)

                Button(loc("specimenSavePng")) {
                    guard let snapshot = snapshot else { return }
                    model.requestSave(snapshot: snapshot, hapticsEnabled: instrumentHapticsEnabled)
                }
                .accessibilityLabel(loc("specimenSavePng"))
                .accessibilityAddTraits(.isButton)
                .keyboardShortcut("s", modifiers: .command)

                Button(loc("specimenClose")) {
                    PointingCursorCoordinator.shared.setPointing(false, token: "specimen-close")
                    onClose()
                }
                .accessibilityLabel(loc("specimenClose"))
                .accessibilityAddTraits(.isButton)
                .keyboardShortcut(.escape, modifiers: [])

                Button(loc("specimenClose")) {
                    PointingCursorCoordinator.shared.setPointing(false, token: "specimen-close")
                    onClose()
                }
                .accessibilityLabel(loc("specimenClose"))
                .accessibilityAddTraits(.isButton)
                .keyboardShortcut("w", modifiers: .command)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
        )
    }

    private func appearanceChip(title: String, choice: SpecimenAppearanceChoice) -> some View {
        let isDarkChoice = (choice == .dark)
        let selected = (resolvedIsDark == isDarkChoice)
        return Text(title.uppercased())
            .font(.system(size: 8.2, weight: selected ? .bold : .medium, design: .monospaced))
            .tracking(0.4)
            .foregroundColor(selected ? theme.invertedInk : theme.inkSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(selected ? theme.invertedBg : Color.clear)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .onTapGesture {
                guard resolvedIsDark != isDarkChoice else { return }
                model.dispatch(.setAppearance(choice))
                CraftEngine.shared.tickDetent(enabled: instrumentHapticsEnabled)
            }
    }

    private func actionButton(
        title: String,
        primary: Bool,
        enabled: Bool,
        cursorToken: String,
        action: @escaping () -> Void
    ) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9.2, weight: .bold, design: .monospaced))
            .tracking(0.7)
            .foregroundColor(primary ? theme.invertedInk : theme.inkPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(primary ? theme.accent : theme.surfaceRaised)
            .overlay(
                Rectangle().stroke(
                    primary ? theme.accent : theme.hairlineStrong,
                    lineWidth: 0.85
                )
            )
            .opacity(enabled ? 1.0 : 0.55)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
            .onHover { inside in
                PointingCursorCoordinator.shared.setPointing(inside && enabled, token: cursorToken)
            }
            .onTapGesture {
                guard enabled else { return }
                action()
            }
    }
}
