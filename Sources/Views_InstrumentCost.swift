import SwiftUI
import AppKit

// Cost Tab Specimen Artifact Visualizations:
// Inspired by archival technical prints (Emil Widlund / Polar) & precision optical HUDs (Fred):
// 0. CostInstrumentView — unified specimen header, de-slabbed hairline scope strip & editorial colophon
// 1. TopographicRidgeChart — Hero generative stipple + horizontal scanline + multi-isoline relief field
// 2. BoreholeModelSection — Wide authentic lithology geological core + single cobalt bracket & drafting leaders

// MARK: - 0. Unified Cost Specimen View

struct CostInstrumentView: View {
    let usage: PeriodUsage
    let bundle: CurrentMonthBundle?
    var dailyOverride: [DailyUsage]? = nil
    var selectedScope: Binding<UsagePeriodScope>?
    let year: Int
    let month: Int
    @Binding var focusedModelId: String?

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @Environment(\.telemetryStaticRender) private var isStaticRender
    @Environment(\.telemetryReduceMotion) private var reduceMotion
    @Environment(\.craftHapticsEnabled) private var hapticsEnabled
    @Namespace private var scopeNamespace
    @State private var hoveredScope: UsagePeriodScope? = nil

    private var scopeAnimation: Animation? {
        guard !isStaticRender else { return nil }
        return reduceMotion ? TelemetryMotion.reduced : TelemetryMotion.tabIndicator
    }

    private var activeScope: UsagePeriodScope {
        selectedScope?.wrappedValue ?? .month
    }

    private var dailyBreakdown: [DailyUsage]? {
        bundle?.dailyBreakdown ?? dailyOverride
    }

    private var scopeTitle: String {
        switch activeScope {
        case .today: return loc("periodTodayShort")
        case .week:  return loc("periodWeekShort")
        case .month: return loc("periodMonthShort")
        }
    }

    private var todayDelta: Double? {
        guard activeScope == .today, let daily = dailyBreakdown else { return nil }
        let todayDay = AppDate.gregorian.component(.day, from: Date())
        return UsageTelemetryLogic.costDeltaPercent(todayCost: usage.cost, daily: daily, todayDay: todayDay)
    }

    var body: some View {
        VStack(spacing: 0) {
            specimenHeader

            if let bundle = bundle, let binding = selectedScope {
                HairlineRule(showCrosshairs: false)
                hairlineScopeStrip(bundle: bundle, binding: binding)
            }

            if let daily = dailyBreakdown, !daily.isEmpty {
                HairlineRule(showCrosshairs: true)
                TopographicRidgeChart(
                    data: daily,
                    year: year,
                    month: month,
                    focusedModelId: focusedModelId
                )
            }

            HairlineRule(showCrosshairs: true)

            BoreholeModelSection(
                usage: usage,
                focusedModelId: $focusedModelId
            )

            HairlineRule(showCrosshairs: false)
            specimenColophon
        }
    }

    // MARK: Specimen Header

    private var specimenHeader: some View {
        let parts = splitCurrencyParts(usage.cost)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text("01.")
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.accent)
                Text("\(loc("apiEquivTag")) // \(scopeTitle.uppercased())")
                    .font(.system(size: 8.5, weight: .regular, design: .monospaced))
                    .tracking(1.0)
                    .foregroundColor(theme.inkMuted)

                Spacer(minLength: 4)

