import SwiftUI
import AppKit

// Live Sessions Instrument Visualization:
// 04.1 Agent Telemetry Radar (Fred ref1 Deep-Sea Optical CV HUD):
// Calibrated vernier viewport, Dark-mode 0.5pt horizontal scan-band shimmer,
// batched dot graticule, concentric range circles with deterministic micro-stipple
// range-ring mist, 000°/090°/180°/270° optical calibration compass, faint inter-hub
// triangulation mesh, workspace diamond hubs, dashed coordinator -> worker swarm beams,
// dual nested corner reticles & multi-layer optical luminescence with 14pt crosshairs
// on `.waiting` / `.busy` beacons, isolated <= 12fps breathing pulse overlay on `.busy`
// nodes, collision-free 2-line laser telemetry, and single-layer continuous hit-testing.

struct AgentTelemetryRadarView: View {
    let sessions: [SessionInfo]
    @ObservedObject var sessionStore: SessionStore
    var visibleSessionIds: Set<String>? = nil
    var selectedSessionId: String? = nil
    @Binding var hoveredSessionId: String?

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @Environment(\.telemetryStaticRender) private var isStaticRender
    @Environment(\.telemetryPanelVisible) private var isPanelVisible
    @Environment(\.telemetryReduceMotion) private var reduceMotion
    @Environment(\.craftHapticsEnabled) private var hapticsEnabled

    private let radarHeight: CGFloat = 152

    private var anyBusy: Bool {
        sessions.contains { $0.status == .busy }
    }

    var body: some View {
        let layout = InstrumentMath.buildSessionRadarLayout(
            sessions: sessions,
            labels: sessionStore.labels
        )

        VStack(alignment: .leading, spacing: 6) {
            headerRow(layout: layout)

            radarStage(layout: layout)
                .frame(height: radarHeight)
                .background(theme.surface.opacity(theme.isDark ? 0.88 : 0.65))
                .overlay(Rectangle().stroke(theme.hairline, lineWidth: 0.85).allowsHitTesting(false))
                .overlay(CornerReticleOverlay(color: theme.reticle.opacity(0.65), length: 6, lineWidth: 0.85))
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .onChange(of: selectedSessionId) { nextId in
            guard let id = nextId,
                  hoveredSessionId != id,
                  let matched = sessions.first(where: { $0.sessionId == id }) else { return }
            let cue: InstrumentHapticCue = (matched.status == .waiting)
                ? .radarAlertLock
                : .radarBeaconLock
            CraftEngine.shared.perform(cue, enabled: hapticsEnabled)
        }
    }

    @ViewBuilder
    private func headerRow(layout: SessionRadarLayout) -> some View {
        let liveTPS = sessionStore.liveTPS

        HStack(spacing: 5) {
            Text("04.1")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.accent.opacity(0.9))
                .fixedSize()
            Text(loc("agentRadarTitle"))
                .font(.system(size: 8, weight: .regular, design: .monospaced))
                .tracking(0.8)
                .foregroundColor(theme.inkSecondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if liveTPS.isWorking {
                RadarLiveTPSReadout(
                    snapshot: liveTPS,
                    theme: theme,
                    tooltipText: liveTPSTooltip(liveTPS)
                )
                .fixedSize()

                Rectangle()
                    .fill(theme.hairlineStrong.opacity(0.75))
                    .frame(width: 0.75, height: 8)
            }

            if let hid = hoveredSessionId,
               let node = layout.nodes.first(where: { $0.id == hid }) {
                let surfacePart = node.surfaceCode.map { " · \($0)" } ?? ""
                Text("PID \(node.session.pid) · \(node.workspaceLabel.uppercased())\(surfacePart) ↗")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(node.session.status == .waiting ? theme.signalAmber : theme.accent)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text(String(format: "%02d HUBS · %02d NODES", layout.hubs.count, layout.nodes.count))
                    .font(.system(size: 8, weight: .regular, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(theme.inkMuted)
                    .fixedSize()
            }
        }
    }

    private func liveTPSTooltip(_ snapshot: LiveTPSSnapshot) -> String {
        let cur = LiveTPSTracker.formatCompactTPS(snapshot.currentTPS)
        let peak = LiveTPSTracker.formatCompactTPS(snapshot.peakTPS)
        if snapshot.peakTPS >= 0.5 {
            return "\(loc("liveTpsHelp")) · \(cur) (\(loc("peakTag")) \(peak))"
        }
        return "\(loc("liveTpsHelp")) · \(cur)"
    }

    private struct RadarNodeKey: Hashable {
        let id: String
        let status: String
        let needsConfirm: Bool
        let label: String
        let surface: String?
        let xMilli: Int
        let yMilli: Int
    }

    private struct RadarArtworkKey: Hashable {
        let nodes: [RadarNodeKey]
        let visibleIds: Set<String>?
        let doneUnseenIds: Set<String>
        let showStaticBusyRing: Bool
        let confirmTag: String
        let inputTag: String
        let doneTag: String
        let theme: AGYTheme.CacheKey
    }

    private func radarStage(layout: SessionRadarLayout) -> some View {
        let shouldAnimateBusy = TelemetryAnimationGate.shouldAnimate(
            active: anyBusy,
            panelVisible: isPanelVisible,
            reduceMotion: reduceMotion,
            staticRender: isStaticRender
        )
        let interactiveNodes = visibleSessionIds.map { allowed in
            layout.nodes.filter { allowed.contains($0.id) }
        } ?? layout.nodes
        let activeHighlightId = hoveredSessionId ?? selectedSessionId
        let busyTargets: [BusyPulseTarget] = shouldAnimateBusy
            ? layout.nodes.compactMap { node in
                guard node.session.status == .busy else { return nil }
                let isDimmed = visibleSessionIds.map { !$0.contains(node.id) } ?? false
                return BusyPulseTarget(pos: node.pos, isDimmed: isDimmed)
            }
            : []
        let confirmTag = loc("badgeConfirm")
        let inputTag = loc("badgeInput")
        let doneTag = loc("badgeDone")
        let showStaticBusy = anyBusy && !shouldAnimateBusy
        let radarKey = RadarArtworkKey(
            nodes: layout.nodes.map { n in
                RadarNodeKey(
                    id: n.id,
                    status: n.session.status.rawValue,
                    needsConfirm: n.session.waitReason == .needsConfirmation,
                    label: n.workspaceLabel,
                    surface: n.surfaceCode,
                    xMilli: Int((n.pos.x * 1000.0).rounded()),
                    yMilli: Int((n.pos.y * 1000.0).rounded())
                )
            },
            visibleIds: visibleSessionIds,
            doneUnseenIds: sessionStore.doneUnseen,
            showStaticBusyRing: showStaticBusy,
            confirmTag: confirmTag,
            inputTag: inputTag,
            doneTag: doneTag,
            theme: theme.cacheKey
        )

        return GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack(alignment: .topLeading) {
                // Layer 1: Pre-rendered 2x Retina cached radar backdrop, mist rings, hubs & 2-line telemetry.
                // Neither 12fps busy ticks nor 120Hz mouse hover ever recompute it.
                CachedTelemetryArtwork(
                    key: radarKey,
                    width: w,
                    height: h
                ) {
                    RadarStaticCanvas(
                        layout: layout,
                        visibleSessionIds: visibleSessionIds,
                        doneUnseenIds: sessionStore.doneUnseen,
                        theme: theme,
                        confirmTag: confirmTag,
                        inputTag: inputTag,
                        doneTag: doneTag,
                        showStaticBusyRing: showStaticBusy
                    )
                }
                .allowsHitTesting(false)

                // Layer 2: Isolated <= 12fps breathing pulse rings — ONLY mounted when busy & motion allowed.
                if !busyTargets.isEmpty {
                    RadarBusyPulseOverlay(
                        targets: busyTargets,
                        accent: theme.accent
                    )
                    .allowsHitTesting(false)
                }

                // Layer 3: Lightweight hover/selection reticle lock overlay (zero static canvas redraw).
                if let activeId = activeHighlightId,
                   let activeNode = layout.nodes.first(where: { $0.id == activeId }) {
                    RadarActiveTargetOverlay(
                        node: activeNode,
                        theme: theme
                    )
                    .allowsHitTesting(false)
                }

                // Layer 4: Single viewport-level continuous hover & click hit-tester.
                // Uses InstrumentMath.hitTestRadarNode instead of per-node `.position()` targets
                // so overlapping tracking rects can never hijack hover or clicks on macOS.
                Color.clear
                    .frame(width: w, height: h)
                    .contentShape(Rectangle())
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        switch phase {
                        case .active(let pt):
                            let hit = InstrumentMath.hitTestRadarNode(
                                x: Double(pt.x),
                                y: Double(pt.y),
                                width: Double(w),
                                height: Double(h),
                                nodes: interactiveNodes,
                                maxRadius: 20.0
                            )
                            let hitId = hit?.id
                            if hoveredSessionId != hitId {
                                hoveredSessionId = hitId
                                if let hitNode = hit {
                                    let cue: InstrumentHapticCue = (hitNode.session.status == .waiting)
                                        ? .radarAlertLock
                                        : .radarBeaconLock
                                    CraftEngine.shared.perform(cue, enabled: hapticsEnabled)
                                }
                            }
                            PointingCursorCoordinator.shared.setPointing(hitId != nil, token: "session-radar")
                        case .ended:
                            if hoveredSessionId != nil {
                                hoveredSessionId = nil
                            }
                            PointingCursorCoordinator.shared.setPointing(false, token: "session-radar")
                        }
                    }
                    .onTapGesture(coordinateSpace: .local) { pt in
                        if let hit = InstrumentMath.hitTestRadarNode(
                            x: Double(pt.x),
                            y: Double(pt.y),
                            width: Double(w),
                            height: Double(h),
                            nodes: interactiveNodes,
                            maxRadius: 20.0
                        ) {
                            CraftEngine.shared.perform(.radarJumpEngage, enabled: hapticsEnabled)
                            sessionStore.jump(hit.session)
                        }
                    }
                    .onDisappear {
                        PointingCursorCoordinator.shared.setPointing(false, token: "session-radar")
                        if hoveredSessionId != nil {
                            hoveredSessionId = nil
                        }
                    }
            }
        }
    }
}

// MARK: - Layer 1: Static Optical Radar Canvas (Equatable, Batched Paths, Collision-Free Telemetry)

private struct RadarStaticCanvas: View, Equatable {
    let layout: SessionRadarLayout
    let visibleSessionIds: Set<String>?
    let doneUnseenIds: Set<String>
    let theme: AGYTheme
    let confirmTag: String
    let inputTag: String
    let doneTag: String
    let showStaticBusyRing: Bool

