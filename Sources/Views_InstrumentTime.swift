import SwiftUI
import AppKit

// Time Tab Instrument Visualizations:
// 1. 24h Polar Chronometer (Week View): 7 concentric Mon-Sun rings around 00h..24h polar clock + NOW ray (Ref 1)
// 2. Year Marching-Squares Topographic Contour Field: smooth isolines + [H] elevation peaks (Ref 2)

// MARK: - 1. 24h Polar Chronometer (Week View)

struct PolarChronometerWeekChart: View {
    @ObservedObject var store: UsageStore
    let timeData: TimeData

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @Environment(\.telemetryStaticRender) private var isStaticRender

    @State private var hoveredArc: PolarArc? = nil
    @State private var hoveredDayKey: String? = nil
    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    private let dialSize: CGFloat = 204
    private let outerRadius: CGFloat = 76
    private let ringStep: CGFloat = 7.6

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
        let index = selectedWeekIndex
        let atFirst = (index ?? 0) <= 0
        let atLast = index.map { $0 >= weeks.count - 1 } ?? true
        let arcs = InstrumentMath.buildPolarWeekArcs(
            dayKeys: dayKeys,
            days: timeData.days,
            monthPrefix: monthPrefix,
            minAngularSeconds: 420
        )

        VStack(alignment: .leading, spacing: 0) {
            TimeKpiStrip(items: [
                (loc("timeWeekTotal"), TimeLogic.formatDurationShort(weekTotal)),
                (loc("timeDailyAvg"), TimeLogic.formatDurationShort(weekTotal / avgDivisor)),
                (loc("timeLongest"), TimeLogic.formatDurationShort(
                    TimeLogic.longestIntervalSeconds(in: timeData.days, dayKeys: renderedDayKeys))),
            ])

            VStack(spacing: 8) {
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

                // Centered 24h Polar Chronometer Dial over subtle graticule
                ZStack {
                    DotGraticuleBackground(spacing: 12)
                    chronometerContainer(arcs: arcs)
                }
                .frame(height: dialSize + 6)

                // Compact 7-column Mon-Sun summary ledger below the dial
                weekdayLedgerStrip
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }

    @ViewBuilder
    private var hoverReadout: some View {
        if let h = hoveredArc {
            HStack(spacing: 5) {
                Rectangle()
                    .fill(theme.modelColor(h.interval.model))
                    .frame(width: 5, height: 5)
                Text(shortDate(h.dayKey))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(theme.inkSecondary)
                Text("\(TimeLogic.formatClock(h.interval.startSec))–\(TimeLogic.formatClock(h.interval.endSec))")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.inkPrimary)
                Text(TimeLogic.formatDurationShort(h.interval.durationSeconds).uppercased())
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(theme.accent)
            }
        } else {
            Text(loc("polarClockTitle"))
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .tracking(0.5)
                .foregroundColor(theme.inkMuted)
        }
    }

    @ViewBuilder
    private func chronometerContainer(arcs: [PolarArc]) -> some View {
        let showsToday = dayKeys.contains(todayKey)
        if showsToday && !reduceMotion && !isStaticRender {
            TimelineView(.periodic(from: Date(), by: 1.0)) { ctx in
                dialCanvas(arcs: arcs, now: ctx.date, showsToday: true)
            }
        } else {
            dialCanvas(arcs: arcs, now: Date(), showsToday: showsToday)
        }
    }

