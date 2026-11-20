import SwiftUI
import AppKit

// Cost / Tokens Swiss Precision Instrument:
// Single-plane drafting grid, precision Hero numerals, flush 3-period cursor bar,
// interactive Canvas strata ledger, and Dot-Graticule Oscilloscope DailyChart.

// MARK: - Usage Overview Section

struct UsageOverviewSection: View {
    @ObservedObject var store: UsageStore
    var metricOverride: DisplayTab? = nil
    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @State private var focusedModelId: String? = nil

    private var activeMetric: DisplayTab {
        metricOverride ?? store.selectedTab
    }

    var body: some View {
        Group {
            if store.isCurrentMonth {
            switch store.effectiveCurrentMonthPhase {
            case .loaded(let bundle), .loading(cached: .some(let bundle)), .failed(_, cached: .some(let bundle)):
                let scope = store.selectedPeriodScope
                let activeUsage: PeriodUsage = {
                    switch scope {
                    case .today: return bundle.today
                    case .week:  return bundle.week
                    case .month: return bundle.month
                    }
                }()
                let scopeTitle: String = {
                    switch scope {
                    case .today: return loc("periodTodayShort")
                    case .week:  return loc("periodWeekShort")
                    case .month: return loc("periodMonthShort")
                    }
                }()

                if store.visualMode == .instrument && activeMetric == .cost {
                    CostInstrumentView(
                        usage: activeUsage,
                        bundle: bundle,
                        selectedScope: $store.selectedPeriodScope,
                        year: store.viewingYear,
                        month: store.viewingMonth,
                        focusedModelId: $focusedModelId
                    )
                } else if store.visualMode == .instrument && activeMetric == .tokens {
                    TokensInstrumentView(
                        usage: activeUsage,
                        bundle: bundle,
                        selectedScope: $store.selectedPeriodScope,
                        year: store.viewingYear,
                        month: store.viewingMonth,
                        focusedModelId: $focusedModelId
                    )
                } else {
                VStack(spacing: 0) {
                    HeroTelemetrySection(
                        metric: activeMetric,
                        scopeTitle: scopeTitle,
                        usage: activeUsage,
                        dailyBreakdown: bundle.dailyBreakdown,
                        isTodayScope: scope == .today,
                        focusedModelId: focusedModelId,
                        showTokenTypeBar: !(store.visualMode == .instrument && activeMetric == .tokens)
                    )

                    HairlineRule(showCrosshairs: true)

                    PeriodScopeStrip(
                        selection: $store.selectedPeriodScope,
                        bundle: bundle,
                        metric: activeMetric
                    )

                    HairlineRule(showCrosshairs: true)

                    if store.visualMode == .instrument {
                        FoldedTokenFlowChart(
                            usage: activeUsage,
                            focusedModelId: $focusedModelId
                        )

                        if let daily = bundle.dailyBreakdown, !daily.isEmpty {
                            HairlineRule(showCrosshairs: true)
                            TokenDensityMatrix(
                                data: daily,
                                year: store.viewingYear,
                                month: store.viewingMonth,
                                focusedModelId: focusedModelId
                            )
                        }
                    } else {
                        ModelLedgerSection(
                            metric: activeMetric,
                            usage: activeUsage,
                            focusedModelId: $focusedModelId
                        )

                        if let daily = bundle.dailyBreakdown, !daily.isEmpty {
                            HairlineRule(showCrosshairs: true)
                            DailyChart(
                                data: daily,
                                mode: activeMetric,
                                year: store.viewingYear,
                                month: store.viewingMonth,
                                focusedModelId: focusedModelId
                            )
                        }
                    }

                    if activeMetric == .cost {
                        HairlineRule(showCrosshairs: false)
                        apiEquivFootnote
                    }
                }
                }

            case .loading(cached: nil), .idle:
                TelemetrySkeleton()
            case .empty:
                stateBox(icon: "tray", tint: theme.inkSecondary, text: loc("noMonthData"), showRetry: false)
            case .failed(_, cached: nil):
                stateBox(icon: "exclamationmark.triangle", tint: theme.signalAmber, text: loc("loadFailed"), showRetry: true)
            }
        } else {
            switch store.effectiveHistoricalMonthPhase {
            case .loaded(let bundle), .loading(cached: .some(let bundle)), .failed(_, cached: .some(let bundle)):
                if store.visualMode == .instrument && activeMetric == .cost {
                    CostInstrumentView(
                        usage: bundle.month,
                        bundle: nil,
                        dailyOverride: bundle.dailyBreakdown,
                        selectedScope: nil,
                        year: store.viewingYear,
                        month: store.viewingMonth,
                        focusedModelId: $focusedModelId
                    )
                } else if store.visualMode == .instrument && activeMetric == .tokens {
                    TokensInstrumentView(
                        usage: bundle.month,
                        bundle: nil,
                        dailyOverride: bundle.dailyBreakdown,
                        selectedScope: nil,
                        year: store.viewingYear,
                        month: store.viewingMonth,
                        focusedModelId: $focusedModelId
                    )
                } else {
                VStack(spacing: 0) {
                    HeroTelemetrySection(
                        metric: activeMetric,
                        scopeTitle: loc("periodMonthShort"),
                        usage: bundle.month,
                        dailyBreakdown: bundle.dailyBreakdown,
                        isTodayScope: false,
                        focusedModelId: focusedModelId,
                        showTokenTypeBar: !(store.visualMode == .instrument && activeMetric == .tokens)
                    )

                    HairlineRule(showCrosshairs: true)

                    if store.visualMode == .instrument {
                        FoldedTokenFlowChart(
                            usage: bundle.month,
                            focusedModelId: $focusedModelId
                        )

                        if let daily = bundle.dailyBreakdown, !daily.isEmpty {
                            HairlineRule(showCrosshairs: true)
                            TokenDensityMatrix(
                                data: daily,
                                year: store.viewingYear,
                                month: store.viewingMonth,
                                focusedModelId: focusedModelId
                            )
                        }
                    } else {
                        ModelLedgerSection(
                            metric: activeMetric,
                            usage: bundle.month,
                            focusedModelId: $focusedModelId
                        )

                        if let daily = bundle.dailyBreakdown, !daily.isEmpty {
                            HairlineRule(showCrosshairs: true)
                            DailyChart(
                                data: daily,
                                mode: activeMetric,
                                year: store.viewingYear,
                                month: store.viewingMonth,
                                focusedModelId: focusedModelId
                            )
                        }
                    }

                    if activeMetric == .cost {
                        HairlineRule(showCrosshairs: false)
                        apiEquivFootnote
                    }
                }
                }

            case .loading(cached: nil), .idle:
                TelemetrySkeleton()
            case .empty:
                stateBox(icon: "tray", tint: theme.inkSecondary, text: loc("noMonthData"), showRetry: false)
            case .failed(_, cached: nil):
                stateBox(icon: "exclamationmark.triangle", tint: theme.signalAmber, text: loc("loadFailed"), showRetry: true)
            }
        }
        }
        .onChange(of: store.selectedTab) { _ in focusedModelId = nil }
        .onChange(of: store.viewingMonth) { _ in focusedModelId = nil }
        .onChange(of: store.viewingYear) { _ in focusedModelId = nil }
        .onChange(of: store.selectedPeriodScope) { _ in focusedModelId = nil }
        .onChange(of: store.visualMode) { _ in focusedModelId = nil }
    }

