import Foundation

// MARK: - Unconventional Instrument Geometry & Scalar Field Math — pure core
//
// Foundation-only (part of AGYCore): uses Double instead of CGFloat and imports
// zero UI/App frameworks. Powers Topographic Ridge, Borehole Core Strata,
// Folded Token Flow, 24h Polar Chronometer, Marching-Squares Year Contour Field,
// Orbital Phase Gauge, and Agent Telemetry Radar.

public struct Point2D: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct Segment2D: Equatable, Sendable {
    public let a: Point2D
    public let b: Point2D

    public init(a: Point2D, b: Point2D) {
        self.a = a
        self.b = b
    }
}

// MARK: - 1. Cost: Topographic Ridgeline & Borehole Strata

public struct TopographicRidgeLayer: Equatable, Sendable {
    public let level: Int
    public let factor: Double
    public let points: [Point2D]

    public init(level: Int, factor: Double, points: [Point2D]) {
        self.level = level
        self.factor = factor
        self.points = points
    }
}

public struct TopographicRidgeResult: Equatable, Sendable {
    public let layers: [TopographicRidgeLayer]
    public let dayAnchors: [Point2D]
    public let peakIndex: Int?
    public let peakValue: Double
    public let maxValue: Double

    public init(
        layers: [TopographicRidgeLayer],
        dayAnchors: [Point2D],
        peakIndex: Int?,
        peakValue: Double,
        maxValue: Double
    ) {
        self.layers = layers
        self.dayAnchors = dayAnchors
        self.peakIndex = peakIndex
        self.peakValue = peakValue
        self.maxValue = maxValue
    }
}

public struct BoreholeSlice: Identifiable, Equatable, Sendable {
    public let id: String
    public let fraction: Double
    public let yStart: Double
    public let yEnd: Double

    public var midY: Double { (yStart + yEnd) * 0.5 }

    public init(id: String, fraction: Double, yStart: Double, yEnd: Double) {
        self.id = id
        self.fraction = fraction
        self.yStart = yStart
        self.yEnd = yEnd
    }
}

// MARK: - 2. Tokens: Folded Token Flow

public enum TokenChannel: Int, CaseIterable, Codable, Sendable {
    case cacheRead
    case input
    case output
    case cacheWrite
}

public struct FlowNode: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let value: Int
    public let y0: Double
    public let y1: Double

    public var midY: Double { (y0 + y1) * 0.5 }

    public init(id: String, label: String, value: Int, y0: Double, y1: Double) {
        self.id = id
        self.label = label
        self.value = value
        self.y0 = y0
        self.y1 = y1
    }
}

public struct FlowLink: Identifiable, Equatable, Sendable {
    public let modelId: String
    public let channel: TokenChannel
    public let value: Int
    public let srcY0: Double
    public let srcY1: Double
    public let dstY0: Double
    public let dstY1: Double

    public var id: String { "\(modelId)->\(channel.rawValue)" }

    public init(
        modelId: String,
        channel: TokenChannel,
        value: Int,
        srcY0: Double,
        srcY1: Double,
        dstY0: Double,
        dstY1: Double
    ) {
        self.modelId = modelId
        self.channel = channel
        self.value = value
        self.srcY0 = srcY0
        self.srcY1 = srcY1
        self.dstY0 = dstY0
        self.dstY1 = dstY1
    }
}

public struct TokenFlowLayout: Equatable, Sendable {
    public let leftNodes: [FlowNode]
    public let rightNodes: [FlowNode]
    public let links: [FlowLink]
    public let totalTokens: Int

    public init(
        leftNodes: [FlowNode],
        rightNodes: [FlowNode],
        links: [FlowLink],
        totalTokens: Int
    ) {
        self.leftNodes = leftNodes
        self.rightNodes = rightNodes
        self.links = links
        self.totalTokens = totalTokens
    }
}

// MARK: - 3. Time: 24h Polar Chronometer & Year Marching Squares Contour Field

public struct PolarArc: Equatable, Sendable {
    public let dayIndex: Int
    public let dayKey: String
    public let startAngle: Double
    public let endAngle: Double
    public let interval: ActiveInterval
    public let inMonth: Bool

    public init(
        dayIndex: Int,
        dayKey: String,
        startAngle: Double,
        endAngle: Double,
        interval: ActiveInterval,
        inMonth: Bool
    ) {
        self.dayIndex = dayIndex
        self.dayKey = dayKey
        self.startAngle = startAngle
        self.endAngle = endAngle
        self.interval = interval
        self.inMonth = inMonth
    }
}

