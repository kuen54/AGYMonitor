import SwiftUI
import AppKit

// Time tab + oscilloscope Week / Month / Year single-plane precision charts.

// MARK: - Time Tab

struct TimeTabView: View {
    @ObservedObject var store: UsageStore
    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            TelemetrySegmentedStrip(
                items: TimeRange.allCases,
                selection: $store.timeRange,
                label: { $0.label(loc) }
            )

            switch store.timeRange {
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
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.invertedInk)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(theme.invertedBg)
                        .contentShape(Rectangle())
                        .onTapGesture { store.refresh(force: true) }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 120)
        }
    }
}

/// Monday-first localized short weekday symbols.
func mondayFirstWeekdaySymbols(_ loc: Localizer) -> [String] {
    let df = DateFormatter()
    df.locale = Locale(identifier: loc.language.rawValue)
    let symbols = df.shortWeekdaySymbols ?? []
    guard symbols.count == 7 else { return ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] }
    return (0..<7).map { symbols[($0 + 1) % 7] }
}

/// Edge-to-edge 3-column hairline KPI strip.
struct TimeKpiStrip: View {
    let items: [(label: String, value: String)]
    @Environment(\.agyTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    VStack(alignment: .leading, spacing: 1.5) {
                        Text(item.label.uppercased())
                            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(theme.inkMuted)
                        Text(item.value.uppercased())
                            .font(.system(size: 13.5, weight: .bold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(theme.inkPrimary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)

                    if idx < items.count - 1 {
                        Rectangle().fill(theme.hairline).frame(width: 1)
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

    private struct HoveredInterval {
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
        GeometryReader { geo in
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
                ForEach(Array((day?.intervals ?? []).enumerated()), id: \.offset) { _, interval in
                    intervalTrace(interval, dayKey: dayKey, width: w)
                }
            }
        }
    }

    private func intervalTrace(_ interval: ActiveInterval, dayKey: String, width w: CGFloat) -> some View {
        let barW = max(3, w * CGFloat(max(interval.durationSeconds, 120)) / 86400.0)
        let x = min(max(0, w * CGFloat(interval.startSec) / 86400.0), w - barW)
        let color = theme.modelColor(interval.model)

        return HStack(spacing: 0) {
            Rectangle().fill(color).frame(width: 1, height: 8)
            Rectangle().fill(color.opacity(0.92)).frame(width: max(1, barW - 2), height: 4)
            Rectangle().fill(color).frame(width: 1, height: 8)
        }
        .frame(width: barW, height: 10)
        .offset(x: x)
        .contentShape(Rectangle())
        .onHover { h in hovered = h ? HoveredInterval(dayKey: dayKey, interval: interval) : nil }
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

    private struct HoveredInterval {
        let dayKey: String
        let interval: ActiveInterval
    }
    @State private var hovered: HoveredInterval? = nil

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
        VStack(alignment: .leading, spacing: 0) {
            TimeKpiStrip(items: [
                (loc("timeMonthTotal"), TimeLogic.formatDurationShort(monthTotal)),
                (loc("timeDailyAvg"), TimeLogic.formatDurationShort(activeDays > 0 ? monthTotal / activeDays : 0)),
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
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(theme.inkPrimary)
                        Text(TimeLogic.formatDurationShort(h.interval.durationSeconds).uppercased())
                            .font(.system(size: 9.5, design: .monospaced))
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
            .padding(.vertical, 8)
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
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
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
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(theme.inkSecondary)
                .frame(width: labelWidth, alignment: .leading)
            timeline(dayKeys: dayKeys)
                .frame(height: rowHeight)
            Text(TimeLogic.formatDurationShort(total).uppercased())
                .font(.system(size: 9, weight: total > 0 ? .semibold : .regular, design: .monospaced))
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

                    Rectangle()
                        .fill(isToday ? theme.accentSoft : (!inMonth ? theme.hairline.opacity(0.4) : theme.surface.opacity(0.75)))
                        .frame(width: cellW, height: rowHeight - 2)
                        .overlay(
                            Rectangle()
                                .strokeBorder(isToday ? theme.accent : theme.hairline.opacity(inMonth ? 0.5 : 0.25), lineWidth: 1)
                        )
                        .offset(x: cellX)

                    if inMonth {
                        Text(dayNumString(key))
                            .font(.system(size: 7.5, weight: isToday ? .bold : .regular, design: .monospaced))
                            .foregroundColor(isToday ? theme.accent : theme.inkMuted)
                            .offset(x: cellX + 3, y: -5.5)
                    }
                }

                ForEach(Array(dayKeys.enumerated()), id: \.offset) { i, key in
                    if key.hasPrefix(monthPrefix), let day = timeData.days[key] {
                        if instrumentElevation && day.totalSeconds > 0 {
                            let hrs = min(1.0, Double(day.totalSeconds) / (8.0 * 3600.0))
                            let elevH = max(2.0, CGFloat(hrs) * (rowHeight - 4))
                            let cellW = max(0, dayW - 2)
                            let cellX = dayW * CGFloat(i) + 1
                            Rectangle()
                                .fill(theme.accent.opacity(theme.isDark ? 0.16 : 0.10))
                                .frame(width: cellW, height: elevH)
                                .offset(x: cellX, y: (rowHeight - 2 - elevH) * 0.5)
                                .allowsHitTesting(false)
                        }
                        ForEach(Array(day.intervals.enumerated()), id: \.offset) { _, interval in
                            intervalBar(interval, dayKey: key, dayIndex: i, dayWidth: dayW)
                        }
                    }
                }
            }
        }
    }

    private func intervalBar(_ interval: ActiveInterval, dayKey: String,
                             dayIndex: Int, dayWidth: CGFloat) -> some View {
        let capWidth = max(2, (dayWidth - 4) * CGFloat(max(interval.durationSeconds, 120)) / 86400.0)
        let x = dayWidth * CGFloat(dayIndex) + 2
            + min(max(0, (dayWidth - 4) * CGFloat(interval.startSec) / 86400.0), max(0, dayWidth - 4 - capWidth))
        return Rectangle()
            .fill(theme.modelColor(interval.model).opacity(0.92))
            .frame(width: capWidth, height: 4)
            .offset(x: x, y: 5)
            .onHover { h in hovered = h ? HoveredInterval(dayKey: dayKey, interval: interval) : nil }
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
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.invertedInk)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(theme.invertedBg)
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
        guard let date = TimeLogic.date(fromDayKey: dayKey) else { return dayKey }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        df.locale = Locale(identifier: loc.language.rawValue)
        return df.string(from: date)
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
