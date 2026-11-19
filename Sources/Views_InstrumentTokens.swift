import SwiftUI
import AppKit

// Tokens Tab Instrument Visualizations:
// 1. Folded Token Flow / Bezier Stream Sankey: Model Tiers -> Cache Read / Input / Output / Cache Write (Ref 2)
// 2. Throughput Density Matrix: 30-day vector glyph density waveform (Ref 3)

// MARK: - 1. Folded Token Flow (Model -> Token Channel Bezier Streams)

struct FoldedTokenFlowChart: View {
    let usage: PeriodUsage
    @Binding var focusedModelId: String?

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @State private var hoveredChannel: TokenChannel? = nil

    private let flowHeight: CGFloat = 132
    private let leftLabelWidth: CGFloat = 80
    private let rightLabelWidth: CGFloat = 104

    var body: some View {
        let layout = InstrumentMath.buildTokenFlowLayout(models: usage.models, maxModels: 6, nodeGap: 0.04)
        let modelById = Dictionary(uniqueKeysWithValues: usage.models.map { ($0.id, $0) })

        VStack(alignment: .leading, spacing: 7) {
            headerRow(layout: layout, modelById: modelById)

            if layout.leftNodes.isEmpty {
                Text(loc("noData").uppercased())
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.inkMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                HStack(spacing: 4) {
                    leftModelColumn(layout: layout, modelById: modelById)
                        .frame(width: leftLabelWidth, height: flowHeight)

                    flowCanvas(layout: layout, modelById: modelById)
                        .frame(height: flowHeight)

                    rightChannelColumn(layout: layout)
                        .frame(width: rightLabelWidth, height: flowHeight)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private func headerRow(layout: TokenFlowLayout, modelById: [String: ModelUsage]) -> some View {
        HStack {
            Text(loc("tokenFlowTitle"))
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundColor(theme.inkSecondary)

            Spacer(minLength: 4)

            if let ch = hoveredChannel {
                let chVal = channelTotal(ch)
                let pct = layout.totalTokens > 0 ? Int((Double(chVal) / Double(layout.totalTokens) * 100.0).rounded()) : 0
                Text("→ \(channelName(ch)) · \(formatTokensShort(chVal).uppercased()) (\(pct)%)")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.accent)
            } else if let fid = focusedModelId, let m = modelById[fid] {
                let hit = UsageTelemetryLogic.cacheHitPercent(input: m.inputTokens, cacheRead: m.cacheRead)
                    .map { "HIT \(Int($0.rounded()))%" } ?? formatTokensShort(m.totalTokens).uppercased()
                Text("\(m.shortCode) · \(formatTokensShort(m.totalTokens).uppercased()) · \(hit)")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.accent)
            } else {
                Text(String(format: "%02d MOD → %02d CH", layout.leftNodes.count, layout.rightNodes.count))
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.inkMuted)
            }
        }
    }

    private func leftModelColumn(layout: TokenFlowLayout, modelById: [String: ModelUsage]) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.leftNodes) { node in
                let isFocused = (focusedModelId == node.id)
                let anyFocused = (focusedModelId != nil || hoveredChannel != nil)
                let m = modelById[node.id]
                let color = m.map { theme.modelColor($0.modelClass, focused: isFocused, anyFocused: focusedModelId != nil) } ?? theme.accent
                let pattern = m.map { theme.modelPattern($0.modelClass) } ?? .solid
                let cy = CGFloat(node.midY) * flowHeight

                HStack(spacing: 4) {
                    StrataSwatch(color: color, pattern: pattern, size: 6)
                    Text(node.label)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(isFocused ? theme.accent : theme.inkPrimary)
                    Spacer(minLength: 2)
                    Text(formatTokensShort(node.value).uppercased())
                        .font(.system(size: 8.5, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(isFocused ? theme.accent : theme.inkSecondary)
                }
                .padding(.horizontal, 2)
                .frame(width: leftLabelWidth, height: 16)
                .background(isFocused ? theme.surfaceRaised.opacity(0.92) : Color.clear)
                .opacity(anyFocused && !isFocused && hoveredChannel == nil ? 0.45 : 1.0)
                .contentShape(Rectangle())
                .position(x: leftLabelWidth * 0.5, y: min(max(8, cy), flowHeight - 8))
                .onHover { inside in
                    focusedModelId = inside ? node.id : (focusedModelId == node.id ? nil : focusedModelId)
                }
            }
        }
    }

