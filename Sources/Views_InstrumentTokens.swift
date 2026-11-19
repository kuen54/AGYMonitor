import SwiftUI
import AppKit

// Tokens Tab Specimen Artifact Visualizations:
// Inspired by archival technical prints (Emil Widlund / Polar Blueprint) & precision optical HUDs (Fred):
// 0. TokensInstrumentView — unified specimen header, de-slabbed hairline scope strip & editorial colophon
// 1. FoldedTokenFlowChart — Monochrome archival folded Bezier stream with single dominant-link 1% accent,
//    upper-edge stipple grain, center calibration meridian, and 00/50/100 depth ruler
// 2. TokenDensityMatrix — Generative halftone stippled signal spectrogram (plotHeight 118pt) with
//    3 elevation contour hairlines, Fred peak reticle HUD (PK.XX + X/Y), and 60Hz hover overlay

// MARK: - 0. Unified Tokens Specimen View

struct TokensInstrumentView: View {
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
    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @State private var hoveredScope: UsagePeriodScope? = nil

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

    private var cacheHitPct: Double? {
        UsageTelemetryLogic.cacheHitPercent(input: usage.totalInput, cacheRead: usage.totalCacheRead)
    }

    var body: some View {
        VStack(spacing: 0) {
            specimenHeader

            if let bundle = bundle, let binding = selectedScope {
                HairlineRule(showCrosshairs: false)
                hairlineScopeStrip(bundle: bundle, binding: binding)
            }

            HairlineRule(showCrosshairs: true)

            FoldedTokenFlowChart(
                usage: usage,
                focusedModelId: $focusedModelId
            )

            if let daily = dailyBreakdown, !daily.isEmpty {
                HairlineRule(showCrosshairs: true)
                TokenDensityMatrix(
                    data: daily,
                    year: year,
                    month: month,
                    focusedModelId: focusedModelId
                )
            }

            HairlineRule(showCrosshairs: false)
            specimenColophon
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
            )
        ) { _ in
            reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }

    // MARK: Specimen Header

    private var specimenHeader: some View {
        let parts = splitTokenParts(usage.totalTokens)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text("02.")
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.accent)
                Text("\(loc("tokensTag")) // \(scopeTitle.uppercased())")
                    .font(.system(size: 8.5, weight: .regular, design: .monospaced))
                    .tracking(1.0)
                    .foregroundColor(theme.inkMuted)

                Spacer(minLength: 4)

