import SwiftUI
import AppKit

// Time tab + oscilloscope Week / Month / Year single-plane precision charts.

// MARK: - Time Tab

private struct TimeStripHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let n = nextValue()
        if n > 0 { value = n }
    }
}

struct TimeTabView: View {
    @ObservedObject var store: UsageStore
    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @Environment(\.telemetryStaticRender) private var isStaticRender
    @Environment(\.telemetryReduceMotion) private var reduceMotion
    @State private var rangeTransition: TabTransitionState<TimeRange>
    @State private var stripHeight: CGFloat = 25

    init(store: UsageStore) {
        self.store = store
        _rangeTransition = State(initialValue: TabTransitionState(initial: store.timeRange))
    }

    private var rangeAnimation: Animation? {
        guard !isStaticRender else { return nil }
        if reduceMotion { return TelemetryMotion.reduced }
        return theme.isNotch ? TelemetryMotion.tabContent : TelemetryMotion.popoverTabContent
    }

    var body: some View {
        let activeRange = rangeTransition.activeId
        let activeKey = PanelHeightKey.make(
            store: store,
            tabOverride: .time,
            timeRangeOverride: activeRange
        )
        VStack(spacing: 0) {
            TelemetrySegmentedStrip(
                items: TimeRange.allCases,
                selection: $store.timeRange,
                label: { $0.label(loc) }
            )
            .background(GeometryReader { geo in
                Color.clear.preference(key: TimeStripHeightKey.self, value: geo.size.height)
            })
            .onPreferenceChange(TimeStripHeightKey.self) { h in
                if h > 1, abs(h - stripHeight) > 0.5 {
                    stripHeight = h
                }
            }

            ZStack(alignment: .top) {
                rangeContent(for: activeRange)
                    .id(activeRange)
                    .background(GeometryReader { geo in
                        Color.clear.preference(
                            key: ContentHeightsKey.self,
                            value: [activeKey: stripHeight + geo.size.height]
                        )
                    })
                    .transition(
                        TelemetryMotion.tabContentTransition(
                            direction: rangeTransition.direction,
                            isNotch: theme.isNotch,
                            reduceMotion: reduceMotion
                        )
                    )
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .clipped()
            .animation(rangeAnimation, value: rangeTransition)
        }
        .onChange(of: store.timeRange) { nextRange in
            var next = rangeTransition
            next.transition(to: nextRange, in: TimeRange.allCases)
            rangeTransition = next
        }
    }

    @ViewBuilder
    private func rangeContent(for range: TimeRange) -> some View {
        switch range {
        case .week:
            if let data = activeTimeData {
                if store.visualMode == .instrument {
                    PolarChronometerWeekChart(store: store, timeData: data)
                } else {
                    WeekTimeChart(store: store, timeData: data)
                }
            } else {
                timeStateView
            }
        case .month:
            if let data = activeTimeData {
                if store.visualMode == .instrument {
                    MonthElevationInstrumentChart(
                        timeData: data,
                        year: store.viewingYear,
                        month: store.viewingMonth
                    )
                } else {
                    MonthTimeChart(
                        timeData: data,
                        year: store.viewingYear,
                        month: store.viewingMonth
                    )
                }
            } else {
                timeStateView
            }
        case .year:
            if store.visualMode == .instrument {
                TopographicYearContourChart(store: store)
            } else {
                YearHeatmap(store: store)
            }
        }
    }

    private var activeTimeData: TimeData? {
        if store.isCurrentMonth {
            return store.effectiveCurrentMonthPhase.value?.time
        }
        return store.effectiveHistoricalMonthPhase.value?.time
    }

    @ViewBuilder
    private var timeStateView: some View {
        let isFailed = store.isCurrentMonth
            ? store.effectiveCurrentMonthPhase.hasFailedWithoutValue
            : store.effectiveHistoricalMonthPhase.hasFailedWithoutValue
        let isLoadingScope = store.isCurrentMonth
            ? store.effectiveCurrentMonthPhase.isLoading
            : store.effectiveHistoricalMonthPhase.isLoading

        if isLoadingScope || store.isLoading {
            TelemetrySkeleton()
        } else {
            VStack(spacing: 8) {
                Image(systemName: isFailed ? "exclamationmark.triangle" : "tray")
                    .font(.system(size: 18))
                    .foregroundColor(isFailed ? theme.signalAmber : theme.inkMuted)
                Text(loc(isFailed ? "loadFailed" : "noData"))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(theme.inkSecondary)
                if isFailed {
                    Text(loc("retry").uppercased())
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(0.8)
                        .foregroundColor(theme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(theme.surfaceRaised.opacity(theme.isDark ? 0.35 : 0.55))
                        .overlay(Rectangle().stroke(theme.accent.opacity(0.6), lineWidth: 0.75))
                        .contentShape(Rectangle())
                        .onTapGesture { store.refresh(force: true) }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 120)
        }
    }
}

/// Thread-safe static cache for DateFormatters and localized weekday symbols
/// so 60Hz hover handlers and SwiftUI body evaluations never allocate DateFormatter instances.
enum TimeDateFormatters {
    private static let lock = NSLock()
    private static var mediumDateByLocale: [String: DateFormatter] = [:]
    private static var weekdaySymbolsByLocale: [String: [String]] = [:]

    static func displayDate(_ dayKey: String, languageCode: String) -> String {
        guard let date = TimeLogic.date(fromDayKey: dayKey) else { return dayKey }
        lock.lock()
        defer { lock.unlock() }
        let df: DateFormatter
        if let existing = mediumDateByLocale[languageCode] {
            df = existing
        } else {
            let created = DateFormatter()
            created.dateStyle = .medium
            created.timeStyle = .none
            created.locale = Locale(identifier: languageCode)
            mediumDateByLocale[languageCode] = created
            df = created
        }
        return df.string(from: date)
    }

    static func mondayFirstWeekdaySymbols(languageCode: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = weekdaySymbolsByLocale[languageCode] {
            return cached
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: languageCode)
        let symbols = df.shortWeekdaySymbols ?? []
        let result: [String]
        if symbols.count == 7 {
            result = (0..<7).map { symbols[($0 + 1) % 7] }
        } else {
            result = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        }
        weekdaySymbolsByLocale[languageCode] = result
        return result
    }
}

/// Monday-first localized short weekday symbols (cached per locale).
func mondayFirstWeekdaySymbols(_ loc: Localizer) -> [String] {
    TimeDateFormatters.mondayFirstWeekdaySymbols(languageCode: loc.language.rawValue)
}

/// Edge-to-edge 3-column hairline KPI strip with sculptural `.ultraLight` numerals.
struct TimeKpiStrip: View {
    let items: [(label: String, value: String)]
    @Environment(\.agyTheme) private var theme

    private static func splitKpiValue(_ raw: String) -> (number: String, unit: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", "") }
        var splitIdx = trimmed.startIndex
        while splitIdx < trimmed.endIndex {
            let ch = trimmed[splitIdx]
            if ch.isNumber || ch == "." || ch == "," || ch == "-" || ch == "+" {
                splitIdx = trimmed.index(after: splitIdx)
            } else {
                break
            }
        }
        if splitIdx == trimmed.startIndex {
            return (trimmed.uppercased(), "")
        }
        let num = String(trimmed[..<splitIdx])
        let unit = String(trimmed[splitIdx...]).trimmingCharacters(in: .whitespaces).uppercased()
        return (num, unit)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    let parts = Self.splitKpiValue(item.value)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.label.uppercased())
                            .font(.system(size: 7.5, weight: .regular, design: .monospaced))
                            .tracking(0.8)
                            .foregroundColor(theme.inkMuted)
                            .lineLimit(1)
                        HStack(alignment: .firstTextBaseline, spacing: 1.5) {
                            Text(parts.number)
                                .font(.system(size: 21, weight: .ultraLight, design: .monospaced))
                                .monospacedDigit()
                                .foregroundColor(theme.inkPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            if !parts.unit.isEmpty {
                                Text(parts.unit)
                                    .font(.system(size: 8.5, weight: .regular, design: .monospaced))
                                    .tracking(0.5)
                                    .foregroundColor(theme.inkMuted)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)

                    if idx < items.count - 1 {
                        Rectangle().fill(theme.hairline.opacity(0.8)).frame(width: 1)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            HairlineRule(showCrosshairs: true)
        }
    }
}

// MARK: - Week View (Oscilloscope Traces)

struct WeekTimeChart: View {
    @ObservedObject var store: UsageStore
    let timeData: TimeData

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @Environment(\.telemetryPanelVisible) private var isPanelVisible

    private struct HoveredInterval: Equatable, Sendable {
        let dayKey: String
        let interval: ActiveInterval
    }
    @State private var inspection = ChartInspectionState<[String], HoveredInterval>(scope: [])

    private var hovered: HoveredInterval? {
        inspection.scope == dayKeys ? inspection.target : nil
    }

    private let rowHeight: CGFloat = 21
    private let labelWidth: CGFloat = 32
    private let totalWidth: CGFloat = 44
    private let gridHours = [0, 6, 12, 18, 24]

    private var monthPrefix: String {
        String(format: "%04d-%02d-", store.viewingYear, store.viewingMonth)
    }
    private var weeks: [Date] {
        TimeLogic.weeksOfMonth(year: store.viewingYear, month: store.viewingMonth)
    }
    private var selectedWeekIndex: Int? {
        store.resolvedWeekMonday.flatMap { TimeLogic.weekIndex(of: $0, in: weeks) }
    }
    private var dayKeys: [String] {
        store.resolvedWeekMonday.map(TimeLogic.weekDayKeys) ?? []
    }
    private var renderedDayKeys: [String] {
        TimeLogic.renderedDayKeys(dayKeys, monthPrefix: monthPrefix, days: timeData.days)
    }
    private var todayKey: String { AppDate.dayKey(Date()) }
    private var weekTotal: Int {
        TimeLogic.totalSeconds(in: timeData.days, dayKeys: renderedDayKeys)
    }
    private var avgDivisor: Int {
        TimeLogic.avgDivisor(dayKeys: dayKeys, todayKey: todayKey, renderedCount: renderedDayKeys.count)
    }
    private var weekdaySymbols: [String] { mondayFirstWeekdaySymbols(loc) }

    private var nowFractionOfDay: CGFloat {
        let cal = AppDate.gregorian
        let comps = cal.dateComponents([.hour, .minute], from: Date())
        let secs = (comps.hour ?? 0) * 3600 + (comps.minute ?? 0) * 60
        return CGFloat(min(max(secs, 0), 86400)) / 86400.0
    }

    var body: some View {
        let index = selectedWeekIndex
        let atFirst = (index ?? 0) <= 0
        let atLast = index.map { $0 >= weeks.count - 1 } ?? true

        VStack(alignment: .leading, spacing: 0) {
            TimeKpiStrip(items: [
                (loc("timeWeekTotal"), TimeLogic.formatDurationShort(weekTotal)),
                (loc("timeDailyAvg"), TimeLogic.formatDurationShort(weekTotal / avgDivisor)),
                (loc("timeLongest"), TimeLogic.formatDurationShort(
                    TimeLogic.longestIntervalSeconds(in: timeData.days, dayKeys: renderedDayKeys))),
            ])

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    TelemetryStepper(
                        label: "\(shortDate(dayKeys.first ?? "")) – \(shortDate(dayKeys.last ?? ""))",
                        canDecrement: !atFirst,
                        canIncrement: !atLast,
                        onDecrement: { store.navigateTimeWeek(offset: -1) },
                        onIncrement: { store.navigateTimeWeek(offset: 1) }
                    )
                    Spacer()
                    hoverReadout
                }

                VStack(spacing: 2) {
                    ForEach(Array(dayKeys.enumerated()), id: \.element) { idx, key in
                        weekRow(index: idx, dayKey: key)
                    }
                }
                .background(DotGraticuleBackground(spacing: 12))

                axisLabels
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .onAppear { inspection.syncScope(dayKeys) }
        .onChange(of: dayKeys) { nextKeys in inspection.syncScope(nextKeys) }
        .onChange(of: isPanelVisible) { visible in if !visible { inspection.reset() } }
        .onDisappear { inspection.reset() }
    }

    private var hoverReadout: some View {
        HStack(spacing: 5) {
            if let h = hovered {
                Rectangle()
                    .fill(theme.modelColor(h.interval.model))
                    .frame(width: 5, height: 5)
                Text(shortDate(h.dayKey))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(theme.inkSecondary)
                Text("\(TimeLogic.formatClock(h.interval.startSec))–\(TimeLogic.formatClock(h.interval.endSec))")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.inkPrimary)
                Text(TimeLogic.formatDurationShort(h.interval.durationSeconds).uppercased())
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(theme.accent)
            }
        }
        .frame(height: 14)
    }

    private func shortDate(_ dayKey: String) -> String {
        guard let date = TimeLogic.date(fromDayKey: dayKey) else { return dayKey }
        let cal = AppDate.gregorian
        return "\(cal.component(.month, from: date))/\(cal.component(.day, from: date))"
    }

    private func weekRow(index: Int, dayKey: String) -> some View {
        let inMonth = dayKey.hasPrefix(monthPrefix)
        let day = timeData.days[dayKey]
        let total = day?.totalSeconds ?? 0
        let isToday = dayKey == todayKey

        return HStack(spacing: 6) {
            Text((weekdaySymbols.indices.contains(index) ? weekdaySymbols[index] : "").uppercased())
                .font(.system(size: 8.5, weight: isToday ? .bold : .medium, design: .monospaced))
                .foregroundColor(isToday ? theme.accent : theme.inkSecondary)
                .frame(width: labelWidth, alignment: .leading)

            timeline(day: day, dayKey: dayKey, dimmed: !inMonth, isToday: isToday)
                .frame(height: rowHeight)

            Text(inMonth || day != nil ? TimeLogic.formatDurationShort(total).uppercased() : "")
                .font(.system(size: 9, weight: total > 0 ? .semibold : .regular, design: .monospaced))
                .foregroundColor(total > 0 ? theme.inkPrimary : theme.inkMuted)
                .frame(width: totalWidth, alignment: .trailing)
        }
        .padding(.vertical, 1)
        .background(isToday ? theme.accentSoft : Color.clear)
    }

    private func timeline(day: DayTimeUsage?, dayKey: String, dimmed: Bool, isToday: Bool) -> some View {
        let intervals = day?.intervals ?? []
        return GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                if dimmed {
                    Rectangle()
                        .fill(theme.hairline.opacity(0.4))
                        .frame(width: max(0, w - 2), height: rowHeight - 2)
                        .offset(x: 1)
                }
                ForEach(gridHours, id: \.self) { h in
                    Rectangle()
                        .fill(theme.hairline)
                        .frame(width: 1)
                        .offset(x: min(w - 1, w * CGFloat(h) / 24.0))
                }
                Rectangle()
                    .fill(theme.hairline)
                    .frame(width: w, height: 1)
                if isToday {
                    Rectangle()
                        .fill(theme.accent)
                        .frame(width: 1.2, height: rowHeight)
                        .offset(x: min(w - 1.2, w * nowFractionOfDay))
                }
                ForEach(Array(intervals.enumerated()), id: \.offset) { _, interval in
                    intervalTrace(interval, dayKey: dayKey, width: w)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let pt):
                    inspection.syncScope(dayKeys)
                    if let hit = Self.hitTestInterval(x: pt.x, width: w, intervals: intervals) {
                        inspection.setTarget(HoveredInterval(dayKey: dayKey, interval: hit))
                    } else if hovered?.dayKey == dayKey {
                        inspection.reset()
                    }
                case .ended:
                    if hovered?.dayKey == dayKey {
                        inspection.reset()
                    }
                }
            }
        }
    }

