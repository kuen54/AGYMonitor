import SwiftUI
import AppKit

// Time tab + its Week / Month / Year active-time charts.

// MARK: - Time tab (active usage time)

struct TimeTabView: View {
    @ObservedObject var store: UsageStore
    @Environment(\.localizer) private var loc

    var body: some View {
        VStack(spacing: 8) {
            TabSelector(isNotch: store.displayMode == .notch,
                        items: TimeRange.allCases,
                        selection: $store.timeRange,
                        label: { $0.label(loc) })

            switch store.timeRange {
            case .week:
                if let data = store.viewingTimeData {
                    WeekTimeChart(store: store, timeData: data)
                } else {
                    timeStateView
                }
            case .month:
                if let data = store.viewingTimeData {
                    MonthTimeChart(timeData: data,
                                   year: store.viewingYear, month: store.viewingMonth)
                } else {
                    timeStateView
                }
            case .year:
                YearHeatmap(store: store)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var timeStateView: some View {
        VStack(spacing: 8) {
            if store.isLoading {
                ProgressView().controlSize(.small)
                Text(loc("loading"))
                    .font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                Image(systemName: "tray")
                    .font(.system(size: 20)).foregroundColor(.secondary)
                Text(loc("noData"))
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
    }
}

/// Monday-first localized short weekday symbols.
private func mondayFirstWeekdaySymbols(_ loc: Localizer) -> [String] {
    let df = DateFormatter()
    df.locale = Locale(identifier: loc.language.rawValue)
    let symbols = df.shortWeekdaySymbols ?? []
    guard symbols.count == 7 else { return Array(repeating: "", count: 7) }
    return (0..<7).map { symbols[($0 + 1) % 7] }
}

// ── Week view: 7 rows Mon–Sun × 0–24h timeline ──
struct WeekTimeChart: View {
    @ObservedObject var store: UsageStore
    let timeData: TimeData
    @Environment(\.localizer) private var loc

    private struct HoveredInterval {
        let dayKey: String
        let interval: ActiveInterval
    }
    @State private var hovered: HoveredInterval? = nil

    private let rowHeight: CGFloat = 20
    private let labelWidth: CGFloat = 34
    private let totalWidth: CGFloat = 40
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            weekNav
            summaryHeader
            hoverStrip
            VStack(spacing: 2) {
                ForEach(Array(dayKeys.enumerated()), id: \.element) { index, key in
                    weekRow(index: index, dayKey: key)
                }
            }
            axisLabels
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.03))
        )
    }

    private var weekNav: some View {
        let index = selectedWeekIndex
        let atFirst = (index ?? 0) <= 0
        let atLast = index.map { $0 >= weeks.count - 1 } ?? true
        return HStack {
            Button(action: { store.navigateTimeWeek(offset: -1) }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 20, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(atFirst)
            .opacity(atFirst ? 0.3 : 1)

            Spacer()

            Text("\(shortDate(dayKeys.first ?? "")) – \(shortDate(dayKeys.last ?? ""))")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)

            Spacer()

            Button(action: { store.navigateTimeWeek(offset: 1) }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 20, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(atLast)
            .opacity(atLast ? 0.3 : 1)
        }
    }

    private var summaryHeader: some View {
        HStack(spacing: 18) {
            stat(loc("timeWeekTotal"), TimeLogic.formatDurationShort(weekTotal))
            stat(loc("timeDailyAvg"), TimeLogic.formatDurationShort(weekTotal / avgDivisor))
            stat(loc("timeLongest"), TimeLogic.formatDurationShort(
                TimeLogic.longestIntervalSeconds(in: timeData.days, dayKeys: renderedDayKeys)))
            Spacer()
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
        }
    }

    private var hoverStrip: some View {
        HStack(spacing: 4) {
            if let h = hovered {
                Text(shortDate(h.dayKey))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.primary.opacity(0.8))
                Text("\(TimeLogic.formatClock(h.interval.startSec))–\(TimeLogic.formatClock(h.interval.endSec))")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.primary)
                Text(TimeLogic.formatDurationShort(h.interval.durationSeconds))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .frame(height: 12)
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
            Text(weekdaySymbols.indices.contains(index) ? weekdaySymbols[index] : "")
                .font(.system(size: 9, weight: isToday ? .semibold : .regular))
                .foregroundColor(isToday ? .primary : .secondary)
                .frame(width: labelWidth, alignment: .leading)
            timeline(day: day, dayKey: dayKey, dimmed: !inMonth)
                .frame(height: rowHeight)
            Text(inMonth || day != nil ? TimeLogic.formatDurationShort(total) : "")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(total > 0 ? .primary : .secondary.opacity(0.6))
                .frame(width: totalWidth, alignment: .trailing)
        }
        .padding(.vertical, 1)
        .background(
            isToday
                ? RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.04))
                : nil
        )
    }

    private func timeline(day: DayTimeUsage?, dayKey: String, dimmed: Bool) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                if dimmed {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.025))
                        .frame(width: max(0, w - 2), height: rowHeight - 2)
                        .offset(x: 1)
                }
                ForEach(gridHours, id: \.self) { h in
                    Rectangle()
                        .fill(Color.primary.opacity(0.07))
                        .frame(width: 1)
                        .offset(x: min(w - 1, w * CGFloat(h) / 24.0))
                }
                ForEach(Array((day?.intervals ?? []).enumerated()), id: \.offset) { _, interval in
                    intervalCapsule(interval, dayKey: dayKey, width: w)
                }
            }
        }
    }

    private func intervalCapsule(_ interval: ActiveInterval, dayKey: String,
                                 width w: CGFloat) -> some View {
        let capWidth = max(2, w * CGFloat(max(interval.durationSeconds, 120)) / 86400.0)
        let x = min(max(0, w * CGFloat(interval.startSec) / 86400.0), w - capWidth)
        return Capsule()
            .fill(modelClassColor(interval.model).opacity(0.85))
            .frame(width: capWidth, height: 8)
            .offset(x: x)
            .onHover { h in
                hovered = h ? HoveredInterval(dayKey: dayKey, interval: interval) : nil
            }
    }

    private var axisLabels: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: labelWidth, height: 1)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    ForEach(gridHours, id: \.self) { h in
                        Text("\(h)")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary.opacity(0.7))
                            .position(x: min(max(w * CGFloat(h) / 24.0, 4), w - 7), y: 5)
                    }
                }
            }
            .frame(height: 10)
            Color.clear.frame(width: totalWidth, height: 1)
        }
    }
}