                if let delta = todayDelta {
                    let signed = formatSignedPercent(delta)
                    Text(String(format: loc("vs7dAvgFmt"), signed).uppercased())
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .foregroundColor(delta > 0 ? theme.accent : theme.accentSecondary)
                }
            }

            HStack(alignment: .firstTextBaseline) {
                PrecisionHeroNumber(
                    prefix: parts.prefix,
                    whole: parts.whole,
                    fraction: parts.frac,
                    size: 40,
                    weight: .ultraLight
                )

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2.5) {
                    Text("\(formatNumber(usage.totalMessages)) MSG")
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundColor(theme.inkMuted)
                    Text("\(formatTokensShort(usage.totalTokens).uppercased()) TOK")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.inkSecondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: De-Slabbed Hairline Period Index Strip (Zero Duplicate Hero Number)

    private func hairlineScopeStrip(
        bundle: CurrentMonthBundle,
        binding: Binding<UsagePeriodScope>
    ) -> some View {
        let monthTotal = max(0, bundle.month.cost)
        let scopes: [(scope: UsagePeriodScope, title: String, cost: Double)] = [
            (.today, loc("periodTodayShort"), bundle.today.cost),
            (.week,  loc("periodWeekShort"),  bundle.week.cost),
            (.month, loc("periodMonthShort"), bundle.month.cost),
        ]

        return HStack(spacing: 0) {
            ForEach(Array(scopes.enumerated()), id: \.element.scope) { idx, item in
                let isSelected = (item.scope == binding.wrappedValue)
                let isHovered = (item.scope == hoveredScope)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if isSelected {
                            Rectangle()
                                .fill(theme.accent)
                                .frame(width: 4, height: 4)
                        }
                        Text(item.title.uppercased())
                            .font(.system(size: 8, weight: isSelected ? .semibold : .regular, design: .monospaced))
                            .tracking(0.7)
                            .foregroundColor(isSelected ? theme.inkPrimary : theme.inkMuted)
                    }

                    if isSelected {
                        Text(activeScopeSublabel(scope: item.scope, cost: item.cost, monthTotal: monthTotal))
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(theme.accent)
                    } else {
                        Text(formatCost(item.cost))
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(isHovered ? theme.inkPrimary : theme.inkSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    ZStack(alignment: .top) {
                        if isSelected {
                            Rectangle()
                                .fill(theme.surfaceRaised.opacity(theme.isDark ? 0.35 : 0.55))
                                .matchedGeometryEffect(id: "costScopePlate", in: scopeNamespace)
                            Rectangle()
                                .fill(theme.accent)
                                .frame(height: 1.5)
                                .matchedGeometryEffect(id: "costScopeRule", in: scopeNamespace)
                        } else if isHovered {
                            Rectangle()
                                .fill(theme.surfaceRaised.opacity(0.35))
                        }
                    }
                )
                .contentShape(Rectangle())
                .onHover { inside in
                    hoveredScope = inside ? item.scope : (hoveredScope == item.scope ? nil : hoveredScope)
                }
                .onTapGesture {
                    guard binding.wrappedValue != item.scope else { return }
                    CraftEngine.shared.perform(.costStrataShift, enabled: hapticsEnabled)
                    withAnimation(scopeAnimation) {
                        binding.wrappedValue = item.scope
                    }
                }

                if idx < scopes.count - 1 {
                    Rectangle().fill(theme.hairline.opacity(0.8)).frame(width: 1)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .animation(scopeAnimation, value: binding.wrappedValue)
    }

    private func activeScopeSublabel(scope: UsagePeriodScope, cost: Double, monthTotal: Double) -> String {
        switch scope {
        case .today:
            if monthTotal > 0.01 {
                let pct = Int(((cost / monthTotal) * 100.0).rounded())
                return String(format: "%02d%% OF MO", min(100, max(0, pct)))
            }
            return "ACTIVE"
        case .week:
            if monthTotal > 0.01 {
                let pct = Int(((cost / monthTotal) * 100.0).rounded())
                return String(format: "%02d%% OF MO", min(100, max(0, pct)))
            }
            return "7D WINDOW"
        case .month:
            return String(format: "%04d.%02d", year, month)
        }
    }

    // MARK: Editorial Specimen Colophon

    private var specimenColophon: some View {
        HStack(spacing: 6) {
            Text("* \(loc("costApiEquivNote"))")
                .font(.system(size: 8.5, weight: .regular, design: .serif))
                .italic()
                .foregroundColor(theme.inkMuted)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("FIG. 01")
                .font(.system(size: 7.5, weight: .regular, design: .monospaced))
                .tracking(0.8)
                .foregroundColor(theme.inkMuted.opacity(0.75))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

// MARK: - 1. Hero Topographic Relief Field (Stipple + Scanline + Multi-Isoline)

/// Bounded LRU cache for Hermite topographic ridge curves so 60Hz hover and
/// repeated borehole model focus never recompute spline geometry.
private enum TopographicRidgeCache {
    struct Key: Hashable {
        let cents: [Int]
        let layerCount: Int
        let samplesPerDay: Int
    }

    private static let lock = NSLock()
    private static var lru = BoundedLRUState<Key, TopographicRidgeResult>(maxEntries: 12)

    static func ridge(dailyValues: [Double], layerCount: Int, samplesPerDay: Int) -> TopographicRidgeResult {
        let key = Key(
            cents: dailyValues.map { Int(($0 * 1000.0).rounded()) },
            layerCount: layerCount,
            samplesPerDay: samplesPerDay
        )

        lock.lock()
        if let hit = lru.get(key) {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let built = InstrumentMath.buildTopographicRidges(
            dailyValues: dailyValues,
            layerCount: layerCount,
            samplesPerDay: samplesPerDay
        )

        lock.lock()
        lru.set(built, for: key)
        lock.unlock()

        return built
    }
}

struct TopographicRidgeChart: View {
    let data: [DailyUsage]
    let year: Int
    let month: Int
    var focusedModelId: String? = nil

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @Environment(\.telemetryStaticRender) private var isStaticRender
    @Environment(\.telemetryPanelVisible) private var isPanelVisible
    @Environment(\.craftHapticsEnabled) private var hapticsEnabled
    @State private var inspection = ChartInspectionState<String, Int>(scope: "")

    private var inspectionScope: String { "\(year)-\(month)" }
    private var hoveredDay: Int? {
        inspection.scope == inspectionScope ? inspection.target : nil
    }

    private let plotHeight: CGFloat = 158
    private let daysInMonth: Int
    private let dayLookup: [Int: DailyUsage]
    private let dailyCentsKey: [Int]
    private let maxValue: Double
    private let avgValue: Double
    private let ridge: TopographicRidgeResult
    private let focusedRidge: TopographicRidgeResult?
    private let labelDays: [Int]
    private let todayNumberIfViewingCurrentMonth: Int?

    private struct TerrainArtworkKey: Hashable {
        let cents: [Int]
        let avgMilli: Int
        let theme: AGYTheme.CacheKey
    }

    init(data: [DailyUsage], year: Int, month: Int, focusedModelId: String? = nil) {
        self.data = data
        self.year = year
        self.month = month
        self.focusedModelId = focusedModelId

        let totalDays = AppDate.daysInMonth(year: year, month: month) ?? 30
        self.daysInMonth = totalDays

        let lookup = Dictionary(uniqueKeysWithValues: data.map { ($0.day, $0) })
        self.dayLookup = lookup

        let values = (1...totalDays).map { lookup[$0]?.cost ?? 0 }
        self.dailyCentsKey = values.map { Int(($0 * 1000.0).rounded()) }
        self.maxValue = values.max() ?? 0
        self.avgValue = UsageTelemetryLogic.dailyAverage(daily: data, modeIsCost: true)

        self.ridge = TopographicRidgeCache.ridge(
            dailyValues: values,
            layerCount: 8,
            samplesPerDay: 8
        )

        self.focusedRidge = focusedModelId.map { fid in
            let fidLower = fid.lowercased()
            let targetClass = ModelClass.parse(fidLower)
            let fVals = (1...totalDays).map { day -> Double in
                guard let dayModels = lookup[day]?.models else { return 0 }
                if let exact = dayModels.first(where: { $0.id == fid || $0.id.lowercased() == fidLower }) {
                    return exact.cost
                }
                if let cls = targetClass {
                    return dayModels.filter { $0.modelClass == cls }.reduce(0.0) { $0 + $1.cost }
                }
                return 0
            }
            return TopographicRidgeCache.ridge(
                dailyValues: fVals,
                layerCount: 4,
                samplesPerDay: 6
            )
        }

        var labels: Set<Int> = [1, totalDays]
        for d in stride(from: 5, through: max(5, totalDays - 3), by: 5) { labels.insert(d) }
        self.labelDays = labels.sorted()

        let nowComps = AppDate.gregorian.dateComponents([.year, .month, .day], from: Date())
        self.todayNumberIfViewingCurrentMonth = (nowComps.year == year && nowComps.month == month) ? nowComps.day : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow

            GeometryReader { geo in
                ZStack {
                    // Pre-rendered 2x Retina cached base terrain (stipple cloud, clipped scanlines, 8 isolines).
                    // Decoupled from hover AND borehole focus so hovering models/days NEVER redraws 10k dots.
                    CachedTelemetryArtwork(
                        key: TerrainArtworkKey(
                            cents: dailyCentsKey,
                            avgMilli: Int((avgValue * 1000.0).rounded()),
                            theme: theme.cacheKey
                        ),
                        width: geo.size.width,
                        height: geo.size.height
                    ) {
                        StaticTopographicTerrainCanvas(
                            ridge: ridge,
                            avgValue: avgValue,
                            theme: theme
                        )
                    }
                    .opacity(focusedModelId != nil ? 0.24 : 1.0)
                    .allowsHitTesting(false)

                    // Tiny 4-spline sub-terrain overlay mounted ONLY while a Borehole stratum is focused
                    if let fRidge = focusedRidge {
                        FocusedTopographicSubTerrainCanvas(
                            ridge: ridge,
                            focusedRidge: fRidge,
                            theme: theme
                        )
                        .allowsHitTesting(false)
                    }

                    // Lightweight overlay: sky survey crosses, peak HUD, and 60Hz hover crosshair
                    TopographicOverlayCanvas(
                        ridge: ridge,
                        daysInMonth: daysInMonth,
                        hoveredDay: hoveredDay,
                        hoveredCost: hoveredDay.map { dayLookup[$0]?.cost ?? 0 } ?? 0,
                        isRecessed: focusedModelId != nil,
                        theme: theme
                    )
                    .allowsHitTesting(false)

                    // Single continuous O(1) hover tracking rect (replaces 31 per-day tracking views)
                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover(coordinateSpace: .local) { phase in
                            switch phase {
                            case .active(let pt):
                                let w = max(1.0, Double(geo.size.width))
                                let nx = min(0.999999, max(0.0, Double(pt.x) / w))
                                let nextDay = min(daysInMonth, max(1, Int(floor(nx * Double(daysInMonth))) + 1))
                                inspection.syncScope(inspectionScope)
                                if inspection.target != nextDay {
                                    inspection.setTarget(nextDay)
                                    let activeRidge = focusedRidge ?? ridge
                                    let isPeak = activeRidge.peakValue > 0 && activeRidge.peakIndex == (nextDay - 1)
                                    CraftEngine.shared.perform(
                                        isPeak ? .costRidgePeak : .costRidgeDay,
                                        enabled: hapticsEnabled
                                    )
                                }
                            case .ended:
                                if inspection.target != nil {
                                    inspection.reset()
                                }
                            }
                        }
                }
            }
            .frame(height: plotHeight)

            calibratedDayAxis
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 9)
        .onChange(of: inspectionScope) { nextScope in
            inspection.syncScope(nextScope)
        }
        .onChange(of: isPanelVisible) { visible in
            if !visible { inspection.reset() }
        }
    }

    private var headerRow: some View {
        let monthStr = String(format: "%04d.%02d", year, month)
        let avgText = formatCost(avgValue)
        let maxText = formatCost(maxValue)

        return HStack(spacing: 5) {
            Text("01.1")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.accent.opacity(0.9))
            Text("\(loc("topoRidgeTitle")) // \(monthStr)")
                .font(.system(size: 8, weight: .regular, design: .monospaced))
                .tracking(0.8)
                .foregroundColor(theme.inkSecondary)

            Spacer(minLength: 4)

            if let day = hoveredDay, let u = dayLookup[day] {
                let topStr = u.models.max(by: { $0.cost < $1.cost }).map { " · \($0.shortCode)" } ?? ""
                Text(String(format: "D%02d · %@%@", day, formatCostTabular(u.cost), topStr))
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(theme.accent)
            } else if let fid = focusedModelId {
                let code = (ModelClass(rawValue: fid.lowercased()) ?? ModelClass.classify(fid)).shortCode
                Text("\(code) · ISOLATED")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.accent)
            } else {
                HStack(spacing: 3) {
                    Text("\(String(format: loc("avgFmt"), avgText))/D")
                        .foregroundColor((theme.isMultiColorSpectrum ? theme.accentQuaternary : theme.accentSecondary).opacity(theme.isDark ? 0.90 : 0.86))
                    Text("· \(String(format: loc("maxFmt"), maxText))")
                        .foregroundColor(theme.inkMuted)
                }
                .font(.system(size: 8, weight: .regular, design: .monospaced))
                .monospacedDigit()
            }
        }
    }

    private var calibratedDayAxis: some View {
        let labelSet = Set(labelDays)
        let todayDay = todayNumberIfViewingCurrentMonth
        return VStack(spacing: 3) {
            Canvas { context, size in
                let count = max(1, daysInMonth)
                let slotW = size.width / CGFloat(count)
                var minorTicks = Path()
                var majorTicks = Path()
                var todayTick = Path()

                for day in 1...daysInMonth {
                    let cx = (CGFloat(day) - 0.5) * slotW
                    let isMajor = labelSet.contains(day)
                    let isToday = (day == todayDay)
                    let tickH: CGFloat = isMajor ? 4.0 : 2.0
                    let rect = CGRect(x: cx - 0.4, y: 0, width: 0.8, height: tickH)
                    if isToday {
                        todayTick.addRect(rect)
                    } else if isMajor {
                        majorTicks.addRect(rect)
                    } else {
                        minorTicks.addRect(rect)
                    }
                }

                context.fill(minorTicks, with: .color(theme.hairline))
                context.fill(majorTicks, with: .color(theme.hairlineStrong))
                if !todayTick.isEmpty {
                    context.fill(todayTick, with: .color(theme.accent))
                }
            }
            .frame(height: 4)

            GeometryReader { geo in
                let slotW = geo.size.width / CGFloat(max(1, daysInMonth))
                ZStack(alignment: .leading) {
                    ForEach(labelDays, id: \.self) { day in
                        Text(String(format: "%02d", day))
                            .font(.system(size: 7.5, weight: .regular, design: .monospaced))
                            .foregroundColor(day == todayDay ? theme.accent : theme.inkMuted)
                            .position(x: (CGFloat(day) - 0.5) * slotW, y: 4.5)
                    }
                    if let today = todayDay {
                        Rectangle()
                            .fill(theme.accent)
                            .frame(width: 3, height: 3)
                            .position(x: (CGFloat(today) - 0.5) * slotW, y: 10.5)
                    }
                }
            }
            .frame(height: 12)
        }
    }
}

fileprivate func sampleRidgeCrestNormY(outerPoints: [Point2D], at nx: Double) -> Double {
    guard outerPoints.count >= 2 else { return 0 }
    if nx <= outerPoints[0].x { return outerPoints[0].y }
    if nx >= outerPoints[outerPoints.count - 1].x { return outerPoints[outerPoints.count - 1].y }
    var lo = 0
    var hi = outerPoints.count - 1
    while hi - lo > 1 {
        let mid = (lo + hi) >> 1
        if outerPoints[mid].x <= nx { lo = mid } else { hi = mid }
    }
    let p0 = outerPoints[lo]
    let p1 = outerPoints[hi]
    let dx = p1.x - p0.x
    guard dx > 1e-9 else { return p0.y }
    let t = (nx - p0.x) / dx
    return p0.y + (p1.y - p0.y) * t
}

/// Static hover- & focus-independent topographic terrain (AVG rule, clipped scanlines,
/// stipple cloud, 8 isolines, baseline). Pre-rendered once into TelemetryArtworkCache.
private struct StaticTopographicTerrainCanvas: View, Equatable {
    let ridge: TopographicRidgeResult
    let avgValue: Double
    let theme: AGYTheme

    var body: some View {
        Canvas { context, size in
            let topPad: CGFloat = 22
            let baseY = size.height - 1
            let usableH = max(20, baseY - topPad)

            func toPt(_ p: Point2D) -> CGPoint {
                CGPoint(x: CGFloat(p.x) * size.width, y: baseY - CGFloat(p.y) * usableH)
            }

            let outerPoints = ridge.layers.first?.points ?? []

            // 1. Dashed monthly average elevation rule + collision-free edge marginalia
            if ridge.maxValue > 0 && avgValue > 0 {
                let avgRuleColor = theme.isMultiColorSpectrum ? theme.accentQuaternary : theme.accentSecondary
                let ratio = min(1.0, avgValue / ridge.maxValue)
                let ay = baseY - CGFloat(ratio) * usableH
                var dash = Path()
                dash.move(to: CGPoint(x: 0, y: ay))
                dash.addLine(to: CGPoint(x: size.width, y: ay))
                context.stroke(
                    dash,
                    with: .color(avgRuleColor.opacity(theme.isDark ? 0.56 : 0.50)),
                    style: StrokeStyle(lineWidth: 0.75, dash: [2.5, 3.5])
                )
                let leftClear = sampleRidgeCrestNormY(outerPoints: outerPoints, at: 0.04)
                    <= sampleRidgeCrestNormY(outerPoints: outerPoints, at: 0.96)
                let avgTag = Text("AVG")
                    .font(.system(size: 6.5, weight: .medium, design: .monospaced))
                    .foregroundColor(avgRuleColor.opacity(theme.isDark ? 0.90 : 0.84))
                context.draw(
                    avgTag,
                    at: CGPoint(x: leftClear ? 2 : size.width - 2, y: ay - 5),
                    anchor: leftClear ? .leading : .trailing
                )
            }

            // 2. Generative Topographic Body: Scanline Hatch + Stipple Particle Field + 8 Isolines
            if outerPoints.count >= 2 {
                var silhouette = Path()
                let firstPt = toPt(outerPoints[0])
                silhouette.move(to: CGPoint(x: firstPt.x, y: baseY))
                for pt in outerPoints { silhouette.addLine(to: toPt(pt)) }
                silhouette.addLine(to: CGPoint(x: toPt(outerPoints[outerPoints.count - 1]).x, y: baseY))
                silhouette.closeSubpath()

                // 2a. Tonal depth wash: 4-color Google spectrum (Blue -> Red -> Yellow -> Green) or 2-color duotone
                let washStops: [Gradient.Stop] = theme.isMultiColorSpectrum
                    ? [
                        .init(color: theme.accent.opacity(theme.isDark ? 0.16 : 0.095), location: 0.0),
                        .init(color: theme.accentSecondary.opacity(theme.isDark ? 0.12 : 0.075), location: 0.36),
                        .init(color: theme.accentTertiary.opacity(theme.isDark ? 0.11 : 0.07), location: 0.68),
                        .init(color: theme.accentQuaternary.opacity(theme.isDark ? 0.08 : 0.05), location: 1.0),
                    ]
                    : [
                        .init(color: theme.accent.opacity(theme.isDark ? 0.15 : 0.09), location: 0.0),
                        .init(color: theme.accentSecondary.opacity(theme.isDark ? 0.10 : 0.065), location: 0.56),
                        .init(color: theme.accentSecondary.opacity(0.012), location: 1.0),
                    ]
                context.fill(
                    silhouette,
                    with: .linearGradient(
                        Gradient(stops: washStops),
                        startPoint: CGPoint(x: 0, y: topPad),
                        endPoint: CGPoint(x: 0, y: baseY)
                    )
                )

                // 2b. Horizontal plotter scanline relief clipped to silhouette (4 elevation bands)
                context.drawLayer { layer in
                    layer.clip(to: silhouette)
                    let scanStep: CGFloat = 3.6
                    let segLen: CGFloat = 5.5
                    let gapLen: CGFloat = 3.2
                    var bands = [Path(), Path(), Path(), Path()]
                    var sy = topPad + 1
                    var rowIdx = 0
                    while sy < baseY - 2 {
                        let elevFrac = Double(max(0, min(1, (baseY - sy) / usableH)))
                        let bandIdx = min(3, max(0, Int(elevFrac * 4.0)))
                        let phaseOffset = CGFloat((rowIdx * 3) % 7) * 1.1
                        var x = -phaseOffset
                        while x < size.width {
                            let x0 = max(0, x)
                            let x1 = min(size.width, x + segLen)
                            if x1 > x0 {
                                bands[bandIdx].move(to: CGPoint(x: x0, y: sy))
                                bands[bandIdx].addLine(to: CGPoint(x: x1, y: sy))
                            }
                            x += segLen + gapLen
                        }
                        sy += scanStep
                        rowIdx += 1
                    }
                    let bandColors: [Color] = theme.isMultiColorSpectrum
                        ? [
                            theme.accentQuaternary.opacity(theme.isDark ? 0.22 : 0.16), // Green valleys
                            theme.accentTertiary.opacity(theme.isDark ? 0.24 : 0.18),   // Yellow lower-mid
                            theme.accentSecondary.opacity(theme.isDark ? 0.22 : 0.16),  // Red upper-mid
                            theme.accent.opacity(theme.isDark ? 0.26 : 0.18),           // Blue summit
                        ]
                        : [
                            theme.accentSecondary.opacity(theme.isDark ? 0.14 : 0.11),
                            theme.accentSecondary.opacity(theme.isDark ? 0.19 : 0.15),
                            theme.inkPrimary.opacity(0.098),
                            theme.accent.opacity(theme.isDark ? 0.22 : 0.16),
                        ]
                    for idx in 0..<4 where !bands[idx].isEmpty {
                        layer.stroke(
                            bands[idx],
                            with: .color(bandColors[idx]),
                            lineWidth: 0.65
                        )
                    }
                }

                // 2c. Deterministic organic stipple particle cloud along ridge crest (batched Paths)
                let stepX: CGFloat = 2.3
                let stepY: CGFloat = 2.3
                let cols = Int(size.width / stepX)
                let rows = Int((baseY - topPad + 4) / stepY)
                var peakDots = Path()
                var denseDots = Path()
                var midLowDots = Path()
                var valleyDots = Path()

                for ix in 0...cols {
                    let px = CGFloat(ix) * stepX
                    let nx = Double(px / max(1, size.width))
                    let crestNorm = sampleRidgeCrestNormY(outerPoints: outerPoints, at: nx)
                    guard crestNorm > 0.025 else { continue }
                    let crestY = baseY - CGFloat(crestNorm) * usableH

                    let minRow = max(0, Int((crestY - topPad - 3) / stepY))
                    let maxRow = min(rows, Int((baseY - topPad) / stepY))
                    for iy in minRow...maxRow {
                        let basePy = topPad + CGFloat(iy) * stepY
                        let h = Self.deterministicHash(ix, iy)
                        let jx = (Double(h & 0xFF) / 255.0 - 0.5) * Double(stepX) * 0.92
                        let jy = (Double((h >> 8) & 0xFF) / 255.0 - 0.5) * Double(stepY) * 0.92
                        let gx = px + CGFloat(jx)
                        let gy = basePy + CGFloat(jy)
                        guard gx >= 0, gx <= size.width, gy <= baseY - 1 else { continue }

                        let distBelow = gy - crestY
                        let prob: Double
                        if distBelow < 0 {
                            let above = Double(-distBelow)
                            prob = crestNorm > 0.35 ? max(0, (1.0 - above / 3.4) * 0.34 * crestNorm) : 0
                        } else {
                            let d = Double(distBelow)
                            let band = exp(-d / (17.0 + 20.0 * crestNorm))
                            prob = min(0.90, band * (0.40 + 0.56 * crestNorm))
                        }

                        let roll = Double((h >> 16) & 0x3FF) / 1023.0
                        if roll < prob {
                            let dotSize: CGFloat = ((h >> 26) & 1 == 0) ? 1.0 : 1.3
                            let rect = CGRect(x: gx, y: gy, width: dotSize, height: dotSize)
                            if theme.isMultiColorSpectrum {
                                let elev = Double(max(0, min(1, (baseY - gy) / usableH)))
                                if elev >= 0.72 {
                                    peakDots.addRect(rect)      // Blue summit
                                } else if elev >= 0.48 {
                                    denseDots.addRect(rect)     // Red upper ridge
                                } else if elev >= 0.24 {
                                    midLowDots.addRect(rect)    // Yellow slope
                                } else {
                                    valleyDots.addRect(rect)    // Green valley
                                }
                            } else {
                                if distBelow >= -2 && distBelow < 10 && crestNorm >= 0.70 {
                                    peakDots.addRect(rect)
                                } else if distBelow >= 0 && distBelow < 13 {
                                    denseDots.addRect(rect)
                                } else {
                                    valleyDots.addRect(rect)
                                }
                            }
                        }
                    }
                }

                if !valleyDots.isEmpty {
                    let c = theme.isMultiColorSpectrum ? theme.accentQuaternary : theme.accentSecondary
                    context.fill(
                        valleyDots,
                        with: .color(c.opacity(theme.isDark ? 0.56 : 0.48))
                    )
                }
                if !midLowDots.isEmpty {
                    context.fill(
                        midLowDots,
                        with: .color(theme.accentTertiary.opacity(theme.isDark ? 0.64 : 0.56))
                    )
                }
                if !denseDots.isEmpty {
                    let c = theme.isMultiColorSpectrum ? theme.accentSecondary : theme.inkPrimary
                    context.fill(
                        denseDots,
                        with: .color(c.opacity(theme.isDark ? 0.68 : 0.60))
                    )
                }
                if !peakDots.isEmpty {
                    context.fill(
                        peakDots,
                        with: .color(theme.accent.opacity(theme.isDark ? 0.88 : 0.80))
                    )
                }

                // 2d. 7 silky internal elevation isolines (Green -> Yellow -> Red -> Blue on Google; Color 2 -> Color 1 on duotone)
                for layer in ridge.layers.dropFirst().reversed() {
                    guard layer.points.count >= 2 else { continue }
                    var iso = Path()
                    iso.move(to: toPt(layer.points[0]))
                    for pt in layer.points.dropFirst() { iso.addLine(to: toPt(pt)) }
                    let isoColor: Color
                    if theme.isMultiColorSpectrum {
                        let base = theme.elevationColor(normalized: layer.factor)
                        let alpha = (theme.isDark ? 0.44 : 0.40) + 0.30 * layer.factor
                        isoColor = base.opacity(alpha)
                    } else if layer.factor < 0.72 {
                        let norm = max(0, min(1, layer.factor / 0.72))
                        let alpha = 0.28 + 0.26 * norm
                        isoColor = theme.accentSecondary.opacity(alpha)
                    } else {
                        let alpha = (theme.isDark ? 0.34 : 0.28) + 0.24 * layer.factor
                        isoColor = theme.accent.opacity(alpha)
                    }
                    context.stroke(iso, with: .color(isoColor), lineWidth: 0.70)
                }

                // 2e. Primary ridge silhouette line (+ Color 1 peak crest glow & vertical shift)
                var crestPath = Path()
                crestPath.move(to: firstPt)
                for pt in outerPoints.dropFirst() { crestPath.addLine(to: toPt(pt)) }

                context.stroke(
                    crestPath,
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: theme.accent.opacity(theme.isDark ? 0.28 : 0.14), location: 0.0),
                            .init(color: theme.accent.opacity(0.0), location: 0.65),
                        ]),
                        startPoint: CGPoint(x: 0, y: topPad),
                        endPoint: CGPoint(x: 0, y: baseY)
                    ),
                    lineWidth: theme.isDark ? 4.5 : 3.0
                )
                if theme.isDark {
                    context.stroke(crestPath, with: .color(theme.inkPrimary.opacity(0.22)), lineWidth: 2.0)
                }
                let crestStops: [Gradient.Stop] = theme.isMultiColorSpectrum
                    ? [
                        .init(color: theme.accent, location: 0.0),
                        .init(color: theme.accentSecondary, location: 0.40),
                        .init(color: theme.accentTertiary, location: 0.72),
                        .init(color: theme.accentQuaternary, location: 1.0),
                    ]
                    : [
                        .init(color: theme.accent, location: 0.0),
                        .init(color: theme.inkPrimary.opacity(0.90), location: 0.58),
                        .init(color: theme.accentSecondary.opacity(0.82), location: 1.0),
                    ]
                context.stroke(
                    crestPath,
                    with: .linearGradient(
                        Gradient(stops: crestStops),
                        startPoint: CGPoint(x: 0, y: topPad),
                        endPoint: CGPoint(x: 0, y: baseY)
                    ),
                    lineWidth: 1.15
                )
            }

            // 3. Crisp calibrated baseline
            context.fill(
                Path(CGRect(x: 0, y: baseY, width: size.width, height: 0.85)),
                with: .color(theme.hairlineStrong)
            )
        }
    }

    private static func deterministicHash(_ x: Int, _ y: Int) -> UInt32 {
        var h = UInt32(truncatingIfNeeded: x &* 374761393 &+ y &* 668265263)
        h = (h ^ (h >> 13)) &* 1274126177
        return h ^ (h >> 16)
    }
}

