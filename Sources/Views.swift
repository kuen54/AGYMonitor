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

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @Environment(\.craftHapticsEnabled) private var hapticsEnabled
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
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(loc("stepperPrevious"))
                .accessibilityAddTraits(.isButton)
                .onHover { hoverLeft = $0 }
                .onTapGesture {
                    if canDecrement {
                        CraftEngine.shared.perform(.tabDetent, enabled: hapticsEnabled)
                        onDecrement()
                    }
                }

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
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(loc("stepperNext"))
                .accessibilityAddTraits(.isButton)
                .onHover { hoverRight = $0 }
                .onTapGesture {
                    if canIncrement {
                        CraftEngine.shared.perform(.tabDetent, enabled: hapticsEnabled)
                        onIncrement()
                    }
                }
        }
    }
}

struct PanelHeightKey: Hashable, Sendable {
    let tab: DisplayTab
    let visualMode: TelemetryVisualMode
    let timeRange: TimeRange?
    let isCurrentMonth: Bool
    let periodScope: UsagePeriodScope?
    let contentPhase: Int
    let sessionDeckMode: SessionDeckMode
    let sessionFilter: SessionStatusFilter
    let sessionBucket: Int
    let replayBucket: Int
    let monthWeekRows: Int

    /// True while Black Box is in a transient loading state (timeline parse or empty initial index scan).
    static func isReplayTransientLoading(_ replayState: ReplayStoreState) -> Bool {
        replayState.timelinePhase.isLoading
            || (replayState.indexPhase.isLoading && replayState.missions.isEmpty && replayState.timelinePhase.timeline == nil)
    }

    /// Layout bucket for Black Box replay timelines:
    /// - `1...6` when `.loaded(let tl)` (matching `ReplayWaterfallDeckView`'s cap at >5 tracks)
    /// - retains `previous >= 1 ? previous : 1` during transient `.loading` so `‹`/`›` never collapses height
    /// - `0` when settled `.idle` / `.unavailable` with no loaded timeline.
    static func replayBucket(for replayState: ReplayStoreState, retaining previous: Int = 0) -> Int {
        if isReplayTransientLoading(replayState) {
            return previous >= 1 ? previous : 1
        }
        switch replayState.timelinePhase {
        case .loaded(let tl):
            return min(max(tl.tracks.count, 1), 6)
        case .loading:
            return previous >= 1 ? previous : 1
        case .idle, .unavailable:
            return 0
        }
    }

    /// `0` when a replay timeline is ready (or retained across transient loading); `1` when settled empty/unavailable.
    static func replayContentPhase(for replayState: ReplayStoreState) -> Int {
        if isReplayTransientLoading(replayState) {
            return 0
        }
        return replayState.activeReplay != nil ? 0 : 1
    }

    /// True when this key represents a transient loading/empty/error content phase rather than ready data.
    var isTransientContentPhase: Bool {
        contentPhase != 0
    }

    /// Only persist settled, canonical (unfiltered) layout heights into global `PopoverHeightMemory`.
    var shouldPersistToMemory: Bool {
        guard !isTransientContentPhase else { return false }
        if tab == .session && sessionDeckMode == .live && sessionFilter != .all {
            return false
        }
        return true
    }