                if let hit = cacheHitPct {
                    Text(String(format: loc("cacheHitFmt"), Int(hit.rounded())).uppercased())
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(theme.accentSecondary)
                }
            }

            HStack(alignment: .firstTextBaseline) {
                PrecisionHeroNumber(
                    whole: parts.number,
                    suffix: parts.unit.isEmpty ? nil : parts.unit,
                    size: 40,
                    weight: .ultraLight
                )

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2.5) {
                    Text("\(formatNumber(usage.totalMessages)) MSG")
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundColor(theme.inkMuted)
                    Text(formatCostTabular(usage.cost))
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .monospacedDigit()
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
        let monthTotal = max(0, bundle.month.totalTokens)
        let scopes: [(scope: UsagePeriodScope, title: String, tokens: Int)] = [
            (.today, loc("periodTodayShort"), bundle.today.totalTokens),
            (.week,  loc("periodWeekShort"),  bundle.week.totalTokens),
            (.month, loc("periodMonthShort"), bundle.month.totalTokens),
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
                        Text(activeScopeSublabel(scope: item.scope, tokens: item.tokens, monthTotal: monthTotal))
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(theme.accent)
                    } else {
                        Text(formatTokensShort(item.tokens).uppercased())
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
                            Rectangle()
                                .fill(theme.accent)
                                .frame(height: 1.5)
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
                    binding.wrappedValue = item.scope
                }

                if idx < scopes.count - 1 {
                    Rectangle().fill(theme.hairline.opacity(0.8)).frame(width: 1)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func activeScopeSublabel(scope: UsagePeriodScope, tokens: Int, monthTotal: Int) -> String {
        switch scope {
        case .today:
            if monthTotal > 0 {
                let pct = Int(((Double(tokens) / Double(monthTotal)) * 100.0).rounded())
                return String(format: "%02d%% OF MO", min(100, max(0, pct)))
            }
            return "ACTIVE"
        case .week:
            if monthTotal > 0 {
                let pct = Int(((Double(tokens) / Double(monthTotal)) * 100.0).rounded())
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
            Text("* Token counts combine uncached input, completion, and prompt-cache reads")
                .font(.system(size: 8.5, weight: .regular, design: .serif))
                .italic()
                .foregroundColor(theme.inkMuted)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("FIG. 02")
                .font(.system(size: 7.5, weight: .regular, design: .monospaced))
                .tracking(0.8)
                .foregroundColor(theme.inkMuted.opacity(0.75))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

// MARK: - Shared Deterministic Stipple Hash & Ridge Sampler

fileprivate func tokenStippleHash(_ a: Int, _ b: Int, _ salt: Int = 0) -> UInt32 {
    var h = UInt32(truncatingIfNeeded: a &* 374761393 &+ b &* 668265263 ^ salt &* 83492791)
    h = (h ^ (h >> 13)) &* 1274126177
    return h ^ (h >> 16)
}

fileprivate func sampleTokenRidgeCrestNormY(outerPoints: [Point2D], at nx: Double) -> Double {
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

// MARK: - 1. Plate 02.1 — Hero Folded Token Flow (Emil Widlund Polar Blueprint Stream)

struct FoldedTokenFlowChart: View {
    let usage: PeriodUsage
    @Binding var focusedModelId: String?

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @Environment(\.telemetryStaticRender) private var isStaticRender
    @State private var hoveredChannel: TokenChannel? = nil

    private let layout: TokenFlowLayout
    private let modelById: [String: ModelUsage]
    private let dominantLinkId: String?
    private let dominantModelId: String?
    private let dominantChannel: TokenChannel
    private let channelTotals: [TokenChannel: Int]
    private let leftLabelCenters: [CGFloat]
    private let rightLabelCenters: [CGFloat]
    private let leftLabelCenterDoubles: [Double]
    private let rightLabelCenterDoubles: [Double]
    private let leftNodeIds: [String]
    private let rightNodeIds: [String]

    fileprivate static let flowHeight: CGFloat = 158
    fileprivate static let leftLabelWidth: CGFloat = 88
    fileprivate static let rightLabelWidth: CGFloat = 94
    fileprivate static let leftBarX: CGFloat = 15.0
    fileprivate static let barW: CGFloat = 2.5

    init(usage: PeriodUsage, focusedModelId: Binding<String?>) {
        self.usage = usage
        self._focusedModelId = focusedModelId

        let built = InstrumentMath.buildTokenFlowLayout(
            models: usage.models,
            maxModels: 6,
            nodeGap: 0.042
        )
        self.layout = built
        self.modelById = Dictionary(uniqueKeysWithValues: usage.models.map { ($0.id, $0) })
        self.channelTotals = [
            .cacheRead: usage.totalCacheRead,
            .input: usage.totalInput,
            .output: usage.totalOutput,
            .cacheWrite: usage.totalCacheWrite,
        ]

        // Strictly single largest flow ribbon (e.g., CRB → CACHE RD) carries the 1% accent at rest
        let dominantLink = built.links.max(by: { $0.value < $1.value })
        self.dominantLinkId = dominantLink?.id
        self.dominantModelId = dominantLink?.modelId
        if let domCh = dominantLink?.channel {
            self.dominantChannel = domCh
        } else if built.rightNodes.contains(where: { Self.channelFromNodeId($0.id) == .cacheRead }) {
            self.dominantChannel = .cacheRead
        } else {
            self.dominantChannel = built.rightNodes
                .max(by: { $0.value < $1.value })
                .flatMap { Self.channelFromNodeId($0.id) } ?? .cacheRead
        }

        let leftCenters = Self.resolveLabelCenters(
            rawCenters: built.leftNodes.map { CGFloat($0.midY) * Self.flowHeight },
            minSpacing: 16,
            height: Self.flowHeight
        )
        let rightCenters = Self.resolveLabelCenters(
            rawCenters: built.rightNodes.map { CGFloat($0.midY) * Self.flowHeight },
            minSpacing: 18,
            height: Self.flowHeight
        )
        self.leftLabelCenters = leftCenters
        self.rightLabelCenters = rightCenters
        self.leftLabelCenterDoubles = leftCenters.map(Double.init)
        self.rightLabelCenterDoubles = rightCenters.map(Double.init)
        self.leftNodeIds = built.leftNodes.map(\.id)
        self.rightNodeIds = built.rightNodes.map(\.id)
    }

    private struct FlowArtworkKey: Hashable {
        let leftIds: [String]
        let leftVals: [Int]
        let rightIds: [String]
        let rightVals: [Int]
        let linkVals: [Int]
        let dominantLinkId: String?
        let theme: AGYTheme.CacheKey
    }

    var body: some View {
        let anyFocus = (focusedModelId != nil || hoveredChannel != nil)
        let flowKey = FlowArtworkKey(
            leftIds: leftNodeIds,
            leftVals: layout.leftNodes.map(\.value),
            rightIds: rightNodeIds,
            rightVals: layout.rightNodes.map(\.value),
            linkVals: layout.links.map(\.value),
            dominantLinkId: dominantLinkId,
            theme: theme.cacheKey
        )

        VStack(alignment: .leading, spacing: 7) {
            headerRow

            if layout.leftNodes.isEmpty {
                Text(loc("noData").uppercased())
                    .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                    .foregroundColor(theme.inkMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                HStack(spacing: 3) {
                    leftModelColumn

                    GeometryReader { geo in
                        ZStack {
                            CachedTelemetryArtwork(
                                key: flowKey,
                                width: geo.size.width,
                                height: Self.flowHeight
                            ) {
                                FoldedFlowBaseCanvas(
                                    layout: layout,
                                    dominantLinkId: dominantLinkId,
                                    theme: theme
                                )
                            }
                            .opacity(anyFocus ? 0.22 : 1.0)

                            if anyFocus {
                                FoldedFlowFocusCanvas(
                                    layout: layout,
                                    focusedModelId: focusedModelId,
                                    hoveredChannel: hoveredChannel,
                                    theme: theme
                                )
                            }
                        }
                    }
                    .frame(height: Self.flowHeight)
                    .allowsHitTesting(false)

                    rightChannelColumn
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var headerRow: some View {
        HStack(spacing: 5) {
            Text("02.1")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.accent.opacity(0.9))
            Text(loc("tokenFlowTitle"))
                .font(.system(size: 8, weight: .regular, design: .monospaced))
                .tracking(0.8)
                .foregroundColor(theme.inkSecondary)

            Spacer(minLength: 4)

            if let ch = hoveredChannel {
                let chVal = channelTotals[ch] ?? 0
                let pct = layout.totalTokens > 0
                    ? Int((Double(chVal) / Double(layout.totalTokens) * 100.0).rounded())
                    : 0
                Text("→ \(channelName(ch)) · \(formatTokensShort(chVal).uppercased()) (\(pct)%)")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(theme.accentSecondary)
            } else if let fid = focusedModelId, let m = modelById[fid] {
                let hit = UsageTelemetryLogic.cacheHitPercent(input: m.inputTokens, cacheRead: m.cacheRead)
                    .map { "HIT \(Int($0.rounded()))%" } ?? formatTokensShort(m.totalTokens).uppercased()
                Text("\(m.shortCode) · \(formatTokensShort(m.totalTokens).uppercased()) · \(hit)")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(theme.accent)
            } else {
                HStack(spacing: 3) {
                    Text(String(format: "%02d MOD", layout.leftNodes.count))
                        .foregroundColor(theme.inkMuted)
                    Text("→")
                        .foregroundColor(theme.inkMuted)
                    Text(String(format: "%02d CH", layout.rightNodes.count))
                        .foregroundColor(theme.accentSecondary.opacity(theme.isDark ? 0.90 : 0.85))
                }
                .font(.system(size: 8, weight: .regular, design: .monospaced))
                .monospacedDigit()
            }
        }
    }

    private var leftModelColumn: some View {
        let connectedToHoveredChannel: Set<String> = {
            guard let ch = hoveredChannel else { return [] }
            return Set(layout.links.filter { $0.channel == ch }.map(\.modelId))
        }()
        let anyFocus = (focusedModelId != nil || hoveredChannel != nil)

        return ZStack(alignment: .topLeading) {
            ForEach(Array(layout.leftNodes.enumerated()), id: \.element.id) { idx, node in
                let isFocused = (focusedModelId == node.id)
                let isDominant = (node.id == dominantModelId)
                let isChannelLinked = (hoveredChannel != nil && connectedToHoveredChannel.contains(node.id))
                let isDimmed: Bool = {
                    if let fid = focusedModelId { return fid != node.id }
                    if hoveredChannel != nil { return !isChannelLinked }
                    return false
                }()
                let cy = idx < leftLabelCenters.count ? leftLabelCenters[idx] : CGFloat(node.midY) * Self.flowHeight

                HStack(spacing: 3) {
                    Text(String(format: "%02d", idx + 1))
                        .font(.system(size: 7, weight: .regular, design: .monospaced))
                        .foregroundColor(
                            isFocused
                                ? theme.accent
                                : (isDominant && !anyFocus ? theme.accent.opacity(0.88) : theme.inkMuted.opacity(0.75))
                        )
                        .frame(width: 12, alignment: .leading)

                    Text(node.label)
                        .font(.system(size: 8.5, weight: (isFocused || (isDominant && !anyFocus)) ? .medium : .regular, design: .monospaced))
                        .foregroundColor(isFocused ? theme.accent : theme.inkPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 2)

                    Text(formatTokensShort(node.value).uppercased())
                        .font(.system(size: 8.5, weight: (isFocused || (isDominant && !anyFocus)) ? .medium : .regular, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(
                            isFocused
                                ? theme.accent
                                : (isDominant && !anyFocus ? theme.accent.opacity(0.92) : theme.inkSecondary)
                        )
                        .lineLimit(1)
                }
                .padding(.horizontal, 3)
                .frame(width: Self.leftLabelWidth, height: 15)
                .background(isFocused ? theme.accent.opacity(theme.isDark ? 0.12 : 0.06) : Color.clear)
                .opacity(isDimmed ? 0.36 : 1.0)
                .position(x: Self.leftLabelWidth * 0.5, y: cy)
                .allowsHitTesting(false)
            }
        }
        .frame(width: Self.leftLabelWidth, height: Self.flowHeight)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let pt):
                let hit = InstrumentMath.hitTestLabelCenters(
                    y: Double(pt.y),
                    centers: leftLabelCenterDoubles,
                    ids: leftNodeIds,
                    maxDistance: 12.0
                )
                if focusedModelId != hit {
                    focusedModelId = hit
                }
            case .ended:
                if focusedModelId != nil {
                    focusedModelId = nil
                }
            }
        }
    }

    private var rightChannelColumn: some View {
        let connectedToFocusedModel: Set<TokenChannel> = {
            guard let fid = focusedModelId else { return [] }
            return Set(layout.links.filter { $0.modelId == fid }.map(\.channel))
        }()
        let anyFocus = (hoveredChannel != nil || focusedModelId != nil)

        return ZStack(alignment: .topLeading) {
            ForEach(Array(layout.rightNodes.enumerated()), id: \.element.id) { idx, node in
                let ch = Self.channelFromNodeId(node.id)
                let isFocused = (ch != nil && hoveredChannel == ch)
                let isDominant = (ch == dominantChannel)
                let isModelLinked = (ch != nil && focusedModelId != nil && connectedToFocusedModel.contains(ch!))
                let isDimmed: Bool = {
                    if hoveredChannel != nil { return !isFocused }
                    if focusedModelId != nil { return !isModelLinked }
                    return false
                }()
                let pct = layout.totalTokens > 0
                    ? Int((Double(node.value) / Double(layout.totalTokens) * 100.0).rounded())
                    : 0
                let cy = idx < rightLabelCenters.count ? rightLabelCenters[idx] : CGFloat(node.midY) * Self.flowHeight

                HStack(spacing: 3) {
                    Text(channelName(ch ?? .cacheRead))
                        .font(.system(size: 8.5, weight: (isFocused || (isDominant && !anyFocus)) ? .medium : .regular, design: .monospaced))
                        .foregroundColor(
                            isFocused
                                ? theme.accentSecondary
                                : (isDominant && !anyFocus
                                   ? theme.accentSecondary
                                   : theme.accentSecondary.opacity(theme.isDark ? 0.80 : 0.78))
                        )
                        .lineLimit(1)

                    Spacer(minLength: 2)

                    Text("\(pct)%")
                        .font(.system(size: 8.5, weight: (isFocused || (isDominant && !anyFocus)) ? .medium : .regular, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(
                            isFocused
                                ? theme.accentSecondary
                                : (isDominant && !anyFocus ? theme.accentSecondary.opacity(0.95) : theme.inkMuted)
                        )
                        .lineLimit(1)
                }
                .padding(.horizontal, 3)
                .frame(width: Self.rightLabelWidth, height: 15)
                .background(isFocused ? theme.accentSecondary.opacity(theme.isDark ? 0.14 : 0.08) : Color.clear)
                .opacity(isDimmed ? 0.36 : 1.0)
                .position(x: Self.rightLabelWidth * 0.5, y: cy)
                .allowsHitTesting(false)
            }
        }
        .frame(width: Self.rightLabelWidth, height: Self.flowHeight)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let pt):
                let hitId = InstrumentMath.hitTestLabelCenters(
                    y: Double(pt.y),
                    centers: rightLabelCenterDoubles,
                    ids: rightNodeIds,
                    maxDistance: 12.0
                )
                let hitChannel = hitId.flatMap { Self.channelFromNodeId($0) }
                if hoveredChannel != hitChannel {
                    hoveredChannel = hitChannel
                }
            case .ended:
                if hoveredChannel != nil {
                    hoveredChannel = nil
                }
            }
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

    fileprivate static func channelFromNodeId(_ id: String) -> TokenChannel? {
        guard id.hasPrefix("ch_"), let raw = Int(id.dropFirst(3)) else { return nil }
        return TokenChannel(rawValue: raw)
    }

    private static func resolveLabelCenters(
        rawCenters: [CGFloat],
        minSpacing: CGFloat,
        height: CGFloat
    ) -> [CGFloat] {
        guard !rawCenters.isEmpty else { return [] }
        let pad = minSpacing * 0.5
        var ys = rawCenters.map { min(max(pad, $0), height - pad) }
        guard ys.count > 1 else { return ys }

        for i in 1..<ys.count {
            if ys[i] < ys[i - 1] + minSpacing {
                ys[i] = ys[i - 1] + minSpacing
            }
        }
        let maxY = height - pad
        if ys[ys.count - 1] > maxY {
            ys[ys.count - 1] = maxY
            for i in stride(from: ys.count - 2, through: 0, by: -1) {
                if ys[i] > ys[i + 1] - minSpacing {
                    ys[i] = ys[i + 1] - minSpacing
                }
            }
        }
        return ys.map { min(max(pad, $0), maxY) }
    }

    fileprivate static func appendLinkPaths(
        _ link: FlowLink,
        width w: CGFloat,
        height h: CGFloat,
        leftBarX: CGFloat,
        barW: CGFloat,
        fills: inout Path,
        outerEdges: inout Path,
        internalFolds: inout Path,
        upperStipple: inout Path,
        includeStipple: Bool
    ) {
        let x0 = leftBarX + barW + 1.0
        let x1 = w - barW - 1.0
        let spanX = max(1, x1 - x0)
        let ctrlX1 = x0 + spanX * 0.44
        let ctrlX2 = x0 + spanX * 0.56

        let sy0 = CGFloat(link.srcY0) * h
        let sy1 = max(sy0 + 0.9, CGFloat(link.srcY1) * h)
        let dy0 = CGFloat(link.dstY0) * h
        let dy1 = max(dy0 + 0.9, CGFloat(link.dstY1) * h)

        fills.move(to: CGPoint(x: x0, y: sy0))
        fills.addCurve(
            to: CGPoint(x: x1, y: dy0),
            control1: CGPoint(x: ctrlX1, y: sy0),
            control2: CGPoint(x: ctrlX2, y: dy0)
        )
        fills.addLine(to: CGPoint(x: x1, y: dy1))
        fills.addCurve(
            to: CGPoint(x: x0, y: sy1),
            control1: CGPoint(x: ctrlX2, y: dy1),
            control2: CGPoint(x: ctrlX1, y: sy1)
        )
        fills.closeSubpath()

        outerEdges.move(to: CGPoint(x: x0, y: sy0))
        outerEdges.addCurve(
            to: CGPoint(x: x1, y: dy0),
            control1: CGPoint(x: ctrlX1, y: sy0),
            control2: CGPoint(x: ctrlX2, y: dy0)
        )

        let avgThick = ((sy1 - sy0) + (dy1 - dy0)) * 0.5
        if avgThick >= 2.2 {
            outerEdges.move(to: CGPoint(x: x0, y: sy1))
            outerEdges.addCurve(
                to: CGPoint(x: x1, y: dy1),
                control1: CGPoint(x: ctrlX1, y: sy1),
                control2: CGPoint(x: ctrlX2, y: dy1)
            )
        }

        // 3-5 crisp internal Bezier fold hairlines inside wide ribbons (Polar Blueprint ref2)
        let internalCount: Int
        if avgThick >= 28 {
            internalCount = 5
        } else if avgThick >= 16 {
            internalCount = 4
        } else if avgThick >= 9 {
            internalCount = 3
        } else if avgThick >= 5 {
            internalCount = 2
        } else if avgThick >= 3.0 {
            internalCount = 1
        } else {
            internalCount = 0
        }

        if internalCount > 0 {
            for k in 1...internalCount {
                let frac = CGFloat(k) / CGFloat(internalCount + 1)
                let sy = sy0 + (sy1 - sy0) * frac
                let dy = dy0 + (dy1 - dy0) * frac
                internalFolds.move(to: CGPoint(x: x0, y: sy))
                internalFolds.addCurve(
                    to: CGPoint(x: x1, y: dy),
                    control1: CGPoint(x: ctrlX1, y: sy),
                    control2: CGPoint(x: ctrlX2, y: dy)
                )
            }
        }

        // Subtle deterministic archival stipple grain along the upper edge of the stream
        if includeStipple && avgThick >= 3.5 {
            let steps = max(18, Int(spanX / 3.4))
            let bandMax = min(CGFloat(11.0), avgThick * 0.45)
            let depthRows = max(2, min(4, Int((bandMax / 2.6).rounded(.up))))
            let salt = link.channel.rawValue &* 31 &+ link.value

            for i in 1..<steps {
                let t = CGFloat(i) / CGFloat(steps)
                let u = 1.0 - t
                let u2 = u * u
                let t2 = t * t
                let w0 = u2 * u
                let w1 = 3.0 * u2 * t
                let w2 = 3.0 * u * t2
                let w3 = t2 * t

                let bx = w0 * x0 + w1 * ctrlX1 + w2 * ctrlX2 + w3 * x1
                let yTop = w0 * sy0 + w1 * sy0 + w2 * dy0 + w3 * dy0
                let yBot = w0 * sy1 + w1 * sy1 + w2 * dy1 + w3 * dy1
                let localThick = max(1.0, yBot - yTop)
                let maxDepth = min(bandMax, localThick - 1.2)
                guard maxDepth >= 1.2 else { continue }

                for r in 0..<depthRows {
                    let hVal = tokenStippleHash(i, r, salt)
                    let baseDepth = (CGFloat(r) + 0.55) * (maxDepth / CGFloat(depthRows))
                    let jx = (CGFloat(hVal & 0xFF) / 255.0 - 0.5) * 2.2
                    let jy = (CGFloat((hVal >> 8) & 0xFF) / 255.0 - 0.5) * 1.4
                    let px = bx + jx
                    let py = yTop + baseDepth + jy
                    guard px > x0 + 1.5, px < x1 - 1.5, py > yTop + 0.5, py < yBot - 0.8 else { continue }

                    let decay = exp(-Double(py - yTop) / 5.2)
                    let roll = Double((hVal >> 16) & 0x3FF) / 1023.0
                    if roll < decay * 0.72 {
                        let sz: CGFloat = ((hVal >> 26) & 1 == 0) ? 0.95 : 1.2
                        upperStipple.addRect(CGRect(x: px, y: py, width: sz, height: sz))
                    }
                }
            }
        }
    }
}

/// Static hover-independent folded stream artwork; Equatable so 60Hz hover never redraws it.
private struct FoldedFlowBaseCanvas: View, Equatable {
    let layout: TokenFlowLayout
    let dominantLinkId: String?
    let theme: AGYTheme

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let leftBarX = FoldedTokenFlowChart.leftBarX
            let barW = FoldedTokenFlowChart.barW
            let x0 = leftBarX + barW + 1.0
            let x1 = w - barW - 1.0

            // 1. Subtle vertical center calibration meridian (x = stream midpoint) with fine 3pt ticks every 16pt
            let midX = (x0 + x1) * 0.5
            var spine = Path()
            spine.move(to: CGPoint(x: midX, y: 3))
            spine.addLine(to: CGPoint(x: midX, y: h - 3))
            context.stroke(
                spine,
                with: .color(theme.hairline.opacity(0.70)),
                style: StrokeStyle(lineWidth: 0.65, dash: [2, 3.5])
            )

            var meridianTicks = Path()
            // Top & bottom registration caps
            meridianTicks.move(to: CGPoint(x: midX - 2.5, y: 2.5))
            meridianTicks.addLine(to: CGPoint(x: midX + 2.5, y: 2.5))
            meridianTicks.move(to: CGPoint(x: midX - 2.5, y: h - 2.5))
            meridianTicks.addLine(to: CGPoint(x: midX + 2.5, y: h - 2.5))
            // Fine 3pt horizontal drafting ticks every 16pt along meridian
            var tickY: CGFloat = 16.0
            while tickY <= h - 14.0 {
                meridianTicks.move(to: CGPoint(x: midX - 1.5, y: tickY))
                meridianTicks.addLine(to: CGPoint(x: midX + 1.5, y: tickY))
                tickY += 16.0
            }
            context.stroke(meridianTicks, with: .color(theme.accentSecondary.opacity(theme.isDark ? 0.42 : 0.36)), lineWidth: 0.65)

            // 2. Micro depth ruler (00 / 50 / 100 + 25/75 ticks) along the left terminal bar (ref2 blueprint craft)
            var majorDepthTicks = Path()
            var minorDepthTicks = Path()
            let innerH = max(1, h - 1.0)
            for step in 0...4 {
                let frac = CGFloat(step) / 4.0
                let ty = 0.5 + innerH * frac
                let isMajor = (step == 0 || step == 2 || step == 4)
                let tickLen: CGFloat = isMajor ? 3.2 : 2.0
                if isMajor {
                    majorDepthTicks.move(to: CGPoint(x: leftBarX - tickLen, y: ty))
                    majorDepthTicks.addLine(to: CGPoint(x: leftBarX, y: ty))
                    let depthText = Text(String(format: "%02d", step * 25))
                        .font(.system(size: 6.0, weight: .regular, design: .monospaced))
                        .foregroundColor(theme.inkMuted.opacity(0.80))
                    let labelY = step == 0 ? ty + 3.5 : (step == 4 ? ty - 3.5 : ty)
                    context.draw(depthText, at: CGPoint(x: leftBarX - 4.2, y: labelY), anchor: .trailing)
                } else {
                    minorDepthTicks.move(to: CGPoint(x: leftBarX - tickLen, y: ty))
                    minorDepthTicks.addLine(to: CGPoint(x: leftBarX, y: ty))
                }
            }
            context.stroke(minorDepthTicks, with: .color(theme.hairline.opacity(0.85)), lineWidth: 0.65)
            context.stroke(majorDepthTicks, with: .color(theme.hairlineStrong.opacity(0.90)), lineWidth: 0.7)

            // 3. Batch ALL monochrome archival links + ONLY the single largest dominant link in vivid accent
            var monoFills = Path()
            var monoOuter = Path()
            var monoInternal = Path()
            var monoStipple = Path()

            var accentFills = Path()
            var accentOuter = Path()
            var accentInternal = Path()
            var accentStipple = Path()
            var dominantLink: FlowLink? = nil

            for link in layout.links {
                if link.id == dominantLinkId {
                    dominantLink = link
                    FoldedTokenFlowChart.appendLinkPaths(
                        link, width: w, height: h, leftBarX: leftBarX, barW: barW,
                        fills: &accentFills, outerEdges: &accentOuter,
                        internalFolds: &accentInternal, upperStipple: &accentStipple,
                        includeStipple: true
                    )
                } else {
                    let avgThick = CGFloat(((link.srcY1 - link.srcY0) + (link.dstY1 - link.dstY0)) * 0.5) * h
                    FoldedTokenFlowChart.appendLinkPaths(
                        link, width: w, height: h, leftBarX: leftBarX, barW: barW,
                        fills: &monoFills, outerEdges: &monoOuter,
                        internalFolds: &monoInternal, upperStipple: &monoStipple,
                        includeStipple: avgThick >= 14.0
                    )
                }
            }

            // Draw secondary streams bridging archival left ink into Color 2 (accentSecondary) right channels
            if !monoFills.isEmpty {
                context.fill(
                    monoFills,
                    with: .linearGradient(
                        Gradient(colors: [
                            theme.inkPrimary.opacity(theme.isDark ? 0.09 : 0.055),
                            theme.accentSecondary.opacity(theme.isDark ? 0.15 : 0.105),
                        ]),
                        startPoint: CGPoint(x: x0, y: 0),
                        endPoint: CGPoint(x: x1, y: 0)
                    )
                )
                context.stroke(
                    monoInternal,
                    with: .color(theme.accentSecondary.opacity(theme.isDark ? 0.28 : 0.22)),
                    lineWidth: 0.55
                )
                if !monoStipple.isEmpty {
                    context.fill(
                        monoStipple,
                        with: .color(theme.accentSecondary.opacity(theme.isDark ? 0.36 : 0.28))
                    )
                }
                context.stroke(
                    monoOuter,
                    with: .linearGradient(
                        Gradient(colors: [
                            theme.inkPrimary.opacity(theme.isDark ? 0.42 : 0.34),
                            theme.accentSecondary.opacity(theme.isDark ? 0.60 : 0.52),
                        ]),
                        startPoint: CGPoint(x: x0, y: 0),
                        endPoint: CGPoint(x: x1, y: 0)
                    ),
                    lineWidth: 0.75
                )
            }

            // Draw dominant flow ribbon bridging Color 1 (left model) -> Color 2 (right channel)
            if !accentFills.isEmpty {
                context.fill(
                    accentFills,
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: theme.accent.opacity(theme.isDark ? 0.22 : 0.14), location: 0.0),
                            .init(color: theme.accent.opacity(theme.isDark ? 0.16 : 0.10), location: 0.55),
                            .init(color: theme.accentSecondary.opacity(theme.isDark ? 0.18 : 0.12), location: 1.0),
                        ]),
                        startPoint: CGPoint(x: x0, y: 0),
                        endPoint: CGPoint(x: x1, y: 0)
                    )
                )
                context.stroke(
                    accentInternal,
                    with: .linearGradient(
                        Gradient(colors: [
                            theme.accent.opacity(theme.isDark ? 0.44 : 0.34),
                            theme.accentSecondary.opacity(theme.isDark ? 0.40 : 0.30),
                        ]),
                        startPoint: CGPoint(x: x0, y: 0),
                        endPoint: CGPoint(x: x1, y: 0)
                    ),
                    lineWidth: 0.55
                )
                if !accentStipple.isEmpty {
                    context.fill(accentStipple, with: .color(theme.accent.opacity(theme.isDark ? 0.56 : 0.46)))
                }
                if theme.isDark {
                    context.stroke(
                        accentOuter,
                        with: .linearGradient(
                            Gradient(colors: [
                                theme.accent.opacity(0.20),
                                theme.accentSecondary.opacity(0.16),
                            ]),
                            startPoint: CGPoint(x: x0, y: 0),
                            endPoint: CGPoint(x: x1, y: 0)
                        ),
                        lineWidth: 3.6
                    )
                    context.stroke(accentOuter, with: .color(theme.accent.opacity(0.22)), lineWidth: 1.8)
                }
                context.stroke(
                    accentOuter,
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: theme.accent.opacity(theme.isDark ? 0.96 : 0.90), location: 0.0),
                            .init(color: theme.accent.opacity(theme.isDark ? 0.88 : 0.82), location: 0.52),
                            .init(color: theme.accentSecondary.opacity(theme.isDark ? 0.92 : 0.86), location: 1.0),
                        ]),
                        startPoint: CGPoint(x: x0, y: 0),
                        endPoint: CGPoint(x: x1, y: 0)
                    ),
                    lineWidth: 0.92
                )
            }

            // 4. Batched left (Color 1 anchor) & right (Color 2 anchor) architectural terminal bars
            var leftBars = Path()
            for node in layout.leftNodes {
                let y0 = CGFloat(node.y0) * h
                let y1 = max(y0 + 2, CGFloat(node.y1) * h)
                leftBars.addRect(CGRect(x: leftBarX, y: y0, width: barW, height: y1 - y0))
            }
            context.fill(leftBars, with: .color(theme.inkPrimary.opacity(theme.isDark ? 0.68 : 0.64)))

            var rightBars = Path()
            for node in layout.rightNodes {
                let y0 = CGFloat(node.y0) * h
                let y1 = max(y0 + 2, CGFloat(node.y1) * h)
                rightBars.addRect(CGRect(x: w - barW, y: y0, width: barW, height: y1 - y0))
            }
            context.fill(rightBars, with: .color(theme.accentSecondary.opacity(theme.isDark ? 0.74 : 0.68)))

            if let dom = dominantLink {
                let sy0 = CGFloat(dom.srcY0) * h
                let sy1 = max(sy0 + 2, CGFloat(dom.srcY1) * h)
                let dy0 = CGFloat(dom.dstY0) * h
                let dy1 = max(dy0 + 2, CGFloat(dom.dstY1) * h)
                context.fill(
                    Path(CGRect(x: leftBarX, y: sy0, width: barW, height: sy1 - sy0)),
                    with: .color(theme.accent)
                )
                context.fill(
                    Path(CGRect(x: w - barW, y: dy0, width: barW, height: dy1 - dy0)),
                    with: .color(theme.accentSecondary)
                )
            }
        }
    }
}

