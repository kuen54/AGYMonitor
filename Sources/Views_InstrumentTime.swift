import SwiftUI
import AppKit

// Time Tab Specimen Artifact Visualizations:
// Inspired by Emil Widlund / Polar archival prints & Fred optical HUDs:
// 1. PolarChronometerWeekChart — 24h concentric Mon-Sun polar chronometer (monochrome + 1% accent)
// 2. TopographicYearContourChart — 12-band high-res Marching Squares isobar field + inline peak marks

// MARK: - Memoization Caches (Zero Recompute on 60Hz Hover)

private enum YearContourFieldCache {
    struct Key: Hashable {
        let year: Int
        let dayCount: Int
        let totalSeconds: Int
        let maxSeconds: Int
    }

    private static let lock = NSLock()
    private static var entries: [Key: ContourFieldResult] = [:]
    private static var order: [Key] = []
    private static let maxEntries = 8

    static func field(days: [String: Int], year: Int, totalSeconds: Int) -> ContourFieldResult {
        var maxSec = 0
        for sec in days.values where sec > maxSec { maxSec = sec }
        let key = Key(year: year, dayCount: days.count, totalSeconds: totalSeconds, maxSeconds: maxSec)

        lock.lock()
        if let hit = entries[key] {
            if let idx = order.firstIndex(of: key) {
                order.remove(at: idx)
                order.append(key)
            }
            lock.unlock()
            return hit
        }
        lock.unlock()

        let computed = InstrumentMath.buildYearContourField(days: days, year: year, levelCount: 12)

        lock.lock()
        entries[key] = computed
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > maxEntries {
            let evicted = order.removeFirst()
            entries.removeValue(forKey: evicted)
        }
        lock.unlock()

        return computed
    }
}

private enum PolarWeekArcsCache {
    struct Key: Hashable {
        let monthPrefix: String
        let dayKeys: [String]
        let totalSeconds: Int
        let intervalCount: Int
    }

    private static let lock = NSLock()
    private static var entries: [Key: [PolarArc]] = [:]
    private static var order: [Key] = []
    private static let maxEntries = 8

    static func arcs(
        dayKeys: [String],
        days: [String: DayTimeUsage],
        monthPrefix: String
    ) -> [PolarArc] {
        var totalSec = 0
        var intervalCount = 0
        for key in dayKeys {
            if let d = days[key] {
                totalSec += d.totalSeconds
                intervalCount += d.intervals.count
            }
        }
        let key = Key(
            monthPrefix: monthPrefix,
            dayKeys: dayKeys,
            totalSeconds: totalSec,
            intervalCount: intervalCount
        )

        lock.lock()
        if let hit = entries[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let built = InstrumentMath.buildPolarWeekArcs(
            dayKeys: dayKeys,
            days: days,
            monthPrefix: monthPrefix,
            minAngularSeconds: 420
        )

        lock.lock()
        entries[key] = built
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > maxEntries {
            let evicted = order.removeFirst()
            entries.removeValue(forKey: evicted)
        }
        lock.unlock()

        return built
    }
}

// MARK: - 1. 24h Polar Chronometer (Week View)

struct PolarChronometerWeekChart: View {
    @ObservedObject var store: UsageStore
    let timeData: TimeData

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @Environment(\.telemetryStaticRender) private var isStaticRender
    @Environment(\.telemetryPanelVisible) private var isPanelVisible

    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

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
        let currentDayKeys = dayKeys
        let currentTodayKey = todayKey
        let arcs = PolarWeekArcsCache.arcs(
            dayKeys: currentDayKeys,
            days: timeData.days,
            monthPrefix: monthPrefix
        )

        VStack(alignment: .leading, spacing: 0) {
            TimeKpiStrip(items: [
                (loc("timeWeekTotal"), TimeLogic.formatDurationShort(weekTotal)),
                (loc("timeDailyAvg"), TimeLogic.formatDurationShort(weekTotal / avgDivisor)),
                (loc("timeLongest"), TimeLogic.formatDurationShort(
                    TimeLogic.longestIntervalSeconds(in: timeData.days, dayKeys: renderedDayKeys))),
            ])

            PolarChronometerInteractiveDeck(
                arcs: arcs,
                dayKeys: currentDayKeys,
                days: timeData.days,
                todayKey: currentTodayKey,
                weekdaySymbols: weekdaySymbols,
                title: loc("polarClockTitle"),
                canDecrement: !atFirst,
                canIncrement: !atLast,
                onDecrement: { store.navigateTimeWeek(offset: -1) },
                onIncrement: { store.navigateTimeWeek(offset: 1) },
                reduceMotion: reduceMotion,
                isStaticRender: isStaticRender,
                isPanelVisible: isPanelVisible,
                theme: theme
            )

            HairlineRule(showCrosshairs: false)

            HStack(spacing: 6) {
                Text("* Concentric 24-hour active session chronometer (Mon outer → Sun inner)")
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
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }
}

/// Interactive child view isolating hover state below `TimeKpiStrip` so 120Hz mouse moves
/// never re-evaluate KPIs, week-of-month geometry, or arc cache lookups.
private struct PolarChronometerInteractiveDeck: View {
    let arcs: [PolarArc]
    let dayKeys: [String]
    let days: [String: DayTimeUsage]
    let todayKey: String
    let weekdaySymbols: [String]
    let title: String
    let canDecrement: Bool
    let canIncrement: Bool
    let onDecrement: () -> Void
    let onIncrement: () -> Void
    let reduceMotion: Bool
    let isStaticRender: Bool
    let isPanelVisible: Bool
    let theme: AGYTheme

    @State private var hoveredArc: PolarArc? = nil
    @State private var hoveredDayKey: String? = nil

    private let dialSize: CGFloat = 222
    private let outerRadius: CGFloat = 80
    private let ringStep: CGFloat = 7.8

    private struct BezelArtworkKey: Hashable {
        let outerRadiusTenths: Int
        let innerHubTenths: Int
        let theme: AGYTheme.CacheKey
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 7) {
                HStack(spacing: 5) {
                    Text("03.1")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.accent.opacity(0.9))
                    Text(title)
                        .font(.system(size: 8, weight: .regular, design: .monospaced))
                        .tracking(0.8)
                        .foregroundColor(theme.inkSecondary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    TelemetryStepper(
                        label: "\(shortDate(dayKeys.first ?? "")) – \(shortDate(dayKeys.last ?? ""))",
                        canDecrement: canDecrement,
                        canIncrement: canIncrement,
                        onDecrement: onDecrement,
                        onIncrement: onIncrement
                    )
                }

                // Centered 24h Polar Chronometer Dial (cached bezel + cached NOW sweep + lightweight arcs)
                chronometerContainer
                    .frame(maxWidth: .infinity)
                    .frame(height: dialSize)

                hoverReadoutRow
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)

            HairlineRule(showCrosshairs: false)

            // Airy 7-column Mon-Sun summary ledger below the dial
            weekdayLedgerStrip
        }
    }

