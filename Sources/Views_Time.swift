import SwiftUI
import AppKit

// Time tab + oscilloscope Week / Month / Year single-plane precision charts.

// MARK: - Time Tab

struct TimeTabView: View {
    @ObservedObject var store: UsageStore
    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @Environment(\.telemetryStaticRender) private var isStaticRender
    @State private var rangeTransition: TabTransitionState<TimeRange>
    @State private var displayedRange: TimeRange
    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    init(store: UsageStore) {
        self.store = store
        _rangeTransition = State(initialValue: TabTransitionState(initial: store.timeRange))
        _displayedRange = State(initialValue: store.timeRange)
    }

    private var rangeAnimation: Animation? {
        guard !isStaticRender else { return nil }
        return reduceMotion ? TelemetryMotion.reduced : TelemetryMotion.tabContent
    }

    var body: some View {
        VStack(spacing: 0) {
            TelemetrySegmentedStrip(
                items: TimeRange.allCases,
                selection: $store.timeRange,
                label: { $0.label(loc) }
            )

            ZStack(alignment: .top) {
                rangeContent(for: displayedRange)
                    .id(displayedRange)
                    .transition(
                        TelemetryMotion.tabContentTransition(
                            direction: rangeTransition.direction,
                            reduceMotion: reduceMotion
                        )
                    )
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .clipped()
        }
        .onChange(of: store.timeRange) { nextRange in
            rangeTransition.transition(to: nextRange, in: TimeRange.allCases)
            withAnimation(rangeAnimation) {
                displayedRange = nextRange
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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
                MonthTimeChart(
                    timeData: data,
                    year: store.viewingYear,
                    month: store.viewingMonth,
                    instrumentElevation: store.visualMode == .instrument
                )
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
            return store.effectiveCurrentMonthPhase.value?.time ?? store.viewingTimeData
        }
        return store.effectiveHistoricalMonthPhase.value?.time ?? store.viewingTimeData
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

    private struct HoveredInterval: Equatable {
        let dayKey: String
        let interval: ActiveInterval
    }
    @State private var hovered: HoveredInterval? = nil

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
                    if let hit = Self.hitTestInterval(x: pt.x, width: w, intervals: intervals) {
                        hovered = HoveredInterval(dayKey: dayKey, interval: hit)
                    } else if hovered?.dayKey == dayKey {
                        hovered = nil
                    }
                case .ended:
                    if hovered?.dayKey == dayKey {
                        hovered = nil
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
    var instrumentElevation: Bool = false

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme

    private struct HoveredInterval: Equatable {
        let dayKey: String
        let interval: ActiveInterval
    }
    @State private var hovered: HoveredInterval? = nil
    @State private var hoveredDayKey: String? = nil

    private var rowHeight: CGFloat { instrumentElevation ? 28 : 25 }
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

    private var peakDay: (key: String, seconds: Int)? {
        var bestKey: String? = nil
        var bestSec = 0
        for key in monthDayKeys {
            let sec = timeData.days[key]?.totalSeconds ?? 0
            if sec > bestSec {
                bestSec = sec
                bestKey = key
            }
        }
        guard let k = bestKey, bestSec > 0 else { return nil }
        return (k, bestSec)
    }

    var body: some View {
        let peak = peakDay
        let peakKey = peak?.key
        let peakSeconds = peak?.seconds ?? 0
        let avgSeconds = activeDays > 0 ? monthTotal / activeDays : 0
        let monthStr = String(format: "%04d.%02d", year, month)

        VStack(alignment: .leading, spacing: 0) {
            TimeKpiStrip(items: [
                (loc("timeMonthTotal"), TimeLogic.formatDurationShort(monthTotal)),
                (loc("timeDailyAvg"), TimeLogic.formatDurationShort(avgSeconds)),
                (loc("timeLongest"), TimeLogic.formatDurationShort(
                    TimeLogic.longestIntervalSeconds(in: timeData.days, dayKeys: monthDayKeys))),
            ])

            VStack(alignment: .leading, spacing: 6) {
                if instrumentElevation {
                    HStack(spacing: 5) {
                        Text("03.2")
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundColor(theme.accent.opacity(0.9))
                        Text("\(loc("timeMonth").uppercased()) CADENCE // \(monthStr)")
                            .font(.system(size: 8, weight: .regular, design: .monospaced))
                            .tracking(0.8)
                            .foregroundColor(theme.inkSecondary)

                        Spacer(minLength: 4)

                        if let h = hovered {
                            HStack(spacing: 4) {
                                Rectangle()
                                    .fill(theme.accent)
                                    .frame(width: 4, height: 4)
                                Text("\(shortDate(h.dayKey)) · \(TimeLogic.formatClock(h.interval.startSec))–\(TimeLogic.formatClock(h.interval.endSec)) · \(TimeLogic.formatDurationShort(h.interval.durationSeconds).uppercased())")
                                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundColor(theme.accent)
                            }
                        } else if let key = hoveredDayKey {
                            let total = timeData.days[key]?.totalSeconds ?? 0
                            HStack(spacing: 4) {
                                Rectangle()
                                    .fill(theme.accent)
                                    .frame(width: 4, height: 4)
                                Text("\(shortDate(key)) · \(total > 0 ? TimeLogic.formatDurationShort(total).uppercased() : "0M")")
                                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundColor(theme.accent)
                            }
                        } else if peakSeconds > 0 {
                            Text("\(loc("peakTag")) \(TimeLogic.formatDurationShort(peakSeconds).uppercased())")
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                                .monospacedDigit()
                                .foregroundColor(theme.accent.opacity(0.88))
                        }
                    }
                    .frame(height: 12)
                } else {
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
                }

                weekdayHeader

                VStack(spacing: 2) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, dayKeys in
                        weekRow(dayKeys: dayKeys, peakKey: peakKey, peakSeconds: peakSeconds, avgSeconds: avgSeconds)
                    }
                }
            }
            .padding(.horizontal, instrumentElevation ? 14 : 12)
            .padding(.top, instrumentElevation ? 10 : 8)
            .padding(.bottom, instrumentElevation ? 10 : 8)

            if instrumentElevation {
                HairlineRule(showCrosshairs: false)
                HStack(spacing: 6) {
                    Text("* Daily active intervals & relative session elevation")
                        .font(.system(size: 8.5, weight: .regular, design: .serif))
                        .italic()
                        .foregroundColor(theme.inkMuted)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("FIG. 03")
                        .font(.system(size: 7.5, weight: .regular, design: .monospaced))
                        .tracking(0.8)
                        .foregroundColor(theme.inkMuted.opacity(0.75))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
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

    private func weekRow(dayKeys: [String], peakKey: String?, peakSeconds: Int, avgSeconds: Int) -> some View {
        let inMonthKeys = dayKeys.filter { $0.hasPrefix(monthPrefix) }
        let total = TimeLogic.totalSeconds(in: timeData.days, dayKeys: inMonthKeys)
        let containsPeak = (peakKey != nil && inMonthKeys.contains(peakKey!))
        return HStack(spacing: 6) {
            Text(shortDate(dayKeys.first ?? ""))
                .font(.system(size: 8.5, weight: .regular, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(theme.inkMuted)
                .frame(width: labelWidth, alignment: .leading)
            timeline(dayKeys: dayKeys, peakKey: peakKey, peakSeconds: peakSeconds, avgSeconds: avgSeconds)
                .frame(height: rowHeight)
            Text(TimeLogic.formatDurationShort(total).uppercased())
                .font(.system(size: 8.5, weight: total > 0 ? .medium : .regular, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(
                    (instrumentElevation && containsPeak)
                        ? theme.accent
                        : (total > 0 ? theme.inkPrimary : theme.inkMuted)
                )
                .frame(width: totalWidth, alignment: .trailing)
        }
        .padding(.vertical, 1)
    }

    @ViewBuilder
    private func timeline(dayKeys: [String], peakKey: String?, peakSeconds: Int, avgSeconds: Int) -> some View {
        if instrumentElevation {
            instrumentTimeline(dayKeys: dayKeys, peakKey: peakKey, peakSeconds: peakSeconds, avgSeconds: avgSeconds)
        } else {
            classicTimeline(dayKeys: dayKeys)
        }
    }

    private func instrumentTimeline(dayKeys: [String], peakKey: String?, peakSeconds: Int, avgSeconds: Int) -> some View {
        let normDenom = Double(max(3600, peakSeconds))
        let dayTotals = dayKeys.map { key -> Int in
            key.hasPrefix(monthPrefix) ? (timeData.days[key]?.totalSeconds ?? 0) : 0
        }
        let dayNumbers = dayKeys.map { key -> String in
            key.hasPrefix(monthPrefix) ? dayNumString(key) : ""
        }
        let inMonthFlags = dayKeys.map { $0.hasPrefix(monthPrefix) }
        let todayIdx = dayKeys.firstIndex(of: todayKey)
        let peakIdx = peakKey.flatMap { dayKeys.firstIndex(of: $0) }
        let rowIntervals: [[ActiveInterval]] = dayKeys.map { key in
            key.hasPrefix(monthPrefix) ? (timeData.days[key]?.intervals ?? []) : []
        }

        return GeometryReader { geo in
            let w = geo.size.width
            let dayW = w / 7.0
            ZStack {
                // Static hover-independent Archival Monthly Signal Specimen cells:
                // deterministic stipple density wash, AVG dashed reference line, 24h micro-oscilloscope baseline,
                // Fred corner brackets + 3x3 accent apex square on peak day, 1.5px top rule on today.
                StaticMonthRowCanvas(
                    dayKeys: dayKeys,
                    dayTotals: dayTotals,
                    dayNumbers: dayNumbers,
                    inMonthFlags: inMonthFlags,
                    todayIdx: todayIdx,
                    peakIdx: peakIdx,
                    avgSeconds: avgSeconds,
                    normDenom: normDenom,
                    theme: theme
                )
                .equatable()
                .allowsHitTesting(false)

                // Lightweight hover & interval pulse overlay (24h micro-oscilloscope pulse ticks)
                MonthRowPulseOverlayCanvas(
                    dayKeys: dayKeys,
                    rowIntervals: rowIntervals,
                    inMonthFlags: inMonthFlags,
                    todayIdx: todayIdx,
                    peakIdx: peakIdx,
                    hoveredDayKey: hoveredDayKey,
                    hoveredIntervalDayKey: hovered?.dayKey,
                    hoveredInterval: hovered?.interval,
                    anyHovered: hovered != nil || hoveredDayKey != nil,
                    theme: theme
                )
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let pt):
                    guard dayW > 0 else { return }
                    let idx = min(dayKeys.count - 1, max(0, Int(floor(pt.x / dayW))))
                    let key = dayKeys[idx]
                    if key.hasPrefix(monthPrefix) {
                        if hoveredDayKey != key {
                            hoveredDayKey = key
                        }
                        let cellX = dayW * CGFloat(idx) + 1.0
                        let cellW = max(0, dayW - 2.0)
                        let innerX0 = cellX + 2.5
                        let innerW = max(1.0, cellW - 5.0)
                        if let hit = Self.hitTestCellInterval(
                            x: pt.x,
                            innerX0: innerX0,
                            innerW: innerW,
                            intervals: rowIntervals[idx]
                        ) {
                            let nextHover = HoveredInterval(dayKey: key, interval: hit)
                            if hovered != nextHover {
                                hovered = nextHover
                            }
                        } else if let h = hovered, dayKeys.contains(h.dayKey) {
                            hovered = nil
                        }
                    } else {
                        if let h = hovered, dayKeys.contains(h.dayKey) { hovered = nil }
                        if let hk = hoveredDayKey, dayKeys.contains(hk) { hoveredDayKey = nil }
                    }
                case .ended:
                    if let h = hovered, dayKeys.contains(h.dayKey) { hovered = nil }
                    if let hk = hoveredDayKey, dayKeys.contains(hk) { hoveredDayKey = nil }
                }
            }
        }
    }

    private func classicTimeline(dayKeys: [String]) -> some View {
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
                            classicIntervalBar(interval, dayKey: key, dayIndex: i, dayWidth: dayW)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let pt):
                    guard dayW > 0 else { return }
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
                            hovered = HoveredInterval(dayKey: key, interval: hit)
                        } else if let h = hovered, dayKeys.contains(h.dayKey) {
                            hovered = nil
                        }
                    } else if let h = hovered, dayKeys.contains(h.dayKey) {
                        hovered = nil
                    }
                case .ended:
                    if let h = hovered, dayKeys.contains(h.dayKey) { hovered = nil }
                }
            }
        }
    }

    private func classicIntervalBar(
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

/// Hover-independent Archival Monthly Signal Specimen row canvas (Equatable).
/// Batches cell frames, out-of-month hatch, duotone stippled density washes (peak in Color 1,
/// other active days & AVG dashed line in Color 2), 24h micro-oscilloscope baselines,
/// today top rule, and peak Fred corner brackets.
private struct StaticMonthRowCanvas: View, Equatable {
    let dayKeys: [String]
    let dayTotals: [Int]
    let dayNumbers: [String]
    let inMonthFlags: [Bool]
    let todayIdx: Int?
    let peakIdx: Int?
    let avgSeconds: Int
    let normDenom: Double
    let theme: AGYTheme

    var body: some View {
        Canvas { context, size in
            let count = dayKeys.count
            guard count > 0 else { return }
            let dayW = size.width / CGFloat(count)
            let cellY: CGFloat = 1.0
            let cellH = max(4.0, size.height - 2.0)
            let baseY = cellY + cellH - 5.2

            var inMonthCells = Path()
            var outMonthCells = Path()
            var outMonthHatch = Path()
            var cellBorders = Path()
            var outBorders = Path()
            var baselines = Path()
            var avgDashedLine = Path()
            var otherDenseStipple = Path()
            var otherSoftStipple = Path()
            var peakDenseStipple = Path()
            var peakSoftStipple = Path()

            let stippleStep: CGFloat = 2.35
            let avgLineY: CGFloat? = {
                guard avgSeconds > 0 else { return nil }
                let avgFrac = min(1.0, Double(avgSeconds) / normDenom)
                let reach = max(3.5, CGFloat(avgFrac) * (cellH - 8.0))
                return max(cellY + 3.0, min(baseY - 2.0, baseY - reach))
            }()

            for i in 0..<count {
                let cellX = dayW * CGFloat(i) + 1.0
                let cellW = max(0, dayW - 2.0)
                let rect = CGRect(x: cellX, y: cellY, width: cellW, height: cellH)
                let inMonth = inMonthFlags[i]
                let isPeak = (i == peakIdx)

                if !inMonth {
                    outMonthCells.addRect(rect)
                    outBorders.addRect(rect)
                    // Delicate diagonal archival hatch for out-of-month cells
                    let step: CGFloat = 6.0
                    var hx = cellX - cellH
                    while hx < cellX + cellW {
                        let x0 = max(cellX, hx)
                        let y0 = cellY + cellH - max(0, cellX - hx)
                        let x1 = min(cellX + cellW, hx + cellH)
                        let y1 = cellY + max(0, (hx + cellH) - (cellX + cellW))
                        if x1 > x0 {
                            outMonthHatch.move(to: CGPoint(x: x0, y: y0))
                            outMonthHatch.addLine(to: CGPoint(x: x1, y: y1))
                        }
                        hx += step
                    }
                    continue
                }

                inMonthCells.addRect(rect)
                if !isPeak {
                    cellBorders.addRect(rect)
                }

                // 24h micro-oscilloscope baseline + 12h center calibration tick
                let lineX0 = cellX + 2.5
                let lineX1 = cellX + cellW - 2.5
                if lineX1 > lineX0 {
                    baselines.move(to: CGPoint(x: lineX0, y: baseY))
                    baselines.addLine(to: CGPoint(x: lineX1, y: baseY))
                    let midX = (lineX0 + lineX1) * 0.5
                    baselines.move(to: CGPoint(x: midX, y: baseY - 1.2))
                    baselines.addLine(to: CGPoint(x: midX, y: baseY + 1.2))
                }

                // Monthly AVG dashed elevation benchmark (Color 2) across in-month cells
                if let ay = avgLineY {
                    let avgX0 = (ay < cellY + 9.5) ? (cellX + 13.0) : (cellX + 2.0)
                    let avgX1 = cellX + cellW - 2.0
                    if avgX1 > avgX0 + 2.0 {
                        avgDashedLine.move(to: CGPoint(x: avgX0, y: ay))
                        avgDashedLine.addLine(to: CGPoint(x: avgX1, y: ay))
                    }
                }

                // Deterministic stippled density wash proportional to daily active hours
                let totalSec = dayTotals[i]
                if totalSec > 0 && cellW > 4 {
                    let frac = min(1.0, Double(totalSec) / normDenom)
                    let seed = Self.daySeed(dayKeys[i])
                    let cols = Int((cellW - 3.0) / stippleStep)
                    let maxReach = max(3.5, CGFloat(frac) * (cellH - 8.0))
                    let rows = Int((cellH - 6.0) / stippleStep)

                    for r in 0...max(0, rows) {
                        let py = baseY - 1.0 - CGFloat(r) * stippleStep
                        guard py >= cellY + 2.0 else { break }
                        let distAboveBase = baseY - py
                        guard distAboveBase <= maxReach + 4.0 else { break }

                        for c in 0...max(0, cols) {
                            let px = cellX + 2.0 + CGFloat(c) * stippleStep
                            guard px <= cellX + cellW - 2.0 else { break }
                            // Keep top-left day numeral zone optically clear
                            if px < cellX + 12.5 && py < cellY + 9.5 { continue }

                            let h = Self.stippleHash(seed, c, r)
                            let jx = (Double(h & 0xFF) / 255.0 - 0.5) * Double(stippleStep) * 0.85
                            let jy = (Double((h >> 8) & 0xFF) / 255.0 - 0.5) * Double(stippleStep) * 0.85
                            let gx = px + CGFloat(jx)
                            let gy = py + CGFloat(jy)
                            guard gx >= cellX + 1.5, gx <= cellX + cellW - 1.8,
                                  gy >= cellY + 1.8, gy <= baseY - 0.5 else { continue }

                            let decay = exp(-Double(distAboveBase) / (3.8 + 10.5 * frac))
                            let prob = min(0.86, decay * (0.26 + 0.58 * frac))
                            let roll = Double((h >> 16) & 0x3FF) / 1023.0
                            if roll < prob {
                                let sz: CGFloat = ((h >> 26) & 1 == 0) ? 0.9 : 1.15
                                let dotRect = CGRect(x: gx, y: gy, width: sz, height: sz)
                                if isPeak {
                                    if distAboveBase < maxReach * 0.55 {
                                        peakDenseStipple.addRect(dotRect)
                                    } else {
                                        peakSoftStipple.addRect(dotRect)
                                    }
                                } else {
                                    if distAboveBase < maxReach * 0.55 {
                                        otherDenseStipple.addRect(dotRect)
                                    } else {
                                        otherSoftStipple.addRect(dotRect)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Batched fills & strokes (zero per-cell / per-dot draw loops)
            if !outMonthCells.isEmpty {
                context.fill(outMonthCells, with: .color(theme.hairline.opacity(0.14)))
                context.stroke(outMonthHatch, with: .color(theme.hairline.opacity(0.30)), lineWidth: 0.5)
                context.stroke(outBorders, with: .color(theme.hairline.opacity(0.28)), lineWidth: 0.55)
            }
            if !inMonthCells.isEmpty {
                context.fill(inMonthCells, with: .color(theme.surface.opacity(theme.isDark ? 0.24 : 0.38)))
            }
            let secondaryWash = theme.isMultiColorSpectrum ? theme.accentQuaternary : theme.accentSecondary
            if !otherSoftStipple.isEmpty {
                context.fill(otherSoftStipple, with: .color(secondaryWash.opacity(theme.isDark ? 0.28 : 0.22)))
            }
            if !otherDenseStipple.isEmpty {
                context.fill(otherDenseStipple, with: .color(secondaryWash.opacity(theme.isDark ? 0.44 : 0.36)))
            }
            if !peakSoftStipple.isEmpty {
                context.fill(peakSoftStipple, with: .color(theme.accent.opacity(theme.isDark ? 0.30 : 0.24)))
            }
            if !peakDenseStipple.isEmpty {
                context.fill(peakDenseStipple, with: .color(theme.accent.opacity(theme.isDark ? 0.48 : 0.40)))
            }
            if !baselines.isEmpty {
                context.stroke(baselines, with: .color(theme.hairlineStrong.opacity(0.55)), lineWidth: 0.55)
            }
            if !avgDashedLine.isEmpty {
                context.stroke(
                    avgDashedLine,
                    with: .color(secondaryWash.opacity(theme.isDark ? 0.62 : 0.54)),
                    style: StrokeStyle(lineWidth: 0.65, dash: [2.0, 2.0])
                )
            }
            if !cellBorders.isEmpty {
                context.stroke(cellBorders, with: .color(theme.hairline.opacity(0.58)), lineWidth: 0.65)
            }

            // Today: clean 1.5px top rule (Color 1 if peak day, Green on Google / Color 2 on duotone otherwise)
            if let ti = todayIdx, ti < count, inMonthFlags[ti] {
                let cellX = dayW * CGFloat(ti) + 1.0
                let cellW = max(0, dayW - 2.0)
                context.fill(
                    Path(CGRect(x: cellX, y: cellY, width: cellW, height: 1.5)),
                    with: .color(ti == peakIdx ? theme.accent : secondaryWash)
                )
            }

            // Peak day: crisp 0.85pt Fred corner brackets ┌ ┐ └ ┘ + 3x3px theme.accent apex square
            if let pi = peakIdx, pi < count, inMonthFlags[pi] {
                let cellX = dayW * CGFloat(pi) + 1.0
                let cellW = max(0, dayW - 2.0)
                let minX = cellX
                let maxX = cellX + cellW
                let minY = cellY
                let maxY = cellY + cellH
                let arm: CGFloat = 4.2

                // Faint interior hairline frame behind brackets
                context.stroke(
                    Path(CGRect(x: minX, y: minY, width: cellW, height: cellH)),
                    with: .color(theme.hairline.opacity(0.45)),
                    lineWidth: 0.55
                )

                var brackets = Path()
                // ┌
                brackets.move(to: CGPoint(x: minX, y: minY + arm))
                brackets.addLine(to: CGPoint(x: minX, y: minY))
                brackets.addLine(to: CGPoint(x: minX + arm, y: minY))
                // ┐
                brackets.move(to: CGPoint(x: maxX - arm, y: minY))
                brackets.addLine(to: CGPoint(x: maxX, y: minY))
                brackets.addLine(to: CGPoint(x: maxX, y: minY + arm))
                // └
                brackets.move(to: CGPoint(x: minX, y: maxY - arm))
                brackets.addLine(to: CGPoint(x: minX, y: maxY))
                brackets.addLine(to: CGPoint(x: minX + arm, y: maxY))
                // ┘
                brackets.move(to: CGPoint(x: maxX - arm, y: maxY))
                brackets.addLine(to: CGPoint(x: maxX, y: maxY))
                brackets.addLine(to: CGPoint(x: maxX, y: maxY - arm))

                context.stroke(brackets, with: .color(theme.accent), lineWidth: 0.85)

                // 3x3px theme.accent apex square in top-right corner
                context.fill(
                    Path(CGRect(x: maxX - 5.5, y: minY + 2.8, width: 3.0, height: 3.0)),
                    with: .color(theme.accent)
                )
            }

            // Crisp day numbers anchored top-left (peak in Color 1, today in Color 2, others muted)
            for i in 0..<count where inMonthFlags[i] {
                let cellX = dayW * CGFloat(i) + 1.0
                let isPeak = (i == peakIdx)
                let isToday = (i == todayIdx)
                let numColor: Color = isPeak ? theme.accent : (isToday ? secondaryWash : theme.inkMuted)
                let label = Text(dayNumbers[i])
                    .font(.system(size: 7, weight: (isPeak || isToday) ? .medium : .regular, design: .monospaced))
                    .foregroundColor(numColor)
                context.draw(label, at: CGPoint(x: cellX + 3.0, y: cellY + 2.2), anchor: .topLeading)
            }
        }
    }

    private static func daySeed(_ key: String) -> Int {
        var h = 5381
        for b in key.utf8 {
            h = ((h << 5) &+ h) &+ Int(b)
        }
        return h
    }

    private static func stippleHash(_ seed: Int, _ x: Int, _ y: Int) -> UInt32 {
        var h = UInt32(truncatingIfNeeded: seed &* 83492791 ^ x &* 374761393 ^ y &* 668265263)
        h = (h ^ (h >> 13)) &* 1274126177
        return h ^ (h >> 16)
    }
}

/// Lightweight dynamic pulse-tick overlay for Month Cadence (Instrument mode).
/// Batches 24h micro-oscilloscope interval traces (peak & hover in Color 1, other active days in Color 2).
private struct MonthRowPulseOverlayCanvas: View {
    let dayKeys: [String]
    let rowIntervals: [[ActiveInterval]]
    let inMonthFlags: [Bool]
    let todayIdx: Int?
    let peakIdx: Int?
    let hoveredDayKey: String?
    let hoveredIntervalDayKey: String?
    let hoveredInterval: ActiveInterval?
    let anyHovered: Bool
    let theme: AGYTheme

    var body: some View {
        Canvas { context, size in
            let count = dayKeys.count
            guard count > 0 else { return }
            let dayW = size.width / CGFloat(count)
            let cellY: CGFloat = 1.0
            let cellH = max(4.0, size.height - 2.0)
            let baseY = cellY + cellH - 5.2

            var secondaryBars = Path()
            var secondaryTicks = Path()
            var peakBars = Path()
            var peakTicks = Path()
            var focusedBars = Path()
            var focusedTicks = Path()

            for i in 0..<count where inMonthFlags[i] {
                let key = dayKeys[i]
                let cellX = dayW * CGFloat(i) + 1.0
                let cellW = max(0, dayW - 2.0)
                let innerX0 = cellX + 2.5
                let innerW = max(1.0, cellW - 5.0)
                let isHoveredDay = (hoveredDayKey == key)
                let isPeakDay = (peakIdx == i)

                if isHoveredDay {
                    context.stroke(
                        Path(CGRect(x: cellX, y: cellY, width: cellW, height: cellH)),
                        with: .color(theme.accent.opacity(0.55)),
                        lineWidth: 0.85
                    )
                }

                for interval in rowIntervals[i] {
                    let iw = max(1.8, innerW * CGFloat(max(interval.durationSeconds, 120)) / 86400.0)
                    let ix = innerX0 + min(
                        max(0, innerW * CGFloat(interval.startSec) / 86400.0),
                        max(0, innerW - iw)
                    )
                    let isHoveredExact = (hoveredIntervalDayKey == key && hoveredInterval == interval)
                    let isDayFocused = (hoveredInterval == nil && isHoveredDay)
                    let isFocused = isHoveredExact || isDayFocused

                    let pulseH: CGFloat = isHoveredExact ? 3.2 : 2.2
                    let tickTop = baseY - (isHoveredExact ? 5.2 : 4.2)
                    let tickBot = baseY + 1.4
                    let barRect = CGRect(x: ix, y: baseY - pulseH, width: iw, height: pulseH)

                    if isFocused {
                        focusedBars.addRect(barRect)
                        focusedTicks.move(to: CGPoint(x: ix + 0.4, y: tickTop))
                        focusedTicks.addLine(to: CGPoint(x: ix + 0.4, y: tickBot))
                        if iw >= 3.2 {
                            focusedTicks.move(to: CGPoint(x: ix + iw - 0.4, y: tickTop))
                            focusedTicks.addLine(to: CGPoint(x: ix + iw - 0.4, y: tickBot))
                        }
                    } else if isPeakDay {
                        peakBars.addRect(barRect)
                        peakTicks.move(to: CGPoint(x: ix + 0.4, y: tickTop))
                        peakTicks.addLine(to: CGPoint(x: ix + 0.4, y: tickBot))
                        if iw >= 3.2 {
                            peakTicks.move(to: CGPoint(x: ix + iw - 0.4, y: tickTop))
                            peakTicks.addLine(to: CGPoint(x: ix + iw - 0.4, y: tickBot))
                        }
                    } else if theme.isMultiColorSpectrum {
                        // On Google theme, color each active interval by its model color (Blue/Green/Yellow/Red)
                        // matching the Week Polar Chronometer instead of flooding the whole month in Red!
                        let mColor = theme.modelColor(interval.model)
                        let alpha: Double = anyHovered ? 0.28 : 0.90
                        context.fill(Path(barRect), with: .color(mColor.opacity(alpha)))
                        var tick = Path()
                        tick.move(to: CGPoint(x: ix + 0.4, y: tickTop))
                        tick.addLine(to: CGPoint(x: ix + 0.4, y: tickBot))
                        if iw >= 3.2 {
                            tick.move(to: CGPoint(x: ix + iw - 0.4, y: tickTop))
                            tick.addLine(to: CGPoint(x: ix + iw - 0.4, y: tickBot))
                        }
                        context.stroke(tick, with: .color(mColor.opacity(min(0.96, alpha + 0.08))), lineWidth: 0.75)
                    } else {
                        secondaryBars.addRect(barRect)
                        secondaryTicks.move(to: CGPoint(x: ix + 0.4, y: tickTop))
                        secondaryTicks.addLine(to: CGPoint(x: ix + 0.4, y: tickBot))
                        if iw >= 3.2 {
                            secondaryTicks.move(to: CGPoint(x: ix + iw - 0.4, y: tickTop))
                            secondaryTicks.addLine(to: CGPoint(x: ix + iw - 0.4, y: tickBot))
                        }
                    }
                }
            }

            if !secondaryBars.isEmpty {
                let alpha: Double = anyHovered ? 0.28 : 0.86
                context.fill(secondaryBars, with: .color(theme.accentSecondary.opacity(alpha)))
                context.stroke(
                    secondaryTicks,
                    with: .color(theme.accentSecondary.opacity(min(0.96, alpha + 0.10))),
                    lineWidth: 0.75
                )
            }
            if !peakBars.isEmpty {
                let alpha: Double = anyHovered ? 0.34 : 0.96
                if theme.isDark && !anyHovered {
                    context.stroke(peakTicks, with: .color(theme.accent.opacity(0.24)), lineWidth: 2.2)
                }
                context.fill(peakBars, with: .color(theme.accent.opacity(alpha)))
                context.stroke(peakTicks, with: .color(theme.accent.opacity(alpha)), lineWidth: 0.85)
            }
            if !focusedBars.isEmpty {
                if theme.isDark {
                    context.stroke(focusedTicks, with: .color(theme.accent.opacity(0.28)), lineWidth: 2.6)
                }
                context.fill(focusedBars, with: .color(theme.accent))
                context.stroke(focusedTicks, with: .color(theme.accent), lineWidth: 0.9)
            }
        }
    }
}

// MARK: - Year View (Precision Matrix Heatmap + Theme Ramp)

struct YearHeatmap: View {
    @ObservedObject var store: UsageStore
    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme

    @State private var hoveredKey: String? = nil

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
            if case .idle = store.effectiveYearPhase {
                store.loadYearTime(store.viewingTimeYear)
            }
        }
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
                        cell(col: col, row: row, startMonday: startMonday,
                             yearPrefix: yearPrefix, days: days)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(col: Int, row: Int, startMonday: Date?, yearPrefix: String,
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
                .onHover { h in hoveredKey = h ? key : (hoveredKey == key ? nil : hoveredKey) }
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
