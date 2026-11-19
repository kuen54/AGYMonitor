import SwiftUI
import AppKit

// Footer menus (language switcher + options) — AppKit NSMenu coordinators
// styled as bare hairline statusline controls matching AGY // TELEMETRY.

// MARK: - Language Switcher

struct LanguageSwitcher: NSViewRepresentable {
    @ObservedObject var store: UsageStore

    func makeNSView(context: Context) -> NSButton {
        let btn = NSButton(frame: NSRect(x: 0, y: 0, width: 26, height: 22))
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .semibold)
        btn.target = context.coordinator
        btn.action = #selector(Coordinator.showMenu(_:))
        btn.setContentHuggingPriority(.required, for: .horizontal)
        btn.widthAnchor.constraint(equalToConstant: 26).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return btn
    }

    func updateNSView(_ btn: NSButton, context: Context) {
        context.coordinator.notchVM = context.environment.notchViewModel
        let theme = context.environment.agyTheme
        let ink = NSColor(theme.inkSecondary)
        let titleAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .semibold),
            .foregroundColor: ink,
        ]
        btn.attributedTitle = NSAttributedString(string: store.language.displayName, attributes: titleAttr)
        btn.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    class Coordinator: NSObject, NSMenuDelegate {
        let store: UsageStore
        weak var notchVM: NotchViewModel?
        init(store: UsageStore) { self.store = store }

        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
            menu.delegate = self
            for lang in AppLanguage.allCases {
                let item = NSMenuItem(title: lang.displayName, action: #selector(pick(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = lang
                if lang == store.language { item.state = .on }
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        }

        @objc func pick(_ item: NSMenuItem) {
            if let lang = item.representedObject as? AppLanguage {
                store.setLanguage(lang)
            }
        }

        func menuWillOpen(_ menu: NSMenu) { notchVM?.acquireModalLock(.languageMenu) }
        func menuDidClose(_ menu: NSMenu) { notchVM?.releaseModalLock(.languageMenu) }
    }
}

// MARK: - Options Menu

/// Footer "⋯" menu: Display location, Theme preset, Status bar readout,
/// Global Hotkey (⌥⇧A), and durable local archive toggle & clear.
struct OptionsMenu: NSViewRepresentable {
    @ObservedObject var store: UsageStore
    let loc: Localizer