    private func intervalTrace(_ interval: ActiveInterval, dayKey: String, width w: CGFloat) -> some View {
        let barW = max(3, w * CGFloat(max(interval.durationSeconds, 120)) / 86400.0)
        let x = min(max(0, w * CGFloat(interval.startSec) / 86400.0), max(0, w - barW))
        let color = theme.modelColor(interval.model)
        let isHovered = (hovered == HoveredInterval(dayKey: dayKey, interval: interval))

        return HStack(spacing: 0) {
            Rectangle().fill(color).frame(width: 1, height: isHovered ? 10 : 8)
            Rectangle().fill(color.opacity(isHovered ? 1.0 : 0.92)).frame(width: max(1, barW - 2), height: isHovered ? 5.5 : 4)
            Rectangle().fill(color).frame(width: 1, height: isHovered ? 10 : 8)
        }
        .frame(width: barW, height: 10)
        .offset(x: x)
        .allowsHitTesting(false)
    }

    private static func hitTestInterval(x: CGFloat, width w: CGFloat, intervals: [ActiveInterval]) -> ActiveInterval? {
        guard w > 0, !intervals.isEmpty else { return nil }
        let tol: CGFloat = 3.0
        var best: ActiveInterval? = nil
        var bestDist = CGFloat.greatestFiniteMagnitude
        for interval in intervals {
            let barW = max(3, w * CGFloat(max(interval.durationSeconds, 120)) / 86400.0)
            let barX = min(max(0, w * CGFloat(interval.startSec) / 86400.0), max(0, w - barW))
            if x >= barX - tol && x <= barX + barW + tol {
                let d = abs(x - (barX + barW * 0.5))
                if d < bestDist {
                    bestDist = d
                    best = interval
                }
            }
        }
        return best
    }

