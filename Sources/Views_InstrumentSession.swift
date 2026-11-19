import SwiftUI
import AppKit

// Live Sessions Instrument Visualization:
// Agent Telemetry Radar (Ref 1 ray.trace() target lock + Ref 2 cluster triangulation):
// Workspace hubs connected by hairline vectors, dashed coordinator -> worker beams,
// corner reticle locks on `.waiting` beacons, gentle optical pulse on `.busy` nodes,
// and direct click-to-jump interaction.

struct AgentTelemetryRadarView: View {
    let sessions: [SessionInfo]
    @ObservedObject var sessionStore: SessionStore
    var visibleSessionIds: Set<String>? = nil
    var selectedSessionId: String? = nil
    @Binding var hoveredSessionId: String?

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @Environment(\.telemetryStaticRender) private var isStaticRender
    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    private let radarHeight: CGFloat = 124

    private var anyBusy: Bool {
        sessions.contains { $0.status == .busy }
    }

    var body: some View {
        let layout = InstrumentMath.buildSessionRadarLayout(
            sessions: sessions,
            labels: sessionStore.labels
        )

        VStack(alignment: .leading, spacing: 5) {
            headerRow(layout: layout)

            radarStageContainer(layout: layout)
                .frame(height: radarHeight)
                .background(theme.surface.opacity(theme.isDark ? 0.85 : 0.65))
                .overlay(Rectangle().stroke(theme.hairline, lineWidth: 1).allowsHitTesting(false))
                .overlay(CornerReticleOverlay(color: theme.reticle.opacity(0.65), length: 6, lineWidth: 1))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }

    @ViewBuilder
    private func headerRow(layout: SessionRadarLayout) -> some View {
        HStack(spacing: 6) {
            Text(loc("agentRadarTitle"))
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundColor(theme.inkSecondary)

            Spacer(minLength: 4)

            if let hid = hoveredSessionId,
               let node = layout.nodes.first(where: { $0.id == hid }) {
                let surfacePart = node.surfaceCode.map { " · \($0)" } ?? ""
                Text("PID \(node.session.pid) · \(node.workspaceLabel)\(surfacePart) ↗")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundColor(node.session.status == .waiting ? theme.signalAmber : theme.accent)
                    .lineLimit(1)
            } else {
                Text(String(format: "%02d HUBS · %02d NODES", layout.hubs.count, layout.nodes.count))
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.inkMuted)
            }
        }
    }

    @ViewBuilder
    private func radarStageContainer(layout: SessionRadarLayout) -> some View {
        if anyBusy && !reduceMotion && !isStaticRender {
            TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { ctx in
                let raw = (ctx.date.timeIntervalSinceReferenceDate / 1.8)
                    .truncatingRemainder(dividingBy: 1.0)
                let phase = raw < 0 ? raw + 1.0 : raw
                radarStage(layout: layout, pulsePhase: phase)
            }
        } else {
            radarStage(layout: layout, pulsePhase: 0.42)
        }
    }