/// Lightweight 4-spline isolated model sub-terrain overlay mounted only during Borehole focus.
private struct FocusedTopographicSubTerrainCanvas: View {
    let ridge: TopographicRidgeResult
    let focusedRidge: TopographicRidgeResult
    let theme: AGYTheme

    var body: some View {
        Canvas { context, size in
            let topPad: CGFloat = 22
            let baseY = size.height - 1
            let usableH = max(20, baseY - topPad)

            guard ridge.maxValue > 0,
                  focusedRidge.maxValue > 0,
                  let fOuter = focusedRidge.layers.first,
                  fOuter.points.count >= 2 else { return }

            let scale = min(1.0, focusedRidge.maxValue / ridge.maxValue)
            func toFocusedPt(_ p: Point2D) -> CGPoint {
                CGPoint(x: CGFloat(p.x) * size.width, y: baseY - CGFloat(p.y * scale) * usableH)
            }

            var fArea = Path()
            let fp0 = toFocusedPt(fOuter.points[0])
            fArea.move(to: CGPoint(x: fp0.x, y: baseY))
            for pt in fOuter.points { fArea.addLine(to: toFocusedPt(pt)) }
            fArea.addLine(to: CGPoint(x: toFocusedPt(fOuter.points[fOuter.points.count - 1]).x, y: baseY))
            fArea.closeSubpath()

            context.fill(
                fArea,
                with: .linearGradient(
                    Gradient(colors: [
                        theme.accent.opacity(theme.isDark ? 0.30 : 0.22),
                        theme.accent.opacity(0.03),
                    ]),
                    startPoint: CGPoint(x: 0, y: topPad),
                    endPoint: CGPoint(x: 0, y: baseY)
                )
            )

            for sub in focusedRidge.layers.dropFirst() {
                guard sub.points.count >= 2 else { continue }
                var subPath = Path()
                subPath.move(to: toFocusedPt(sub.points[0]))
                for pt in sub.points.dropFirst() { subPath.addLine(to: toFocusedPt(pt)) }
                context.stroke(subPath, with: .color(theme.accent.opacity(0.35 * sub.factor)), lineWidth: 0.7)
            }

            var fCrest = Path()
            fCrest.move(to: fp0)
            for pt in fOuter.points.dropFirst() { fCrest.addLine(to: toFocusedPt(pt)) }
            if theme.isDark {
                context.stroke(fCrest, with: .color(theme.accent.opacity(0.32)), lineWidth: 3.8)
            }
            context.stroke(fCrest, with: .color(theme.accent), lineWidth: 1.4)
        }
    }
}

