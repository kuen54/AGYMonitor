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

/// Footer "⋯" menu: 5-row top-level menu abstracting Specimen Card export,
/// Appearance, Craft & Wallpaper, Data & Shortcuts, and Updates (plus a
/// conditional top-level Update Available banner when a newer release exists).
struct OptionsMenu: NSViewRepresentable {
    @ObservedObject var store: UsageStore
    let loc: Localizer
    var onClose: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSButton {
        let btn = NSButton(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
        let desc = loc("optionsMenuHelp")
        btn.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: desc)
        btn.setAccessibilityLabel(desc)
        btn.toolTip = desc
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
        context.coordinator.onClose = onClose
        let desc = loc("optionsMenuHelp")
        if btn.toolTip != desc {
            btn.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: desc)
            btn.setAccessibilityLabel(desc)
            btn.toolTip = desc
        }
        let theme = context.environment.agyTheme
        btn.contentTintColor = NSColor(theme.inkSecondary)
        btn.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator { Coordinator(store: store, loc: loc, onClose: onClose) }

    class Coordinator: NSObject, NSMenuDelegate {
        let store: UsageStore
        var loc: Localizer
        var onClose: (() -> Void)?
        weak var notchVM: NotchViewModel?
        init(store: UsageStore, loc: Localizer, onClose: (() -> Void)? = nil) {
            self.store = store
            self.loc = loc
            self.onClose = onClose
        }

        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.delegate = self

            // 1. Primary Action: Export Specimen Card (⌘E)
            let exportSpecimen = NSMenuItem(
                title: loc("menuExportSpecimen"),
                action: #selector(exportSpecimenCard),
                keyEquivalent: "e"
            )
            exportSpecimen.keyEquivalentModifierMask = .command
            exportSpecimen.target = self
            menu.addItem(exportSpecimen)
            menu.addItem(.separator())

            // 2. Appearance ▸
            menu.addItem(makeSubmenuItem(title: loc("menuAppearance"), submenu: makeAppearanceSubmenu()))

            // 3. Craft & Wallpaper ▸
            menu.addItem(makeSubmenuItem(title: loc("menuCraftAndWallpaper"), submenu: makeCraftSubmenu()))

            // 4. Data & Shortcuts ▸
            menu.addItem(makeSubmenuItem(title: loc("menuDataAndShortcuts"), submenu: makeDataSubmenu()))
            menu.addItem(.separator())

            // 5. Conditional Update Available banner + Updates · vX.Y.Z ▸
            let updateState = store.updateService.state
            if let available = updateState.availableUpdate {
                let openUpdate = NSMenuItem(
                    title: String(format: loc("updateMenuAvailableFmt"), available.version.displayTag),
                    action: #selector(openAvailableUpdate),
                    keyEquivalent: ""
                )
                openUpdate.target = self
                menu.addItem(openUpdate)
            }

            let updatesTitle = String(format: loc("menuUpdatesFmt"), updateState.currentVersion.displayTag)
            menu.addItem(makeSubmenuItem(
                title: updatesTitle,
                submenu: makeUpdatesSubmenu(updateState: updateState)
            ))

            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        }

        // MARK: - Submenu Builders