/// Lightweight hover isolation overlay drawing ONLY the matched model/channel stream subset.
private struct FoldedFlowFocusCanvas: View {
    let layout: TokenFlowLayout
    let focusedModelId: String?
    let hoveredChannel: TokenChannel?
    let theme: AGYTheme

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let leftBarX = FoldedTokenFlowChart.leftBarX
            let barW = FoldedTokenFlowChart.barW

            var fills = Path()
            var outer = Path()
            var internalFolds = Path()
            var stipple = Path()
            var activeLeftIds = Set<String>()
            var activeRightChannels = Set<TokenChannel>()

            for link in layout.links {
                let matches: Bool = {
                    if let ch = hoveredChannel { return link.channel == ch }
                    if let fid = focusedModelId { return link.modelId == fid }
                    return false
                }()
                guard matches else { continue }
                activeLeftIds.insert(link.modelId)
                activeRightChannels.insert(link.channel)
                FoldedTokenFlowChart.appendLinkPaths(
                    link, width: w, height: h, leftBarX: leftBarX, barW: barW,
                    fills: &fills, outerEdges: &outer,
                    internalFolds: &internalFolds, upperStipple: &stipple,
                    includeStipple: true
                )
            }

            let x0 = leftBarX + barW + 1.0
            let x1 = w - barW - 1.0
            let isChannelFocus = (hoveredChannel != nil)
            let startTint = isChannelFocus ? theme.accent.opacity(0.85) : theme.accent
            let endTint = theme.accentSecondary