public struct ContourLevel: Equatable, Sendable {
    public let level: Int
    public let thresholdHours: Double
    public let segments: [Segment2D]

    public init(level: Int, thresholdHours: Double, segments: [Segment2D]) {
        self.level = level
        self.thresholdHours = thresholdHours
        self.segments = segments
    }
}

public struct ContourPeak: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let hours: Double
    public let dayKey: String

    public init(x: Double, y: Double, hours: Double, dayKey: String) {
        self.x = x
        self.y = y
        self.hours = hours
        self.dayKey = dayKey
    }
}

public struct ContourFieldResult: Equatable, Sendable {
    public let levels: [ContourLevel]
    public let peaks: [ContourPeak]
    public let maxHours: Double

    public init(levels: [ContourLevel], peaks: [ContourPeak], maxHours: Double) {
        self.levels = levels
        self.peaks = peaks
        self.maxHours = maxHours
    }
}

// MARK: - 4. Plan: Orbital Phase Gauge

public struct OrbitalGaugeAngles: Equatable, Sendable {
    public let startAngle: Double
    public let endAngle: Double
    public let remainingEndAngle: Double
    public let paceAngle: Double?
    public let isDeficit: Bool

    public init(
        startAngle: Double,
        endAngle: Double,
        remainingEndAngle: Double,
        paceAngle: Double?,
        isDeficit: Bool
    ) {
        self.startAngle = startAngle
        self.endAngle = endAngle
        self.remainingEndAngle = remainingEndAngle
        self.paceAngle = paceAngle
        self.isDeficit = isDeficit
    }
}

// MARK: - 5. Live Sessions: Agent Telemetry Radar

public struct RadarHub: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let pos: Point2D

    public init(id: String, label: String, pos: Point2D) {
        self.id = id
        self.label = label
        self.pos = pos
    }
}

public struct RadarNode: Identifiable, Equatable, Sendable {
    public let id: String
    public let session: SessionInfo
    public let workspaceLabel: String
    public let surfaceCode: String?
    public let hubPos: Point2D
    public let pos: Point2D
    public let parentNodePos: Point2D?

    public init(
        id: String,
        session: SessionInfo,
        workspaceLabel: String,
        surfaceCode: String?,
        hubPos: Point2D,
        pos: Point2D,
        parentNodePos: Point2D?
    ) {
        self.id = id
        self.session = session
        self.workspaceLabel = workspaceLabel
        self.surfaceCode = surfaceCode
        self.hubPos = hubPos
        self.pos = pos
        self.parentNodePos = parentNodePos
    }
}

public struct SessionRadarLayout: Equatable, Sendable {
    public let hubs: [RadarHub]
    public let nodes: [RadarNode]

    public init(hubs: [RadarHub], nodes: [RadarNode]) {
        self.hubs = hubs
        self.nodes = nodes
    }
}

// MARK: - Pure Math Engine

public enum InstrumentMath {

    // MARK: 1a. Topographic Ridgeline (Monotone Cubic Hermite Spline)

    public static func buildTopographicRidges(
        dailyValues: [Double],
        layerCount: Int = 6,
        samplesPerDay: Int = 4
    ) -> TopographicRidgeResult {
        guard !dailyValues.isEmpty, layerCount >= 1 else {
            return TopographicRidgeResult(layers: [], dayAnchors: [], peakIndex: nil, peakValue: 0, maxValue: 0)
        }

        let sanitized = dailyValues.map { max(0.0, $0) }
        var maxIdx: Int? = nil
        var maxVal: Double = 0
        for (i, v) in sanitized.enumerated() where v > maxVal {
            maxVal = v
            maxIdx = i
        }
        guard maxVal > 0 else {
            return TopographicRidgeResult(layers: [], dayAnchors: [], peakIndex: nil, peakValue: 0, maxValue: 0)
        }

        let n = sanitized.count
        let normalizedY = sanitized.map { min(1.0, max(0.0, $0 / maxVal)) }
        let anchors: [Point2D] = (0..<n).map { i in
            let nx = n == 1 ? 0.5 : (Double(i) + 0.5) / Double(n)
            return Point2D(x: nx, y: normalizedY[i])
        }

        let basePoints = sampleMonotoneHermite(anchors: anchors, samplesPerSegment: max(2, samplesPerDay))
        var layers: [TopographicRidgeLayer] = []
        for layerIdx in 0..<layerCount {
            let factor = layerCount == 1
                ? 1.0
                : max(0.14, 1.0 - Double(layerIdx) * (0.82 / Double(layerCount - 1)))
            let pts = basePoints.map { pt in
                Point2D(x: pt.x, y: min(1.0, max(0.0, pt.y * factor)))
            }
            layers.append(TopographicRidgeLayer(level: layerIdx, factor: factor, points: pts))
        }

        return TopographicRidgeResult(
            layers: layers,
            dayAnchors: anchors,
            peakIndex: maxIdx,
            peakValue: maxVal,
            maxValue: maxVal
        )
    }