    private var axisLabels: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: labelWidth, height: 1)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    ForEach(gridHours, id: \.self) { h in
                        Text(String(format: "%02d", h))
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(theme.inkMuted)
                            .position(x: min(max(w * CGFloat(h) / 24.0, 6), w - 8), y: 5)
                    }
                }
            }
            .frame(height: 10)
            Color.clear.frame(width: totalWidth, height: 1)
        }
    }
}

// MARK: - Month View

struct MonthTimeChart: View {
    let timeData: TimeData
    let year: Int
    let month: Int

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @Environment(\.telemetryPanelVisible) private var isPanelVisible

    private struct HoveredInterval: Equatable, Sendable {
        let dayKey: String
        let interval: ActiveInterval
    }
    @State private var inspection = ChartInspectionState<String, HoveredInterval>(scope: "")

    private var hovered: HoveredInterval? {
        inspection.scope == monthPrefix ? inspection.target : nil
    }

    private let rowHeight: CGFloat = 25
    private let labelWidth: CGFloat = 32
    private let totalWidth: CGFloat = 44

    private var monthPrefix: String { String(format: "%04d-%02d-", year, month) }
    private var todayKey: String { AppDate.dayKey(Date()) }

    private var weeks: [[String]] {
        TimeLogic.weeksOfMonth(year: year, month: month).map(TimeLogic.weekDayKeys)
    }