    private func radarStage(layout: SessionRadarLayout, pulsePhase: Double) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack(alignment: .topLeading) {
                DotGraticuleBackground(spacing: 14)

                Canvas { context, size in
                    let cw = size.width
                    let ch = size.height
                    let center = CGPoint(x: cw * 0.5, y: ch * 0.5)

                    func pt(_ p: Point2D) -> CGPoint {
                        CGPoint(x: CGFloat(p.x) * cw, y: CGFloat(p.y) * ch)
                    }

                    // 1. Subtle radar range circles & axis crosshairs
                    for radius in [24.0, 48.0, 72.0] {
                        let rRect = CGRect(
                            x: center.x - radius,
                            y: center.y - radius,
                            width: radius * 2,
                            height: radius * 2
                        )
                        context.stroke(
                            Path(ellipseIn: rRect),
                            with: .color(theme.hairline.opacity(0.60)),
                            style: StrokeStyle(lineWidth: 0.75, dash: [2, 3])
                        )
                    }

                    var axes = Path()
                    axes.move(to: CGPoint(x: 0, y: center.y))
                    axes.addLine(to: CGPoint(x: cw, y: center.y))
                    axes.move(to: CGPoint(x: center.x, y: 0))
                    axes.addLine(to: CGPoint(x: center.x, y: ch))
                    context.stroke(axes, with: .color(theme.hairline.opacity(0.45)), lineWidth: 0.75)

                    // 2. Hub triangulation vectors & dashed coordinator -> subagent beams
                    for node in layout.nodes {
                        let np = pt(node.pos)
                        let hp = pt(node.hubPos)
                        let isHighlighted = (hoveredSessionId == node.id || selectedSessionId == node.id)
                        let isDimmed = visibleSessionIds.map { !$0.contains(node.id) } ?? false

                        var vec = Path()
                        vec.move(to: hp)
                        vec.addLine(to: np)
                        let vecColor: Color = {
                            if isHighlighted { return theme.accent.opacity(0.85) }
                            if node.session.status == .waiting { return theme.signalAmber.opacity(isDimmed ? 0.20 : 0.65) }
                            return theme.hairlineStrong.opacity(isDimmed ? 0.25 : 0.80)
                        }()
                        context.stroke(vec, with: .color(vecColor), lineWidth: isHighlighted ? 1.15 : 0.8)

                        if let parentP = node.parentNodePos {
                            let pp = pt(parentP)
                            var swarmBeam = Path()
                            swarmBeam.move(to: pp)
                            swarmBeam.addLine(to: np)
                            context.stroke(
                                swarmBeam,
                                with: .color(theme.accent.opacity(isDimmed ? 0.20 : 0.72)),
                                style: StrokeStyle(lineWidth: 1.0, dash: [3, 2])
                            )
                        }
                    }

                    // 3. Workspace hub diamond anchors + micro hub codes
                    for hub in layout.hubs {
                        let hp = pt(hub.pos)
                        let r: CGFloat = 3.5
                        var diamond = Path()
                        diamond.move(to: CGPoint(x: hp.x, y: hp.y - r))
                        diamond.addLine(to: CGPoint(x: hp.x + r, y: hp.y))
                        diamond.addLine(to: CGPoint(x: hp.x, y: hp.y + r))
                        diamond.addLine(to: CGPoint(x: hp.x - r, y: hp.y))
                        diamond.closeSubpath()

                        context.fill(diamond, with: .color(theme.canvas))
                        context.stroke(diamond, with: .color(theme.inkSecondary), lineWidth: 1.0)

                        let labelY = hp.y > ch * 0.55 ? min(ch - 8, hp.y + 11) : max(9, hp.y - 11)
                        let labelStr = hub.label.uppercased()
                        let haloW = CGFloat(labelStr.count) * 5.0 + 6
                        let haloRect = CGRect(x: hp.x - haloW * 0.5, y: labelY - 5.5, width: haloW, height: 11)
                        context.fill(Path(haloRect), with: .color(theme.surface.opacity(0.88)))
                        let labelText = Text(labelStr)
                            .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                            .foregroundColor(theme.inkSecondary)
                        context.draw(labelText, at: CGPoint(x: hp.x, y: labelY))
                    }

                    // 4. Session telemetry beacons
                    for node in layout.nodes {
                        let np = pt(node.pos)
                        let isHovered = (hoveredSessionId == node.id)
                        let isSelected = (selectedSessionId == node.id)
                        let isDoneUnseen = sessionStore.doneUnseen.contains(node.id)
                        let isDimmed = visibleSessionIds.map { !$0.contains(node.id) } ?? false
                        let alphaMul: Double = isDimmed ? 0.28 : 1.0

                        switch node.session.status {
                        case .waiting:
                            let amb = theme.signalAmber.opacity(alphaMul)
                            // Ref-1 target lock corner brackets `┌ ┐ └ ┘`
                            drawCornerReticle(in: &context, center: np, radius: isHovered ? 9 : 7.5, len: 3.5, color: amb)

                            // Core rotating diamond beacon
                            let dr: CGFloat = 3.5
                            var dia = Path()
                            dia.move(to: CGPoint(x: np.x, y: np.y - dr))
                            dia.addLine(to: CGPoint(x: np.x + dr, y: np.y))
                            dia.addLine(to: CGPoint(x: np.x, y: np.y + dr))
                            dia.addLine(to: CGPoint(x: np.x - dr, y: np.y))
                            dia.closeSubpath()
                            context.fill(dia, with: .color(amb))

                            // Short HUD leader tag (`CONFIRM` / `INPUT`)
                            if !isDimmed {
                                let alignLeft = node.pos.x > 0.68
                                let dx: CGFloat = alignLeft ? -11 : 11
                                let tag = node.session.waitReason == .needsConfirmation ? loc("badgeConfirm") : loc("badgeInput")
                                var ldr = Path()
                                ldr.move(to: CGPoint(x: np.x + (alignLeft ? -8 : 8), y: np.y))
                                ldr.addLine(to: CGPoint(x: np.x + dx * 1.4, y: np.y - 6))
                                context.stroke(ldr, with: .color(amb.opacity(0.85)), lineWidth: 0.85)

                                let tx = min(max(np.x + (alignLeft ? -34 : 34), 26), cw - 26)
                                let ty = max(10, np.y - 9)
                                let pillRect = CGRect(x: tx - 21, y: ty - 5.5, width: 42, height: 11)
                                context.fill(Path(pillRect), with: .color(amb))
                                let tagText = Text(tag)
                                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                                    .foregroundColor(.black)
                                context.draw(tagText, at: CGPoint(x: tx, y: ty))
                            }

                        case .busy:
                            let c = theme.accent.opacity(alphaMul)
                            // Optical expanding wave ring + bloom
                            let waveR = 5.0 + CGFloat(pulsePhase) * 8.0
                            let waveAlpha = (1.0 - pulsePhase) * 0.65 * alphaMul
                            context.stroke(
                                Path(ellipseIn: CGRect(x: np.x - waveR, y: np.y - waveR, width: waveR * 2, height: waveR * 2)),
                                with: .color(theme.accent.opacity(waveAlpha)),
                                lineWidth: 1.0
                            )
                            context.fill(
                                Path(ellipseIn: CGRect(x: np.x - 5.5, y: np.y - 5.5, width: 11, height: 11)),
                                with: .color(c.opacity(0.24))
                            )
                            context.fill(
                                Path(ellipseIn: CGRect(x: np.x - 3, y: np.y - 3, width: 6, height: 6)),
                                with: .color(c)
                            )

                        case .idle, .shell, .unknown:
                            if isDoneUnseen {
                                let g = theme.signalGreen.opacity(alphaMul)
                                context.stroke(
                                    Path(ellipseIn: CGRect(x: np.x - 5, y: np.y - 5, width: 10, height: 10)),
                                    with: .color(g.opacity(0.6)),
                                    lineWidth: 0.9
                                )
                                context.fill(
                                    Path(ellipseIn: CGRect(x: np.x - 2.5, y: np.y - 2.5, width: 5, height: 5)),
                                    with: .color(g)
                                )
                            } else {
                                let ink = theme.inkSecondary.opacity(alphaMul)
                                var plus = Path()
                                plus.move(to: CGPoint(x: np.x - 3, y: np.y)); plus.addLine(to: CGPoint(x: np.x + 3, y: np.y))
                                plus.move(to: CGPoint(x: np.x, y: np.y - 3)); plus.addLine(to: CGPoint(x: np.x, y: np.y + 3))
                                context.stroke(plus, with: .color(ink), lineWidth: 1.1)
                            }
                        }

                        // Hovered or keyboard-selected lock ring + micro surface code
                        if isHovered || isSelected {
                            drawCornerReticle(in: &context, center: np, radius: 10, len: 4, color: theme.inkPrimary)
                        }
                    }
                }
                .allowsHitTesting(false)

                // Direct click & hover hit targets pinned to each node's projected position
                ForEach(layout.nodes) { node in
                    let nx = CGFloat(node.pos.x) * w
                    let ny = CGFloat(node.pos.y) * h
                    RadarHitTarget(
                        onHoverChange: { inside in
                            hoveredSessionId = inside ? node.id : (hoveredSessionId == node.id ? nil : hoveredSessionId)
                        },
                        onTap: { sessionStore.jump(node.session) }
                    )
                    .position(x: nx, y: ny)
                }
            }
        }
    }

    private func drawCornerReticle(
        in context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        len: CGFloat,
        color: Color
    ) {
        let minX = center.x - radius, maxX = center.x + radius
        let minY = center.y - radius, maxY = center.y + radius
        var p = Path()
        p.move(to: CGPoint(x: minX, y: minY + len)); p.addLine(to: CGPoint(x: minX, y: minY)); p.addLine(to: CGPoint(x: minX + len, y: minY))
        p.move(to: CGPoint(x: maxX - len, y: minY)); p.addLine(to: CGPoint(x: maxX, y: minY)); p.addLine(to: CGPoint(x: maxX, y: minY + len))
        p.move(to: CGPoint(x: minX, y: maxY - len)); p.addLine(to: CGPoint(x: minX, y: maxY)); p.addLine(to: CGPoint(x: minX + len, y: maxY))
        p.move(to: CGPoint(x: maxX - len, y: maxY)); p.addLine(to: CGPoint(x: maxX, y: maxY)); p.addLine(to: CGPoint(x: maxX, y: maxY - len))
        context.stroke(p, with: .color(color), lineWidth: 1.0)
    }
}

private struct RadarHitTarget: View {
    let onHoverChange: (Bool) -> Void
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Color.clear
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .onHover { inside in
                guard inside != hovering else { return }
                hovering = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                onHoverChange(inside)
            }
            .onDisappear {
                if hovering { NSCursor.pop(); hovering = false }
            }
            .onTapGesture(perform: onTap)
    }
}