    func makeNSView(context: Context) -> NSButton {
        let btn = NSButton(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
        btn.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        btn.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
        btn.imageScaling = .scaleProportionallyDown
        btn.isBordered = false
        btn.target = context.coordinator
        btn.action = #selector(Coordinator.showMenu(_:))
        btn.setContentHuggingPriority(.required, for: .horizontal)
        btn.widthAnchor.constraint(equalToConstant: 24).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return btn
    }

    func updateNSView(_ btn: NSButton, context: Context) {
        context.coordinator.loc = loc
        context.coordinator.notchVM = context.environment.notchViewModel
        let theme = context.environment.agyTheme
        btn.contentTintColor = NSColor(theme.inkSecondary)
        btn.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator { Coordinator(store: store, loc: loc) }

    class Coordinator: NSObject, NSMenuDelegate {
        let store: UsageStore
        var loc: Localizer
        weak var notchVM: NotchViewModel?
        init(store: UsageStore, loc: Localizer) { self.store = store; self.loc = loc }

        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
            menu.delegate = self

            // Display location
            let modeHeader = NSMenuItem(title: loc("displayModeHeader"), action: nil, keyEquivalent: "")
            modeHeader.isEnabled = false
            menu.addItem(modeHeader)
            for mode in DisplayMode.allCases {
                let item = NSMenuItem(title: mode.label(loc),
                                      action: #selector(pickDisplayMode(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = mode.rawValue
                item.state = store.displayMode == mode ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())

            // Theme preset submenu
            let themeSubItem = NSMenuItem(title: loc("themeHeader"), action: nil, keyEquivalent: "")
            let themeMenu = NSMenu()
            for preset in TelemetryThemePreset.allCases {
                let item = NSMenuItem(title: preset.label(loc),
                                      action: #selector(pickThemePreset(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = preset.rawValue
                item.state = store.themePreset == preset ? .on : .off
                themeMenu.addItem(item)
            }
            themeSubItem.submenu = themeMenu
            menu.addItem(themeSubItem)

            // Visual style submenu (Instrument vs Classic)
            let visualSubItem = NSMenuItem(title: loc("visualModeHeader"), action: nil, keyEquivalent: "")
            let visualMenu = NSMenu()
            for vMode in TelemetryVisualMode.allCases {
                let item = NSMenuItem(title: vMode.label(loc),
                                      action: #selector(pickVisualMode(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = vMode.rawValue
                item.state = store.visualMode == vMode ? .on : .off
                visualMenu.addItem(item)
            }
            visualSubItem.submenu = visualMenu
            menu.addItem(visualSubItem)

            // Status bar readout submenu
            let metricSubItem = NSMenuItem(title: loc("metricHeader"), action: nil, keyEquivalent: "")
            let metricMenu = NSMenu()
            for metric in MenuBarMetricPreference.allCases {
                let item = NSMenuItem(title: metric.label(loc),
                                      action: #selector(pickMetric(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = metric.rawValue
                item.state = store.menuBarMetric == metric ? .on : .off
                metricMenu.addItem(item)
            }
            metricSubItem.submenu = metricMenu
            menu.addItem(metricSubItem)

            // Global Hotkey toggle
            let hk = NSMenuItem(title: loc("hotkeyToggle"),
                                action: #selector(toggleHotkey), keyEquivalent: "")
            hk.target = self
            hk.state = store.globalHotkeyEnabled ? .on : .off
            menu.addItem(hk)
            menu.addItem(.separator())

            // Archive section
            let toggle = NSMenuItem(title: loc("archiveToggle"),
                                    action: #selector(toggleArchive), keyEquivalent: "")
            toggle.target = self
            toggle.state = store.archiveHistoryLocally ? .on : .off
            menu.addItem(toggle)

            let count = store.archivedDayCount
            let noteTitle = count > 0 ? String(format: loc("archiveCount"), count) : loc("archiveNote")
            let note = NSMenuItem(title: noteTitle, action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)

            menu.addItem(.separator())

            let clear = NSMenuItem(title: loc("archiveClear"),
                                   action: #selector(clearArchive), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)

            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        }

        @objc func pickDisplayMode(_ item: NSMenuItem) {
            if let raw = item.representedObject as? String,
               let mode = DisplayMode(rawValue: raw) {
                store.setDisplayMode(mode)
            }
        }

        @objc func pickThemePreset(_ item: NSMenuItem) {
            if let raw = item.representedObject as? String,
               let preset = TelemetryThemePreset(rawValue: raw) {
                store.setThemePreset(preset)
            }
        }

        @objc func pickVisualMode(_ item: NSMenuItem) {
            if let raw = item.representedObject as? String,
               let vMode = TelemetryVisualMode(rawValue: raw) {
                store.setVisualMode(vMode)
            }
        }

        @objc func pickMetric(_ item: NSMenuItem) {
            if let raw = item.representedObject as? String,
               let metric = MenuBarMetricPreference(rawValue: raw) {
                store.setMenuBarMetric(metric)
            }
        }

        @objc func toggleHotkey() {
            store.setGlobalHotkeyEnabled(!store.globalHotkeyEnabled)
        }

        @objc func toggleArchive() {
            store.setArchiveHistoryLocally(!store.archiveHistoryLocally)
        }

        @objc func clearArchive() {
            notchVM?.acquireModalLock(.clearArchiveAlert)
            if notchVM != nil { NSApp.activate(ignoringOtherApps: true) }
            defer { notchVM?.releaseModalLock(.clearArchiveAlert) }

            let alert = NSAlert()
            alert.messageText = loc("archiveClearTitle")
            alert.informativeText = loc("archiveClearBody")
            alert.alertStyle = .warning
            alert.addButton(withTitle: loc("archiveClearConfirm"))
            alert.addButton(withTitle: loc("archiveClearCancel"))
            if alert.runModal().rawValue == 1000 {
                store.clearArchive()
            }
        }

        func menuWillOpen(_ menu: NSMenu) { notchVM?.acquireModalLock(.optionsMenu) }
        func menuDidClose(_ menu: NSMenu) { notchVM?.releaseModalLock(.optionsMenu) }
    }
}