    private func dialCanvas(arcs: [PolarArc], now: Date, showsToday: Bool) -> some View {
        let cal = AppDate.gregorian
        let comps = cal.dateComponents([.hour, .minute, .second], from: now)
        let nowSec = (comps.hour ?? 0) * 3600 + (comps.minute ?? 0) * 60 + (comps.second ?? 0)
        let nowAngle = InstrumentMath.polarAngle(secondsOfDay: nowSec)
        let todayIdx = dayKeys.firstIndex(of: todayKey)
        let innerHubR = outerRadius - 6.0 * ringStep - 5.5

        return Canvas { context, size in
            let cx = size.width * 0.5
            let cy = size.height * 0.5
            let center = CGPoint(x: cx, y: cy)
            let bezelR = outerRadius + 6.5

            // 1. Crosshair cardinal spokes (00/06/12/18)
            var spokes = Path()
            for hour in [0, 6, 12, 18] {
                let ang = InstrumentMath.polarAngle(secondsOfDay: hour * 3600)
                let p0 = CGPoint(x: cx + cos(ang) * innerHubR, y: cy + sin(ang) * innerHubR)
                let p1 = CGPoint(x: cx + cos(ang) * bezelR, y: cy + sin(ang) * bezelR)
                spokes.move(to: p0)
                spokes.addLine(to: p1)
            }
            context.stroke(spokes, with: .color(theme.hairline.opacity(0.65)), lineWidth: 0.75)

            // 2. Outer calibrated 24-hour tick bezel
            let bezelRect = CGRect(x: cx - bezelR, y: cy - bezelR, width: bezelR * 2, height: bezelR * 2)
            context.stroke(Path(ellipseIn: bezelRect), with: .color(theme.hairlineStrong), lineWidth: 0.9)

            for h in 0..<24 {
                let ang = InstrumentMath.polarAngle(secondsOfDay: h * 3600)
                let isCardinal = (h % 6 == 0)
                let isQuarter = (h % 3 == 0)
                let tIn = bezelR - (isCardinal ? 4.5 : (isQuarter ? 3.0 : 1.8))
                let tOut = bezelR + (isCardinal ? 2.0 : 0.8)
                var tick = Path()
                tick.move(to: CGPoint(x: cx + cos(ang) * tIn, y: cy + sin(ang) * tIn))
                tick.addLine(to: CGPoint(x: cx + cos(ang) * tOut, y: cy + sin(ang) * tOut))
                context.stroke(
                    tick,
                    with: .color(isCardinal ? theme.inkSecondary : theme.hairlineStrong),
                    lineWidth: isCardinal ? 1.1 : 0.75
                )
            }

            // Cardinal clock labels ("00", "06", "12", "18") outside bezel
            let cardinalHours: [(Int, String)] = [(0, "00"), (6, "06"), (12, "12"), (18, "18")]
            let labelR = bezelR + 10.5
            for (hr, text) in cardinalHours {
                let ang = InstrumentMath.polarAngle(secondsOfDay: hr * 3600)
                let pos = CGPoint(x: cx + cos(ang) * labelR, y: cy + sin(ang) * labelR)
                let tView = Text(text)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.inkSecondary)
                context.draw(tView, at: pos)
            }

            // 3. Seven concentric Mon..Sun track rings (Mon outermost -> Sun innermost)
            for idx in 0..<7 {
                let r = outerRadius - CGFloat(idx) * ringStep
                let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
                let isTodayRing = (todayIdx == idx)
                let isHoveredDayRing = (dayKeys.indices.contains(idx) && hoveredDayKey == dayKeys[idx])
                let ringColor: Color = {
                    if isHoveredDayRing { return theme.accent.opacity(0.45) }
                    if isTodayRing { return theme.accent.opacity(0.28) }
                    return theme.hairline.opacity(0.65)
                }()
                context.stroke(Path(ellipseIn: rect), with: .color(ringColor), lineWidth: isTodayRing ? 1.1 : 0.7)
            }

            // 4. Activity interval arcs per ring
            for arc in arcs {
                let r = outerRadius - CGFloat(arc.dayIndex) * ringStep
                let isHoveredArc = (hoveredArc == arc)
                let isDayHighlighted = (hoveredDayKey == nil || hoveredDayKey == arc.dayKey)
                let baseColor = theme.modelColor(arc.interval.model)

                var path = Path()
                path.addArc(
                    center: center,
                    radius: r,
                    startAngle: .radians(arc.startAngle),
                    endAngle: .radians(arc.endAngle),
                    clockwise: false
                )

                let alpha: Double = {
                    if !arc.inMonth { return 0.25 }
                    if hoveredArc != nil && !isHoveredArc { return 0.30 }
                    if !isDayHighlighted { return 0.24 }
                    return 0.94
                }()

                if theme.isDark || isHoveredArc {
                    context.stroke(
                        path,
                        with: .color(baseColor.opacity(isHoveredArc ? 0.38 : 0.20)),
                        style: StrokeStyle(lineWidth: isHoveredArc ? 8.5 : 7.0, lineCap: .butt)
                    )
                }

                context.stroke(
                    path,
                    with: .color(baseColor.opacity(alpha)),
                    style: StrokeStyle(lineWidth: isHoveredArc ? 5.2 : 4.0, lineCap: .butt)
                )

                if isHoveredArc {
                    let mid = (arc.startAngle + arc.endAngle) * 0.5
                    let hx = cx + cos(mid) * r
                    let hy = cy + sin(mid) * r
                    context.fill(Path(CGRect(x: hx - 2.5, y: hy - 2.5, width: 5, height: 5)),
                                 with: .color(theme.inkPrimary))
                }
            }

            // 5. Sweeping `NOW` radar scan sector & pointer needle when viewing current week
            if showsToday {
                let trailRad = 0.32
                var sweep = Path()
                sweep.move(to: center)
                sweep.addArc(
                    center: center,
                    radius: bezelR,
                    startAngle: .radians(nowAngle - trailRad),
                    endAngle: .radians(nowAngle),
                    clockwise: false
                )
                sweep.closeSubpath()
                context.fill(sweep, with: .color(theme.accent.opacity(theme.isDark ? 0.14 : 0.09)))

                var ray = Path()
                ray.move(to: CGPoint(x: cx + cos(nowAngle) * innerHubR, y: cy + sin(nowAngle) * innerHubR))
                ray.addLine(to: CGPoint(x: cx + cos(nowAngle) * bezelR, y: cy + sin(nowAngle) * bezelR))
                context.stroke(ray, with: .color(theme.accent), lineWidth: 1.2)

                let tipX = cx + cos(nowAngle) * bezelR
                let tipY = cy + sin(nowAngle) * bezelR
                context.fill(Path(CGRect(x: tipX - 2, y: tipY - 2, width: 4, height: 4)),
                             with: .color(theme.accent))
            }

            // 6. Center core hub ring + live clock / week badge
            let hubRect = CGRect(x: cx - innerHubR, y: cy - innerHubR, width: innerHubR * 2, height: innerHubR * 2)
            context.fill(Path(ellipseIn: hubRect), with: .color(theme.canvas))
            context.stroke(Path(ellipseIn: hubRect), with: .color(theme.hairlineStrong), lineWidth: 0.9)

            let clockLabel = Text(TimeLogic.formatClock(nowSec))
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundColor(showsToday ? theme.accent : theme.inkPrimary)
            let subLabel = Text("24H")
                .font(.system(size: 7, weight: .medium, design: .monospaced))
                .foregroundColor(theme.inkMuted)
            context.draw(clockLabel, at: CGPoint(x: cx, y: cy - 3))
            context.draw(subLabel, at: CGPoint(x: cx, y: cy + 6))
        }
        .frame(width: dialSize, height: dialSize)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let pt):
                let dx = Double(pt.x - dialSize * 0.5)
                let dy = Double(pt.y - dialSize * 0.5)
                hoveredArc = InstrumentMath.hitTestPolarArc(
                    dx: dx,
                    dy: dy,
                    outerRadius: Double(outerRadius),
                    ringStep: Double(ringStep),
                    ringCount: 7,
                    arcs: arcs
                )
            case .ended:
                hoveredArc = nil
            }
        }
    }

    private var weekdayLedgerStrip: some View {
        HStack(spacing: 0) {
            ForEach(Array(dayKeys.enumerated()), id: \.element) { idx, key in
                let day = timeData.days[key]
                let total = day?.totalSeconds ?? 0
                let isToday = (key == todayKey)
                let isHovered = (hoveredDayKey == key)
                let sym = (weekdaySymbols.indices.contains(idx) ? weekdaySymbols[idx] : "").uppercased()

                VStack(spacing: 2) {
                    Text(sym)
                        .font(.system(size: 7.5, weight: isToday ? .bold : .medium, design: .monospaced))
                        .foregroundColor(isToday ? theme.accent : theme.inkMuted)
                    Text(total > 0 ? TimeLogic.formatDurationShort(total).uppercased() : "—")
                        .font(.system(size: 8.5, weight: total > 0 ? .semibold : .regular, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(isHovered || isToday ? theme.accent : (total > 0 ? theme.inkPrimary : theme.inkMuted))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(isHovered ? theme.surfaceRaised.opacity(0.85) : (isToday ? theme.accentSoft : Color.clear))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(isToday || isHovered ? theme.accent : theme.hairline)
                        .frame(height: isToday || isHovered ? 1.5 : 1)
                }
                .contentShape(Rectangle())
                .onHover { inside in
                    hoveredDayKey = inside ? key : (hoveredDayKey == key ? nil : hoveredDayKey)
                }

                if idx < dayKeys.count - 1 {
                    Rectangle().fill(theme.hairline).frame(width: 1)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .overlay(Rectangle().stroke(theme.hairline, lineWidth: 1))
    }

    private func shortDate(_ dayKey: String) -> String {
        guard let date = TimeLogic.date(fromDayKey: dayKey) else { return dayKey }
        let cal = AppDate.gregorian
        return "\(cal.component(.month, from: date))/\(cal.component(.day, from: date))"
    }
}

// MARK: - 2. Year Topographic Contour Field (Marching Squares Isoline Terrain)

struct TopographicYearContourChart: View {
    @ObservedObject var store: UsageStore
    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme

    @State private var hoveredDayKey: String? = nil
    @State private var hoverNormPos: Point2D? = nil

    private let plotHeight: CGFloat = 144

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch store.effectiveYearPhase {
            case .loaded(let days), .loading(cached: .some(let days)), .failed(_, cached: .some(let days)):
                yearContourContent(days)
            case .empty:
                yearContourContent([:])
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
    private func yearContourContent(_ days: [String: Int]) -> some View {
        let year = store.viewingTimeYear
        let summary = TimeLogic.yearSummary(days: days, year: year)
        let field = InstrumentMath.buildYearContourField(days: days, year: year, levelCount: 5)
        let startMonday = TimeLogic.yearGridStartMonday(year: year)
        let monthCols = TimeLogic.monthLabelColumns(year: year)
        let yearPrefix = String(format: "%04d-", year)

        TimeKpiStrip(items: [
            (loc("timeYearTotal"), TimeLogic.formatDurationShort(summary.totalSeconds)),
            (loc("timeActiveDays"), String(format: loc("daysUnitFmt"), summary.activeDays)),
            (loc("timeStreak"), String(format: loc("daysUnitFmt"), summary.longestStreakDays)),
        ])

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(loc("yearContourTitle")) // \(String(year))")
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundColor(theme.inkSecondary)
                Spacer()
                if field.maxHours > 0 {
                    Text(String(format: "%@ %.1fH", loc("peakTag"), field.maxHours))
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.accent)
                }
            }

            monthAxisRow(monthCols: monthCols)

            ZStack {
                DotGraticuleBackground(spacing: 12)
                contourCanvas(field: field, monthCols: monthCols)
            }
            .frame(height: plotHeight)
            .overlay(Rectangle().stroke(theme.hairline, lineWidth: 1).allowsHitTesting(false))
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let pt):
                    // Inside popover width (420 - 24 = 396)
                    let nx = min(0.999, max(0.0, Double(pt.x) / Double(AGYTheme.panelWidth - 24)))
                    let ny = min(0.999, max(0.0, Double(pt.y) / Double(plotHeight)))
                    hoverNormPos = Point2D(x: nx, y: ny)
                    let col = min(52, max(0, Int(nx * 53.0)))
                    let row = min(6, max(0, Int(ny * 7.0)))
                    if let key = startMonday.flatMap({ TimeLogic.dayKey(col: col, row: row, startMonday: $0) }),
                       key.hasPrefix(yearPrefix) {
                        hoveredDayKey = key
                    } else {
                        hoveredDayKey = nil
                    }
                case .ended:
                    hoverNormPos = nil
                    hoveredDayKey = nil
                }
            }

            HStack {
                if let key = hoveredDayKey {
                    Text("+ \(displayDate(key)) · \(TimeLogic.formatDurationShort(days[key] ?? 0).uppercased())")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.inkPrimary)
                } else {
                    Text("ISO // 5-LEVEL FIELD")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(theme.inkMuted)
                }
                Spacer()
                contourLegend
            }
            .frame(height: 12)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func monthAxisRow(monthCols: [(month: Int, col: Int)]) -> some View {
        let names = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                ForEach(monthCols, id: \.month) { entry in
                    Text(names[entry.month - 1])
                        .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.inkMuted)
                        .offset(x: geo.size.width * CGFloat(entry.col) / 53.0)
                }
            }
        }
        .frame(height: 10)
    }

    private func contourCanvas(field: ContourFieldResult, monthCols: [(month: Int, col: Int)]) -> some View {
        Canvas { context, size in
            let padY: CGFloat = 10
            let innerH = max(20, size.height - padY * 2)

            func pt(_ p: Point2D) -> CGPoint {
                CGPoint(x: CGFloat(p.x) * size.width, y: padY + CGFloat(p.y) * innerH)
            }

            // 1. Subtle monthly vertical cartographic meridian lines
            for entry in monthCols where entry.col > 0 {
                let mx = size.width * CGFloat(entry.col) / 53.0
                var v = Path()
                v.move(to: CGPoint(x: mx, y: 0))
                v.addLine(to: CGPoint(x: mx, y: size.height))
                context.stroke(v, with: .color(theme.hairline.opacity(0.65)), lineWidth: 0.75)
            }

            if field.levels.isEmpty {
                let emptyLabel = Text(loc("noData").uppercased())
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(theme.inkMuted)
                context.draw(emptyLabel, at: CGPoint(x: size.width * 0.5, y: size.height * 0.5))
                return
            }

            // 2. Render Marching Squares isoline contour bands (low -> peak elevation)
            for lvl in field.levels {
                var path = Path()
                for seg in lvl.segments {
                    path.move(to: pt(seg.a))
                    path.addLine(to: pt(seg.b))
                }
                let isPeakBand = lvl.level >= field.levels.count - 2
                let color: Color = {
                    switch lvl.level {
                    case 0: return theme.inkSecondary.opacity(0.36)
                    case 1: return theme.inkSecondary.opacity(0.54)
                    case 2: return theme.inkPrimary.opacity(0.72)
                    case 3: return theme.accent.opacity(0.74)
                    default: return theme.accent
                    }
                }()
                let lw: CGFloat = isPeakBand ? (lvl.level == field.levels.count - 1 ? 1.35 : 1.1) : 0.85
                context.stroke(path, with: .color(color), lineWidth: lw)
            }

            // 3. Cartographic `[H]` elevation peaks with angled leader + crisp halo tag
            for peak in field.peaks {
                let p = pt(Point2D(x: peak.x, y: peak.y))
                var cross = Path()
                cross.move(to: CGPoint(x: p.x - 3, y: p.y)); cross.addLine(to: CGPoint(x: p.x + 3, y: p.y))
                cross.move(to: CGPoint(x: p.x, y: p.y - 3)); cross.addLine(to: CGPoint(x: p.x, y: p.y + 3))
                context.stroke(cross, with: .color(theme.accent), lineWidth: 1.0)

                let goRight = p.x < size.width * 0.72
                let goUp = p.y > size.height * 0.36
                let tagW: CGFloat = 46
                let tagH: CGFloat = 13
                let rawCenterX = p.x + (goRight ? 30 : -30)
                let tagX = min(max(rawCenterX, tagW * 0.5 + 4), size.width - tagW * 0.5 - 4)
                let tagY = goUp ? max(tagH * 0.5 + 3, p.y - 12) : min(size.height - tagH * 0.5 - 3, p.y + 12)

                var ldr = Path()
                ldr.move(to: CGPoint(x: p.x + (goRight ? 3 : -3), y: p.y + (goUp ? -2 : 2)))
                ldr.addLine(to: CGPoint(x: tagX + (goRight ? -tagW * 0.5 : tagW * 0.5), y: tagY))
                context.stroke(ldr, with: .color(theme.accent.opacity(0.75)), lineWidth: 0.85)

                let box = CGRect(x: tagX - tagW * 0.5, y: tagY - tagH * 0.5, width: tagW, height: tagH)
                context.fill(Path(box), with: .color(theme.canvas.opacity(0.94)))
                context.stroke(Path(box), with: .color(theme.accent.opacity(0.8)), lineWidth: 0.85)
                let label = Text(String(format: "H %.1fh", peak.hours))
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.accent)
                context.draw(label, at: CGPoint(x: tagX, y: tagY))
            }

            // 4. Interactive hover coordinate crosshair
            if let hp = hoverNormPos {
                let hx = CGFloat(hp.x) * size.width
                let hy = CGFloat(hp.y) * size.height
                var v = Path()
                v.move(to: CGPoint(x: hx, y: 0)); v.addLine(to: CGPoint(x: hx, y: size.height))
                var h = Path()
                h.move(to: CGPoint(x: 0, y: hy)); h.addLine(to: CGPoint(x: size.width, y: hy))
                context.stroke(v, with: .color(theme.reticle), lineWidth: 0.9)
                context.stroke(h, with: .color(theme.reticle), lineWidth: 0.9)
                context.fill(Path(CGRect(x: hx - 2, y: hy - 2, width: 4, height: 4)),
                             with: .color(theme.accent))
            }
        }
        .allowsHitTesting(false)
    }

    private var contourLegend: some View {
        HStack(spacing: 4) {
            Text(loc("timeLess").uppercased())
                .font(.system(size: 7.5, design: .monospaced))
                .foregroundColor(theme.inkMuted)
            HStack(spacing: 2) {
                Rectangle().fill(theme.inkSecondary.opacity(0.38)).frame(width: 8, height: 1.5)
                Rectangle().fill(theme.inkPrimary.opacity(0.72)).frame(width: 8, height: 1.5)
                Rectangle().fill(theme.accent).frame(width: 8, height: 2.0)
            }
            Text(loc("timeMore").uppercased())
                .font(.system(size: 7.5, design: .monospaced))
                .foregroundColor(theme.inkMuted)
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
}
