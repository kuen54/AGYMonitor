import SwiftUI
import AppKit

// Cost Tab Instrument Visualizations:
// 1. Stratigraphic Borehole Core Column + Leader-Line Callouts (Ref 3 Polar geological column)
// 2. Topographic Ridgeline Elevation Plot + Peak Target Lock (Ref 2/3 contour field)

// MARK: - 1. Stratigraphic Borehole Section

struct BoreholeModelSection: View {
    let usage: PeriodUsage
    @Binding var focusedModelId: String?

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme

    private var visibleModels: [ModelUsage] {
        usage.models.filter { $0.cost >= 0.005 }
    }

    private let rowHeight: CGFloat = 22
    private let coreWidth: CGFloat = 28
    private let leaderWidth: CGFloat = 24

    var body: some View {
        let models = visibleModels
        let totalCost = usage.cost > 0 ? usage.cost : models.reduce(0.0) { $0 + $1.cost }
        let slices = InstrumentMath.buildBoreholeSlices(
            items: models.map { ($0.id, $0.cost) },
            minSliceFraction: 0.065
        )
        let diagramHeight = max(66, CGFloat(models.count) * rowHeight)

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(loc("boreholeTitle"))
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundColor(theme.inkSecondary)
                Spacer()
                if let fid = focusedModelId, let fm = models.first(where: { $0.id == fid }) {
                    Text("\(fm.shortCode) · \(formatCostTabular(fm.cost))")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.accent)
                } else {
                    Text(String(format: "%02d STRATA", models.count))
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.inkMuted)
                }
            }

            if models.isEmpty {
                Text(loc("noData").uppercased())
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.inkMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 14)
            } else {
                HStack(spacing: 0) {
                    boreholeCoreColumn(models: models, slices: slices, height: diagramHeight)
                        .frame(width: coreWidth + 8, height: diagramHeight)

                    leaderLinesCanvas(models: models, slices: slices, height: diagramHeight)
                        .frame(width: leaderWidth, height: diagramHeight)

                    VStack(spacing: 0) {
                        ForEach(models) { m in
                            modelCalloutRow(m, totalCost: totalCost)
                                .frame(height: rowHeight)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func boreholeCoreColumn(
        models: [ModelUsage],
        slices: [BoreholeSlice],
        height: CGFloat
    ) -> some View {
        let modelById = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        let coreX: CGFloat = 8

        return ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let coreRect = CGRect(x: coreX, y: 0.5, width: coreWidth, height: size.height - 1)
                context.fill(Path(coreRect), with: .color(theme.surface))

                // Left-edge borehole depth ruler ticks
                for step in 0...4 {
                    let ty = 0.5 + (size.height - 1) * CGFloat(step) / 4.0
                    var tick = Path()
                    tick.move(to: CGPoint(x: 2, y: ty))
                    tick.addLine(to: CGPoint(x: coreX, y: ty))
                    context.stroke(tick, with: .color(theme.hairlineStrong), lineWidth: 1)
                }

                // Draw geological core strata layers
                for slice in slices {
                    guard let m = modelById[slice.id] else { continue }
                    let y0 = CGFloat(slice.yStart) * (size.height - 1) + 0.5
                    let y1 = CGFloat(slice.yEnd) * (size.height - 1) + 0.5
                    let rect = CGRect(x: coreX + 0.5, y: y0, width: coreWidth - 1, height: max(1, y1 - y0))

                    let isFocused = (focusedModelId == m.id)
                    let anyFocused = (focusedModelId != nil)
                    let baseColor = theme.modelColor(m.modelClass, focused: isFocused, anyFocused: anyFocused)
                    var ctx = context
                    drawStrataRect(
                        in: &ctx,
                        rect: rect,
                        color: baseColor,
                        pattern: theme.modelPattern(m.modelClass)
                    )

                    // Bedding plane seam
                    if slice.yEnd < 0.999 {
                        var seam = Path()
                        seam.move(to: CGPoint(x: coreX, y: y1))
                        seam.addLine(to: CGPoint(x: coreX + coreWidth, y: y1))
                        context.stroke(seam, with: .color(theme.canvas.opacity(0.85)), lineWidth: 1)
                    }

                    // Active cobalt/accent core indicator along right wall when focused
                    if isFocused {
                        context.fill(
                            Path(CGRect(x: coreX + coreWidth - 2.5, y: y0, width: 2.5, height: max(2, y1 - y0))),
                            with: .color(theme.accent)
                        )
                    }
                }

                // Crisp outer casing frame
                context.stroke(Path(coreRect), with: .color(theme.hairlineStrong), lineWidth: 1)
            }

            // Direct slice hover hit targets aligned with core column
            ForEach(slices) { slice in
                let y0 = CGFloat(slice.yStart) * height
                let h = max(8, CGFloat(slice.yEnd - slice.yStart) * height)
                Color.clear
                    .frame(width: coreWidth + 8, height: h)
                    .contentShape(Rectangle())
                    .offset(y: y0)
                    .onHover { inside in
                        focusedModelId = inside ? slice.id : (focusedModelId == slice.id ? nil : focusedModelId)
                    }
            }
        }
    }

    private func leaderLinesCanvas(
        models: [ModelUsage],
        slices: [BoreholeSlice],
        height: CGFloat
    ) -> some View {
        let sliceById = Dictionary(uniqueKeysWithValues: slices.map { ($0.id, $0) })

        return Canvas { context, size in
            for (idx, m) in models.enumerated() {
                guard let slice = sliceById[m.id] else { continue }
                let sy = CGFloat(slice.midY) * size.height
                let ry = (CGFloat(idx) + 0.5) * rowHeight
                let isFocused = (focusedModelId == m.id)
                let anyFocused = (focusedModelId != nil)

                let lineColor: Color = {
                    if isFocused { return theme.accent }
                    if anyFocused { return theme.hairline }
                    return theme.hairlineStrong
                }()

                var path = Path()
                path.move(to: CGPoint(x: 0, y: sy))
                path.addLine(to: CGPoint(x: size.width * 0.36, y: sy))
                path.addLine(to: CGPoint(x: size.width * 0.68, y: ry))
                path.addLine(to: CGPoint(x: size.width - 2, y: ry))
                context.stroke(path, with: .color(lineColor), lineWidth: isFocused ? 1.3 : 0.85)

                let dotSize: CGFloat = isFocused ? 3.5 : 2.5
                context.fill(
                    Path(CGRect(
                        x: size.width - dotSize,
                        y: ry - dotSize * 0.5,
                        width: dotSize,
                        height: dotSize
                    )),
                    with: .color(isFocused ? theme.accent : theme.inkSecondary.opacity(anyFocused ? 0.3 : 0.75))
                )
            }
        }
        .allowsHitTesting(false)
    }

    private func modelCalloutRow(_ m: ModelUsage, totalCost: Double) -> some View {
        let fraction = totalCost > 0 ? max(0, min(1, m.cost / totalCost)) : 0
        let pctStr = String(format: "%.1f%%", fraction * 100.0)
        let isFocused = (focusedModelId == m.id)
        let anyFocused = (focusedModelId != nil)
        let swatchColor = theme.modelColor(m.modelClass, focused: isFocused, anyFocused: anyFocused)
        let pattern = theme.modelPattern(m.modelClass)

        return HStack(spacing: 6) {
            StrataSwatch(color: swatchColor, pattern: pattern, size: 7)
            Text(m.shortCode)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundColor(isFocused ? theme.accent : theme.inkPrimary)
            Text(m.name)
                .font(.system(size: 10.5))
                .foregroundColor(theme.inkSecondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(pctStr)
                .font(.system(size: 9.5, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(theme.inkMuted)
                .frame(width: 40, alignment: .trailing)

            Text(formatCostTabular(m.cost))
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(isFocused ? theme.accent : theme.inkPrimary)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .background(isFocused ? theme.surfaceRaised.opacity(0.92) : Color.clear)
        .contentShape(Rectangle())
        .onHover { inside in
            focusedModelId = inside ? m.id : (focusedModelId == m.id ? nil : focusedModelId)
        }
    }
}

// MARK: - 2. Topographic Ridgeline Chart (Daily Cost Elevation Field)

struct TopographicRidgeChart: View {
    let data: [DailyUsage]
    let year: Int
    let month: Int
    var focusedModelId: String? = nil

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @State private var hoveredDay: Int? = nil

    private let plotHeight: CGFloat = 104

    private var daysInMonth: Int { AppDate.daysInMonth(year: year, month: month) ?? 30 }

    private var dayLookup: [Int: DailyUsage] {
        Dictionary(uniqueKeysWithValues: data.map { ($0.day, $0) })
    }

    private var dailyValues: [Double] {
        (1...daysInMonth).map { day in
            guard let d = dayLookup[day] else { return 0 }
            return d.cost
        }
    }

    private var maxValue: Double {
        dailyValues.max() ?? 0
    }

    private var avgValue: Double {
        UsageTelemetryLogic.dailyAverage(daily: data, modeIsCost: true)
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
                    ridgeCanvas
                    hoverTargetOverlay
                }
                .frame(height: plotHeight)

                if let day = hoveredDay {
                    DailyTelemetryTooltip(
                        day: day,
                        month: month,
                        daysInMonth: daysInMonth,
                        usage: dayLookup[day],
                        modeIsCost: true
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
        let avgText = formatCost(avgValue)
        let maxText = formatCost(maxValue)
        return HStack(spacing: 4) {
            Text("\(loc("topoRidgeTitle")) // \(monthStr)")
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundColor(theme.inkSecondary)
            Spacer()
            Text("\(String(format: loc("avgFmt"), avgText))/D · \(String(format: loc("maxFmt"), maxText))")
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .foregroundColor(theme.inkMuted)
        }
    }

    private var ridgeCanvas: some View {
        let values = dailyValues
        let ridge = InstrumentMath.buildTopographicRidges(dailyValues: values, layerCount: 6, samplesPerDay: 4)

        // Optional focused-model elevation overlay normalized to the same month max ceiling
        let focusedValues: [Double]? = focusedModelId.map { fid in
            (1...daysInMonth).map { day in
                dayLookup[day]?.models.first(where: { $0.id == fid })?.cost ?? 0
            }
        }

        return Canvas { context, size in
            let topPad: CGFloat = 14
            let baseY = size.height - 1
            let usableH = max(12, baseY - topPad)

            func toCanvasPoint(_ p: Point2D) -> CGPoint {
                CGPoint(x: CGFloat(p.x) * size.width, y: baseY - CGFloat(p.y) * usableH)
            }

            // 1. Deterministic sparse survey `+` markers above the terrain ridge (Ref 3)
            let surveyMarkers: [(Double, Double)] = [
                (0.08, 0.16), (0.21, 0.11), (0.37, 0.24), (0.58, 0.14),
                (0.74, 0.28), (0.89, 0.15), (0.94, 0.34),
            ]
            for (sx, sy) in surveyMarkers {
                let mx = CGFloat(sx) * size.width
                let my = CGFloat(sy) * size.height
                var plus = Path()
                plus.move(to: CGPoint(x: mx - 2.5, y: my))
                plus.addLine(to: CGPoint(x: mx + 2.5, y: my))
                plus.move(to: CGPoint(x: mx, y: my - 2.5))
                plus.addLine(to: CGPoint(x: mx, y: my + 2.5))
                context.stroke(plus, with: .color(theme.reticle.opacity(0.42)), lineWidth: 0.85)
            }

            // 2. Dashed monthly average horizontal reference rule
            if ridge.maxValue > 0 && avgValue > 0 {
                let ratio = min(1.0, avgValue / ridge.maxValue)
                let ay = baseY - CGFloat(ratio) * usableH
                var dash = Path()
                dash.move(to: CGPoint(x: 0, y: ay))
                dash.addLine(to: CGPoint(x: size.width, y: ay))
                context.stroke(dash, with: .color(theme.hairlineStrong.opacity(0.85)),
                               style: StrokeStyle(lineWidth: 0.9, dash: [3, 3]))
            }

            // 3. Multi-layer topographic ridge fill + nested contour lines
            if let outerLayer = ridge.layers.first, outerLayer.points.count >= 2 {
                var silhouette = Path()
                let firstPt = toCanvasPoint(outerLayer.points[0])
                silhouette.move(to: CGPoint(x: firstPt.x, y: baseY))
                for pt in outerLayer.points {
                    silhouette.addLine(to: toCanvasPoint(pt))
                }
                if let lastPt = outerLayer.points.last {
                    silhouette.addLine(to: CGPoint(x: toCanvasPoint(lastPt).x, y: baseY))
                }
                silhouette.closeSubpath()

                let crestColor = focusedModelId == nil ? theme.accent : theme.inkMuted
                context.fill(
                    silhouette,
                    with: .linearGradient(
                        Gradient(colors: [
                            crestColor.opacity(theme.isDark ? 0.22 : 0.14),
                            crestColor.opacity(0.02),
                        ]),
                        startPoint: CGPoint(x: 0, y: topPad),
                        endPoint: CGPoint(x: 0, y: baseY)
                    )
                )

                // Draw lower internal contour isolines bottom-up, then main crest on top
                for layer in ridge.layers.dropFirst().reversed() {
                    guard layer.points.count >= 2 else { continue }
                    var line = Path()
                    line.move(to: toCanvasPoint(layer.points[0]))
                    for pt in layer.points.dropFirst() {
                        line.addLine(to: toCanvasPoint(pt))
                    }
                    let alpha = (0.18 + 0.34 * layer.factor) * (focusedModelId == nil ? 1.0 : 0.45)
                    context.stroke(line, with: .color(theme.inkSecondary.opacity(alpha)), lineWidth: 0.85)
                }

                // Stipple vertical texture columns under notable peaks (top 30% elevation)
                for (dIdx, anchor) in ridge.dayAnchors.enumerated() where anchor.y > 0.38 {
                    let pt = toCanvasPoint(anchor)
                    var y = pt.y + 5
                    var step = 0
                    while y < baseY - 3 {
                        if (dIdx + step) % 2 == 0 {
                            context.fill(
                                Path(CGRect(x: pt.x - 0.5, y: y, width: 1.1, height: 1.1)),
                                with: .color(theme.inkSecondary.opacity(0.28))
                            )
                        }
                        y += 4.0
                        step += 1
                    }
                }

                // Primary ridge crest stroke (+ subtle dark-mode optical glow)
                var crestPath = Path()
                crestPath.move(to: firstPt)
                for pt in outerLayer.points.dropFirst() {
                    crestPath.addLine(to: toCanvasPoint(pt))
                }
                if theme.isDark && focusedModelId == nil {
                    context.stroke(crestPath, with: .color(theme.accent.opacity(0.26)), lineWidth: 4.0)
                }
                context.stroke(
                    crestPath,
                    with: .color(focusedModelId == nil ? theme.accent : theme.hairlineStrong),
                    lineWidth: focusedModelId == nil ? 1.5 : 1.0
                )
            }

            // 4. Focused model isolated ridge curve when hovering a Borehole stratum
            if let fVals = focusedValues, ridge.maxValue > 0 {
                let fAnchors: [Point2D] = fVals.enumerated().map { idx, val in
                    let nx = (Double(idx) + 0.5) / Double(max(1, fVals.count))
                    let ny = min(1.0, max(0.0, val / ridge.maxValue))
                    return Point2D(x: nx, y: ny)
                }
                if fAnchors.count >= 2 {
                    var fArea = Path()
                    let p0 = toCanvasPoint(fAnchors[0])
                    fArea.move(to: CGPoint(x: p0.x, y: baseY))
                    fArea.addLine(to: p0)
                    for a in fAnchors.dropFirst() {
                        fArea.addLine(to: toCanvasPoint(a))
                    }
                    fArea.addLine(to: CGPoint(x: toCanvasPoint(fAnchors.last!).x, y: baseY))
                    fArea.closeSubpath()
                    context.fill(fArea, with: .color(theme.accent.opacity(0.22)))

                    var fLine = Path()
                    fLine.move(to: p0)
                    for a in fAnchors.dropFirst() {
                        fLine.addLine(to: toCanvasPoint(a))
                    }
                    context.stroke(fLine, with: .color(theme.accent), lineWidth: 1.6)
                }
            }

            // 5. Peak HUD lock reticle + coordinate callout (when not actively hovering a day)
            if hoveredDay == nil,
               let pIdx = ridge.peakIndex,
               pIdx < ridge.dayAnchors.count,
               focusedModelId == nil {
                let peakPt = toCanvasPoint(ridge.dayAnchors[pIdx])
                drawHUDReticle(in: &context, center: peakPt, radius: 5.5, color: theme.accent)
                context.fill(
                    Path(CGRect(x: peakPt.x - 1.5, y: peakPt.y - 1.5, width: 3, height: 3)),
                    with: .color(theme.accent)
                )

                let tagStr = "\(loc("peakTag")) D\(String(format: "%02d", pIdx + 1)) · \(formatCost(ridge.peakValue))"
                let labelRight = ridge.dayAnchors[pIdx].x < 0.62
                let elbowX = peakPt.x + (labelRight ? 16 : -16)
                let elbowY = max(9, peakPt.y - 4)
                var leader = Path()
                leader.move(to: CGPoint(x: peakPt.x + (labelRight ? 6.5 : -6.5), y: peakPt.y))
                leader.addLine(to: CGPoint(x: elbowX, y: elbowY))
                leader.addLine(to: CGPoint(x: elbowX + (labelRight ? 6 : -6), y: elbowY))
                context.stroke(leader, with: .color(theme.accent.opacity(0.8)), lineWidth: 0.9)

                let text = Text(tagStr)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.accent)
                let textX = labelRight
                    ? min(size.width - 4, elbowX + 9)
                    : max(4, elbowX - 9)
                context.draw(
                    text,
                    at: CGPoint(x: textX, y: elbowY),
                    anchor: labelRight ? .leading : .trailing
                )
            }

            // 6. Interactive hover crosshair + target vertex lock
            if let day = hoveredDay, day >= 1, day <= ridge.dayAnchors.count {
                let anchor = ridge.dayAnchors[day - 1]
                let pt = toCanvasPoint(anchor)

                var vline = Path()
                vline.move(to: CGPoint(x: pt.x, y: 0))
                vline.addLine(to: CGPoint(x: pt.x, y: baseY))
                context.stroke(vline, with: .color(theme.reticle), lineWidth: 1)

                var hline = Path()
                hline.move(to: CGPoint(x: 0, y: pt.y))
                hline.addLine(to: CGPoint(x: size.width, y: pt.y))
                context.stroke(hline, with: .color(theme.reticle.opacity(0.5)),
                               style: StrokeStyle(lineWidth: 0.9, dash: [2, 2]))

                drawHUDReticle(in: &context, center: pt, radius: 5.5, color: theme.accent)
                context.fill(Path(CGRect(x: pt.x - 2, y: pt.y - 2, width: 4, height: 4)),
                             with: .color(theme.accent))
            }

            // 7. Baseline rule
            context.fill(Path(CGRect(x: 0, y: baseY, width: size.width, height: 0.8)),
                         with: .color(theme.hairlineStrong))
        }
    }

    private func drawHUDReticle(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat, color: Color) {
        let len: CGFloat = 3.0
        let minX = center.x - radius, maxX = center.x + radius
        let minY = center.y - radius, maxY = center.y + radius
        var p = Path()
        p.move(to: CGPoint(x: minX, y: minY + len)); p.addLine(to: CGPoint(x: minX, y: minY)); p.addLine(to: CGPoint(x: minX + len, y: minY))
        p.move(to: CGPoint(x: maxX - len, y: minY)); p.addLine(to: CGPoint(x: maxX, y: minY)); p.addLine(to: CGPoint(x: maxX, y: minY + len))
        p.move(to: CGPoint(x: minX, y: maxY - len)); p.addLine(to: CGPoint(x: minX, y: maxY)); p.addLine(to: CGPoint(x: minX + len, y: maxY))
        p.move(to: CGPoint(x: maxX - len, y: maxY)); p.addLine(to: CGPoint(x: maxX, y: maxY)); p.addLine(to: CGPoint(x: maxX, y: maxY - len))
        context.stroke(p, with: .color(color), lineWidth: 1.0)
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