            if !fills.isEmpty {
                context.fill(
                    fills,
                    with: .linearGradient(
                        Gradient(colors: [
                            startTint.opacity(theme.isDark ? 0.24 : 0.15),
                            endTint.opacity(theme.isDark ? 0.24 : 0.15),
                        ]),
                        startPoint: CGPoint(x: x0, y: 0),
                        endPoint: CGPoint(x: x1, y: 0)
                    )
                )
                context.stroke(
                    internalFolds,
                    with: .linearGradient(
                        Gradient(colors: [
                            startTint.opacity(theme.isDark ? 0.46 : 0.36),
                            endTint.opacity(theme.isDark ? 0.46 : 0.36),
                        ]),
                        startPoint: CGPoint(x: x0, y: 0),
                        endPoint: CGPoint(x: x1, y: 0)
                    ),
                    lineWidth: 0.55
                )
                if !stipple.isEmpty {
                    context.fill(
                        stipple,
                        with: .color((isChannelFocus ? theme.accentSecondary : theme.accent).opacity(theme.isDark ? 0.58 : 0.48))
                    )
                }
                if theme.isDark {
                    context.stroke(
                        outer,
                        with: .linearGradient(
                            Gradient(colors: [startTint.opacity(0.22), endTint.opacity(0.22)]),
                            startPoint: CGPoint(x: x0, y: 0),
                            endPoint: CGPoint(x: x1, y: 0)
                        ),
                        lineWidth: 3.8
                    )
                }
                context.stroke(
                    outer,
                    with: .linearGradient(
                        Gradient(colors: [startTint, endTint]),
                        startPoint: CGPoint(x: x0, y: 0),
                        endPoint: CGPoint(x: x1, y: 0)
                    ),
                    lineWidth: 1.05
                )
            }