    private var hoverReadoutRow: some View {
        HStack(spacing: 5) {
            if let h = hoveredArc {
                Rectangle()
                    .fill(theme.accent)
                    .frame(width: 4, height: 4)
                Text("\(shortDate(h.dayKey)) · \(TimeLogic.formatClock(h.interval.startSec))–\(TimeLogic.formatClock(h.interval.endSec))")
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(theme.inkPrimary)
                Spacer(minLength: 4)
                Text(TimeLogic.formatDurationShort(h.interval.durationSeconds).uppercased())
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(theme.accent)
            } else if let key = hoveredDayKey, let idx = dayKeys.firstIndex(of: key) {
                let sym = (weekdaySymbols.indices.contains(idx) ? weekdaySymbols[idx] : "").uppercased()
                let total = days[key]?.totalSeconds ?? 0
                Rectangle()
                    .fill(theme.accent)
                    .frame(width: 4, height: 4)
                Text("\(sym) · \(shortDate(key))")
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(theme.inkPrimary)
                Spacer(minLength: 4)
                Text(total > 0 ? TimeLogic.formatDurationShort(total).uppercased() : "0M")
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(theme.accent)
            } else {
                Text("MON OUTER → SUN INNER")
                    .font(.system(size: 7.5, weight: .regular, design: .monospaced))
                    .tracking(0.6)
                    .foregroundColor(theme.inkMuted)
                Spacer(minLength: 4)
                Text("7 RINGS // 24H")
                    .font(.system(size: 7.5, weight: .regular, design: .monospaced))
                    .tracking(0.6)
                    .foregroundColor(theme.inkMuted)
            }
        }
        .frame(height: 12)
    }