    private static func sampleMonotoneHermite(anchors: [Point2D], samplesPerSegment: Int) -> [Point2D] {
        let n = anchors.count
        if n == 1 {
            return [Point2D(x: 0.0, y: anchors[0].y), anchors[0], Point2D(x: 1.0, y: anchors[0].y)]
        }

        // Compute secant slopes between adjacent anchors
        var secants = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let dx = anchors[i + 1].x - anchors[i].x
            secants[i] = dx > 1e-9 ? (anchors[i + 1].y - anchors[i].y) / dx : 0
        }

        // Fritsch-Carlson tangent computation (strictly monotone, zero overshoot)
        var tangents = [Double](repeating: 0, count: n)
        tangents[0] = secants[0]
        tangents[n - 1] = secants[n - 2]
        for i in 1..<(n - 1) {
            let s0 = secants[i - 1]
            let s1 = secants[i]
            if s0 * s1 <= 0 {
                tangents[i] = 0
            } else {
                tangents[i] = (s0 + s1) * 0.5
            }
        }
        for i in 0..<(n - 1) {
            let s = secants[i]
            if abs(s) < 1e-9 {
                tangents[i] = 0
                tangents[i + 1] = 0
            } else {
                let a = tangents[i] / s
                let b = tangents[i + 1] / s
                let mag = a * a + b * b
                if mag > 9.0 {
                    let scale = 3.0 / sqrt(mag)
                    tangents[i] = scale * a * s
                    tangents[i + 1] = scale * b * s
                }
            }
        }