            var leftTermBars = Path()
            for node in layout.leftNodes where activeLeftIds.contains(node.id) {
                let y0 = CGFloat(node.y0) * h
                let y1 = max(y0 + 2, CGFloat(node.y1) * h)
                leftTermBars.addRect(CGRect(x: leftBarX, y: y0, width: barW, height: y1 - y0))
            }
            if !leftTermBars.isEmpty {
                context.fill(leftTermBars, with: .color(theme.accent))
            }

            var rightTermBars = Path()
            for node in layout.rightNodes {
                if let ch = FoldedTokenFlowChart.channelFromNodeId(node.id), activeRightChannels.contains(ch) {
                    let y0 = CGFloat(node.y0) * h
                    let y1 = max(y0 + 2, CGFloat(node.y1) * h)
                    rightTermBars.addRect(CGRect(x: w - barW, y: y0, width: barW, height: y1 - y0))
                }
            }
            if !rightTermBars.isEmpty {
                context.fill(rightTermBars, with: .color(theme.accentSecondary))
            }
        }
    }
}

// MARK: - 2. Plate 02.2 — Generative Stippled Throughput Spectrogram

/// Bounded LRU cache for Hermite throughput envelopes so 60Hz hover and repeated
/// model focus never recompute spline geometry.
private enum TokenThroughputRidgeCache {
    struct Key: Hashable {
        let values: [Int]
        let layerCount: Int
        let samplesPerDay: Int
    }

    private static let lock = NSLock()
    private static var entries: [Key: TopographicRidgeResult] = [:]
    private static var order: [Key] = []
    private static let maxEntries = 12

    static func ridge(dailyValues: [Double], layerCount: Int, samplesPerDay: Int) -> TopographicRidgeResult {
        let key = Key(
            values: dailyValues.map { Int($0.rounded()) },
            layerCount: layerCount,
            samplesPerDay: samplesPerDay
        )

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

        let built = InstrumentMath.buildTopographicRidges(
            dailyValues: dailyValues,
            layerCount: layerCount,
            samplesPerDay: samplesPerDay
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

private struct SpectrogramSnapshot: Equatable {
    let daysInMonth: Int
    let values: [Double]
    let dayCacheHit: [Int?]
    let dayTopCode: [String?]
    let maxValue: Double
    let avgValue: Double
    let isModelIsolated: Bool
}

struct TokenDensityMatrix: View {
    let data: [DailyUsage]
    let year: Int
    let month: Int
    var focusedModelId: String? = nil

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @Environment(\.telemetryStaticRender) private var isStaticRender
    @State private var hoveredDay: Int? = nil

    private let plotHeight: CGFloat = 118
    private let topPad: CGFloat = 20

    private let snapshot: SpectrogramSnapshot
    private let dailyTokenKey: [Int]
    private let ridge: TopographicRidgeResult
    private let focusedRidge: TopographicRidgeResult?
    private let labelDays: [Int]
    private let todayNumberIfViewingCurrentMonth: Int?

    private struct SpectrogramArtworkKey: Hashable {
        let tokens: [Int]
        let avgTokens: Int
        let theme: AGYTheme.CacheKey
    }

    init(data: [DailyUsage], year: Int, month: Int, focusedModelId: String? = nil) {
        self.data = data
        self.year = year
        self.month = month
        self.focusedModelId = focusedModelId

        let totalDays = AppDate.daysInMonth(year: year, month: month) ?? 30
        let lookup = Dictionary(uniqueKeysWithValues: data.map { ($0.day, $0) })

        var totalVals = [Double](repeating: 0, count: totalDays)
        var totalInts = [Int](repeating: 0, count: totalDays)
        var activeVals = [Double](repeating: 0, count: totalDays)
        var hits = [Int?](repeating: nil, count: totalDays)
        var topCodes = [String?](repeating: nil, count: totalDays)

        for day in 1...totalDays {
            let idx = day - 1
            guard let u = lookup[day] else { continue }
            totalVals[idx] = Double(u.totalTokens)
            totalInts[idx] = u.totalTokens

            if let fid = focusedModelId {
                if let m = u.models.first(where: { $0.id == fid }) {
                    activeVals[idx] = Double(m.totalTokens)
                    hits[idx] = UsageTelemetryLogic.cacheHitPercent(input: m.inputTokens, cacheRead: m.cacheRead)
                        .map { Int($0.rounded()) }
                    topCodes[idx] = m.shortCode
                }
            } else {
                activeVals[idx] = Double(u.totalTokens)
                let dayIn = u.models.reduce(0) { $0 + $1.inputTokens }
                let dayCR = u.models.reduce(0) { $0 + $1.cacheRead }
                hits[idx] = UsageTelemetryLogic.cacheHitPercent(input: dayIn, cacheRead: dayCR)
                    .map { Int($0.rounded()) }
                topCodes[idx] = u.models.max(by: { $0.totalTokens < $1.totalTokens })?.shortCode
            }
        }

        let overallMax = totalVals.max() ?? 0
        let avg = UsageTelemetryLogic.dailyAverage(daily: data, modeIsCost: false)
        self.dailyTokenKey = totalInts

        self.ridge = TokenThroughputRidgeCache.ridge(
            dailyValues: totalVals,
            layerCount: 5,
            samplesPerDay: 6
        )

        self.focusedRidge = focusedModelId.map { _ in
            TokenThroughputRidgeCache.ridge(
                dailyValues: activeVals,
                layerCount: 4,
                samplesPerDay: 6
            )
        }

        self.snapshot = SpectrogramSnapshot(
            daysInMonth: totalDays,
            values: activeVals,
            dayCacheHit: hits,
            dayTopCode: topCodes,
            maxValue: overallMax,
            avgValue: avg,
            isModelIsolated: focusedModelId != nil
        )

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
                    // Pre-rendered 2x Retina cached base spectrogram (decoupled from hover AND model focus).
                    CachedTelemetryArtwork(
                        key: SpectrogramArtworkKey(
                            tokens: dailyTokenKey,
                            avgTokens: Int(snapshot.avgValue.rounded()),
                            theme: theme.cacheKey
                        ),
                        width: geo.size.width,
                        height: geo.size.height
                    ) {
                        TokenSpectrogramStaticCanvas(
                            ridge: ridge,
                            avgValue: snapshot.avgValue,
                            topPad: topPad,
                            theme: theme
                        )
                    }
                    .opacity(snapshot.isModelIsolated ? 0.24 : 1.0)
                    .allowsHitTesting(false)

                    // Lightweight focused-model sub-spectrogram mounted ONLY while hovering a model
                    if let fRidge = focusedRidge {
                        FocusedTokenSubSpectrogramCanvas(
                            ridge: ridge,
                            focusedRidge: fRidge,
                            topPad: topPad,
                            theme: theme
                        )
                        .allowsHitTesting(false)
                    }

                    // Lightweight overlay: sky survey crosses, Fred peak reticle HUD, 60Hz hover crosshair
                    TokenSpectrogramOverlayCanvas(
                        ridge: ridge,
                        focusedRidge: focusedRidge,
                        snapshot: snapshot,
                        topPad: topPad,
                        hoveredDay: hoveredDay,
                        theme: theme
                    )
                    .allowsHitTesting(false)

                    hoverTargetOverlay
                }
            }
            .frame(height: plotHeight)

            calibratedDayAxis
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 9)
    }

