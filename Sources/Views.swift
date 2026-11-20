import SwiftUI
import AppKit

// PopoverView (single-plane Swiss Telemetry drafting board), context-aware header,
// grid tab bar, and bare hairline statusline footer.

/// Bare monospace stepper (`< 2026.11 >`) shared by Header & WeekTimeChart.
struct TelemetryStepper: View {
    let label: String
    let canDecrement: Bool
    let canIncrement: Bool
    let onDecrement: () -> Void
    let onIncrement: () -> Void

    @Environment(\.agyTheme) private var theme
    @State private var hoverLeft = false
    @State private var hoverRight = false

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "chevron.left")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundColor(canDecrement ? (hoverLeft ? theme.accent : theme.inkSecondary) : theme.inkMuted)
                .frame(width: 18, height: 18)
                .background(hoverLeft && canDecrement ? theme.surfaceRaised : Color.clear)
                .contentShape(Rectangle())
                .opacity(canDecrement ? 1 : 0.3)
                .onHover { hoverLeft = $0 }
                .onTapGesture { if canDecrement { onDecrement() } }

            Text(label)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.inkPrimary)
                .padding(.horizontal, 2)
                .fixedSize()

            Image(systemName: "chevron.right")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundColor(canIncrement ? (hoverRight ? theme.accent : theme.inkSecondary) : theme.inkMuted)
                .frame(width: 18, height: 18)
                .background(hoverRight && canIncrement ? theme.surfaceRaised : Color.clear)
                .contentShape(Rectangle())
                .opacity(canIncrement ? 1 : 0.3)
                .onHover { hoverRight = $0 }
                .onTapGesture { if canIncrement { onIncrement() } }
        }
    }
}