    static func make(
        store: UsageStore,
        tabOverride: DisplayTab? = nil,
        timeRangeOverride: TimeRange? = nil,
        sessionDeckModeOverride: SessionDeckMode? = nil,
        sessionFilterOverride: SessionStatusFilter? = nil,
        liveSessionBucketOverride: Int? = nil,
        replayBucketOverride: Int? = nil,
        replayContentPhaseOverride: Int? = nil
    ) -> PanelHeightKey {
        let tab = tabOverride ?? store.selectedTab
        let range = timeRangeOverride ?? store.timeRange
        let isCurrentMonthForKey: Bool = {
            switch tab {
            case .cost, .tokens:
                return store.isCurrentMonth
            case .time:
                return range == .year ? true : store.isCurrentMonth
            case .session, .subscription:
                return true
            }
        }()
        let periodScope: UsagePeriodScope? = (isCurrentMonthForKey && (tab == .cost || tab == .tokens))
            ? store.selectedPeriodScope
            : nil
        let deckMode: SessionDeckMode = (tab == .session)
            ? (sessionDeckModeOverride ?? store.sessionStore.deckMode)
            : .live
        let liveFilter: SessionStatusFilter = (tab == .session && deckMode == .live)
            ? (sessionFilterOverride ?? .all)
            : .all
        let sessionBucket: Int = (tab == .session && deckMode == .live)
            ? (liveSessionBucketOverride ?? min(store.sessionStore.sessions.count, 6))
            : 0
        let replayBucket: Int = (tab == .session && deckMode == .blackBox)
            ? (replayBucketOverride ?? Self.replayBucket(for: store.sessionStore.replayState))
            : 0
        let contentPhase: Int = {
            switch tab {
            case .cost, .tokens:
                if store.isCurrentMonth {
                    return store.effectiveCurrentMonthPhase.value != nil ? 0 : 1
                } else {
                    return store.effectiveHistoricalMonthPhase.value != nil ? 0 : 1
                }
            case .time:
                switch range {
                case .year:
                    switch store.effectiveYearPhase {
                    case .loaded, .loading(cached: .some), .failed(_, cached: .some), .empty:
                        return 0
                    case .idle, .loading(cached: nil), .failed(_, cached: nil):
                        return 1
                    }
                case .week, .month:
                    if store.isCurrentMonth {
                        return store.effectiveCurrentMonthPhase.value?.time != nil ? 0 : 1
                    } else {
                        return store.effectiveHistoricalMonthPhase.value?.time != nil ? 0 : 1
                    }
                }
            case .subscription:
                return store.effectiveQuotaPhase.snapshot != nil ? 0 : 1
            case .session:
                if deckMode == .blackBox {
                    return replayContentPhaseOverride ?? Self.replayContentPhase(for: store.sessionStore.replayState)
                }
                return 0
            }
        }()
        let monthWeekRows: Int = (tab == .time && range == .month)
            ? TimeLogic.weeksOfMonth(year: store.viewingYear, month: store.viewingMonth).count
            : 0
        return PanelHeightKey(
            tab: tab,
            visualMode: store.visualMode,
            timeRange: tab == .time ? range : nil,
            isCurrentMonth: isCurrentMonthForKey,
            periodScope: periodScope,
            contentPhase: contentPhase,
            sessionDeckMode: deckMode,
            sessionFilter: liveFilter,
            sessionBucket: sessionBucket,
            replayBucket: replayBucket,
            monthWeekRows: monthWeekRows
        )
    }
}

