import SwiftUI
import AppKit

// Plan Tab Instrument Visualization:
// Dual 270° Orbital Phase Gyroscope Dials with radial Pace Vector rays & burn-deficit
// sector arcs, plus paired 7D weekly horizon strip.

struct OrbitalPlanDeck: View {
    let quota: OAuthUsage
    let geminiWeeklyLimits: [OAuthUsageLimit]
    let claudeWeeklyLimits: [OAuthUsageLimit]
    let hasGemini5h: Bool
    let hasClaude5h: Bool

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            if hasGemini5h || hasClaude5h {
                HStack(spacing: 0) {
                    if hasGemini5h {
                        OrbitalQuotaDial(
                            title: loc("planGeminiFamily"),
                            codes: "CRB · ARG · NEO",
                            usedPercent: quota.five_hour.displayPercent,
                            resetAt: quota.fiveHourResetDate,
                            windowDurationSeconds: QuotaPaceLogic.fiveHourWindowSeconds
                        )
                        .frame(maxWidth: .infinity)
                    }

                    if hasGemini5h && hasClaude5h {
                        Rectangle().fill(theme.hairline).frame(width: 1)
                    }

                    if hasClaude5h {
                        OrbitalQuotaDial(
                            title: loc("planClaudeFamily"),
                            codes: "CLD · OTH",
                            usedPercent: quota.seven_day.displayPercent,
                            resetAt: quota.sevenDayResetDate,
                            windowDurationSeconds: QuotaPaceLogic.fiveHourWindowSeconds
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                HairlineRule(showCrosshairs: true)
            }

            if !geminiWeeklyLimits.isEmpty || !claudeWeeklyLimits.isEmpty {
                weeklyHorizonStrip
                HairlineRule(showCrosshairs: true)
            }
        }
    }

    private var weeklyHorizonStrip: some View {
        let items: [(title: String, lim: OAuthUsageLimit)] =
            geminiWeeklyLimits.map { ("GEMINI · 7D", $0) }
            + claudeWeeklyLimits.map { ("CLAUDE · 7D", $0) }

        return HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, entry in
                let remaining = entry.lim.remainingPercent
                let frac = max(0, min(1, CGFloat(remaining) / 100.0))
                let pace = QuotaPaceLogic.compute(
                    usedPercent: entry.lim.displayPercent,
                    resetAt: entry.lim.resetDate,
                    windowDurationSeconds: QuotaPaceLogic.sevenDayWindowSeconds,
                    now: Date()
                )
                let tint: Color = {
                    switch remaining {
                    case 30...:   return theme.accent
                    case 10..<30: return theme.signalAmber
                    default:      return theme.signalRed
                    }
                }()

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(entry.title)
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .foregroundColor(theme.inkSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        if let r = entry.lim.resetDate {
                            Text(String(format: loc("planResetShortFmt"), formatQuotaResetDuration(r).uppercased()))
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundColor(theme.inkMuted)
                        }
                    }

                    HStack(alignment: .firstTextBaseline) {
                        Text("\(remaining)%")
                            .font(.system(size: 13.5, weight: .bold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(remaining < 30 ? tint : theme.inkPrimary)
                        Text("LEFT")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.inkMuted)
                        Spacer()
                        if let p = pace {
                            let sign = p.paceDeltaPercent > 0 ? "+\(p.paceDeltaPercent)%" : "\(p.paceDeltaPercent)%"
                            Text(p.isOverPaceWarning ? "▲ \(sign)" : sign)
                                .font(.system(size: 8.5, weight: p.isOverPaceWarning ? .bold : .medium, design: .monospaced))
                                .foregroundColor(p.isOverPaceWarning ? theme.signalAmber : theme.inkSecondary)
                        }
                    }

                    VernierScaleBar(
                        fraction: frac,
                        fillColor: tint,
                        paceMarkerFraction: pace.map { CGFloat($0.expectedRemainingFraction) },
                        paceWarning: pace?.isOverPaceWarning == true,
                        ticks: 30
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                if idx < items.count - 1 {
                    Rectangle().fill(theme.hairline).frame(width: 1)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Single Orbital Phase Dial

private struct OrbitalQuotaDial: View {
    let title: String
    let codes: String
    let usedPercent: Int
    let resetAt: Date?
    let windowDurationSeconds: TimeInterval

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme

    private let dialDiameter: CGFloat = 112

    private var remaining: Int { max(0, 100 - usedPercent) }
    private var remainingFraction: Double { max(0.0, min(1.0, Double(remaining) / 100.0)) }

    private var pace: QuotaPaceSnapshot? {
        QuotaPaceLogic.compute(
            usedPercent: usedPercent,
            resetAt: resetAt,
            windowDurationSeconds: windowDurationSeconds,
            now: Date()
        )
    }

    private var statusColor: Color {
        switch remaining {
        case 30...:   return theme.accent
        case 10..<30: return theme.signalAmber
        default:      return theme.signalRed
        }
    }

    var body: some View {
        let angles = InstrumentMath.orbitalGaugeAngles(
            remainingFraction: remainingFraction,
            paceExpectedRemainingFraction: pace?.expectedRemainingFraction,
            isOverPaceWarning: pace?.isOverPaceWarning == true
        )

        VStack(spacing: 6) {
            // Header
            VStack(alignment: .leading, spacing: 1.5) {
                Text(title)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundColor(theme.inkPrimary)
                    .lineLimit(1)
                Text(codes)
                    .font(.system(size: 7.5, design: .monospaced))
                    .foregroundColor(theme.inkMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 270° Orbital Phase Gauge Canvas
            ZStack {
                DotGraticuleBackground(spacing: 12)

                Canvas { context, size in
                    let cx = size.width * 0.5
                    let cy = size.height * 0.52
                    let center = CGPoint(x: cx, y: cy)
                    let radius: CGFloat = 41
                    let tickOuterR: CGFloat = 50
                    let innerRingR: CGFloat = 31

                    // 1. 48 calibrated vernier dial ticks along 270 deg
                    let tickCount = 48
                    for i in 0...tickCount {
                        let f = Double(i) / Double(tickCount)
                        let ang = InstrumentMath.orbitalAngleRad(fraction: f)
                        let isMajor = (i % 12 == 0)
                        let r0 = radius + 4.5
                        let r1 = isMajor ? tickOuterR + 1.5 : tickOuterR - 1.5
                        var tick = Path()
                        tick.move(to: CGPoint(x: cx + cos(ang) * r0, y: cy + sin(ang) * r0))
                        tick.addLine(to: CGPoint(x: cx + cos(ang) * r1, y: cy + sin(ang) * r1))
                        let isLit = f <= remainingFraction + 0.001
                        context.stroke(
                            tick,
                            with: .color(isLit ? statusColor.opacity(0.92) : theme.hairlineStrong.opacity(0.55)),
                            lineWidth: isMajor ? 1.2 : 0.75
                        )
                    }

                    // 2. Background track arc
                    var track = Path()
                    track.addArc(
                        center: center,
                        radius: radius,
                        startAngle: .radians(angles.startAngle),
                        endAngle: .radians(angles.endAngle),
                        clockwise: false
                    )
                    context.stroke(
                        track,
                        with: .color(theme.hairlineStrong.opacity(0.45)),
                        style: StrokeStyle(lineWidth: 6, lineCap: .butt)
                    )

                    // 3. Deficit warning sector between remainingEndAngle & expected paceAngle when over-pace
                    if let pAng = angles.paceAngle, pAng > angles.remainingEndAngle + 0.02 {
                        var deficitArc = Path()
                        deficitArc.addArc(
                            center: center,
                            radius: radius,
                            startAngle: .radians(angles.remainingEndAngle),
                            endAngle: .radians(pAng),
                            clockwise: false
                        )
                        context.stroke(
                            deficitArc,
                            with: .color((angles.isDeficit ? theme.signalAmber : theme.inkMuted).opacity(0.35)),
                            style: StrokeStyle(lineWidth: 6, lineCap: .butt)
                        )
                    }

                    // 4. Active remaining quota arc (+ dark optical glow)
                    if remainingFraction > 0.004 {
                        var remArc = Path()
                        remArc.addArc(
                            center: center,
                            radius: radius,
                            startAngle: .radians(angles.startAngle),
                            endAngle: .radians(angles.remainingEndAngle),
                            clockwise: false
                        )
                        if theme.isDark {
                            context.stroke(
                                remArc,
                                with: .color(statusColor.opacity(0.24)),
                                style: StrokeStyle(lineWidth: 10, lineCap: .butt)
                            )
                        }
                        context.stroke(
                            remArc,
                            with: .color(statusColor),
                            style: StrokeStyle(lineWidth: 6, lineCap: .butt)
                        )
                    }

                    // 5. Inner time-elapsed reference ring + radial Pace Vector ray
                    var innerTrack = Path()
                    innerTrack.addArc(
                        center: center,
                        radius: innerRingR,
                        startAngle: .radians(angles.startAngle),
                        endAngle: .radians(angles.endAngle),
                        clockwise: false
                    )
                    context.stroke(
                        innerTrack,
                        with: .color(theme.hairline),
                        style: StrokeStyle(lineWidth: 1, dash: [2, 2])
                    )

                    if let pAng = angles.paceAngle {
                        var elapsedArc = Path()
                        elapsedArc.addArc(
                            center: center,
                            radius: innerRingR,
                            startAngle: .radians(angles.startAngle),
                            endAngle: .radians(pAng),
                            clockwise: false
                        )
                        let paceColor = angles.isDeficit ? theme.signalAmber : theme.inkSecondary
                        context.stroke(elapsedArc, with: .color(paceColor.opacity(0.85)), lineWidth: 1.5)

                        // Radial target vector ray intersecting the gauge track
                        let rStart = innerRingR - 2
                        let rEnd = tickOuterR + 1
                        var ray = Path()
                        ray.move(to: CGPoint(x: cx + cos(pAng) * rStart, y: cy + sin(pAng) * rStart))
                        ray.addLine(to: CGPoint(x: cx + cos(pAng) * rEnd, y: cy + sin(pAng) * rEnd))
                        context.stroke(ray, with: .color(paceColor), lineWidth: 1.3)

                        let tipX = cx + cos(pAng) * rEnd
                        let tipY = cy + sin(pAng) * rEnd
                        context.fill(
                            Path(CGRect(x: tipX - 2, y: tipY - 2, width: 4, height: 4)),
                            with: .color(paceColor)
                        )
                    }
                }
                .frame(width: dialDiameter, height: dialDiameter)

                // Center core numeric readout inside dial aperture
                VStack(spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(remaining)")
                            .font(.system(size: 21, weight: .bold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(remaining < 30 ? statusColor : theme.inkPrimary)
                            .contentTransition(.numericText())
                        Text("%")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.inkSecondary)
                    }
                    Text("LEFT")
                        .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.inkMuted)
                }
                .offset(y: -2)
            }
            .frame(height: dialDiameter)

            // Bottom calibration readout: Window + Pace / Reset countdown
            HStack(spacing: 4) {
                if let r = resetAt {
                    Text(String(format: loc("planResetShortFmt"), formatQuotaResetDuration(r).uppercased()))
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.inkSecondary)
                } else {
                    Text(loc("planWindow5h"))
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.inkMuted)
                }

                Spacer(minLength: 2)

                if let p = pace {
                    let sign = p.paceDeltaPercent > 0 ? "+\(p.paceDeltaPercent)%" : "\(p.paceDeltaPercent)%"
                    let tag = p.isOverPaceWarning ? "▲ \(loc("paceFast")) \(sign)" : "\(loc("paceSafe")) \(sign)"
                    Text(tag)
                        .font(.system(size: 8, weight: p.isOverPaceWarning ? .bold : .semibold, design: .monospaced))
                        .foregroundColor(p.isOverPaceWarning ? theme.signalAmber : theme.accent)
                        .padding(.horizontal, p.isOverPaceWarning ? 4 : 0)
                        .padding(.vertical, p.isOverPaceWarning ? 1 : 0)
                        .overlay {
                            if p.isOverPaceWarning {
                                CornerReticleOverlay(color: theme.signalAmber, length: 3, lineWidth: 0.9)
                            }
                        }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