/// Lightweight overlay for sky survey calibration crosses, idle Peak Target Lock HUD,
/// and 60Hz interactive hover crosshair.
private struct TopographicOverlayCanvas: View {
    let ridge: TopographicRidgeResult
    let daysInMonth: Int
    let hoveredDay: Int?
    let hoveredCost: Double
    let isRecessed: Bool
    let theme: AGYTheme

    var body: some View {
        Canvas { context, size in
            let topPad: CGFloat = 22
            let baseY = size.height - 1
            let usableH = max(20, baseY - topPad)
            let outerPoints = ridge.layers.first?.points ?? []

            func toPt(_ p: Point2D) -> CGPoint {
                CGPoint(x: CGFloat(p.x) * size.width, y: baseY - CGFloat(p.y) * usableH)
            }

            // Pre-compute peak HUD exclusion rect so sky calibration `+` never collides with callout text
            let peakLabelRect: CGRect? = {
                guard hoveredDay == nil, !isRecessed,
                      let pIdx = ridge.peakIndex, pIdx < ridge.dayAnchors.count else { return nil }
                let anchor = ridge.dayAnchors[pIdx]
                let peakPt = toPt(anchor)
                let labelRight = anchor.x < 0.62
                let elbowX = peakPt.x + (labelRight ? 18 : -18)
                let elbowY = max(11, peakPt.y - 6)
                let textX = labelRight ? min(size.width - 2, elbowX + 10) : max(2, elbowX - 10)
                let boxW: CGFloat = 94
                let minX = labelRight ? (textX - 6) : (textX - boxW)
                return CGRect(x: minX, y: elbowY - 12, width: boxW + 8, height: 32)
            }()

            // 1. Batched coordinate-anchored survey `+` calibration crosses in clear sky above the ridge
            var skyCrosses = Path()
            let gridDays = stride(from: 5, through: max(5, daysInMonth - 2), by: 5)
            let gridElevs: [Double] = [0.34, 0.67, 0.96]
            for d in gridDays {
                let nx = (Double(d) - 0.5) / Double(max(1, daysInMonth))
                let crestY = baseY - CGFloat(sampleRidgeCrestNormY(outerPoints: outerPoints, at: nx)) * usableH
                let mx = CGFloat(nx) * size.width
                for elev in gridElevs {
                    let my = baseY - CGFloat(elev) * usableH
                    guard my < crestY - 13 else { continue }
                    if let excl = peakLabelRect, excl.contains(CGPoint(x: mx, y: my)) { continue }
                    skyCrosses.move(to: CGPoint(x: mx - 2.2, y: my))
                    skyCrosses.addLine(to: CGPoint(x: mx + 2.2, y: my))
                    skyCrosses.move(to: CGPoint(x: mx, y: my - 2.2))
                    skyCrosses.addLine(to: CGPoint(x: mx, y: my + 2.2))
                }
            }
            if !skyCrosses.isEmpty {
                context.stroke(skyCrosses, with: .color(theme.accentSecondary.opacity(theme.isDark ? 0.44 : 0.36)), lineWidth: 0.75)
            }

            // 2. Peak Target Lock HUD (1% Cobalt Accent + Fred micro-coordinates)
            if hoveredDay == nil,
               !isRecessed,
               let pIdx = ridge.peakIndex,
               pIdx < ridge.dayAnchors.count {
                let anchor = ridge.dayAnchors[pIdx]
                let peakPt = toPt(anchor)

                if theme.isDark {
                    context.fill(
                        Path(ellipseIn: CGRect(x: peakPt.x - 8, y: peakPt.y - 8, width: 16, height: 16)),
                        with: .color(theme.accent.opacity(0.18))
                    )
                }

                var stem = Path()
                stem.move(to: CGPoint(x: peakPt.x, y: peakPt.y + 6.5))
                stem.addLine(to: CGPoint(x: peakPt.x, y: baseY))
                context.stroke(
                    stem,
                    with: .color(theme.accent.opacity(0.32)),
                    style: StrokeStyle(lineWidth: 0.75, dash: [2, 2.5])
                )

                drawHUDReticle(in: &context, center: peakPt, radius: 6.5, color: theme.accent.opacity(0.9))
                context.fill(
                    Path(CGRect(x: peakPt.x - 1.75, y: peakPt.y - 1.75, width: 3.5, height: 3.5)),
                    with: .color(theme.accent)
                )

                let labelRight = anchor.x < 0.62
                let elbowX = peakPt.x + (labelRight ? 18 : -18)
                let elbowY = max(11, peakPt.y - 6)
                var leader = Path()
                leader.move(to: CGPoint(x: peakPt.x + (labelRight ? 7.5 : -7.5), y: peakPt.y))
                leader.addLine(to: CGPoint(x: elbowX, y: elbowY))
                leader.addLine(to: CGPoint(x: elbowX + (labelRight ? 7 : -7), y: elbowY))
                context.stroke(leader, with: .color(theme.accent.opacity(0.75)), lineWidth: 0.75)

                let textX = labelRight
                    ? min(size.width - 2, elbowX + 10)
                    : max(2, elbowX - 10)
                let align: UnitPoint = labelRight ? .leading : .trailing

                let line1 = Text(String(format: "PK.%02d  %@", pIdx + 1, formatCost(ridge.peakValue)))
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.accent)
                let line2 = Text(String(format: "X%.2f  Y%.2f", anchor.x, anchor.y))
                    .font(.system(size: 6.8, weight: .regular, design: .monospaced))
                    .foregroundColor(theme.inkMuted)

                context.draw(line1, at: CGPoint(x: textX, y: elbowY - 1), anchor: align)
                context.draw(line2, at: CGPoint(x: textX, y: elbowY + 8.5), anchor: align)
            }

            // 3. Interactive Hover Crosshair + Magnetic Vertex Reticle Lock
            if let day = hoveredDay, day >= 1, day <= ridge.dayAnchors.count {
                let anchor = ridge.dayAnchors[day - 1]
                let pt = toPt(anchor)

                var vline = Path()
                vline.move(to: CGPoint(x: pt.x, y: 0))
                vline.addLine(to: CGPoint(x: pt.x, y: baseY))
                context.stroke(vline, with: .color(theme.accent.opacity(0.55)), lineWidth: 0.75)

                var hline = Path()
                hline.move(to: CGPoint(x: 0, y: pt.y))
                hline.addLine(to: CGPoint(x: size.width, y: pt.y))
                context.stroke(
                    hline,
                    with: .color(theme.accent.opacity(0.36)),
                    style: StrokeStyle(lineWidth: 0.75, dash: [2, 2.5])
                )

                var stem = Path()
                stem.move(to: CGPoint(x: pt.x, y: pt.y))
                stem.addLine(to: CGPoint(x: pt.x, y: baseY))
                context.stroke(stem, with: .color(theme.accent), lineWidth: 1.25)

                drawHUDReticle(in: &context, center: pt, radius: 6.5, color: theme.accent)
                context.fill(
                    Path(CGRect(x: pt.x - 2, y: pt.y - 2, width: 4, height: 4)),
                    with: .color(theme.accent)
                )

                let labelRight = anchor.x < 0.62
                let tagX = pt.x + (labelRight ? 11 : -11)
                let tagY = max(12, min(baseY - 18, pt.y - 7))
                let align: UnitPoint = labelRight ? .leading : .trailing

                let hudLine1 = Text(String(format: "D%02d  %@", day, formatCostTabular(hoveredCost)))
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.accent)
                let hudLine2 = Text(String(format: "X%.2f  Y%.2f", anchor.x, anchor.y))
                    .font(.system(size: 6.8, weight: .regular, design: .monospaced))
                    .foregroundColor(theme.inkSecondary)

                context.draw(hudLine1, at: CGPoint(x: tagX, y: tagY), anchor: align)
                context.draw(hudLine2, at: CGPoint(x: tagX, y: tagY + 9), anchor: align)
            }
        }
    }

    private func drawHUDReticle(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat, color: Color) {
        let len: CGFloat = 3.2
        let minX = center.x - radius, maxX = center.x + radius
        let minY = center.y - radius, maxY = center.y + radius
        var p = Path()
        p.move(to: CGPoint(x: minX, y: minY + len)); p.addLine(to: CGPoint(x: minX, y: minY)); p.addLine(to: CGPoint(x: minX + len, y: minY))
        p.move(to: CGPoint(x: maxX - len, y: minY)); p.addLine(to: CGPoint(x: maxX, y: minY)); p.addLine(to: CGPoint(x: maxX, y: minY + len))
        p.move(to: CGPoint(x: minX, y: maxY - len)); p.addLine(to: CGPoint(x: minX, y: maxY)); p.addLine(to: CGPoint(x: minX + len, y: maxY))
        p.move(to: CGPoint(x: maxX - len, y: maxY)); p.addLine(to: CGPoint(x: maxX, y: maxY)); p.addLine(to: CGPoint(x: maxX, y: maxY - len))
        context.stroke(p, with: .color(color), lineWidth: 0.85)
    }
}