    private var headerRow: some View {
        let monthStr = String(format: "%04d.%02d", year, month)
        let avgText = formatTokensShort(Int(snapshot.avgValue)).uppercased()
        let maxText = formatTokensShort(Int(snapshot.maxValue)).uppercased()

        return HStack(spacing: 5) {
            Text("02.2")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.accent.opacity(0.9))
            Text("\(loc("densityMatrixTitle")) // \(monthStr)")
                .font(.system(size: 8, weight: .regular, design: .monospaced))
                .tracking(0.8)
                .foregroundColor(theme.inkSecondary)

            Spacer(minLength: 4)

            if let day = hoveredDay, day >= 1, day <= snapshot.daysInMonth {
                let idx = day - 1
                let val = Int(snapshot.values[idx])
                let suffix: String = {
                    if let hit = snapshot.dayCacheHit[idx] {
                        return " · HIT \(hit)%"
                    }
                    if let code = snapshot.dayTopCode[idx] {
                        return " · \(code)"
                    }
                    return ""
                }()
                Text(String(format: "D%02d · %@%@", day, formatTokensShort(val).uppercased(), suffix))
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
                        .foregroundColor(theme.accentSecondary.opacity(theme.isDark ? 0.90 : 0.86))
                    Text("· \(String(format: loc("maxFmt"), maxText))")
                        .foregroundColor(theme.inkMuted)
                }
                .font(.system(size: 8, weight: .regular, design: .monospaced))
                .monospacedDigit()
            }
        }
    }

    /// Single continuous hover tracking rect mapping X -> day in O(1) with zero per-day views.
    private var hoverTargetOverlay: some View {
        let totalDays = max(1, snapshot.daysInMonth)
        return GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let pt):
                        let w = max(1.0, Double(geo.size.width))
                        let nx = min(0.999999, max(0.0, Double(pt.x) / w))
                        let day = min(totalDays, max(1, Int(floor(nx * Double(totalDays))) + 1))
                        if hoveredDay != day {
                            hoveredDay = day
                        }
                    case .ended:
                        if hoveredDay != nil {
                            hoveredDay = nil
                        }
                    }
                }
        }
    }

    private var calibratedDayAxis: some View {
        let labelSet = Set(labelDays)
        let daysCount = snapshot.daysInMonth
        let todayDay = todayNumberIfViewingCurrentMonth

        return VStack(spacing: 3) {
            Canvas { context, size in
                let count = max(1, daysCount)
                let slotW = size.width / CGFloat(count)
                var minorTicks = Path()
                var majorTicks = Path()
                var todayTick = Path()

                for day in 1...daysCount {
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
                let slotW = geo.size.width / CGFloat(max(1, daysCount))
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

/// Static hover- & focus-independent generative stippled spectrogram (3 batched Paths: faintMatrixDots,
/// midSignalStipple, densePeakCrest + 3 whisper-fine 0.55pt elevation contour hairlines + AVG rule).
/// Pre-rendered once into TelemetryArtworkCache so mouse sweeps & model focus NEVER redraw it.
private struct TokenSpectrogramStaticCanvas: View, Equatable {
    let ridge: TopographicRidgeResult
    let avgValue: Double
    let topPad: CGFloat
    let theme: AGYTheme

    /// 4x4 ordered Bayer halftone matrix normalized to [0, 1) for structured spectrogram dithering.
    fileprivate static let bayer4x4: [Double] = [
         0.0 / 16.0,  8.0 / 16.0,  2.0 / 16.0, 10.0 / 16.0,
        12.0 / 16.0,  4.0 / 16.0, 14.0 / 16.0,  6.0 / 16.0,
         3.0 / 16.0, 11.0 / 16.0,  1.0 / 16.0,  9.0 / 16.0,
        15.0 / 16.0,  7.0 / 16.0, 13.0 / 16.0,  5.0 / 16.0,
    ]

    var body: some View {
        Canvas { context, size in
            let baseY = size.height - 1
            let usableH = max(20, baseY - topPad)
            let outerPoints = ridge.layers.first?.points ?? []

            func toPt(_ p: Point2D) -> CGPoint {
                CGPoint(x: CGFloat(p.x) * size.width, y: baseY - CGFloat(p.y) * usableH)
            }

            // 1. Batched Path #1: faintMatrixDots — structured archival coordinate matrix grid
            var faintMatrixDots = Path()
            let bgStepX: CGFloat = 4.8
            let bgStepY: CGFloat = 4.8
            var gy = topPad + 2
            while gy < baseY - 2 {
                var gx: CGFloat = 2.4
                while gx < size.width - 1 {
                    faintMatrixDots.addRect(CGRect(x: gx - 0.42, y: gy - 0.42, width: 0.85, height: 0.85))
                    gx += bgStepX
                }
                gy += bgStepY
            }
            context.fill(faintMatrixDots, with: .color(theme.hairline.opacity(0.46)))

            // 2. Collision-free monthly AVG dashed hairline (Color 2)
            if ridge.maxValue > 0 && avgValue > 0 {
                let avgRatio = min(1.0, avgValue / ridge.maxValue)
                let ay = baseY - CGFloat(avgRatio) * usableH
                var dash = Path()
                dash.move(to: CGPoint(x: 0, y: ay))
                dash.addLine(to: CGPoint(x: size.width, y: ay))
                context.stroke(
                    dash,
                    with: .color(theme.accentSecondary.opacity(theme.isDark ? 0.54 : 0.46)),
                    style: StrokeStyle(lineWidth: 0.75, dash: [2.5, 3.5])
                )

                let leftClear = sampleTokenRidgeCrestNormY(outerPoints: outerPoints, at: 0.04)
                    <= sampleTokenRidgeCrestNormY(outerPoints: outerPoints, at: 0.96)
                let avgTag = Text("AVG")
                    .font(.system(size: 6.5, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.accentSecondary.opacity(theme.isDark ? 0.88 : 0.82))
                context.draw(
                    avgTag,
                    at: CGPoint(x: leftClear ? 2 : size.width - 2, y: max(6, ay - 5)),
                    anchor: leftClear ? .leading : .trailing
                )
            }

            // 3. Generative Halftone Stipple Spectrogram inside the smooth throughput envelope
            if outerPoints.count >= 2 {
                var silhouette = Path()
                let firstPt = toPt(outerPoints[0])
                silhouette.move(to: CGPoint(x: firstPt.x, y: baseY))
                for pt in outerPoints { silhouette.addLine(to: toPt(pt)) }
                silhouette.addLine(to: CGPoint(x: toPt(outerPoints[outerPoints.count - 1]).x, y: baseY))
                silhouette.closeSubpath()

                // 3a. Duotone tonal depth wash: Color 1 peaks shifting into Color 2 valleys
                context.fill(
                    silhouette,
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: theme.accent.opacity(theme.isDark ? 0.14 : 0.085), location: 0.0),
                            .init(color: theme.accentSecondary.opacity(theme.isDark ? 0.10 : 0.065), location: 0.55),
                            .init(color: theme.accentSecondary.opacity(0.010), location: 1.0),
                        ]),
                        startPoint: CGPoint(x: 0, y: topPad),
                        endPoint: CGPoint(x: 0, y: baseY)
                    )
                )

                // 3b. Batched stipple paths: lowerSecondaryStipple (Color 2), midSignalStipple, densePeakCrest (Color 1)
                let cellX: CGFloat = 2.5
                let cellY: CGFloat = 2.5
                let cols = Int(size.width / cellX)
                let rows = Int((baseY - topPad + 2) / cellY)

                var lowerSecondaryStipple = Path()
                var midSignalStipple = Path()
                var densePeakCrest = Path()

                for ix in 0...cols {
                    let px = CGFloat(ix) * cellX
                    let nx = Double(px / max(1, size.width))
                    let crestNorm = sampleTokenRidgeCrestNormY(outerPoints: outerPoints, at: nx)
                    guard crestNorm > 0.02 else { continue }
                    let crestY = baseY - CGFloat(crestNorm) * usableH
                    let localSpan = max(1.0, baseY - crestY)

                    let minRow = max(0, Int((crestY - topPad - 1.5) / cellY))
                    let maxRow = min(rows, Int((baseY - topPad - 1.0) / cellY))
                    guard minRow <= maxRow else { continue }

                    for iy in minRow...maxRow {
                        let py = topPad + CGFloat(iy) * cellY
                        guard py >= crestY - 0.6, py <= baseY - 1.0 else { continue }

                        let elevNorm = Double((baseY - py) / usableH)
                        let relH = min(1.0, max(0.0, Double((baseY - py) / localSpan)))

                        let h = tokenStippleHash(ix, iy, 53)
                        let bayer = Self.bayer4x4[((iy & 3) << 2) | (ix & 3)]
                        let noise = Double(h & 0x3FF) / 1023.0
                        let threshold = 0.64 * bayer + 0.36 * noise

                        // Density rises smoothly from quiet lower halftone into dense signal crest
                        let distBelow = max(0.0, Double(py - crestY))
                        let crestBoost = exp(-distBelow / (14.0 + 16.0 * crestNorm))
                        let targetDensity = min(0.92, 0.14 + 0.34 * relH + 0.44 * crestBoost * (0.45 + 0.55 * crestNorm))

                        guard threshold < targetDensity else { continue }

                        let jx = (CGFloat((h >> 10) & 0x3F) / 63.0 - 0.5) * 0.52
                        let jy = (CGFloat((h >> 16) & 0x3F) / 63.0 - 0.5) * 0.52
                        let dx = px + jx
                        let dy = py + jy
                        guard dx >= 0, dx <= size.width - 1.0, dy <= baseY - 1.0 else { continue }

                        if elevNorm >= 0.82 {
                            // Top peak crest in vivid Color 1 (accent) + delicate horizontal dither ticks
                            if (iy & 1) == 0 && ((h >> 22) & 3) == 0 {
                                densePeakCrest.addRect(CGRect(x: dx - 1.2, y: dy - 0.42, width: 2.5, height: 0.85))
                            } else {
                                let sz: CGFloat = ((h >> 24) & 1 == 0) ? 1.15 : 1.35
                                densePeakCrest.addRect(CGRect(x: dx - sz * 0.5, y: dy - sz * 0.5, width: sz, height: sz))
                            }
                        } else if elevNorm < 0.48 {
                            // Lower/mid secondary stipple field weaving Color 2 (accentSecondary)
                            let sz: CGFloat = relH > 0.52 ? 1.1 : (relH > 0.25 ? 0.95 : 0.85)
                            lowerSecondaryStipple.addRect(CGRect(x: dx - sz * 0.5, y: dy - sz * 0.5, width: sz, height: sz))
                        } else {
                            // Mid-upper core: archival dot-matrix halftone + delicate upper dither ticks
                            if relH > 0.72 && (iy & 1) == 0 && ((h >> 22) & 3) == 0 {
                                midSignalStipple.addRect(CGRect(x: dx - 1.1, y: dy - 0.38, width: 2.2, height: 0.75))
                            } else {
                                let sz: CGFloat = relH > 0.58 ? 1.18 : 1.02
                                midSignalStipple.addRect(CGRect(x: dx - sz * 0.5, y: dy - sz * 0.5, width: sz, height: sz))
                            }
                        }
                    }
                }

                if !lowerSecondaryStipple.isEmpty {
                    context.fill(
                        lowerSecondaryStipple,
                        with: .color(theme.accentSecondary.opacity(theme.isDark ? 0.56 : 0.50))
                    )
                }

                if !midSignalStipple.isEmpty {
                    context.fill(
                        midSignalStipple,
                        with: .color(theme.inkPrimary.opacity(theme.isDark ? 0.64 : 0.56))
                    )
                }

                if !densePeakCrest.isEmpty {
                    if theme.isDark {
                        context.stroke(densePeakCrest, with: .color(theme.accent.opacity(0.24)), lineWidth: 2.2)
                    }
                    context.fill(
                        densePeakCrest,
                        with: .color(theme.accent.opacity(theme.isDark ? 0.96 : 0.92))
                    )
                }

                // 3c. 3 elevation contour hairlines: lower/mid ridge bands in Color 2 -> upper band in Color 1
                for layer in ridge.layers.dropFirst().prefix(3).reversed() {
                    guard layer.points.count >= 2 else { continue }
                    var iso = Path()
                    iso.move(to: toPt(layer.points[0]))
                    for pt in layer.points.dropFirst() { iso.addLine(to: toPt(pt)) }
                    let isoColor: Color
                    if layer.factor < 0.72 {
                        let norm = max(0, min(1, layer.factor / 0.72))
                        isoColor = theme.accentSecondary.opacity(0.30 + 0.25 * norm)
                    } else {
                        isoColor = theme.accent.opacity(theme.isDark ? 0.50 : 0.42)
                    }
                    context.stroke(iso, with: .color(isoColor), lineWidth: 0.62)
                }

                // 3d. Primary throughput envelope crest hairline (+ Color 1 peak bloom & duotone vertical shift)
                var crestPath = Path()
                crestPath.move(to: firstPt)
                for pt in outerPoints.dropFirst() { crestPath.addLine(to: toPt(pt)) }
                context.stroke(
                    crestPath,
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: theme.accent.opacity(theme.isDark ? 0.24 : 0.12), location: 0.0),
                            .init(color: theme.accent.opacity(0.0), location: 0.62),
                        ]),
                        startPoint: CGPoint(x: 0, y: topPad),
                        endPoint: CGPoint(x: 0, y: baseY)
                    ),
                    lineWidth: theme.isDark ? 3.8 : 2.6
                )
                if theme.isDark {
                    context.stroke(crestPath, with: .color(theme.inkPrimary.opacity(0.20)), lineWidth: 1.8)
                }
                context.stroke(
                    crestPath,
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: theme.accent, location: 0.0),
                            .init(color: theme.inkPrimary.opacity(0.86), location: 0.56),
                            .init(color: theme.accentSecondary.opacity(0.80), location: 1.0),
                        ]),
                        startPoint: CGPoint(x: 0, y: topPad),
                        endPoint: CGPoint(x: 0, y: baseY)
                    ),
                    lineWidth: 1.05
                )
            }

            // 4. Crisp calibrated baseline
            context.fill(
                Path(CGRect(x: 0, y: baseY, width: size.width, height: 0.85)),
                with: .color(theme.hairlineStrong)
            )
        }
    }
}