    private func rightChannelColumn(layout: TokenFlowLayout) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.rightNodes) { node in
                let ch = channelFromNodeId(node.id)
                let isFocused = (hoveredChannel == ch && ch != nil)
                let pct = layout.totalTokens > 0
                    ? Int((Double(node.value) / Double(layout.totalTokens) * 100.0).rounded())
                    : 0
                let cy = CGFloat(node.midY) * flowHeight

                HStack(spacing: 4) {
                    Text(channelName(ch ?? .cacheRead))
                        .font(.system(size: 8.5, weight: isFocused ? .bold : .semibold, design: .monospaced))
                        .foregroundColor(isFocused ? theme.accent : theme.inkPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text("\(pct)%")
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(isFocused ? theme.accent : theme.inkMuted)
                }
                .padding(.horizontal, 2)
                .frame(width: rightLabelWidth, height: 16)
                .background(isFocused ? theme.surfaceRaised.opacity(0.92) : Color.clear)
                .opacity(hoveredChannel != nil && !isFocused ? 0.42 : 1.0)
                .contentShape(Rectangle())
                .position(x: rightLabelWidth * 0.5, y: min(max(8, cy), flowHeight - 8))
                .onHover { inside in
                    guard let ch = ch else { return }
                    hoveredChannel = inside ? ch : (hoveredChannel == ch ? nil : hoveredChannel)
                }
            }
        }
    }

    private func flowCanvas(layout: TokenFlowLayout, modelById: [String: ModelUsage]) -> some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let barW: CGFloat = 3.0
            let ctrlX1 = w * 0.44
            let ctrlX2 = w * 0.56

            // 1. Folded cubic Bezier flow streams
            for link in layout.links {
                let matchesFocus: Bool = {
                    if let ch = hoveredChannel { return link.channel == ch }
                    if let fid = focusedModelId { return link.modelId == fid }
                    return true
                }()
                let anyFocus = (hoveredChannel != nil || focusedModelId != nil)
                let mClass = modelById[link.modelId]?.modelClass ?? .other
                let baseColor = theme.modelColor(mClass)

                let sy0 = CGFloat(link.srcY0) * h
                let sy1 = max(sy0 + 0.8, CGFloat(link.srcY1) * h)
                let dy0 = CGFloat(link.dstY0) * h
                let dy1 = max(dy0 + 0.8, CGFloat(link.dstY1) * h)

                var ribbon = Path()
                ribbon.move(to: CGPoint(x: barW, y: sy0))
                ribbon.addCurve(
                    to: CGPoint(x: w - barW, y: dy0),
                    control1: CGPoint(x: ctrlX1, y: sy0),
                    control2: CGPoint(x: ctrlX2, y: dy0)
                )
                ribbon.addLine(to: CGPoint(x: w - barW, y: dy1))
                ribbon.addCurve(
                    to: CGPoint(x: barW, y: sy1),
                    control1: CGPoint(x: ctrlX2, y: dy1),
                    control2: CGPoint(x: ctrlX1, y: sy1)
                )
                ribbon.closeSubpath()

                let fillOpacity: Double = anyFocus
                    ? (matchesFocus ? 0.48 : 0.05)
                    : (theme.isDark ? 0.30 : 0.22)
                let strokeOpacity: Double = anyFocus
                    ? (matchesFocus ? 0.95 : 0.12)
                    : (theme.isDark ? 0.65 : 0.55)

                context.fill(ribbon, with: .color(baseColor.opacity(fillOpacity)))

                // Crisp Ref-2 blueprint outer stream splines
                var topEdge = Path()
                topEdge.move(to: CGPoint(x: barW, y: sy0))
                topEdge.addCurve(
                    to: CGPoint(x: w - barW, y: dy0),
                    control1: CGPoint(x: ctrlX1, y: sy0),
                    control2: CGPoint(x: ctrlX2, y: dy0)
                )
                context.stroke(topEdge, with: .color(baseColor.opacity(strokeOpacity)), lineWidth: matchesFocus && anyFocus ? 1.1 : 0.7)
            }

            // 2. Left terminal model bars
            for node in layout.leftNodes {
                let y0 = CGFloat(node.y0) * h
                let y1 = max(y0 + 2, CGFloat(node.y1) * h)
                let isFocused = (focusedModelId == node.id)
                let mClass = modelById[node.id]?.modelClass ?? .other
                let col = theme.modelColor(mClass, focused: isFocused, anyFocused: focusedModelId != nil)
                var ctx = context
                drawStrataRect(
                    in: &ctx,
                    rect: CGRect(x: 0, y: y0, width: barW, height: y1 - y0),
                    color: col,
                    pattern: modelById[node.id].map { theme.modelPattern($0.modelClass) } ?? .solid
                )
            }

            // 3. Right terminal channel bars
            for node in layout.rightNodes {
                let y0 = CGFloat(node.y0) * h
                let y1 = max(y0 + 2, CGFloat(node.y1) * h)
                let ch = channelFromNodeId(node.id)
                let isFocused = (ch != nil && hoveredChannel == ch)
                let col: Color = {
                    if isFocused { return theme.accent }
                    switch ch {
                    case .cacheRead:  return theme.accent
                    case .input:      return theme.inkPrimary.opacity(0.78)
                    case .output:     return theme.inkSecondary
                    case .cacheWrite: return theme.inkMuted
                    case .none:       return theme.inkMuted
                    }
                }()
                context.fill(Path(CGRect(x: w - barW, y: y0, width: barW, height: y1 - y0)), with: .color(col))
            }
        }
        .allowsHitTesting(false)
    }

    private func channelFromNodeId(_ id: String) -> TokenChannel? {
        guard id.hasPrefix("ch_"), let raw = Int(id.dropFirst(3)) else { return nil }
        return TokenChannel(rawValue: raw)
    }

    private func channelTotal(_ channel: TokenChannel) -> Int {
        switch channel {
        case .cacheRead:  return usage.totalCacheRead
        case .input:      return usage.totalInput
        case .output:     return usage.totalOutput
        case .cacheWrite: return usage.totalCacheWrite
        }
    }

    private func channelName(_ channel: TokenChannel) -> String {
        switch channel {
        case .cacheRead:  return loc("tokCacheReadShort")
        case .input:      return loc("tokInputShort")
        case .output:     return loc("tokOutputShort")
        case .cacheWrite: return loc("tokCacheWriteShort")
        }
    }
}

