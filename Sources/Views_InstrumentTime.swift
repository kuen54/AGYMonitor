import SwiftUI
import AppKit

// Time Tab Specimen Artifact Visualizations:
// Inspired by Emil Widlund / Polar archival prints & Fred optical HUDs:
// 1. PolarChronometerWeekChart (1A) — 24h concentric Mon-Sun polar chronometer with
//    00:00 Meridian Index Gate, 5+2 weekday/weekend grouping, strict accent semantics,
//    smart Peak callout, click-to-pin ledger, and dynamic center hub.
// 2. TopographicYearContourChart (3A) — 12-band high-res Marching Squares isobar field with
//    left weekday Y-axis, honest NOW cutoff (Neumann boundary + archival future hatch),
//    and integrated 12-month micro-elevation strip.
// 3. MonthElevationInstrumentChart (M3) — 30-day stratified elevation sequence paired with
//    an aggregated 48-bin 24h diurnal rhythm profile & cross-deck hover inspection.

// MARK: - Memoization Caches (Zero Recompute on 120Hz Hover)

private enum YearContourFieldCache {
    struct Key: Hashable {
        let year: Int
        let cutoffDayKey: String?
        let dayCount: Int
        let totalSeconds: Int
        let maxSeconds: Int
        let digest: Int
    }

    private static let lock = NSLock()
    private static var lru = BoundedLRUState<Key, ContourFieldResult>(maxEntries: 8)

    static func dataDigest(days: [String: Int]) -> Int {
        var acc: UInt64 = 14695981039346656037
        for k in days.keys.sorted() {
            let v = days[k] ?? 0
            for b in k.utf8 {
                acc = (acc ^ UInt64(b)) &* 1099511628211
            }
            acc = (acc ^ UInt64(bitPattern: Int64(v))) &* 1099511628211
        }
        return Int(truncatingIfNeeded: acc)
    }