// MARK: - 2. Authentic Geological Lithology Borehole Specimen (Ref 3)

struct BoreholeModelSection: View {
    let usage: PeriodUsage
    @Binding var focusedModelId: String?

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @Environment(\.telemetryStaticRender) private var isStaticRender
    @Environment(\.craftHapticsEnabled) private var hapticsEnabled
    @State private var focusState = ModelFocusState()

    private var visibleModels: [ModelUsage] {
        usage.models.filter { $0.cost >= 0.005 }
    }

    private let rowHeight: CGFloat = 21
    private let depthRulerWidth: CGFloat = 22
    private let coreWidth: CGFloat = 52
    private let bracketAllowance: CGFloat = 6
    private let leaderWidth: CGFloat = 22

    var body: some View {
        let models = visibleModels
        let totalCost = usage.cost > 0 ? usage.cost : models.reduce(0.0) { $0 + $1.cost }
        let slices = InstrumentMath.buildBoreholeSlices(
            items: models.map { ($0.id, $0.cost) },
            minSliceFraction: 0.085
        )
        let diagramHeight = max(68, CGFloat(models.count) * rowHeight)
        let dominantId = models.max(by: { $0.cost < $1.cost })?.id
        let bracketTargetId = focusedModelId ?? dominantId

        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Text("01.2")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.accent.opacity(0.9))
                Text(loc("boreholeTitle"))
                    .font(.system(size: 8, weight: .regular, design: .monospaced))
                    .tracking(0.8)
                    .foregroundColor(theme.inkSecondary)