// MARK: - 2. Throughput Density Matrix (30-Day ASCII / Matrix Waterfall)

struct TokenDensityMatrix: View {
    let data: [DailyUsage]
    let year: Int
    let month: Int
    var focusedModelId: String? = nil

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @State private var hoveredDay: Int? = nil

    private let plotHeight: CGFloat = 86
    private let rows = 12

    private var daysInMonth: Int { AppDate.daysInMonth(year: year, month: month) ?? 30 }

    private var dayLookup: [Int: DailyUsage] {
        Dictionary(uniqueKeysWithValues: data.map { ($0.day, $0) })
    }

    private func dayTokens(_ day: Int) -> Double {
        guard let d = dayLookup[day] else { return 0 }
        if let fid = focusedModelId {
            return Double(d.models.first(where: { $0.id == fid })?.totalTokens ?? 0)
        }
        return Double(d.totalTokens)
    }

    private var maxValue: Double {
        let m = (1...daysInMonth).map { dayTokens($0) }.max() ?? 0
        return max(m, Double(data.map(\.totalTokens).max() ?? 0))
    }

    private var avgValue: Double {
        UsageTelemetryLogic.dailyAverage(daily: data, modeIsCost: false)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow

            ZStack(alignment: .top) {
                ZStack {
                    DotGraticuleBackground(spacing: 11)
                    matrixCanvas
                    hoverTargetOverlay
                }
                .frame(height: plotHeight)

                if let day = hoveredDay {
                    DailyTelemetryTooltip(
                        day: day,
                        month: month,
                        daysInMonth: daysInMonth,
                        usage: dayLookup[day],
                        modeIsCost: false
                    )
                }
            }

            xAxisLabels
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var headerRow: some View {
        let monthStr = String(format: "%04d.%02d", year, month)
        let avgText = formatTokensShort(Int(avgValue)).uppercased()
        let maxText = formatTokensShort(Int(maxValue)).uppercased()
        return HStack(spacing: 4) {
            Text("\(loc("densityMatrixTitle")) // \(monthStr)")
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundColor(theme.inkSecondary)
            Spacer()
            Text("\(String(format: loc("avgFmt"), avgText))/D · \(String(format: loc("maxFmt"), maxText))")
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .foregroundColor(theme.inkMuted)
        }
    }

    private var matrixCanvas: some View {
        Canvas { context, size in
            let count = max(1, daysInMonth)
            let slotW = size.width / CGFloat(count)
            let cellH = (size.height - 6) / CGFloat(rows)
            let cellW = max(3.0, min(6.5, slotW * 0.65))
            let ceilMax = max(1.0, maxValue)

            for day in 1...daysInMonth {
                let val = dayTokens(day)
                let cx = (CGFloat(day) - 0.5) * slotW
                let x = cx - cellW * 0.5
                let isDayHovered = (hoveredDay == day)
                let dayDimmed = (hoveredDay != nil && !isDayHovered)

                let ratio = val > 0 ? min(1.0, val / ceilMax) : 0
                let activeRows = val > 0 ? max(1, Int((ratio * Double(rows)).rounded(.up))) : 0
                let level = InstrumentMath.densityLevel(value: val, maxValue: ceilMax)

                for r in 0..<rows {
                    let rowFromBottom = r
                    let ry = size.height - 3 - CGFloat(rowFromBottom + 1) * cellH + cellH * 0.16
                    let rh = max(1.5, cellH * 0.68)

                    if rowFromBottom < activeRows {
                        // High-throughput crest cells glow in accent; low-level baseline days stay tonal
                        let isCrest = (rowFromBottom == activeRows - 1)
                        let rowIntensity = Double(level) / 5.0
                        let useAccent = (level >= 4 && rowFromBottom >= activeRows - 2) || (isCrest && level >= 3)
                        let tint = useAccent
                            ? theme.accent
                            : theme.inkPrimary.opacity(0.30 + 0.55 * rowIntensity)
                        let finalColor = dayDimmed ? tint.opacity(0.24) : tint

                        if level == 5 || isCrest {
                            context.fill(Path(CGRect(x: x, y: ry, width: cellW, height: rh)), with: .color(finalColor))
                        } else if level >= 3 {
                            // Double micro-bar glyph `=`
                            let halfH = max(1.0, rh * 0.36)
                            context.fill(Path(CGRect(x: x, y: ry, width: cellW, height: halfH)), with: .color(finalColor))
                            context.fill(Path(CGRect(x: x, y: ry + rh - halfH, width: cellW, height: halfH)), with: .color(finalColor))
                        } else {
                            // Crisp center micro-cross / pip `·`
                            let pipW = max(2.0, cellW * 0.55)
                            context.fill(
                                Path(CGRect(x: cx - pipW * 0.5, y: ry + (rh - 2) * 0.5, width: pipW, height: 2)),
                                with: .color(finalColor)
                            )
                        }
                    } else {
                        // Inactive sparse dot matrix coordinate
                        context.fill(
                            Path(CGRect(x: cx - 0.5, y: ry + rh * 0.5 - 0.5, width: 1, height: 1)),
                            with: .color(theme.hairline.opacity(0.65))
                        )
                    }
                }

                if isDayHovered {
                    var vline = Path()
                    vline.move(to: CGPoint(x: cx, y: 0))
                    vline.addLine(to: CGPoint(x: cx, y: size.height))
                    context.stroke(vline, with: .color(theme.reticle), lineWidth: 1)

                    if activeRows > 0 {
                        let peakY = size.height - 3 - CGFloat(activeRows) * cellH
                        context.fill(Path(CGRect(x: cx - 2, y: peakY - 2, width: 4, height: 4)),
                                     with: .color(theme.accent))
                    }
                }
            }

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
}