// ── Month view: week-per-row timeline ──
struct MonthTimeChart: View {
    let timeData: TimeData
    let year: Int
    let month: Int
    @Environment(\.localizer) private var loc

    private struct HoveredInterval {
        let dayKey: String
        let interval: ActiveInterval
    }
    @State private var hovered: HoveredInterval? = nil

    private let rowHeight: CGFloat = 20
    private let labelWidth: CGFloat = 34
    private let totalWidth: CGFloat = 40

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
        VStack(alignment: .leading, spacing: 6) {
            summaryHeader
            hoverStrip
            weekdayHeader
            VStack(spacing: 2) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, dayKeys in
                    weekRow(dayKeys: dayKeys)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.03))
        )
    }

    private var summaryHeader: some View {
        HStack(spacing: 18) {
            stat(loc("timeMonthTotal"), TimeLogic.formatDurationShort(monthTotal))
            stat(loc("timeDailyAvg"),
                 TimeLogic.formatDurationShort(activeDays > 0 ? monthTotal / activeDays : 0))
            stat(loc("timeLongest"), TimeLogic.formatDurationShort(
                TimeLogic.longestIntervalSeconds(in: timeData.days, dayKeys: monthDayKeys)))
            Spacer()
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
        }
    }

    private var hoverStrip: some View {
        HStack(spacing: 4) {
            if let h = hovered {
                Text(shortDate(h.dayKey))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.primary.opacity(0.8))
                Text("\(TimeLogic.formatClock(h.interval.startSec))–\(TimeLogic.formatClock(h.interval.endSec))")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.primary)
                Text(TimeLogic.formatDurationShort(h.interval.durationSeconds))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .frame(height: 12)
    }

    private func shortDate(_ dayKey: String) -> String {
        guard let date = TimeLogic.date(fromDayKey: dayKey) else { return dayKey }
        let cal = AppDate.gregorian
        return "\(cal.component(.month, from: date))/\(cal.component(.day, from: date))"
    }

    private var weekdayHeader: some View {
        let symbols = mondayFirstWeekdaySymbols(loc)
        return HStack(spacing: 6) {
            Color.clear.frame(width: labelWidth, height: 1)
            GeometryReader { geo in
                let dayW = geo.size.width / 7
                ZStack(alignment: .leading) {
                    ForEach(0..<7, id: \.self) { i in
                        Text(symbols[i])
                            .font(.system(size: 8))
                            .foregroundColor(.secondary.opacity(0.7))
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
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            timeline(dayKeys: dayKeys)
                .frame(height: rowHeight)
            Text(TimeLogic.formatDurationShort(total))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(total > 0 ? .primary : .secondary.opacity(0.6))
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
                    if !key.hasPrefix(monthPrefix) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.primary.opacity(0.025))
                            .frame(width: max(0, dayW - 2), height: rowHeight - 2)
                            .offset(x: dayW * CGFloat(i) + 1)
                    } else if key == todayKey {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.primary.opacity(0.045))
                            .frame(width: max(0, dayW - 2), height: rowHeight - 2)
                            .offset(x: dayW * CGFloat(i) + 1)
                    }
                }
                ForEach(0...7, id: \.self) { i in
                    Rectangle()
                        .fill(Color.primary.opacity(0.07))
                        .frame(width: 1)
                        .offset(x: min(w - 1, dayW * CGFloat(i)))
                }
                ForEach(Array(dayKeys.enumerated()), id: \.offset) { i, key in
                    if key.hasPrefix(monthPrefix), let day = timeData.days[key] {
                        ForEach(Array(day.intervals.enumerated()), id: \.offset) { _, interval in
                            intervalCapsule(interval, dayKey: key, dayIndex: i, dayWidth: dayW)
                        }
                    }
                }
            }
        }
    }

    private func intervalCapsule(_ interval: ActiveInterval, dayKey: String,
                                 dayIndex: Int, dayWidth: CGFloat) -> some View {
        let capWidth = max(1.5, dayWidth * CGFloat(max(interval.durationSeconds, 120)) / 86400.0)
        let x = dayWidth * CGFloat(dayIndex)
            + min(max(0, dayWidth * CGFloat(interval.startSec) / 86400.0), dayWidth - capWidth)
        return Capsule()
            .fill(modelClassColor(interval.model).opacity(0.85))
            .frame(width: capWidth, height: 8)
            .offset(x: x)
            .onHover { h in
                hovered = h ? HoveredInterval(dayKey: dayKey, interval: interval) : nil
            }
    }
}