@MainActor
private enum PopoverHeightMemory {
    static var byTab: [DisplayTab: CGFloat] = [:]
}

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    let onQuit: () -> Void
    var onClose: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.telemetryStaticRender) private var isStaticRender
    @State private var contentHeight: CGFloat
    @State private var hasMeasuredInitialHeight = false
    @State private var tabTransition: TabTransitionState<DisplayTab>
    @State private var displayedTab: DisplayTab
    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    init(store: UsageStore, onQuit: @escaping () -> Void, onClose: (() -> Void)? = nil) {
        self.store = store
        self.onQuit = onQuit
        self.onClose = onClose
        let initialTab = store.selectedTab
        let initialH = PopoverHeightMemory.byTab[initialTab] ?? 460
        _contentHeight = State(initialValue: initialH)
        _tabTransition = State(initialValue: TabTransitionState(initial: initialTab))
        _displayedTab = State(initialValue: initialTab)
    }

    private var loc: Localizer { Localizer(language: store.language) }
    private var isNotch: Bool { store.displayMode == .notch }
    private var theme: AGYTheme {
        AGYTheme(preset: store.themePreset, colorScheme: colorScheme, isNotch: isNotch)
    }

    private var tabContentAnimation: Animation? {
        guard !isStaticRender else { return nil }
        return reduceMotion ? TelemetryMotion.reduced : TelemetryMotion.tabContent
    }

    private var panelHeightAnimation: Animation? {
        guard !isStaticRender else { return nil }
        return reduceMotion ? TelemetryMotion.reduced : TelemetryMotion.panelHeight
    }

    /// Keyed per-tab height map so an outgoing tab still animating out in the ZStack
    /// can never pollute or bounce the incoming tab's target panel height.
    private struct ContentHeightsKey: PreferenceKey {
        static var defaultValue: [DisplayTab: CGFloat] = [:]
        static func reduce(value: inout [DisplayTab: CGFloat], nextValue: () -> [DisplayTab: CGFloat]) {
            value.merge(nextValue(), uniquingKeysWith: { _, new in new })
        }
    }

    private var maxContentHeight: CGFloat {
        let screenH = NSScreen.main?.visibleFrame.height ?? 900
        return max(260, screenH - 170)
    }

    private var currentYear: Int {
        AppDate.gregorian.component(.year, from: Date())
    }

    private var visibleTabs: [DisplayTab] {
        store.hasOAuthToken
            ? [.cost, .tokens, .time, .session, .subscription]
            : [.cost, .tokens, .time, .session]
    }

    /// Stable identity for the right-aligned header accessory so identical steppers
    /// across COST / TOK / TIME (Week/Month) stay rock-solid while distinct badges glide.
    private var headerAccessoryTransitionId: String {
        switch store.selectedTab {
        case .cost, .tokens:
            return "monthStepper"
        case .time:
            return store.timeRange == .year ? "yearStepper" : "monthStepper"
        case .session:
            return "liveCount"
        case .subscription:
            return "planBadge"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 8)

            TelemetryTabBar(
                items: visibleTabs,
                selection: $store.selectedTab,
                sessionStore: store.sessionStore,
                loc: loc
            )

            ScrollView(showsIndicators: false) {
                ZStack(alignment: .top) {
                    contentSection(for: displayedTab)
                        .id(displayedTab)
                        .background(GeometryReader { geo in
                            Color.clear.preference(
                                key: ContentHeightsKey.self,
                                value: [displayedTab: geo.size.height]
                            )
                        })
                        .transition(
                            TelemetryMotion.tabContentTransition(
                                direction: tabTransition.direction,
                                reduceMotion: reduceMotion
                            )
                        )
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .clipped()
            .onPreferenceChange(ContentHeightsKey.self) { heights in
                guard let next = heights[displayedTab], next > 1 else { return }
                PopoverHeightMemory.byTab[displayedTab] = next
                guard abs(next - contentHeight) > 0.5 else { return }
                if hasMeasuredInitialHeight {
                    withAnimation(panelHeightAnimation) {
                        contentHeight = next
                    }
                } else {
                    contentHeight = next
                    hasMeasuredInitialHeight = true
                }
            }
            .frame(height: min(max(contentHeight, 1), maxContentHeight))

            HairlineRule(showCrosshairs: true)

            footer
        }
        .overlay(keyboardShortcutsOverlay)
        .frame(width: AGYTheme.panelWidth)
        .background(
            ZStack {
                isNotch ? Color.clear : theme.canvas
                ArchivalGrainOverlay()
            }
        )
        .onChange(of: store.selectedTab) { nextTab in
            tabTransition.transition(to: nextTab, in: visibleTabs)
            withAnimation(tabContentAnimation) {
                displayedTab = nextTab
                if let remembered = PopoverHeightMemory.byTab[nextTab],
                   abs(remembered - contentHeight) > 0.5 {
                    contentHeight = remembered
                }
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        .environment(\.localizer, loc)
        .environment(\.agyTheme, theme)
        .environment(\.telemetryPanelVisible, store.isPanelVisible)
    }

    // MARK: - Bare Context-Aware Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                SessionAwareLogo(sessionStore: store.sessionStore,
                                 size: 13, color: theme.accent, dotSize: 4.5,
                                 isActive: store.isPanelVisible)
                Text(loc("title").uppercased())
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .tracking(1.6)
                    .foregroundColor(theme.inkPrimary)
                    .lineLimit(1)

                liveHeaderTag
            }
            .frame(height: 20, alignment: .leading)

            Spacer(minLength: 4)

            ZStack(alignment: .trailing) {
                contextHeaderAccessory
                    .id(headerAccessoryTransitionId)
                    .transition(TelemetryMotion.headerAccessoryTransition(reduceMotion: reduceMotion))
            }
            .frame(height: 20, alignment: .trailing)
            .clipped()
            .animation(tabContentAnimation, value: headerAccessoryTransitionId)
        }
        .frame(height: 20)
    }

    @ViewBuilder
    private var liveHeaderTag: some View {
        let waitingCount = store.sessionStore.sessions.filter { $0.status == .waiting }.count
        let busyCount = store.sessionStore.sessions.filter { $0.status == .busy }.count
        if waitingCount > 0 {
            HStack(spacing: 4) {
                Rectangle()
                    .fill(theme.signalAmber)
                    .frame(width: 4.5, height: 4.5)
                    .rotationEffect(.degrees(45))
                Text(String(format: loc("waitTagFmt"), waitingCount))
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .tracking(0.4)
                    .foregroundColor(theme.signalAmber)
                    .lineLimit(1)
            }
            .padding(.horizontal, 5.5)
            .padding(.vertical, 2)
            .background(theme.signalAmber.opacity(theme.isDark ? 0.12 : 0.08))
            .overlay(Rectangle().strokeBorder(theme.signalAmber.opacity(0.48), lineWidth: 0.75))
            .contentShape(Rectangle())
            .onTapGesture { store.selectedTab = .session }
        } else if busyCount > 0 {
            HStack(spacing: 3.5) {
                Circle().fill(theme.accent).frame(width: 4, height: 4)
                Text(String(format: loc("runTagFmt"), busyCount))
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.accent)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture { store.selectedTab = .session }
        }
    }

    @ViewBuilder
    private var contextHeaderAccessory: some View {
        switch store.selectedTab {
        case .cost, .tokens:
            TelemetryStepper(
                label: store.viewingMonthCompactLabel,
                canDecrement: true,
                canIncrement: !store.isCurrentMonth,
                onDecrement: { store.navigateMonth(offset: -1) },
                onIncrement: { store.navigateMonth(offset: 1) }
            )
        case .time:
            if store.timeRange == .year {
                TelemetryStepper(
                    label: String(store.viewingTimeYear),
                    canDecrement: true,
                    canIncrement: store.viewingTimeYear < currentYear,
                    onDecrement: { store.navigateTimeYear(offset: -1) },
                    onIncrement: { store.navigateTimeYear(offset: 1) }
                )
            } else {
                TelemetryStepper(
                    label: store.viewingMonthCompactLabel,
                    canDecrement: true,
                    canIncrement: !store.isCurrentMonth,
                    onDecrement: { store.navigateMonth(offset: -1) },
                    onIncrement: { store.navigateMonth(offset: 1) }
                )
            }
        case .session:
            Text(String(format: loc("liveTagFmt"), store.sessionStore.liveCount))
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.inkSecondary)
                .lineLimit(1)
        case .subscription:
            if let badge = formatPlanTierBadge(store.subscriptionQuota?.planTier) {
                let badgeColor = theme.isMultiColorSpectrum ? theme.accent : theme.accentSecondary
                HStack(spacing: 4) {
                    LogoShape()
                        .fill(badgeColor)
                        .frame(width: 8, height: 8)
                    Text(badge)
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundColor(badgeColor)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - Content Routing

    @ViewBuilder
    private func contentSection(for tab: DisplayTab) -> some View {
        switch tab {
        case .time:
            TimeTabView(store: store)
        case .session:
            SessionTabView(sessionStore: store.sessionStore, visualMode: store.visualMode, onClose: onClose)
        case .subscription:
            SubscriptionView(store: store)
        case .cost, .tokens:
            UsageOverviewSection(store: store, metricOverride: tab)
        }
    }

    // MARK: - Bare Statusline Footer (Zero Floating Bug)

    private var footer: some View {
        HStack(spacing: 6) {
            statusText
                .lineLimit(1)
            Spacer()

            HStack(spacing: 4) {
                LanguageSwitcher(store: store)
                footerSeparator
                OptionsMenu(store: store, loc: loc)
                footerSeparator
                RefreshToolbarButton(isLoading: store.isLoading, helpText: loc("refresh")) {
                    store.refresh(force: true)
                }
                footerSeparator
                ToolbarIconButton(systemName: "power", helpText: loc("quit"), action: onQuit)
            }
        }
        .frame(height: 22)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private var footerSeparator: some View {
        Rectangle()
            .fill(theme.hairline)
            .frame(width: 1, height: 11)
    }

    @ViewBuilder
    private var statusText: some View {
        HStack(spacing: 6) {
            if store.isLoading {
                Circle().fill(theme.accent).frame(width: 4.5, height: 4.5)
                Text(loc("syncing"))
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.accent)
            } else if store.selectedTab == .subscription, let qt = store.quotaUpdatedAt {
                Text(String(format: loc("updated"), timeAgo(qt, loc)).uppercased())
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.inkSecondary)
            } else if !store.isCurrentMonth && (store.selectedTab == .cost || store.selectedTab == .tokens || store.selectedTab == .time) {
                Text(loc("cachedData").uppercased())
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.inkSecondary)
            } else if let time = store.lastUpdate {
                Text(String(format: loc("updated"), timeAgo(time, loc)).uppercased())
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.inkSecondary)
            }

            Text("· ⌘R · ⌘T · ⌘I")
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .foregroundColor(theme.inkMuted)
        }
    }

    // MARK: - Hidden Keyboard Shortcuts

    private var keyboardShortcutsOverlay: some View {
        Group {
            Button("") { selectTabIndex(0) }.keyboardShortcut("1", modifiers: .command)
            Button("") { selectTabIndex(1) }.keyboardShortcut("2", modifiers: .command)
            Button("") { selectTabIndex(2) }.keyboardShortcut("3", modifiers: .command)
            Button("") { selectTabIndex(3) }.keyboardShortcut("4", modifiers: .command)
            Button("") { selectTabIndex(4) }.keyboardShortcut("5", modifiers: .command)
            Button("") { stepContext(offset: -1) }.keyboardShortcut("[", modifiers: .command)
            Button("") { stepContext(offset: 1) }.keyboardShortcut("]", modifiers: .command)
            Button("") { store.refresh(force: true) }.keyboardShortcut("r", modifiers: .command)
            Button("") { store.cycleThemePreset() }.keyboardShortcut("t", modifiers: .command)
            Button("") { store.toggleVisualMode() }.keyboardShortcut("i", modifiers: .command)
            Button("") { onClose?() }.keyboardShortcut(.escape, modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
    }

    private func selectTabIndex(_ index: Int) {
        let tabs = visibleTabs
        guard index < tabs.count else { return }
        store.selectedTab = tabs[index]
    }

    private func stepContext(offset: Int) {
        if store.selectedTab == .time && store.timeRange == .year {
            store.navigateTimeYear(offset: offset)
        } else if store.selectedTab == .cost || store.selectedTab == .tokens || store.selectedTab == .time {
            store.navigateMonth(offset: offset)
        }
    }
}