/// Lightweight focused-model sub-spectrogram overlay mounted ONLY while hovering a model in Plate 02.1.
private struct FocusedTokenSubSpectrogramCanvas: View {
    let ridge: TopographicRidgeResult
    let focusedRidge: TopographicRidgeResult
    let topPad: CGFloat
    let theme: AGYTheme

    var body: some View {
        Canvas { context, size in
            let baseY = size.height - 1
            let usableH = max(20, baseY - topPad)

            guard ridge.maxValue > 0,
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
                        theme.accent.opacity(theme.isDark ? 0.26 : 0.18),
                        theme.accent.opacity(0.025),
                    ]),
                    startPoint: CGPoint(x: 0, y: topPad),
                    endPoint: CGPoint(x: 0, y: baseY)
                )
            )

            // Batched halftone stipple inside focused model envelope
            var fStipple = Path()
            let fStep: CGFloat = 3.2
            let fCols = Int(size.width / fStep)
            let fRows = Int((baseY - topPad) / fStep)
            for ix in 0...fCols {
                let px = CGFloat(ix) * fStep
                let nx = Double(px / max(1, size.width))
                let cNorm = sampleTokenRidgeCrestNormY(outerPoints: fOuter.points, at: nx) * scale
                guard cNorm > 0.015 else { continue }
                let cy = baseY - CGFloat(cNorm) * usableH
                let minR = max(0, Int((cy - topPad) / fStep))
                let maxR = min(fRows, Int((baseY - topPad - 1) / fStep))
                guard minR <= maxR else { continue }
                for iy in minR...maxR {
                    let py = topPad + CGFloat(iy) * fStep
                    guard py >= cy else { continue }
                    let bayer = TokenSpectrogramStaticCanvas.bayer4x4[((iy & 3) << 2) | (ix & 3)]
                    let rel = Double((baseY - py) / max(1.0, baseY - cy))
                    if bayer < 0.25 + 0.55 * rel {
                        fStipple.addRect(CGRect(x: px - 0.55, y: py - 0.55, width: 1.1, height: 1.1))
                    }
                }
            }
            if !fStipple.isEmpty {
                context.fill(fStipple, with: .color(theme.accent.opacity(theme.isDark ? 0.64 : 0.54)))
            }

            for sub in focusedRidge.layers.dropFirst() {
                guard sub.points.count >= 2 else { continue }
                var subPath = Path()
                subPath.move(to: toFocusedPt(sub.points[0]))
                for pt in sub.points.dropFirst() { subPath.addLine(to: toFocusedPt(pt)) }
                context.stroke(subPath, with: .color(theme.accent.opacity(0.32 * sub.factor)), lineWidth: 0.55)
            }

            var fCrest = Path()
            fCrest.move(to: fp0)
            for pt in fOuter.points.dropFirst() { fCrest.addLine(to: toFocusedPt(pt)) }
            if theme.isDark {
                context.stroke(fCrest, with: .color(theme.accent.opacity(0.30)), lineWidth: 3.6)
            }
            context.stroke(fCrest, with: .color(theme.accent), lineWidth: 1.3)
        }
    }
}

/// Lightweight overlay Canvas handling sky survey calibration crosses, idle Fred peak reticle HUD
/// (`PK.XX` + `X0.XX Y1.00`), and 60Hz interactive hover crosshair + magnetic vertex lock.
private struct TokenSpectrogramOverlayCanvas: View {
    let ridge: TopographicRidgeResult
    let focusedRidge: TopographicRidgeResult?
    let snapshot: SpectrogramSnapshot
    let topPad: CGFloat
    let hoveredDay: Int?
    let theme: AGYTheme