                Spacer(minLength: 4)

                if let fid = focusedModelId, let fm = models.first(where: { $0.id == fid }) {
                    let pct = totalCost > 0 ? (fm.cost / totalCost) * 100.0 : 0
                    Text(String(format: "%@ · %.1f%%", fm.shortCode, pct))
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.accent)
                } else {
                    Text(String(format: "%02d STRATA", models.count))
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.accentSecondary.opacity(theme.isDark ? 0.88 : 0.82))
                }
            }

            if models.isEmpty {
                Text(loc("noData").uppercased())
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(theme.inkMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 14)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    boreholeCoreColumn(
                        models: models,
                        slices: slices,
                        bracketTargetId: bracketTargetId,
                        height: diagramHeight
                    )

                    leaderLinesCanvas(
                        models: models,
                        slices: slices,
                        bracketTargetId: bracketTargetId,
                        height: diagramHeight
                    )
                    .frame(width: leaderWidth, height: diagramHeight)

                    VStack(spacing: 0) {
                        ForEach(Array(models.enumerated()), id: \.element.id) { idx, m in
                            modelCalloutRow(
                                m,
                                index: idx,
                                totalCost: totalCost,
                                isBracketed: m.id == bracketTargetId
                            )
                            .frame(height: rowHeight)
                        }
                    }
                    .frame(height: diagramHeight, alignment: .top)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 11)
        .onChange(of: focusedModelId) { newValue in
            if newValue == nil {
                focusState.reset()
            }
        }
        .onChange(of: models.map(\.id)) { ids in
            let valid = Set(ids)
            focusState.reconcile(validIds: valid)
            if let fid = focusedModelId, !valid.contains(fid) {
                focusedModelId = focusState.effectiveFocusedId
            }
        }
        .onDisappear {
            focusState.reset()
            if focusedModelId != nil {
                focusedModelId = nil
            }
        }
    }

    private struct BoreholeStratumSpec: Hashable {
        let id: String
        let modelClass: ModelClass
        let yStart: Double
        let yEnd: Double
    }

    private struct BoreholeArtworkKey: Hashable {
        let strata: [BoreholeStratumSpec]
        let theme: AGYTheme.CacheKey
    }

    /// Equatable hover-independent geological rock lithology layer cached in a GPU texture.
    /// Hovering strata NEVER re-runs sandstone stipple, sinusoidal shale waves, or pebble loops.
    private struct BoreholeStaticLithologyCanvas: View, Equatable {
        let strata: [BoreholeStratumSpec]
        let depthRulerWidth: CGFloat
        let coreWidth: CGFloat
        let theme: AGYTheme

        var body: some View {
            Canvas { context, size in
                let coreX = depthRulerWidth
                let innerH = size.height - 1
                let coreRect = CGRect(x: coreX, y: 0.5, width: coreWidth, height: innerH)
                context.fill(Path(coreRect), with: .color(theme.surface))

                // 1. Left-margin geological depth ruler (00 / 50 / 100 + minor ticks, batched in Color 2)
                var majorDepthTicks = Path()
                var minorDepthTicks = Path()
                for step in 0...4 {
                    let frac = CGFloat(step) / 4.0
                    let ty = 0.5 + innerH * frac
                    let isMajor = (step == 0 || step == 2 || step == 4)
                    let tickLen: CGFloat = isMajor ? 5.0 : 3.0
                    if isMajor {
                        majorDepthTicks.move(to: CGPoint(x: coreX - tickLen, y: ty))
                        majorDepthTicks.addLine(to: CGPoint(x: coreX, y: ty))
                        let depthLabel = Text(String(format: "%02d", step * 25))
                            .font(.system(size: 6.5, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.accentSecondary.opacity(theme.isDark ? 0.82 : 0.76))
                        let labelY = step == 0 ? ty + 3.5 : (step == 4 ? ty - 3.5 : ty)
                        context.draw(depthLabel, at: CGPoint(x: coreX - 7, y: labelY), anchor: .trailing)
                    } else {
                        minorDepthTicks.move(to: CGPoint(x: coreX - tickLen, y: ty))
                        minorDepthTicks.addLine(to: CGPoint(x: coreX, y: ty))
                    }
                }
                context.stroke(minorDepthTicks, with: .color(theme.accentSecondary.opacity(theme.isDark ? 0.30 : 0.26)), lineWidth: 0.75)
                context.stroke(majorDepthTicks, with: .color(theme.accentSecondary.opacity(theme.isDark ? 0.58 : 0.50)), lineWidth: 0.75)

                // 2. Archival lithological strata layers (monochrome on .monolith; Color 1 x Color 2 duotone on color presets)
                let usesMono = theme.preset.usesMonochromeStrata
                var seams = Path()
                for stratum in strata {
                    let y0 = 0.5 + CGFloat(stratum.yStart) * innerH
                    let y1 = 0.5 + CGFloat(stratum.yEnd) * innerH
                    let rect = CGRect(x: coreX + 0.5, y: y0, width: coreWidth - 1, height: max(1, y1 - y0))
                    let stratumInk: Color = usesMono
                        ? theme.inkPrimary.opacity(0.80)
                        : theme.modelColor(stratum.modelClass).opacity(theme.isDark ? 0.92 : 0.88)

                    var ctx = context
                    BoreholeModelSection.drawLithologyStratum(
                        in: &ctx,
                        rect: rect,
                        modelClass: stratum.modelClass,
                        ink: stratumInk,
                        isDark: theme.isDark
                    )

                    if stratum.yEnd < 0.999 {
                        seams.move(to: CGPoint(x: coreX, y: y1))
                        seams.addLine(to: CGPoint(x: coreX + coreWidth, y: y1))
                    }
                }
                if !seams.isEmpty {
                    context.stroke(seams, with: .color(theme.inkPrimary.opacity(0.45)), lineWidth: 0.75)
                }

                // 3. Archival borehole outer casing hairline
                context.stroke(Path(coreRect), with: .color(theme.hairlineStrong.opacity(0.95)), lineWidth: 0.85)
            }
        }
    }

    private func boreholeCoreColumn(
        models: [ModelUsage],
        slices: [BoreholeSlice],
        bracketTargetId: String?,
        height: CGFloat
    ) -> some View {
        let modelById = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        let strata: [BoreholeStratumSpec] = slices.compactMap { s in
            guard let m = modelById[s.id] else { return nil }
            return BoreholeStratumSpec(id: s.id, modelClass: m.modelClass, yStart: s.yStart, yEnd: s.yEnd)
        }
        let coreX = depthRulerWidth

        let columnWidth = depthRulerWidth + coreWidth + bracketAllowance

        return ZStack(alignment: .topLeading) {
            // Pre-rendered 2x Retina cached rock lithology layer (zero procedural redraws on hover/open)
            CachedTelemetryArtwork(
                key: BoreholeArtworkKey(strata: strata, theme: theme.cacheKey),
                width: columnWidth,
                height: height
            ) {
                BoreholeStaticLithologyCanvas(
                    strata: strata,
                    depthRulerWidth: depthRulerWidth,
                    coreWidth: coreWidth,
                    theme: theme
                )
            }
            .allowsHitTesting(false)

            // Lightweight hover overlay: non-focused dim wash + Emil's single exterior cobalt bracket
            Canvas { context, size in
                let innerH = size.height - 1
                var dimRects = Path()
                for stratum in strata {
                    let y0 = 0.5 + CGFloat(stratum.yStart) * innerH
                    let y1 = 0.5 + CGFloat(stratum.yEnd) * innerH

                    if let fid = focusedModelId, fid != stratum.id {
                        dimRects.addRect(CGRect(x: coreX + 0.5, y: y0, width: coreWidth - 1, height: max(1, y1 - y0)))
                    }

                    if stratum.id == bracketTargetId {
                        let bx = coreX + coreWidth + 2.5
                        let by = y0 + 0.5
                        let bh = max(3, (y1 - y0) - 1.0)
                        context.fill(
                            Path(CGRect(x: bx, y: by, width: 2.2, height: bh)),
                            with: .color(theme.accent)
                        )
                    }
                }
                if !dimRects.isEmpty {
                    context.fill(dimRects, with: .color(theme.surface.opacity(theme.isDark ? 0.62 : 0.66)))
                }
            }
            .allowsHitTesting(false)
        }
        .frame(width: depthRulerWidth + coreWidth + bracketAllowance, height: height)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let pt):
                let ny = min(1.0, max(0.0, Double(pt.y / max(1, height))))
                let hit = InstrumentMath.hitTestBoreholeSlice(normalizedY: ny, slices: slices)
                if focusState.columnHoveredId != hit {
                    focusState.setColumnHover(hit)
                }
                let nextFocus = focusState.effectiveFocusedId
                if focusedModelId != nextFocus {
                    focusedModelId = nextFocus
                    if nextFocus != nil {
                        CraftEngine.shared.perform(.costStrataShift, enabled: hapticsEnabled)
                    }
                }
            case .ended:
                if focusState.columnHoveredId != nil {
                    focusState.setColumnHover(nil)
                }
                let nextFocus = focusState.effectiveFocusedId
                if focusedModelId != nextFocus {
                    focusedModelId = nextFocus
                }
            }
        }
    }

    /// Hand-crafted archival geological lithology patterns modeled after Emil Widlund's Borehole poster.
    private static func drawLithologyStratum(
        in context: inout GraphicsContext,
        rect: CGRect,
        modelClass: ModelClass,
        ink: Color,
        isDark: Bool
    ) {
        guard rect.width > 1, rect.height > 1 else { return }

        context.drawLayer { layer in
            layer.clip(to: Path(rect))

            switch modelClass {
            case .carbon:
                // Dense fine-grain sandstone / basalt stipple
                layer.fill(Path(rect), with: .color(ink.opacity(isDark ? 0.14 : 0.08)))
                var dots = Path()
                let step: CGFloat = 2.8
                let cols = Int(rect.width / step) + 1
                let rows = Int(rect.height / step) + 1
                for r in 0...rows {
                    for c in 0...cols {
                        let h = lithoHash(c, r, 11)
                        guard (h & 7) < 5 else { continue }
                        let jx = (CGFloat((h >> 3) & 0xF) / 15.0 - 0.5) * 1.8
                        let jy = (CGFloat((h >> 7) & 0xF) / 15.0 - 0.5) * 1.8
                        let px = rect.minX + CGFloat(c) * step + jx
                        let py = rect.minY + CGFloat(r) * step + jy
                        let sz: CGFloat = ((h >> 12) & 1 == 0) ? 0.9 : 1.2
                        dots.addRect(CGRect(x: px, y: py, width: sz, height: sz))
                    }
                }
                layer.fill(dots, with: .color(ink.opacity(0.68)))

            case .argon:
                // Undulating sinusoidal sedimentary shale bedding
                layer.fill(Path(rect), with: .color(ink.opacity(isDark ? 0.08 : 0.045)))
                var waves = Path()
                var y = rect.minY + 2.2
                var row = 0
                while y < rect.maxY + 2 {
                    let phase = Double(row) * 1.15
                    var x = rect.minX - 2
                    var first = true
                    while x <= rect.maxX + 2 {
                        let wy = y + CGFloat(sin(Double(x) * 0.24 + phase)) * 1.25
                        if first {
                            waves.move(to: CGPoint(x: x, y: wy))
                            first = false
                        } else {
                            waves.addLine(to: CGPoint(x: x, y: wy))
                        }
                        x += 2.0
                    }
                    y += 3.4
                    row += 1
                }
                layer.stroke(waves, with: .color(ink.opacity(0.62)), lineWidth: 0.72)

            case .neon:
                // Cross-bedded diagonal sandstone hatch
                layer.fill(Path(rect), with: .color(ink.opacity(isDark ? 0.09 : 0.05)))
                var hatch = Path()
                let step: CGFloat = 3.8
                let span = rect.height
                var x = rect.minX - span
                while x <= rect.maxX + span {
                    hatch.move(to: CGPoint(x: x, y: rect.maxY))
                    hatch.addLine(to: CGPoint(x: x + span, y: rect.minY))
                    x += step
                }
                layer.stroke(hatch, with: .color(ink.opacity(0.58)), lineWidth: 0.7)

            case .hydrogen:
                // Pebbled conglomerate (tiny scattered pebbles + sand grains — Ref 3 bottom band)
                layer.fill(Path(rect), with: .color(ink.opacity(isDark ? 0.06 : 0.035)))
                var pebbles = Path()
                var grains = Path()
                let step: CGFloat = 5.4
                let cols = Int(rect.width / step) + 1
                let rows = Int(rect.height / step) + 1
                for r in 0...rows {
                    for c in 0...cols {
                        let h = lithoHash(c, r, 37)
                        let jx = (CGFloat(h & 0x1F) / 31.0 - 0.5) * 3.0
                        let jy = (CGFloat((h >> 5) & 0x1F) / 31.0 - 0.5) * 3.0
                        let cx = rect.minX + (CGFloat(c) + 0.4) * step + jx
                        let cy = rect.minY + (CGFloat(r) + 0.4) * step + jy
                        if (h >> 10) & 3 == 0 {
                            let pw: CGFloat = 1.8 + CGFloat((h >> 12) & 3) * 0.35
                            let ph: CGFloat = 1.4 + CGFloat((h >> 14) & 3) * 0.25
                            pebbles.addEllipse(in: CGRect(x: cx - pw * 0.5, y: cy - ph * 0.5, width: pw, height: ph))
                        } else {
                            grains.addRect(CGRect(x: cx, y: cy, width: 1.0, height: 1.0))
                        }
                    }
                }
                layer.stroke(pebbles, with: .color(ink.opacity(0.68)), lineWidth: 0.75)
                layer.fill(grains, with: .color(ink.opacity(0.55)))

            case .claude:
                // Horizontal siltstone laminae with uneven geological rhythm
                layer.fill(Path(rect), with: .color(ink.opacity(isDark ? 0.09 : 0.05)))
                var laminae = Path()
                var y = rect.minY + 1.8
                var row = 0
                while y < rect.maxY {
                    laminae.move(to: CGPoint(x: rect.minX, y: y))
                    laminae.addLine(to: CGPoint(x: rect.maxX, y: y))
                    y += (row % 3 == 0) ? 2.1 : 3.2
                    row += 1
                }
                layer.stroke(laminae, with: .color(ink.opacity(0.60)), lineWidth: 0.7)

            case .flash:
                // Staggered limestone masonry dash bedding
                layer.fill(Path(rect), with: .color(ink.opacity(isDark ? 0.07 : 0.04)))
                var dashes = Path()
                var y = rect.minY + 2.2
                var row = 0
                while y < rect.maxY {
                    let offset: CGFloat = (row % 2 == 0) ? 1.5 : 5.0
                    var x = rect.minX + offset
                    while x < rect.maxX - 1 {
                        dashes.move(to: CGPoint(x: x, y: y))
                        dashes.addLine(to: CGPoint(x: min(rect.maxX - 1, x + 4.5), y: y))
                        x += 7.5
                    }
                    y += 3.2
                    row += 1
                }
                layer.stroke(dashes, with: .color(ink.opacity(0.58)), lineWidth: 0.72)

            case .other:
                // Sparse unconsolidated silt stipple
                var grains = Path()
                var y = rect.minY + 2.5
                var r = 0
                while y < rect.maxY {
                    var x = rect.minX + (r % 2 == 0 ? 2.5 : 5.0)
                    while x < rect.maxX {
                        grains.addRect(CGRect(x: x, y: y, width: 1.0, height: 1.0))
                        x += 5.0
                    }
                    y += 3.8
                    r += 1
                }
                layer.fill(grains, with: .color(ink.opacity(0.45)))
            }
        }
    }

    private static func lithoHash(_ a: Int, _ b: Int, _ salt: Int) -> UInt32 {
        var h = UInt32(truncatingIfNeeded: a &* 73856093 ^ b &* 19349663 ^ salt &* 83492791)
        h = (h ^ (h >> 13)) &* 1274126177
        return h ^ (h >> 16)
    }

    private func leaderLinesCanvas(
        models: [ModelUsage],
        slices: [BoreholeSlice],
        bracketTargetId: String?,
        height: CGFloat
    ) -> some View {
        let sliceById = Dictionary(uniqueKeysWithValues: slices.map { ($0.id, $0) })

        return Canvas { context, size in
            let innerH = size.height - 1
            for (idx, m) in models.enumerated() {
                guard let slice = sliceById[m.id] else { continue }
                let sy = 0.5 + CGFloat(slice.midY) * innerH
                let ry = (CGFloat(idx) + 0.5) * rowHeight
                let isFocused = (focusedModelId == m.id)
                let anyFocused = (focusedModelId != nil)
                let isBracketed = (m.id == bracketTargetId)

                let stratumColor = theme.isMultiColorSpectrum ? theme.modelColor(m.modelClass) : theme.accentSecondary
                let lineColor: Color = {
                    if isFocused { return theme.isMultiColorSpectrum ? stratumColor : theme.accent }
                    if anyFocused { return theme.hairline }
                    if theme.isMultiColorSpectrum {
                        return stratumColor.opacity(isBracketed ? 0.85 : (theme.isDark ? 0.58 : 0.52))
                    }
                    return isBracketed
                        ? theme.accent.opacity(0.76)
                        : theme.accentSecondary.opacity(theme.isDark ? 0.44 : 0.38)
                }()

                var path = Path()
                path.move(to: CGPoint(x: 0, y: sy))
                path.addLine(to: CGPoint(x: size.width * 0.34, y: sy))
                path.addLine(to: CGPoint(x: size.width * 0.68, y: ry))
                path.addLine(to: CGPoint(x: size.width - 2.5, y: ry))
                context.stroke(path, with: .color(lineColor), lineWidth: isFocused ? 1.05 : 0.72)

                let dotSize: CGFloat = isFocused ? 3.0 : 2.0
                let dotColor: Color = {
                    if theme.isMultiColorSpectrum {
                        return stratumColor.opacity(anyFocused && !isFocused ? 0.28 : 0.92)
                    }
                    return (isFocused || (!anyFocused && isBracketed))
                        ? theme.accent
                        : theme.accentSecondary.opacity(anyFocused ? 0.28 : (theme.isDark ? 0.84 : 0.78))
                }()
                context.fill(
                    Path(CGRect(
                        x: size.width - dotSize,
                        y: ry - dotSize * 0.5,
                        width: dotSize,
                        height: dotSize
                    )),
                    with: .color(dotColor)
                )
            }
        }
        .allowsHitTesting(false)
    }

    private func modelCalloutRow(
        _ m: ModelUsage,
        index: Int,
        totalCost: Double,
        isBracketed: Bool
    ) -> some View {
        let fraction = totalCost > 0 ? max(0, min(1, m.cost / totalCost)) : 0
        let pctStr = String(format: "%.1f%%", fraction * 100.0)
        let isFocused = (focusedModelId == m.id)
        let anyFocused = (focusedModelId != nil)
        let dimmed = anyFocused && !isFocused

        let rowAccent = theme.isMultiColorSpectrum ? theme.modelColor(m.modelClass) : theme.accentSecondary

        return HStack(spacing: 5) {
            Text(String(format: "%02d", index + 1))
                .font(.system(size: 7, weight: .regular, design: .monospaced))
                .foregroundColor(
                    isFocused
                        ? (theme.isMultiColorSpectrum ? rowAccent : theme.accent)
                        : (theme.isMultiColorSpectrum
                            ? rowAccent.opacity(0.86)
                            : (isBracketed ? theme.accent.opacity(0.85) : theme.accentSecondary.opacity(0.72)))
                )
                .frame(width: 14, alignment: .leading)

            Text(m.shortCode)
                .font(.system(size: 9, weight: (isFocused || isBracketed) ? .semibold : .medium, design: .monospaced))
                .foregroundColor(
                    isFocused
                        ? (theme.isMultiColorSpectrum ? rowAccent : theme.accent)
                        : (theme.isMultiColorSpectrum
                            ? rowAccent
                            : (isBracketed ? theme.inkPrimary : theme.accentSecondary.opacity(theme.isDark ? 0.92 : 0.88)))
                )

            Text(m.name)
                .font(.system(size: 9.5, weight: .regular))
                .foregroundColor(theme.inkSecondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(pctStr)
                .font(.system(size: 8.5, weight: .regular, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(theme.inkMuted)
                .frame(width: 38, alignment: .trailing)

            Text(formatCostTabular(m.cost))
                .font(.system(size: 9.5, weight: isFocused ? .semibold : .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(isFocused ? theme.accent : theme.inkPrimary)
                .frame(width: 58, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .background(isFocused ? theme.accent.opacity(theme.isDark ? 0.12 : 0.06) : Color.clear)
        .opacity(dimmed ? 0.36 : 1.0)
        .contentShape(Rectangle())
        .onHover { inside in
            focusState.setRowHover(m.id, inside: inside)
            let nextFocus = focusState.effectiveFocusedId
            if focusedModelId != nextFocus {
                focusedModelId = nextFocus
                if nextFocus != nil {
                    CraftEngine.shared.perform(.costStrataShift, enabled: hapticsEnabled)
                }
            }
        }
    }
}