        var out: [Point2D] = []
        // Gentle ramp in from x=0 edge
        out.append(Point2D(x: 0.0, y: anchors[0].y * 0.65))
        for i in 0..<(n - 1) {
            let p0 = anchors[i]
            let p1 = anchors[i + 1]
            let h = p1.x - p0.x
            for s in 0..<samplesPerSegment {
                let t = Double(s) / Double(samplesPerSegment)
                let t2 = t * t
                let t3 = t2 * t
                let h00 = 2 * t3 - 3 * t2 + 1
                let h10 = t3 - 2 * t2 + t
                let h01 = -2 * t3 + 3 * t2
                let h11 = t3 - t2
                let y = h00 * p0.y + h10 * h * tangents[i] + h01 * p1.y + h11 * h * tangents[i + 1]
                out.append(Point2D(x: p0.x + t * h, y: min(1.0, max(0.0, y))))
            }
        }
        out.append(anchors[n - 1])
        out.append(Point2D(x: 1.0, y: anchors[n - 1].y * 0.65))
        return out
    }

    // MARK: 1b. Stratigraphic Borehole

    public static func buildBoreholeSlices(
        items: [(id: String, value: Double)],
        minSliceFraction: Double = 0.06
    ) -> [BoreholeSlice] {
        let positive = items.filter { $0.value > 0 }
        let total = positive.reduce(0.0) { $0 + $1.value }
        guard !positive.isEmpty, total > 0 else { return [] }

        let count = positive.count
        let clampedMin = min(max(0.0, minSliceFraction), 0.85 / Double(count))
        let rawFractions = positive.map { $0.value / total }

        let remainder = max(0.0, 1.0 - Double(count) * clampedMin)
        let visualFractions = rawFractions.map { clampedMin + $0 * remainder }

        var cursor = 0.0
        var slices: [BoreholeSlice] = []
        for (i, item) in positive.enumerated() {
            let yStart = cursor
            let yEnd = (i == count - 1) ? 1.0 : min(1.0, cursor + visualFractions[i])
            slices.append(BoreholeSlice(id: item.id, fraction: rawFractions[i], yStart: yStart, yEnd: yEnd))
            cursor = yEnd
        }
        return slices
    }

    // MARK: 2a. Folded Token Flow (Model -> Token Channel Sankey)

    public static func buildTokenFlowLayout(
        models: [ModelUsage],
        maxModels: Int = 6,
        nodeGap: Double = 0.036
    ) -> TokenFlowLayout {
        let activeModels = models
            .filter { $0.totalTokens > 0 }
            .sorted { $0.totalTokens > $1.totalTokens }
        let keptModels = Array(activeModels.prefix(max(1, maxModels)))
        let total = keptModels.reduce(0) { $0 + $1.totalTokens }
        guard !keptModels.isEmpty, total > 0 else {
            return TokenFlowLayout(leftNodes: [], rightNodes: [], links: [], totalTokens: 0)
        }

        func modelChannelValue(_ m: ModelUsage, _ ch: TokenChannel) -> Int {
            switch ch {
            case .cacheRead:  return max(0, m.cacheRead)
            case .input:      return max(0, m.inputTokens)
            case .output:     return max(0, m.outputTokens)
            case .cacheWrite: return max(0, m.cacheWrite)
            }
        }

        let leftSpans = allocateSpans(
            values: keptModels.map(\.totalTokens),
            minSpan: 0.055,
            gap: nodeGap
        )
        let leftNodes: [FlowNode] = keptModels.enumerated().map { idx, m in
            let mc = ModelClass(rawValue: m.id.lowercased()) ?? ModelClass.classify(m.id)
            return FlowNode(
                id: m.id,
                label: mc.shortCode,
                value: m.totalTokens,
                y0: leftSpans[idx].y0,
                y1: leftSpans[idx].y1
            )
        }

        var activeChannels: [(channel: TokenChannel, total: Int)] = []
        for ch in TokenChannel.allCases {
            let chTotal = keptModels.reduce(0) { $0 + modelChannelValue($1, ch) }
            if chTotal > 0 {
                activeChannels.append((ch, chTotal))
            }
        }
        let rightSpans = allocateSpans(
            values: activeChannels.map(\.total),
            minSpan: 0.065,
            gap: max(nodeGap, 0.045)
        )
        let rightNodes: [FlowNode] = activeChannels.enumerated().map { idx, item in
            FlowNode(
                id: "ch_\(item.channel.rawValue)",
                label: channelTag(item.channel),
                value: item.total,
                y0: rightSpans[idx].y0,
                y1: rightSpans[idx].y1
            )
        }

        // Compute outgoing sub-spans along each left node (in channel order)
        var srcSpans: [String: (Double, Double)] = [:]
        for (idx, m) in keptModels.enumerated() {
            let node = leftNodes[idx]
            let height = node.y1 - node.y0
            let nodeSum = max(1, activeChannels.reduce(0) { $0 + modelChannelValue(m, $1.channel) })
            var cursor = node.y0
            for item in activeChannels {
                let v = modelChannelValue(m, item.channel)
                guard v > 0 else { continue }
                let h = height * (Double(v) / Double(nodeSum))
                srcSpans["\(m.id)->\(item.channel.rawValue)"] = (cursor, cursor + h)
                cursor += h
            }
        }

        // Compute incoming sub-spans along each right node (in matching model order so ribbons stay untangled)
        var dstSpans: [String: (Double, Double)] = [:]
        for (cIdx, item) in activeChannels.enumerated() {
            let node = rightNodes[cIdx]
            let height = node.y1 - node.y0
            var cursor = node.y0
            for m in keptModels {
                let v = modelChannelValue(m, item.channel)
                guard v > 0 else { continue }
                let h = height * (Double(v) / Double(max(1, item.total)))
                dstSpans["\(m.id)->\(item.channel.rawValue)"] = (cursor, cursor + h)
                cursor += h
            }
        }

        var links: [FlowLink] = []
        for m in keptModels {
            for item in activeChannels {
                let v = modelChannelValue(m, item.channel)
                guard v > 0,
                      let s = srcSpans["\(m.id)->\(item.channel.rawValue)"],
                      let d = dstSpans["\(m.id)->\(item.channel.rawValue)"] else { continue }
                links.append(FlowLink(
                    modelId: m.id,
                    channel: item.channel,
                    value: v,
                    srcY0: s.0,
                    srcY1: s.1,
                    dstY0: d.0,
                    dstY1: d.1
                ))
            }
        }

        return TokenFlowLayout(
            leftNodes: leftNodes,
            rightNodes: rightNodes,
            links: links,
            totalTokens: total
        )
    }

    private static func channelTag(_ channel: TokenChannel) -> String {
        switch channel {
        case .cacheRead:  return "CR"
        case .input:      return "IN"
        case .output:     return "OUT"
        case .cacheWrite: return "CW"
        }
    }

    private static func allocateSpans(
        values: [Int],
        minSpan: Double,
        gap: Double
    ) -> [(y0: Double, y1: Double)] {
        let count = values.count
        guard count > 0 else { return [] }
        if count == 1 { return [(0.0, 1.0)] }

        let totalGap = gap * Double(count - 1)
        let usable = max(0.25, 1.0 - totalGap)
        let effMin = min(minSpan, (usable * 0.85) / Double(count))
        let remainder = max(0.0, usable - Double(count) * effMin)
        let sum = Double(max(1, values.reduce(0, +)))

        var spans: [(Double, Double)] = []
        var cursor = 0.0
        for (i, val) in values.enumerated() {
            let h = effMin + remainder * (Double(max(0, val)) / sum)
            let y0 = cursor
            let y1 = (i == count - 1) ? 1.0 : min(1.0, cursor + h)
            spans.append((y0, y1))
            cursor = y1 + gap
        }
        return spans
    }

    // MARK: 2b. Density Matrix Quantizer

    public static func densityLevel(value: Double, maxValue: Double) -> Int {
        guard value > 0, maxValue > 0 else { return 0 }
        let ratio = min(1.0, max(0.0, value / maxValue))
        return 1 + min(4, Int(floor(ratio * 4.999)))
    }

    // MARK: 3a. 24h Polar Chronometer

    public static func polarAngle(secondsOfDay: Int) -> Double {
        let clamped = min(max(secondsOfDay, 0), 86400)
        return -Double.pi * 0.5 + (Double(clamped) / 86400.0) * 2.0 * Double.pi
    }

    public static func buildPolarWeekArcs(
        dayKeys: [String],
        days: [String: DayTimeUsage],
        monthPrefix: String,
        minAngularSeconds: Int = 420
    ) -> [PolarArc] {
        var out: [PolarArc] = []
        let minDelta = Double(max(60, minAngularSeconds)) / 86400.0 * 2.0 * Double.pi
        for (idx, key) in dayKeys.enumerated() {
            let inMonth = key.hasPrefix(monthPrefix)
            guard let day = days[key] else { continue }
            for interval in day.intervals {
                let s = polarAngle(secondsOfDay: interval.startSec)
                var e = polarAngle(secondsOfDay: interval.endSec)
                if e - s < minDelta {
                    e = s + minDelta
                }
                out.append(PolarArc(
                    dayIndex: idx,
                    dayKey: key,
                    startAngle: s,
                    endAngle: e,
                    interval: interval,
                    inMonth: inMonth
                ))
            }
        }
        return out
    }

    public static func hitTestPolarArc(
        dx: Double,
        dy: Double,
        outerRadius: Double,
        ringStep: Double,
        ringCount: Int,
        arcs: [PolarArc]
    ) -> PolarArc? {
        guard ringCount > 0, ringStep > 0 else { return nil }
        let r = hypot(dx, dy)
        let minRadius = outerRadius - Double(ringCount - 1) * ringStep - ringStep * 0.48
        let maxRadius = outerRadius + ringStep * 0.48
        guard r >= minRadius, r <= maxRadius else { return nil }

        var matchedRing: Int? = nil
        var bestDist = Double.greatestFiniteMagnitude
        for idx in 0..<ringCount {
            let ringR = outerRadius - Double(idx) * ringStep
            let d = abs(r - ringR)
            if d <= ringStep * 0.48 && d < bestDist {
                bestDist = d
                matchedRing = idx
            }
        }
        guard let ringIdx = matchedRing else { return nil }

        var angle = atan2(dy, dx)
        if angle < -Double.pi * 0.5 {
            angle += 2.0 * Double.pi
        }
        let tol = 0.035
        return arcs.first { arc in
            guard arc.dayIndex == ringIdx else { return false }
            let start = arc.startAngle - tol
            let end = arc.endAngle + tol
            if angle >= start && angle <= end { return true }
            let wrapped = angle + 2.0 * Double.pi
            return wrapped >= start && wrapped <= end
        }
    }

    // MARK: 3b. Year Marching-Squares Isoline Field

    public static func buildYearContourField(
        days: [String: Int],
        year: Int,
        levelCount: Int = 5
    ) -> ContourFieldResult {
        guard let startMonday = TimeLogic.yearGridStartMonday(year: year), levelCount >= 1 else {
            return ContourFieldResult(levels: [], peaks: [], maxHours: 0)
        }

        let colsRaw = 53
        let rowsRaw = 7
        let yearPrefix = String(format: "%04d-", year)
        var rawGrid = Array(repeating: Array(repeating: 0.0, count: colsRaw), count: rowsRaw)
        var rawKeys = Array(repeating: Array(repeating: "", count: colsRaw), count: rowsRaw)
        var maxRawHours = 0.0

        for row in 0..<rowsRaw {
            for col in 0..<colsRaw {
                if let key = TimeLogic.dayKey(col: col, row: row, startMonday: startMonday),
                   key.hasPrefix(yearPrefix) {
                    rawKeys[row][col] = key
                    let hrs = Double(max(0, days[key] ?? 0)) / 3600.0
                    rawGrid[row][col] = hrs
                    if hrs > maxRawHours { maxRawHours = hrs }
                }
            }
        }

        guard maxRawHours > 0 else {
            return ContourFieldResult(levels: [], peaks: [], maxHours: 0)
        }

        // Upsample Y 2x + zero border pad so Marching Squares contours form closed topographic loops
        let cols = colsRaw + 2   // 55: interior 1...53
        let rows = 15            // interior 1...13 maps Y 0...6 at 0.5 row steps
        var field = Array(repeating: Array(repeating: 0.0, count: cols), count: rows)
        for c in 0..<colsRaw {
            for yr in 0..<13 {
                let fy = Double(yr) * 0.5
                let r0 = min(rowsRaw - 1, Int(floor(fy)))
                let r1 = min(rowsRaw - 1, r0 + 1)
                let frac = fy - Double(r0)
                let val = rawGrid[r0][c] * (1.0 - frac) + rawGrid[r1][c] * frac
                field[yr + 1][c + 1] = val
            }
        }

        // Two separable smoothing passes keeping zero perimeter intact
        field = smoothField(field, passes: 2)

        var smoothPeak = 0.0
        for row in field {
            for v in row where v > smoothPeak { smoothPeak = v }
        }
        guard smoothPeak > 0.01 else {
            return ContourFieldResult(levels: [], peaks: [], maxHours: maxRawHours)
        }

        let ratios: [Double] = (0..<levelCount).map { idx in
            0.16 + (0.68 * Double(idx)) / Double(max(1, levelCount - 1))
        }

        var levels: [ContourLevel] = []
        for (idx, ratio) in ratios.enumerated() {
            let threshold = smoothPeak * ratio
            let segs = marchingSquaresSegments(field: field, threshold: threshold)
            levels.append(ContourLevel(level: idx, thresholdHours: threshold, segments: segs))
        }

        // Pick up to 3 well-separated high-elevation peaks for cartographic `[H]` callouts
        var candidates: [(col: Int, row: Int, hours: Double, key: String)] = []
        for r in 0..<rowsRaw {
            for c in 0..<colsRaw {
                let hrs = rawGrid[r][c]
                guard hrs >= 0.5 else { continue }
                candidates.append((c, r, hrs, rawKeys[r][c]))
            }
        }
        candidates.sort { $0.hours > $1.hours }

        var peaks: [ContourPeak] = []
        for cand in candidates {
            let nx = (Double(cand.col) + 0.5) / Double(colsRaw)
            let ny = (Double(cand.row) + 0.5) / Double(rowsRaw)
            if peaks.allSatisfy({ abs($0.x - nx) >= 0.16 }) {
                peaks.append(ContourPeak(x: nx, y: ny, hours: cand.hours, dayKey: cand.key))
                if peaks.count == 3 { break }
            }
        }

        return ContourFieldResult(levels: levels, peaks: peaks, maxHours: maxRawHours)
    }

    private static func smoothField(_ input: [[Double]], passes: Int) -> [[Double]] {
        let rows = input.count
        let cols = input.first?.count ?? 0
        guard rows > 2, cols > 2 else { return input }
        var current = input
        for _ in 0..<passes {
            var temp = current
            for r in 1..<(rows - 1) {
                for c in 1..<(cols - 1) {
                    temp[r][c] = 0.25 * current[r][c - 1] + 0.5 * current[r][c] + 0.25 * current[r][c + 1]
                }
            }
            var next = temp
            for r in 1..<(rows - 1) {
                for c in 1..<(cols - 1) {
                    next[r][c] = 0.25 * temp[r - 1][c] + 0.5 * temp[r][c] + 0.25 * temp[r + 1][c]
                }
            }
            current = next
        }
        return current
    }

    private static func marchingSquaresSegments(field: [[Double]], threshold: Double) -> [Segment2D] {
        let rows = field.count
        let cols = field.first?.count ?? 0
        guard rows >= 2, cols >= 2 else { return [] }

        let xDenom = Double(max(1, cols - 2))
        let yDenom = Double(max(1, rows - 2))

        func normX(_ gridC: Double) -> Double {
            min(1.0, max(0.0, (gridC - 0.5) / xDenom))
        }
        func normY(_ gridR: Double) -> Double {
            min(1.0, max(0.0, (gridR - 0.5) / yDenom))
        }
        func interp(_ v1: Double, _ v2: Double) -> Double {
            let dv = v2 - v1
            if abs(dv) < 1e-9 { return 0.5 }
            return min(1.0, max(0.0, (threshold - v1) / dv))
        }

        var segments: [Segment2D] = []
        for r in 0..<(rows - 1) {
            for c in 0..<(cols - 1) {
                let tl = field[r][c]
                let tr = field[r][c + 1]
                let br = field[r + 1][c + 1]
                let bl = field[r + 1][c]

                let mask = (tl >= threshold ? 8 : 0)
                    | (tr >= threshold ? 4 : 0)
                    | (br >= threshold ? 2 : 0)
                    | (bl >= threshold ? 1 : 0)
                if mask == 0 || mask == 15 { continue }

                let fc = Double(c)
                let fr = Double(r)
                let top    = Point2D(x: normX(fc + interp(tl, tr)), y: normY(fr))
                let right  = Point2D(x: normX(fc + 1.0),             y: normY(fr + interp(tr, br)))
                let bottom = Point2D(x: normX(fc + interp(bl, br)), y: normY(fr + 1.0))
                let left   = Point2D(x: normX(fc),                   y: normY(fr + interp(tl, bl)))

                switch mask {
                case 1:  segments.append(Segment2D(a: left,   b: bottom))
                case 2:  segments.append(Segment2D(a: bottom, b: right))
                case 3:  segments.append(Segment2D(a: left,   b: right))
                case 4:  segments.append(Segment2D(a: top,    b: right))
                case 5:
                    let center = (tl + tr + br + bl) * 0.25
                    if center >= threshold {
                        segments.append(Segment2D(a: left, b: top))
                        segments.append(Segment2D(a: bottom, b: right))
                    } else {
                        segments.append(Segment2D(a: left, b: bottom))
                        segments.append(Segment2D(a: top, b: right))
                    }
                case 6:  segments.append(Segment2D(a: top,    b: bottom))
                case 7:  segments.append(Segment2D(a: left,   b: top))
                case 8:  segments.append(Segment2D(a: left,   b: top))
                case 9:  segments.append(Segment2D(a: top,    b: bottom))
                case 10:
                    let center = (tl + tr + br + bl) * 0.25
                    if center >= threshold {
                        segments.append(Segment2D(a: left, b: bottom))
                        segments.append(Segment2D(a: top, b: right))
                    } else {
                        segments.append(Segment2D(a: left, b: top))
                        segments.append(Segment2D(a: bottom, b: right))
                    }
                case 11: segments.append(Segment2D(a: top,    b: right))
                case 12: segments.append(Segment2D(a: left,   b: right))
                case 13: segments.append(Segment2D(a: bottom, b: right))
                case 14: segments.append(Segment2D(a: left,   b: bottom))
                default: break
                }
            }
        }
        return segments
    }

    // MARK: 4. Plan: Orbital Phase Gauge

    public static let orbitalStartAngle: Double = 0.75 * Double.pi
    public static let orbitalEndAngle: Double = 2.25 * Double.pi

    public static func orbitalAngleRad(fraction: Double) -> Double {
        let clamped = min(1.0, max(0.0, fraction))
        return orbitalStartAngle + clamped * 1.5 * Double.pi
    }

    public static func orbitalGaugeAngles(
        remainingFraction: Double,
        paceExpectedRemainingFraction: Double?,
        isOverPaceWarning: Bool
    ) -> OrbitalGaugeAngles {
        let remEnd = orbitalAngleRad(fraction: remainingFraction)
        let paceAng = paceExpectedRemainingFraction.map { orbitalAngleRad(fraction: $0) }
        let deficit: Bool = {
            if isOverPaceWarning { return true }
            if let exp = paceExpectedRemainingFraction {
                return remainingFraction < exp - 0.005
            }
            return false
        }()
        return OrbitalGaugeAngles(
            startAngle: orbitalStartAngle,
            endAngle: orbitalEndAngle,
            remainingEndAngle: remEnd,
            paceAngle: paceAng,
            isDeficit: deficit
        )
    }

    // MARK: 5. Live Sessions: Agent Telemetry Radar

    public static func buildSessionRadarLayout(
        sessions: [SessionInfo],
        labels: [String: String]
    ) -> SessionRadarLayout {
        guard !sessions.isEmpty else {
            return SessionRadarLayout(hubs: [], nodes: [])
        }

        // Group sessions by workspace cwd deterministically
        var grouped: [String: [SessionInfo]] = [:]
        for s in sessions {
            grouped[s.cwd, default: []].append(s)
        }
        let sortedCwds = grouped.keys.sorted { a, b in
            let ca = grouped[a]?.count ?? 0
            let cb = grouped[b]?.count ?? 0
            if ca != cb { return ca > cb }
            return a < b
        }

        let hubAnchors = computeHubAnchors(count: sortedCwds.count)
        var hubs: [RadarHub] = []
        var hubByCwd: [String: RadarHub] = [:]
        for (idx, cwd) in sortedCwds.enumerated() {
            let label = labels[cwd] ?? SessionLogic.basename(cwd)
            let hub = RadarHub(id: cwd, label: label, pos: hubAnchors[idx])
            hubs.append(hub)
            hubByCwd[cwd] = hub
        }

        // Pass 1: Place every session on a deterministic orbit around its workspace hub
        var posById: [String: Point2D] = [:]
        var draftNodes: [(session: SessionInfo, hub: RadarHub, pos: Point2D)] = []
        for (hIdx, cwd) in sortedCwds.enumerated() {
            guard let hub = hubByCwd[cwd] else { continue }
            let members = (grouped[cwd] ?? []).sorted { a, b in
                if a.status != b.status {
                    return statusSortRank(a.status) < statusSortRank(b.status)
                }
                return a.sessionId < b.sessionId
            }
            let total = members.count
            let baseAngle = -Double.pi * 0.4 + Double(hIdx) * 1.15
            for (mIdx, s) in members.enumerated() {
                let angle = baseAngle + (Double(mIdx) / Double(max(1, total))) * 2.0 * Double.pi
                let rx = (total == 1) ? 0.085 : 0.115
                let ry = (total == 1) ? 0.145 : 0.195
                let px = min(0.92, max(0.08, hub.pos.x + cos(angle) * rx))
                let py = min(0.82, max(0.18, hub.pos.y + sin(angle) * ry))
                let pt = Point2D(x: px, y: py)
                posById[s.sessionId] = pt
                draftNodes.append((s, hub, pt))
            }
        }

        // Pass 2: Resolve parentSessionId links & surface tags
        let nodes: [RadarNode] = draftNodes.map { entry in
            let parentPos = entry.session.parentSessionId.flatMap { posById[$0] }
            let surfaceCode: String? = {
                switch SessionSurfaceBadge.from(entrypoint: entry.session.entrypoint, surface: entry.session.surface) {
                case .cli:     return "CLI"
                case .desktop: return "DESK"
                case .ide:     return "IDE"
                case .none:    return nil
                }
            }()
            return RadarNode(
                id: entry.session.sessionId,
                session: entry.session,
                workspaceLabel: entry.hub.label,
                surfaceCode: surfaceCode,
                hubPos: entry.hub.pos,
                pos: entry.pos,
                parentNodePos: parentPos
            )
        }

        return SessionRadarLayout(hubs: hubs, nodes: nodes)
    }

    private static func computeHubAnchors(count: Int) -> [Point2D] {
        switch count {
        case 0:
            return []
        case 1:
            return [Point2D(x: 0.46, y: 0.52)]
        case 2:
            return [Point2D(x: 0.28, y: 0.50), Point2D(x: 0.72, y: 0.50)]
        case 3:
            return [Point2D(x: 0.23, y: 0.54), Point2D(x: 0.52, y: 0.34), Point2D(x: 0.78, y: 0.56)]
        case 4:
            return [
                Point2D(x: 0.24, y: 0.36),
                Point2D(x: 0.74, y: 0.36),
                Point2D(x: 0.26, y: 0.66),
                Point2D(x: 0.76, y: 0.66),
            ]
        default:
            return (0..<count).map { idx in
                let cols = min(3, count)
                let row = idx / cols
                let col = idx % cols
                let totalRows = (count + cols - 1) / cols
                let x = 0.22 + (Double(col) / Double(max(1, cols - 1))) * 0.56
                let y = totalRows == 1
                    ? 0.50
                    : 0.32 + (Double(row) / Double(max(1, totalRows - 1))) * 0.38
                return Point2D(x: x, y: y)
            }
        }
    }

    private static func statusSortRank(_ status: SessionStatus) -> Int {
        switch status {
        case .waiting: return 0
        case .busy:    return 1
        case .idle:    return 2
        case .shell:   return 3
        case .unknown: return 4
        }
    }
}