    @ViewBuilder
    private var chronometerContainer: some View {
        let showsToday = dayKeys.contains(todayKey)
        let todayIdx = dayKeys.firstIndex(of: todayKey)
        let innerHubR = outerRadius - 6.0 * ringStep - 5.5

        ZStack {
            // Layer 1: Pre-rendered 2x Retina cached horological bezel
            CachedTelemetryArtwork(
                key: BezelArtworkKey(
                    outerRadiusTenths: Int((outerRadius * 10).rounded()),
                    innerHubTenths: Int((innerHubR * 10).rounded()),
                    theme: theme.cacheKey
                ),
                width: dialSize,
                height: dialSize
            ) {
                PolarDialBezelLayer(
                    outerRadius: outerRadius,
                    innerHubR: innerHubR,
                    theme: theme
                )
            }
            .allowsHitTesting(false)

            // Layer 2: Lightweight activity rings & hover focus (zero stipple loops!)
            PolarDialActivityLayer(
                arcs: arcs,
                dayKeys: dayKeys,
                todayKey: todayKey,
                todayIdx: todayIdx,
                hoveredArc: hoveredArc,
                hoveredDayKey: hoveredDayKey,
                outerRadius: outerRadius,
                ringStep: ringStep,
                theme: theme
            )

            // Layer 3: Isolated NOW stippled radar sweep + center hub (cached per minute, 0Hz when closed)
            if isPanelVisible && showsToday && !reduceMotion && !isStaticRender {
                TimelineView(.periodic(from: Date(), by: 30.0)) { ctx in
                    PolarNowSweepAndHubLayer(
                        now: ctx.date,
                        showsToday: true,
                        dialSize: dialSize,
                        outerRadius: outerRadius,
                        innerHubR: innerHubR,
                        theme: theme
                    )
                }
            } else {
                PolarNowSweepAndHubLayer(
                    now: Date(),
                    showsToday: showsToday,
                    dialSize: dialSize,
                    outerRadius: outerRadius,
                    innerHubR: innerHubR,
                    theme: theme
                )
            }
        }
        .frame(width: dialSize, height: dialSize)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let pt):
                let dx = Double(pt.x - dialSize * 0.5)
                let dy = Double(pt.y - dialSize * 0.5)
                let hit = InstrumentMath.hitTestPolarArc(
                    dx: dx,
                    dy: dy,
                    outerRadius: Double(outerRadius),
                    ringStep: Double(ringStep),
                    ringCount: 7,
                    arcs: arcs
                )
                if hoveredArc != hit {
                    hoveredArc = hit
                }
            case .ended:
                if hoveredArc != nil {
                    hoveredArc = nil
                }
            }
        }
    }

    private var weekdayLedgerStrip: some View {
        HStack(spacing: 0) {
            ForEach(Array(dayKeys.enumerated()), id: \.element) { idx, key in
                let day = days[key]
                let total = day?.totalSeconds ?? 0
                let isToday = (key == todayKey)
                let isHovered = (hoveredDayKey == key || hoveredArc?.dayKey == key)
                let isActive = isToday || isHovered
                let sym = (weekdaySymbols.indices.contains(idx) ? weekdaySymbols[idx] : "").uppercased()

                VStack(spacing: 2.5) {
                    HStack(spacing: 3) {
                        if isToday {
                            Rectangle()
                                .fill(theme.accent)
                                .frame(width: 3.5, height: 3.5)
                        }
                        Text(sym)
                            .font(.system(size: 7.5, weight: isActive ? .medium : .regular, design: .monospaced))
                            .tracking(0.5)
                            .foregroundColor(isActive ? theme.inkPrimary : theme.inkMuted)
                    }
                    Text(total > 0 ? TimeLogic.formatDurationShort(total).uppercased() : "—")
                        .font(.system(size: 8.5, weight: isActive ? .medium : .regular, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(isActive ? theme.accent : (total > 0 ? theme.inkSecondary : theme.inkMuted.opacity(0.75)))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    ZStack(alignment: .top) {
                        if isActive {
                            Rectangle()
                                .fill(theme.surfaceRaised.opacity(theme.isDark ? 0.35 : 0.55))
                            Rectangle()
                                .fill(theme.accent)
                                .frame(height: 1.5)
                        }
                    }
                )
                .contentShape(Rectangle())
                .onHover { inside in
                    let next = inside ? key : (hoveredDayKey == key ? nil : hoveredDayKey)
                    if hoveredDayKey != next {
                        hoveredDayKey = next
                    }
                }

                if idx < dayKeys.count - 1 {
                    Rectangle().fill(theme.hairline.opacity(0.8)).frame(width: 1)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func shortDate(_ dayKey: String) -> String {
        guard let date = TimeLogic.date(fromDayKey: dayKey) else { return dayKey }
        let cal = AppDate.gregorian
        return "\(cal.component(.month, from: date))/\(cal.component(.day, from: date))"
    }
}

/// Static Polar Chronometer Bezel — Swiss horological 24h ticks, 8 degree/hour markings,
/// subtle outer stippled compass dots, and cardinal/octant astrolabe spokes (Equatable).
private struct PolarDialBezelLayer: View, Equatable {
    let outerRadius: CGFloat
    let innerHubR: CGFloat
    let theme: AGYTheme

    var body: some View {
        Canvas { context, size in
            let cx = size.width * 0.5
            let cy = size.height * 0.5
            let bezelR = outerRadius + 7.5
            let compassR = bezelR + 4.8

            // 1. Crosshair cardinal spokes (00/06/12/18) + whisper-light dashed octant spokes (03/09/15/21)
            var cardinalSpokes = Path()
            var octantSpokes = Path()
            for hour in [0, 6, 12, 18] {
                let ang = InstrumentMath.polarAngle(secondsOfDay: hour * 3600)
                cardinalSpokes.move(to: CGPoint(x: cx + cos(ang) * innerHubR, y: cy + sin(ang) * innerHubR))
                cardinalSpokes.addLine(to: CGPoint(x: cx + cos(ang) * bezelR, y: cy + sin(ang) * bezelR))
            }
            for hour in [3, 9, 15, 21] {
                let ang = InstrumentMath.polarAngle(secondsOfDay: hour * 3600)
                octantSpokes.move(to: CGPoint(x: cx + cos(ang) * innerHubR, y: cy + sin(ang) * innerHubR))
                octantSpokes.addLine(to: CGPoint(x: cx + cos(ang) * bezelR, y: cy + sin(ang) * bezelR))
            }
            context.stroke(
                octantSpokes,
                with: .color(theme.hairline.opacity(0.32)),
                style: StrokeStyle(lineWidth: 0.5, dash: [1.5, 3.0])
            )
            context.stroke(cardinalSpokes, with: .color(theme.hairline.opacity(0.65)), lineWidth: 0.65)

            // 2. Outer calibrated 24-hour bezel ring + delicate chapter ring
            let bezelRect = CGRect(x: cx - bezelR, y: cy - bezelR, width: bezelR * 2, height: bezelR * 2)
            let chapterRect = CGRect(x: cx - compassR, y: cy - compassR, width: compassR * 2, height: compassR * 2)
            context.stroke(Path(ellipseIn: chapterRect), with: .color(theme.hairline.opacity(0.40)), lineWidth: 0.45)
            context.stroke(Path(ellipseIn: bezelRect), with: .color(theme.hairlineStrong.opacity(0.85)), lineWidth: 0.75)

            // 3. 24-hour calibrated bezel ticks batched into 3 weight paths
            var cardinalTicks = Path()
            var octantTicks = Path()
            var minorTicks = Path()
            for h in 0..<24 {
                let ang = InstrumentMath.polarAngle(secondsOfDay: h * 3600)
                let isCardinal = (h % 6 == 0)
                let isOctant = (h % 3 == 0) && !isCardinal
                let tIn = bezelR - (isCardinal ? 4.8 : (isOctant ? 3.2 : 1.8))
                let tOut = bezelR + (isCardinal ? 3.0 : (isOctant ? 2.0 : 0.9))
                let p0 = CGPoint(x: cx + cos(ang) * tIn, y: cy + sin(ang) * tIn)
                let p1 = CGPoint(x: cx + cos(ang) * tOut, y: cy + sin(ang) * tOut)
                if isCardinal {
                    cardinalTicks.move(to: p0)
                    cardinalTicks.addLine(to: p1)
                } else if isOctant {
                    octantTicks.move(to: p0)
                    octantTicks.addLine(to: p1)
                } else {
                    minorTicks.move(to: p0)
                    minorTicks.addLine(to: p1)
                }
            }
            context.stroke(minorTicks, with: .color(theme.hairlineStrong.opacity(0.82)), lineWidth: 0.6)
            context.stroke(octantTicks, with: .color(theme.inkSecondary.opacity(0.76)), lineWidth: 0.75)
            context.stroke(cardinalTicks, with: .color(theme.inkSecondary), lineWidth: 0.95)

            // 4. Subtle outer stippled compass dots (72 steps = every 5 deg, batched into 1 Path)
            var compassDots = Path()
            let dotSize: CGFloat = 0.95
            for step in 0..<72 {
                // Keep major 8 hour tick bearings uncluttered
                if step % 9 == 0 { continue }
                let ang = -Double.pi * 0.5 + (Double(step) / 72.0) * 2.0 * Double.pi
                let dx = cx + CGFloat(cos(ang)) * compassR - dotSize * 0.5
                let dy = cy + CGFloat(sin(ang)) * compassR - dotSize * 0.5
                compassDots.addRect(CGRect(x: dx, y: dy, width: dotSize, height: dotSize))
            }
            context.fill(compassDots, with: .color(theme.inkMuted.opacity(0.48)))

            // 5. Coordinate-anchored 8 degree/hour markings (00/06/12/18 primary, 03/09/15/21 subtle)
            let labelR = bezelR + 12.2
            let hourMarkings: [(hour: Int, text: String, primary: Bool)] = [
                (0,  "00", true),  (3,  "03", false),
                (6,  "06", true),  (9,  "09", false),
                (12, "12", true),  (15, "15", false),
                (18, "18", true),  (21, "21", false),
            ]
            for mark in hourMarkings {
                let ang = InstrumentMath.polarAngle(secondsOfDay: mark.hour * 3600)
                let pos = CGPoint(x: cx + cos(ang) * labelR, y: cy + sin(ang) * labelR)
                let tView = Text(mark.text)
                    .font(.system(
                        size: mark.primary ? 7.5 : 6.5,
                        weight: mark.primary ? .medium : .regular,
                        design: .monospaced
                    ))
                    .foregroundColor(mark.primary ? theme.inkSecondary : theme.inkMuted.opacity(0.80))
                context.draw(tView, at: pos)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Dynamic Polar Chronometer Activity Layer — 7 batched rings, precision dual-rail engraved arcs
/// + fine radial hatch ticks, idle peak indicator pip, and hover midpoint lock.
/// Decoupled from the stippled NOW radar sweep so 120Hz arc hovering stays ultra-light.
private struct PolarDialActivityLayer: View {
    let arcs: [PolarArc]
    let dayKeys: [String]
    let todayKey: String
    let todayIdx: Int?
    let hoveredArc: PolarArc?
    let hoveredDayKey: String?
    let outerRadius: CGFloat
    let ringStep: CGFloat
    let theme: AGYTheme

    var body: some View {
        Canvas { context, size in
            let cx = size.width * 0.5
            let cy = size.height * 0.5
            let center = CGPoint(x: cx, y: cy)
            let bezelR = outerRadius + 7.5
            let activeHoverDay = hoveredArc?.dayKey ?? hoveredDayKey
            let anyFocus = (hoveredArc != nil || hoveredDayKey != nil)

            // 1. Seven concentric Mon..Sun track rings (batched into normal + accent)
            var normalRings = Path()
            var accentRings = Path()
            for idx in 0..<7 {
                let r = outerRadius - CGFloat(idx) * ringStep
                let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
                let isTodayRing = (todayIdx == idx)
                let isHoveredDayRing = (dayKeys.indices.contains(idx) && activeHoverDay == dayKeys[idx])
                if isTodayRing || isHoveredDayRing {
                    accentRings.addEllipse(in: rect)
                } else {
                    normalRings.addEllipse(in: rect)
                }
            }
            context.stroke(normalRings, with: .color(theme.hairline.opacity(0.60)), lineWidth: 0.6)
            if !accentRings.isEmpty {
                context.stroke(
                    accentRings,
                    with: .color(theme.accent.opacity(activeHoverDay != nil ? 0.42 : 0.28)),
                    lineWidth: 0.85
                )
            }

            // 2. Precision dual-rail engraved activity arcs + fine radial hatch ticks (batched)
            var outMonthMain = Path()
            var inMonthMain = Path()
            var inMonthRail = Path()
            var inMonthTicks = Path()
            var todayMain = Path()
            var todayRail = Path()
            var todayTicks = Path()
            var focusedMain = Path()
            var focusedRail = Path()
            var focusedTicks = Path()

            let railOffset: CGFloat = 2.15

            func appendArc(to path: inout Path, radius r: CGFloat, start: Double, end: Double) {
                let startPt = CGPoint(x: cx + CGFloat(cos(start)) * r, y: cy + CGFloat(sin(start)) * r)
                path.move(to: startPt)
                path.addArc(
                    center: center,
                    radius: r,
                    startAngle: .radians(start),
                    endAngle: .radians(end),
                    clockwise: false
                )
            }

            func appendEngravedTicks(to ticksPath: inout Path, radius r: CGFloat, start: Double, end: Double) {
                let capIn = r - 1.5
                let capOut = r + railOffset + 0.35
                // Start & end mechanical drafting serifs
                for a in [start, end] {
                    let ca = CGFloat(cos(a)), sa = CGFloat(sin(a))
                    ticksPath.move(to: CGPoint(x: cx + ca * capIn, y: cy + sa * capIn))
                    ticksPath.addLine(to: CGPoint(x: cx + ca * capOut, y: cy + sa * capOut))
                }
                // Interior fine radial hatch engravings (~every 15 min)
                let span = end - start
                let hatchStep = 0.068
                if span > hatchStep * 1.4 {
                    let tickIn = r - 0.9
                    let tickOut = r + railOffset
                    var a = start + hatchStep
                    while a < end - hatchStep * 0.55 {
                        let ca = CGFloat(cos(a)), sa = CGFloat(sin(a))
                        ticksPath.move(to: CGPoint(x: cx + ca * tickIn, y: cy + sa * tickIn))
                        ticksPath.addLine(to: CGPoint(x: cx + ca * tickOut, y: cy + sa * tickOut))
                        a += hatchStep
                    }
                }
            }

            var longestArc: PolarArc? = nil
            for arc in arcs {
                if arc.inMonth {
                    if let cur = longestArc {
                        if arc.interval.durationSeconds > cur.interval.durationSeconds { longestArc = arc }
                    } else if arc.interval.durationSeconds > 0 {
                        longestArc = arc
                    }
                }

                let r = outerRadius - CGFloat(arc.dayIndex) * ringStep
                let isHoveredArc = (hoveredArc == arc)
                let isHoveredDayArc = (hoveredArc == nil && hoveredDayKey != nil && hoveredDayKey == arc.dayKey)
                let isTodayArc = (arc.dayKey == todayKey)

                if isHoveredArc || isHoveredDayArc {
                    appendArc(to: &focusedMain, radius: r, start: arc.startAngle, end: arc.endAngle)
                    appendArc(to: &focusedRail, radius: r + railOffset, start: arc.startAngle, end: arc.endAngle)
                    appendEngravedTicks(to: &focusedTicks, radius: r, start: arc.startAngle, end: arc.endAngle)
                } else if isTodayArc && arc.inMonth {
                    appendArc(to: &todayMain, radius: r, start: arc.startAngle, end: arc.endAngle)
                    appendArc(to: &todayRail, radius: r + railOffset, start: arc.startAngle, end: arc.endAngle)
                    appendEngravedTicks(to: &todayTicks, radius: r, start: arc.startAngle, end: arc.endAngle)
                } else if arc.inMonth {
                    appendArc(to: &inMonthMain, radius: r, start: arc.startAngle, end: arc.endAngle)
                    appendArc(to: &inMonthRail, radius: r + railOffset, start: arc.startAngle, end: arc.endAngle)
                    appendEngravedTicks(to: &inMonthTicks, radius: r, start: arc.startAngle, end: arc.endAngle)
                } else {
                    appendArc(to: &outMonthMain, radius: r, start: arc.startAngle, end: arc.endAngle)
                }
            }

            if !outMonthMain.isEmpty {
                context.stroke(
                    outMonthMain,
                    with: .color(theme.inkMuted.opacity(anyFocus ? 0.14 : 0.28)),
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .butt)
                )
            }
            if !inMonthMain.isEmpty {
                context.stroke(
                    inMonthMain,
                    with: .color(theme.inkPrimary.opacity(anyFocus ? 0.20 : 0.78)),
                    style: StrokeStyle(lineWidth: 2.4, lineCap: .butt)
                )
                context.stroke(
                    inMonthRail,
                    with: .color(theme.inkPrimary.opacity(anyFocus ? 0.10 : 0.36)),
                    style: StrokeStyle(lineWidth: 0.5, lineCap: .butt)
                )
                context.stroke(
                    inMonthTicks,
                    with: .color(theme.inkPrimary.opacity(anyFocus ? 0.10 : 0.42)),
                    lineWidth: 0.5
                )
            }
            if !todayMain.isEmpty {
                if theme.isDark && !anyFocus {
                    context.stroke(
                        todayMain,
                        with: .color(theme.accent.opacity(0.20)),
                        style: StrokeStyle(lineWidth: 5.8, lineCap: .butt)
                    )
                }
                context.stroke(
                    todayMain,
                    with: .color(theme.accent.opacity(anyFocus ? 0.34 : 0.94)),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .butt)
                )
                context.stroke(
                    todayRail,
                    with: .color(theme.accent.opacity(anyFocus ? 0.20 : 0.56)),
                    style: StrokeStyle(lineWidth: 0.55, lineCap: .butt)
                )
                context.stroke(
                    todayTicks,
                    with: .color(theme.accent.opacity(anyFocus ? 0.20 : 0.62)),
                    lineWidth: 0.55
                )
            }
            if !focusedMain.isEmpty {
                context.stroke(
                    focusedMain,
                    with: .color(theme.accent.opacity(theme.isDark ? 0.30 : 0.16)),
                    style: StrokeStyle(lineWidth: 6.8, lineCap: .butt)
                )
                context.stroke(
                    focusedMain,
                    with: .color(theme.accent),
                    style: StrokeStyle(lineWidth: 2.9, lineCap: .butt)
                )
                context.stroke(
                    focusedRail,
                    with: .color(theme.accent.opacity(0.75)),
                    style: StrokeStyle(lineWidth: 0.6, lineCap: .butt)
                )
                context.stroke(
                    focusedTicks,
                    with: .color(theme.accent.opacity(0.75)),
                    lineWidth: 0.6
                )
            }

            // 2b. Idle Fred-style outer peak indicator pip on the longest interval of the week
            if !anyFocus, let peak = longestArc {
                let peakR = outerRadius - CGFloat(peak.dayIndex) * ringStep
                let mid = (peak.startAngle + peak.endAngle) * 0.5
                let cm = CGFloat(cos(mid))
                let sm = CGFloat(sin(mid))

                // Delicate dashed radial sightline from peak arc to bezel
                var sightline = Path()
                sightline.move(to: CGPoint(x: cx + cm * (peakR + railOffset + 1.0), y: cy + sm * (peakR + railOffset + 1.0)))
                sightline.addLine(to: CGPoint(x: cx + cm * (bezelR + 1.0), y: cy + sm * (bezelR + 1.0)))
                context.stroke(
                    sightline,
                    with: .color(theme.accent.opacity(0.42)),
                    style: StrokeStyle(lineWidth: 0.65, dash: [1.5, 2.0])
                )

                // Inward-pointing Fred bezel chevron pip outside the bezel ring
                let tipR = bezelR + 1.6
                let baseR = bezelR + 5.6
                let halfW: CGFloat = 2.1
                let perpX = -sm
                let perpY = cm
                let tipPt = CGPoint(x: cx + cm * tipR, y: cy + sm * tipR)
                let leftBase = CGPoint(x: cx + cm * baseR + perpX * halfW, y: cy + sm * baseR + perpY * halfW)
                let rightBase = CGPoint(x: cx + cm * baseR - perpX * halfW, y: cy + sm * baseR - perpY * halfW)
                var pip = Path()
                pip.move(to: tipPt)
                pip.addLine(to: leftBase)
                pip.addLine(to: rightBase)
                pip.closeSubpath()
                context.fill(pip, with: .color(theme.accent.opacity(0.92)))

                // Tiny square apex anchor on the peak arc midpoint
                let ax = cx + cm * peakR
                let ay = cy + sm * peakR
                context.fill(
                    Path(CGRect(x: ax - 1.4, y: ay - 1.4, width: 2.8, height: 2.8)),
                    with: .color(theme.accent)
                )
            }

            // 2c. Hovered arc optical midpoint lock + bezel bearing tick
            if let h = hoveredArc {
                let r = outerRadius - CGFloat(h.dayIndex) * ringStep
                let mid = (h.startAngle + h.endAngle) * 0.5
                let cm = CGFloat(cos(mid))
                let sm = CGFloat(sin(mid))
                let hx = cx + cm * r
                let hy = cy + sm * r
                context.fill(
                    Path(CGRect(x: hx - 1.8, y: hy - 1.8, width: 3.6, height: 3.6)),
                    with: .color(theme.inkPrimary)
                )
                var bearingTick = Path()
                bearingTick.move(to: CGPoint(x: cx + cm * (bezelR - 2.0), y: cy + sm * (bezelR - 2.0)))
                bearingTick.addLine(to: CGPoint(x: cx + cm * (bezelR + 3.6), y: cy + sm * (bezelR + 3.6)))
                context.stroke(bearingTick, with: .color(theme.accent), lineWidth: 1.1)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Isolated NOW radar stippled sweep + live HH:MM center hub cached per minute in TelemetryArtworkCache
/// so 120Hz hover across chronometer arcs NEVER re-runs the radial stipple loop.
private struct PolarNowSweepAndHubLayer: View {
    let now: Date
    let showsToday: Bool
    let dialSize: CGFloat
    let outerRadius: CGFloat
    let innerHubR: CGFloat
    let theme: AGYTheme

    private struct SweepArtworkKey: Hashable {
        let nowMinute: Int
        let showsToday: Bool
        let theme: AGYTheme.CacheKey
    }

    var body: some View {
        let cal = AppDate.gregorian
        let comps = cal.dateComponents([.hour, .minute], from: now)
        let nowMinute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let nowSec = nowMinute * 60
        let nowAngle = InstrumentMath.polarAngle(secondsOfDay: nowSec)

        CachedTelemetryArtwork(
            key: SweepArtworkKey(nowMinute: nowMinute, showsToday: showsToday, theme: theme.cacheKey),
            width: dialSize,
            height: dialSize
        ) {
            Canvas { context, size in
                let cx = size.width * 0.5
                let cy = size.height * 0.5
                let center = CGPoint(x: cx, y: cy)
                let bezelR = outerRadius + 7.5

                if showsToday {
                    let trailRad = 0.30
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
                    context.fill(sweep, with: .color(theme.accent.opacity(theme.isDark ? 0.075 : 0.045)))

                    var sweepDenseDots = Path()
                    var sweepSoftDots = Path()
                    let radialStep: CGFloat = 3.2
                    let angStep: Double = 0.028
                    let rSteps = Int((bezelR - innerHubR - 5.0) / radialStep)
                    let aSteps = Int(trailRad / angStep)
                    for ir in 0...max(0, rSteps) {
                        let baseR = innerHubR + 3.5 + CGFloat(ir) * radialStep
                        guard baseR < bezelR - 1.5 else { break }
                        for ia in 1...max(1, aSteps) {
                            let lag = Double(ia) * angStep
                            guard lag <= trailRad else { break }
                            let h = Self.sweepHash(ir, ia)
                            let jR = (Double(h & 0xFF) / 255.0 - 0.5) * Double(radialStep) * 0.72
                            let jA = (Double((h >> 8) & 0xFF) / 255.0 - 0.5) * angStep * 0.72
                            let dr = baseR + CGFloat(jR)
                            let effLag = lag + jA
                            guard dr > innerHubR + 2.0, dr < bezelR - 1.2,
                                  effLag > 0.008, effLag < trailRad else { continue }

                            let prob = exp(-effLag / 0.13) * 0.72
                            let roll = Double((h >> 16) & 0x3FF) / 1023.0
                            if roll < prob {
                                let ang = nowAngle - effLag
                                let sz: CGFloat = ((h >> 26) & 1 == 0) ? 0.9 : 1.15
                                let px = cx + CGFloat(cos(ang)) * dr - sz * 0.5
                                let py = cy + CGFloat(sin(ang)) * dr - sz * 0.5
                                let dotRect = CGRect(x: px, y: py, width: sz, height: sz)
                                if effLag < 0.10 {
                                    sweepDenseDots.addRect(dotRect)
                                } else {
                                    sweepSoftDots.addRect(dotRect)
                                }
                            }
                        }
                    }
                    if !sweepSoftDots.isEmpty {
                        context.fill(sweepSoftDots, with: .color(theme.accent.opacity(theme.isDark ? 0.28 : 0.22)))
                    }
                    if !sweepDenseDots.isEmpty {
                        context.fill(sweepDenseDots, with: .color(theme.accent.opacity(theme.isDark ? 0.58 : 0.46)))
                    }

                    var ray = Path()
                    ray.move(to: CGPoint(x: cx + cos(nowAngle) * innerHubR, y: cy + sin(nowAngle) * innerHubR))
                    ray.addLine(to: CGPoint(x: cx + cos(nowAngle) * bezelR, y: cy + sin(nowAngle) * bezelR))
                    if theme.isDark {
                        context.stroke(ray, with: .color(theme.accent.opacity(0.24)), lineWidth: 3.0)
                    }
                    context.stroke(ray, with: .color(theme.accent), lineWidth: 1.05)

                    let tipX = cx + cos(nowAngle) * bezelR
                    let tipY = cy + sin(nowAngle) * bezelR
                    context.fill(
                        Path(CGRect(x: tipX - 1.75, y: tipY - 1.75, width: 3.5, height: 3.5)),
                        with: .color(theme.accent)
                    )
                }

                // Center core hub ring + live HH:MM readout
                let hubRect = CGRect(x: cx - innerHubR, y: cy - innerHubR, width: innerHubR * 2, height: innerHubR * 2)
                context.fill(Path(ellipseIn: hubRect), with: .color(theme.canvas))
                context.stroke(Path(ellipseIn: hubRect), with: .color(theme.hairlineStrong.opacity(0.85)), lineWidth: 0.75)

                let clockLabel = Text(TimeLogic.formatClock(nowSec))
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundColor(showsToday ? theme.accent : theme.inkPrimary)
                let subLabel = Text("24H")
                    .font(.system(size: 6.5, weight: .regular, design: .monospaced))
                    .foregroundColor(theme.inkMuted)
                context.draw(clockLabel, at: CGPoint(x: cx, y: cy - 3.2))
                context.draw(subLabel, at: CGPoint(x: cx, y: cy + 5.8))
            }
        }
        .allowsHitTesting(false)
    }

    private static func sweepHash(_ r: Int, _ a: Int) -> UInt32 {
        var h = UInt32(truncatingIfNeeded: r &* 374761393 &+ a &* 668265263)
        h = (h ^ (h >> 13)) &* 1274126177
        return h ^ (h >> 16)
    }
}

// MARK: - 2. Year Topographic Contour Field (12-Band Marching Squares Isobar Terrain)

struct TopographicYearContourChart: View {
    @ObservedObject var store: UsageStore
    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme

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
    private func yearContourContent(_ days: [String: Int]) -> some View {
        let year = store.viewingTimeYear
        let summary = TimeLogic.yearSummary(days: days, year: year)
        let field = YearContourFieldCache.field(days: days, year: year, totalSeconds: summary.totalSeconds)
        let startMonday = TimeLogic.yearGridStartMonday(year: year)
        let monthCols = TimeLogic.monthLabelColumns(year: year)

        TimeKpiStrip(items: [
            (loc("timeYearTotal"), TimeLogic.formatDurationShort(summary.totalSeconds)),
            (loc("timeActiveDays"), String(format: loc("daysUnitFmt"), summary.activeDays)),
            (loc("timeStreak"), String(format: loc("daysUnitFmt"), summary.longestStreakDays)),
        ])

        YearContourInteractiveStage(
            year: year,
            days: days,
            totalSeconds: summary.totalSeconds,
            activeDays: summary.activeDays,
            field: field,
            startMonday: startMonday,
            monthCols: monthCols,
            loc: loc,
            theme: theme
        )

        HairlineRule(showCrosshairs: false)

        HStack(spacing: 6) {
            Text("* Contours of daily active session density")
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

/// Interactive child view isolating hover state below `TimeKpiStrip` so 120Hz cursor sweeps
/// NEVER re-run `TimeLogic.yearSummary`, `monthLabelColumns`, or `TimeKpiStrip`.
private struct YearContourInteractiveStage: View {
    let year: Int
    let days: [String: Int]
    let totalSeconds: Int
    let activeDays: Int
    let field: ContourFieldResult
    let startMonday: Date?
    let monthCols: [(month: Int, col: Int)]
    let loc: Localizer
    let theme: AGYTheme

    @State private var hoveredDayKey: String? = nil
    @State private var hoverNormPos: Point2D? = nil

    private let plotHeight: CGFloat = 184
    private static let contourPadY: CGFloat = 16

    private struct YearArtworkKey: Hashable {
        let year: Int
        let totalSeconds: Int
        let activeDays: Int
        let maxHoursCenti: Int
        let noDataLabel: String
        let theme: AGYTheme.CacheKey
    }

    var body: some View {
        let yearPrefix = String(format: "%04d-", year)
        let artworkKey = YearArtworkKey(
            year: year,
            totalSeconds: totalSeconds,
            activeDays: activeDays,
            maxHoursCenti: Int((field.maxHours * 100.0).rounded()),
            noDataLabel: loc("noData").uppercased(),
            theme: theme.cacheKey
        )

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text("03.3")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.accent.opacity(0.9))
                Text("\(loc("yearContourTitle")) // \(String(year))")
                    .font(.system(size: 8, weight: .regular, design: .monospaced))
                    .tracking(0.8)
                    .foregroundColor(theme.inkSecondary)

                Spacer(minLength: 4)

                if let key = hoveredDayKey {
                    Text("\(displayDate(key)) · \(TimeLogic.formatDurationShort(days[key] ?? 0).uppercased())")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(theme.accent)
                } else if field.maxHours > 0 {
                    Text(String(format: "%@ %.1fH", loc("peakTag"), field.maxHours))
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(theme.inkSecondary)
                }
            }

            monthAxisRow

            GeometryReader { geo in
                ZStack {
                    // Pre-rendered 2x Retina cached 12-band contour artwork + interior basin stippling
                    CachedTelemetryArtwork(
                        key: artworkKey,
                        width: geo.size.width,
                        height: geo.size.height
                    ) {
                        StaticYearContourCanvas(
                            field: field,
                            monthColumns: monthCols.map(\.col),
                            noDataLabel: loc("noData").uppercased(),
                            padY: Self.contourPadY,
                            theme: theme
                        )
                    }
                    .allowsHitTesting(false)

                    // Lightweight 2-line hover reticle overlay aligned 100% with padded contour geometry
                    ContourHoverReticleCanvas(
                        hoverNormPos: hoverNormPos,
                        padY: Self.contourPadY,
                        theme: theme
                    )
                }
                .overlay(Rectangle().stroke(theme.hairline.opacity(0.85), lineWidth: 0.75).allowsHitTesting(false))
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let pt):
                        let w = Double(geo.size.width)
                        let h = Double(geo.size.height)
                        if let cell = InstrumentMath.yearContourCell(
                            x: Double(pt.x),
                            y: Double(pt.y),
                            width: w,
                            height: h,
                            padY: Double(Self.contourPadY)
                        ) {
                            let nextPos = Point2D(x: cell.normX, y: cell.normY)
                            if hoverNormPos != nextPos {
                                hoverNormPos = nextPos
                            }
                            let nextKey: String?
                            if let key = startMonday.flatMap({ TimeLogic.dayKey(col: cell.col, row: cell.row, startMonday: $0) }),
                               key.hasPrefix(yearPrefix) {
                                nextKey = key
                            } else {
                                nextKey = nil
                            }
                            if hoveredDayKey != nextKey {
                                hoveredDayKey = nextKey
                            }
                        } else {
                            if hoverNormPos != nil { hoverNormPos = nil }
                            if hoveredDayKey != nil { hoveredDayKey = nil }
                        }
                    case .ended:
                        if hoverNormPos != nil { hoverNormPos = nil }
                        if hoveredDayKey != nil { hoveredDayKey = nil }
                    }
                }
            }
            .frame(height: plotHeight)

            HStack {
                Text("ISO // 12-BAND FIELD")
                    .font(.system(size: 7.5, weight: .regular, design: .monospaced))
                    .tracking(0.6)
                    .foregroundColor(theme.inkMuted)
                Spacer()
                contourLegend
            }
            .frame(height: 11)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var monthAxisRow: some View {
        let names = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                ForEach(monthCols, id: \.month) { entry in
                    Text(names[entry.month - 1])
                        .font(.system(size: 7, weight: .regular, design: .monospaced))
                        .tracking(0.4)
                        .foregroundColor(theme.inkMuted)
                        .offset(x: geo.size.width * CGFloat(entry.col) / 53.0)
                }
            }
        }
        .frame(height: 10)
    }

    private var contourLegend: some View {
        HStack(spacing: 4) {
            Text(loc("timeLess").uppercased())
                .font(.system(size: 7, weight: .regular, design: .monospaced))
                .foregroundColor(theme.inkMuted)
            HStack(spacing: 2.5) {
                Rectangle().fill(theme.inkSecondary.opacity(0.32)).frame(width: 8, height: 0.75)
                Rectangle().fill(theme.inkPrimary.opacity(0.68)).frame(width: 8, height: 1.0)
                Rectangle().fill(theme.accent).frame(width: 8, height: 1.5)
            }
            Text(loc("timeMore").uppercased())
                .font(.system(size: 7, weight: .regular, design: .monospaced))
                .foregroundColor(theme.inkMuted)
        }
    }

    private func displayDate(_ dayKey: String) -> String {
        TimeDateFormatters.displayDate(dayKey, languageCode: loc.language.rawValue)
    }
}

/// Static 12-band Marching Squares contour artwork + organic interior basin stippling
/// + Emil Widlund meteorological circular `(H)` peak marks (Equatable, 0ms hover cost).
private struct StaticYearContourCanvas: View, Equatable {
    let field: ContourFieldResult
    let monthColumns: [Int]
    let noDataLabel: String
    let padY: CGFloat
    let theme: AGYTheme

    var body: some View {
        Canvas { context, size in
            let innerH = max(20, size.height - padY * 2)

            func pt(_ p: Point2D) -> CGPoint {
                CGPoint(x: CGFloat(p.x) * size.width, y: padY + CGFloat(p.y) * innerH)
            }

            // 1. Subtle monthly vertical cartographic meridian lines — single batched Path
            var meridians = Path()
            for col in monthColumns where col > 0 {
                let mx = size.width * CGFloat(col) / 53.0
                meridians.move(to: CGPoint(x: mx, y: 0))
                meridians.addLine(to: CGPoint(x: mx, y: size.height))
            }
            context.stroke(meridians, with: .color(theme.hairline.opacity(0.55)), lineWidth: 0.65)

            if field.levels.isEmpty {
                let emptyLabel = Text(noDataLabel)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundColor(theme.inkMuted)
                context.draw(emptyLabel, at: CGPoint(x: size.width * 0.5, y: size.height * 0.5))
                return
            }

            // 2. Organic interior basin stippling inside high-elevation contour zones (level >= 7),
            //    with denser printmaker grain in summit cores (level >= 9) — batched into 1 Path.
            let totalLevels = field.levels.count
            let basinIdx = min(totalLevels - 1, max(0, (totalLevels * 7) / 12))
            let coreIdx = min(totalLevels - 1, max(basinIdx, (totalLevels * 9) / 12))
            let basinSegments = field.levels[basinIdx].segments
            let coreSegments = (coreIdx > basinIdx) ? field.levels[coreIdx].segments : []

            if !basinSegments.isEmpty {
                var basinStipple = Path()
                let stepX: CGFloat = 2.45
                let stepY: CGFloat = 2.45
                let rowCount = Int(innerH / stepY)

                var basinXs: [CGFloat] = []
                var coreXs: [CGFloat] = []
                basinXs.reserveCapacity(16)
                coreXs.reserveCapacity(12)

                for iy in 0...max(0, rowCount) {
                    let py = padY + CGFloat(iy) * stepY
                    let ny = Double((py - padY) / innerH)
                    guard ny > 0.0, ny < 1.0 else { continue }

                    Self.scanlineIntersections(
                        segments: basinSegments,
                        ny: ny,
                        width: size.width,
                        out: &basinXs
                    )
                    guard basinXs.count >= 2 else { continue }

                    if !coreSegments.isEmpty {
                        Self.scanlineIntersections(
                            segments: coreSegments,
                            ny: ny,
                            width: size.width,
                            out: &coreXs
                        )
                    } else {
                        coreXs.removeAll(keepingCapacity: true)
                    }

                    var spanIdx = 0
                    while spanIdx + 1 < basinXs.count {
                        let x0 = basinXs[spanIdx]
                        let x1 = basinXs[spanIdx + 1]
                        spanIdx += 2
                        guard x1 - x0 > 1.2 else { continue }

                        let minIx = max(0, Int(ceil(x0 / stepX)))
                        let maxIx = Int(floor(x1 / stepX))
                        guard minIx <= maxIx else { continue }

                        for ix in minIx...maxIx {
                            let h = Self.deterministicHash(ix, iy)
                            let jx = (Double(h & 0xFF) / 255.0 - 0.5) * Double(stepX) * 0.86
                            let jy = (Double((h >> 8) & 0xFF) / 255.0 - 0.5) * Double(stepY) * 0.86
                            let gx = CGFloat(ix) * stepX + CGFloat(jx)
                            let gy = py + CGFloat(jy)
                            guard gx >= x0 + 0.4, gx <= x1 - 0.4,
                                  gy >= padY, gy <= size.height - padY else { continue }

                            let inCore = Self.containsX(gx, inSortedSpans: coreXs)
                            let prob = inCore ? 0.72 : 0.40
                            let roll = Double((h >> 16) & 0x3FF) / 1023.0
                            if roll < prob {
                                let sz: CGFloat = ((h >> 26) & 1 == 0) ? 0.95 : 1.25
                                basinStipple.addRect(CGRect(x: gx, y: gy, width: sz, height: sz))
                            }
                        }
                    }
                }

                if !basinStipple.isEmpty {
                    context.fill(
                        basinStipple,
                        with: .color(theme.inkPrimary.opacity(theme.isDark ? 0.36 : 0.30))
                    )
                }
            }

            // 3. Render 12 silky Marching Squares isobar contours (levels 0..9 monochrome, top 2 accent)
            let monochromeCount = max(1, totalLevels - 2)

            for lvl in field.levels {
                guard !lvl.segments.isEmpty else { continue }
                var path = Path()
                for seg in lvl.segments {
                    path.move(to: pt(seg.a))
                    path.addLine(to: pt(seg.b))
                }

                let isTopPeak = (lvl.level == totalLevels - 1)
                let isSecondPeak = (lvl.level == totalLevels - 2) && totalLevels >= 2

                if isTopPeak {
                    if theme.isDark {
                        context.stroke(path, with: .color(theme.accent.opacity(0.18)), lineWidth: 3.2)
                    }
                    context.stroke(path, with: .color(theme.accent), lineWidth: 1.15)
                } else if isSecondPeak {
                    if theme.isDark {
                        context.stroke(path, with: .color(theme.accent.opacity(0.11)), lineWidth: 2.3)
                    }
                    context.stroke(path, with: .color(theme.accent.opacity(0.78)), lineWidth: 0.95)
                } else {
                    let t = Double(lvl.level) / Double(max(1, monochromeCount - 1))
                    let color: Color
                    if t < 0.45 {
                        let localT = t / 0.45
                        color = theme.inkSecondary.opacity(0.22 + localT * 0.24)
                    } else {
                        let localT = (t - 0.45) / 0.55
                        color = theme.inkPrimary.opacity(0.30 + localT * 0.42)
                    }
                    let lw: CGFloat = 0.55 + CGFloat(t) * 0.30
                    context.stroke(path, with: .color(color), lineWidth: lw)
                }
            }

            // 4. Emil Widlund meteorological circular `(H)` marks + clean borderless value readouts
            let circleD: CGFloat = 9.0
            let circleR: CGFloat = circleD * 0.5
            let valW: CGFloat = 24.0
            let valH: CGFloat = 9.5

            // Pre-reserve all circular `(H)` footprints so adjacent text labels never overlap a badge
            var peakCenters: [CGPoint] = []
            var placedRects: [CGRect] = []
            for peak in field.peaks {
                let rawP = pt(Point2D(x: peak.x, y: peak.y))
                let clampedP = CGPoint(
                    x: min(max(rawP.x, circleR + 2.5), max(circleR + 2.5, size.width - circleR - 2.5)),
                    y: min(max(rawP.y, circleR + 2.5), max(circleR + 2.5, size.height - circleR - 2.5))
                )
                peakCenters.append(clampedP)
                placedRects.append(CGRect(
                    x: clampedP.x - circleR - 1.5,
                    y: clampedP.y - circleR - 1.5,
                    width: circleD + 3.0,
                    height: circleD + 3.0
                ))
            }

            for (idx, peak) in field.peaks.enumerated() {
                let p = peakCenters[idx]
                let isPrimary = (idx == 0)

                // Crisp 9pt meteorological circular `(H)` badge
                let circleRect = CGRect(x: p.x - circleR, y: p.y - circleR, width: circleD, height: circleD)
                let circlePath = Path(ellipseIn: circleRect)
                context.fill(circlePath, with: .color(theme.canvas.opacity(0.92)))
                context.stroke(
                    circlePath,
                    with: .color(isPrimary ? theme.accent : theme.accent.opacity(0.78)),
                    lineWidth: 0.75
                )

                let hGlyph = Text("H")
                    .font(.system(size: 6, weight: .semibold, design: .monospaced))
                    .foregroundColor(isPrimary ? theme.accent : theme.inkPrimary)
                context.draw(hGlyph, at: p)

                // Clean borderless `6.7h` value beside the circular mark (collision-avoided)
                let dxSide: CGFloat = circleR + valW * 0.5 + 3.5
                let candidates: [CGPoint] = [
                    CGPoint(x: p.x + dxSide, y: p.y),
                    CGPoint(x: p.x - dxSide, y: p.y),
                    CGPoint(x: p.x + dxSide * 0.85, y: p.y - 8.5),
                    CGPoint(x: p.x - dxSide * 0.85, y: p.y - 8.5),
                    CGPoint(x: p.x + dxSide * 0.85, y: p.y + 8.5),
                    CGPoint(x: p.x - dxSide * 0.85, y: p.y + 8.5),
                    CGPoint(x: p.x, y: p.y - 10.5),
                    CGPoint(x: p.x, y: p.y + 10.5),
                ]

                let minCX = valW * 0.5 + 2.5
                let maxCX = max(minCX, size.width - valW * 0.5 - 2.5)
                let minCY = valH * 0.5 + 2.0
                let maxCY = max(minCY, size.height - valH * 0.5 - 2.0)

                var chosenCenter = CGPoint(
                    x: min(max(candidates[0].x, minCX), maxCX),
                    y: min(max(candidates[0].y, minCY), maxCY)
                )
                for cand in candidates {
                    let clamped = CGPoint(
                        x: min(max(cand.x, minCX), maxCX),
                        y: min(max(cand.y, minCY), maxCY)
                    )
                    let rect = CGRect(
                        x: clamped.x - valW * 0.5 - 1.5,
                        y: clamped.y - valH * 0.5 - 1.0,
                        width: valW + 3.0,
                        height: valH + 2.0
                    )
                    if placedRects.allSatisfy({ !$0.intersects(rect) }) {
                        chosenCenter = clamped
                        placedRects.append(rect)
                        break
                    }
                }

                // Tiny soft legibility halo (borderless capsule, never a sticky-note box)
                let haloRect = CGRect(
                    x: chosenCenter.x - valW * 0.5,
                    y: chosenCenter.y - valH * 0.5,
                    width: valW,
                    height: valH
                )
                context.fill(
                    Path(roundedRect: haloRect, cornerRadius: valH * 0.5),
                    with: .color(theme.canvas.opacity(0.76))
                )

                let labelColor = isPrimary ? theme.accent : theme.inkPrimary.opacity(0.88)
                let valLabel = Text(String(format: "%.1fh", peak.hours))
                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                    .foregroundColor(labelColor)
                context.draw(valLabel, at: chosenCenter)
            }
        }
        .allowsHitTesting(false)
    }

    private static func scanlineIntersections(
        segments: [Segment2D],
        ny: Double,
        width: CGFloat,
        out: inout [CGFloat]
    ) {
        out.removeAll(keepingCapacity: true)
        for seg in segments {
            let ay = seg.a.y
            let by = seg.b.y
            if (ay <= ny && by > ny) || (by <= ny && ay > ny) {
                let t = (ny - ay) / (by - ay)
                let ix = seg.a.x + t * (seg.b.x - seg.a.x)
                out.append(CGFloat(ix) * width)
            }
        }
        if out.count > 1 {
            out.sort()
        }
    }

    private static func containsX(_ x: CGFloat, inSortedSpans spans: [CGFloat]) -> Bool {
        var i = 0
        while i + 1 < spans.count {
            if x >= spans[i] && x <= spans[i + 1] { return true }
            i += 2
        }
        return false
    }

    private static func deterministicHash(_ x: Int, _ y: Int) -> UInt32 {
        var h = UInt32(truncatingIfNeeded: x &* 374761393 &+ y &* 668265263)
        h = (h ^ (h >> 13)) &* 1274126177
        return h ^ (h >> 16)
    }
}

/// Lightweight top hover-reticle overlay — aligned 100% with padded contour geometry.
private struct ContourHoverReticleCanvas: View {
    let hoverNormPos: Point2D?
    let padY: CGFloat
    let theme: AGYTheme

    var body: some View {
        Canvas { context, size in
            guard let hp = hoverNormPos else { return }
            let innerH = max(1, size.height - padY * 2)
            let hx = CGFloat(hp.x) * size.width
            let hy = padY + CGFloat(hp.y) * innerH

            var lines = Path()
            lines.move(to: CGPoint(x: hx, y: 0))
            lines.addLine(to: CGPoint(x: hx, y: size.height))
            lines.move(to: CGPoint(x: 0, y: hy))
            lines.addLine(to: CGPoint(x: size.width, y: hy))

            context.stroke(lines, with: .color(theme.reticle.opacity(0.72)), lineWidth: 0.75)
            context.fill(
                Path(CGRect(x: hx - 1.75, y: hy - 1.75, width: 3.5, height: 3.5)),
                with: .color(theme.accent)
            )
        }
        .allowsHitTesting(false)
    }
}