    var body: some View {
        Canvas { context, size in
            let cw = size.width
            let ch = size.height
            guard cw > 20, ch > 20 else { return }
            let center = CGPoint(x: cw * 0.5, y: ch * 0.5)

            func pt(_ p: Point2D) -> CGPoint {
                CGPoint(x: CGFloat(p.x) * cw, y: CGFloat(p.y) * ch)
            }

            // 0. Subtle radial optical depth wash & Dark-mode 0.5pt horizontal scan-band shimmer
            let lensRadius = min(cw, ch) * 0.62
            context.fill(
                Path(CGRect(x: 0, y: 0, width: cw, height: ch)),
                with: .radialGradient(
                    Gradient(colors: [
                        theme.accent.opacity(theme.isDark ? 0.065 : 0.024),
                        Color.clear,
                    ]),
                    center: center,
                    startRadius: 4,
                    endRadius: lensRadius
                )
            )

            if theme.isDark {
                var scanBase = Path()
                var scanShimmer = Path()
                var sy: CGFloat = 3.5
                var rowIdx = 0
                while sy < ch - 2 {
                    scanBase.move(to: CGPoint(x: 4, y: sy))
                    scanBase.addLine(to: CGPoint(x: cw - 4, y: sy))

                    // Delicate mid-band optical shimmer segments (Fred ref1 sonar horizon)
                    if abs(sy - center.y) <= ch * 0.24 && (rowIdx % 2 == 0) {
                        let phaseShift = CGFloat((rowIdx * 11) % 24)
                        var sx: CGFloat = 8 + phaseShift
                        while sx < cw - 12 {
                            let segW: CGFloat = 14
                            scanShimmer.move(to: CGPoint(x: sx, y: sy))
                            scanShimmer.addLine(to: CGPoint(x: min(cw - 8, sx + segW), y: sy))
                            sx += 34
                        }
                    }
                    sy += 4.0
                    rowIdx += 1
                }
                context.stroke(scanBase, with: .color(theme.inkPrimary.opacity(0.032)), lineWidth: 0.5)
                if !scanShimmer.isEmpty {
                    context.stroke(scanShimmer, with: .color(theme.accent.opacity(0.065)), lineWidth: 0.5)
                }
            }

            // 1. Batched dot graticule (single Path fill instead of per-dot fills)
            var graticuleDots = Path()
            let spacing: CGFloat = 14
            var gy: CGFloat = spacing * 0.5
            while gy < ch {
                var gx: CGFloat = spacing * 0.5
                while gx < cw {
                    graticuleDots.addRect(CGRect(x: gx, y: gy, width: 1, height: 1))
                    gx += spacing
                }
                gy += spacing
            }
            context.fill(graticuleDots, with: .color(theme.hairline.opacity(0.48)))

            // 2. Calibration vernier tick marks along left/right edges + cardinal top/bottom ticks
            var minorTicks = Path()
            var majorTicks = Path()
            let tickStep: CGFloat = 6
            var tickIdx = 0
            var ty: CGFloat = 10
            while ty <= ch - 10 {
                let isMajor = (tickIdx % 4 == 0)
                let len: CGFloat = isMajor ? 5.5 : 3.0
                if isMajor {
                    majorTicks.move(to: CGPoint(x: 0, y: ty))
                    majorTicks.addLine(to: CGPoint(x: len, y: ty))
                    majorTicks.move(to: CGPoint(x: cw - len, y: ty))
                    majorTicks.addLine(to: CGPoint(x: cw, y: ty))
                } else {
                    minorTicks.move(to: CGPoint(x: 0, y: ty))
                    minorTicks.addLine(to: CGPoint(x: len, y: ty))
                    minorTicks.move(to: CGPoint(x: cw - len, y: ty))
                    minorTicks.addLine(to: CGPoint(x: cw, y: ty))
                }
                ty += tickStep
                tickIdx += 1
            }
            for frac in [0.25, 0.50, 0.75] as [CGFloat] {
                let tx = cw * frac
                majorTicks.move(to: CGPoint(x: tx, y: 0))
                majorTicks.addLine(to: CGPoint(x: tx, y: 3.5))
                majorTicks.move(to: CGPoint(x: tx, y: ch - 3.5))
                majorTicks.addLine(to: CGPoint(x: tx, y: ch))
            }
            context.stroke(minorTicks, with: .color(theme.hairline.opacity(0.75)), lineWidth: 0.65)
            context.stroke(majorTicks, with: .color(theme.hairlineStrong.opacity(0.80)), lineWidth: 0.75)

            // 3. Concentric range circles + deterministic micro-stipple range-ring mist + azimuth ticks
            let ringRadii: [CGFloat] = [26.0, 52.0, 78.0]
            var rangeCircles = Path()
            var ringMistCore = Path()
            var ringMistHalo = Path()
            var azimuthTicks = Path()

            for (ringIdx, radius) in ringRadii.enumerated() {
                rangeCircles.addEllipse(in: CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                ))

                // Deterministic micro-stipple mist hugging each concentric range ring (batched into 2 Paths)
                let sampleCount = Int(radius * 3.4)
                let bandWidth = 3.6 + Double(ringIdx) * 1.1
                for i in 0..<sampleCount {
                    let h = Self.opticalHash(ringIdx * 1009 + i, Int(radius))
                    let u1 = Double(h & 0xFF) / 255.0
                    let u2 = Double((h >> 8) & 0xFF) / 255.0
                    let radialJitter = (u1 + u2 - 1.0) * bandWidth
                    let angJitter = (Double((h >> 16) & 0x3F) / 63.0 - 0.5) * 0.055
                    let angle = (Double(i) / Double(sampleCount)) * (.pi * 2.0) + angJitter
                    let rr = radius + CGFloat(radialJitter)
                    let dx = center.x + CGFloat(cos(angle)) * rr
                    let dy = center.y + CGFloat(sin(angle)) * rr
                    guard dx >= 7, dx <= cw - 7, dy >= 5, dy <= ch - 5 else { continue }

                    let roll = Double((h >> 22) & 0xFF) / 255.0
                    let distFrac = abs(radialJitter) / max(0.5, bandWidth)
                    let prob = 0.72 * (1.0 - distFrac * 0.62)
                    if roll < prob {
                        if abs(radialJitter) < 1.55 {
                            ringMistCore.addRect(CGRect(x: dx, y: dy, width: 0.95, height: 0.95))
                        } else {
                            ringMistHalo.addRect(CGRect(x: dx, y: dy, width: 0.75, height: 0.75))
                        }
                    }
                }

                // Subtle 30-degree compass azimuth ticks on the middle & outer range rings
                if ringIdx >= 1 {
                    let tickLen: CGFloat = ringIdx == 1 ? 2.0 : 2.6
                    for deg in stride(from: 0, to: 360, by: 30) {
                        guard deg % 90 != 0 else { continue }
                        let rad = Double(deg) * .pi / 180.0
                        let ca = CGFloat(cos(rad))
                        let sa = CGFloat(sin(rad))
                        let x0 = center.x + ca * (radius - tickLen * 0.5)
                        let y0 = center.y + sa * (radius - tickLen * 0.5)
                        let x1 = center.x + ca * (radius + tickLen * 0.5)
                        let y1 = center.y + sa * (radius + tickLen * 0.5)
                        guard x0 >= 6, x0 <= cw - 6, y0 >= 4, y0 <= ch - 4 else { continue }
                        azimuthTicks.move(to: CGPoint(x: x0, y: y0))
                        azimuthTicks.addLine(to: CGPoint(x: x1, y: y1))
                    }
                }
            }

            let radarRingColor = theme.isMultiColorSpectrum ? theme.accent : theme.accentSecondary
            let radarTickColor = theme.isMultiColorSpectrum ? theme.accentQuaternary : theme.accentSecondary
            if !ringMistHalo.isEmpty {
                context.fill(ringMistHalo, with: .color(radarRingColor.opacity(theme.isDark ? 0.12 : 0.09)))
            }
            if !ringMistCore.isEmpty {
                context.fill(ringMistCore, with: .color(radarRingColor.opacity(theme.isDark ? 0.20 : 0.15)))
            }
            context.stroke(
                rangeCircles,
                with: .color(radarRingColor.opacity(theme.isDark ? 0.28 : 0.24)),
                style: StrokeStyle(lineWidth: 0.65, dash: [2, 3])
            )
            if !azimuthTicks.isEmpty {
                context.stroke(azimuthTicks, with: .color(radarTickColor.opacity(theme.isDark ? 0.48 : 0.40)), lineWidth: 0.6)
            }

            var axes = Path()
            axes.move(to: CGPoint(x: 6, y: center.y))
            axes.addLine(to: CGPoint(x: cw - 6, y: center.y))
            axes.move(to: CGPoint(x: center.x, y: 4))
            axes.addLine(to: CGPoint(x: center.x, y: ch - 4))
            context.stroke(axes, with: .color(theme.hairline.opacity(0.42)), lineWidth: 0.65)

            var centerCross = Path()
            centerCross.move(to: CGPoint(x: center.x - 3.5, y: center.y))
            centerCross.addLine(to: CGPoint(x: center.x + 3.5, y: center.y))
            centerCross.move(to: CGPoint(x: center.x, y: center.y - 3.5))
            centerCross.addLine(to: CGPoint(x: center.x, y: center.y + 3.5))
            context.stroke(centerCross, with: .color((theme.isMultiColorSpectrum ? theme.accent : theme.reticle).opacity(0.50)), lineWidth: 0.75)

            // 3b. Optical calibration compass cardinal labels (000° / 090° / 180° / 270°)
            //     4-color Google cardinal compass on Google theme; Color 2 on duotone themes.
            let compassAlpha: Double = theme.isDark ? 0.72 : 0.68
            let northColor = theme.isMultiColorSpectrum ? theme.accent.opacity(compassAlpha) : theme.accentSecondary.opacity(theme.isDark ? 0.62 : 0.58)
            let eastColor  = theme.isMultiColorSpectrum ? theme.accentSecondary.opacity(compassAlpha) : theme.accentSecondary.opacity(theme.isDark ? 0.62 : 0.58)
            let southColor = theme.isMultiColorSpectrum ? theme.accentTertiary.opacity(compassAlpha) : theme.accentSecondary.opacity(theme.isDark ? 0.62 : 0.58)
            let westColor  = theme.isMultiColorSpectrum ? theme.accentQuaternary.opacity(compassAlpha) : theme.accentSecondary.opacity(theme.isDark ? 0.62 : 0.58)
            let northLabel = Text("000°").font(.system(size: 6, weight: .medium, design: .monospaced)).tracking(0.3).foregroundColor(northColor)
            let southLabel = Text("180°").font(.system(size: 6, weight: .medium, design: .monospaced)).tracking(0.3).foregroundColor(southColor)
            let eastLabel  = Text("090°").font(.system(size: 6, weight: .medium, design: .monospaced)).tracking(0.3).foregroundColor(eastColor)
            let westLabel  = Text("270°").font(.system(size: 6, weight: .medium, design: .monospaced)).tracking(0.3).foregroundColor(westColor)

            let northPos = CGPoint(x: center.x, y: 8.5)
            let southPos = CGPoint(x: center.x, y: ch - 8.5)
            let eastPos  = CGPoint(x: cw - 8.5, y: center.y - 5.5)
            let westPos  = CGPoint(x: 8.5, y: center.y - 5.5)
            context.draw(northLabel, at: northPos)
            context.draw(southLabel, at: southPos)
            context.draw(eastLabel, at: eastPos, anchor: .trailing)
            context.draw(westLabel, at: westPos, anchor: .leading)

            // 3c. Faint inter-hub triangulation mesh connecting workspace hubs (0.5pt dashed)
            if layout.hubs.count >= 2 {
                var hubMesh = Path()
                let hubPts = layout.hubs.map { pt($0.pos) }
                if hubPts.count <= 4 {
                    for i in 0..<hubPts.count {
                        for j in (i + 1)..<hubPts.count {
                            hubMesh.move(to: hubPts[i])
                            hubMesh.addLine(to: hubPts[j])
                        }
                    }
                } else {
                    var seenPairs = Set<Int>()
                    for i in 0..<hubPts.count {
                        let next = (i + 1) % hubPts.count
                        let key = min(i, next) * 64 + max(i, next)
                        if seenPairs.insert(key).inserted {
                            hubMesh.move(to: hubPts[i])
                            hubMesh.addLine(to: hubPts[next])
                        }
                        // Link each hub to its closest non-adjacent hub for airy triangulation
                        var bestJ: Int? = nil
                        var bestDist = CGFloat.greatestFiniteMagnitude
                        for j in 0..<hubPts.count where j != i && j != next {
                            let d = hypot(hubPts[i].x - hubPts[j].x, hubPts[i].y - hubPts[j].y)
                            if d < bestDist {
                                bestDist = d
                                bestJ = j
                            }
                        }
                        if let j = bestJ {
                            let nKey = min(i, j) * 64 + max(i, j)
                            if seenPairs.insert(nKey).inserted {
                                hubMesh.move(to: hubPts[i])
                                hubMesh.addLine(to: hubPts[j])
                            }
                        }
                    }
                }
                if !hubMesh.isEmpty {
                    context.stroke(
                        hubMesh,
                        with: .color(theme.hairlineStrong.opacity(theme.isDark ? 0.34 : 0.25)),
                        style: StrokeStyle(lineWidth: 0.5, dash: [2, 3.5])
                    )
                }
            }

            // 4. Batched hub triangulation vectors & dashed coordinator -> subagent swarm beams
            var normalVectors = Path()
            var dimmedVectors = Path()
            var waitingVectors = Path()
            var waitingDimmedVectors = Path()
            var swarmBeams = Path()
            var swarmDimmedBeams = Path()

            for node in layout.nodes {
                let np = pt(node.pos)
                let hp = pt(node.hubPos)
                let isDimmed = visibleSessionIds.map { !$0.contains(node.id) } ?? false

                if node.session.status == .waiting {
                    if isDimmed {
                        waitingDimmedVectors.move(to: hp)
                        waitingDimmedVectors.addLine(to: np)
                    } else {
                        waitingVectors.move(to: hp)
                        waitingVectors.addLine(to: np)
                    }
                } else {
                    if isDimmed {
                        dimmedVectors.move(to: hp)
                        dimmedVectors.addLine(to: np)
                    } else {
                        normalVectors.move(to: hp)
                        normalVectors.addLine(to: np)
                    }
                }

                if let parentP = node.parentNodePos {
                    let pp = pt(parentP)
                    if isDimmed {
                        swarmDimmedBeams.move(to: pp)
                        swarmDimmedBeams.addLine(to: np)
                    } else {
                        swarmBeams.move(to: pp)
                        swarmBeams.addLine(to: np)
                    }
                }
            }

            if !dimmedVectors.isEmpty {
                context.stroke(dimmedVectors, with: .color(theme.hairlineStrong.opacity(0.22)), lineWidth: 0.7)
            }
            if !normalVectors.isEmpty {
                context.stroke(normalVectors, with: .color(theme.hairlineStrong.opacity(0.76)), lineWidth: 0.75)
            }
            if !waitingDimmedVectors.isEmpty {
                context.stroke(waitingDimmedVectors, with: .color(theme.signalAmber.opacity(0.20)), lineWidth: 0.7)
            }
            if !waitingVectors.isEmpty {
                context.stroke(waitingVectors, with: .color(theme.signalAmber.opacity(0.58)), lineWidth: 0.8)
            }
            if !swarmDimmedBeams.isEmpty {
                context.stroke(
                    swarmDimmedBeams,
                    with: .color(theme.accent.opacity(0.20)),
                    style: StrokeStyle(lineWidth: 0.85, dash: [3, 2])
                )
            }
            if !swarmBeams.isEmpty {
                context.stroke(
                    swarmBeams,
                    with: .color(theme.accent.opacity(0.75)),
                    style: StrokeStyle(lineWidth: 0.95, dash: [3, 2])
                )
            }

            // Track occupied bounding boxes so micro-telemetry never overlaps compass ticks, hub labels or nodes
            var occupiedRects: [CGRect] = [
                CGRect(x: northPos.x - 14, y: northPos.y - 5, width: 28, height: 10),
                CGRect(x: southPos.x - 14, y: southPos.y - 5, width: 28, height: 10),
                CGRect(x: eastPos.x - 24,  y: eastPos.y - 5,  width: 24, height: 10),
                CGRect(x: westPos.x,       y: westPos.y - 5,  width: 24, height: 10),
            ]
            for node in layout.nodes {
                let np = pt(node.pos)
                let pad: CGFloat = node.session.status == .waiting ? 12.5 : 8.5
                occupiedRects.append(CGRect(x: np.x - pad, y: np.y - pad, width: pad * 2, height: pad * 2))
            }

            // 5. Workspace hub diamond anchors + clean haloed uppercase labels
            var hubDiamonds = Path()
            for hub in layout.hubs {
                let hp = pt(hub.pos)
                let r: CGFloat = 3.8
                hubDiamonds.move(to: CGPoint(x: hp.x, y: hp.y - r))
                hubDiamonds.addLine(to: CGPoint(x: hp.x + r, y: hp.y))
                hubDiamonds.addLine(to: CGPoint(x: hp.x, y: hp.y + r))
                hubDiamonds.addLine(to: CGPoint(x: hp.x - r, y: hp.y))
                hubDiamonds.closeSubpath()
                occupiedRects.append(CGRect(x: hp.x - 6, y: hp.y - 6, width: 12, height: 12))
            }
            if !hubDiamonds.isEmpty {
                context.fill(hubDiamonds, with: .color(theme.canvas))
                context.stroke(hubDiamonds, with: .color(theme.inkSecondary), lineWidth: 0.95)
            }

            for hub in layout.hubs {
                let hp = pt(hub.pos)
                let labelStr = hub.label.uppercased()
                let haloW = min(cw * 0.38, CGFloat(labelStr.count) * 5.5 + 8)
                let labelX = min(max(hp.x, 8 + haloW * 0.5), cw - 8 - haloW * 0.5)
                let nearMeridian = abs(labelX - center.x) < (haloW * 0.5 + 16)
                let minYBound: CGFloat = nearMeridian ? 18.0 : 9.0
                let maxYBound: CGFloat = nearMeridian ? (ch - 18.0) : (ch - 9.0)
                let labelY = hp.y > ch * 0.54 ? min(maxYBound, hp.y + 11.5) : max(minYBound, hp.y - 11.5)
                let haloRect = CGRect(x: labelX - haloW * 0.5, y: labelY - 5.5, width: haloW, height: 11)
                context.fill(Path(haloRect), with: .color(theme.surface.opacity(0.86)))
                let labelText = Text(labelStr)
                    .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                    .tracking(0.8)
                    .foregroundColor(theme.inkSecondary)
                context.draw(labelText, at: CGPoint(x: labelX, y: labelY))
                occupiedRects.append(haloRect.insetBy(dx: -2, dy: -1.5))
            }

            // 6. Session telemetry beacons + Fred ref1 2-line laser micro-telemetry
            // Process highest-priority nodes first so waiting/busy nodes always claim the clearest space.
            let prioritizedNodes = layout.nodes.sorted { a, b in
                nodePriority(a) < nodePriority(b)
            }

            for node in prioritizedNodes {
                let np = pt(node.pos)
                let hp = pt(node.hubPos)
                let isDoneUnseen = doneUnseenIds.contains(node.id)
                let isDimmed = visibleSessionIds.map { !$0.contains(node.id) } ?? false
                let alphaMul: Double = isDimmed ? 0.26 : 1.0
                let coordStr = String(format: "X%.2f Y%.2f", node.pos.x, node.pos.y)

                switch node.session.status {
                case .waiting:
                    let amb = theme.signalAmber.opacity(alphaMul)
                    // Fred ref1 multi-layer concentric optical luminescence halo
                    context.fill(
                        Path(ellipseIn: CGRect(x: np.x - 15.0, y: np.y - 15.0, width: 30, height: 30)),
                        with: .color(theme.signalAmber.opacity((theme.isDark ? 0.11 : 0.055) * alphaMul))
                    )
                    context.fill(
                        Path(ellipseIn: CGRect(x: np.x - 9.5, y: np.y - 9.5, width: 19, height: 19)),
                        with: .color(theme.signalAmber.opacity((theme.isDark ? 0.20 : 0.105) * alphaMul))
                    )
                    context.fill(
                        Path(ellipseIn: CGRect(x: np.x - 5.2, y: np.y - 5.2, width: 10.4, height: 10.4)),
                        with: .color(amb.opacity(theme.isDark ? 0.30 : 0.16))
                    )

                    // Subtle 0.5pt horizontal optical scan-band shimmer through beacon plane in Dark mode
                    if theme.isDark && !isDimmed {
                        var shimmer = Path()
                        shimmer.move(to: CGPoint(x: max(4, np.x - 24), y: np.y))
                        shimmer.addLine(to: CGPoint(x: min(cw - 4, np.x + 24), y: np.y))
                        context.stroke(shimmer, with: .color(theme.signalAmber.opacity(0.22)), lineWidth: 0.5)
                    }

                    // Crisp hairline crosshairs radiating 14pt from waiting target center
                    var waitCross = Path()
                    let wInner: CGFloat = 5.0
                    let wOuter: CGFloat = 14.0
                    waitCross.move(to: CGPoint(x: max(2, np.x - wOuter), y: np.y))
                    waitCross.addLine(to: CGPoint(x: np.x - wInner, y: np.y))
                    waitCross.move(to: CGPoint(x: np.x + wInner, y: np.y))
                    waitCross.addLine(to: CGPoint(x: min(cw - 2, np.x + wOuter), y: np.y))
                    waitCross.move(to: CGPoint(x: np.x, y: max(2, np.y - wOuter)))
                    waitCross.addLine(to: CGPoint(x: np.x, y: np.y - wInner))
                    waitCross.move(to: CGPoint(x: np.x, y: np.y + wInner))
                    waitCross.addLine(to: CGPoint(x: np.x, y: min(ch - 2, np.y + wOuter)))
                    context.stroke(waitCross, with: .color(amb.opacity(0.42)), lineWidth: 0.6)

                    // Dual nested corner reticles (r=7 + outer r=11.5 at 0.32 opacity)
                    drawCornerReticle(in: &context, center: np, radius: 11.5, len: 3.8, color: amb.opacity(0.32), lineWidth: 0.75)
                    drawCornerReticle(in: &context, center: np, radius: 7.0, len: 3.0, color: amb, lineWidth: 0.9)

                    // Core rotated diamond beacon (+ delicate luminous specular core in Dark mode)
                    let dr: CGFloat = 3.2
                    var dia = Path()
                    dia.move(to: CGPoint(x: np.x, y: np.y - dr))
                    dia.addLine(to: CGPoint(x: np.x + dr, y: np.y))
                    dia.addLine(to: CGPoint(x: np.x, y: np.y + dr))
                    dia.addLine(to: CGPoint(x: np.x - dr, y: np.y))
                    dia.closeSubpath()
                    context.fill(dia, with: .color(amb))
                    if theme.isDark && !isDimmed {
                        context.fill(
                            Path(ellipseIn: CGRect(x: np.x - 1.0, y: np.y - 1.0, width: 2.0, height: 2.0)),
                            with: .color(theme.inkPrimary.opacity(0.88))
                        )
                    }

                    if !isDimmed {
                        let tag = node.session.waitReason == .needsConfirmation ? confirmTag : inputTag
                        let pillW = max(36, CGFloat(tag.count) * 5.0 + 10)
                        let boxW = max(pillW, 48)
                        let boxH: CGFloat = 21
                        let placement = placeLabelBox(
                            near: np,
                            awayFrom: hp,
                            boxSize: CGSize(width: boxW, height: boxH),
                            reticleGap: 14,
                            bounds: CGSize(width: cw, height: ch),
                            occupied: occupiedRects
                        )
                        occupiedRects.append(placement.rect.insetBy(dx: -2, dy: -1.5))

                        // Hairline leader from reticle edge to callout
                        drawLeaderLine(
                            in: &context,
                            from: np,
                            to: placement.rect,
                            reticleRadius: 11.5,
                            color: amb.opacity(0.72),
                            lineWidth: 0.75
                        )

                        // Halo backing so background vectors never slice through micro-text
                        context.fill(
                            Path(placement.rect.insetBy(dx: -1.5, dy: -1)),
                            with: .color(theme.surface.opacity(0.84))
                        )

                        // Line 1: Hairline-framed amber telemetry tag (NO solid black-on-orange slab)
                        let pillX = placement.alignRight ? (placement.rect.maxX - pillW) : placement.rect.minX
                        let pillRect = CGRect(x: pillX, y: placement.rect.minY, width: pillW, height: 11)
                        context.fill(
                            Path(pillRect),
                            with: .color(theme.signalAmber.opacity(theme.isDark ? 0.12 : 0.10))
                        )
                        context.stroke(
                            Path(pillRect),
                            with: .color(theme.signalAmber.opacity(0.65)),
                            lineWidth: 0.75
                        )
                        let tagText = Text(tag)
                            .font(.system(size: 6.5, weight: .semibold, design: .monospaced))
                            .tracking(0.4)
                            .foregroundColor(theme.signalAmber)
                        context.draw(tagText, at: CGPoint(x: pillRect.midX, y: pillRect.midY))

                        // Line 2: Normalized laser coordinate readout
                        let coordX = placement.alignRight ? placement.rect.maxX : placement.rect.minX
                        let coordAnchor: UnitPoint = placement.alignRight ? .trailing : .leading
                        let coordText = Text(coordStr)
                            .font(.system(size: 6.5, weight: .regular, design: .monospaced))
                            .foregroundColor(theme.inkMuted)
                        context.draw(coordText, at: CGPoint(x: coordX, y: placement.rect.minY + 16.5), anchor: coordAnchor)
                    }

                case .busy:
                    let c = theme.accent.opacity(alphaMul)
                    // Fred ref1 multi-layer optical luminescence bloom (outer mist + mid halo + inner core)
                    context.fill(
                        Path(ellipseIn: CGRect(x: np.x - 15.0, y: np.y - 15.0, width: 30, height: 30)),
                        with: .color(theme.accent.opacity((theme.isDark ? 0.12 : 0.055) * alphaMul))
                    )
                    context.fill(
                        Path(ellipseIn: CGRect(x: np.x - 9.5, y: np.y - 9.5, width: 19, height: 19)),
                        with: .color(theme.accent.opacity((theme.isDark ? 0.22 : 0.10) * alphaMul))
                    )
                    context.fill(
                        Path(ellipseIn: CGRect(x: np.x - 5.4, y: np.y - 5.4, width: 10.8, height: 10.8)),
                        with: .color(c.opacity(theme.isDark ? 0.34 : 0.24))
                    )

                    // Subtle 0.5pt horizontal optical scan-band shimmer in Dark mode
                    if theme.isDark && !isDimmed {
                        var shimmer = Path()
                        shimmer.move(to: CGPoint(x: max(4, np.x - 22), y: np.y))
                        shimmer.addLine(to: CGPoint(x: min(cw - 4, np.x + 22), y: np.y))
                        context.stroke(shimmer, with: .color(theme.accent.opacity(0.20)), lineWidth: 0.5)
                    }

                    // Crisp hairline crosshairs radiating 14pt from busy target center
                    var busyCross = Path()
                    let bInner: CGFloat = 5.0
                    let bOuter: CGFloat = 14.0
                    busyCross.move(to: CGPoint(x: max(2, np.x - bOuter), y: np.y))
                    busyCross.addLine(to: CGPoint(x: np.x - bInner, y: np.y))
                    busyCross.move(to: CGPoint(x: np.x + bInner, y: np.y))
                    busyCross.addLine(to: CGPoint(x: min(cw - 2, np.x + bOuter), y: np.y))
                    busyCross.move(to: CGPoint(x: np.x, y: max(2, np.y - bOuter)))
                    busyCross.addLine(to: CGPoint(x: np.x, y: np.y - bInner))
                    busyCross.move(to: CGPoint(x: np.x, y: np.y + bInner))
                    busyCross.addLine(to: CGPoint(x: np.x, y: min(ch - 2, np.y + bOuter)))
                    context.stroke(busyCross, with: .color(c.opacity(0.36)), lineWidth: 0.6)

                    // Crisp inner optical ring + bright core (+ specular highlight in Dark mode)
                    context.stroke(
                        Path(ellipseIn: CGRect(x: np.x - 5.4, y: np.y - 5.4, width: 10.8, height: 10.8)),
                        with: .color(c.opacity(0.50)),
                        lineWidth: 0.6
                    )
                    context.fill(
                        Path(ellipseIn: CGRect(x: np.x - 2.7, y: np.y - 2.7, width: 5.4, height: 5.4)),
                        with: .color(c)
                    )
                    if theme.isDark && !isDimmed {
                        context.fill(
                            Path(ellipseIn: CGRect(x: np.x - 1.0, y: np.y - 1.0, width: 2.0, height: 2.0)),
                            with: .color(theme.inkPrimary.opacity(0.92))
                        )
                    }
                    if showStaticBusyRing {
                        context.stroke(
                            Path(ellipseIn: CGRect(x: np.x - 8.2, y: np.y - 8.2, width: 16.4, height: 16.4)),
                            with: .color(theme.accent.opacity(0.38 * alphaMul)),
                            lineWidth: 0.85
                        )
                    }

                    if !isDimmed {
                        let pidStr = "PID·\(node.session.pid)"
                        let boxW = max(48, CGFloat(pidStr.count) * 4.4 + 4)
                        let boxH: CGFloat = 17.5
                        let placement = placeLabelBox(
                            near: np,
                            awayFrom: hp,
                            boxSize: CGSize(width: boxW, height: boxH),
                            reticleGap: 11.5,
                            bounds: CGSize(width: cw, height: ch),
                            occupied: occupiedRects
                        )
                        occupiedRects.append(placement.rect.insetBy(dx: -2, dy: -1.5))

                        drawLeaderLine(
                            in: &context,
                            from: np,
                            to: placement.rect,
                            reticleRadius: 6.5,
                            color: theme.accent.opacity(0.45),
                            lineWidth: 0.65
                        )

                        context.fill(
                            Path(placement.rect.insetBy(dx: -1.5, dy: -1)),
                            with: .color(theme.surface.opacity(0.84))
                        )

                        let tx = placement.alignRight ? placement.rect.maxX : placement.rect.minX
                        let anchor: UnitPoint = placement.alignRight ? .trailing : .leading
                        let line1 = Text(pidStr)
                            .font(.system(size: 6.8, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.inkPrimary.opacity(0.92))
                        let line2 = Text(coordStr)
                            .font(.system(size: 6.5, weight: .regular, design: .monospaced))
                            .foregroundColor(theme.inkMuted)
                        context.draw(line1, at: CGPoint(x: tx, y: placement.rect.minY + 4.5), anchor: anchor)
                        context.draw(line2, at: CGPoint(x: tx, y: placement.rect.minY + 13.0), anchor: anchor)
                    }

                case .idle, .shell, .unknown:
                    if isDoneUnseen {
                        let g = theme.signalGreen.opacity(alphaMul)
                        context.stroke(
                            Path(ellipseIn: CGRect(x: np.x - 4.8, y: np.y - 4.8, width: 9.6, height: 9.6)),
                            with: .color(g.opacity(0.68)),
                            lineWidth: 0.85
                        )
                        context.fill(
                            Path(ellipseIn: CGRect(x: np.x - 2.2, y: np.y - 2.2, width: 4.4, height: 4.4)),
                            with: .color(g)
                        )
                    } else {
                        let standbyBase = theme.isMultiColorSpectrum ? theme.inkSecondary : theme.accentSecondary
                        let standby = standbyBase.opacity((theme.isDark ? 0.78 : 0.72) * alphaMul)
                        var cross = Path()
                        cross.move(to: CGPoint(x: np.x - 3.2, y: np.y))
                        cross.addLine(to: CGPoint(x: np.x + 3.2, y: np.y))
                        cross.move(to: CGPoint(x: np.x, y: np.y - 3.2))
                        cross.addLine(to: CGPoint(x: np.x, y: np.y + 3.2))
                        context.stroke(cross, with: .color(standby), lineWidth: 0.95)
                        context.stroke(
                            Path(ellipseIn: CGRect(x: np.x - 2.1, y: np.y - 2.1, width: 4.2, height: 4.2)),
                            with: .color(standby.opacity(0.75)),
                            lineWidth: 0.7
                        )
                    }

                    if !isDimmed {
                        let tagStr: String = isDoneUnseen
                            ? (node.surfaceCode.map { "\($0)·\(doneTag)" } ?? doneTag)
                            : (node.surfaceCode ?? "IDLE")
                        let compactW = max(24, CGFloat(tagStr.count) * 4.5 + 4)
                        let fullW = max(compactW, 46)
                        let twoLinePlacement = placeLabelBox(
                            near: np,
                            awayFrom: hp,
                            boxSize: CGSize(width: fullW, height: 16.5),
                            reticleGap: 9.5,
                            bounds: CGSize(width: cw, height: ch),
                            occupied: occupiedRects
                        )
                        let useTwoLines = (twoLinePlacement.overlapArea < 18)
                        let placement = useTwoLines
                            ? twoLinePlacement
                            : placeLabelBox(
                                near: np,
                                awayFrom: hp,
                                boxSize: CGSize(width: compactW, height: 9.5),
                                reticleGap: 8.5,
                                bounds: CGSize(width: cw, height: ch),
                                occupied: occupiedRects
                            )
                        occupiedRects.append(placement.rect.insetBy(dx: -1.5, dy: -1))

                        context.fill(
                            Path(placement.rect.insetBy(dx: -1.5, dy: -0.8)),
                            with: .color(theme.surface.opacity(0.84))
                        )

                        let tx = placement.alignRight ? placement.rect.maxX : placement.rect.minX
                        let anchor: UnitPoint = placement.alignRight ? .trailing : .leading
                        let primaryColor = isDoneUnseen ? theme.signalGreen : theme.inkSecondary
                        let line1 = Text(tagStr)
                            .font(.system(size: 6.5, weight: .medium, design: .monospaced))
                            .foregroundColor(primaryColor)
                        context.draw(line1, at: CGPoint(x: tx, y: placement.rect.minY + 4.5), anchor: anchor)

                        if useTwoLines {
                            let line2 = Text(coordStr)
                                .font(.system(size: 6.2, weight: .regular, design: .monospaced))
                                .foregroundColor(theme.inkMuted.opacity(0.85))
                            context.draw(line2, at: CGPoint(x: tx, y: placement.rect.minY + 12.2), anchor: anchor)
                        }
                    }
                }
            }
        }
    }

