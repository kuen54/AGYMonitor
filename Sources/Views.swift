import SwiftUI
import AppKit

// PopoverView (the root popover) + the segmented tab selectors.

// MARK: - Segmented tab selector

/// Pure-SwiftUI segmented control used in the NOTCH (avoids NSSegmentedControl
/// height mis-measurement inside a borderless non-key NSPanel).
struct NotchSegmentedControl<Value: Hashable>: View {
    let items: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let selected = item == selection
                Text(label(item))
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? .white : Color.white.opacity(0.55))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selected ? Color.white.opacity(0.18) : Color.clear))
                    .contentShape(Rectangle())
                    .onTapGesture { selection = item }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.07)))
    }
}

/// Tab selector: custom dark control in the notch, native segmented Picker in menu bar.
struct TabSelector<Value: Hashable>: View {
    let isNotch: Bool
    let items: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    var body: some View {
        if isNotch {
            NotchSegmentedControl(items: items, selection: $selection, label: label)
        } else {
            Picker("", selection: $selection) {
                ForEach(items, id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    let onQuit: () -> Void

    private var loc: Localizer { Localizer(language: store.language) }

    @State private var contentHeight: CGFloat = 0

    private struct ContentHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    private var maxContentHeight: CGFloat {
        let screenH = NSScreen.main?.visibleFrame.height ?? 900
        return max(240, screenH - 190)
    }

    /// Cost + Tokens + Time + Sessions always; Plan tab when quota/account state is available.
    private var visibleTabs: [DisplayTab] {
        store.hasOAuthToken
            ? [.cost, .tokens, .time, .session, .subscription]
            : [.cost, .tokens, .time, .session]
    }

    private var notchWidthAnimation: Animation? {
        guard store.displayMode == .notch else { return nil }
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? NotchAnimations.reduced : NotchAnimations.open
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──
            HStack {
                HStack(spacing: 6) {
                    SessionAwareLogo(sessionStore: store.sessionStore,
                                     size: 14, color: .agyBrand, dotSize: 5)
                    Text(loc("title"))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.primary)
                }
                Spacer()
                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 6)

            // ── Month Navigator ──
            HStack {
                Button(action: { store.navigateMonth(offset: -1) }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)

                Spacer()

                Text(store.viewingMonthLabel)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)

                Spacer()

                Button(action: { store.navigateMonth(offset: 1) }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(store.isCurrentMonth)
                .opacity(store.isCurrentMonth ? 0.3 : 1)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            // ── Tab selector (Cost / Tokens / Time / Sessions / Plan) ──
            TabSelector(isNotch: store.displayMode == .notch,
                        items: visibleTabs,
                        selection: $store.selectedTab,
                        label: { $0.label(loc) })
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            // ── Content (sized to fit, scrolls only when taller than the screen) ──
            ScrollView(showsIndicators: false) {
                contentSection
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: ContentHeightKey.self,
                                               value: geo.size.height)
                    })
            }
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            .frame(height: min(max(contentHeight, 1), maxContentHeight))

            Divider()
                .padding(.horizontal, 10)

            footer
        }
        // Compact 360pt on Cost/Tokens/Plan; 480pt on Time/Sessions.
        .frame(width: (store.selectedTab == .time || store.selectedTab == .session) ? 480 : 360)
        .animation(notchWidthAnimation, value: store.selectedTab)
        .environment(\.localizer, loc)
    }

    @ViewBuilder
    private var contentSection: some View {
        if store.selectedTab == .time {
            TimeTabView(store: store)
        } else if store.selectedTab == .session {
            SessionTabView(sessionStore: store.sessionStore)
        } else if store.selectedTab == .subscription {
            SubscriptionView(store: store)
        } else if store.isCurrentMonth {
            switch store.effectiveCurrentMonthPhase {
            case .loaded(let bundle), .loading(cached: .some(let bundle)), .failed(_, cached: .some(let bundle)):
                cardsWithChart(daily: bundle.dailyBreakdown) {
                    PeriodCard(metric: store.selectedTab, icon: "calendar",
                               title: loc("today"), usage: bundle.today)
                    PeriodCard(metric: store.selectedTab, icon: "calendar.badge.clock",
                               title: loc("thisWeek"), usage: bundle.week)
                    PeriodCard(metric: store.selectedTab, icon: "chart.bar",
                               title: loc("thisMonth"), usage: bundle.month,
                               showStats: true)
                }
            case .loading(cached: nil), .idle:
                loadingView
            case .empty:
                noDataView
            case .failed(_, cached: nil):
                errorView
            }
        } else {
            switch store.effectiveHistoricalMonthPhase {
            case .loaded(let bundle), .loading(cached: .some(let bundle)), .failed(_, cached: .some(let bundle)):
                cardsWithChart(daily: bundle.dailyBreakdown) {
                    PeriodCard(metric: store.selectedTab, icon: "chart.bar",
                               title: loc("monthlyTotal"), usage: bundle.month,
                               showStats: true)
                }
            case .loading(cached: nil), .idle:
                loadingView
            case .empty:
                noDataView
            case .failed(_, cached: nil):
                errorView
            }
        }
    }

    @ViewBuilder
    private func cardsWithChart<Cards: View>(daily: [DailyUsage]?, @ViewBuilder cards: () -> Cards) -> some View {
        VStack(spacing: 8) {
            cards()
            if let daily = daily, !daily.isEmpty {
                DailyChart(data: daily, mode: store.selectedTab,
                           year: store.viewingYear, month: store.viewingMonth)
            }
            if store.selectedTab == .cost {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 9.5))
                    Text(loc("costApiEquivNote"))
                        .font(.system(size: 9.5))
                    Spacer(minLength: 0)
                }
                .foregroundColor(.secondary.opacity(0.8))
                .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    // ── Footer ──
    private var footer: some View {
        HStack(spacing: 12) {
            if store.selectedTab == .subscription {
                if let qt = store.quotaUpdatedAt {
                    Text(String(format: loc("updated"), timeAgo(qt, loc)))
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                }
            } else if let time = store.lastUpdate, store.isCurrentMonth {
                Text(String(format: loc("updated"), timeAgo(time, loc)))
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
            } else if !store.isCurrentMonth {
                Text(loc("cachedData"))
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
            }
            Spacer()

            LanguageSwitcher(store: store)
            OptionsMenu(store: store, loc: loc)

            Button(action: { store.refresh(force: true) }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help(loc("refresh"))
            .keyboardShortcut("r", modifiers: .command)

            Button(action: onQuit) {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help(loc("quit"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(loc("loading"))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(height: 120)
    }

    private var errorView: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundColor(.orange)
            Text(loc("loadFailed"))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Button(loc("retry")) {
                store.refresh(force: true)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.accentColor)
        }
        .frame(height: 120)
    }

    private var noDataView: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 24))
                .foregroundColor(.secondary)
            Text(loc("noMonthData"))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(height: 120)
    }
}