    var body: some View {
        Canvas { context, size in
            let count = max(1, snapshot.daysInMonth)
            let baseY = size.height - 1
            let usableH = max(20, baseY - topPad)
            let outerPoints = ridge.layers.first?.points ?? []

            func toPt(_ p: Point2D) -> CGPoint {
                CGPoint(x: CGFloat(p.x) * size.width, y: baseY - CGFloat(p.y) * usableH)
            }

            // Pre-compute peak HUD exclusion rect so sky survey `+` crosses never collide with callout text
            let peakLabelRect: CGRect? = {
                guard hoveredDay == nil, !snapshot.isModelIsolated,
                      let pIdx = ridge.peakIndex, pIdx < ridge.dayAnchors.count else { return nil }
                let anchor = ridge.dayAnchors[pIdx]
                let peakPt = toPt(anchor)
                let labelRight = anchor.x < 0.62
                let elbowX = peakPt.x + (labelRight ? 16 : -16)
                let elbowY = max(10, peakPt.y - 5)
                let textX = labelRight ? min(size.width - 2, elbowX + 9) : max(2, elbowX - 9)
                let boxW: CGFloat = 92
                let minX = labelRight ? (textX - 6) : (textX - boxW)
                return CGRect(x: minX, y: elbowY - 12, width: boxW + 8, height: 30)
            }()

            // 1. Batched coordinate-anchored survey `+` calibration crosses in clear sky above signal crest
            var skyCrosses = Path()
            let gridDays = stride(from: 5, through: max(5, count - 2), by: 5)
            let gridElevs: [Double] = [0.42, 0.78]
            for d in gridDays {
                let nx = (Double(d) - 0.5) / Double(count)
                let crestY = baseY - CGFloat(sampleTokenRidgeCrestNormY(outerPoints: outerPoints, at: nx)) * usableH
                let mx = CGFloat(nx) * size.width
                for elev in gridElevs {
                    let my = baseY - CGFloat(elev) * usableH
                    guard my < crestY - 12 else { continue }
                    if let excl = peakLabelRect, excl.contains(CGPoint(x: mx, y: my)) { continue }
                    skyCrosses.move(to: CGPoint(x: mx - 2.0, y: my))
                    skyCrosses.addLine(to: CGPoint(x: mx + 2.0, y: my))
                    skyCrosses.move(to: CGPoint(x: mx, y: my - 2.0))
                    skyCrosses.addLine(to: CGPoint(x: mx, y: my + 2.0))
                }
            }
            if !skyCrosses.isEmpty {
                context.stroke(skyCrosses, with: .color(theme.accentSecondary.opacity(theme.isDark ? 0.44 : 0.36)), lineWidth: 0.72)
            }

            // 2. Interactive 60Hz hover crosshair + magnetic vertex lock
            if let day = hoveredDay, day >= 1, day <= snapshot.daysInMonth {
                let idx = day - 1
                let val = snapshot.values[idx]

                let anchor: Point2D = {
                    if let fRidge = focusedRidge, ridge.maxValue > 0, idx < fRidge.dayAnchors.count {
                        let a = fRidge.dayAnchors[idx]
                        let scale = min(1.0, fRidge.maxValue / ridge.maxValue)
                        return Point2D(x: a.x, y: a.y * scale)
                    }
                    if idx < ridge.dayAnchors.count {
                        return ridge.dayAnchors[idx]
                    }
                    let nx = (Double(day) - 0.5) / Double(count)
                    let ny = snapshot.maxValue > 0 ? min(1.0, val / snapshot.maxValue) : 0
                    return Point2D(x: nx, y: ny)
                }()
                let pt = toPt(anchor)

                // Vertical hairline crosshair
                var vline = Path()
                vline.move(to: CGPoint(x: pt.x, y: 0))
                vline.addLine(to: CGPoint(x: pt.x, y: baseY))
                context.stroke(vline, with: .color(theme.accent.opacity(0.55)), lineWidth: 0.75)

                if val > 0 {
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
                    context.stroke(stem, with: .color(theme.accent), lineWidth: 1.2)

                    drawReticle(in: &context, center: pt, radius: 6.0, color: theme.accent)
                    context.fill(
                        Path(CGRect(x: pt.x - 1.85, y: pt.y - 1.85, width: 3.7, height: 3.7)),
                        with: .color(theme.accent)
                    )
                }

                // Non-occluding Fred micro-HUD tag anchored beside crosshair
                let labelRight = anchor.x < 0.62
                let tagX = labelRight ? min(size.width - 2, pt.x + 10.5) : max(2, pt.x - 10.5)
                let tagY = max(10, min(baseY - 17, pt.y - 6))
                let align: UnitPoint = labelRight ? .leading : .trailing

                let primaryStr = String(format: "D%02d  %@", day, formatTokensShort(Int(val)).uppercased())
                let secondaryStr: String = {
                    if let hit = snapshot.dayCacheHit[idx] {
                        return String(format: "HIT %d%%  Y%.2f", hit, anchor.y)
                    }
                    return String(format: "X%.2f  Y%.2f", anchor.x, anchor.y)
                }()

                let hudLine1 = Text(primaryStr)
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.accent)
                let hudLine2 = Text(secondaryStr)
                    .font(.system(size: 6.8, weight: .regular, design: .monospaced))
                    .foregroundColor(theme.inkSecondary)

                let resolved1 = context.resolve(hudLine1)
                let resolved2 = context.resolve(hudLine2)
                let sz1 = resolved1.measure(in: size)
                let sz2 = resolved2.measure(in: size)
                let maskW = max(sz1.width, sz2.width) + 6
                let maskH = sz1.height + sz2.height + 3
                let maskX = labelRight ? (tagX - 3) : (tagX - maskW + 3)
                context.fill(
                    Path(CGRect(x: maskX, y: tagY - sz1.height * 0.5 - 1, width: maskW, height: maskH)),
                    with: .color(theme.canvas.opacity(0.86))
                )

                context.draw(resolved1, at: CGPoint(x: tagX, y: tagY), anchor: align)
                context.draw(resolved2, at: CGPoint(x: tagX, y: tagY + 8.8), anchor: align)

            } else if !snapshot.isModelIsolated,
                      let pIdx = ridge.peakIndex,
                      pIdx < ridge.dayAnchors.count,
                      ridge.peakValue > 0 {
                // 3. Idle Fred Peak Target Lock HUD (PK.14  130.9M + X0.45  Y1.00)
                let anchor = ridge.dayAnchors[pIdx]
                let peakPt = toPt(anchor)

                if theme.isDark {
                    context.fill(
                        Path(ellipseIn: CGRect(x: peakPt.x - 8, y: peakPt.y - 8, width: 16, height: 16)),
                        with: .color(theme.accent.opacity(0.18))
                    )
                }

                var stem = Path()
                stem.move(to: CGPoint(x: peakPt.x, y: peakPt.y + 6.0))
                stem.addLine(to: CGPoint(x: peakPt.x, y: baseY))
                context.stroke(
                    stem,
                    with: .color(theme.accent.opacity(0.32)),
                    style: StrokeStyle(lineWidth: 0.75, dash: [2, 2.5])
                )

                drawReticle(in: &context, center: peakPt, radius: 6.0, color: theme.accent.opacity(0.90))
                context.fill(
                    Path(CGRect(x: peakPt.x - 1.75, y: peakPt.y - 1.75, width: 3.5, height: 3.5)),
                    with: .color(theme.accent)
                )

                let labelRight = anchor.x < 0.62
                let elbowX = peakPt.x + (labelRight ? 16 : -16)
                let elbowY = max(10, peakPt.y - 5)

                var leader = Path()
                leader.move(to: CGPoint(x: peakPt.x + (labelRight ? 7.0 : -7.0), y: peakPt.y))
                leader.addLine(to: CGPoint(x: elbowX, y: elbowY))
                leader.addLine(to: CGPoint(x: elbowX + (labelRight ? 6.5 : -6.5), y: elbowY))
                context.stroke(leader, with: .color(theme.accent.opacity(0.75)), lineWidth: 0.75)

                let textX = labelRight ? min(size.width - 2, elbowX + 9) : max(2, elbowX - 9)
                let align: UnitPoint = labelRight ? .leading : .trailing

                let line1 = Text(String(format: "PK.%02d  %@", pIdx + 1, formatTokensShort(Int(ridge.peakValue)).uppercased()))
                    .font(.system(size: 7.8, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.accent)
                let line2 = Text(String(format: "X%.2f  Y%.2f", anchor.x, anchor.y))
                    .font(.system(size: 6.6, weight: .regular, design: .monospaced))
                    .foregroundColor(theme.inkMuted)

                let r1 = context.resolve(line1)
                let r2 = context.resolve(line2)
                let sz1 = r1.measure(in: size)
                let sz2 = r2.measure(in: size)
                let maskW = max(sz1.width, sz2.width) + 5
                let maskH = sz1.height + sz2.height + 2.5
                let maskX = labelRight ? (textX - 2.5) : (textX - maskW + 2.5)
                context.fill(
                    Path(CGRect(x: maskX, y: elbowY - sz1.height * 0.5 - 1.5, width: maskW, height: maskH)),
                    with: .color(theme.canvas.opacity(0.84))
                )

                context.draw(r1, at: CGPoint(x: textX, y: elbowY - 0.5), anchor: align)
                context.draw(r2, at: CGPoint(x: textX, y: elbowY + 8.2), anchor: align)
            }
        }
    }

    private func drawReticle(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat, color: Color) {
        let len: CGFloat = 3.0
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