    private func nodePriority(_ node: RadarNode) -> Int {
        switch node.session.status {
        case .waiting: return 0
        case .busy:    return 1
        case .idle, .shell, .unknown:
            return doneUnseenIds.contains(node.id) ? 2 : 3
        }
    }

    private struct LabelPlacement {
        let rect: CGRect
        let alignRight: Bool
        let overlapArea: CGFloat
    }

    /// Deterministic multi-candidate label placement avoiding hubs, node beacons, and earlier labels.
    private func placeLabelBox(
        near np: CGPoint,
        awayFrom hp: CGPoint,
        boxSize: CGSize,
        reticleGap: CGFloat,
        bounds: CGSize,
        occupied: [CGRect]
    ) -> LabelPlacement {
        let padX: CGFloat = 8
        let padY: CGFloat = 5
        let outX = np.x - hp.x
        let outY = np.y - hp.y
        let w = boxSize.width
        let h = boxSize.height

        let candidates: [(x: CGFloat, y: CGFloat, alignRight: Bool, dirX: CGFloat, dirY: CGFloat)] = [
            (np.x + reticleGap,           np.y - h - 2,      false,  1, -1), // upper-right
            (np.x - reticleGap - w,       np.y - h - 2,      true,  -1, -1), // upper-left
            (np.x + reticleGap,           np.y + 2,          false,  1,  1), // lower-right
            (np.x - reticleGap - w,       np.y + 2,          true,  -1,  1), // lower-left
            (np.x + reticleGap + 1,       np.y - h * 0.5,    false,  1,  0), // right
            (np.x - reticleGap - w - 1,   np.y - h * 0.5,    true,  -1,  0), // left
            (np.x - w * 0.5,              np.y - reticleGap - h, false, 0, -1), // above
            (np.x - w * 0.5,              np.y + reticleGap,     false, 0,  1), // below
        ]

        var best: LabelPlacement?
        var bestScore = CGFloat.greatestFiniteMagnitude

        for c in candidates {
            let clampedX = min(max(c.x, padX), max(padX, bounds.width - padX - w))
            let clampedY = min(max(c.y, padY), max(padY, bounds.height - padY - h))
            let rect = CGRect(x: clampedX, y: clampedY, width: w, height: h)

            var overlap: CGFloat = 0
            for occ in occupied {
                let inter = rect.intersection(occ)
                if !inter.isNull && !inter.isEmpty {
                    overlap += inter.width * inter.height
                }
            }

            let clampPenalty = (abs(clampedX - c.x) + abs(clampedY - c.y)) * 1.6
            // Gentle preference for fanning outward away from the workspace hub
            let dot = c.dirX * outX + c.dirY * outY
            let outwardBonus: CGFloat = dot > 0 ? -5.0 : 2.0
            let score = overlap * 40.0 + clampPenalty + outwardBonus

            if score < bestScore {
                bestScore = score
                best = LabelPlacement(rect: rect, alignRight: c.alignRight, overlapArea: overlap)
            }
        }

        return best ?? LabelPlacement(
            rect: CGRect(x: padX, y: padY, width: w, height: h),
            alignRight: false,
            overlapArea: 0
        )
    }