    private var apiEquivFootnote: some View {
        HStack(spacing: 5) {
            Text("*")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(theme.accent)
            Text(loc("costApiEquivNote"))
                .font(.system(size: 9))
                .foregroundColor(theme.inkMuted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func stateBox(icon: String, tint: Color, text: String, showRetry: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(tint)
            Text(text)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(theme.inkSecondary)
            if showRetry {
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
        .frame(height: 130)
    }
}

// MARK: - Hero Telemetry Section

struct HeroTelemetrySection: View {
    let metric: DisplayTab
    let scopeTitle: String
    let usage: PeriodUsage
    let dailyBreakdown: [DailyUsage]?
    let isTodayScope: Bool
    var focusedModelId: String? = nil
    var showTokenTypeBar: Bool = true

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme

    private var todayDelta: Double? {
        guard metric == .cost, isTodayScope, let daily = dailyBreakdown else { return nil }
        let todayDay = AppDate.gregorian.component(.day, from: Date())
        return UsageTelemetryLogic.costDeltaPercent(todayCost: usage.cost, daily: daily, todayDay: todayDay)
    }

    private var cacheHitPct: Double? {
        guard metric == .tokens else { return nil }
        return UsageTelemetryLogic.cacheHitPercent(input: usage.totalInput, cacheRead: usage.totalCacheRead)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("\(metric == .cost ? loc("apiEquivTag") : loc("tokensTag")) // \(scopeTitle.uppercased())")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundColor(theme.inkSecondary)

                Spacer(minLength: 4)

                if let delta = todayDelta {
                    let signed = formatSignedPercent(delta)
                    Text(String(format: loc("vs7dAvgFmt"), signed).uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(delta > 0 ? theme.accent : theme.accentSecondary)
                } else if let hit = cacheHitPct {
                    Text(String(format: loc("cacheHitFmt"), Int(hit.rounded())))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.accentSecondary)
                }
            }

            HStack(alignment: .firstTextBaseline) {
                if metric == .cost {
                    let parts = splitCurrencyParts(usage.cost)
                    PrecisionHeroNumber(prefix: parts.prefix, whole: parts.whole, fraction: parts.frac, size: 34)
                } else {
                    let parts = splitTokenParts(usage.totalTokens)
                    PrecisionHeroNumber(whole: parts.number, suffix: parts.unit, size: 34)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(formatNumber(usage.totalMessages)) MSG")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.inkSecondary)
                    Text(metric == .cost
                         ? formatTokensShort(usage.totalTokens).uppercased() + " TOK"
                         : formatCostTabular(usage.cost))
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.inkPrimary)
                }
            }

            if metric == .cost {
                if !usage.models.isEmpty {
                    let segs = usage.models.map { m in
                        StrataSegment(
                            id: m.id,
                            color: theme.modelColor(m.modelClass),
                            pattern: theme.modelPattern(m.modelClass),
                            fraction: usage.cost > 0 ? m.cost / usage.cost : 0
                        )
                    }
                    StrataBarView(segments: segs, focusedId: focusedModelId, height: 5)
                }
            } else if showTokenTypeBar, usage.totalTokens > 0 {
                TokenTypeBar(usage: usage, focusedModelId: focusedModelId)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }
}

// MARK: - Flush 3-Column Period Switcher

struct PeriodScopeStrip: View {
    @Binding var selection: UsagePeriodScope
    let bundle: CurrentMonthBundle
    let metric: DisplayTab

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @Environment(\.telemetryStaticRender) private var isStaticRender
    @Namespace private var scopeNamespace
    @State private var hovered: UsagePeriodScope? = nil
    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    private var scopeAnimation: Animation? {
        guard !isStaticRender else { return nil }
        return reduceMotion ? TelemetryMotion.reduced : TelemetryMotion.tabIndicator
    }

    private var cells: [(scope: UsagePeriodScope, title: String, value: String)] {
        [
            (.today, loc("periodTodayShort"), metric == .cost ? formatCost(bundle.today.cost) : formatTokensShort(bundle.today.totalTokens).uppercased()),
            (.week,  loc("periodWeekShort"),  metric == .cost ? formatCost(bundle.week.cost)  : formatTokensShort(bundle.week.totalTokens).uppercased()),
            (.month, loc("periodMonthShort"), metric == .cost ? formatCost(bundle.month.cost) : formatTokensShort(bundle.month.totalTokens).uppercased()),
        ]
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.element.scope) { idx, item in
                let selected = (item.scope == selection)
                let isHovered = (item.scope == hovered)
                VStack(alignment: .leading, spacing: 1.5) {
                    Text(selected ? "▸ \(item.title.uppercased())" : item.title.uppercased())
                        .font(.system(size: 8.5, weight: selected ? .bold : .medium, design: .monospaced))
                        .foregroundColor(selected ? theme.invertedInk.opacity(0.75) : theme.inkMuted)
                    Text(item.value)
                        .font(.system(size: 12.5, weight: selected ? .bold : .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(selected ? theme.invertedInk : theme.inkPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    ZStack {
                        if selected {
                            Rectangle()
                                .fill(theme.invertedBg)
                                .matchedGeometryEffect(id: "classicScopePlate", in: scopeNamespace)
                        } else if isHovered {
                            Rectangle()
                                .fill(theme.surfaceRaised.opacity(0.65))
                        }
                    }
                )
                .contentShape(Rectangle())
                .onHover { inside in hovered = inside ? item.scope : (hovered == item.scope ? nil : hovered) }
                .onTapGesture {
                    guard selection != item.scope else { return }
                    withAnimation(scopeAnimation) {
                        selection = item.scope
                    }
                }

                if idx < cells.count - 1 {
                    Rectangle().fill(theme.hairline).frame(width: 1)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .animation(scopeAnimation, value: selection)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }
}

// MARK: - Monospace Interactive Model Breakdown Ledger

struct ModelLedgerSection: View {
    let metric: DisplayTab
    let usage: PeriodUsage
    @Binding var focusedModelId: String?

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme

    private var visibleModels: [ModelUsage] {
        if metric == .cost {
            return usage.models.filter { $0.cost >= 0.005 }
        }
        return usage.models.filter { $0.totalTokens > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if visibleModels.isEmpty {
                Text(loc("noData").uppercased())
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.inkMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else if metric == .cost {
                costHeader
                Rectangle().fill(theme.hairline).frame(height: 1)
                    .padding(.bottom, 2)
                ForEach(visibleModels) { m in
                    costRow(m)
                }
            } else {
                tokensHeader
                Rectangle().fill(theme.hairline).frame(height: 1)
                    .padding(.bottom, 2)
                ForEach(visibleModels) { m in
                    tokensRow(m)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var costHeader: some View {
        HStack(spacing: 6) {
            Text(loc("colModel"))
                .frame(width: 112, alignment: .leading)
            Text(loc("colDist"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(loc("colShare"))
                .frame(width: 44, alignment: .trailing)
            Text(loc("colAmount"))
                .frame(width: 68, alignment: .trailing)
        }
        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
        .foregroundColor(theme.inkMuted)
        .padding(.horizontal, 2)
    }

    private func costRow(_ m: ModelUsage) -> some View {
        let fraction = usage.cost > 0 ? max(0, min(1, m.cost / usage.cost)) : 0
        let pctStr = String(format: "%.1f%%", fraction * 100.0)
        let isFocused = (focusedModelId == m.id)
        let anyFocused = (focusedModelId != nil)
        let swatchColor = theme.modelColor(m.modelClass, focused: isFocused, anyFocused: anyFocused)
        let pattern = theme.modelPattern(m.modelClass)

        return HStack(spacing: 6) {
            HStack(spacing: 5) {
                StrataSwatch(color: swatchColor, pattern: pattern, size: 7)
                Text(m.shortCode)
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundColor(isFocused ? theme.accent : theme.inkPrimary)
                Text(m.name)
                    .font(.system(size: 10.5))
                    .foregroundColor(theme.inkSecondary)
                    .lineLimit(1)
            }
            .frame(width: 112, alignment: .leading)

            Canvas { context, size in
                context.fill(Path(CGRect(x: 0, y: size.height * 0.5 - 1.5, width: size.width, height: 3)),
                             with: .color(theme.hairline))
                let fillW = max(2, size.width * CGFloat(fraction))
                var ctx = context
                drawStrataRect(
                    in: &ctx,
                    rect: CGRect(x: 0, y: size.height * 0.5 - 1.5, width: fillW, height: 3),
                    color: swatchColor,
                    pattern: pattern
                )
            }
            .frame(height: 14)

            Text(pctStr)
                .font(.system(size: 9.5, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(theme.inkSecondary)
                .frame(width: 44, alignment: .trailing)

            Text(formatCostTabular(m.cost))
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(isFocused ? theme.accent : theme.inkPrimary)
                .frame(width: 68, alignment: .trailing)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2.5)
        .background(isFocused ? theme.surfaceRaised.opacity(0.9) : Color.clear)
        .contentShape(Rectangle())
        .onHover { inside in
            focusedModelId = inside ? m.id : (focusedModelId == m.id ? nil : focusedModelId)
        }
    }

    private var tokensHeader: some View {
        HStack(spacing: 4) {
            Text(loc("colModel"))
                .frame(width: 66, alignment: .leading)
            Spacer(minLength: 2)
            Text(loc("colTotal"))
                .frame(width: 52, alignment: .trailing)
            Text(loc("tkIn").uppercased())
                .frame(width: 46, alignment: .trailing)
            Text(loc("tkOut").uppercased())
                .frame(width: 46, alignment: .trailing)
            Text(loc("tkCR").uppercased())
                .frame(width: 52, alignment: .trailing)
            Text(loc("colHit"))
                .frame(width: 36, alignment: .trailing)
        }
        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
        .foregroundColor(theme.inkMuted)
        .padding(.horizontal, 2)
    }

    private func tokensRow(_ m: ModelUsage) -> some View {
        let isFocused = (focusedModelId == m.id)
        let anyFocused = (focusedModelId != nil)
        let swatchColor = theme.modelColor(m.modelClass, focused: isFocused, anyFocused: anyFocused)
        let pattern = theme.modelPattern(m.modelClass)
        let hitPct = UsageTelemetryLogic.cacheHitPercent(input: m.inputTokens, cacheRead: m.cacheRead)
            .map { String(format: "%d%%", Int($0.rounded())) } ?? "—"

        return HStack(spacing: 4) {
            HStack(spacing: 5) {
                StrataSwatch(color: swatchColor, pattern: pattern, size: 7)
                Text(m.shortCode)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(isFocused ? theme.accent : theme.inkPrimary)
            }
            .frame(width: 66, alignment: .leading)

            Spacer(minLength: 2)

            Text(formatTokensShort(m.totalTokens).uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(isFocused ? theme.accent : theme.inkPrimary)
                .frame(width: 52, alignment: .trailing)

            Text(formatTokensShort(m.inputTokens).uppercased())
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundColor(theme.inkSecondary)
                .frame(width: 46, alignment: .trailing)

            Text(formatTokensShort(m.outputTokens).uppercased())
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundColor(theme.inkSecondary)
                .frame(width: 46, alignment: .trailing)

            Text(formatTokensShort(m.cacheRead).uppercased())
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundColor(theme.inkSecondary)
                .frame(width: 52, alignment: .trailing)

            Text(hitPct)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.accentSecondary)
                .frame(width: 36, alignment: .trailing)
        }
        .monospacedDigit()
        .padding(.horizontal, 2)
        .padding(.vertical, 2.5)
        .background(isFocused ? theme.surfaceRaised.opacity(0.9) : Color.clear)
        .contentShape(Rectangle())
        .onHover { inside in
            focusedModelId = inside ? m.id : (focusedModelId == m.id ? nil : focusedModelId)
        }
    }
}

// MARK: - Oscilloscope Canvas Daily Chart with Dot Graticule & Crosshair Lock

struct DailyChart: View {
    let data: [DailyUsage]
    let mode: DisplayTab
    let year: Int
    let month: Int
    var focusedModelId: String? = nil

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @State private var hoveredDay: Int? = nil

    private var daysInMonth: Int { AppDate.daysInMonth(year: year, month: month) ?? 30 }

    private var dayLookup: [Int: DailyUsage] {
        Dictionary(uniqueKeysWithValues: data.map { ($0.day, $0) })
    }

    private var maxValue: Double {
        data.map { mode == .cost ? $0.cost : Double($0.totalTokens) }.max() ?? 1
    }

    private var avgValue: Double {
        UsageTelemetryLogic.dailyAverage(daily: data, modeIsCost: mode == .cost)
    }

    private var todayNumberIfViewingCurrentMonth: Int? {
        let nowComps = AppDate.gregorian.dateComponents([.year, .month, .day], from: Date())
        guard nowComps.year == year, nowComps.month == month else { return nil }
        return nowComps.day
    }

    private var labelDays: Set<Int> {
        let total = daysInMonth
        var labels: Set<Int> = [1]
        for d in stride(from: 5, through: total - 3, by: 5) { labels.insert(d) }
        labels.insert(total)
        return labels
    }

    private let chartHeight: CGFloat = 86

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            chartHeader

            ZStack(alignment: .top) {
                ZStack {
                    DotGraticuleBackground(spacing: 11)
                    plotCanvas
                    hoverTargetOverlay
                }
                .frame(height: chartHeight)

                if let day = hoveredDay {
                    DailyTelemetryTooltip(
                        day: day,
                        month: month,
                        daysInMonth: daysInMonth,
                        usage: dayLookup[day],
                        modeIsCost: mode == .cost
                    )
                }
            }

            xAxisLabels
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var plotCanvas: some View {
        Canvas { context, size in
            let count = max(1, daysInMonth)
            let slotW = size.width / CGFloat(count)
            let barW = max(3.0, min(6.5, slotW * 0.62))

            // 1. Dashed monthly average horizontal reference rule (Color 2)
            if maxValue > 0 && avgValue > 0 {
                let ratio = min(1.0, avgValue / maxValue)
                let y = max(1, size.height - CGFloat(ratio) * size.height)
                var dash = Path()
                dash.move(to: CGPoint(x: 0, y: y))
                dash.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(dash, with: .color(theme.accentSecondary.opacity(theme.isDark ? 0.62 : 0.55)),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }

            // 2. Stacked sharp telemetry bars per day
            for day in 1...daysInMonth {
                let cx = (CGFloat(day) - 0.5) * slotW
                let x = cx - barW * 0.5
                let isDayHovered = (hoveredDay == day)
                let dayDimmed = (hoveredDay != nil && !isDayHovered)

                if let usage = dayLookup[day] {
                    let total = mode == .cost ? usage.cost : Double(usage.totalTokens)
                    if total > 0 && maxValue > 0 {
                        let totalH = max(2.5, CGFloat(total / maxValue) * (size.height - 4))
                        var cursorY = size.height
                        let models = usage.models

                        for idx in models.indices.reversed() {
                            let m = models[idx]
                            let mv = mode == .cost ? m.cost : Double(m.totalTokens)
                            guard mv > 0 else { continue }
                            let segH = max(0.8, CGFloat(mv / total) * totalH)
                            let segY = cursorY - segH
                            let segRect = CGRect(x: x, y: segY, width: barW, height: segH)

                            let isModelFocused = (focusedModelId == m.id)
                            let anyModelFocused = (focusedModelId != nil)
                            var barColor = theme.modelColor(m.modelClass, focused: isModelFocused, anyFocused: anyModelFocused)
                            if dayDimmed { barColor = barColor.opacity(0.28) }
                            var ctx = context
                            drawStrataRect(
                                in: &ctx,
                                rect: segRect,
                                color: barColor,
                                pattern: theme.modelPattern(m.modelClass)
                            )
                            cursorY = segY - 0.5
                        }

                        // Peak bright 1px cap
                        let capColor = isDayHovered ? theme.inkPrimary : theme.accent.opacity(dayDimmed ? 0.25 : 0.9)
                        context.fill(Path(CGRect(x: x, y: max(0, cursorY), width: barW, height: 1.2)),
                                     with: .color(capColor))

                        // Full-height crosshair + lock reticle on hover
                        if isDayHovered {
                            let peakY = max(2, cursorY)
                            var vline = Path()
                            vline.move(to: CGPoint(x: cx, y: 0))
                            vline.addLine(to: CGPoint(x: cx, y: size.height))
                            context.stroke(vline, with: .color(theme.reticle), lineWidth: 1)

                            var hline = Path()
                            hline.move(to: CGPoint(x: 0, y: peakY))
                            hline.addLine(to: CGPoint(x: size.width, y: peakY))
                            context.stroke(hline, with: .color(theme.reticle.opacity(0.55)),
                                           style: StrokeStyle(lineWidth: 1, dash: [2, 2]))

                            context.fill(Path(CGRect(x: cx - 2, y: peakY - 2, width: 4, height: 4)),
                                         with: .color(theme.accent))
                        }
                    }
                } else {
                    context.fill(Path(CGRect(x: x, y: size.height - 1, width: barW, height: 1)),
                                 with: .color(isDayHovered ? theme.hairlineStrong : theme.hairline))
                    if isDayHovered {
                        var vline = Path()
                        vline.move(to: CGPoint(x: cx, y: 0))
                        vline.addLine(to: CGPoint(x: cx, y: size.height))
                        context.stroke(vline, with: .color(theme.reticle.opacity(0.65)), lineWidth: 1)
                    }
                }
            }

            // 3. Baseline rule
            context.fill(Path(CGRect(x: 0, y: size.height - 0.8, width: size.width, height: 0.8)),
                         with: .color(theme.hairlineStrong))
        }
    }

    private var hoverTargetOverlay: some View {
        HStack(spacing: 0) {
            ForEach(1...daysInMonth, id: \.self) { day in
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onHover { h in hoveredDay = h ? day : (hoveredDay == day ? nil : hoveredDay) }
            }
        }
    }

    private var xAxisLabels: some View {
        GeometryReader { geo in
            let slotW = geo.size.width / CGFloat(max(1, daysInMonth))
            ZStack(alignment: .leading) {
                ForEach(Array(labelDays.sorted()), id: \.self) { day in
                    Text(String(format: "%02d", day))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(day == todayNumberIfViewingCurrentMonth ? theme.accent : theme.inkMuted)
                        .position(x: (CGFloat(day) - 0.5) * slotW, y: 5)
                }
                if let todayDay = todayNumberIfViewingCurrentMonth {
                    Rectangle()
                        .fill(theme.accent)
                        .frame(width: 3, height: 3)
                        .position(x: (CGFloat(todayDay) - 0.5) * slotW, y: 11)
                }
            }
        }
        .frame(height: 13)
    }

    private var chartHeader: some View {
        let monthStr = String(format: "%04d.%02d", year, month)
        let avgText = mode == .cost ? formatCost(avgValue) : formatTokensShort(Int(avgValue)).uppercased()
        let maxText = mode == .cost ? formatCost(maxValue) : formatTokensShort(Int(maxValue)).uppercased()

        return HStack(spacing: 4) {
            Text("\(loc("dailyTelemetry")) // \(monthStr)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.5)
                .foregroundColor(theme.inkSecondary)
            Spacer()
            HStack(spacing: 3) {
                Text("\(String(format: loc("avgFmt"), avgText))/D")
                    .foregroundColor(theme.accentSecondary.opacity(theme.isDark ? 0.90 : 0.86))
                Text("· \(String(format: loc("maxFmt"), maxText))")
                    .foregroundColor(theme.inkMuted)
            }
            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
            .monospacedDigit()
        }
    }
}

/// Shared floating HUD callout box used by DailyChart, TopographicRidgeChart, and TokenDensityMatrix.
struct DailyTelemetryTooltip: View {
    let day: Int
    let month: Int
    let daysInMonth: Int
    let usage: DailyUsage?
    let modeIsCost: Bool

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme

    var body: some View {
        let alignTrailing = (day <= daysInMonth / 2)
        let nonZeroModels = (usage?.models ?? []).filter { modeIsCost ? $0.cost >= 0.005 : $0.totalTokens > 0 }

        HStack {
            if alignTrailing { Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(String(format: "%02d/%02d", month, day))
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.invertedInk.opacity(0.72))
                    Spacer(minLength: 4)
                    if let usage = usage {
                        Text(modeIsCost ? formatCostTabular(usage.cost) : formatTokensShort(usage.totalTokens).uppercased())
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(theme.invertedInk)
                    } else {
                        Text(loc("noData").uppercased())
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(theme.invertedInk.opacity(0.6))
                    }
                }
                if !nonZeroModels.isEmpty {
                    Rectangle().fill(theme.invertedInk.opacity(0.22)).frame(height: 1)
                    ForEach(nonZeroModels.prefix(4)) { m in
                        HStack(spacing: 5) {
                            Rectangle()
                                .fill(theme.modelColor(m.modelClass))
                                .frame(width: 5, height: 5)
                            Text(m.shortCode)
                                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                .foregroundColor(theme.invertedInk.opacity(0.85))
                            Spacer(minLength: 6)
                            Text(modeIsCost ? formatCostTabular(m.cost) : formatTokensShort(m.totalTokens).uppercased())
                                .font(.system(size: 8.5, design: .monospaced))
                                .foregroundColor(theme.invertedInk)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minWidth: 114, maxWidth: 142)
            .background(theme.invertedBg.opacity(0.96))
            .overlay(CornerReticleOverlay(color: theme.invertedInk.opacity(0.45), length: 4, lineWidth: 1))
            if !alignTrailing { Spacer(minLength: 0) }
        }
        .padding(.top, 2)
        .allowsHitTesting(false)
    }
}
