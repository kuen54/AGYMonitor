import SwiftUI
import AppKit

// Footer menus (language switcher + options) — AppKit NSMenu coordinators.

// ── Language switcher (plain button → NSMenu, avoids accent color tinting) ──
struct LanguageSwitcher: NSViewRepresentable {
    @ObservedObject var store: UsageStore

    func makeNSView(context: Context) -> NSButton {
        let btn = NSButton(frame: .zero)
        btn.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        btn.imageScaling = .scaleProportionallyDown
        btn.isBordered = false
        btn.contentTintColor = .secondaryLabelColor
        btn.target = context.coordinator
        btn.action = #selector(Coordinator.showMenu(_:))
        btn.setContentHuggingPriority(.required, for: .horizontal)
        return btn
    }

    func updateNSView(_ btn: NSButton, context: Context) {
        context.coordinator.notchVM = context.environment.notchViewModel
        btn.contentTintColor = .secondaryLabelColor
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

        func menuWillOpen(_ menu: NSMenu) { notchVM?.preventClose = true }
        func menuDidClose(_ menu: NSMenu) { notchVM?.preventClose = false }
    }
}

/// Footer "⋯" menu: Display location (Menu bar / Notch) + durable local archive toggle & clear.
struct OptionsMenu: NSViewRepresentable {
    @ObservedObject var store: UsageStore
    let loc: Localizer

    func makeNSView(context: Context) -> NSButton {
        let btn = NSButton(frame: .zero)
        btn.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
        btn.imageScaling = .scaleProportionallyDown
        btn.isBordered = false
        btn.contentTintColor = .secondaryLabelColor
        btn.target = context.coordinator
        btn.action = #selector(Coordinator.showMenu(_:))
        btn.setContentHuggingPriority(.required, for: .horizontal)
        return btn
    }

    func updateNSView(_ btn: NSButton, context: Context) {
        context.coordinator.loc = loc
        context.coordinator.notchVM = context.environment.notchViewModel
        btn.contentTintColor = .secondaryLabelColor
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

        @objc func toggleArchive() {
            store.setArchiveHistoryLocally(!store.archiveHistoryLocally)
        }

        @objc func clearArchive() {
            notchVM?.preventClose = true
            if notchVM != nil { NSApp.activate(ignoringOtherApps: true) }
            defer { notchVM?.preventClose = false }

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

        func menuWillOpen(_ menu: NSMenu) { notchVM?.preventClose = true }
        func menuDidClose(_ menu: NSMenu) { notchVM?.preventClose = false }
    }
}