    private func drawLeaderLine(
        in context: inout GraphicsContext,
        from np: CGPoint,
        to rect: CGRect,
        reticleRadius: CGFloat,
        color: Color,
        lineWidth: CGFloat
    ) {
        let targetX = rect.midX >= np.x ? rect.minX - 1.5 : rect.maxX + 1.5
        let targetY = rect.minY + 5.5
        let dx = targetX - np.x
        let dy = targetY - np.y
        let dist = hypot(dx, dy)
        guard dist > reticleRadius + 2 else { return }

        let startX = np.x + (dx / dist) * reticleRadius
        let startY = np.y + (dy / dist) * reticleRadius
        let elbowX = targetX + (rect.midX >= np.x ? -4.0 : 4.0)

        var path = Path()
        path.move(to: CGPoint(x: startX, y: startY))
        path.addLine(to: CGPoint(x: elbowX, y: targetY))
        path.addLine(to: CGPoint(x: targetX, y: targetY))
        context.stroke(path, with: .color(color), lineWidth: lineWidth)
    }

    private static func opticalHash(_ a: Int, _ b: Int) -> UInt32 {
        var h = UInt32(truncatingIfNeeded: a &* 374761393 &+ b &* 668265263)
        h = (h ^ (h >> 13)) &* 1274126177
        return h ^ (h >> 16)
    }
}

// MARK: - Layer 2: Isolated <= 12fps Busy Pulse Ring Overlay (Zero Wakeups When Idle)

private struct BusyPulseTarget: Equatable {
    let pos: Point2D
    let isDimmed: Bool
}

private struct RadarBusyPulseOverlay: View {
    let targets: [BusyPulseTarget]
    let accent: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { ctx in
            let raw = (ctx.date.timeIntervalSinceReferenceDate / 2.0)
                .truncatingRemainder(dividingBy: 1.0)
            let phase = raw < 0 ? raw + 1.0 : raw
            let phase2 = (phase + 0.5).truncatingRemainder(dividingBy: 1.0)

            Canvas { context, size in
                let cw = size.width
                let ch = size.height
                let r1 = 5.5 + CGFloat(phase) * 9.5
                let r2 = 5.5 + CGFloat(phase2) * 9.5
                let a1 = (1.0 - phase) * 0.60
                let a2 = (1.0 - phase2) * 0.28

                var primaryRings = Path()
                var secondaryRings = Path()
                var dimmedRings = Path()

                for t in targets {
                    let cx = CGFloat(t.pos.x) * cw
                    let cy = CGFloat(t.pos.y) * ch
                    let rect1 = CGRect(x: cx - r1, y: cy - r1, width: r1 * 2, height: r1 * 2)
                    if t.isDimmed {
                        dimmedRings.addEllipse(in: rect1)
                    } else {
                        primaryRings.addEllipse(in: rect1)
                        secondaryRings.addEllipse(in: CGRect(x: cx - r2, y: cy - r2, width: r2 * 2, height: r2 * 2))
                    }
                }

                if !secondaryRings.isEmpty {
                    context.stroke(secondaryRings, with: .color(accent.opacity(a2)), lineWidth: 0.75)
                }
                if !primaryRings.isEmpty {
                    context.stroke(primaryRings, with: .color(accent.opacity(a1)), lineWidth: 0.95)
                }
                if !dimmedRings.isEmpty {
                    context.stroke(dimmedRings, with: .color(accent.opacity(a1 * 0.26)), lineWidth: 0.8)
                }
            }
        }
    }
}