        private func makeSubmenuItem(title: String, submenu: NSMenu) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            return item
        }

        private func makeDisabledLabelItem(title: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }

        private func makeAppearanceSubmenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false

            // Display location
            menu.addItem(makeDisabledLabelItem(title: loc("displayModeHeader")))
            for mode in DisplayMode.allCases {
                let item = NSMenuItem(
                    title: mode.label(loc),
                    action: #selector(pickDisplayMode(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = mode.rawValue
                item.state = store.displayMode == mode ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())

            // Theme ▸
            let themeMenu = NSMenu()
            for preset in TelemetryThemePreset.allCases {
                let item = NSMenuItem(
                    title: preset.label(loc),
                    action: #selector(pickThemePreset(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = preset.rawValue
                item.state = store.themePreset == preset ? .on : .off
                themeMenu.addItem(item)
            }
            menu.addItem(makeSubmenuItem(title: loc("themeHeader"), submenu: themeMenu))

            // Visual Style ▸
            let visualMenu = NSMenu()
            for vMode in TelemetryVisualMode.allCases {
                let item = NSMenuItem(
                    title: vMode.label(loc),
                    action: #selector(pickVisualMode(_:)),
                    keyEquivalent: vMode == .instrument ? "i" : ""
                )
                if vMode == .instrument {
                    item.keyEquivalentModifierMask = .command
                }
                item.target = self
                item.representedObject = vMode.rawValue
                item.state = store.visualMode == vMode ? .on : .off
                visualMenu.addItem(item)
            }
            menu.addItem(makeSubmenuItem(title: loc("visualModeHeader"), submenu: visualMenu))

            // Status Bar Readout ▸
            let metricMenu = NSMenu()
            for metric in MenuBarMetricPreference.allCases {
                let item = NSMenuItem(
                    title: metric.label(loc),
                    action: #selector(pickMetric(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = metric.rawValue
                item.state = store.menuBarMetric == metric ? .on : .off
                metricMenu.addItem(item)
            }
            menu.addItem(makeSubmenuItem(title: loc("metricHeader"), submenu: metricMenu))

            return menu
        }

        private func makeCraftSubmenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            let craftPrefs = store.craftPreferences

            let hapticsItem = NSMenuItem(
                title: loc("craftHapticsToggle"),
                action: #selector(toggleHaptics),
                keyEquivalent: ""
            )
            hapticsItem.target = self
            hapticsItem.state = craftPrefs.hapticsEnabled ? .on : .off
            menu.addItem(hapticsItem)

            if store.visualMode != .instrument {
                menu.addItem(makeDisabledLabelItem(title: loc("craftHapticsInstrumentNote")))
            }

            let chimesItem = NSMenuItem(
                title: loc("craftChimesToggle"),
                action: #selector(toggleAcousticChimes),
                keyEquivalent: ""
            )
            chimesItem.target = self
            chimesItem.state = craftPrefs.acousticChimesEnabled ? .on : .off
            menu.addItem(chimesItem)

            menu.addItem(.separator())

            let dailyWpItem = NSMenuItem(
                title: loc("craftDailyWallpaperToggle"),
                action: #selector(toggleDailyWallpaper),
                keyEquivalent: ""
            )
            dailyWpItem.target = self
            dailyWpItem.state = craftPrefs.dailyWallpaperEnabled ? .on : .off
            menu.addItem(dailyWpItem)

            let wpStyleMenu = NSMenu()
            for style in BlueprintWallpaperStyle.allCases {
                let title = (style == .darkMonolith) ? loc("craftWallpaperDark") : loc("craftWallpaperLight")
                let item = NSMenuItem(
                    title: title,
                    action: #selector(pickWallpaperStyle(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = style.rawValue
                item.state = craftPrefs.wallpaperStyle == style ? .on : .off
                wpStyleMenu.addItem(item)
            }
            menu.addItem(makeSubmenuItem(title: loc("craftWallpaperStyleHeader"), submenu: wpStyleMenu))

            let applyWpItem = NSMenuItem(
                title: loc("craftWallpaperApplyNow"),
                action: #selector(applyBlueprintWallpaperNow),
                keyEquivalent: ""
            )
            applyWpItem.target = self
            menu.addItem(applyWpItem)

            let canRestoreWallpaper = store.canRestorePreviousWallpaper
            let restoreWpItem = NSMenuItem(
                title: loc("craftWallpaperRestore"),
                action: canRestoreWallpaper ? #selector(restorePreviousWallpaper) : nil,
                keyEquivalent: ""
            )
            restoreWpItem.target = canRestoreWallpaper ? self : nil
            restoreWpItem.isEnabled = canRestoreWallpaper
            menu.addItem(restoreWpItem)

            return menu
        }

        private func makeDataSubmenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false

            let hotkeyItem = NSMenuItem(
                title: loc("hotkeyToggle"),
                action: #selector(toggleHotkey),
                keyEquivalent: ""
            )
            hotkeyItem.target = self
            hotkeyItem.state = store.globalHotkeyEnabled ? .on : .off
            menu.addItem(hotkeyItem)

            menu.addItem(.separator())

            let archiveToggle = NSMenuItem(
                title: loc("archiveToggle"),
                action: #selector(toggleArchive),
                keyEquivalent: ""
            )
            archiveToggle.target = self
            archiveToggle.state = store.archiveHistoryLocally ? .on : .off
            menu.addItem(archiveToggle)

            let count = store.archivedDayCount
            let noteTitle = count > 0 ? String(format: loc("archiveCount"), count) : loc("archiveNote")
            menu.addItem(makeDisabledLabelItem(title: noteTitle))

            let clearItem = NSMenuItem(
                title: loc("archiveClear"),
                action: #selector(clearArchive),
                keyEquivalent: ""
            )
            clearItem.target = self
            menu.addItem(clearItem)

            return menu
        }

        private func makeUpdatesSubmenu(updateState: UpdateCheckerState) -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false

            let checkTitle = updateState.isManualChecking
                ? loc("updateMenuChecking")
                : loc("updateMenuCheck")
            let checkUpdates = NSMenuItem(
                title: checkTitle,
                action: updateState.isManualChecking ? nil : #selector(checkForUpdates),
                keyEquivalent: ""
            )
            checkUpdates.target = updateState.isManualChecking ? nil : self
            checkUpdates.isEnabled = !updateState.isManualChecking
            menu.addItem(checkUpdates)

            let autoCheck = NSMenuItem(
                title: loc("updateMenuAutoCheck"),
                action: #selector(toggleAutoUpdateCheck),
                keyEquivalent: ""
            )
            autoCheck.target = self
            autoCheck.state = updateState.autoCheckEnabled ? .on : .off
            menu.addItem(autoCheck)

            menu.addItem(.separator())

            let versionTitle = String(format: loc("updateMenuVersionFmt"), updateState.currentVersion.displayTag)
            menu.addItem(makeDisabledLabelItem(title: versionTitle))

            return menu
        }

        // MARK: - Actions

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

        @objc func exportSpecimenCard() {
            notchVM?.releaseModalLock(.optionsMenu)
            if let onClose = onClose {
                onClose()
            } else {
                notchVM?.onRequestClose?()
            }
            let targetStore = store
            Task { @MainActor in
                SpecimenWindowController.shared.present(store: targetStore)
            }
        }

        @MainActor @objc func toggleHaptics() {
            let next = !store.craftPreferences.hapticsEnabled
            store.setHapticsEnabled(next)
            if next && store.visualMode == .instrument {
                CraftEngine.shared.tickDetent(enabled: true)
            } else if !next {
                CraftEngine.shared.cancelPendingHapticCadence()
            }
        }

        @objc func toggleAcousticChimes() {
            let next = !store.craftPreferences.acousticChimesEnabled
            store.setAcousticChimesEnabled(next)
            if next {
                Task { @MainActor in
                    CraftEngine.shared.playCue(.turnDoneChord, enabled: true)
                }
            }
        }

        @objc func toggleDailyWallpaper() {
            store.setDailyWallpaperEnabled(!store.craftPreferences.dailyWallpaperEnabled)
        }

        @objc func pickWallpaperStyle(_ item: NSMenuItem) {
            if let raw = item.representedObject as? String,
               let style = BlueprintWallpaperStyle(rawValue: raw) {
                store.setWallpaperStyle(style)
            }
        }

        @objc func applyBlueprintWallpaperNow() {
            store.applyBlueprintWallpaperNow()
        }

        @objc func restorePreviousWallpaper() {
            store.restorePreviousWallpaper()
        }

        @objc func toggleArchive() {
            store.setArchiveHistoryLocally(!store.archiveHistoryLocally)
        }

        @objc func openAvailableUpdate() {
            store.updateService.openReleasePage()
        }

        @objc func checkForUpdates() {
            store.checkForUpdatesManually()
        }

        @objc func toggleAutoUpdateCheck() {
            store.updateService.setAutoCheckEnabled(!store.updateService.state.autoCheckEnabled)
        }

        @objc func clearArchive() {
            notchVM?.releaseModalLock(.optionsMenu)
            if let onClose = onClose {
                onClose()
            } else {
                notchVM?.onRequestClose?()
            }

            let targetStore = store
            let targetLoc = loc
            DispatchQueue.main.async {
                if #available(macOS 14.0, *) {
                    NSApp.activate()
                } else {
                    NSApp.activate(ignoringOtherApps: true)
                }

                let alert = NSAlert()
                alert.messageText = targetLoc("archiveClearTitle")
                alert.informativeText = targetLoc("archiveClearBody")
                alert.alertStyle = .warning
                alert.addButton(withTitle: targetLoc("archiveClearConfirm"))
                alert.addButton(withTitle: targetLoc("archiveClearCancel"))
                alert.window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
                if alert.runModal() == .alertFirstButtonReturn {
                    targetStore.clearArchive()
                }
            }
        }

        func menuWillOpen(_ menu: NSMenu) { notchVM?.acquireModalLock(.optionsMenu) }
        func menuDidClose(_ menu: NSMenu) { notchVM?.releaseModalLock(.optionsMenu) }
    }
}