// ── Year view: GitHub-style heatmap, 53 cols × 7 rows, Monday-first ──
struct YearHeatmap: View {
    @ObservedObject var store: UsageStore
    @Environment(\.localizer) private var loc
    @Environment(\.colorScheme) private var colorScheme

    @State private var hoveredKey: String? = nil

    private let cellSize: CGFloat = 7
    private let cellSpacing: CGFloat = 1

    private var currentYear: Int { AppDate.gregorian.component(.year, from: Date()) }

    private static let lightRamp: [Color] = [
        Color(red: 0.608, green: 0.914, blue: 0.659), // #9be9a8
        Color(red: 0.251, green: 0.769, blue: 0.388), // #40c463
        Color(red: 0.188, green: 0.631, blue: 0.306), // #30a14e
        Color(red: 0.129, green: 0.431, blue: 0.224), // #216e39
    ]
    private static let darkRamp: [Color] = [
        Color(red: 0.055, green: 0.267, blue: 0.161), // #0e4429
        Color(red: 0.000, green: 0.427, blue: 0.196), // #006d32
        Color(red: 0.149, green: 0.651, blue: 0.255), // #26a641
        Color(red: 0.224, green: 0.827, blue: 0.325), // #39d353
    ]

    static func levelColor(_ level: Int, dark: Bool) -> Color {
        guard (1...4).contains(level) else { return Color.primary.opacity(0.06) }
        return (dark ? darkRamp : lightRamp)[level - 1]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            yearNav
            if let days = store.yearTimeDays {
                hoverStrip(days)
                grid(days)
                legend
            } else {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(loc("timeLoadingYear"))
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 90)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.03))
        )
        .onAppear { store.loadYearTime(store.viewingTimeYear) }
    }

    private var yearNav: some View {
        HStack {
            Button(action: { store.navigateTimeYear(offset: -1) }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 20, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)

            Spacer()

            Text(String(store.viewingTimeYear))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)

            Spacer()

            Button(action: { store.navigateTimeYear(offset: 1) }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 20, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(store.viewingTimeYear >= currentYear)
            .opacity(store.viewingTimeYear >= currentYear ? 0.3 : 1)
        }
    }

    private func hoverStrip(_ days: [String: Int]) -> some View {
        HStack(spacing: 4) {
            if let key = hoveredKey {
                Text(displayDate(key))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.primary.opacity(0.8))
                Text(TimeLogic.formatDurationShort(days[key] ?? 0))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.primary)
            }
            Spacer()
        }
        .frame(height: 12)
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
        let key = startMonday.flatMap {
            TimeLogic.dayKey(col: col, row: row, startMonday: $0)
        }
        if let key = key, key.hasPrefix(yearPrefix) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Self.levelColor(TimeLogic.heatLevel(days[key] ?? 0),
                                      dark: colorScheme == .dark))
                .frame(width: cellSize, height: cellSize)
                .onHover { h in hoveredKey = h ? key : nil }
        } else {
            Color.clear.frame(width: cellSize, height: cellSize)
        }
    }

    private var legend: some View {
        HStack(spacing: 3) {
            Spacer()
            Text(loc("timeLess"))
                .font(.system(size: 8))
                .foregroundColor(.secondary)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Self.levelColor(level, dark: colorScheme == .dark))
                    .frame(width: cellSize, height: cellSize)
            }
            Text(loc("timeMore"))
                .font(.system(size: 8))
                .foregroundColor(.secondary)
        }
    }
}