    static func field(
        days: [String: Int],
        year: Int,
        totalSeconds: Int,
        cutoffDayKey: String?
    ) -> ContourFieldResult {
        var maxSec = 0
        for sec in days.values where sec > maxSec { maxSec = sec }
        let key = Key(
            year: year,
            cutoffDayKey: cutoffDayKey,
            dayCount: days.count,
            totalSeconds: totalSeconds,
            maxSeconds: maxSec,
            digest: dataDigest(days: days)
        )

        lock.lock()
        if let hit = lru.get(key) {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let computed = InstrumentMath.buildYearContourField(
            days: days,
            year: year,
            levelCount: 12,
            cutoffDayKey: cutoffDayKey
        )

        lock.lock()
        lru.set(computed, for: key)
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
        let digest: Int
    }

    private static let lock = NSLock()
    private static var lru = BoundedLRUState<Key, [PolarArc]>(maxEntries: 8)

    static func arcs(
        dayKeys: [String],
        days: [String: DayTimeUsage],
        monthPrefix: String
    ) -> [PolarArc] {
        var totalSec = 0
        var intervalCount = 0
        var acc: UInt64 = 14695981039346656037
        for key in dayKeys {
            if let d = days[key] {
                totalSec += d.totalSeconds
                intervalCount += d.intervals.count
                for iv in d.intervals {
                    acc = (acc ^ UInt64(bitPattern: Int64(iv.startSec))) &* 1099511628211
                    acc = (acc ^ UInt64(bitPattern: Int64(iv.endSec))) &* 1099511628211
                    if let m = iv.model {
                        for b in m.utf8 { acc = (acc ^ UInt64(b)) &* 1099511628211 }
                    }
                }
            }
        }
        let key = Key(
            monthPrefix: monthPrefix,
            dayKeys: dayKeys,
            totalSeconds: totalSec,
            intervalCount: intervalCount,
            digest: Int(truncatingIfNeeded: acc)
        )

        lock.lock()
        if let hit = lru.get(key) {
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
        lru.set(built, for: key)
        lock.unlock()

        return built
    }
}

private enum MonthDiurnalProfileCache {
    struct Key: Hashable {
        let year: Int
        let month: Int
        let dayCount: Int
        let totalSeconds: Int
        let intervalCount: Int
        let digest: Int
    }

    private static let lock = NSLock()
    private static var lru = BoundedLRUState<Key, MonthDiurnalProfile>(maxEntries: 8)

    static func profile(
        days: [String: DayTimeUsage],
        year: Int,
        month: Int
    ) -> (profile: MonthDiurnalProfile, digest: Int) {
        let prefix = String(format: "%04d-%02d-", year, month)
        let matchingKeys = days.keys.filter { $0.hasPrefix(prefix) }.sorted()

        var totalSec = 0
        var intervalCount = 0
        var acc: UInt64 = 14695981039346656037
        for k in matchingKeys {
            for b in k.utf8 {
                acc = (acc ^ UInt64(b)) &* 1099511628211
            }
            if let d = days[k] {
                totalSec += d.totalSeconds
                intervalCount += d.intervals.count
                acc = (acc ^ UInt64(bitPattern: Int64(d.totalSeconds))) &* 1099511628211
                for iv in d.intervals {
                    acc = (acc ^ UInt64(bitPattern: Int64(iv.startSec))) &* 1099511628211
                    acc = (acc ^ UInt64(bitPattern: Int64(iv.endSec))) &* 1099511628211
                }
            }
        }
        let digest = Int(truncatingIfNeeded: acc)
        let key = Key(
            year: year,
            month: month,
            dayCount: matchingKeys.count,
            totalSeconds: totalSec,
            intervalCount: intervalCount,
            digest: digest
        )

        lock.lock()
        if let hit = lru.get(key) {
            lock.unlock()
            return (hit, digest)
        }
        lock.unlock()

        let built = InstrumentMath.buildMonthDiurnalProfile(
            days: days,
            year: year,
            month: month,
            binCount: 48,
            peakWindowBins: 4
        )

        lock.lock()
        lru.set(built, for: key)
        lock.unlock()

        return (built, digest)
    }
}

// MARK: - Shared Localization & Archival Geometry Helpers

private func polarGateWeekdayLetters(for language: AppLanguage) -> [String] {
    switch language {
    case .en:
        return ["M", "T", "W", "T", "F", "S", "S"]
    case .zhHans, .zhHant:
        return ["一", "二", "三", "四", "五", "六", "日"]
    case .ja:
        return ["月", "火", "水", "木", "金", "土", "日"]
    }
}

private func yearYAxisWeekdayTicks(for language: AppLanguage) -> [(row: Int, label: String, isWeekend: Bool)] {
    switch language {
    case .en:
        return [(0, "M", false), (2, "W", false), (4, "F", false), (6, "S", true)]
    case .zhHans, .zhHant:
        return [(0, "一", false), (2, "三", false), (4, "五", false), (6, "日", true)]
    case .ja:
        return [(0, "月", false), (2, "水", false), (4, "金", false), (6, "日", true)]
    }
}

private func formatPolarPeakTag(_ seconds: Int) -> String {
    let hrs = Double(seconds) / 3600.0
    if hrs >= 1.0 {
        return String(format: "PK %.1fH", hrs)
    }
    return String(format: "PK %dM", max(1, seconds / 60))
}

private func addArchivalDiagonalHatch(to path: inout Path, in rect: CGRect, step: CGFloat = 5.2) {
    guard rect.width > 0.5, rect.height > 0.5 else { return }
    var hx = rect.minX - rect.height
    while hx < rect.maxX {
        let x0 = max(rect.minX, hx)
        let y0 = rect.maxY - max(0, rect.minX - hx)
        let x1 = min(rect.maxX, hx + rect.height)
        let y1 = rect.minY + max(0, (hx + rect.height) - rect.maxX)
        if x1 > x0 {
            path.move(to: CGPoint(x: x0, y: y0))
            path.addLine(to: CGPoint(x: x1, y: y1))
        }
        hx += step
    }
}

private func addFredCornerBrackets(to path: inout Path, rect: CGRect, arm: CGFloat) {
    let minX = rect.minX
    let maxX = rect.maxX
    let minY = rect.minY
    let maxY = rect.maxY
    let a = min(arm, min(rect.width * 0.45, rect.height * 0.45))
    guard a > 0.5 else { return }
    // ┌
    path.move(to: CGPoint(x: minX, y: minY + a))
    path.addLine(to: CGPoint(x: minX, y: minY))
    path.addLine(to: CGPoint(x: minX + a, y: minY))
    // ┐
    path.move(to: CGPoint(x: maxX - a, y: minY))
    path.addLine(to: CGPoint(x: maxX, y: minY))
    path.addLine(to: CGPoint(x: maxX, y: minY + a))
    // └
    path.move(to: CGPoint(x: minX, y: maxY - a))
    path.addLine(to: CGPoint(x: minX, y: maxY))
    path.addLine(to: CGPoint(x: minX + a, y: maxY))
    // ┘
    path.move(to: CGPoint(x: maxX - a, y: maxY))
    path.addLine(to: CGPoint(x: maxX, y: maxY))
    path.addLine(to: CGPoint(x: maxX, y: maxY - a))
}

private func drawYearNowDatum(
    in context: inout GraphicsContext,
    cutoffX: CGFloat,
    canvasWidth: CGFloat,
    height: CGFloat,
    showTag: Bool,
    drawTopTick: Bool,
    drawBottomTick: Bool,
    theme: AGYTheme
) -> CGRect? {
    let datumColor = theme.isMultiColorSpectrum ? theme.accentQuaternary : theme.accentSecondary
    var dashLine = Path()
    dashLine.move(to: CGPoint(x: cutoffX, y: 0))
    dashLine.addLine(to: CGPoint(x: cutoffX, y: height))
    context.stroke(
        dashLine,
        with: .color(datumColor.opacity(theme.isDark ? 0.90 : 0.84)),
        style: StrokeStyle(lineWidth: 0.9, dash: [2.5, 2.0])
    )

    if drawTopTick {
        context.fill(Path(CGRect(x: cutoffX - 1.25, y: 0, width: 2.5, height: 2.0)), with: .color(datumColor))
    }
    if drawBottomTick {
        context.fill(Path(CGRect(x: cutoffX - 1.25, y: height - 2.0, width: 2.5, height: 2.0)), with: .color(datumColor))
    }

    guard showTag else { return nil }
    let tagW: CGFloat = 21.0
    let tagH: CGFloat = 9.5
    let flipLeft = (cutoffX > canvasWidth - 36.0)
    let tagX: CGFloat = flipLeft
        ? max(2.0, cutoffX - tagW - 3.0)
        : min(max(2.0, canvasWidth - tagW - 2.0), cutoffX + 3.0)
    let tagY: CGFloat = 3.5
    let tagRect = CGRect(x: tagX, y: tagY, width: tagW, height: tagH)
    context.fill(Path(tagRect), with: .color(theme.canvas.opacity(0.95)))
    context.stroke(Path(tagRect), with: .color(datumColor.opacity(0.78)), lineWidth: 0.65)
    let label = Text("NOW")
        .font(.system(size: 6, weight: .bold, design: .monospaced))
        .tracking(0.3)
        .foregroundColor(datumColor)
    context.draw(label, at: CGPoint(x: tagRect.midX, y: tagRect.midY))
    return tagRect
}

// MARK: - 1. 24h Polar Chronometer (Week 1A)

struct PolarChronometerWeekChart: View {
    @ObservedObject var store: UsageStore
    let timeData: TimeData

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @Environment(\.telemetryStaticRender) private var isStaticRender
    @Environment(\.telemetryPanelVisible) private var isPanelVisible
    @Environment(\.telemetryReduceMotion) private var reduceMotion

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
                gateLetters: polarGateWeekdayLetters(for: loc.language),
                todayLabel: loc("today").uppercased(),
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
                Text("* Concentric 24-hour chronometer · 00:00 meridian index (01 Mon outer → 07 Sun inner)")
                    .font(.system(size: 8.2, weight: .regular, design: .serif))
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

/// Interactive child view isolating hover & pin state below `TimeKpiStrip` so 120Hz mouse moves
/// never re-evaluate KPIs, week-of-month geometry, or arc cache lookups.
private struct PolarChronometerInteractiveDeck: View {
    let arcs: [PolarArc]
    let dayKeys: [String]
    let days: [String: DayTimeUsage]
    let todayKey: String
    let weekdaySymbols: [String]
    let gateLetters: [String]
    let todayLabel: String
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
    @State private var pinnedDayKey: String? = nil

    private let dialHeight: CGFloat = 236
    private let outerRadius: CGFloat = 82.0
    private let ringStep: CGFloat = 7.4
    private let weekendGap: CGFloat = 3.2
    private let gateHalfWidth: CGFloat = 6.8

    private var innerHubR: CGFloat {
        let sunR = CGFloat(InstrumentMath.polarRingRadius(
            dayIndex: 6,
            outerRadius: Double(outerRadius),
            ringStep: Double(ringStep),
            weekendGap: Double(weekendGap)
        ))
        return sunR - 6.8
    }

    private struct BezelArtworkKey: Hashable {
        let outerRadiusTenths: Int
        let innerHubTenths: Int
        let theme: AGYTheme.CacheKey
    }

    private var peakArc: PolarArc? {
        var best: PolarArc? = nil
        for arc in arcs where arc.inMonth && arc.interval.durationSeconds > 0 {
            if let cur = best {
                if arc.interval.durationSeconds > cur.interval.durationSeconds { best = arc }
            } else {
                best = arc
            }
        }
        return best
    }

    var body: some View {
        let currentPeak = peakArc
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 6) {
                HStack(spacing: 5) {
                    Text("03.1")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.accent.opacity(0.95))
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

                // Full-width Polar Chronometer Dial (cached bezel + cached NOW sweep + lightweight arcs/gate/hub)
                chronometerContainer(peakArc: currentPeak)
                    .frame(maxWidth: .infinity)
                    .frame(height: dialHeight)

                hoverReadoutRow(peakArc: currentPeak)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 7)

            HairlineRule(showCrosshairs: false)

            // 7-column Mon-Sun summary ledger with 01..07 ring index pairing + 5+2 break + click-to-pin
            weekdayLedgerStrip(peakDayKey: currentPeak?.dayKey)
        }
    }

    private func hoverReadoutRow(peakArc: PolarArc?) -> some View {
        let focusedDayKey = hoveredDayKey ?? pinnedDayKey
        let isPinnedOnly = (hoveredArc == nil && hoveredDayKey == nil && pinnedDayKey != nil)

        return HStack(spacing: 6) {
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
            } else if let key = focusedDayKey, let idx = dayKeys.firstIndex(of: key) {
                let sym = (weekdaySymbols.indices.contains(idx) ? weekdaySymbols[idx] : "").uppercased()
                let total = days[key]?.totalSeconds ?? 0
                Rectangle()
                    .fill(theme.accent)
                    .frame(width: 4, height: 4)
                if isPinnedOnly {
                    Text("PIN")
                        .font(.system(size: 6.6, weight: .bold, design: .monospaced))
                        .tracking(0.4)
                        .foregroundColor(theme.accent)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 0.5)
                        .overlay(Rectangle().stroke(theme.accent.opacity(0.65), lineWidth: 0.6))
                }
                Text("\(String(format: "%02d", idx + 1)) \(sym) · \(shortDate(key))")
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(theme.inkPrimary)
                Spacer(minLength: 4)
                Text(total > 0 ? TimeLogic.formatDurationShort(total).uppercased() : "0M")
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(theme.accent)
            } else {
                HStack(spacing: 3.5) {
                    Rectangle()
                        .fill(theme.accent)
                        .frame(width: 4.5, height: 4.5)
                    Text(todayLabel)
                        .font(.system(size: 7.2, weight: .semibold, design: .monospaced))
                        .tracking(0.5)
                        .foregroundColor(theme.accent)
                }

                if let peak = peakArc {
                    HStack(spacing: 3.5) {
                        Rectangle()
                            .stroke(theme.accentSecondary, lineWidth: 1.0)
                            .frame(width: 4.5, height: 4.5)
                            .rotationEffect(.degrees(45))
                        Text(formatPolarPeakTag(peak.interval.durationSeconds))
                            .font(.system(size: 7.2, weight: .semibold, design: .monospaced))
                            .tracking(0.5)
                            .foregroundColor(theme.accentSecondary)
                    }
                }

                Spacer(minLength: 4)

                Text("01–07 · CLICK TO PIN · 5+2")
                    .font(.system(size: 7.0, weight: .regular, design: .monospaced))
                    .tracking(0.4)
                    .foregroundColor(theme.inkMuted)
            }
        }
        .frame(height: 12)
    }

    @ViewBuilder
    private func chronometerContainer(peakArc: PolarArc?) -> some View {
        let showsToday = dayKeys.contains(todayKey)
        let todayIdx = dayKeys.firstIndex(of: todayKey)
        let hubR = innerHubR

        // Focused center hub overlay (only populated when hovering or pinning; nil in idle state)
        let hubFocus: PolarHubFocus? = {
            if let h = hoveredArc {
                let sym = (weekdaySymbols.indices.contains(h.dayIndex) ? weekdaySymbols[h.dayIndex] : "").uppercased()
                return PolarHubFocus(
                    topLabel: sym,
                    bottomValue: TimeLogic.formatDurationShort(h.interval.durationSeconds).uppercased()
                )
            }
            if let key = hoveredDayKey ?? pinnedDayKey, let idx = dayKeys.firstIndex(of: key) {
                let sym = (weekdaySymbols.indices.contains(idx) ? weekdaySymbols[idx] : "").uppercased()
                let total = days[key]?.totalSeconds ?? 0
                return PolarHubFocus(
                    topLabel: sym,
                    bottomValue: total > 0 ? TimeLogic.formatDurationShort(total).uppercased() : "0M"
                )
            }
            return nil
        }()

        GeometryReader { geo in
            ZStack {
                // Layer 1: Pre-rendered 2x Retina cached horological bezel (centered inside full-width container)
                CachedTelemetryArtwork(
                    key: BezelArtworkKey(
                        outerRadiusTenths: Int((outerRadius * 10).rounded()),
                        innerHubTenths: Int((hubR * 10).rounded()),
                        theme: theme.cacheKey
                    ),
                    width: dialHeight,
                    height: dialHeight
                ) {
                    PolarDialBezelLayer(
                        outerRadius: outerRadius,
                        innerHubR: hubR,
                        theme: theme
                    )
                }
                .allowsHitTesting(false)

                // Layer 2: Isolated NOW stippled radar sweep + idle HH:MM/24H center hub
                // Cached per minute in PolarSweepArtworkCache; rendered under arcs & gate so data stays razor-sharp.
                if TelemetryAnimationGate.shouldAnimate(
                    active: showsToday,
                    panelVisible: isPanelVisible,
                    reduceMotion: reduceMotion,
                    staticRender: isStaticRender
                ) {
                    TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: 30.0)) { ctx in
                        PolarNowSweepAndHubLayer(
                            now: ctx.date,
                            showsToday: true,
                            dialSize: dialHeight,
                            outerRadius: outerRadius,
                            innerHubR: hubR,
                            theme: theme
                        )
                    }
                } else {
                    PolarNowSweepAndHubLayer(
                        now: Date(),
                        showsToday: showsToday,
                        dialSize: dialHeight,
                        outerRadius: outerRadius,
                        innerHubR: hubR,
                        theme: theme
                    )
                }

                // Layer 3: Lightweight full-width activity rings, 5+2 separator, engraved arcs,
                // smart Peak callout, 00:00 Meridian Index Gate, and dynamic focus hub overlay.
                PolarDialActivityLayer(
                    arcs: arcs,
                    dayKeys: dayKeys,
                    weekdaySymbols: weekdaySymbols,
                    gateLetters: gateLetters,
                    todayKey: todayKey,
                    todayIdx: todayIdx,
                    peakArc: peakArc,
                    hoveredArc: hoveredArc,
                    hoveredDayKey: hoveredDayKey,
                    pinnedDayKey: pinnedDayKey,
                    hubFocus: hubFocus,
                    outerRadius: outerRadius,
                    ringStep: ringStep,
                    weekendGap: weekendGap,
                    gateHalfWidth: gateHalfWidth,
                    innerHubR: hubR,
                    theme: theme
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let pt):
                    let dx = Double(pt.x - geo.size.width * 0.5)
                    let dy = Double(pt.y - geo.size.height * 0.5)
                    let hit = InstrumentMath.hitTestPolarArc(
                        dx: dx,
                        dy: dy,
                        outerRadius: Double(outerRadius),
                        ringStep: Double(ringStep),
                        ringCount: 7,
                        weekendGap: Double(weekendGap),
                        arcs: arcs
                    )
                    PointingCursorCoordinator.shared.setPointing(hit != nil, token: "polar-dial-arc")
                    if hoveredArc != hit {
                        hoveredArc = hit
                    }
                    if hit != nil && hoveredDayKey != nil {
                        hoveredDayKey = nil
                    }
                case .ended:
                    PointingCursorCoordinator.shared.setPointing(false, token: "polar-dial-arc")
                    if hoveredArc != nil {
                        hoveredArc = nil
                    }
                }
            }
            .onTapGesture {
                if let h = hoveredArc {
                    pinnedDayKey = (pinnedDayKey == h.dayKey) ? nil : h.dayKey
                } else if pinnedDayKey != nil {
                    pinnedDayKey = nil
                }
            }
            .onDisappear {
                PointingCursorCoordinator.shared.setPointing(false, token: "polar-dial-arc")
            }
        }
        .onChange(of: dayKeys) { _ in
            hoveredArc = nil
            hoveredDayKey = nil
            pinnedDayKey = nil
        }
        .onChange(of: isPanelVisible) { visible in
            if !visible {
                PointingCursorCoordinator.shared.setPointing(false, token: "polar-dial-arc")
                hoveredArc = nil
                hoveredDayKey = nil
                pinnedDayKey = nil
            }
        }
    }

    private func weekdayLedgerStrip(peakDayKey: String?) -> some View {
        let anyUserFocus = (hoveredArc != nil || hoveredDayKey != nil || pinnedDayKey != nil)

        return HStack(spacing: 0) {
            ForEach(Array(dayKeys.enumerated()), id: \.element) { idx, key in
                let day = days[key]
                let total = day?.totalSeconds ?? 0
                let isToday = (key == todayKey)
                let isPinned = (pinnedDayKey == key)
                let isHovered = (hoveredDayKey == key || hoveredArc?.dayKey == key)
                let isPeakDay = (key == peakDayKey)
                let isFocusedCell = isPinned || isHovered || (!anyUserFocus && isToday)
                let sym = (weekdaySymbols.indices.contains(idx) ? weekdaySymbols[idx] : "").uppercased()
                let ringNum = String(format: "%02d", idx + 1)

                VStack(spacing: 2.0) {
                    HStack(spacing: 2.0) {
                        if isToday {
                            Rectangle()
                                .fill(isFocusedCell ? theme.accent : theme.accent.opacity(0.65))
                                .frame(width: 3.2, height: 3.2)
                        }
                        Text(ringNum)
                            .font(.system(size: 6.0, weight: isFocusedCell ? .semibold : .regular, design: .monospaced))
                            .foregroundColor(isFocusedCell ? theme.accent.opacity(0.92) : theme.inkMuted.opacity(0.78))
                        Text(sym)
                            .font(.system(size: 7.3, weight: isFocusedCell ? .bold : .medium, design: .monospaced))
                            .tracking(0.2)
                            .foregroundColor(isFocusedCell ? theme.inkPrimary : (idx >= 5 ? theme.inkMuted : theme.inkSecondary))
                            .lineLimit(1)
                        if isPeakDay && !isToday {
                            Rectangle()
                                .stroke(theme.accentSecondary, lineWidth: 0.9)
                                .frame(width: 3.3, height: 3.3)
                                .rotationEffect(.degrees(45))
                        }
                    }
                    Text(total > 0 ? TimeLogic.formatDurationShort(total).uppercased() : "—")
                        .font(.system(size: 8.5, weight: isFocusedCell ? .semibold : .regular, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(
                            isFocusedCell
                                ? theme.accent
                                : (total > 0 ? theme.inkPrimary.opacity(idx >= 5 ? 0.68 : 0.86) : theme.inkMuted.opacity(0.75))
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    ZStack(alignment: .top) {
                        if isFocusedCell {
                            Rectangle()
                                .fill(theme.surfaceRaised.opacity(theme.isNotch ? 1.0 : (theme.isDark ? 0.50 : 0.72)))
                            Rectangle()
                                .fill(theme.accent)
                                .frame(height: isPinned ? 2.0 : 1.5)
                        } else if idx >= 5 {
                            Rectangle()
                                .fill(theme.surface.opacity(theme.isDark ? 0.24 : 0.34))
                        }
                    }
                )
                .contentShape(Rectangle())
                .onHover { inside in
                    PointingCursorCoordinator.shared.setPointing(inside, token: "polar-ledger-\(idx)")
                    let next = inside ? key : (hoveredDayKey == key ? nil : hoveredDayKey)
                    if hoveredDayKey != next {
                        hoveredDayKey = next
                    }
                }
                .onTapGesture {
                    pinnedDayKey = (pinnedDayKey == key) ? nil : key
                }
                .onDisappear {
                    PointingCursorCoordinator.shared.setPointing(false, token: "polar-ledger-\(idx)")
                }

                if idx < dayKeys.count - 1 {
                    if idx == 4 {
                        // Crisp 5 + 2 double-hairline break mirroring the dial's weekday/weekend split
                        HStack(spacing: 1.5) {
                            Rectangle().fill(theme.hairlineStrong.opacity(0.65)).frame(width: 0.75)
                            Rectangle().fill(theme.hairlineStrong.opacity(0.65)).frame(width: 0.75)
                        }
                    } else {
                        Rectangle().fill(theme.hairline.opacity(0.75)).frame(width: 0.75)
                    }
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

private struct PolarHubFocus: Equatable {
    let topLabel: String
    let bottomValue: String
}

/// Static Polar Chronometer Bezel — Swiss horological 24h ticks, 8 degree/hour markings,
/// subtle outer stippled compass dots, and cardinal/octant astrolabe spokes (Equatable).
/// Omits the 00:00 spoke & shortens the 00:00 inward tick to keep the Meridian Index Gate spotless.
private struct PolarDialBezelLayer: View, Equatable {
    let outerRadius: CGFloat
    let innerHubR: CGFloat
    let theme: AGYTheme

    var body: some View {
        Canvas { context, size in
            let cx = size.width * 0.5
            let cy = size.height * 0.5
            let bezelR = outerRadius + 7.5
            let compassR = bezelR + 4.4

            // 1. Cardinal spokes (06/12/18 — 00:00 stops outside Meridian Index Gate) + dashed octant spokes (03/09/15/21)
            var cardinalSpokes = Path()
            var octantSpokes = Path()
            for hour in [6, 12, 18] {
                let ang = InstrumentMath.polarAngle(secondsOfDay: hour * 3600)
                cardinalSpokes.move(to: CGPoint(x: cx + CGFloat(cos(ang)) * innerHubR, y: cy + CGFloat(sin(ang)) * innerHubR))
                cardinalSpokes.addLine(to: CGPoint(x: cx + CGFloat(cos(ang)) * bezelR, y: cy + CGFloat(sin(ang)) * bezelR))
            }
            for hour in [3, 9, 15, 21] {
                let ang = InstrumentMath.polarAngle(secondsOfDay: hour * 3600)
                octantSpokes.move(to: CGPoint(x: cx + CGFloat(cos(ang)) * innerHubR, y: cy + CGFloat(sin(ang)) * innerHubR))
                octantSpokes.addLine(to: CGPoint(x: cx + CGFloat(cos(ang)) * bezelR, y: cy + CGFloat(sin(ang)) * bezelR))
            }
            context.stroke(
                octantSpokes,
                with: .color(theme.hairline.opacity(0.34)),
                style: StrokeStyle(lineWidth: 0.5, dash: [1.5, 3.0])
            )
            context.stroke(
                cardinalSpokes,
                with: .color(theme.hairlineStrong.opacity(theme.isDark ? 0.36 : 0.30)),
                lineWidth: 0.6
            )

            // 2. Outer calibrated 24-hour bezel ring + delicate chapter ring
            let bezelRect = CGRect(x: cx - bezelR, y: cy - bezelR, width: bezelR * 2, height: bezelR * 2)
            let chapterRect = CGRect(x: cx - compassR, y: cy - compassR, width: compassR * 2, height: compassR * 2)
            context.stroke(Path(ellipseIn: chapterRect), with: .color(theme.hairline.opacity(0.42)), lineWidth: 0.45)
            context.stroke(Path(ellipseIn: bezelRect), with: .color(theme.hairlineStrong.opacity(0.88)), lineWidth: 0.75)

            // 3. 24-hour calibrated bezel ticks batched into 3 weight paths
            var cardinalTicks = Path()
            var octantTicks = Path()
            var minorTicks = Path()
            for h in 0..<24 {
                let ang = InstrumentMath.polarAngle(secondsOfDay: h * 3600)
                let isCardinal = (h % 6 == 0)
                let isOctant = (h % 3 == 0) && !isCardinal
                // Shorten inward tip at 00:00 so it never crowds the top ring letter in the meridian gate
                let cardinalIn: CGFloat = (h == 0) ? 2.4 : 4.4
                let tIn = bezelR - (isCardinal ? cardinalIn : (isOctant ? 3.0 : 1.7))
                let tOut = bezelR + (isCardinal ? 2.8 : (isOctant ? 1.8 : 0.9))
                let p0 = CGPoint(x: cx + CGFloat(cos(ang)) * tIn, y: cy + CGFloat(sin(ang)) * tIn)
                let p1 = CGPoint(x: cx + CGFloat(cos(ang)) * tOut, y: cy + CGFloat(sin(ang)) * tOut)
                if isCardinal {
                    if theme.isMultiColorSpectrum {
                        let cardinalColor: Color = {
                            switch h {
                            case 0:  return theme.accent
                            case 6:  return theme.accentQuaternary
                            case 12: return theme.accentTertiary
                            default: return theme.accentSecondary
                            }
                        }()
                        var tick = Path()
                        tick.move(to: p0)
                        tick.addLine(to: p1)
                        context.stroke(tick, with: .color(cardinalColor.opacity(0.86)), lineWidth: 1.05)
                    } else {
                        cardinalTicks.move(to: p0)
                        cardinalTicks.addLine(to: p1)
                    }
                } else if isOctant {
                    octantTicks.move(to: p0)
                    octantTicks.addLine(to: p1)
                } else {
                    minorTicks.move(to: p0)
                    minorTicks.addLine(to: p1)
                }
            }
            context.stroke(minorTicks, with: .color(theme.hairlineStrong.opacity(0.78)), lineWidth: 0.55)
            context.stroke(octantTicks, with: .color(theme.inkSecondary.opacity(0.74)), lineWidth: 0.7)
            if !cardinalTicks.isEmpty {
                context.stroke(cardinalTicks, with: .color(theme.inkPrimary.opacity(0.78)), lineWidth: 0.95)
            }

            // 4. Subtle outer stippled compass dots (72 steps = every 5 deg, batched into 1 Path)
            var compassDots = Path()
            let dotSize: CGFloat = 0.9
            for step in 0..<72 {
                if step % 9 == 0 { continue }
                let ang = -Double.pi * 0.5 + (Double(step) / 72.0) * 2.0 * Double.pi
                let dx = cx + CGFloat(cos(ang)) * compassR - dotSize * 0.5
                let dy = cy + CGFloat(sin(ang)) * compassR - dotSize * 0.5
                compassDots.addRect(CGRect(x: dx, y: dy, width: dotSize, height: dotSize))
            }
            context.fill(compassDots, with: .color(theme.inkMuted.opacity(0.46)))

            // 5. Coordinate-anchored 8 degree/hour markings (00/06/12/18 primary, 03/09/15/21 subtle)
            let labelR = bezelR + 11.8
            let hourMarkings: [(hour: Int, text: String, primary: Bool)] = [
                (0,  "00", true),  (3,  "03", false),
                (6,  "06", true),  (9,  "09", false),
                (12, "12", true),  (15, "15", false),
                (18, "18", true),  (21, "21", false),
            ]
            for mark in hourMarkings {
                let ang = InstrumentMath.polarAngle(secondsOfDay: mark.hour * 3600)
                let pos = CGPoint(x: cx + CGFloat(cos(ang)) * labelR, y: cy + CGFloat(sin(ang)) * labelR)
                let primaryColor: Color = {
                    guard theme.isMultiColorSpectrum else { return theme.inkPrimary.opacity(0.84) }
                    switch mark.hour {
                    case 0:  return theme.accent.opacity(0.90)
                    case 6:  return theme.accentQuaternary.opacity(0.90)
                    case 12: return theme.accentTertiary.opacity(0.90)
                    default: return theme.accentSecondary.opacity(0.88)
                    }
                }()
                let tView = Text(mark.text)
                    .font(.system(
                        size: mark.primary ? 7.6 : 6.5,
                        weight: mark.primary ? .semibold : .regular,
                        design: .monospaced
                    ))
                    .foregroundColor(mark.primary ? primaryColor : theme.inkMuted.opacity(0.84))
                context.draw(tView, at: pos)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Dynamic Polar Chronometer Activity Layer — 7 gated rings + 5+2 separator, precision dual-rail
/// engraved arcs with strict accent semantics, smart outer-quadrant Peak callout, 00:00 Meridian
/// Index Gate, and focused center hub overlay.
private struct PolarDialActivityLayer: View {
    let arcs: [PolarArc]
    let dayKeys: [String]
    let weekdaySymbols: [String]
    let gateLetters: [String]
    let todayKey: String
    let todayIdx: Int?
    let peakArc: PolarArc?
    let hoveredArc: PolarArc?
    let hoveredDayKey: String?
    let pinnedDayKey: String?
    let hubFocus: PolarHubFocus?
    let outerRadius: CGFloat
    let ringStep: CGFloat
    let weekendGap: CGFloat
    let gateHalfWidth: CGFloat
    let innerHubR: CGFloat
    let theme: AGYTheme

    private func ringRadius(for idx: Int) -> CGFloat {
        CGFloat(InstrumentMath.polarRingRadius(
            dayIndex: idx,
            outerRadius: Double(outerRadius),
            ringStep: Double(ringStep),
            weekendGap: Double(weekendGap)
        ))
    }

    private var weekendSeparatorRadius: CGFloat {
        (ringRadius(for: 4) + ringRadius(for: 5)) * 0.5 + 0.4
    }

    var body: some View {
        Canvas { context, size in
            let cx = size.width * 0.5
            let cy = size.height * 0.5
            let center = CGPoint(x: cx, y: cy)
            let bezelR = outerRadius + 7.5
            let labelR = bezelR + 11.8
            let railOffset: CGFloat = 2.0

            // Focus priority:
            // - For arcs/rings: direct arc hover > ledger day hover > pinned day > Today (idle)
            // - For gate ring highlight: pinned > hovered > today when pinned & idle; hover previews active ring
            let activeUserDayKey = hoveredArc?.dayKey ?? hoveredDayKey ?? pinnedDayKey
            let anyUserFocus = (hoveredArc != nil || hoveredDayKey != nil || pinnedDayKey != nil)
            let highlightedGateDayKey: String? = {
                if let hArc = hoveredArc { return hArc.dayKey }
                if let hDay = hoveredDayKey { return hDay }
                if let pDay = pinnedDayKey { return pDay }
                return dayKeys.contains(todayKey) ? todayKey : nil
            }()
            let highlightedGateIdx = highlightedGateDayKey.flatMap { dayKeys.firstIndex(of: $0) }

            // ── 1. Seven Concentric Rings (Interrupted Cleanly at 00:00 Gate) + 5+2 Separator ──
            func addGatedCircle(to path: inout Path, radius r: CGFloat) {
                let gapAngle = asin(min(0.95, Double(gateHalfWidth / r)))
                let start = -Double.pi * 0.5 + gapAngle
                let end = Double.pi * 1.5 - gapAngle
                path.move(to: CGPoint(x: cx + CGFloat(cos(start)) * r, y: cy + CGFloat(sin(start)) * r))
                path.addArc(center: center, radius: r, startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
            }

            var weekdayRings = Path()
            var weekendRings = Path()
            var accentRings = Path()
            for idx in 0..<7 {
                let r = ringRadius(for: idx)
                let isAccentRing = (highlightedGateIdx == idx)
                if isAccentRing {
                    addGatedCircle(to: &accentRings, radius: r)
                } else if idx >= 5 {
                    addGatedCircle(to: &weekendRings, radius: r)
                } else {
                    addGatedCircle(to: &weekdayRings, radius: r)
                }
            }
            context.stroke(weekdayRings, with: .color(theme.hairline.opacity(0.68)), lineWidth: 0.6)
            context.stroke(weekendRings, with: .color(theme.hairline.opacity(0.55)), lineWidth: 0.55)

            // Subtle dashed 5+2 weekday/weekend radial separator ring
            var sepRing = Path()
            addGatedCircle(to: &sepRing, radius: weekendSeparatorRadius)
            context.stroke(
                sepRing,
                with: .color(theme.hairlineStrong.opacity(theme.isDark ? 0.62 : 0.52)),
                style: StrokeStyle(lineWidth: 0.65, dash: [2.2, 2.8])
            )

            if !accentRings.isEmpty {
                context.stroke(
                    accentRings,
                    with: .color(theme.accent.opacity(anyUserFocus ? (theme.isDark ? 0.58 : 0.48) : (theme.isDark ? 0.52 : 0.42))),
                    lineWidth: 0.9
                )
            }

            // ── 2. Precision Dual-Rail Engraved Activity Arcs (Strict Accent Semantics) ──
            var outMonthMain = Path()
            var weekdayMain = Path(), weekdayRail = Path(), weekdayTicks = Path()
            var weekendMain = Path(), weekendRail = Path(), weekendTicks = Path()
            var modelMain: [ModelClass: Path] = [:]
            var modelRail: [ModelClass: Path] = [:]
            var modelTicks: [ModelClass: Path] = [:]
            var peakMain = Path(), peakRail = Path(), peakTicks = Path()
            var todayMain = Path(), todayRail = Path(), todayTicks = Path()
            var focusedMain = Path(), focusedRail = Path(), focusedTicks = Path()

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
                let capIn = r - 1.4
                let capOut = r + railOffset + 0.35
                for a in [start, end] {
                    let ca = CGFloat(cos(a)), sa = CGFloat(sin(a))
                    ticksPath.move(to: CGPoint(x: cx + ca * capIn, y: cy + sa * capIn))
                    ticksPath.addLine(to: CGPoint(x: cx + ca * capOut, y: cy + sa * capOut))
                }
                let span = end - start
                let hatchStep = 0.068
                if span > hatchStep * 1.4 {
                    let tickIn = r - 0.85
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

            for arc in arcs {
                let r = ringRadius(for: arc.dayIndex)
                let isDirectlyHoveredArc = (hoveredArc == arc)
                let isFocusedDayArc = (hoveredArc == nil && activeUserDayKey != nil && activeUserDayKey == arc.dayKey)
                let isTodayArc = (arc.dayKey == todayKey)
                let isPeakArc = (arc == peakArc)

                if isDirectlyHoveredArc || isFocusedDayArc {
                    appendArc(to: &focusedMain, radius: r, start: arc.startAngle, end: arc.endAngle)
                    appendArc(to: &focusedRail, radius: r + railOffset, start: arc.startAngle, end: arc.endAngle)
                    appendEngravedTicks(to: &focusedTicks, radius: r, start: arc.startAngle, end: arc.endAngle)
                } else if !arc.inMonth {
                    appendArc(to: &outMonthMain, radius: r, start: arc.startAngle, end: arc.endAngle)
                } else if isTodayArc && !anyUserFocus {
                    appendArc(to: &todayMain, radius: r, start: arc.startAngle, end: arc.endAngle)
                    appendArc(to: &todayRail, radius: r + railOffset, start: arc.startAngle, end: arc.endAngle)
                    appendEngravedTicks(to: &todayTicks, radius: r, start: arc.startAngle, end: arc.endAngle)
                } else if isPeakArc && !theme.isMultiColorSpectrum {
                    appendArc(to: &peakMain, radius: r, start: arc.startAngle, end: arc.endAngle)
                    appendArc(to: &peakRail, radius: r + railOffset, start: arc.startAngle, end: arc.endAngle)
                    appendEngravedTicks(to: &peakTicks, radius: r, start: arc.startAngle, end: arc.endAngle)
                } else if theme.isMultiColorSpectrum {
                    let mc = Self.classifyModel(arc.interval.model)
                    var mPath = modelMain[mc] ?? Path()
                    var rPath = modelRail[mc] ?? Path()
                    var tPath = modelTicks[mc] ?? Path()
                    appendArc(to: &mPath, radius: r, start: arc.startAngle, end: arc.endAngle)
                    appendArc(to: &rPath, radius: r + railOffset, start: arc.startAngle, end: arc.endAngle)
                    appendEngravedTicks(to: &tPath, radius: r, start: arc.startAngle, end: arc.endAngle)
                    modelMain[mc] = mPath
                    modelRail[mc] = rPath
                    modelTicks[mc] = tPath
                } else if arc.dayIndex >= 5 {
                    appendArc(to: &weekendMain, radius: r, start: arc.startAngle, end: arc.endAngle)
                    appendArc(to: &weekendRail, radius: r + railOffset, start: arc.startAngle, end: arc.endAngle)
                    appendEngravedTicks(to: &weekendTicks, radius: r, start: arc.startAngle, end: arc.endAngle)
                } else {
                    appendArc(to: &weekdayMain, radius: r, start: arc.startAngle, end: arc.endAngle)
                    appendArc(to: &weekdayRail, radius: r + railOffset, start: arc.startAngle, end: arc.endAngle)
                    appendEngravedTicks(to: &weekdayTicks, radius: r, start: arc.startAngle, end: arc.endAngle)
                }
            }

            if !outMonthMain.isEmpty {
                context.stroke(
                    outMonthMain,
                    with: .color(theme.inkMuted.opacity(anyUserFocus ? 0.14 : 0.28)),
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .butt)
                )
            }

            if theme.isMultiColorSpectrum {
                for mc in ModelClass.allCases {
                    guard let mPath = modelMain[mc], !mPath.isEmpty else { continue }
                    let color = theme.modelColor(mc)
                    context.stroke(
                        mPath,
                        with: .color(color.opacity(anyUserFocus ? 0.22 : 0.78)),
                        style: StrokeStyle(lineWidth: 2.25, lineCap: .butt)
                    )
                    if let rPath = modelRail[mc], !rPath.isEmpty {
                        context.stroke(
                            rPath,
                            with: .color(color.opacity(anyUserFocus ? 0.11 : 0.40)),
                            style: StrokeStyle(lineWidth: 0.5, lineCap: .butt)
                        )
                    }
                    if let tPath = modelTicks[mc], !tPath.isEmpty {
                        context.stroke(
                            tPath,
                            with: .color(color.opacity(anyUserFocus ? 0.11 : 0.44)),
                            lineWidth: 0.48
                        )
                    }
                }
            } else {
                // Disciplined archival monochrome ink for Monolith & Duotone presets so Today/Focus pops
                let wkInk = theme.inkPrimary
                if !weekdayMain.isEmpty {
                    context.stroke(
                        weekdayMain,
                        with: .color(wkInk.opacity(anyUserFocus ? (theme.isDark ? 0.24 : 0.22) : (theme.isDark ? 0.74 : 0.70))),
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .butt)
                    )
                    context.stroke(
                        weekdayRail,
                        with: .color(wkInk.opacity(anyUserFocus ? 0.12 : (theme.isDark ? 0.36 : 0.34))),
                        style: StrokeStyle(lineWidth: 0.5, lineCap: .butt)
                    )
                    context.stroke(
                        weekdayTicks,
                        with: .color(wkInk.opacity(anyUserFocus ? 0.12 : (theme.isDark ? 0.42 : 0.40))),
                        lineWidth: 0.48
                    )
                }

                let weInk = theme.inkSecondary
                if !weekendMain.isEmpty {
                    context.stroke(
                        weekendMain,
                        with: .color(weInk.opacity(anyUserFocus ? (theme.isDark ? 0.22 : 0.20) : (theme.isDark ? 0.68 : 0.66))),
                        style: StrokeStyle(lineWidth: 2.1, lineCap: .butt)
                    )
                    context.stroke(
                        weekendRail,
                        with: .color(weInk.opacity(anyUserFocus ? 0.11 : (theme.isDark ? 0.34 : 0.32))),
                        style: StrokeStyle(lineWidth: 0.5, lineCap: .butt)
                    )
                    context.stroke(
                        weekendTicks,
                        with: .color(weInk.opacity(anyUserFocus ? 0.11 : (theme.isDark ? 0.38 : 0.36))),
                        lineWidth: 0.48
                    )
                }

                // Peak arc (when != Today and not focused): bold archival ink + accentSecondary outer rail
                if !peakMain.isEmpty {
                    context.stroke(
                        peakMain,
                        with: .color(theme.inkPrimary.opacity(anyUserFocus ? 0.30 : 0.96)),
                        style: StrokeStyle(lineWidth: 2.55, lineCap: .butt)
                    )
                    context.stroke(
                        peakRail,
                        with: .color(theme.accentSecondary.opacity(anyUserFocus ? 0.28 : 0.88)),
                        style: StrokeStyle(lineWidth: 0.7, lineCap: .butt)
                    )
                    context.stroke(
                        peakTicks,
                        with: .color(theme.inkPrimary.opacity(anyUserFocus ? 0.18 : 0.60)),
                        lineWidth: 0.52
                    )
                }
            }

            // Today's ring arcs (idle state): strictly theme.accent
            if !todayMain.isEmpty {
                context.stroke(
                    todayMain,
                    with: .color(theme.accent.opacity(theme.isDark ? 0.26 : 0.14)),
                    style: StrokeStyle(lineWidth: theme.isDark ? 5.8 : 5.2, lineCap: .butt)
                )
                context.stroke(
                    todayMain,
                    with: .color(theme.accent),
                    style: StrokeStyle(lineWidth: 2.7, lineCap: .butt)
                )
                context.stroke(
                    todayRail,
                    with: .color(theme.accent.opacity(0.68)),
                    style: StrokeStyle(lineWidth: 0.6, lineCap: .butt)
                )
                context.stroke(
                    todayTicks,
                    with: .color(theme.accent.opacity(0.75)),
                    lineWidth: 0.55
                )
            }

            // Hovered or Pinned day/arc: strictly theme.accent
            if !focusedMain.isEmpty {
                context.stroke(
                    focusedMain,
                    with: .color(theme.accent.opacity(theme.isDark ? 0.30 : 0.16)),
                    style: StrokeStyle(lineWidth: 6.4, lineCap: .butt)
                )
                context.stroke(
                    focusedMain,
                    with: .color(theme.accent),
                    style: StrokeStyle(lineWidth: 2.85, lineCap: .butt)
                )
                context.stroke(
                    focusedRail,
                    with: .color(theme.accent.opacity(0.76)),
                    style: StrokeStyle(lineWidth: 0.62, lineCap: .butt)
                )
                context.stroke(
                    focusedTicks,
                    with: .color(theme.accent.opacity(0.76)),
                    lineWidth: 0.58
                )
            }

            // ── 3. Smart Peak Callout (Hollow Apex Diamond + Dashed Sightline + Fred Chevron + Collision-Free Badge) ──
            if let peak = peakArc {
                let peakIsFocused = (hoveredArc == peak) || (hoveredArc == nil && activeUserDayKey == peak.dayKey)
                let peakAlpha: Double = (!anyUserFocus || peakIsFocused) ? 1.0 : 0.34
                let peakR = ringRadius(for: peak.dayIndex)
                let mid = (peak.startAngle + peak.endAngle) * 0.5
                let cm = CGFloat(cos(mid))
                let sm = CGFloat(sin(mid))
                let peakColor = theme.accentSecondary

                // Dashed radial sightline from peak arc outward to bezel
                var sightline = Path()
                sightline.move(to: CGPoint(x: cx + cm * (peakR + railOffset + 1.6), y: cy + sm * (peakR + railOffset + 1.6)))
                sightline.addLine(to: CGPoint(x: cx + cm * (bezelR + 1.2), y: cy + sm * (bezelR + 1.2)))
                context.stroke(
                    sightline,
                    with: .color(peakColor.opacity(0.76 * peakAlpha)),
                    style: StrokeStyle(lineWidth: 0.75, dash: [2.0, 2.0])
                )

                // Hollow apex diamond centered on the Peak arc midpoint
                let ax = cx + cm * peakR
                let ay = cy + sm * peakR
                let dR: CGFloat = 3.2
                var diamond = Path()
                diamond.move(to: CGPoint(x: ax, y: ay - dR))
                diamond.addLine(to: CGPoint(x: ax + dR, y: ay))
                diamond.addLine(to: CGPoint(x: ax, y: ay + dR))
                diamond.addLine(to: CGPoint(x: ax - dR, y: ay))
                diamond.closeSubpath()
                context.fill(diamond, with: .color(theme.canvas))
                context.stroke(diamond, with: .color(peakColor.opacity(peakAlpha)), lineWidth: 1.2)

                // Inward-pointing Fred chevron pip outside bezel
                let tipR = bezelR + 1.4
                let baseR = bezelR + 6.0
                let halfW: CGFloat = 2.5
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
                context.fill(pip, with: .color(peakColor.opacity(peakAlpha)))

                // Smart outer-quadrant `PK X.XH` callout (guaranteed clear of 00/03/06/09/12/15/18/21 & container bounds)
                if size.width >= 310 {
                    let goLeft = (cm < -0.05)
                    let tagW: CGFloat = 46.0
                    let tagH: CGFloat = 13.5

                    // Detect proximity to any 3-hour label bearing (multiples of pi/4) so leader skirts around text
                    let step45 = Double.pi * 0.25
                    let nearestIdx = (mid / step45).rounded()
                    let angDistToLabel = abs(mid - nearestIdx * step45)
                    let nearHourLabel = angDistToLabel < 0.22

                    var targetCenterY = cy + sm * (bezelR + 16.0)
                    if nearHourLabel {
                        if abs(sm) < 0.25 {
                            // Near 06:00 or 18:00: nudge vertically clear of the horizontal hour label
                            targetCenterY += (sm <= 0 ? -15.0 : 15.0)
                        } else if abs(cm) >= 0.25 {
                            // Near 03/09/15/21: nudge gently toward horizontal midline for open margin
                            targetCenterY += (sm > 0 ? -10.0 : 10.0)
                        }
                    }
                    let clampedCenterY = min(max(targetCenterY, 14.0), size.height - 19.0)

                    // Horizontal exclusion circle outside all 8 hour labels (radius = labelR + 11.5)
                    let clearR = labelR + 11.5
                    let dy = clampedCenterY - cy
                    let minDx = sqrt(max(0.0, clearR * clearR - dy * dy)) + 5.0

                    let tagMinX: CGFloat
                    if goLeft {
                        let desiredMaxX = min(cx - minDx, cx - 70.0)
                        tagMinX = max(3.0, desiredMaxX - tagW)
                    } else {
                        let desiredMinX = max(cx + minDx, cx + 70.0)
                        tagMinX = min(size.width - tagW - 3.0, desiredMinX)
                    }
                    let tagRect = CGRect(
                        x: tagMinX,
                        y: clampedCenterY - tagH * 0.5,
                        width: tagW,
                        height: tagH
                    )

                    let elbowStart = CGPoint(x: cx + cm * (baseR + 1.4), y: cy + sm * (baseR + 1.4))
                    let elbowEnd = CGPoint(x: goLeft ? tagRect.maxX : tagRect.minX, y: tagRect.midY)
                    let kneeX: CGFloat = {
                        if nearHourLabel && abs(sm) < 0.25 {
                            return elbowStart.x + (goLeft ? -4.0 : 4.0)
                        }
                        let rawMidX = cx + cm * (baseR + 10.0)
                        return goLeft ? max(tagRect.maxX + 6.0, rawMidX) : min(tagRect.minX - 6.0, rawMidX)
                    }()
                    let elbowMid = CGPoint(x: kneeX, y: tagRect.midY)

                    var leader = Path()
                    leader.move(to: elbowStart)
                    leader.addLine(to: elbowMid)
                    leader.addLine(to: elbowEnd)
                    context.stroke(leader, with: .color(peakColor.opacity(0.75 * peakAlpha)), lineWidth: 0.7)

                    context.fill(Path(tagRect), with: .color(theme.canvas.opacity(0.96)))
                    context.fill(Path(tagRect), with: .color(peakColor.opacity((theme.isDark ? 0.14 : 0.08) * peakAlpha)))
                    context.stroke(Path(tagRect), with: .color(peakColor.opacity(0.78 * peakAlpha)), lineWidth: 0.75)

                    let pkLabel = Text(formatPolarPeakTag(peak.interval.durationSeconds))
                        .font(.system(size: 7.3, weight: .bold, design: .monospaced))
                        .foregroundColor(peakColor.opacity(peakAlpha))
                    context.draw(pkLabel, at: CGPoint(x: tagRect.midX, y: tagRect.midY))

                    let peakDaySym = (weekdaySymbols.indices.contains(peak.dayIndex) ? weekdaySymbols[peak.dayIndex] : "").uppercased()
                    let subCaption = Text("\(peakDaySym) \(TimeLogic.formatClock(peak.interval.startSec))–\(TimeLogic.formatClock(peak.interval.endSec))")
                        .font(.system(size: 6.2, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.inkSecondary.opacity(0.86 * peakAlpha))
                    context.draw(subCaption, at: CGPoint(x: tagRect.midX, y: tagRect.maxY + 6.5))
                }
            }

            // ── 4. Hovered Arc Optical Midpoint Lock + Bezel Bearing Tick ──
            if let h = hoveredArc {
                let r = ringRadius(for: h.dayIndex)
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

            // ── 5. 00:00 Meridian Index Gate (13.6pt Cutout Corridor + Flanking Hairlines + 7 Weekday Letters) ──
            let gateTopY = cy - (outerRadius + 4.0)
            let gateBotY = cy - (innerHubR + 1.6)
            let gateRect = CGRect(
                x: cx - gateHalfWidth,
                y: gateTopY,
                width: gateHalfWidth * 2.0,
                height: gateBotY - gateTopY
            )
            // Crisp canvas mask so NOW stipple or rings never muddy the 7 ring letters
            context.fill(Path(gateRect), with: .color(theme.canvas.opacity(0.96)))

            var gateRails = Path()
            for sx in [-gateHalfWidth, gateHalfWidth] {
                gateRails.move(to: CGPoint(x: cx + sx, y: gateTopY))
                gateRails.addLine(to: CGPoint(x: cx + sx, y: gateBotY))
            }
            // Tiny top framing ticks
            gateRails.move(to: CGPoint(x: cx - gateHalfWidth - 1.5, y: gateTopY))
            gateRails.addLine(to: CGPoint(x: cx - gateHalfWidth + 1.5, y: gateTopY))
            gateRails.move(to: CGPoint(x: cx + gateHalfWidth - 1.5, y: gateTopY))
            gateRails.addLine(to: CGPoint(x: cx + gateHalfWidth + 1.5, y: gateTopY))
            context.stroke(gateRails, with: .color(theme.hairlineStrong.opacity(0.65)), lineWidth: 0.55)

            // 5+2 gate divider tick between FRI (4) and SAT (5)
            let gateSepY = cy - weekendSeparatorRadius
            var gateSep = Path()
            gateSep.move(to: CGPoint(x: cx - gateHalfWidth - 1.6, y: gateSepY))
            gateSep.addLine(to: CGPoint(x: cx + gateHalfWidth + 1.6, y: gateSepY))
            context.stroke(gateSep, with: .color(theme.hairlineStrong.opacity(0.85)), lineWidth: 0.65)

            for idx in 0..<7 {
                let r = ringRadius(for: idx)
                let ly = cy - r
                let isHighlighted = (highlightedGateIdx == idx)

                if isHighlighted {
                    let slotRect = CGRect(
                        x: cx - gateHalfWidth + 0.6,
                        y: ly - 3.3,
                        width: gateHalfWidth * 2.0 - 1.2,
                        height: 6.6
                    )
                    context.fill(Path(slotRect), with: .color(theme.accent.opacity(theme.isDark ? 0.22 : 0.14)))
                    for sx in [-gateHalfWidth, gateHalfWidth] {
                        context.fill(
                            Path(CGRect(x: cx + sx - 1.1, y: ly - 1.1, width: 2.2, height: 2.2)),
                            with: .color(theme.accent)
                        )
                    }
                }

                let letter = gateLetters.indices.contains(idx) ? gateLetters[idx] : ""
                let letterColor: Color = isHighlighted
                    ? theme.accent
                    : (idx >= 5 ? theme.inkMuted : theme.inkSecondary)
                let letterText = Text(letter)
                    .font(.system(size: isHighlighted ? 6.2 : 5.8, weight: isHighlighted ? .bold : .medium, design: .monospaced))
                    .foregroundColor(letterColor)
                context.draw(letterText, at: CGPoint(x: cx, y: ly))
            }

            // ── 6. Dynamic Center Hub Overlay (Only Drawn on Hover/Pin; Idle Hub Lives in PolarSweepArtworkCache) ──
            if let focus = hubFocus {
                let hubRect = CGRect(x: cx - innerHubR, y: cy - innerHubR, width: innerHubR * 2, height: innerHubR * 2)
                let innerRingR = innerHubR - 2.6
                let innerRingRect = CGRect(x: cx - innerRingR, y: cy - innerRingR, width: innerRingR * 2, height: innerRingR * 2)

                context.fill(Path(ellipseIn: hubRect), with: .color(theme.canvas))
                context.stroke(Path(ellipseIn: hubRect), with: .color(theme.accent.opacity(0.92)), lineWidth: 0.95)
                context.stroke(Path(ellipseIn: innerRingRect), with: .color(theme.accent.opacity(0.28)), lineWidth: 0.45)

                var hubRule = Path()
                hubRule.move(to: CGPoint(x: cx - 10, y: cy + 0.5))
                hubRule.addLine(to: CGPoint(x: cx + 10, y: cy + 0.5))
                context.stroke(hubRule, with: .color(theme.hairline.opacity(0.80)), lineWidth: 0.5)

                let topText = Text(focus.topLabel)
                    .font(.system(size: 7.0, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundColor(theme.inkSecondary)
                let botText = Text(focus.bottomValue)
                    .font(.system(size: 8.6, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.accent)
                context.draw(topText, at: CGPoint(x: cx, y: cy - 6.0))
                context.draw(botText, at: CGPoint(x: cx, y: cy + 7.0))
            }
        }
        .allowsHitTesting(false)
    }

    private static func classifyModel(_ id: String?) -> ModelClass {
        guard let raw = id, !raw.isEmpty else { return .other }
        return ModelClass(rawValue: raw.lowercased()) ?? ModelClass.classify(raw)
    }
}

/// Dedicated 2-entry LRU cache for `PolarNowSweepAndHubLayer` so minute-by-minute
/// NOW sweep renders never evict heavy static artwork from the global 24-entry cache.
@MainActor
private final class PolarSweepArtworkCache {
    static let shared = PolarSweepArtworkCache()
    private var lru = BoundedLRUState<AnyHashable, NSImage>(maxEntries: 2)

    func image<K: Hashable, V: View>(
        for key: K,
        size: CGSize,
        @ViewBuilder content: () -> V
    ) -> NSImage? {
        guard size.width >= 2, size.height >= 2 else { return nil }
        let box = AnyHashable(key)
        if let hit = lru.get(box) { return hit }
        let renderer = ImageRenderer(
            content: content()
                .frame(width: size.width, height: size.height)
                .environment(\.telemetryStaticRender, true)
        )
        renderer.scale = 2.0
        guard let img = renderer.nsImage else { return nil }
        lru.set(img, for: box)
        return img
    }
}

/// Isolated NOW radar stippled sweep + live HH:MM center hub cached per minute in its own
/// 2-entry LRU so 120Hz hover & click-to-pin NEVER re-run the radial stipple loop.
private struct PolarNowSweepAndHubLayer: View {
    let now: Date
    let showsToday: Bool
    let dialSize: CGFloat
    let outerRadius: CGFloat
    let innerHubR: CGFloat
    let theme: AGYTheme

    @Environment(\.telemetryStaticRender) private var isStaticRender

    private struct SweepArtworkKey: Hashable {
        let nowMinute: Int
        let showsToday: Bool
        let dialPx: Int
        let innerHubTenths: Int
        let theme: AGYTheme.CacheKey
    }

    var body: some View {
        let cal = AppDate.gregorian
        let comps = cal.dateComponents([.hour, .minute], from: now)
        let nowMinute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let nowSec = nowMinute * 60
        let nowAngle = InstrumentMath.polarAngle(secondsOfDay: nowSec)
        let sweepView = sweepCanvas(nowAngle: nowAngle, nowSec: nowSec)

        if isStaticRender {
            sweepView.frame(width: dialSize, height: dialSize)
        } else if let img = PolarSweepArtworkCache.shared.image(
            for: SweepArtworkKey(
                nowMinute: nowMinute,
                showsToday: showsToday,
                dialPx: Int((dialSize * 2.0).rounded()),
                innerHubTenths: Int((innerHubR * 10).rounded()),
                theme: theme.cacheKey
            ),
            size: CGSize(width: dialSize, height: dialSize),
            content: { sweepView }
        ) {
            Image(nsImage: img)
                .resizable()
                .frame(width: dialSize, height: dialSize)
                .allowsHitTesting(false)
        } else {
            sweepView.frame(width: dialSize, height: dialSize)
        }
    }

    private func sweepCanvas(nowAngle: Double, nowSec: Int) -> some View {
        Canvas { context, size in
            let cx = size.width * 0.5
            let cy = size.height * 0.5
            let center = CGPoint(x: cx, y: cy)
            let bezelR = outerRadius + 7.5
            let sweepColor = theme.isMultiColorSpectrum ? theme.accentQuaternary : theme.accentSecondary

            if showsToday {
                let trailRad = 0.28
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
                context.fill(sweep, with: .color(sweepColor.opacity(theme.isDark ? 0.11 : 0.065)))

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

                        let prob = exp(-effLag / 0.13) * 0.70
                        let roll = Double((h >> 16) & 0x3FF) / 1023.0
                        if roll < prob {
                            let ang = nowAngle - effLag
                            let sz: CGFloat = ((h >> 26) & 1 == 0) ? 0.85 : 1.1
                            let px = cx + CGFloat(cos(ang)) * dr - sz * 0.5
                            let py = cy + CGFloat(sin(ang)) * dr - sz * 0.5
                            let dotRect = CGRect(x: px, y: py, width: sz, height: sz)
                            if effLag < 0.095 {
                                sweepDenseDots.addRect(dotRect)
                            } else {
                                sweepSoftDots.addRect(dotRect)
                            }
                        }
                    }
                }
                if !sweepSoftDots.isEmpty {
                    context.fill(sweepSoftDots, with: .color(sweepColor.opacity(theme.isDark ? 0.34 : 0.25)))
                }
                if !sweepDenseDots.isEmpty {
                    context.fill(sweepDenseDots, with: .color(sweepColor.opacity(theme.isDark ? 0.64 : 0.52)))
                }

                var ray = Path()
                ray.move(to: CGPoint(x: cx + CGFloat(cos(nowAngle)) * innerHubR, y: cy + CGFloat(sin(nowAngle)) * innerHubR))
                ray.addLine(to: CGPoint(x: cx + CGFloat(cos(nowAngle)) * bezelR, y: cy + CGFloat(sin(nowAngle)) * bezelR))
                if theme.isDark {
                    context.stroke(ray, with: .color(sweepColor.opacity(0.26)), lineWidth: 3.0)
                }
                context.stroke(ray, with: .color(sweepColor), lineWidth: 1.1)

                let tipX = cx + CGFloat(cos(nowAngle)) * bezelR
                let tipY = cy + CGFloat(sin(nowAngle)) * bezelR
                context.fill(
                    Path(CGRect(x: tipX - 1.75, y: tipY - 1.75, width: 3.5, height: 3.5)),
                    with: .color(sweepColor)
                )
            }

            // Center core hub ring + live HH:MM / 24H readout
            let hubRect = CGRect(x: cx - innerHubR, y: cy - innerHubR, width: innerHubR * 2, height: innerHubR * 2)
            let innerRingR = innerHubR - 2.6
            let innerRingRect = CGRect(x: cx - innerRingR, y: cy - innerRingR, width: innerRingR * 2, height: innerRingR * 2)

            context.fill(Path(ellipseIn: hubRect), with: .color(theme.canvas))
            context.stroke(
                Path(ellipseIn: hubRect),
                with: .color(showsToday ? sweepColor.opacity(0.82) : theme.hairlineStrong.opacity(0.85)),
                lineWidth: showsToday ? 0.9 : 0.75
            )
            context.stroke(
                Path(ellipseIn: innerRingRect),
                with: .color(theme.hairline.opacity(0.45)),
                lineWidth: 0.45
            )

            var hubRule = Path()
            hubRule.move(to: CGPoint(x: cx - 10, y: cy + 2.0))
            hubRule.addLine(to: CGPoint(x: cx + 10, y: cy + 2.0))
            context.stroke(hubRule, with: .color(theme.hairline.opacity(0.75)), lineWidth: 0.5)

            let clockLabel = Text(TimeLogic.formatClock(nowSec))
                .font(.system(size: 9.0, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.inkPrimary)
            let subLabel = Text("24H")
                .font(.system(size: 6.4, weight: .medium, design: .monospaced))
                .tracking(0.8)
                .foregroundColor(showsToday ? sweepColor.opacity(0.88) : theme.inkMuted)
            context.draw(clockLabel, at: CGPoint(x: cx, y: cy - 4.2))
            context.draw(subLabel, at: CGPoint(x: cx, y: cy + 7.2))
        }
        .allowsHitTesting(false)
    }

    private static func sweepHash(_ r: Int, _ a: Int) -> UInt32 {
        var h = UInt32(truncatingIfNeeded: r &* 374761393 &+ a &* 668265263)
        h = (h ^ (h >> 13)) &* 1274126177
        return h ^ (h >> 16)
    }
}

// MARK: - 2. Year Topographic Contour Field (Year 3A)

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
        let now = Date()
        let currentCalendarYear = AppDate.gregorian.component(.year, from: now)
        let cutoffDayKey: String? = (year == currentCalendarYear) ? AppDate.dayKey(now) : nil
        let summary = TimeLogic.yearSummary(days: days, year: year)
        let field = YearContourFieldCache.field(
            days: days,
            year: year,
            totalSeconds: summary.totalSeconds,
            cutoffDayKey: cutoffDayKey
        )
        let startMonday = TimeLogic.yearGridStartMonday(year: year)
        let monthCols = TimeLogic.monthLabelColumns(year: year)
        let monthlyHours = InstrumentMath.yearMonthlyHours(days: days, year: year)

        TimeKpiStrip(items: [
            (loc("timeYearTotal"), TimeLogic.formatDurationShort(summary.totalSeconds)),
            (loc("timeActiveDays"), String(format: loc("daysUnitFmt"), summary.activeDays)),
            (loc("timeStreak"), String(format: loc("daysUnitFmt"), summary.longestStreakDays)),
        ])

        YearContourInteractiveStage(
            year: year,
            cutoffDayKey: cutoffDayKey,
            days: days,
            totalSeconds: summary.totalSeconds,
            activeDays: summary.activeDays,
            field: field,
            startMonday: startMonday,
            monthCols: monthCols,
            monthlyHours: monthlyHours,
            loc: loc,
            theme: theme
        )

        HairlineRule(showCrosshairs: false)

        HStack(spacing: 6) {
            Text("* Contours of daily active density (Mon–Sun) & monthly totals")
                .font(.system(size: 8.3, weight: .regular, design: .serif))
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
/// NEVER re-run `TimeLogic.yearSummary`, `monthLabelColumns`, `yearMonthlyHours`, or `TimeKpiStrip`.
private struct YearContourInteractiveStage: View {
    let year: Int
    let cutoffDayKey: String?
    let days: [String: Int]
    let totalSeconds: Int
    let activeDays: Int
    let field: ContourFieldResult
    let startMonday: Date?
    let monthCols: [(month: Int, col: Int)]
    let monthlyHours: [Double]
    let loc: Localizer
    let theme: AGYTheme

    @Environment(\.telemetryPanelVisible) private var isPanelVisible
    @State private var hoveredDayKey: String? = nil
    @State private var hoverNormPos: Point2D? = nil

    private static let leftAxisWidth: CGFloat = 16
    private let plotHeight: CGFloat = 164
    private static let contourPadY: CGFloat = 12

    private struct YearArtworkKey: Hashable {
        let year: Int
        let cutoffDayKey: String?
        let totalSeconds: Int
        let activeDays: Int
        let maxHoursCenti: Int
        let dataDigest: Int
        let language: AppLanguage
        let noDataLabel: String
        let theme: AGYTheme.CacheKey
    }

    var body: some View {
        let yearPrefix = String(format: "%04d-", year)
        let artworkKey = YearArtworkKey(
            year: year,
            cutoffDayKey: cutoffDayKey,
            totalSeconds: totalSeconds,
            activeDays: activeDays,
            maxHoursCenti: Int((field.maxHours * 100.0).rounded()),
            dataDigest: YearContourFieldCache.dataDigest(days: days),
            language: loc.language,
            noDataLabel: loc("noData").uppercased(),
            theme: theme.cacheKey
        )

        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text("03.3")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.accent.opacity(0.95))
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

            // Double-deck Instrument Stack: Topographic Field + Shared Hairline + 12-Month Elevation Strip
            VStack(spacing: -0.75) {
                HStack(alignment: .top, spacing: 0) {
                    YearWeekdayYAxisRuler(
                        language: loc.language,
                        width: Self.leftAxisWidth,
                        height: plotHeight,
                        padY: Self.contourPadY,
                        theme: theme
                    )

                    GeometryReader { geo in
                        ZStack {
                            // Pre-rendered 2x Retina cached 12-band contour artwork + interior stippling + NOW hatch
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

                            // Lightweight 2-line hover reticle overlay strictly aligned inside the plot rect
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
                                    // Reject future days past NOW in the current year
                                    if let cutoffNorm = field.cutoffNormX, cell.normX > cutoffNorm {
                                        if hoverNormPos != nil { hoverNormPos = nil }
                                        if hoveredDayKey != nil { hoveredDayKey = nil }
                                        return
                                    }
                                    let resolvedKey = startMonday.flatMap {
                                        TimeLogic.dayKey(col: cell.col, row: cell.row, startMonday: $0)
                                    }
                                    if let cutoff = cutoffDayKey, let key = resolvedKey, key > cutoff {
                                        if hoverNormPos != nil { hoverNormPos = nil }
                                        if hoveredDayKey != nil { hoveredDayKey = nil }
                                        return
                                    }
                                    let nextPos = Point2D(x: cell.normX, y: cell.normY)
                                    if hoverNormPos != nextPos {
                                        hoverNormPos = nextPos
                                    }
                                    let nextKey: String? = (resolvedKey?.hasPrefix(yearPrefix) == true) ? resolvedKey : nil
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
                }

                YearMonthlyElevationStrip(
                    monthCols: monthCols,
                    monthlyHours: monthlyHours,
                    cutoffNormX: field.cutoffNormX,
                    leftAxisWidth: Self.leftAxisWidth,
                    theme: theme
                )
            }

            HStack {
                Text("ISO // 12-BAND + MO Σ")
                    .font(.system(size: 7.2, weight: .regular, design: .monospaced))
                    .tracking(0.5)
                    .foregroundColor(theme.inkMuted)
                Spacer()
                contourLegend
            }
            .frame(height: 11)
            .padding(.top, 1)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .onChange(of: year) { _ in
            hoveredDayKey = nil
            hoverNormPos = nil
        }
        .onChange(of: isPanelVisible) { visible in
            if !visible {
                hoveredDayKey = nil
                hoverNormPos = nil
            }
        }
    }

    private var monthAxisRow: some View {
        let names = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                ForEach(monthCols, id: \.month) { entry in
                    Text(names[entry.month - 1])
                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                        .tracking(0.3)
                        .foregroundColor(theme.isMultiColorSpectrum ? theme.inkSecondary : theme.inkSecondary.opacity(0.88))
                        .offset(x: geo.size.width * CGFloat(entry.col) / 53.0)
                }
            }
        }
        .frame(height: 10)
        .padding(.leading, Self.leftAxisWidth)
    }

    private var contourLegend: some View {
        HStack(spacing: 4) {
            Text(loc("timeLess").uppercased())
                .font(.system(size: 7, weight: .regular, design: .monospaced))
                .foregroundColor(theme.inkMuted)
            HStack(spacing: 2.5) {
                if theme.isMultiColorSpectrum {
                    Rectangle().fill(theme.accentQuaternary).frame(width: 8, height: 1.0)
                    Rectangle().fill(theme.accentTertiary).frame(width: 8, height: 1.1)
                    Rectangle().fill(theme.accentSecondary).frame(width: 8, height: 1.25)
                    Rectangle().fill(theme.accent).frame(width: 8, height: 1.5)
                } else {
                    Rectangle().fill(theme.accentSecondary.opacity(0.38)).frame(width: 8, height: 0.75)
                    Rectangle().fill(theme.accentSecondary.opacity(0.78)).frame(width: 8, height: 0.95)
                    Rectangle().fill(theme.accent.opacity(0.68)).frame(width: 8, height: 1.15)
                    Rectangle().fill(theme.accent).frame(width: 8, height: 1.5)
                }
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

/// 16pt Left Weekday Y-Axis Ruler aligned 1:1 with padded contour rows 0, 2, 4, 6
/// plus matching FRI/SAT weekend split tick (Equatable, 0ms hover cost).
private struct YearWeekdayYAxisRuler: View, Equatable {
    let language: AppLanguage
    let width: CGFloat
    let height: CGFloat
    let padY: CGFloat
    let theme: AGYTheme

    var body: some View {
        let innerH = max(20, height - padY * 2)
        let ticks = yearYAxisWeekdayTicks(for: language)

        Canvas { context, size in
            var tickMarks = Path()
            for r in 0..<7 {
                let ry = padY + ((CGFloat(r) + 0.5) / 7.0) * innerH
                let isMajor = (r == 0 || r == 2 || r == 4 || r == 6)
                tickMarks.move(to: CGPoint(x: size.width - (isMajor ? 3.0 : 1.6), y: ry))
                tickMarks.addLine(to: CGPoint(x: size.width, y: ry))
            }
            context.stroke(tickMarks, with: .color(theme.hairlineStrong.opacity(0.72)), lineWidth: 0.65)

            // Matching FRI/SAT weekend divider split tick
            let wkndY = padY + (5.0 / 7.0) * innerH
            var split = Path()
            split.move(to: CGPoint(x: size.width - 4.2, y: wkndY))
            split.addLine(to: CGPoint(x: size.width, y: wkndY))
            context.stroke(split, with: .color(theme.accentSecondary.opacity(0.60)), lineWidth: 0.7)

            for tick in ticks {
                let ry = padY + ((CGFloat(tick.row) + 0.5) / 7.0) * innerH
                let label = Text(tick.label)
                    .font(.system(size: 6.6, weight: .medium, design: .monospaced))
                    .foregroundColor(tick.isWeekend ? theme.inkMuted : theme.inkSecondary)
                context.draw(label, at: CGPoint(x: size.width - 9.2, y: ry))
            }
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
    }
}

/// Integrated 12-Month Micro-Elevation Strip beneath the contour field — aligned horizontally
/// to JAN..DEC month spans, sharing the 16pt left rail (`MO / HR`) and unified NOW datum (Equatable).
private struct YearMonthlyElevationStrip: View, Equatable {
    let monthCols: [(month: Int, col: Int)]
    let monthlyHours: [Double]
    let cutoffNormX: Double?
    let leftAxisWidth: CGFloat
    let theme: AGYTheme

    private let stripHeight: CGFloat = 32

    static func == (lhs: YearMonthlyElevationStrip, rhs: YearMonthlyElevationStrip) -> Bool {
        lhs.monthCols.count == rhs.monthCols.count
            && zip(lhs.monthCols, rhs.monthCols).allSatisfy { $0.month == $1.month && $0.col == $1.col }
            && lhs.monthlyHours == rhs.monthlyHours
            && lhs.cutoffNormX == rhs.cutoffNormX
            && lhs.leftAxisWidth == rhs.leftAxisWidth
            && lhs.theme == rhs.theme
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left rail (`MO / HR`) centered on the exact same vertical rail as M/W/F/S above
            Canvas { context, size in
                let cx = size.width - 9.2
                let baselineY = size.height - 2.5
                var tick = Path()
                tick.move(to: CGPoint(x: size.width - 3.0, y: baselineY))
                tick.addLine(to: CGPoint(x: size.width, y: baselineY))
                context.stroke(tick, with: .color(theme.hairlineStrong.opacity(0.72)), lineWidth: 0.65)

                let mo = Text("MO")
                    .font(.system(size: 6.0, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.inkSecondary.opacity(0.88))
                let hr = Text("HR")
                    .font(.system(size: 5.4, weight: .regular, design: .monospaced))
                    .foregroundColor(theme.inkMuted)
                context.draw(mo, at: CGPoint(x: cx, y: size.height * 0.5 - 3.6))
                context.draw(hr, at: CGPoint(x: cx, y: size.height * 0.5 + 3.8))
            }
            .frame(width: leftAxisWidth, height: stripHeight)

            Canvas { context, size in
                let w = size.width
                let h = size.height
                let baselineY = h - 2.5
                let topLabelZone: CGFloat = 12.0
                let maxBarH = max(6.0, baselineY - topLabelZone)
                let cutoffX = cutoffNormX.map { CGFloat($0) * w }

                // 1. Uncharted future hatch continuation
                if let cx = cutoffX, cx < w {
                    let futureRect = CGRect(x: cx, y: 0, width: w - cx, height: h)
                    context.fill(Path(futureRect), with: .color(theme.hairline.opacity(theme.isDark ? 0.16 : 0.12)))
                    var hatch = Path()
                    addArchivalDiagonalHatch(to: &hatch, in: futureRect, step: 5.2)
                    context.stroke(hatch, with: .color(theme.hairline.opacity(theme.isDark ? 0.44 : 0.40)), lineWidth: 0.55)
                }

                // 2. Vertical month meridian continuations
                var meridians = Path()
                for entry in monthCols where entry.col > 0 {
                    let mx = w * CGFloat(entry.col) / 53.0
                    meridians.move(to: CGPoint(x: mx, y: 0))
                    meridians.addLine(to: CGPoint(x: mx, y: h))
                }
                let meridianBase = theme.isMultiColorSpectrum ? theme.inkMuted : theme.inkSecondary
                context.stroke(
                    meridians,
                    with: .color(meridianBase.opacity(theme.isDark ? 0.18 : 0.14)),
                    lineWidth: 0.6
                )

                // 3. Baseline across charted months
                let chartedW = cutoffX ?? w
                var basePath = Path()
                basePath.move(to: CGPoint(x: 0, y: baselineY))
                basePath.addLine(to: CGPoint(x: chartedW, y: baselineY))
                context.stroke(basePath, with: .color(theme.hairlineStrong.opacity(0.55)), lineWidth: 0.6)

                // 4. Monthly elevation bars aligned strictly to JAN..DEC column spans
                var peakIdx = -1
                var maxHrs = 0.0
                for (i, hrs) in monthlyHours.enumerated() where hrs > maxHrs {
                    maxHrs = hrs
                    peakIdx = i
                }

                if maxHrs > 0.05 {
                    let secColor = theme.isMultiColorSpectrum ? theme.accentQuaternary : theme.accentSecondary
                    var lastLabelMaxX: CGFloat = -100

                    for idx in 0..<monthCols.count {
                        let entry = monthCols[idx]
                        let monthIdx = entry.month - 1
                        guard monthlyHours.indices.contains(monthIdx) else { continue }
                        let hrs = monthlyHours[monthIdx]
                        guard hrs > 0.05 else { continue }

                        let startX = w * CGFloat(entry.col) / 53.0
                        let nextCol = (idx + 1 < monthCols.count) ? monthCols[idx + 1].col : 53
                        var endX = w * CGFloat(nextCol) / 53.0
                        if let cx = cutoffX {
                            if startX >= cx - 2.0 { continue }
                            endX = min(endX, cx - 1.5)
                        }

                        let rawSpan = endX - startX
                        guard rawSpan >= 2.5 else { continue }
                        let padX: CGFloat = min(2.4, max(0.6, rawSpan * 0.12))
                        let bx = startX + padX
                        let bw = max(2.0, rawSpan - padX * 2.0)
                        let frac = min(1.0, hrs / maxHrs)
                        let bh = max(2.2, CGFloat(frac) * maxBarH)
                        let by = baselineY - bh
                        let barRect = CGRect(x: bx, y: by, width: bw, height: bh)
                        let isPeak = (monthIdx == peakIdx)

                        if isPeak {
                            context.fill(Path(barRect), with: .color(theme.accent.opacity(theme.isDark ? 0.24 : 0.16)))
                            var hatch = Path()
                            addArchivalDiagonalHatch(to: &hatch, in: barRect, step: 3.4)
                            context.stroke(hatch, with: .color(theme.accent.opacity(theme.isDark ? 0.48 : 0.42)), lineWidth: 0.55)
                            context.stroke(Path(barRect), with: .color(theme.accent.opacity(0.85)), lineWidth: 0.7)
                            context.fill(Path(CGRect(x: bx, y: by, width: bw, height: 1.5)), with: .color(theme.accent))
                        } else {
                            context.fill(Path(barRect), with: .color(secColor.opacity(theme.isDark ? 0.14 : 0.10)))
                            var hatch = Path()
                            addArchivalDiagonalHatch(to: &hatch, in: barRect, step: 3.8)
                            context.stroke(hatch, with: .color(secColor.opacity(theme.isDark ? 0.36 : 0.30)), lineWidth: 0.5)
                            context.stroke(Path(barRect), with: .color(secColor.opacity(0.55)), lineWidth: 0.55)
                            context.fill(Path(CGRect(x: bx, y: by, width: bw, height: 1.15)), with: .color(secColor.opacity(0.92)))
                        }

                        // Compact integer hour readout above non-zero bars (clipped cleanly inside chartedW & frame)
                        let hrsInt = max(1, Int(hrs.rounded()))
                        let textStr = isPeak ? "\(hrsInt)H" : "\(hrsInt)"
                        let estHalfW = CGFloat(textStr.count) * 2.2 + 1.5
                        let rightLimit = chartedW - 2.0
                        let clampedMidX = min(max(barRect.midX, estHalfW + 1.5), rightLimit - estHalfW)
                        if clampedMidX - estHalfW >= lastLabelMaxX + 2.0, clampedMidX + estHalfW <= rightLimit {
                            let labelColor = isPeak ? theme.accent : theme.inkSecondary.opacity(theme.isDark ? 0.88 : 0.82)
                            let label = Text(textStr)
                                .font(.system(size: isPeak ? 6.5 : 6.0, weight: isPeak ? .bold : .medium, design: .monospaced))
                                .foregroundColor(labelColor)
                            let labelY = max(5.6, by - 5.0)
                            context.draw(label, at: CGPoint(x: clampedMidX, y: labelY))
                            lastLabelMaxX = clampedMidX + estHalfW
                        }
                    }
                }

                // 5. Extend vertical dashed NOW datum seamlessly through the monthly strip
                if let cx = cutoffX {
                    _ = drawYearNowDatum(
                        in: &context,
                        cutoffX: cx,
                        canvasWidth: w,
                        height: h,
                        showTag: false,
                        drawTopTick: false,
                        drawBottomTick: true,
                        theme: theme
                    )
                }
            }
            .frame(height: stripHeight)
            .overlay(Rectangle().stroke(theme.hairline.opacity(0.85), lineWidth: 0.75))
        }
        .allowsHitTesting(false)
    }
}

/// Static 12-band Marching Squares contour artwork + organic interior basin stippling
/// + honest NOW cutoff & archival future hatch + Emil Widlund circular `(H)` peak marks (Equatable).
private struct StaticYearContourCanvas: View, Equatable {
    let field: ContourFieldResult
    let monthColumns: [Int]
    let noDataLabel: String
    let padY: CGFloat
    let theme: AGYTheme

    var body: some View {
        Canvas { context, size in
            let innerH = max(20, size.height - padY * 2)
            let cutoffX: CGFloat = field.cutoffNormX.map { CGFloat($0) * size.width } ?? size.width
            let chartedRect = CGRect(x: 0, y: 0, width: cutoffX, height: size.height)

            func pt(_ p: Point2D) -> CGPoint {
                CGPoint(x: CGFloat(p.x) * size.width, y: padY + CGFloat(p.y) * innerH)
            }

            // 1. Subtle monthly vertical cartographic meridian lines + edge ticks — batched Paths
            var meridians = Path()
            var monthTicks = Path()
            for col in monthColumns where col > 0 {
                let mx = size.width * CGFloat(col) / 53.0
                meridians.move(to: CGPoint(x: mx, y: 0))
                meridians.addLine(to: CGPoint(x: mx, y: size.height))
                monthTicks.move(to: CGPoint(x: mx, y: 0))
                monthTicks.addLine(to: CGPoint(x: mx, y: 3.5))
                monthTicks.move(to: CGPoint(x: mx, y: size.height - 3.5))
                monthTicks.addLine(to: CGPoint(x: mx, y: size.height))
            }
            let meridianBase = theme.isMultiColorSpectrum ? theme.inkMuted : theme.inkSecondary
            context.stroke(
                meridians,
                with: .color(meridianBase.opacity(theme.isDark ? 0.18 : 0.14)),
                lineWidth: 0.6
            )
            context.stroke(
                monthTicks,
                with: .color(meridianBase.opacity(theme.isDark ? 0.48 : 0.40)),
                lineWidth: 0.7
            )

            // 2. Subtle horizontal FRI / SAT weekend separator hairline across charted region
            let weekendY = padY + (5.0 / 7.0) * innerH
            var wkndLine = Path()
            wkndLine.move(to: CGPoint(x: 0, y: weekendY))
            wkndLine.addLine(to: CGPoint(x: cutoffX, y: weekendY))
            context.stroke(
                wkndLine,
                with: .color(theme.hairlineStrong.opacity(theme.isDark ? 0.48 : 0.42)),
                style: StrokeStyle(lineWidth: 0.6, dash: [2.0, 2.5])
            )

            // 3. Clipped Charted Topographic Field (Stippling + 12-Band Marching Squares Isolines)
            if !field.levels.isEmpty {
                var clippedCtx = context
                clippedCtx.clip(to: Path(chartedRect))

                let totalLevels = field.levels.count
                let midIdx = min(totalLevels - 1, max(0, (totalLevels * 4) / 12))
                let summitIdx = min(totalLevels - 1, max(midIdx, (totalLevels * 7) / 12))
                let coreIdx = min(totalLevels - 1, max(summitIdx, (totalLevels * 9) / 12))
                let midSegments = field.levels[midIdx].segments
                let summitSegments = field.levels[summitIdx].segments
                let coreSegments = (coreIdx > summitIdx) ? field.levels[coreIdx].segments : []

                // 3a. Organic interior basin stippling (clipped cleanly to x <= cutoffX)
                if !midSegments.isEmpty || !summitSegments.isEmpty {
                    let outerSegments = !midSegments.isEmpty ? midSegments : summitSegments
                    var midStipple = Path()
                    var summitStipple = Path()
                    var coreStipple = Path()
                    let stepX: CGFloat = 2.45
                    let stepY: CGFloat = 2.45
                    let rowCount = Int(innerH / stepY)

                    var outerXs: [CGFloat] = []
                    var summitXs: [CGFloat] = []
                    var coreXs: [CGFloat] = []
                    outerXs.reserveCapacity(16)
                    summitXs.reserveCapacity(14)
                    coreXs.reserveCapacity(12)

                    for iy in 0...max(0, rowCount) {
                        let py = padY + CGFloat(iy) * stepY
                        let ny = Double((py - padY) / innerH)
                        guard ny > 0.0, ny < 1.0 else { continue }

                        Self.scanlineIntersections(
                            segments: outerSegments,
                            ny: ny,
                            width: size.width,
                            out: &outerXs
                        )
                        guard outerXs.count >= 2 else { continue }

                        if !summitSegments.isEmpty {
                            Self.scanlineIntersections(
                                segments: summitSegments,
                                ny: ny,
                                width: size.width,
                                out: &summitXs
                            )
                        } else {
                            summitXs.removeAll(keepingCapacity: true)
                        }

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
                        while spanIdx + 1 < outerXs.count {
                            let x0 = outerXs[spanIdx]
                            let x1 = min(cutoffX, outerXs[spanIdx + 1])
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
                                let inSummit = inCore || Self.containsX(gx, inSortedSpans: summitXs)
                                let prob = inCore ? 0.72 : (inSummit ? 0.42 : 0.24)
                                let roll = Double((h >> 16) & 0x3FF) / 1023.0
                                if roll < prob {
                                    let sz: CGFloat = ((h >> 26) & 1 == 0) ? 0.95 : 1.25
                                    let rect = CGRect(x: gx, y: gy, width: sz, height: sz)
                                    if inCore {
                                        coreStipple.addRect(rect)
                                    } else if inSummit {
                                        summitStipple.addRect(rect)
                                    } else {
                                        midStipple.addRect(rect)
                                    }
                                }
                            }
                        }
                    }

                    if !midStipple.isEmpty {
                        let c = theme.isMultiColorSpectrum ? theme.accentQuaternary : theme.accentSecondary
                        clippedCtx.fill(midStipple, with: .color(c.opacity(theme.isDark ? 0.40 : 0.32)))
                    }
                    if !summitStipple.isEmpty {
                        let c = theme.isMultiColorSpectrum ? theme.accentTertiary : theme.accent
                        clippedCtx.fill(summitStipple, with: .color(c.opacity(theme.isDark ? 0.48 : 0.40)))
                    }
                    if !coreStipple.isEmpty {
                        clippedCtx.fill(coreStipple, with: .color(theme.accent.opacity(theme.isDark ? 0.58 : 0.48)))
                    }
                }

                // 3b. Render 12 silky Marching Squares isobar contours (clipped at cutoffX — zero fake cliff!)
                for lvl in field.levels {
                    guard !lvl.segments.isEmpty else { continue }
                    var path = Path()
                    for seg in lvl.segments {
                        path.move(to: pt(seg.a))
                        path.addLine(to: pt(seg.b))
                    }

                    let normLevel = totalLevels > 1 ? Double(lvl.level) / Double(totalLevels - 1) : 1.0
                    let isTopPeak = (lvl.level == totalLevels - 1)
                    let isSecondPeak = (lvl.level == totalLevels - 2) && totalLevels >= 2

                    if isTopPeak {
                        if theme.isDark {
                            clippedCtx.stroke(path, with: .color(theme.accent.opacity(0.18)), lineWidth: 3.2)
                        }
                        clippedCtx.stroke(path, with: .color(theme.accent), lineWidth: 1.15)
                    } else if isSecondPeak {
                        if theme.isDark {
                            clippedCtx.stroke(path, with: .color(theme.accent.opacity(0.11)), lineWidth: 2.3)
                        }
                        clippedCtx.stroke(path, with: .color(theme.accent.opacity(0.84)), lineWidth: 0.95)
                    } else if theme.isMultiColorSpectrum {
                        let baseColor = theme.elevationColor(normalized: normLevel)
                        let alpha = (theme.isDark ? 0.42 : 0.38) + normLevel * 0.42
                        let lw: CGFloat = 0.58 + CGFloat(normLevel) * 0.36
                        clippedCtx.stroke(path, with: .color(baseColor.opacity(alpha)), lineWidth: lw)
                    } else if normLevel < 0.55 {
                        let localT = normLevel / 0.55
                        let color = theme.accentSecondary.opacity(0.24 + localT * 0.54)
                        let lw: CGFloat = 0.55 + CGFloat(localT) * 0.25
                        clippedCtx.stroke(path, with: .color(color), lineWidth: lw)
                    } else {
                        let localT = (normLevel - 0.55) / 0.45
                        let color = theme.accent.opacity(0.46 + localT * 0.34)
                        let lw: CGFloat = 0.78 + CGFloat(localT) * 0.14
                        clippedCtx.stroke(path, with: .color(color), lineWidth: lw)
                    }
                }
            }

            // 4. Uncharted Future Region (right of NOW): delicate 45° archival hatch + vertical dashed NOW datum + auto-flipping NOW tag
            var nowTagRect: CGRect? = nil
            if field.cutoffNormX != nil {
                if cutoffX < size.width {
                    let futureRect = CGRect(x: cutoffX, y: 0, width: size.width - cutoffX, height: size.height)
                    context.fill(Path(futureRect), with: .color(theme.hairline.opacity(theme.isDark ? 0.16 : 0.12)))
                    var hatch = Path()
                    addArchivalDiagonalHatch(to: &hatch, in: futureRect, step: 5.2)
                    context.stroke(hatch, with: .color(theme.hairline.opacity(theme.isDark ? 0.44 : 0.40)), lineWidth: 0.55)
                }

                nowTagRect = drawYearNowDatum(
                    in: &context,
                    cutoffX: cutoffX,
                    canvasWidth: size.width,
                    height: size.height,
                    showTag: true,
                    drawTopTick: true,
                    drawBottomTick: false,
                    theme: theme
                )
            }

            if field.levels.isEmpty {
                let emptyLabel = Text(noDataLabel)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundColor(theme.inkMuted)
                context.draw(emptyLabel, at: CGPoint(x: cutoffX * 0.5, y: size.height * 0.5))
                return
            }

            // 5. Emil Widlund meteorological circular `(H)` marks + collision-avoided value readouts (constrained <= cutoffX)
            let circleD: CGFloat = 9.0
            let circleR: CGFloat = circleD * 0.5
            let valW: CGFloat = 24.0
            let valH: CGFloat = 9.5

            var peakCenters: [CGPoint] = []
            var placedRects: [CGRect] = []
            if let nr = nowTagRect {
                placedRects.append(nr.insetBy(dx: -2.0, dy: -2.0))
            }
            for peak in field.peaks {
                let rawP = pt(Point2D(x: peak.x, y: peak.y))
                let clampedP = CGPoint(
                    x: min(max(rawP.x, circleR + 2.5), max(circleR + 2.5, cutoffX - circleR - 3.0)),
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

                let circleRect = CGRect(x: p.x - circleR, y: p.y - circleR, width: circleD, height: circleD)
                let circlePath = Path(ellipseIn: circleRect)
                context.fill(circlePath, with: .color(theme.canvas.opacity(0.92)))
                context.stroke(
                    circlePath,
                    with: .color(isPrimary ? theme.accent : theme.accent.opacity(0.84)),
                    lineWidth: 0.75
                )

                let hGlyph = Text("H")
                    .font(.system(size: 6, weight: .semibold, design: .monospaced))
                    .foregroundColor(isPrimary ? theme.accent : theme.accent.opacity(0.88))
                context.draw(hGlyph, at: p)

                let dxSide: CGFloat = circleR + valW * 0.5 + 3.5
                let preferLeft = (p.x + dxSide + valW * 0.5 + 2.5) > cutoffX
                let candidates: [CGPoint] = preferLeft
                    ? [
                        CGPoint(x: p.x - dxSide, y: p.y),
                        CGPoint(x: p.x - dxSide * 0.85, y: p.y - 8.5),
                        CGPoint(x: p.x - dxSide * 0.85, y: p.y + 8.5),
                        CGPoint(x: p.x, y: p.y - 10.5),
                        CGPoint(x: p.x, y: p.y + 10.5),
                    ]
                    : [
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
                let maxCX = max(minCX, cutoffX - valW * 0.5 - 3.0)
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

            context.stroke(lines, with: .color(theme.accent.opacity(0.62)), lineWidth: 0.75)
            context.fill(
                Path(CGRect(x: hx - 1.75, y: hy - 1.75, width: 3.5, height: 3.5)),
                with: .color(theme.accent)
            )
        }
        .allowsHitTesting(false)
    }
}


// MARK: - 3. Month Elevation Sequence + 24H Diurnal Profile (Month M3)

private struct MonthElevationSlot: Equatable {
    let dayNum: Int
    let key: String
    let seconds: Int
    let hours: Double
    let sessionCount: Int
    let isWeekend: Bool
    let isMonday: Bool
    let isToday: Bool
    let shortMondayLabel: String?
    let weekdayIndex: Int // 0 = Mon ... 6 = Sun
}

private struct MonthElevationScale: Equatable {
    let ceiling: Double
    let topTick: Double
    let midTick: Double
    let topLabel: String
    let midLabel: String

    static func make(peakHours: Double) -> MonthElevationScale {
        guard peakHours > 0 else {
            return MonthElevationScale(ceiling: 8.8, topTick: 8.0, midTick: 4.0, topLabel: "8H", midLabel: "4H")
        }
        switch peakHours {
        case ...1.0:
            return MonthElevationScale(ceiling: 1.15, topTick: 1.0, midTick: 0.5, topLabel: "1H", midLabel: "0.5H")
        case ...2.0:
            return MonthElevationScale(ceiling: 2.25, topTick: 2.0, midTick: 1.0, topLabel: "2H", midLabel: "1H")
        case ...4.0:
            return MonthElevationScale(ceiling: 4.45, topTick: 4.0, midTick: 2.0, topLabel: "4H", midLabel: "2H")
        case ...6.0:
            return MonthElevationScale(ceiling: 6.65, topTick: 6.0, midTick: 3.0, topLabel: "6H", midLabel: "3H")
        case ...9.0:
            return MonthElevationScale(ceiling: 10.0, topTick: 9.0, midTick: 5.0, topLabel: "9H", midLabel: "5H")
        case ...12.0:
            return MonthElevationScale(ceiling: 13.2, topTick: 12.0, midTick: 6.0, topLabel: "12H", midLabel: "6H")
        case ...16.0:
            return MonthElevationScale(ceiling: 17.6, topTick: 16.0, midTick: 8.0, topLabel: "16H", midLabel: "8H")
        case ...20.0:
            return MonthElevationScale(ceiling: 22.0, topTick: 20.0, midTick: 10.0, topLabel: "20H", midLabel: "10H")
        default:
            return MonthElevationScale(ceiling: 26.0, topTick: 24.0, midTick: 12.0, topLabel: "24H", midLabel: "12H")
        }
    }
}

private enum MonthElevationLayout {
    static let yAxisWidth: CGFloat = 22.0
    static let topBandHeight: CGFloat = 13.0
    static let bottomAxisHeight: CGFloat = 17.0
    static let columnInset: CGFloat = 1.45

    static func plotRect(for size: CGSize) -> CGRect {
        CGRect(
            x: yAxisWidth,
            y: topBandHeight,
            width: max(40.0, size.width - yAxisWidth),
            height: max(40.0, size.height - topBandHeight - bottomAxisHeight)
        )
    }

    static func slotWidth(plotRect: CGRect, count: Int) -> CGFloat {
        plotRect.width / CGFloat(max(1, count))
    }

    static func yForHours(_ hours: Double, ceiling: Double, plotRect: CGRect) -> CGFloat {
        guard ceiling > 0 else { return plotRect.maxY }
        let frac = min(1.0, max(0.0, hours / ceiling))
        return plotRect.maxY - CGFloat(frac) * plotRect.height
    }

    static func columnRect(
        index: Int,
        hours: Double,
        ceiling: Double,
        plotRect: CGRect,
        slotW: CGFloat
    ) -> CGRect {
        let x0 = plotRect.minX + CGFloat(index) * slotW + columnInset
        let cw = max(2.0, slotW - columnInset * 2.0)
        let topY = yForHours(hours, ceiling: ceiling, plotRect: plotRect)
        let colH = max(2.0, plotRect.maxY - topY)
        return CGRect(x: x0, y: topY, width: cw, height: colH)
    }
}

private enum MonthDiurnalLayout {
    static let rulerHeight: CGFloat = 14.0

    static func plotRect(for size: CGSize) -> CGRect {
        CGRect(
            x: 0.0,
            y: 2.0,
            width: max(40.0, size.width),
            height: max(20.0, size.height - rulerHeight - 2.0)
        )
    }
}

private func monthElevationColumnTone(for theme: AGYTheme) -> Color {
    // On Google 4-color theme, use calm Google Green wash for the 30-day body columns so the
    // chart stays archival and restrained, reserving Google Blue for Peak/hover and Red/Yellow for datum ticks.
    theme.isMultiColorSpectrum ? theme.accentQuaternary : theme.accentSecondary
}

private func monthElevationCompactHours(_ seconds: Int) -> String {
    guard seconds > 0 else { return "0M" }
    let hrs = Double(seconds) / 3600.0
    if hrs >= 1.0 {
        return String(format: "%.1fH", hrs)
    }
    return "\(max(1, seconds / 60))M"
}

private func monthElevationPeakSubtitle(
    slot: MonthElevationSlot,
    month: Int,
    language: AppLanguage,
    weekdaySymbols: [String]
) -> String {
    if language == .en {
        let enWeekdays = ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]
        let enMonths = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
        let wd = enWeekdays.indices.contains(slot.weekdayIndex) ? enWeekdays[slot.weekdayIndex] : "DAY"
        let mon = (1...12).contains(month) ? enMonths[month - 1] : String(format: "%02d", month)
        return String(format: "%@  %@ %02d", wd, mon, slot.dayNum)
    }
    let wd = weekdaySymbols.indices.contains(slot.weekdayIndex) ? weekdaySymbols[slot.weekdayIndex].uppercased() : ""
    return String(format: "%@ %02d/%02d", wd, month, slot.dayNum)
}

private func formatBinWindowClock(startBin: Int, endBin: Int, binCount: Int) -> String {
    let safeBins = max(1, binCount)
    let binSeconds = 86400 / safeBins
    let startSec = max(0, min(86400, startBin * binSeconds))
    let endSec = max(0, min(86400, endBin * binSeconds))
    return "\(TimeLogic.formatClock(startSec))–\(TimeLogic.formatClock(endSec))"
}

private func monthDiurnalHash(_ a: Int, _ b: Int) -> UInt32 {
    var x = UInt32(truncatingIfNeeded: a &* 374761393 &+ b &* 668265263)
    x = (x ^ (x >> 13)) &* 1274126177
    return x ^ (x >> 16)
}

struct MonthElevationInstrumentChart: View {
    let timeData: TimeData
    let year: Int
    let month: Int

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @Environment(\.telemetryPanelVisible) private var isPanelVisible

    private var monthPrefix: String { String(format: "%04d-%02d-", year, month) }
    private var todayKey: String { AppDate.dayKey(Date()) }
    private var daysInMonth: Int { AppDate.daysInMonth(year: year, month: month) ?? 30 }

    var body: some View {
        let cal = AppDate.gregorian
        let prefix = monthPrefix
        let currentTodayKey = todayKey
        let dayCount = daysInMonth
        let monthKeys = timeData.days.keys.filter { $0.hasPrefix(prefix) }
        let monthTotal = TimeLogic.totalSeconds(in: timeData.days, dayKeys: monthKeys)
        let longestSec = TimeLogic.longestIntervalSeconds(in: timeData.days, dayKeys: monthKeys)

        var slots: [MonthElevationSlot] = []
        slots.reserveCapacity(dayCount)
        var activeDays = 0
        var peakIndex: Int? = nil
        var peakSeconds = 0

        for d in 1...dayCount {
            let key = String(format: "%04d-%02d-%02d", year, month, d)
            let usage = timeData.days[key]
            let secs = usage?.totalSeconds ?? 0
            let sessCount = usage?.intervals.count ?? 0
            if secs > 0 {
                activeDays += 1
                if secs > peakSeconds {
                    peakSeconds = secs
                    peakIndex = d - 1
                }
            }
            let date = cal.date(from: DateComponents(year: year, month: month, day: d))
            let wd = date.map { cal.component(.weekday, from: $0) } ?? 2 // 1=Sun, 2=Mon..7=Sat
            let mondayZeroWd = (wd + 5) % 7
            let isWeekend = (wd == 1 || wd == 7)
            let isMonday = (wd == 2)
            let mondayLabel: String? = isMonday ? String(format: "%02d/%02d", month, d) : nil

            slots.append(MonthElevationSlot(
                dayNum: d,
                key: key,
                seconds: secs,
                hours: Double(secs) / 3600.0,
                sessionCount: sessCount,
                isWeekend: isWeekend,
                isMonday: isMonday,
                isToday: key == currentTodayKey,
                shortMondayLabel: mondayLabel,
                weekdayIndex: mondayZeroWd
            ))
        }

        let avgSeconds = activeDays > 0 ? monthTotal / activeDays : 0
        let cached = MonthDiurnalProfileCache.profile(days: timeData.days, year: year, month: month)

        return VStack(alignment: .leading, spacing: 0) {
            TimeKpiStrip(items: [
                (loc("timeMonthTotal"), TimeLogic.formatDurationShort(monthTotal)),
                (loc("timeDailyAvg"), TimeLogic.formatDurationShort(avgSeconds)),
                (loc("timeLongest"), TimeLogic.formatDurationShort(longestSec)),
            ])

            MonthElevationInteractiveDeck(
                year: year,
                month: month,
                monthPrefix: prefix,
                todayKey: currentTodayKey,
                days: timeData.days,
                slots: slots,
                monthTotal: monthTotal,
                avgSeconds: avgSeconds,
                peakIndex: peakIndex,
                profile: cached.profile,
                dataDigest: cached.digest,
                language: loc.language,
                weekdaySymbols: mondayFirstWeekdaySymbols(loc),
                noDataLabel: loc("noData").uppercased(),
                isPanelVisible: isPanelVisible,
                theme: theme
            )

            HairlineRule(showCrosshairs: false)

            HStack(spacing: 6) {
                Text("* Daily active elevation (01–\(dayCount)) & aggregated 24h diurnal rhythm")
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

/// Interactive child view isolating hover state below `TimeKpiStrip` so 120Hz mouse moves
/// never re-evaluate KPIs, day slots, or diurnal profile cache lookups.
private struct MonthElevationInteractiveDeck: View {
    let year: Int
    let month: Int
    let monthPrefix: String
    let todayKey: String
    let days: [String: DayTimeUsage]
    let slots: [MonthElevationSlot]
    let monthTotal: Int
    let avgSeconds: Int
    let peakIndex: Int?
    let profile: MonthDiurnalProfile
    let dataDigest: Int
    let language: AppLanguage
    let weekdaySymbols: [String]
    let noDataLabel: String
    let isPanelVisible: Bool
    let theme: AGYTheme

    @State private var hoveredDayIndex: Int? = nil
    @State private var hoveredBinIndex: Int? = nil

    private let upperHeight: CGFloat = 148
    private let lowerHeight: CGFloat = 54

    private struct UpperArtworkKey: Hashable {
        let year: Int
        let month: Int
        let todayKey: String
        let monthTotal: Int
        let avgSeconds: Int
        let peakIndex: Int?
        let dataDigest: Int
        let language: AppLanguage
        let noDataLabel: String
        let theme: AGYTheme.CacheKey
    }

    private struct LowerArtworkKey: Hashable {
        let year: Int
        let month: Int
        let monthTotal: Int
        let maxBinCenti: Int
        let dataDigest: Int
        let noDataLabel: String
        let theme: AGYTheme.CacheKey
    }

    var body: some View {
        let peakSlot = peakIndex.flatMap { slots.indices.contains($0) ? slots[$0] : nil }
        let peakHours = peakSlot?.hours ?? 0.0
        let avgHours = Double(avgSeconds) / 3600.0
        let scale = MonthElevationScale.make(peakHours: peakHours)
        let monthStr = String(format: "%04d.%02d", year, month)
        let columnTone = monthElevationColumnTone(for: theme)

        let upperKey = UpperArtworkKey(
            year: year,
            month: month,
            todayKey: todayKey,
            monthTotal: monthTotal,
            avgSeconds: avgSeconds,
            peakIndex: peakIndex,
            dataDigest: dataDigest,
            language: language,
            noDataLabel: noDataLabel,
            theme: theme.cacheKey
        )
        let lowerKey = LowerArtworkKey(
            year: year,
            month: month,
            monthTotal: monthTotal,
            maxBinCenti: Int((profile.maxBinHours * 100.0).rounded()),
            dataDigest: dataDigest,
            noDataLabel: noDataLabel,
            theme: theme.cacheKey
        )

        let hoveredSlot: MonthElevationSlot? = hoveredDayIndex.flatMap {
            slots.indices.contains($0) ? slots[$0] : nil
        }
        let hoveredDayIntervals: [ActiveInterval] = hoveredSlot.flatMap { days[$0.key]?.intervals } ?? []
        let hoveredDayBins: [Double]? = hoveredSlot != nil
            ? InstrumentMath.buildDayDiurnalBins(intervals: hoveredDayIntervals, binCount: max(1, profile.bins.count))
            : nil

        VStack(alignment: .leading, spacing: 0) {
            // UPPER DECK — 30-Day Elevation Sequence
            VStack(alignment: .leading, spacing: 6) {
                upperHeaderRow(
                    monthStr: monthStr,
                    hoveredSlot: hoveredSlot,
                    peakSlot: peakSlot,
                    columnTone: columnTone
                )

                GeometryReader { geo in
                    ZStack {
                        CachedTelemetryArtwork(
                            key: upperKey,
                            width: geo.size.width,
                            height: geo.size.height
                        ) {
                            StaticMonthElevationCanvas(
                                slots: slots,
                                month: month,
                                monthTotal: monthTotal,
                                avgSeconds: avgSeconds,
                                avgHours: avgHours,
                                peakIndex: peakIndex,
                                scale: scale,
                                language: language,
                                weekdaySymbols: weekdaySymbols,
                                noDataLabel: noDataLabel,
                                theme: theme
                            )
                        }
                        .allowsHitTesting(false)

                        MonthElevationHoverOverlayCanvas(
                            slots: slots,
                            hoveredDayIndex: hoveredDayIndex,
                            scale: scale,
                            theme: theme
                        )
                        .allowsHitTesting(false)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        guard monthTotal > 0, !slots.isEmpty else {
                            if hoveredDayIndex != nil { hoveredDayIndex = nil }
                            return
                        }
                        switch phase {
                        case .active(let pt):
                            let plotRect = MonthElevationLayout.plotRect(for: geo.size)
                            if pt.x >= plotRect.minX && pt.x <= plotRect.maxX
                                && pt.y >= plotRect.minY - 6.0 && pt.y <= plotRect.maxY + 14.0
                            {
                                let slotW = MonthElevationLayout.slotWidth(plotRect: plotRect, count: slots.count)
                                let idx = min(slots.count - 1, max(0, Int(floor((pt.x - plotRect.minX) / slotW))))
                                if hoveredDayIndex != idx {
                                    hoveredDayIndex = idx
                                }
                                if hoveredBinIndex != nil {
                                    hoveredBinIndex = nil
                                }
                            } else if hoveredDayIndex != nil {
                                hoveredDayIndex = nil
                            }
                        case .ended:
                            if hoveredDayIndex != nil {
                                hoveredDayIndex = nil
                            }
                        }
                    }
                }
                .frame(height: upperHeight)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 9)

            HairlineRule(showCrosshairs: true)

            // LOWER DECK — Aggregated 24H Diurnal Profile
            VStack(alignment: .leading, spacing: 5) {
                lowerHeaderRow(
                    hoveredSlot: hoveredSlot,
                    hoveredDayIntervals: hoveredDayIntervals,
                    columnTone: columnTone
                )

                GeometryReader { geo in
                    ZStack {
                        CachedTelemetryArtwork(
                            key: lowerKey,
                            width: geo.size.width,
                            height: geo.size.height
                        ) {
                            StaticMonthDiurnalCanvas(
                                profile: profile,
                                monthTotal: monthTotal,
                                noDataLabel: noDataLabel,
                                theme: theme
                            )
                        }
                        .allowsHitTesting(false)

                        if monthTotal > 0 {
                            MonthDiurnalOverlayCanvas(
                                profile: profile,
                                hoveredDayBins: hoveredDayBins,
                                hoveredBinIndex: hoveredBinIndex,
                                theme: theme
                            )
                            .allowsHitTesting(false)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        guard monthTotal > 0, !profile.bins.isEmpty else {
                            if hoveredBinIndex != nil { hoveredBinIndex = nil }
                            return
                        }
                        switch phase {
                        case .active(let pt):
                            let plotRect = MonthDiurnalLayout.plotRect(for: geo.size)
                            if pt.x >= plotRect.minX && pt.x <= plotRect.maxX
                                && pt.y >= plotRect.minY - 2.0 && pt.y <= plotRect.maxY + 14.0
                            {
                                let binW = plotRect.width / CGFloat(profile.bins.count)
                                let idx = min(profile.bins.count - 1, max(0, Int(floor((pt.x - plotRect.minX) / binW))))
                                if hoveredBinIndex != idx {
                                    hoveredBinIndex = idx
                                }
                                if hoveredDayIndex != nil {
                                    hoveredDayIndex = nil
                                }
                            } else if hoveredBinIndex != nil {
                                hoveredBinIndex = nil
                            }
                        case .ended:
                            if hoveredBinIndex != nil {
                                hoveredBinIndex = nil
                            }
                        }
                    }
                }
                .frame(height: lowerHeight)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 9)
        }
        .onChange(of: monthPrefix) { _ in
            hoveredDayIndex = nil
            hoveredBinIndex = nil
        }
        .onChange(of: isPanelVisible) { visible in
            if !visible {
                hoveredDayIndex = nil
                hoveredBinIndex = nil
            }
        }
    }

    private func upperHeaderRow(
        monthStr: String,
        hoveredSlot: MonthElevationSlot?,
        peakSlot: MonthElevationSlot?,
        columnTone: Color
    ) -> some View {
        HStack(spacing: 5) {
            Text("03.2")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.accent.opacity(0.92))
            Text("MONTH ELEVATION // \(monthStr)")
                .font(.system(size: 8, weight: .regular, design: .monospaced))
                .tracking(0.8)
                .foregroundColor(theme.inkSecondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if let h = hoveredSlot {
                let dateTag = String(format: "%02d/%02d", month, h.dayNum)
                HStack(spacing: 4) {
                    Rectangle()
                        .fill(theme.accent)
                        .frame(width: 4, height: 4)
                    if h.seconds > 0 {
                        let dur = TimeLogic.formatDurationShort(h.seconds).uppercased()
                        Text("\(dateTag) · \(dur) · \(h.sessionCount) SESS")
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(theme.accent)
                            .lineLimit(1)
                    } else {
                        Text("\(dateTag) · 0M")
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(theme.inkSecondary)
                            .lineLimit(1)
                    }
                }
            } else if monthTotal > 0 {
                HStack(spacing: 3) {
                    Text("AVG \(TimeLogic.formatDurationShort(avgSeconds).uppercased())")
                        .foregroundColor(columnTone.opacity(theme.isDark ? 0.92 : 0.88))
                    if let pk = peakSlot {
                        Text("·")
                            .foregroundColor(theme.inkMuted)
                        Text("PEAK \(TimeLogic.formatDurationShort(pk.seconds).uppercased())")
                            .fontWeight(.semibold)
                            .foregroundColor(theme.accent)
                    }
                }
                .font(.system(size: 8, weight: .regular, design: .monospaced))
                .monospacedDigit()
                .lineLimit(1)
            }
        }
        .frame(height: 12)
    }

    private func lowerHeaderRow(
        hoveredSlot: MonthElevationSlot?,
        hoveredDayIntervals: [ActiveInterval],
        columnTone: Color
    ) -> some View {
        let binCount = max(1, profile.bins.count)
        return HStack(spacing: 5) {
            Rectangle()
                .fill(hoveredDayIndex != nil || hoveredBinIndex != nil ? theme.accent : columnTone)
                .frame(width: 4, height: 4)
            Text("24H DIURNAL PROFILE")
                .font(.system(size: 7.5, weight: .regular, design: .monospaced))
                .tracking(0.8)
                .foregroundColor(theme.inkSecondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if let b = hoveredBinIndex, profile.bins.indices.contains(b) {
                let winStr = formatBinWindowClock(startBin: b, endBin: b + 1, binCount: binCount)
                let secs = Int((profile.bins[b] * 3600.0).rounded())
                let valStr = secs > 0 ? monthElevationCompactHours(secs) : "0M"
                Text("\(winStr) · \(valStr)")
                    .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(secs > 0 ? theme.accent : theme.inkMuted)
                    .lineLimit(1)
            } else if let h = hoveredSlot {
                let dateTag = String(format: "%02d/%02d", month, h.dayNum)
                if let minStart = hoveredDayIntervals.map(\.startSec).min(),
                   let maxEnd = hoveredDayIntervals.map(\.endSec).max(),
                   maxEnd > minStart
                {
                    Text("\(dateTag) · \(TimeLogic.formatClock(minStart))–\(TimeLogic.formatClock(maxEnd))")
                        .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(theme.accent)
                        .lineLimit(1)
                } else {
                    Text("\(dateTag) · 0M")
                        .font(.system(size: 7.5, weight: .regular, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(theme.inkMuted)
                        .lineLimit(1)
                }
            } else if let s = profile.peakWindowStartBin, let e = profile.peakWindowEndBin, e > s {
                let peakWinStr = formatBinWindowClock(startBin: s, endBin: e, binCount: binCount)
                Text("PEAK \(peakWinStr)")
                    .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(theme.accent)
                    .lineLimit(1)
            }
        }
        .frame(height: 11)
    }
}

// MARK: Upper Deck Static Canvas (Cached via CachedTelemetryArtwork)

private struct StaticMonthElevationCanvas: View {
    let slots: [MonthElevationSlot]
    let month: Int
    let monthTotal: Int
    let avgSeconds: Int
    let avgHours: Double
    let peakIndex: Int?
    let scale: MonthElevationScale
    let language: AppLanguage
    let weekdaySymbols: [String]
    let noDataLabel: String
    let theme: AGYTheme

    var body: some View {
        Canvas { context, size in
            let count = max(1, slots.count)
            let plotRect = MonthElevationLayout.plotRect(for: size)
            let slotW = MonthElevationLayout.slotWidth(plotRect: plotRect, count: count)
            let columnTone = monthElevationColumnTone(for: theme)

            // 1. Subtle framed plot backdrop
            let plotBg: Color = theme.isNotch
                ? theme.surfaceRaised.opacity(0.55)
                : (theme.isDark ? theme.surface.opacity(0.42) : theme.surfaceRaised.opacity(0.50))
            context.fill(Path(plotRect), with: .color(plotBg))

            // 2. Weekend columns (Sat-Sun) subtle shaded + fine 45° archival hatch
            var weekendFill = Path()
            var weekendHatch = Path()
            for (i, slot) in slots.enumerated() where slot.isWeekend {
                let r = CGRect(
                    x: plotRect.minX + CGFloat(i) * slotW,
                    y: plotRect.minY,
                    width: slotW,
                    height: plotRect.height
                )
                weekendFill.addRect(r)
                addArchivalDiagonalHatch(to: &weekendHatch, in: r, step: 5.5)
            }
            if !weekendFill.isEmpty {
                let wkFillColor: Color = theme.isNotch
                    ? Color.white.opacity(0.035)
                    : (theme.isDark ? Color.white.opacity(0.026) : theme.surface.opacity(0.62))
                context.fill(weekendFill, with: .color(wkFillColor))
                context.stroke(
                    weekendHatch,
                    with: .color(theme.hairline.opacity(theme.isNotch ? 0.44 : (theme.isDark ? 0.36 : 0.34))),
                    lineWidth: 0.45
                )
            }

            // 3. Horizontal calibration gridlines at midTick & topTick
            var hGrid = Path()
            for refH in [scale.midTick, scale.topTick] {
                let ry = MonthElevationLayout.yForHours(refH, ceiling: scale.ceiling, plotRect: plotRect)
                hGrid.move(to: CGPoint(x: plotRect.minX, y: ry))
                hGrid.addLine(to: CGPoint(x: plotRect.maxX, y: ry))
            }
            context.stroke(
                hGrid,
                with: .color(theme.hairline.opacity(theme.isDark ? 0.65 : 0.60)),
                style: StrokeStyle(lineWidth: 0.5, dash: [1.5, 2.5])
            )

            // 4. Monday week-boundary hairlines + non-colliding W1..W5 labels
            var mondayLines = Path()
            var mondayTopTicks = Path()
            var weekIdx = 0
            var lastLabelRight: CGFloat = -1000.0
            let estimatedWeekLabelW: CGFloat = 36.0
            for (i, slot) in slots.enumerated() where slot.isMonday {
                let bx = plotRect.minX + CGFloat(i) * slotW
                if i > 0 {
                    mondayLines.move(to: CGPoint(x: bx, y: plotRect.minY))
                    mondayLines.addLine(to: CGPoint(x: bx, y: plotRect.maxY))
                }
                mondayTopTicks.move(to: CGPoint(x: bx, y: plotRect.minY - 3.5))
                mondayTopTicks.addLine(to: CGPoint(x: bx, y: plotRect.minY))
                weekIdx += 1
                if let lbl = slot.shortMondayLabel {
                    let drawX = max(plotRect.minX + 1.5, bx + 2.5)
                    if (drawX + estimatedWeekLabelW) <= (plotRect.maxX + 2.0) && drawX >= (lastLabelRight + 4.0) {
                        let txt = Text("W\(weekIdx) \(lbl)")
                            .font(.system(size: 6.5, weight: .regular, design: .monospaced))
                            .foregroundColor(theme.inkMuted)
                        context.draw(txt, at: CGPoint(x: drawX, y: plotRect.minY - 3.0), anchor: .bottomLeading)
                        lastLabelRight = drawX + estimatedWeekLabelW
                    }
                }
            }
            context.stroke(mondayLines, with: .color(theme.hairlineStrong.opacity(theme.isDark ? 0.52 : 0.46)), lineWidth: 0.6)
            context.stroke(mondayTopTicks, with: .color(theme.hairlineStrong.opacity(theme.isDark ? 0.85 : 0.78)), lineWidth: 0.75)

            // 5. Left Y-axis micro-scale (0H, midTick, topTick) + tick pips
            var yTicks = Path()
            let yMarks: [(Double, String)] = [(0, "0H"), (scale.midTick, scale.midLabel), (scale.topTick, scale.topLabel)]
            for (val, label) in yMarks {
                let ry = MonthElevationLayout.yForHours(val, ceiling: scale.ceiling, plotRect: plotRect)
                yTicks.move(to: CGPoint(x: plotRect.minX - 3.0, y: ry))
                yTicks.addLine(to: CGPoint(x: plotRect.minX, y: ry))
                let t = Text(label)
                    .font(.system(size: 6.5, weight: .regular, design: .monospaced))
                    .foregroundColor(theme.inkMuted)
                context.draw(t, at: CGPoint(x: plotRect.minX - 4.5, y: ry), anchor: .trailing)
            }
            context.stroke(yTicks, with: .color(theme.hairlineStrong.opacity(0.85)), lineWidth: 0.7)

            // Subtle Google Yellow tick highlight on mid-Y calibration mark
            if theme.isMultiColorSpectrum {
                let midY = MonthElevationLayout.yForHours(scale.midTick, ceiling: scale.ceiling, plotRect: plotRect)
                var yellowTick = Path()
                yellowTick.move(to: CGPoint(x: plotRect.minX - 3.0, y: midY))
                yellowTick.addLine(to: CGPoint(x: plotRect.minX, y: midY))
                context.stroke(yellowTick, with: .color(theme.accentTertiary.opacity(0.95)), lineWidth: 0.95)
            }

            if monthTotal > 0 {
                // 6. Stratified Profile Columns (45° archival hatch + crisp side borders + horizontal top caps)
                var regWash = Path()
                var regHatch = Path()
                var regBorders = Path()
                var regCaps = Path()
                var aboveAvgWash = Path()
                var aboveAvgHatch = Path()
                var aboveAvgBorders = Path()
                var aboveAvgCaps = Path()
                var zeroTicks = Path()

                var peakRect: CGRect? = nil
                var peakSlotRef: MonthElevationSlot? = nil
                var todayRect: CGRect? = nil

                for (i, slot) in slots.enumerated() {
                    if slot.seconds <= 0 {
                        let cx = plotRect.minX + (CGFloat(i) + 0.5) * slotW
                        zeroTicks.move(to: CGPoint(x: cx - 2.0, y: plotRect.maxY - 1.2))
                        zeroTicks.addLine(to: CGPoint(x: cx + 2.0, y: plotRect.maxY - 1.2))
                        continue
                    }

                    let rect = MonthElevationLayout.columnRect(
                        index: i,
                        hours: slot.hours,
                        ceiling: scale.ceiling,
                        plotRect: plotRect,
                        slotW: slotW
                    )

                    if slot.isToday {
                        todayRect = rect
                    }

                    if i == peakIndex {
                        peakRect = rect
                        peakSlotRef = slot
                        continue
                    }

                    let isAboveAvg = slot.hours >= avgHours
                    if isAboveAvg {
                        aboveAvgWash.addRect(rect)
                        addArchivalDiagonalHatch(to: &aboveAvgHatch, in: rect, step: 3.1)
                        aboveAvgBorders.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                        aboveAvgBorders.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
                        aboveAvgBorders.move(to: CGPoint(x: rect.maxX, y: rect.maxY))
                        aboveAvgBorders.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                        aboveAvgCaps.addRect(CGRect(x: rect.minX - 0.3, y: rect.minY, width: rect.width + 0.6, height: 1.4))
                    } else {
                        regWash.addRect(rect)
                        addArchivalDiagonalHatch(to: &regHatch, in: rect, step: 3.4)
                        regBorders.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                        regBorders.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
                        regBorders.move(to: CGPoint(x: rect.maxX, y: rect.maxY))
                        regBorders.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                        regCaps.addRect(CGRect(x: rect.minX - 0.2, y: rect.minY, width: rect.width + 0.4, height: 1.2))
                    }
                }

                // Draw below-average columns
                if !regWash.isEmpty {
                    context.fill(regWash, with: .color(columnTone.opacity(theme.isDark ? 0.14 : 0.10)))
                    context.stroke(regHatch, with: .color(columnTone.opacity(theme.isDark ? 0.38 : 0.34)), lineWidth: 0.6)
                    context.stroke(regBorders, with: .color(columnTone.opacity(theme.isDark ? 0.56 : 0.48)), lineWidth: 0.6)
                    context.fill(regCaps, with: .color(columnTone.opacity(theme.isDark ? 0.85 : 0.78)))
                }

                // Draw above-average columns
                if !aboveAvgWash.isEmpty {
                    context.fill(aboveAvgWash, with: .color(columnTone.opacity(theme.isDark ? 0.24 : 0.18)))
                    context.stroke(aboveAvgHatch, with: .color(columnTone.opacity(theme.isDark ? 0.62 : 0.56)), lineWidth: 0.65)
                    context.stroke(aboveAvgBorders, with: .color(columnTone.opacity(theme.isDark ? 0.84 : 0.78)), lineWidth: 0.7)
                    context.fill(aboveAvgCaps, with: .color(theme.isDark ? columnTone : theme.inkPrimary.opacity(0.86)))
                }

                // Draw 0h baseline ticks
                if !zeroTicks.isEmpty {
                    context.stroke(zeroTicks, with: .color(theme.inkMuted.opacity(theme.isDark ? 0.55 : 0.50)), lineWidth: 0.9)
                }

                // 7. Today subtle accent outline + top cap (when Today is not the Peak day)
                if let tRect = todayRect, slots.firstIndex(where: { $0.isToday }) != peakIndex {
                    let outline = CGRect(
                        x: tRect.minX - 0.6,
                        y: tRect.minY - 0.6,
                        width: tRect.width + 1.2,
                        height: tRect.height + 0.6
                    )
                    context.stroke(Path(outline), with: .color(theme.accent.opacity(theme.isDark ? 0.58 : 0.52)), lineWidth: 0.75)
                    context.fill(
                        Path(CGRect(x: tRect.minX - 0.6, y: tRect.minY - 0.6, width: tRect.width + 1.2, height: 1.5)),
                        with: .color(theme.accent.opacity(0.85))
                    )
                }

                // 8. Peak Column in theme.accent + Fred Brackets + Auto-Flipping Clamped Elbow Callout
                var peakCalloutBounds: CGRect? = nil
                var peakBracketBounds: CGRect? = nil

                if let pRect = peakRect, let pSlot = peakSlotRef, let pIdx = peakIndex {
                    if theme.isDark {
                        let glow = pRect.insetBy(dx: -2.0, dy: -2.0)
                        context.fill(Path(glow), with: .color(theme.accent.opacity(0.14)))
                    }
                    context.fill(Path(pRect), with: .color(theme.accent.opacity(theme.isDark ? 0.28 : 0.17)))
                    var pkHatch = Path()
                    addArchivalDiagonalHatch(to: &pkHatch, in: pRect, step: 2.9)
                    context.stroke(pkHatch, with: .color(theme.accent.opacity(theme.isDark ? 0.76 : 0.64)), lineWidth: 0.7)
                    var pkWalls = Path()
                    pkWalls.move(to: CGPoint(x: pRect.minX, y: pRect.maxY))
                    pkWalls.addLine(to: CGPoint(x: pRect.minX, y: pRect.minY))
                    pkWalls.move(to: CGPoint(x: pRect.maxX, y: pRect.maxY))
                    pkWalls.addLine(to: CGPoint(x: pRect.maxX, y: pRect.minY))
                    context.stroke(pkWalls, with: .color(theme.accent.opacity(0.95)), lineWidth: 0.9)
                    context.fill(
                        Path(CGRect(x: pRect.minX - 0.5, y: pRect.minY, width: pRect.width + 1.0, height: 1.8)),
                        with: .color(theme.accent)
                    )

                    // Fred corner brackets framing the Peak column summit
                    let bracketRect = CGRect(
                        x: pRect.minX - 2.6,
                        y: max(plotRect.minY + 1.0, pRect.minY - 2.6),
                        width: pRect.width + 5.2,
                        height: min(pRect.height + 2.6, 18.0)
                    )
                    peakBracketBounds = bracketRect
                    var fred = Path()
                    addFredCornerBrackets(to: &fred, rect: bracketRect, arm: 3.4)
                    context.stroke(fred, with: .color(theme.accent), lineWidth: 0.95)

                    // Crisp micro target square at peak summit center
                    context.fill(
                        Path(CGRect(x: pRect.midX - 1.5, y: pRect.minY - 1.5, width: 3.0, height: 3.0)),
                        with: .color(theme.accent)
                    )

                    // Auto-flipping elbow callout: flip left when peak is in right ~40% of month OR cannot fit right
                    let calloutW: CGFloat = 68.0
                    let calloutH: CGFloat = 19.5
                    let anchorGap: CGFloat = 3.2
                    let elbowDx: CGFloat = 9.0
                    let leadDx: CGFloat = 6.0
                    let textGap: CGFloat = 1.5
                    let neededReach = anchorGap + elbowDx + leadDx + textGap + calloutW

                    let inRightZone = (Double(pIdx + 1) / Double(count)) > 0.62
                    let fitsRight = (pRect.maxX + neededReach) <= (plotRect.maxX - 3.0)
                    let fitsLeft = (pRect.minX - neededReach) >= (plotRect.minX + 3.0)
                    let flipLeft = (inRightZone || !fitsRight) && fitsLeft

                    let anchorY = min(plotRect.maxY - 6.0, max(plotRect.minY + 4.0, pRect.minY + 1.5))
                    let rawElbowY = pRect.minY - 3.5
                    let calloutMinY = min(
                        plotRect.maxY - calloutH - 2.5,
                        max(plotRect.minY + 2.5, rawElbowY - 5.5)
                    )
                    let elbowY = calloutMinY + 5.5

                    let anchorX: CGFloat
                    let elbowX: CGFloat
                    let leadEndX: CGFloat
                    let calloutMinX: CGFloat

                    if flipLeft {
                        anchorX = pRect.minX - anchorGap
                        elbowX = anchorX - elbowDx
                        leadEndX = elbowX - leadDx
                        calloutMinX = max(plotRect.minX + 3.0, leadEndX - textGap - calloutW)
                    } else {
                        anchorX = pRect.maxX + anchorGap
                        elbowX = anchorX + elbowDx
                        leadEndX = elbowX + leadDx
                        calloutMinX = min(plotRect.maxX - 3.0 - calloutW, leadEndX + textGap)
                    }

                    let calloutRect = CGRect(x: calloutMinX, y: calloutMinY, width: calloutW, height: calloutH)
                    peakCalloutBounds = calloutRect

                    var leader = Path()
                    leader.move(to: CGPoint(x: anchorX, y: anchorY))
                    leader.addLine(to: CGPoint(x: elbowX, y: elbowY))
                    leader.addLine(to: CGPoint(x: leadEndX, y: elbowY))
                    context.stroke(leader, with: .color(theme.accent.opacity(0.84)), lineWidth: 0.8)

                    // Canvas knockout behind callout text so Monday hairlines never cut through glyphs
                    let knockoutBg: Color = theme.isNotch
                        ? Color.black.opacity(0.92)
                        : (theme.isDark ? theme.canvas : theme.surfaceRaised).opacity(0.88)
                    context.fill(Path(calloutRect), with: .color(knockoutBg))

                    let pkValStr = monthElevationCompactHours(pSlot.seconds)
                    let pkTitle = Text(String(format: "PK.%02d · %@", pSlot.dayNum, pkValStr))
                        .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.accent)
                    let pkSubStr = monthElevationPeakSubtitle(
                        slot: pSlot,
                        month: month,
                        language: language,
                        weekdaySymbols: weekdaySymbols
                    )
                    let pkSub = Text(pkSubStr)
                        .font(.system(size: 6.2, weight: .regular, design: .monospaced))
                        .foregroundColor(theme.inkSecondary)

                    if flipLeft {
                        context.draw(pkTitle, at: CGPoint(x: calloutRect.maxX - 2.0, y: elbowY), anchor: .trailing)
                        context.draw(pkSub, at: CGPoint(x: calloutRect.maxX - 2.0, y: elbowY + 8.5), anchor: .trailing)
                    } else {
                        context.draw(pkTitle, at: CGPoint(x: calloutRect.minX + 2.0, y: elbowY), anchor: .leading)
                        context.draw(pkSub, at: CGPoint(x: calloutRect.minX + 2.0, y: elbowY + 8.5), anchor: .leading)
                    }
                }

                // 9. Full-width dashed horizontal AVG datum line + smart collision-free micro-badge
                if avgSeconds > 0 {
                    let avgY = MonthElevationLayout.yForHours(avgHours, ceiling: scale.ceiling, plotRect: plotRect)
                    var avgLine = Path()
                    avgLine.move(to: CGPoint(x: plotRect.minX, y: avgY))
                    avgLine.addLine(to: CGPoint(x: plotRect.maxX, y: avgY))
                    context.stroke(
                        avgLine,
                        with: .color(theme.isDark ? theme.inkPrimary.opacity(0.58) : theme.inkPrimary.opacity(0.48)),
                        style: StrokeStyle(lineWidth: 0.85, dash: [3.2, 2.4])
                    )

                    // Subtle Google Red end-datum ticks on the AVG hairline
                    if theme.isMultiColorSpectrum {
                        var redPips = Path()
                        redPips.addRect(CGRect(x: plotRect.minX, y: avgY - 1.25, width: 2.2, height: 2.5))
                        redPips.addRect(CGRect(x: plotRect.maxX - 2.2, y: avgY - 1.25, width: 2.2, height: 2.5))
                        context.fill(redPips, with: .color(theme.accentSecondary))
                    }

                    let tagW: CGFloat = 42.0
                    let tagH: CGFloat = 9.5
                    let preferredAboveY = avgY - tagH - 3.5
                    let rawTagY = preferredAboveY >= (plotRect.minY + 3.0) ? preferredAboveY : (avgY + 3.5)
                    let clampedTagY = min(plotRect.maxY - tagH - 2.5, max(plotRect.minY + 2.5, rawTagY))

                    let leftTag = CGRect(x: plotRect.minX + 3.5, y: clampedTagY, width: tagW, height: tagH)
                    let rightTag = CGRect(x: plotRect.maxX - tagW - 3.5, y: clampedTagY, width: tagW, height: tagH)

                    let paddedLeft = leftTag.insetBy(dx: -3.0, dy: -3.0)
                    let peakOnFarLeft = (peakIndex != nil && peakIndex! < 6)
                    let hitsCallout = peakCalloutBounds.map { $0.intersects(paddedLeft) } ?? false
                    let hitsBracket = peakBracketBounds.map { $0.intersects(paddedLeft) } ?? false
                    let tagRect = (peakOnFarLeft || hitsCallout || hitsBracket) ? rightTag : leftTag

                    let badgeBg: Color = theme.isNotch ? Color.black.opacity(0.95) : theme.canvas.opacity(0.94)
                    context.fill(Path(tagRect), with: .color(badgeBg))
                    context.stroke(
                        Path(tagRect),
                        with: .color(theme.hairlineStrong.opacity(theme.isNotch ? 0.78 : 0.55)),
                        lineWidth: 0.5
                    )
                    let avgText = Text("AVG \(monthElevationCompactHours(avgSeconds))")
                        .font(.system(size: 6.3, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.inkSecondary)
                    context.draw(avgText, at: CGPoint(x: tagRect.midX, y: tagRect.midY), anchor: .center)
                }
            } else {
                // Clean framed empty state (zero NaN / zero division-by-zero)
                let emptyLabel = Text(noDataLabel)
                    .font(.system(size: 9.0, weight: .regular, design: .monospaced))
                    .tracking(0.8)
                    .foregroundColor(theme.inkMuted)
                context.draw(emptyLabel, at: CGPoint(x: plotRect.midX, y: plotRect.midY), anchor: .center)
            }

            // 10. Crisp Perimeter Frame
            context.stroke(
                Path(plotRect),
                with: .color(theme.hairlineStrong.opacity(theme.isNotch ? 0.85 : (theme.isDark ? 0.72 : 0.65))),
                lineWidth: 0.7
            )

            // 11. Bottom X-Axis Vernier Ticks + Day Numerals (01, 05, 10, 15, 20, 25, lastDay)
            let lastDay = slots.count
            let labelSet: Set<Int> = [1, 5, 10, 15, 20, 25, lastDay]
            var minorTicks = Path()
            var majorTicks = Path()
            var todayTick = Path()
            var peakTick = Path()

            for (i, slot) in slots.enumerated() {
                let cx = plotRect.minX + (CGFloat(i) + 0.5) * slotW
                let isMajor = labelSet.contains(slot.dayNum)
                let isPeak = (i == peakIndex)
                let th: CGFloat = (isMajor || slot.isToday || isPeak) ? 4.2 : 2.0
                let tickRect = CGRect(x: cx - 0.4, y: plotRect.maxY, width: 0.8, height: th)

                if slot.isToday {
                    todayTick.addRect(tickRect)
                    if !isMajor {
                        // Baseline indicator pip right underneath today's tick when not colliding with a numeral
                        todayTick.addRect(CGRect(x: cx - 1.6, y: plotRect.maxY + 6.5, width: 3.2, height: 3.2))
                    } else {
                        // Compact baseline pip tucked cleanly on the plot floor when today sits on a major numeral
                        todayTick.addRect(CGRect(x: cx - 1.3, y: plotRect.maxY - 2.6, width: 2.6, height: 2.6))
                    }
                } else if isPeak {
                    peakTick.addRect(tickRect)
                } else if isMajor {
                    majorTicks.addRect(tickRect)
                } else {
                    minorTicks.addRect(tickRect)
                }

                if isMajor {
                    let lblColor: Color = (isPeak || slot.isToday) ? theme.accent : theme.inkMuted
                    let lbl = Text(String(format: "%02d", slot.dayNum))
                        .font(.system(size: 7.0, weight: (isPeak || slot.isToday) ? .semibold : .regular, design: .monospaced))
                        .foregroundColor(lblColor)
                    let anchor: UnitPoint = slot.dayNum == 1 ? .topLeading : (slot.dayNum == lastDay ? .topTrailing : .top)
                    let drawX: CGFloat = slot.dayNum == 1 ? plotRect.minX : (slot.dayNum == lastDay ? plotRect.maxX : cx)
                    context.draw(lbl, at: CGPoint(x: drawX, y: plotRect.maxY + 5.5), anchor: anchor)
                }
            }
            context.fill(minorTicks, with: .color(theme.hairline))
            context.fill(majorTicks, with: .color(theme.hairlineStrong))
            if !peakTick.isEmpty { context.fill(peakTick, with: .color(theme.accent)) }
            if !todayTick.isEmpty { context.fill(todayTick, with: .color(theme.accent)) }
        }
    }
}

// MARK: Upper Deck Lightweight Hover Overlay (120Hz Zero-Recompute)

private struct MonthElevationHoverOverlayCanvas: View {
    let slots: [MonthElevationSlot]
    let hoveredDayIndex: Int?
    let scale: MonthElevationScale
    let theme: AGYTheme

    var body: some View {
        Canvas { context, size in
            guard let idx = hoveredDayIndex, slots.indices.contains(idx) else { return }
            let slot = slots[idx]
            let plotRect = MonthElevationLayout.plotRect(for: size)
            let slotW = MonthElevationLayout.slotWidth(plotRect: plotRect, count: slots.count)

            let bandX = plotRect.minX + CGFloat(idx) * slotW
            let bandRect = CGRect(x: bandX, y: plotRect.minY, width: slotW, height: plotRect.height)

            // Subtle hairline focus column band
            context.fill(
                Path(bandRect),
                with: .color(theme.accent.opacity(theme.isDark ? 0.10 : 0.06))
            )
            context.stroke(
                Path(bandRect),
                with: .color(theme.accent.opacity(theme.isDark ? 0.55 : 0.45)),
                lineWidth: 0.65
            )

            if slot.seconds > 0 {
                let colRect = MonthElevationLayout.columnRect(
                    index: idx,
                    hours: slot.hours,
                    ceiling: scale.ceiling,
                    plotRect: plotRect,
                    slotW: slotW
                )
                context.fill(Path(colRect), with: .color(theme.accent.opacity(theme.isDark ? 0.34 : 0.22)))
                var hatch = Path()
                addArchivalDiagonalHatch(to: &hatch, in: colRect, step: 2.9)
                context.stroke(hatch, with: .color(theme.accent.opacity(theme.isDark ? 0.85 : 0.72)), lineWidth: 0.75)
                var walls = Path()
                walls.move(to: CGPoint(x: colRect.minX, y: colRect.maxY))
                walls.addLine(to: CGPoint(x: colRect.minX, y: colRect.minY))
                walls.move(to: CGPoint(x: colRect.maxX, y: colRect.maxY))
                walls.addLine(to: CGPoint(x: colRect.maxX, y: colRect.minY))
                context.stroke(walls, with: .color(theme.accent), lineWidth: 0.95)
                context.fill(
                    Path(CGRect(x: colRect.minX - 0.5, y: colRect.minY, width: colRect.width + 1.0, height: 1.9)),
                    with: .color(theme.accent)
                )
            } else {
                let cx = bandX + slotW * 0.5
                context.fill(
                    Path(CGRect(x: cx - 2.0, y: plotRect.maxY - 2.2, width: 4.0, height: 2.2)),
                    with: .color(theme.accent)
                )
            }

            // Crisp bottom X-axis accent reticle tick
            let cx = bandX + slotW * 0.5
            context.fill(
                Path(CGRect(x: cx - 0.55, y: plotRect.maxY, width: 1.1, height: 4.6)),
                with: .color(theme.accent)
            )
        }
    }
}

// MARK: Lower Deck Static Canvas — 24H Diurnal Base Profile (Cached via CachedTelemetryArtwork)

private struct StaticMonthDiurnalCanvas: View {
    let profile: MonthDiurnalProfile
    let monthTotal: Int
    let noDataLabel: String
    let theme: AGYTheme

    var body: some View {
        Canvas { context, size in
            let plotRect = MonthDiurnalLayout.plotRect(for: size)
            let bins = profile.bins
            let binCount = max(1, bins.count)
            let binW = plotRect.width / CGFloat(binCount)
            let maxVal = max(0.0001, profile.maxBinHours)
            let columnTone = monthElevationColumnTone(for: theme)

            // 1. Subtle framed background
            let bg: Color = theme.isNotch
                ? theme.surfaceRaised.opacity(0.50)
                : (theme.isDark ? theme.surface.opacity(0.38) : theme.surfaceRaised.opacity(0.45))
            context.fill(Path(plotRect), with: .color(bg))

            // 2. Vertical 06 / 12 / 18 reference hairlines + subtle 50% horizontal datum
            var vGrid = Path()
            for q in [1, 2, 3] {
                let gx = plotRect.minX + plotRect.width * CGFloat(q) * 0.25
                vGrid.move(to: CGPoint(x: gx, y: plotRect.minY))
                vGrid.addLine(to: CGPoint(x: gx, y: plotRect.maxY))
            }
            let midY = plotRect.minY + plotRect.height * 0.5
            vGrid.move(to: CGPoint(x: plotRect.minX, y: midY))
            vGrid.addLine(to: CGPoint(x: plotRect.maxX, y: midY))
            context.stroke(
                vGrid,
                with: .color(theme.hairline.opacity(theme.isDark ? 0.88 : 0.72)),
                style: StrokeStyle(lineWidth: 0.55, dash: [1.5, 2.2])
            )

            if monthTotal > 0 && profile.maxBinHours > 0 {
                // 3. Stepped envelope gradient fill + stepped crest trace
                var areaPath = Path()
                var crestPath = Path()
                let usableH = plotRect.height - 4.0

                areaPath.move(to: CGPoint(x: plotRect.minX, y: plotRect.maxY))
                for i in 0..<binCount {
                    let norm = CGFloat(min(1.0, max(0.0, bins[i] / maxVal)))
                    let x0 = plotRect.minX + CGFloat(i) * binW
                    let x1 = x0 + binW
                    let y = plotRect.maxY - norm * usableH
                    areaPath.addLine(to: CGPoint(x: x0, y: y))
                    areaPath.addLine(to: CGPoint(x: x1, y: y))

                    if i == 0 {
                        crestPath.move(to: CGPoint(x: x0, y: y))
                    } else {
                        crestPath.addLine(to: CGPoint(x: x0, y: y))
                    }
                    crestPath.addLine(to: CGPoint(x: x1, y: y))
                }
                areaPath.addLine(to: CGPoint(x: plotRect.maxX, y: plotRect.maxY))
                areaPath.closeSubpath()

                context.fill(
                    areaPath,
                    with: .linearGradient(
                        Gradient(colors: [
                            columnTone.opacity(theme.isDark ? 0.24 : 0.16),
                            columnTone.opacity(theme.isDark ? 0.04 : 0.025),
                        ]),
                        startPoint: CGPoint(x: 0, y: plotRect.minY),
                        endPoint: CGPoint(x: 0, y: plotRect.maxY)
                    )
                )

                // 4. Deterministic archival micro-stipple texture inside active diurnal density
                var stippleDots = Path()
                let stepX: CGFloat = 2.6
                let stepY: CGFloat = 2.4
                let cols = Int(plotRect.width / stepX)
                let rows = Int(plotRect.height / stepY)
                for ix in 0...cols {
                    let px = plotRect.minX + CGFloat(ix) * stepX
                    let bIdx = min(binCount - 1, max(0, Int((px - plotRect.minX) / binW)))
                    let norm = CGFloat(min(1.0, max(0.0, bins[bIdx] / maxVal)))
                    guard norm > 0.05 else { continue }
                    let crestY = plotRect.maxY - norm * usableH
                    for iy in 0...rows {
                        let py = plotRect.minY + CGFloat(iy) * stepY
                        guard py >= crestY + 1.0 && py <= plotRect.maxY - 1.2 else { continue }
                        let h = monthDiurnalHash(ix + 11, iy + 37)
                        let roll = Double(h & 0xFF) / 255.0
                        let depthFrac = Double((py - crestY) / max(1.0, plotRect.maxY - crestY))
                        let prob = (0.55 - 0.25 * depthFrac) * Double(0.45 + 0.55 * norm)
                        if roll < prob {
                            stippleDots.addRect(CGRect(x: px, y: py, width: 1.0, height: 1.0))
                        }
                    }
                }
                if !stippleDots.isEmpty {
                    context.fill(stippleDots, with: .color(columnTone.opacity(theme.isDark ? 0.52 : 0.44)))
                }

                // 5. 48 Vernier impulse stems
                var stems = Path()
                for i in 0..<binCount {
                    let norm = CGFloat(min(1.0, max(0.0, bins[i] / maxVal)))
                    guard norm > 0.01 else { continue }
                    let cx = plotRect.minX + (CGFloat(i) + 0.5) * binW
                    let topY = plotRect.maxY - norm * usableH
                    let stemW: CGFloat = 1.6
                    stems.addRect(CGRect(x: cx - stemW * 0.5, y: topY, width: stemW, height: plotRect.maxY - topY))
                }
                if !stems.isEmpty {
                    context.fill(stems, with: .color(columnTone.opacity(theme.isDark ? 0.64 : 0.56)))
                }

                // 6. Crisp stepped crest trace
                context.stroke(
                    crestPath,
                    with: .color(theme.isDark ? columnTone.opacity(0.90) : theme.inkPrimary.opacity(0.75)),
                    lineWidth: 0.9
                )
            } else {
                let emptyLabel = Text(noDataLabel)
                    .font(.system(size: 8.5, weight: .regular, design: .monospaced))
                    .tracking(0.8)
                    .foregroundColor(theme.inkMuted)
                context.draw(emptyLabel, at: CGPoint(x: plotRect.midX, y: plotRect.midY), anchor: .center)
            }

            // 7. Frame border
            context.stroke(
                Path(plotRect),
                with: .color(theme.hairlineStrong.opacity(theme.isNotch ? 0.85 : (theme.isDark ? 0.68 : 0.60))),
                lineWidth: 0.65
            )

            // 8. Calibrated 24H ruler ticks (00 / 06 / 12 / 18 / 24)
            var minorTicks = Path()
            var medTicks = Path()
            var majorTicks = Path()
            for h in 0...24 {
                let tx = plotRect.minX + (CGFloat(h) / 24.0) * plotRect.width
                if h % 6 == 0 {
                    majorTicks.addRect(CGRect(x: tx - 0.45, y: plotRect.maxY, width: 0.9, height: 4.2))
                    let label = Text(String(format: "%02d", h))
                        .font(.system(size: 7.0, weight: .regular, design: .monospaced))
                        .foregroundColor(theme.inkMuted)
                    let anchor: UnitPoint = h == 0 ? .topLeading : (h == 24 ? .topTrailing : .top)
                    context.draw(label, at: CGPoint(x: tx, y: plotRect.maxY + 5.0), anchor: anchor)
                } else if h % 3 == 0 {
                    medTicks.addRect(CGRect(x: tx - 0.35, y: plotRect.maxY, width: 0.7, height: 2.8))
                } else {
                    minorTicks.addRect(CGRect(x: tx - 0.3, y: plotRect.maxY, width: 0.6, height: 1.7))
                }
            }
            context.fill(minorTicks, with: .color(theme.hairline))
            context.fill(medTicks, with: .color(theme.hairlineStrong.opacity(0.70)))
            context.fill(majorTicks, with: .color(theme.hairlineStrong))

            // Subtle Google Yellow noon datum tick on 12:00
            if theme.isMultiColorSpectrum {
                let noonX = plotRect.minX + plotRect.width * 0.5
                context.fill(
                    Path(CGRect(x: noonX - 0.55, y: plotRect.maxY, width: 1.1, height: 4.2)),
                    with: .color(theme.accentTertiary)
                )
            }
        }
    }
}

// MARK: Lower Deck Lightweight Dynamic Overlay (Idle Peak Window / Cross-Day Highlight / Bin Reticle)

private struct MonthDiurnalOverlayCanvas: View {
    let profile: MonthDiurnalProfile
    let hoveredDayBins: [Double]?
    let hoveredBinIndex: Int?
    let theme: AGYTheme

    var body: some View {
        Canvas { context, size in
            let bins = profile.bins
            let binCount = bins.count
            guard binCount > 0, profile.maxBinHours > 0 else { return }

            let plotRect = MonthDiurnalLayout.plotRect(for: size)
            let binW = plotRect.width / CGFloat(binCount)
            let usableH = plotRect.height - 4.0
            let maxVal = profile.maxBinHours

            if let b = hoveredBinIndex, bins.indices.contains(b) {
                // Lower-deck hover: crisp vertical accent reticle + highlighted bin bar
                let x0 = plotRect.minX + CGFloat(b) * binW
                let cx = x0 + binW * 0.5
                let norm = CGFloat(min(1.0, max(0.0, bins[b] / maxVal)))
                let crestY = plotRect.maxY - norm * usableH

                // Column highlight band + top cap
                context.fill(
                    Path(CGRect(x: x0, y: plotRect.minY, width: binW, height: plotRect.height)),
                    with: .color(theme.accent.opacity(theme.isDark ? 0.18 : 0.11))
                )
                context.fill(
                    Path(CGRect(x: x0, y: plotRect.minY, width: binW, height: 1.5)),
                    with: .color(theme.accent)
                )

                // Highlighted bin bar fill + crest cap
                if norm > 0.005 {
                    let barRect = CGRect(x: x0 + 0.5, y: crestY, width: max(1.6, binW - 1.0), height: plotRect.maxY - crestY)
                    context.fill(Path(barRect), with: .color(theme.accent.opacity(theme.isDark ? 0.52 : 0.42)))
                    context.fill(
                        Path(CGRect(x: x0, y: crestY - 0.5, width: binW, height: 1.6)),
                        with: .color(theme.accent)
                    )
                }

                // Vertical accent reticle hairline
                var reticle = Path()
                reticle.move(to: CGPoint(x: cx, y: plotRect.minY))
                reticle.addLine(to: CGPoint(x: cx, y: plotRect.maxY))
                context.stroke(reticle, with: .color(theme.accent.opacity(0.82)), lineWidth: 0.8)

                // Crisp 3x3 target pip on the crest
                context.fill(
                    Path(CGRect(x: cx - 1.5, y: crestY - 1.5, width: 3.0, height: 3.0)),
                    with: .color(theme.accent)
                )

                // Ruler accent tick
                context.fill(
                    Path(CGRect(x: cx - 0.55, y: plotRect.maxY, width: 1.1, height: 4.4)),
                    with: .color(theme.accent)
                )
            } else if let dayBins = hoveredDayBins {
                // Upper-deck day hover: cross-highlight that specific day's 24h active bins in theme.accent
                let binCapacityHours = 24.0 / Double(max(1, dayBins.count))
                var topCaps = Path()
                var stems = Path()
                var dayCrest = Path()

                for i in 0..<min(binCount, dayBins.count) {
                    let hrs = dayBins[i]
                    guard hrs > 0.0005 else { continue }
                    let intensity = min(1.0, max(0.0, hrs / binCapacityHours))
                    let x0 = plotRect.minX + CGFloat(i) * binW
                    let cx = x0 + binW * 0.5

                    // Column highlight wash across the full band so active hours read immediately
                    let washAlpha = (theme.isDark ? 0.16 : 0.10) * (0.45 + 0.55 * intensity)
                    context.fill(
                        Path(CGRect(x: x0, y: plotRect.minY, width: binW, height: plotRect.height)),
                        with: .color(theme.accent.opacity(washAlpha))
                    )
                    topCaps.addRect(CGRect(x: x0, y: plotRect.minY, width: binW, height: 1.5))

                    // Accent vernier impulse stem scaled to this day's density within the 30-min bin
                    let stemH = max(3.5, CGFloat(intensity) * usableH)
                    let topY = plotRect.maxY - stemH
                    let stemW: CGFloat = max(1.8, min(2.6, binW * 0.34))
                    stems.addRect(CGRect(x: cx - stemW * 0.5, y: topY, width: stemW, height: stemH))

                    dayCrest.move(to: CGPoint(x: x0, y: topY))
                    dayCrest.addLine(to: CGPoint(x: x0 + binW, y: topY))
                }

                if !topCaps.isEmpty {
                    context.fill(topCaps, with: .color(theme.accent))
                }
                if !stems.isEmpty {
                    context.fill(stems, with: .color(theme.accent.opacity(theme.isDark ? 0.92 : 0.86)))
                }
                if !dayCrest.isEmpty {
                    context.stroke(dayCrest, with: .color(theme.accent), lineWidth: 1.35)
                }
            } else if let pkStart = profile.peakWindowStartBin,
                      let pkEnd = profile.peakWindowEndBin,
                      pkEnd > pkStart
            {
                // Idle state: highlight the month's peak 2-hour diurnal window in theme.accent
                let clampedStart = max(0, min(binCount - 1, pkStart))
                let clampedEnd = max(clampedStart + 1, min(binCount, pkEnd))
                let pkX0 = plotRect.minX + CGFloat(clampedStart) * binW
                let pkW = CGFloat(clampedEnd - clampedStart) * binW

                context.fill(
                    Path(CGRect(x: pkX0, y: plotRect.minY, width: pkW, height: plotRect.height)),
                    with: .color(theme.accent.opacity(theme.isDark ? 0.11 : 0.065))
                )
                context.fill(
                    Path(CGRect(x: pkX0, y: plotRect.minY, width: pkW, height: 1.5)),
                    with: .color(theme.accent)
                )

                // Accent stipple dots inside peak window
                var pkDots = Path()
                let stepX: CGFloat = 2.6
                let stepY: CGFloat = 2.4
                let minIx = max(0, Int(floor((pkX0 - plotRect.minX) / stepX)))
                let maxIx = Int(ceil((pkX0 + pkW - plotRect.minX) / stepX))
                let rows = Int(plotRect.height / stepY)
                for ix in minIx...maxIx {
                    let px = plotRect.minX + CGFloat(ix) * stepX
                    let bIdx = min(binCount - 1, max(0, Int((px - plotRect.minX) / binW)))
                    guard bIdx >= clampedStart && bIdx < clampedEnd else { continue }
                    let norm = CGFloat(min(1.0, max(0.0, bins[bIdx] / maxVal)))
                    guard norm > 0.05 else { continue }
                    let crestY = plotRect.maxY - norm * usableH
                    for iy in 0...rows {
                        let py = plotRect.minY + CGFloat(iy) * stepY
                        guard py >= crestY + 1.0 && py <= plotRect.maxY - 1.2 else { continue }
                        let h = monthDiurnalHash(ix + 11, iy + 37)
                        let roll = Double(h & 0xFF) / 255.0
                        let depthFrac = Double((py - crestY) / max(1.0, plotRect.maxY - crestY))
                        let prob = (0.55 - 0.25 * depthFrac) * Double(0.45 + 0.55 * norm)
                        if roll < prob {
                            pkDots.addRect(CGRect(x: px, y: py, width: 1.0, height: 1.0))
                        }
                    }
                }
                if !pkDots.isEmpty {
                    context.fill(pkDots, with: .color(theme.accent.opacity(theme.isDark ? 0.72 : 0.62)))
                }

                // Accent vernier stems & crest trace for peak window bins
                var pkStems = Path()
                var pkCrest = Path()
                for i in clampedStart..<clampedEnd {
                    let norm = CGFloat(min(1.0, max(0.0, bins[i] / maxVal)))
                    let x0 = plotRect.minX + CGFloat(i) * binW
                    let cx = x0 + binW * 0.5
                    let topY = plotRect.maxY - norm * usableH
                    if norm > 0.01 {
                        let stemW: CGFloat = 1.6
                        pkStems.addRect(CGRect(x: cx - stemW * 0.5, y: topY, width: stemW, height: plotRect.maxY - topY))
                    }
                    pkCrest.move(to: CGPoint(x: x0, y: topY))
                    pkCrest.addLine(to: CGPoint(x: x0 + binW, y: topY))
                }
                if !pkStems.isEmpty {
                    context.fill(pkStems, with: .color(theme.accent.opacity(theme.isDark ? 0.90 : 0.85)))
                }
                if !pkCrest.isEmpty {
                    context.stroke(pkCrest, with: .color(theme.accent), lineWidth: 1.35)
                }
            }
        }
    }
}
