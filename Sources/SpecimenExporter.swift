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

// MARK: - Floating Swiss Telemetry Specimen Window Controller

@MainActor
final class SpecimenWindowController: NSObject, NSWindowDelegate {
    static let shared = SpecimenWindowController()

    private var window: NSWindow?
    private weak var observedStore: UsageStore?

    private override init() {
        super.init()
    }

    /// Opens or brings forward the floating Archival Specimen Exporter window.
    func present(store: UsageStore) {
        observedStore = store
        if store.yearTimeDays == nil {
            store.loadYearTime(store.viewingTimeYear)
        }

        if let existing = window {
            existing.contentView = NSHostingView(
                rootView: SpecimenExporterHostView(store: store) { [weak self] in
                    self?.window?.close()
                }
            )
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let hostView = SpecimenExporterHostView(store: store) { [weak self] in
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
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        PointingCursorCoordinator.shared.releaseAll()
    }
}

// MARK: - Specimen Exporter Utility Window Content

private struct SpecimenExporterHostView: View {
    @ObservedObject var store: UsageStore
    let onClose: () -> Void

    @Environment(\.colorScheme) private var systemScheme
    @State private var aspect: SpecimenAspect = .portrait4x5
    @State private var darkModeOverride: Bool? = nil
    @State private var feedbackLabel: String? = nil
    @State private var feedbackClearTask: DispatchWorkItem? = nil

    private var loc: Localizer { Localizer(language: store.language) }
    private var resolvedIsDark: Bool { darkModeOverride ?? (systemScheme == .dark) }
    private var instrumentHapticsEnabled: Bool {
        store.visualMode == .instrument && store.craftPreferences.hapticsEnabled
    }
    private var theme: AGYTheme {
        AGYTheme(preset: store.themePreset, colorScheme: resolvedIsDark ? .dark : .light, isNotch: false)
    }

    var body: some View {
        let snapshot = SpecimenCardSnapshot.from(store: store, isDark: resolvedIsDark)
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
                        Text(option.label(loc).uppercased())
                            .font(.system(size: 8.5, weight: selected ? .bold : .medium, design: .monospaced))
                            .tracking(0.5)
                            .foregroundColor(selected ? theme.invertedInk : theme.inkSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(selected ? theme.invertedBg : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard aspect != option else { return }
                                aspect = option
                                CraftEngine.shared.tickDetent(enabled: instrumentHapticsEnabled)
                            }
                    }
                }
                .overlay(Rectangle().stroke(theme.hairlineStrong, lineWidth: 0.75))

                // Light / Dark card appearance switch
                HStack(spacing: 0) {
                    appearanceChip(title: loc("specimenLightMode"), isDarkChoice: false)
                    appearanceChip(title: loc("specimenDarkMode"), isDarkChoice: true)
                }
                .overlay(Rectangle().stroke(theme.hairlineStrong, lineWidth: 0.75))
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
                ArchivalSpecimenCardView(snapshot: snapshot, aspect: aspect)
                    .scaleEffect(previewScale)
                    .frame(width: cardSize.width * previewScale, height: cardSize.height * previewScale)
                    .shadow(color: Color.black.opacity(resolvedIsDark ? 0.55 : 0.16), radius: 18, x: 0, y: 8)
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
                    if let feedback = feedbackLabel {
                        Text(feedback.uppercased())
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .tracking(0.6)
                            .foregroundColor(theme.accent)
                    } else {
                        Text("\(snapshot.periodLabel) · \(snapshot.archetype.kind.localizedTitle(loc).uppercased())")
                            .font(.system(size: 8.0, weight: .regular, design: .monospaced))
                            .foregroundColor(theme.inkMuted)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                actionButton(
                    title: feedbackLabel == loc("specimenCopied") ? loc("specimenCopied") : loc("specimenCopyPng"),
                    primary: false
                ) {
                    copyPNG(snapshot: snapshot)
                }

                actionButton(title: loc("specimenSavePng"), primary: true) {
                    savePNG(snapshot: snapshot)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(theme.canvas)
        }
        .frame(width: 560, height: 690)
        .background(theme.canvas)
        .overlay(
            Group {
                Button("") { copyPNG(snapshot: snapshot) }.keyboardShortcut("c", modifiers: .command)
                Button("") { savePNG(snapshot: snapshot) }.keyboardShortcut("s", modifiers: .command)
                Button("") { onClose() }.keyboardShortcut(.escape, modifiers: [])
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
        )
    }

    private func appearanceChip(title: String, isDarkChoice: Bool) -> some View {
        let selected = (resolvedIsDark == isDarkChoice)
        return Text(title.uppercased())
            .font(.system(size: 8.2, weight: selected ? .bold : .medium, design: .monospaced))
            .tracking(0.4)
            .foregroundColor(selected ? theme.invertedInk : theme.inkSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(selected ? theme.invertedBg : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture {
                guard resolvedIsDark != isDarkChoice else { return }
                darkModeOverride = isDarkChoice
                CraftEngine.shared.tickDetent(enabled: instrumentHapticsEnabled)
            }
    }

    private func actionButton(title: String, primary: Bool, action: @escaping () -> Void) -> some View {
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
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    private func copyPNG(snapshot: SpecimenCardSnapshot) {
        guard let rendered = SpecimenPNGExporter.render(snapshot: snapshot, aspect: aspect) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(rendered.pngData, forType: .png)
        if let tiff = rendered.image.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        pb.writeObjects([item])
        CraftEngine.shared.tickDetent(enabled: instrumentHapticsEnabled)
        flashFeedback(loc("specimenCopied"))
    }

    private func savePNG(snapshot: SpecimenCardSnapshot) {
        guard let rendered = SpecimenPNGExporter.render(snapshot: snapshot, aspect: aspect) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = String(
            format: "AGY-Specimen-%04d-%02d.png",
            snapshot.year,
            snapshot.month
        )
        let response = panel.runModal()
        guard response == .OK, let destURL = panel.url else { return }
        do {
            try rendered.pngData.write(to: destURL, options: .atomic)
            CraftEngine.shared.tickDetent(enabled: instrumentHapticsEnabled)
            flashFeedback(loc("specimenSaved"))
        } catch {
            return
        }
    }

    private func flashFeedback(_ text: String) {
        feedbackClearTask?.cancel()
        feedbackLabel = text
        let task = DispatchWorkItem {
            feedbackLabel = nil
        }
        feedbackClearTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: task)
    }
}