/// Keyed per-layout height map so an outgoing tab or outgoing Time sub-range still
/// animating out in a ZStack can never pollute or bounce the incoming panel height.
struct ContentHeightsKey: PreferenceKey {
    static var defaultValue: [PanelHeightKey: CGFloat] = [:]
    static func reduce(value: inout [PanelHeightKey: CGFloat], nextValue: () -> [PanelHeightKey: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

@MainActor
private enum PopoverHeightMemory {
    private static var byKey: [PanelHeightKey: Double] = [:]

    static func snapshot() -> [PanelHeightKey: Double] {
        byKey
    }

    static func height(for key: PanelHeightKey) -> Double? {
        byKey[key]
    }

    static func record(_ height: Double, for key: PanelHeightKey) {
        guard height.isFinite, height > 1.0 else { return }
        if byKey[key] == nil && byKey.count >= 128 {
            byKey.removeAll(keepingCapacity: true)
        }
        byKey[key] = height
    }
}

private struct ReplayLayoutSignal: Equatable {
    let isTransientLoading: Bool
    let settledBucket: Int
    let settledContentPhase: Int

    init(state: ReplayStoreState) {
        let loading = PanelHeightKey.isReplayTransientLoading(state)
        self.isTransientLoading = loading
        if loading {
            self.settledBucket = 0
            self.settledContentPhase = 0
        } else if let tl = state.activeReplay {
            self.settledBucket = min(max(tl.tracks.count, 1), 6)
            self.settledContentPhase = 0
        } else {
            self.settledBucket = 0
            self.settledContentPhase = 1
        }
    }
}

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject private var updateService: UpdateService
    let onQuit: () -> Void
    var onClose: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.telemetryStaticRender) private var isStaticRender
    @Environment(\.popoverHostScreenHeight) private var popoverHostScreenHeight
    @Environment(\.notchViewModel) private var notchVM
    @State private var heightState: PanelHeightState<PanelHeightKey>
    @State private var tabTransition: TabTransitionState<DisplayTab>
    @State private var sessionDeckMode: SessionDeckMode
    @State private var liveSessionBucket: Int
    @State private var activeLiveFilter: SessionStatusFilter = .all
    @State private var replayLayoutBucket: Int
    @State private var replayContentPhase: Int
    @State private var isReplayLoading: Bool
    @State private var latestContentHeights: [PanelHeightKey: CGFloat] = [:]
    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    private static let canonicalTabOrder: [DisplayTab] = [.cost, .tokens, .time, .session, .subscription]

    init(store: UsageStore, onQuit: @escaping () -> Void, onClose: (() -> Void)? = nil) {
        self.store = store
        _updateService = ObservedObject(wrappedValue: store.updateService)
        self.onQuit = onQuit
        self.onClose = onClose
        let initialTab = store.selectedTab
        let initialDeckMode = store.sessionStore.deckMode
        let initialLiveBucket = min(store.sessionStore.sessions.count, 6)
        let initialReplayState = store.sessionStore.replayState
        let initialReplayLoading = PanelHeightKey.isReplayTransientLoading(initialReplayState)
        let initialReplayBucket = PanelHeightKey.replayBucket(for: initialReplayState, retaining: 0)
        let initialReplayContentPhase = PanelHeightKey.replayContentPhase(for: initialReplayState)
        let initialKey = PanelHeightKey.make(
            store: store,
            tabOverride: initialTab,
            sessionDeckModeOverride: initialDeckMode,
            sessionFilterOverride: .all,
            liveSessionBucketOverride: initialLiveBucket,
            replayBucketOverride: initialReplayBucket,
            replayContentPhaseOverride: initialReplayContentPhase
        )
        _heightState = State(initialValue: PanelHeightState(
            initialKey: initialKey,
            defaultHeight: 460.0,
            memory: PopoverHeightMemory.snapshot()
        ))
        _tabTransition = State(initialValue: TabTransitionState(initial: initialTab))
        _sessionDeckMode = State(initialValue: initialDeckMode)
        _liveSessionBucket = State(initialValue: initialLiveBucket)
        _replayLayoutBucket = State(initialValue: initialReplayBucket)
        _replayContentPhase = State(initialValue: initialReplayContentPhase)
        _isReplayLoading = State(initialValue: initialReplayLoading)
    }

    private func heightKey(
        tab: DisplayTab? = nil,
        timeRange: TimeRange? = nil,
        sessionDeckMode deckModeOverride: SessionDeckMode? = nil,
        sessionFilter filterOverride: SessionStatusFilter? = nil,
        liveSessionBucket liveBucketOverride: Int? = nil,
        replayBucket replayBucketOverride: Int? = nil,
        replayContentPhase replayPhaseOverride: Int? = nil
    ) -> PanelHeightKey {
        PanelHeightKey.make(
            store: store,
            tabOverride: tab ?? tabTransition.activeId,
            timeRangeOverride: timeRange,
            sessionDeckModeOverride: deckModeOverride ?? sessionDeckMode,
            sessionFilterOverride: filterOverride ?? activeLiveFilter,
            liveSessionBucketOverride: liveBucketOverride ?? liveSessionBucket,
            replayBucketOverride: replayBucketOverride ?? replayLayoutBucket,
            replayContentPhaseOverride: replayPhaseOverride ?? replayContentPhase
        )
    }

    private var currentHeightKey: PanelHeightKey {
        heightKey()
    }

    private var loc: Localizer { Localizer(language: store.language) }
    private var isNotch: Bool { store.displayMode == .notch }
    private var allowsPanelHeightAnimation: Bool { isNotch && !isStaticRender }
    private var instrumentHapticsEnabled: Bool {
        !isStaticRender && store.visualMode == .instrument && store.craftPreferences.hapticsEnabled
    }
    private var theme: AGYTheme {
        AGYTheme(preset: store.themePreset, colorScheme: colorScheme, isNotch: isNotch)
    }

    private var tabContentAnimation: Animation? {
        guard !isStaticRender else { return nil }
        if reduceMotion { return TelemetryMotion.reduced }
        return isNotch ? TelemetryMotion.tabContent : TelemetryMotion.popoverTabContent
    }

    private var panelHeightAnimation: Animation? {
        guard allowsPanelHeightAnimation else { return nil }
        return reduceMotion ? TelemetryMotion.reduced : TelemetryMotion.panelHeight
    }

    private var maxContentHeight: CGFloat {
        let screenH = Double(popoverHostScreenHeight ?? NSScreen.main?.visibleFrame.height ?? 900)
        let closedNotchH = Double(notchVM?.closedNotchSize.height ?? 32)
        return CGFloat(PanelHeightBudget.maxContentHeight(
            hostAvailableHeight: screenH,
            isNotch: isNotch,
            notchClosedHeight: closedNotchH,
            hasUpdateBanner: updateService.state.bannerDisplay != .none
        ))
    }

    private var isContentScrollable: Bool {
        !isStaticRender && heightState.currentHeight > Double(maxContentHeight) + 2.0
    }

    private var clampedContentHeight: CGFloat {
        let raw = min(max(CGFloat(heightState.currentHeight), 1), maxContentHeight)
        return isNotch ? raw : ceil(raw)
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
    /// Synced to `tabTransition.activeId` so header & content never desync by 1 frame.
    private var headerAccessoryTransitionId: String {
        switch tabTransition.activeId {
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
        let activeTab = tabTransition.activeId
        let activeKey = currentHeightKey
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

            ZStack(alignment: .top) {
                ScrollView(showsIndicators: isContentScrollable) {
                    tabContentWithHeightReporting(for: activeTab, key: activeKey)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                .id("\(activeTab.rawValue)-\(activeTab == .session ? sessionDeckMode.rawValue : "")")
                .transition(
                    TelemetryMotion.tabContentTransition(
                        direction: tabTransition.direction,
                        isNotch: isNotch,
                        reduceMotion: reduceMotion
                    )
                )
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .animation(tabContentAnimation, value: tabTransition)
            .frame(height: clampedContentHeight, alignment: .top)
            .clipped()
            .onPreferenceChange(ContentHeightsKey.self) { heights in
                let activeKey = currentHeightKey
                let isBlackBoxLoading = (tabTransition.activeId == .session && sessionDeckMode == .blackBox && isReplayLoading)
                if !isBlackBoxLoading {
                    for (key, height) in heights where height.isFinite && height > 1 {
                        if let existing = latestContentHeights[key], abs(existing - height) <= 0.5 {
                            continue
                        }
                        latestContentHeights[key] = height
                    }
                }
                guard !isBlackBoxLoading, let next = heights[activeKey], next.isFinite, next > 1 else { return }
                var nextState = heightState
                if nextState.activeKey != activeKey {
                    seedSharedHeight(&nextState, for: activeKey)
                    _ = nextState.switchKey(to: activeKey, allowsAnimation: allowsPanelHeightAnimation)
                }
                let update = nextState.recordMeasurement(
                    for: activeKey,
                    height: Double(next),
                    allowsAnimation: allowsPanelHeightAnimation
                )
                if activeKey.shouldPersistToMemory, let recorded = nextState.memory[activeKey] {
                    PopoverHeightMemory.record(recorded, for: activeKey)
                }
                guard nextState != heightState else { return }
                if let update = update, update.animate {
                    withAnimation(panelHeightAnimation) {
                        heightState = nextState
                    }
                } else {
                    heightState = nextState
                }
            }

            UpdateBannerStrip(updateService: updateService)

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
            if store.isPanelVisible {
                CraftEngine.shared.perform(.tabDetent, enabled: instrumentHapticsEnabled)
            }
            var nextTransition = tabTransition
            nextTransition.transition(to: nextTab, in: Self.canonicalTabOrder)
            if nextTab != .session || tabTransition.activeId != .session {
                activeLiveFilter = .all
            }
            let nextKey = heightKey(tab: nextTab, sessionFilter: .all)
            // Keep `tabTransition` outside `withAnimation` so `.animation(tabContentAnimation, value: tabTransition)`
            // animates ONLY the inner tab ZStack, while `heightState` updates non-animated in Menu Bar mode
            // (eliminating VStack vertical centering bounce & NSPopover spring churn) and smoothly in Notch mode.
            tabTransition = nextTransition
            applyPanelHeightSwitch(to: nextKey)
        }
        .onChange(of: store.visualMode) { nextMode in
            syncPanelHeightKey()
            if nextMode == .instrument {
                if store.isPanelVisible {
                    CraftEngine.shared.perform(
                        .modeEngage,
                        enabled: !isStaticRender && store.craftPreferences.hapticsEnabled
                    )
                }
            } else {
                CraftEngine.shared.cancelPendingHapticCadence()
            }
        }
        .onChange(of: store.craftPreferences.hapticsEnabled) { enabled in
            if !enabled {
                CraftEngine.shared.cancelPendingHapticCadence()
            }
        }
        .onChange(of: store.themePreset) { _ in
            if store.isPanelVisible {
                CraftEngine.shared.perform(.modeEngage, enabled: instrumentHapticsEnabled)
            }
        }
        .onChange(of: store.timeRange) { _ in
            syncPanelHeightKey()
            if store.isPanelVisible && store.selectedTab == .time {
                CraftEngine.shared.perform(.tabDetent, enabled: instrumentHapticsEnabled)
            }
        }
        .onChange(of: store.viewingMonth) { _ in syncPanelHeightKey() }
        .onChange(of: store.viewingYear) { _ in syncPanelHeightKey() }
        .onChange(of: store.selectedPeriodScope) { _ in syncPanelHeightKey() }
        .onChange(of: currentHeightKey) { nextKey in
            applyPanelHeightSwitch(to: nextKey)
        }
        .onReceive(
            store.sessionStore.$sessions
                .map { min($0.count, 6) }
                .removeDuplicates()
        ) { nextBucket in
            liveSessionBucket = nextBucket
            if tabTransition.activeId == .session && sessionDeckMode == .live {
                applyPanelHeightSwitch(to: heightKey(liveSessionBucket: nextBucket))
            }
        }
        .onReceive(
            store.sessionStore.$deckMode
                .removeDuplicates()
        ) { nextMode in
            sessionDeckMode = nextMode
            if nextMode != .live {
                activeLiveFilter = .all
            }
            if tabTransition.activeId == .session {
                let nextFilter: SessionStatusFilter = (nextMode == .live) ? activeLiveFilter : .all
                applyPanelHeightSwitch(to: heightKey(sessionDeckMode: nextMode, sessionFilter: nextFilter))
            }
        }
        .onReceive(
            store.sessionStore.$replayState
                .map { ReplayLayoutSignal(state: $0) }
                .removeDuplicates()
        ) { signal in
            isReplayLoading = signal.isTransientLoading
            let nextBucket: Int
            let nextPhase: Int
            if signal.isTransientLoading {
                nextBucket = replayLayoutBucket >= 1 ? replayLayoutBucket : 1
                nextPhase = 0
            } else {
                nextBucket = signal.settledBucket
                nextPhase = signal.settledContentPhase
            }
            replayLayoutBucket = nextBucket
            replayContentPhase = nextPhase
            if tabTransition.activeId == .session && sessionDeckMode == .blackBox {
                applyPanelHeightSwitch(
                    to: heightKey(replayBucket: nextBucket, replayContentPhase: nextPhase)
                )
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        .environment(\.localizer, loc)
        .environment(\.agyTheme, theme)
        .environment(\.telemetryPanelVisible, store.isPanelVisible)
        .environment(\.telemetryReduceMotion, reduceMotion)
        .environment(\.craftHapticsEnabled, instrumentHapticsEnabled)
    }

    private func seedSharedHeight(_ state: inout PanelHeightState<PanelHeightKey>, for key: PanelHeightKey) {
        guard state.activeKey != key,
              state.memory[key] == nil,
              let remembered = PopoverHeightMemory.height(for: key) else {
            return
        }
        _ = state.recordMeasurement(
            for: key,
            height: remembered,
            allowsAnimation: allowsPanelHeightAnimation
        )
    }

    private func applyPanelHeightSwitch(to nextKey: PanelHeightKey) {
        var nextHeight = heightState
        seedSharedHeight(&nextHeight, for: nextKey)
        let switchUpdate = nextHeight.switchKey(to: nextKey, allowsAnimation: allowsPanelHeightAnimation)
        var measurementUpdate: PanelHeightUpdate? = nil
        if let freshHeight = latestContentHeights[nextKey], freshHeight.isFinite, freshHeight > 1 {
            measurementUpdate = nextHeight.recordMeasurement(
                for: nextKey,
                height: Double(freshHeight),
                allowsAnimation: allowsPanelHeightAnimation
            )
        }
        guard nextHeight != heightState else { return }
        let shouldAnimate = (measurementUpdate?.animate ?? false) || (switchUpdate?.animate ?? false)
        if shouldAnimate {
            withAnimation(panelHeightAnimation) {
                heightState = nextHeight
            }
        } else {
            heightState = nextHeight
        }
    }

    private func syncPanelHeightKey() {
        applyPanelHeightSwitch(to: currentHeightKey)
    }

    /// Emits `ContentHeightsKey` for the active tab. `.time` reports its own height from inside
    /// `TimeTabView`'s `.id(activeRange)` child so outgoing range views can never inflate the
    /// incoming range's measured height.
    @ViewBuilder
    private func tabContentWithHeightReporting(for tab: DisplayTab, key: PanelHeightKey) -> some View {
        if tab == .time {
            contentSection(for: tab)
        } else {
            contentSection(for: tab)
                .background(GeometryReader { geo in
                    Color.clear.preference(
                        key: ContentHeightsKey.self,
                        value: [key: geo.size.height]
                    )
                })
        }
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

                LiveHeaderTagView(sessionStore: store.sessionStore) {
                    store.sessionStore.deckMode = .live
                    store.selectedTab = .session
                }
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
    private var contextHeaderAccessory: some View {
        switch tabTransition.activeId {
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
            LiveHeaderCountView(sessionStore: store.sessionStore)
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
            SessionTabView(
                sessionStore: store.sessionStore,
                visualMode: store.visualMode,
                isActiveTab: store.selectedTab == .session,
                onClose: onClose,
                onFilterChange: { nextFilter in
                    guard activeLiveFilter != nextFilter else { return }
                    activeLiveFilter = nextFilter
                    if tabTransition.activeId == .session && sessionDeckMode == .live {
                        applyPanelHeightSwitch(to: heightKey(sessionFilter: nextFilter))
                    }
                }
            )
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
                OptionsMenu(store: store, loc: loc, onClose: onClose)
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

            Text("· ⌘R · ⌘T · ⌘I · ⌘E")
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
            Button("") {
                onClose?()
                SpecimenWindowController.shared.present(store: store)
            }.keyboardShortcut("e", modifiers: .command)
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

// MARK: - Live Header Session Subviews (Isolated SessionStore Observation)

/// Isolated header pill observing `SessionStore` directly so `WAIT N` / `RUN N` updates
/// in real time on 2s polls without re-evaluating `PopoverView.body`.
private struct LiveHeaderTagView: View {
    @ObservedObject var sessionStore: SessionStore
    let onTap: () -> Void

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme

    var body: some View {
        let waitingCount = sessionStore.sessions.filter { $0.status == .waiting }.count
        let busyCount = sessionStore.sessions.filter { $0.status == .busy }.count
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
            .onTapGesture(perform: onTap)
        } else if busyCount > 0 {
            HStack(spacing: 3.5) {
                Circle().fill(theme.accent).frame(width: 4, height: 4)
                Text(String(format: loc("runTagFmt"), busyCount))
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.accent)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
        }
    }
}

/// Isolated right-aligned Tab 04 `N LIVE` accessory observing `SessionStore` directly.
private struct LiveHeaderCountView: View {
    @ObservedObject var sessionStore: SessionStore

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme

    var body: some View {
        Text(String(format: loc("liveTagFmt"), sessionStore.liveCount))
            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .foregroundColor(theme.inkSecondary)
            .lineLimit(1)
    }
}

// MARK: - In-App Update Status Strip

/// Compact Swiss Telemetry strip rendered above the footer when a new GitHub Release
/// is available (or during transient manual-check feedback). Uses `.onTapGesture`
/// rather than SwiftUI `Button` so `ImageRenderer` stays crash-free.
struct UpdateBannerStrip: View {
    @ObservedObject var updateService: UpdateService

    @Environment(\.agyTheme) private var theme
    @Environment(\.localizer) private var loc
    @State private var hoverView = false
    @State private var hoverSkip = false

    var body: some View {
        switch updateService.state.bannerDisplay {
        case .none:
            EmptyView()

        case .available(let release):
            VStack(spacing: 0) {
                HairlineRule(showCrosshairs: false)
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Rectangle()
                            .fill(theme.accent)
                            .frame(width: 5, height: 5)
                            .rotationEffect(.degrees(45))
                        Text(String(format: loc("updateBannerAvailableFmt"), release.version.displayTag))
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .tracking(0.4)
                            .foregroundColor(theme.inkPrimary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    Text(loc("updateBannerView"))
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .tracking(0.5)
                        .foregroundColor(hoverView ? theme.invertedInk : theme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(hoverView ? theme.accent : theme.accent.opacity(theme.isDark ? 0.16 : 0.10))
                        .overlay(
                            Rectangle()
                                .strokeBorder(theme.accent.opacity(hoverView ? 1.0 : 0.55), lineWidth: 0.75)
                        )
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            hoverView = hovering
                            PointingCursorCoordinator.shared.setPointing(hovering, token: "updateBanner.view")
                        }
                        .onTapGesture {
                            updateService.openReleasePage()
                        }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel(loc("updateBannerView"))

                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundColor(hoverSkip ? theme.inkPrimary : theme.inkSecondary)
                        .frame(width: 18, height: 18)
                        .background(hoverSkip ? theme.surfaceRaised : Color.clear)
                        .contentShape(Rectangle())
                        .help(loc("updateBannerSkip"))
                        .onHover { hovering in
                            hoverSkip = hovering
                            PointingCursorCoordinator.shared.setPointing(hovering, token: "updateBanner.skip")
                        }
                        .onTapGesture {
                            PointingCursorCoordinator.shared.setPointing(false, token: "updateBanner.skip")
                            updateService.dismissAvailableUpdate()
                        }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel(loc("updateBannerSkip"))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(theme.accent.opacity(theme.isDark ? 0.09 : 0.055))
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(theme.accent)
                        .frame(width: 2)
                }
            }
            .onDisappear {
                hoverView = false
                hoverSkip = false
                PointingCursorCoordinator.shared.setPointing(false, token: "updateBanner.view")
                PointingCursorCoordinator.shared.setPointing(false, token: "updateBanner.skip")
            }

        case .checking:
            transientStatusRow(
                dotColor: theme.accent,
                text: loc("updateChecking"),
                textColor: theme.accent
            )

        case .upToDate(let version):
            transientStatusRow(
                dotColor: theme.signalGreen,
                text: String(format: loc("updateUpToDateFmt"), version.displayTag),
                textColor: theme.inkSecondary
            )

        case .failed:
            transientStatusRow(
                dotColor: theme.signalAmber,
                text: loc("updateCheckFailed"),
                textColor: theme.signalAmber
            )
        }
    }

    private func transientStatusRow(dotColor: Color, text: String, textColor: Color) -> some View {
        VStack(spacing: 0) {
            HairlineRule(showCrosshairs: false)
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 4.5, height: 4.5)
                Text(text)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.4)
                    .foregroundColor(textColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(theme.surface.opacity(theme.isNotch ? 0.0 : 0.65))
        }
    }
}