    private var monthDayKeys: [String] {
        timeData.days.keys.filter { $0.hasPrefix(monthPrefix) }
    }

    private var monthTotal: Int {
        TimeLogic.totalSeconds(in: timeData.days, dayKeys: monthDayKeys)
    }

    private var activeDays: Int {
        monthDayKeys.filter { (timeData.days[$0]?.totalSeconds ?? 0) > 0 }.count
    }

    var body: some View {
        let avgSeconds = activeDays > 0 ? monthTotal / activeDays : 0

        VStack(alignment: .leading, spacing: 0) {
            TimeKpiStrip(items: [
                (loc("timeMonthTotal"), TimeLogic.formatDurationShort(monthTotal)),
                (loc("timeDailyAvg"), TimeLogic.formatDurationShort(avgSeconds)),
                (loc("timeLongest"), TimeLogic.formatDurationShort(
                    TimeLogic.longestIntervalSeconds(in: timeData.days, dayKeys: monthDayKeys))),
            ])

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let h = hovered {
                        Rectangle()
                            .fill(theme.modelColor(h.interval.model))
                            .frame(width: 5, height: 5)
                        Text("\(shortDate(h.dayKey)) · \(TimeLogic.formatClock(h.interval.startSec))–\(TimeLogic.formatClock(h.interval.endSec))")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.inkPrimary)
                        Text(TimeLogic.formatDurationShort(h.interval.durationSeconds).uppercased())
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(theme.accent)
                    }
                    Spacer()
                }
                .frame(height: 12)