// MARK: - Layer 3: Lightweight Active Hover / Selection Reticle Lock Overlay

private struct RadarActiveTargetOverlay: View {
    let node: RadarNode
    let theme: AGYTheme

    var body: some View {
        Canvas { context, size in
            let cw = size.width
            let ch = size.height
            let np = CGPoint(x: CGFloat(node.pos.x) * cw, y: CGFloat(node.pos.y) * ch)
            let hp = CGPoint(x: CGFloat(node.hubPos.x) * cw, y: CGFloat(node.hubPos.y) * ch)
            let isWaiting = (node.session.status == .waiting)
            let highlightColor = isWaiting ? theme.signalAmber : theme.accent
            let lockRadius: CGFloat = isWaiting ? 13.5 : 10.5

            // Subtle 0.5pt horizontal optical scan-band shimmer through locked elevation in Dark mode
            if theme.isDark {
                var lockBand = Path()
                lockBand.move(to: CGPoint(x: 4, y: np.y))
                lockBand.addLine(to: CGPoint(x: cw - 4, y: np.y))
                context.stroke(lockBand, with: .color(highlightColor.opacity(0.18)), lineWidth: 0.5)
            }

            // Concentric multi-layer soft optical lock luminescence
            let outerHaloR = lockRadius + 5.0
            let innerHaloR = lockRadius + 1.5
            context.fill(
                Path(ellipseIn: CGRect(x: np.x - outerHaloR, y: np.y - outerHaloR, width: outerHaloR * 2, height: outerHaloR * 2)),
                with: .color(highlightColor.opacity(theme.isDark ? 0.11 : 0.055))
            )
            context.fill(
                Path(ellipseIn: CGRect(x: np.x - innerHaloR, y: np.y - innerHaloR, width: innerHaloR * 2, height: innerHaloR * 2)),
                with: .color(highlightColor.opacity(theme.isDark ? 0.16 : 0.08))
            )

            // Illuminated triangulation vector
            var vec = Path()
            vec.move(to: hp)
            vec.addLine(to: np)
            context.stroke(vec, with: .color(highlightColor.opacity(0.88)), lineWidth: 1.1)

            // Crisp hairline crosshairs radiating 14pt outward from active target lock
            var hairs = Path()
            let innerHair = lockRadius + 1.5
            let outerHair = lockRadius + 14.0
            hairs.move(to: CGPoint(x: max(2, np.x - outerHair), y: np.y))
            hairs.addLine(to: CGPoint(x: np.x - innerHair, y: np.y))
            hairs.move(to: CGPoint(x: np.x + innerHair, y: np.y))
            hairs.addLine(to: CGPoint(x: min(cw - 2, np.x + outerHair), y: np.y))
            hairs.move(to: CGPoint(x: np.x, y: max(2, np.y - outerHair)))
            hairs.addLine(to: CGPoint(x: np.x, y: np.y - innerHair))
            hairs.move(to: CGPoint(x: np.x, y: np.y + innerHair))
            hairs.addLine(to: CGPoint(x: np.x, y: min(ch - 2, np.y + outerHair)))
            context.stroke(hairs, with: .color(highlightColor.opacity(0.60)), lineWidth: 0.65)

            // Crisp outer target-lock reticle
            drawCornerReticle(
                in: &context,
                center: np,
                radius: lockRadius,
                len: 3.8,
                color: highlightColor,
                lineWidth: 0.95
            )
        }
    }
}