                weekdayHeader

                VStack(spacing: 2) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, dayKeys in
                        weekRow(dayKeys: dayKeys)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        .onAppear {
            inspection.syncScope(monthPrefix)
        }
        .onChange(of: monthPrefix) { nextPrefix in
            inspection.syncScope(nextPrefix)
        }
        .onChange(of: isPanelVisible) { visible in
            if !visible {
                inspection.reset()
            }
        }
        .onDisappear {
            inspection.reset()
        }
    }

    private func shortDate(_ dayKey: String) -> String {
        guard let date = TimeLogic.date(fromDayKey: dayKey) else { return dayKey }
        let cal = AppDate.gregorian
        return "\(cal.component(.month, from: date))/\(cal.component(.day, from: date))"
    }

    private func dayNumString(_ dayKey: String) -> String {
        guard let date = TimeLogic.date(fromDayKey: dayKey) else { return "" }
        return String(format: "%02d", AppDate.gregorian.component(.day, from: date))
    }

    private var weekdayHeader: some View {
        let symbols = mondayFirstWeekdaySymbols(loc)
        return HStack(spacing: 6) {
            Color.clear.frame(width: labelWidth, height: 1)
            GeometryReader { geo in
                let dayW = geo.size.width / 7
                ZStack(alignment: .leading) {
                    ForEach(0..<7, id: \.self) { i in
                        Text(symbols[i].uppercased())
                            .font(.system(size: 7.5, weight: .regular, design: .monospaced))
                            .tracking(0.6)
                            .foregroundColor(theme.inkMuted)
                            .position(x: dayW * (CGFloat(i) + 0.5), y: 5)
                    }
                }
            }
            .frame(height: 10)
            Color.clear.frame(width: totalWidth, height: 1)
        }
    }

    private func weekRow(dayKeys: [String]) -> some View {
        let inMonthKeys = dayKeys.filter { $0.hasPrefix(monthPrefix) }
        let total = TimeLogic.totalSeconds(in: timeData.days, dayKeys: inMonthKeys)
        return HStack(spacing: 6) {
            Text(shortDate(dayKeys.first ?? ""))
                .font(.system(size: 8.5, weight: .regular, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(theme.inkMuted)
                .frame(width: labelWidth, alignment: .leading)
            timeline(dayKeys: dayKeys)
                .frame(height: rowHeight)
            Text(TimeLogic.formatDurationShort(total).uppercased())
                .font(.system(size: 8.5, weight: total > 0 ? .medium : .regular, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(total > 0 ? theme.inkPrimary : theme.inkMuted)
                .frame(width: totalWidth, alignment: .trailing)
        }
        .padding(.vertical, 1)
    }

    private func timeline(dayKeys: [String]) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let dayW = w / 7
            ZStack(alignment: .leading) {
                ForEach(Array(dayKeys.enumerated()), id: \.offset) { i, key in
                    let inMonth = key.hasPrefix(monthPrefix)
                    let isToday = (key == todayKey)
                    let cellW = max(0, dayW - 2)
                    let cellX = dayW * CGFloat(i) + 1
                    let cellFill: Color = !inMonth
                        ? theme.hairline.opacity(0.40)
                        : (isToday ? theme.accentSoft : theme.surface.opacity(0.75))

                    Rectangle()
                        .fill(cellFill)
                        .frame(width: cellW, height: rowHeight - 2)
                        .overlay(
                            Rectangle()
                                .strokeBorder(
                                    isToday ? theme.accent : theme.hairline.opacity(inMonth ? 0.55 : 0.25),
                                    lineWidth: 1.0
                                )
                        )
                        .offset(x: cellX)
                        .allowsHitTesting(false)

                    if inMonth {
                        Text(dayNumString(key))
                            .font(.system(size: 7, weight: isToday ? .medium : .regular, design: .monospaced))
                            .foregroundColor(isToday ? theme.accent : theme.inkMuted)
                            .offset(x: cellX + 3, y: -5.5)
                            .allowsHitTesting(false)
                    }
                }

                ForEach(Array(dayKeys.enumerated()), id: \.offset) { i, key in
                    if key.hasPrefix(monthPrefix), let day = timeData.days[key] {
                        ForEach(Array(day.intervals.enumerated()), id: \.offset) { _, interval in
                            intervalBar(interval, dayKey: key, dayIndex: i, dayWidth: dayW)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let pt):
                    guard dayW > 0 else { return }
                    inspection.syncScope(monthPrefix)
                    let idx = min(dayKeys.count - 1, max(0, Int(floor(pt.x / dayW))))
                    let key = dayKeys[idx]
                    if key.hasPrefix(monthPrefix), let day = timeData.days[key] {
                        let innerX0 = dayW * CGFloat(idx) + 2.0
                        let innerW = max(1.0, dayW - 4.0)
                        if let hit = Self.hitTestCellInterval(
                            x: pt.x,
                            innerX0: innerX0,
                            innerW: innerW,
                            intervals: day.intervals
                        ) {
                            inspection.setTarget(HoveredInterval(dayKey: key, interval: hit))
                        } else if let h = hovered, dayKeys.contains(h.dayKey) {
                            inspection.reset()
                        }
                    } else if let h = hovered, dayKeys.contains(h.dayKey) {
                        inspection.reset()
                    }
                case .ended:
                    if let h = hovered, dayKeys.contains(h.dayKey) { inspection.reset() }
                }
            }
        }
    }

    private func intervalBar(
        _ interval: ActiveInterval,
        dayKey: String,
        dayIndex: Int,
        dayWidth: CGFloat
    ) -> some View {
        let capWidth = max(2, (dayWidth - 4) * CGFloat(max(interval.durationSeconds, 120)) / 86400.0)
        let x = dayWidth * CGFloat(dayIndex) + 2
            + min(max(0, (dayWidth - 4) * CGFloat(interval.startSec) / 86400.0), max(0, dayWidth - 4 - capWidth))
        let isHovered = (hovered == HoveredInterval(dayKey: dayKey, interval: interval))

        return Rectangle()
            .fill(theme.modelColor(interval.model).opacity(isHovered ? 1.0 : 0.92))
            .frame(width: capWidth, height: isHovered ? 5 : 3.5)
            .offset(x: x, y: 5.5)
            .allowsHitTesting(false)
    }

    private static func hitTestCellInterval(
        x: CGFloat,
        innerX0: CGFloat,
        innerW: CGFloat,
        intervals: [ActiveInterval]
    ) -> ActiveInterval? {
        guard innerW > 0, !intervals.isEmpty else { return nil }
        let tol: CGFloat = 2.5
        var best: ActiveInterval? = nil
        var bestDist = CGFloat.greatestFiniteMagnitude
        for interval in intervals {
            let capW = max(2.0, innerW * CGFloat(max(interval.durationSeconds, 120)) / 86400.0)
            let bx = innerX0 + min(
                max(0, innerW * CGFloat(interval.startSec) / 86400.0),
                max(0, innerW - capW)
            )
            if x >= bx - tol && x <= bx + capW + tol {
                let d = abs(x - (bx + capW * 0.5))
                if d < bestDist {
                    bestDist = d
                    best = interval
                }
            }
        }
        return best
    }
}

// MARK: - Year View (Precision Matrix Heatmap + Theme Ramp)

struct YearHeatmap: View {
    @ObservedObject var store: UsageStore
    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @Environment(\.telemetryPanelVisible) private var isPanelVisible

    @State private var inspection = ChartInspectionState<Int, String>(scope: 0)

    private var hoveredKey: String? {
        inspection.scope == store.viewingTimeYear ? inspection.target : nil
    }

    private let cellSize: CGFloat = 5.9
    private let cellSpacing: CGFloat = 1.1
    private let weekdayAxisWidth: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch store.effectiveYearPhase {
            case .loaded(let days), .loading(cached: .some(let days)), .failed(_, cached: .some(let days)):
                yearContent(days)
            case .empty:
                yearContent([:])
            case .failed(_, cached: nil):
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 18)).foregroundColor(theme.signalAmber)
                    Text(loc("loadFailed"))
                        .font(.system(size: 10.5, design: .monospaced)).foregroundColor(theme.inkSecondary)
                    Text(loc("retry").uppercased())
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(0.8)
                        .foregroundColor(theme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(theme.surfaceRaised.opacity(theme.isDark ? 0.35 : 0.55))
                        .overlay(Rectangle().stroke(theme.accent.opacity(0.6), lineWidth: 0.75))
                        .contentShape(Rectangle())
                        .onTapGesture { store.loadYearTime(store.viewingTimeYear, force: true) }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 120)
            case .idle, .loading(cached: nil):
                TelemetrySkeleton()
            }
        }
        .onAppear {
            inspection.syncScope(store.viewingTimeYear)
            if case .idle = store.effectiveYearPhase {
                store.loadYearTime(store.viewingTimeYear)
            }
        }
        .onChange(of: store.viewingTimeYear) { nextYear in inspection.syncScope(nextYear) }
        .onChange(of: isPanelVisible) { visible in if !visible { inspection.reset() } }
        .onDisappear { inspection.reset() }
    }

    @ViewBuilder
    private func yearContent(_ days: [String: Int]) -> some View {
        let year = store.viewingTimeYear
        let summary = TimeLogic.yearSummary(days: days, year: year)

        TimeKpiStrip(items: [
            (loc("timeYearTotal"), TimeLogic.formatDurationShort(summary.totalSeconds)),
            (loc("timeActiveDays"), String(format: loc("daysUnitFmt"), summary.activeDays)),
            (loc("timeStreak"), String(format: loc("daysUnitFmt"), summary.longestStreakDays)),
        ])

        VStack(alignment: .leading, spacing: 6) {
            monthAxisHeader(year: year)

            HStack(alignment: .top, spacing: 4) {
                VStack(spacing: cellSpacing) {
                    ForEach(0..<7, id: \.self) { row in
                        let label = (row == 0 ? "M" : (row == 2 ? "W" : (row == 4 ? "F" : "")))
                        Text(label)
                            .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.inkMuted)
                            .frame(width: weekdayAxisWidth, height: cellSize, alignment: .trailing)
                    }
                }

                grid(days)
            }

            HStack {
                if let key = hoveredKey {
                    Text("+ \(displayDate(key)) · \(TimeLogic.formatDurationShort(days[key] ?? 0).uppercased())")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.inkPrimary)
                }
                Spacer()
                legend
            }
            .frame(height: 12)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func monthAxisHeader(year: Int) -> some View {
        let months = TimeLogic.monthLabelColumns(year: year)
        let names = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
        let stride = cellSize + cellSpacing

        return HStack(spacing: 4) {
            Color.clear.frame(width: weekdayAxisWidth, height: 1)
            ZStack(alignment: .leading) {
                ForEach(months, id: \.month) { entry in
                    Text(names[entry.month - 1])
                        .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.inkMuted)
                        .offset(x: CGFloat(entry.col) * stride)
                }
            }
            .frame(width: 53 * cellSize + 52 * cellSpacing, height: 10, alignment: .leading)
        }
    }

    private func displayDate(_ dayKey: String) -> String {
        TimeDateFormatters.displayDate(dayKey, languageCode: loc.language.rawValue)
    }

    private func grid(_ days: [String: Int]) -> some View {
        let year = store.viewingTimeYear
        let startMonday = TimeLogic.yearGridStartMonday(year: year)
        let yearPrefix = String(format: "%04d-", year)
        return VStack(alignment: .leading, spacing: cellSpacing) {
            ForEach(0..<7, id: \.self) { row in
                HStack(spacing: cellSpacing) {
                    ForEach(0..<53, id: \.self) { col in
                        cell(col: col, row: row, year: year, startMonday: startMonday,
                             yearPrefix: yearPrefix, days: days)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(col: Int, row: Int, year: Int, startMonday: Date?, yearPrefix: String,
                      days: [String: Int]) -> some View {
        let key = startMonday.flatMap { TimeLogic.dayKey(col: col, row: row, startMonday: $0) }
        if let key = key, key.hasPrefix(yearPrefix) {
            let isHovered = (hoveredKey == key)
            Rectangle()
                .fill(theme.heatmapColor(level: TimeLogic.heatLevel(days[key] ?? 0)))
                .frame(width: cellSize, height: cellSize)
                .overlay(
                    isHovered
                        ? Rectangle().stroke(theme.inkPrimary, lineWidth: 1)
                        : nil
                )
                .onHover { inside in
                    inspection.syncScope(year)
                    if inside {
                        inspection.setTarget(key)
                    } else if inspection.target == key {
                        inspection.reset()
                    }
                }
        } else {
            Color.clear.frame(width: cellSize, height: cellSize)
        }
    }

    private var legend: some View {
        HStack(spacing: 2.5) {
            Text(loc("timeLess").uppercased())
                .font(.system(size: 7.5, design: .monospaced))
                .foregroundColor(theme.inkMuted)
            ForEach(0..<5, id: \.self) { level in
                Rectangle()
                    .fill(theme.heatmapColor(level: level))
                    .frame(width: cellSize, height: cellSize)
            }
            Text(loc("timeMore").uppercased())
                .font(.system(size: 7.5, design: .monospaced))
                .foregroundColor(theme.inkMuted)
        }
    }
}