// MARK: - Radar Header Live Output TPS Oscilloscope Micro-Sparkline

private struct RadarLiveTPSReadout: View, Equatable {
    let snapshot: LiveTPSSnapshot
    let theme: AGYTheme
    let tooltipText: String

    private var formattedTPS: String {
        LiveTPSTracker.formatCompactTPS(snapshot.currentTPS)
    }

    var body: some View {
        HStack(spacing: 4) {
            RadarTPSSparklineCanvas(
                samples: snapshot.sparkline,
                accent: theme.accent,
                hairline: theme.hairline,
                isDark: theme.isDark
            )
            .frame(width: 36, height: 12)

            Text(formattedTPS)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(theme.accent)
        }
        .help(tooltipText)
    }
}

private struct RadarTPSSparklineCanvas: View, Equatable {
    let samples: [Double]
    let accent: Color
    let hairline: Color
    let isDark: Bool

    var body: some View {
        Canvas { context, size in
            let cw = size.width
            let ch = size.height
            guard cw > 4, ch > 4 else { return }

            let padX: CGFloat = 1.5
            let padTop: CGFloat = 1.5
            let padBottom: CGFloat = 1.5
            let baseY = ch - padBottom
            let plotH = max(1.0, baseY - padTop)
            let plotW = max(1.0, cw - padX * 2.0)

            // Crisp oscilloscope zero-baseline hairline
            var baseline = Path()
            baseline.move(to: CGPoint(x: padX, y: baseY))
            baseline.addLine(to: CGPoint(x: cw - padX, y: baseY))
            context.stroke(
                baseline,
                with: .color(hairline.opacity(isDark ? 0.72 : 0.60)),
                lineWidth: 0.5
            )

            guard !samples.isEmpty else { return }

            let maxVal = max(samples.max() ?? 0.0, 1.0)
            let points: [CGPoint]
            if samples.count == 1 {
                let norm = CGFloat(min(1.0, max(0.0, samples[0] / maxVal)))
                let y = baseY - norm * plotH
                points = [
                    CGPoint(x: padX + plotW * 0.5, y: y),
                    CGPoint(x: cw - padX, y: y),
                ]
            } else {
                let denom = CGFloat(samples.count - 1)
                points = samples.enumerated().map { idx, val in
                    let x = padX + (CGFloat(idx) / denom) * plotW
                    let norm = CGFloat(min(1.0, max(0.0, val / maxVal)))
                    let y = baseY - norm * plotH
                    return CGPoint(x: x, y: y)
                }
            }

            guard let first = points.first, let last = points.last else { return }

            var linePath = Path()
            linePath.move(to: first)
            for pt in points.dropFirst() {
                linePath.addLine(to: pt)
            }

            var fillPath = linePath
            fillPath.addLine(to: CGPoint(x: last.x, y: baseY))
            fillPath.addLine(to: CGPoint(x: first.x, y: baseY))
            fillPath.closeSubpath()

            context.fill(
                fillPath,
                with: .linearGradient(
                    Gradient(colors: [
                        accent.opacity(isDark ? 0.24 : 0.16),
                        accent.opacity(0.02),
                    ]),
                    startPoint: CGPoint(x: 0, y: padTop),
                    endPoint: CGPoint(x: 0, y: baseY)
                )
            )

            context.stroke(
                linePath,
                with: .color(accent),
                style: StrokeStyle(lineWidth: 1.0, lineCap: .round, lineJoin: .round)
            )

            // Live oscilloscope endpoint dot + faint optical halo
            let haloR: CGFloat = 2.4
            let dotR: CGFloat = 1.25
            context.fill(
                Path(ellipseIn: CGRect(x: last.x - haloR, y: last.y - haloR, width: haloR * 2, height: haloR * 2)),
                with: .color(accent.opacity(isDark ? 0.30 : 0.20))
            )
            context.fill(
                Path(ellipseIn: CGRect(x: last.x - dotR, y: last.y - dotR, width: dotR * 2, height: dotR * 2)),
                with: .color(accent)
            )
        }
    }
}

// MARK: - Shared Reticle Helper

private func drawCornerReticle(
    in context: inout GraphicsContext,
    center: CGPoint,
    radius: CGFloat,
    len: CGFloat,
    color: Color,
    lineWidth: CGFloat
) {
    let minX = center.x - radius, maxX = center.x + radius
    let minY = center.y - radius, maxY = center.y + radius
    var p = Path()
    p.move(to: CGPoint(x: minX, y: minY + len)); p.addLine(to: CGPoint(x: minX, y: minY)); p.addLine(to: CGPoint(x: minX + len, y: minY))
    p.move(to: CGPoint(x: maxX - len, y: minY)); p.addLine(to: CGPoint(x: maxX, y: minY)); p.addLine(to: CGPoint(x: maxX, y: minY + len))
    p.move(to: CGPoint(x: minX, y: maxY - len)); p.addLine(to: CGPoint(x: minX, y: maxY)); p.addLine(to: CGPoint(x: minX + len, y: maxY))
    p.move(to: CGPoint(x: maxX - len, y: maxY)); p.addLine(to: CGPoint(x: maxX, y: maxY)); p.addLine(to: CGPoint(x: maxX, y: maxY - len))
    context.stroke(p, with: .color(color), lineWidth: lineWidth)
}
