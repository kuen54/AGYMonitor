import SwiftUI
import AppKit

// Plan Tab Instrument Visualization (FIG. 05):
// Dual 270° Swiss Drafting Protractor Gauges with calibrated cardinal numerals (0/50/100),
// deterministic archival stippled calibration halos, batched 60-tick graduated vernier scales,
// sleek 2.8pt precision arcs, diagonal-hatched burn-deficit sectors, radial Pace Vector rays
// with Fred-style coordinate reticles, and paired 48-line 7D Swiss caliper verniers.

struct OrbitalPlanDeck: View {
    let quota: OAuthUsage
    let geminiWeeklyLimits: [OAuthUsageLimit]
    let claudeWeeklyLimits: [OAuthUsageLimit]
    let hasGemini5h: Bool
    let hasClaude5h: Bool

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme

    private var hasWeekly: Bool {
        !geminiWeeklyLimits.isEmpty || !claudeWeeklyLimits.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasGemini5h || hasClaude5h {
                HStack(spacing: 0) {
                    if hasGemini5h {
                        OrbitalQuotaDial(
                            indexTag: "05.1",
                            title: stripLeadingIndexPrefix(loc("planGeminiFamily")),
                            codes: "CRB · ARG · NEO",
                            usedPercent: quota.five_hour.displayPercent,
                            resetAt: quota.fiveHourResetDate,
                            windowDurationSeconds: QuotaPaceLogic.fiveHourWindowSeconds,
                            dialSeed: 11
                        )
                        .frame(maxWidth: .infinity)
                    }

                    if hasGemini5h && hasClaude5h {
                        Rectangle().fill(theme.hairline.opacity(0.85)).frame(width: 1)
                    }

                    if hasClaude5h {
                        OrbitalQuotaDial(
                            indexTag: "05.2",
                            title: stripLeadingIndexPrefix(loc("planClaudeFamily")),
                            codes: "CLD · OTH",
                            usedPercent: quota.seven_day.displayPercent,
                            resetAt: quota.sevenDayResetDate,
                            windowDurationSeconds: QuotaPaceLogic.fiveHourWindowSeconds,
                            dialSeed: 29,
                            useSecondaryAccent: true
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                if hasWeekly {
                    HairlineRule(showCrosshairs: true)
                }
            }

            if hasWeekly {
                weeklyHorizonStrip
            }
        }
    }

    // MARK: 7D Weekly Horizon Strip

    private var weeklyHorizonStrip: some View {
        let now = Date()
        let items: [(title: String, lim: OAuthUsageLimit, useSecondaryAccent: Bool)] =
            geminiWeeklyLimits.map { ("GEMINI · 7D", $0, false) }
            + claudeWeeklyLimits.map { ("CLAUDE · 7D", $0, true) }

        return HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, entry in
                let remaining = entry.lim.remainingPercent
                let frac = max(0, min(1, CGFloat(remaining) / 100.0))
                let pace = QuotaPaceLogic.compute(
                    usedPercent: entry.lim.displayPercent,
                    resetAt: entry.lim.resetDate,
                    windowDurationSeconds: QuotaPaceLogic.sevenDayWindowSeconds,
                    now: now
                )
                let familyAccent = entry.useSecondaryAccent ? theme.accentSecondary : theme.accent
                let alertColor: Color? = {
                    switch remaining {
                    case 30...:   return nil
                    case 10..<30: return theme.signalAmber
                    default:      return theme.signalRed
                    }
                }()

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(entry.title)
                            .font(.system(size: 8, weight: .regular, design: .monospaced))
                            .tracking(0.7)
                            .foregroundColor(theme.inkSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        if let r = entry.lim.resetDate {
                            Text(String(format: loc("planResetShortFmt"), formatQuotaResetDuration(r).uppercased()))
                                .font(.system(size: 7.5, weight: .regular, design: .monospaced))
                                .monospacedDigit()
                                .foregroundColor(theme.inkMuted)
                        }
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(remaining)%")
                            .font(.system(size: 17, weight: .light, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(alertColor ?? theme.inkPrimary)
                        Text("LEFT")
                            .font(.system(size: 7.5, weight: .regular, design: .monospaced))
                            .tracking(0.8)
                            .foregroundColor(theme.inkMuted)
                        Spacer(minLength: 4)
                        if let p = pace {
                            let signed = formatSignedPaceDelta(p.paceDeltaPercent)
                            Text(p.isOverPaceWarning ? "▲ \(signed)" : signed)
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                                .monospacedDigit()
                                .foregroundColor(p.isOverPaceWarning ? theme.signalAmber : theme.inkSecondary)
                        }
                    }

                    DraftingVernierBar(
                        fraction: frac,
                        litColor: alertColor ?? familyAccent.opacity(0.88),
                        paceMarkerFraction: pace.map { CGFloat($0.expectedRemainingFraction) },
                        paceMarkerColor: (pace?.isOverPaceWarning == true) ? theme.signalAmber : familyAccent,
                        isOverPace: pace?.isOverPaceWarning == true,
                        ticks: 48,
                        barSeed: idx + 1
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)

                if idx < items.count - 1 {
                    Rectangle().fill(theme.hairline.opacity(0.85)).frame(width: 1)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Single Swiss Drafting Protractor Gauge

private struct OrbitalQuotaDial: View {
    let indexTag: String
    let title: String
    let codes: String
    let usedPercent: Int
    let resetAt: Date?
    let windowDurationSeconds: TimeInterval
    let dialSeed: Int
    var useSecondaryAccent: Bool = false

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @Environment(\.telemetryStaticRender) private var telemetryStaticRender
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let dialWidth: CGFloat = 152
    private let dialHeight: CGFloat = 132

    private struct ProtractorArtworkKey: Hashable {
        let usedPercent: Int
        let paceAngleMilli: Int?
        let isOverPace: Bool
        let dialSeed: Int
        let useSecondaryAccent: Bool
        let theme: AGYTheme.CacheKey
    }

    private var remaining: Int { max(0, 100 - usedPercent) }
    private var remainingFraction: Double { max(0.0, min(1.0, Double(remaining) / 100.0)) }

    private var dialAccent: Color {
        useSecondaryAccent ? theme.accentSecondary : theme.accent
    }

    private var statusColor: Color {
        switch remaining {
        case 30...:   return dialAccent
        case 10..<30: return theme.signalAmber
        default:      return theme.signalRed
        }
    }

    var body: some View {
        let currentPace = QuotaPaceLogic.compute(
            usedPercent: usedPercent,
            resetAt: resetAt,
            windowDurationSeconds: windowDurationSeconds,
            now: Date()
        )
        let angles = InstrumentMath.orbitalGaugeAngles(
            remainingFraction: remainingFraction,
            paceExpectedRemainingFraction: currentPace?.expectedRemainingFraction,
            isOverPaceWarning: currentPace?.isOverPaceWarning == true
        )

        VStack(spacing: 4) {
            // Specimen Header: 05.1 GEMINI FAMILY / CRB · ARG · NEO
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(indexTag)
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundColor(dialAccent.opacity(0.9))
                    Text(title)
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .tracking(0.6)
                        .foregroundColor(theme.inkPrimary)
                        .lineLimit(1)
                }
                Text(codes)
                    .font(.system(size: 7.5, weight: .regular, design: .monospaced))
                    .tracking(0.4)
                    .foregroundColor(theme.inkMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 270° Horological / Drafting Protractor Canvas (pre-rendered 2x Retina cached artwork)
            ZStack {
                CachedTelemetryArtwork(
                    key: ProtractorArtworkKey(
                        usedPercent: usedPercent,
                        paceAngleMilli: angles.paceAngle.map { Int(($0 * 1000.0).rounded()) },
                        isOverPace: currentPace?.isOverPaceWarning == true,
                        dialSeed: dialSeed,
                        useSecondaryAccent: useSecondaryAccent,
                        theme: theme.cacheKey
                    ),
                    width: dialWidth,
                    height: dialHeight
                ) {
                    ProtractorDialCanvas(
                        remainingFraction: remainingFraction,
                        angles: angles,
                        statusColor: statusColor,
                        theme: theme,
                        dialSeed: dialSeed
                    )
                }
                .allowsHitTesting(false)

                // Sculptural .ultraLight Center Numeral aligned to dial aperture center
                VStack(spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 1.5) {
                        Text("%")
                            .font(.system(size: 10, weight: .light, design: .monospaced))
                            .opacity(0)
                            .accessibilityHidden(true)
                        Text("\(remaining)")
                            .font(.system(size: remaining >= 100 ? 24 : 26, weight: .ultraLight, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(remaining < 30 ? statusColor : theme.inkPrimary)
                            .contentTransition((telemetryStaticRender || reduceMotion) ? .identity : .numericText())
                        Text("%")
                            .font(.system(size: 10, weight: .light, design: .monospaced))
                            .foregroundColor(theme.inkSecondary)
                    }
                    Text("LEFT")
                        .font(.system(size: 7, weight: .regular, design: .monospaced))
                        .tracking(1.0)
                        .padding(.leading, 1.0)
                        .foregroundColor(theme.inkMuted)
                }
                .offset(y: 7.5)
            }
            .frame(height: dialHeight)

            // Bottom calibration row: Reset countdown + monochrome NOMINAL / hairline amber reticle FAST
            HStack(spacing: 4) {
                if let r = resetAt {
                    Text(String(format: loc("planResetShortFmt"), formatQuotaResetDuration(r).uppercased()))
                        .font(.system(size: 8, weight: .regular, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(theme.inkMuted)
                        .lineLimit(1)
                } else {
                    Text(loc("planWindow5h"))
                        .font(.system(size: 8, weight: .regular, design: .monospaced))
                        .foregroundColor(theme.inkMuted)
                        .lineLimit(1)
                }

                Spacer(minLength: 2)

                if let p = currentPace {
                    let signed = formatSignedPaceDelta(p.paceDeltaPercent)
                    if p.isOverPaceWarning {
                        HStack(spacing: 3.5) {
                            Rectangle()
                                .fill(theme.signalAmber)
                                .frame(width: 4.5, height: 4.5)
                                .rotationEffect(.degrees(45))
                            Text("\(loc("paceFast")) \(signed)")
                                .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                                .monospacedDigit()
                                .foregroundColor(theme.signalAmber)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1.5)
                        .background(theme.signalAmber.opacity(theme.isDark ? 0.11 : 0.08))
                        .overlay(
                            Rectangle()
                                .strokeBorder(theme.signalAmber.opacity(0.5), lineWidth: 0.75)
                        )
                    } else {
                        Text("\(loc("paceSafe")) \(signed)")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(theme.inkSecondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 10)
    }
}

/// Equatable static Canvas for the 270° horological protractor dial:
/// polar crosshairs, deterministic archival stippled calibration halo, 60-tick graduated vernier,
/// cardinal micro scale numerals (0 / 50 / 100), diagonal-hatched over-pace deficit sector,
/// optical-bloomed active arc, and Fred-style coordinate reticle on the radial PACE ray tip.
private struct ProtractorDialCanvas: View, Equatable {
    let remainingFraction: Double
    let angles: OrbitalGaugeAngles
    let statusColor: Color
    let theme: AGYTheme
    let dialSeed: Int

    var body: some View {
        Canvas { context, size in
            let cx = size.width * 0.5
            let cy = size.height * 0.556
            let center = CGPoint(x: cx, y: cy)
            let radius: CGFloat = 44.5
            let innerRingR: CGFloat = 34.5
            let tickInnerR: CGFloat = 49.0
            let minorOuterR: CGFloat = 52.5
            let mediumOuterR: CGFloat = 54.3
            let majorOuterR: CGFloat = 56.2
            let crosshairR: CGFloat = 58.0

            // 1. Clean hairline polar crosshairs behind the protractor (single batched Path)
            var crosshairs = Path()
            crosshairs.move(to: CGPoint(x: cx - crosshairR, y: cy))
            crosshairs.addLine(to: CGPoint(x: cx - innerRingR + 2, y: cy))
            crosshairs.move(to: CGPoint(x: cx + innerRingR - 2, y: cy))
            crosshairs.addLine(to: CGPoint(x: cx + crosshairR, y: cy))
            crosshairs.move(to: CGPoint(x: cx, y: cy - crosshairR))
            crosshairs.addLine(to: CGPoint(x: cx, y: cy - innerRingR + 2))
            crosshairs.move(to: CGPoint(x: cx, y: cy + innerRingR + 2.5))
            crosshairs.addLine(to: CGPoint(x: cx, y: cy + radius + 5.0))
            context.stroke(crosshairs, with: .color(theme.hairline.opacity(0.55)), lineWidth: 0.5)

            // 2. Deterministic archival stippled calibration halo along the active remaining band
            //    (batched into 1 Path, ~140 tiny 1px dots tapering radially inward inside aperture)
            if remainingFraction > 0.008 {
                var washArc = Path()
                washArc.addArc(
                    center: center,
                    radius: (innerRingR + radius) * 0.5,
                    startAngle: .radians(angles.startAngle),
                    endAngle: .radians(angles.remainingEndAngle),
                    clockwise: false
                )
                context.stroke(
                    washArc,
                    with: .color(statusColor.opacity(theme.isDark ? 0.065 : 0.042)),
                    style: StrokeStyle(lineWidth: radius - innerRingR - 1.5, lineCap: .butt)
                )

                let rMin: CGFloat = innerRingR - 0.6
                let rMax: CGFloat = radius - 1.8
                let angSteps = 80
                let radSteps = 5
                let angStep = (angles.endAngle - angles.startAngle) / Double(angSteps)
                let radStep = (rMax - rMin) / CGFloat(radSteps)
                var stippleHalo = Path()

                for ia in 0..<angSteps {
                    let f = (Double(ia) + 0.5) / Double(angSteps)
                    if f > remainingFraction + 0.004 { break }
                    let baseAng = angles.startAngle + (Double(ia) + 0.5) * angStep
                    for ir in 0..<radSteps {
                        let h = Self.stippleHash(ia, ir, dialSeed)
                        let ja = (Double(h & 0xFF) / 255.0 - 0.5) * angStep * 0.90
                        let jr = (Double((h >> 8) & 0xFF) / 255.0 - 0.5) * Double(radStep) * 0.88
                        let ang = baseAng + ja
                        guard ang >= angles.startAngle + 0.004,
                              ang <= angles.remainingEndAngle - 0.004 else { continue }
                        let r = rMin + (CGFloat(ir) + 0.5) * radStep + CGFloat(jr)
                        guard r >= rMin, r <= rMax else { continue }

                        let radNorm = Double(max(0, min(1, (r - rMin) / max(1, rMax - rMin))))
                        let prob = 0.14 + 0.72 * pow(radNorm, 1.35)
                        let roll = Double((h >> 16) & 0x3FF) / 1023.0
                        if roll < prob {
                            let dotSize: CGFloat = ((h >> 26) & 3 == 0) ? 1.15 : 0.95
                            let px = cx + CGFloat(cos(ang)) * r
                            let py = cy + CGFloat(sin(ang)) * r
                            stippleHalo.addRect(CGRect(
                                x: px - dotSize * 0.5,
                                y: py - dotSize * 0.5,
                                width: dotSize,
                                height: dotSize
                            ))
                        }
                    }
                }

                if !stippleHalo.isEmpty {
                    let haloInk = statusColor.opacity(theme.isDark ? 0.44 : 0.36)
                    context.fill(stippleHalo, with: .color(haloInk))
                }
            }

            // 3. 60-tick razor vernier outer protractor (3 graduated lengths, batched into 4 Paths)
            let tickCount = 60
            var litMinorTicks = Path()
            var dimMinorTicks = Path()
            var litMajorTicks = Path()
            var dimMajorTicks = Path()

            for i in 0...tickCount {
                let f = Double(i) / Double(tickCount)
                let ang = InstrumentMath.orbitalAngleRad(fraction: f)
                let ca = CGFloat(cos(ang))
                let sa = CGFloat(sin(ang))
                let isMajor = (i % 15 == 0)
                let isMedium = (!isMajor && i % 5 == 0)
                let r1 = isMajor ? majorOuterR : (isMedium ? mediumOuterR : minorOuterR)
                let p0 = CGPoint(x: cx + ca * tickInnerR, y: cy + sa * tickInnerR)
                let p1 = CGPoint(x: cx + ca * r1, y: cy + sa * r1)
                let isLit = f <= remainingFraction + 0.001

                if isMajor {
                    if isLit {
                        litMajorTicks.move(to: p0); litMajorTicks.addLine(to: p1)
                    } else {
                        dimMajorTicks.move(to: p0); dimMajorTicks.addLine(to: p1)
                    }
                } else {
                    if isLit {
                        litMinorTicks.move(to: p0); litMinorTicks.addLine(to: p1)
                    } else {
                        dimMinorTicks.move(to: p0); dimMinorTicks.addLine(to: p1)
                    }
                }
            }

            let litTickColor = theme.inkPrimary.opacity(0.80)
            let dimTickColor = theme.hairlineStrong.opacity(0.45)

            if !dimMinorTicks.isEmpty {
                context.stroke(dimMinorTicks, with: .color(dimTickColor), lineWidth: 0.65)
            }
            if !litMinorTicks.isEmpty {
                context.stroke(litMinorTicks, with: .color(litTickColor), lineWidth: 0.65)
            }
            if !dimMajorTicks.isEmpty {
                context.stroke(dimMajorTicks, with: .color(dimTickColor), lineWidth: 1.0)
            }
            if !litMajorTicks.isEmpty {
                context.stroke(litMajorTicks, with: .color(litTickColor), lineWidth: 1.0)
            }

            // 4. Calibrated micro scale numerals (0, 50, 100) outside cardinal protractor points
            let scaleFont = Font.system(size: 6.5, weight: .regular, design: .monospaced)
            let scaleInk = theme.inkMuted.opacity(0.90)

            let startAng = InstrumentMath.orbitalAngleRad(fraction: 0.0)
            let endAng = InstrumentMath.orbitalAngleRad(fraction: 1.0)
            let cardinalR: CGFloat = 61.8

            context.draw(
                Text("0").font(scaleFont).foregroundColor(scaleInk),
                at: CGPoint(
                    x: cx + CGFloat(cos(startAng)) * cardinalR,
                    y: cy + CGFloat(sin(startAng)) * cardinalR + 0.5
                ),
                anchor: .trailing
            )
            context.draw(
                Text("50").font(scaleFont).foregroundColor(scaleInk),
                at: CGPoint(x: cx, y: cy - 61.5),
                anchor: .bottom
            )
            context.draw(
                Text("100").font(scaleFont).foregroundColor(scaleInk),
                at: CGPoint(
                    x: cx + CGFloat(cos(endAng)) * cardinalR,
                    y: cy + CGFloat(sin(endAng)) * cardinalR + 0.5
                ),
                anchor: .leading
            )

            // 5. Recessed hairline track arc (2.8pt)
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
                with: .color(theme.hairlineStrong.opacity(theme.isDark ? 0.30 : 0.26)),
                style: StrokeStyle(lineWidth: 2.8, lineCap: .butt)
            )

            // 6. Refined diagonal-hatched over-pace deficit sector
            if let pAng = angles.paceAngle, pAng > angles.remainingEndAngle + 0.02 {
                let deficitColor = angles.isDeficit ? theme.signalAmber : theme.inkMuted
                let span = pAng - angles.remainingEndAngle
                let hatchR0 = radius - 3.2
                let hatchR1 = radius + 3.2

                var tintArc = Path()
                tintArc.addArc(
                    center: center,
                    radius: radius,
                    startAngle: .radians(angles.remainingEndAngle),
                    endAngle: .radians(pAng),
                    clockwise: false
                )
                context.stroke(
                    tintArc,
                    with: .color(deficitColor.opacity(theme.isDark ? 0.13 : 0.10)),
                    style: StrokeStyle(lineWidth: 6.4, lineCap: .butt)
                )

                // Batched diagonal hatch strokes strictly clamped to the deficit sector
                let hatchStep = 0.065
                let count = max(2, Int(ceil(span / hatchStep)))
                var hatchPath = Path()
                for h in 0...count {
                    let a0 = angles.remainingEndAngle + (Double(h) / Double(count)) * span
                    let a1 = min(pAng, a0 + 0.052)
                    hatchPath.move(to: CGPoint(
                        x: cx + CGFloat(cos(a0)) * hatchR0,
                        y: cy + CGFloat(sin(a0)) * hatchR0
                    ))
                    hatchPath.addLine(to: CGPoint(
                        x: cx + CGFloat(cos(a1)) * hatchR1,
                        y: cy + CGFloat(sin(a1)) * hatchR1
                    ))
                }
                context.stroke(hatchPath, with: .color(deficitColor.opacity(0.70)), lineWidth: 0.72)

                // Razor containment arcs + closing radial caps framing the hatched sector
                var boundsPath = Path()
                boundsPath.addArc(
                    center: center,
                    radius: hatchR1,
                    startAngle: .radians(angles.remainingEndAngle),
                    endAngle: .radians(pAng),
                    clockwise: false
                )
                boundsPath.addLine(to: CGPoint(
                    x: cx + CGFloat(cos(pAng)) * hatchR0,
                    y: cy + CGFloat(sin(pAng)) * hatchR0
                ))
                boundsPath.addArc(
                    center: center,
                    radius: hatchR0,
                    startAngle: .radians(pAng),
                    endAngle: .radians(angles.remainingEndAngle),
                    clockwise: true
                )
                boundsPath.closeSubpath()
                context.stroke(boundsPath, with: .color(deficitColor.opacity(0.42)), lineWidth: 0.55)
            }

            // 7. Sleek 2.8pt precision remaining arc (+ delicate dark-mode optical bloom & frontier tick)
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
                        with: .color(statusColor.opacity(0.14)),
                        style: StrokeStyle(lineWidth: 7.6, lineCap: .butt)
                    )
                    context.stroke(
                        remArc,
                        with: .color(statusColor.opacity(0.28)),
                        style: StrokeStyle(lineWidth: 4.5, lineCap: .butt)
                    )
                }
                context.stroke(
                    remArc,
                    with: .color(statusColor),
                    style: StrokeStyle(lineWidth: 2.8, lineCap: .butt)
                )

                // Knife-edge radial frontier index tick terminating the remaining arc
                let fa = angles.remainingEndAngle
                let fca = CGFloat(cos(fa))
                let fsa = CGFloat(sin(fa))
                var frontier = Path()
                frontier.move(to: CGPoint(x: cx + fca * (radius - 3.6), y: cy + fsa * (radius - 3.6)))
                frontier.addLine(to: CGPoint(x: cx + fca * (radius + 3.6), y: cy + fsa * (radius + 3.6)))
                context.stroke(frontier, with: .color(statusColor), lineWidth: 0.9)
            }

            // 8. Inner hairline elapsed ring (0.8pt dashed) + radial PACE vector ray & Fred reticle
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
                with: .color(theme.hairline.opacity(0.9)),
                style: StrokeStyle(lineWidth: 0.8, dash: [2, 2.5])
            )

            if let pAng = angles.paceAngle {
                let paceColor = angles.isDeficit ? theme.signalAmber : theme.inkSecondary

                var elapsedArc = Path()
                elapsedArc.addArc(
                    center: center,
                    radius: innerRingR,
                    startAngle: .radians(angles.startAngle),
                    endAngle: .radians(pAng),
                    clockwise: false
                )
                context.stroke(elapsedArc, with: .color(paceColor.opacity(0.75)), lineWidth: 0.95)

                // Radial PACE vector ray + tangential arc intersection tick
                let rStart = innerRingR - 2.5
                let rTip = majorOuterR + 1.2
                let ca = CGFloat(cos(pAng))
                let sa = CGFloat(sin(pAng))
                let tx = -sa
                let ty = ca

                var ray = Path()
                ray.move(to: CGPoint(x: cx + ca * rStart, y: cy + sa * rStart))
                ray.addLine(to: CGPoint(x: cx + ca * (rTip - 2.8), y: cy + sa * (rTip - 2.8)))
                let arcCrossX = cx + ca * radius
                let arcCrossY = cy + sa * radius
                ray.move(to: CGPoint(x: arcCrossX - tx * 2.2, y: arcCrossY - ty * 2.2))
                ray.addLine(to: CGPoint(x: arcCrossX + tx * 2.2, y: arcCrossY + ty * 2.2))
                context.stroke(ray, with: .color(paceColor), lineWidth: 0.95)

                // Crisp Fred-style 4-corner coordinate reticle + centered pip on the PACE ray tip
                let tipX = cx + ca * rTip
                let tipY = cy + sa * rTip
                let retR: CGFloat = 3.2
                let cLen: CGFloat = 1.5
                let minX = tipX - retR, maxX = tipX + retR
                let minY = tipY - retR, maxY = tipY + retR
                var reticle = Path()
                reticle.move(to: CGPoint(x: minX, y: minY + cLen))
                reticle.addLine(to: CGPoint(x: minX, y: minY))
                reticle.addLine(to: CGPoint(x: minX + cLen, y: minY))
                reticle.move(to: CGPoint(x: maxX - cLen, y: minY))
                reticle.addLine(to: CGPoint(x: maxX, y: minY))
                reticle.addLine(to: CGPoint(x: maxX, y: minY + cLen))
                reticle.move(to: CGPoint(x: minX, y: maxY - cLen))
                reticle.addLine(to: CGPoint(x: minX, y: maxY))
                reticle.addLine(to: CGPoint(x: minX + cLen, y: maxY))
                reticle.move(to: CGPoint(x: maxX - cLen, y: maxY))
                reticle.addLine(to: CGPoint(x: maxX, y: maxY))
                reticle.addLine(to: CGPoint(x: maxX, y: maxY - cLen))
                context.stroke(reticle, with: .color(paceColor.opacity(0.92)), lineWidth: 0.75)

                context.fill(
                    Path(CGRect(x: tipX - 1.2, y: tipY - 1.2, width: 2.4, height: 2.4)),
                    with: .color(paceColor)
                )
            }
        }
    }

    private static func stippleHash(_ a: Int, _ b: Int, _ salt: Int) -> UInt32 {
        var h = UInt32(truncatingIfNeeded: a &* 374761393 &+ b &* 668265263 ^ salt &* 83492791)
        h = (h ^ (h >> 13)) &* 1274126177
        return h ^ (h >> 16)
    }
}

// MARK: - Batched 48-Line Swiss Caliper Vernier Bar (Hairline Ticks + Consumed Stipple + Pace Plumb)

private struct DraftingVernierBar: View {
    let fraction: CGFloat
    let litColor: Color
    var paceMarkerFraction: CGFloat? = nil
    var paceMarkerColor: Color
    var isOverPace: Bool = false
    var ticks: Int = 48
    var barSeed: Int = 1

    @Environment(\.agyTheme) private var theme

    var body: some View {
        DraftingVernierCanvas(
            fraction: fraction,
            litColor: litColor,
            paceMarkerFraction: paceMarkerFraction,
            paceMarkerColor: paceMarkerColor,
            isOverPace: isOverPace,
            ticks: ticks,
            barSeed: barSeed,
            theme: theme
        )
        .equatable()
        .frame(height: 18)
    }
}

private struct DraftingVernierCanvas: View, Equatable {
    let fraction: CGFloat
    let litColor: Color
    let paceMarkerFraction: CGFloat?
    let paceMarkerColor: Color
    let isOverPace: Bool
    let ticks: Int
    let barSeed: Int
    let theme: AGYTheme

    var body: some View {
        let clamped = max(0, min(1, fraction))
        Canvas { context, size in
            let topPad: CGFloat = 5.0
            let barBottom = size.height - 0.6
            let usableH = max(4, barBottom - topPad)
            let count = max(2, ticks)
            let tickW: CGFloat = 0.9
            let usableW = max(1, size.width - tickW)

            // 1. Subtle deterministic stippled shadow across the consumed / over-pace deficit region
            let splitX = clamped * size.width
            if splitX < size.width - 1.5 {
                let deficitEndX: CGFloat? = {
                    guard let pace = paceMarkerFraction, pace > clamped + 0.01 else { return nil }
                    return min(size.width, pace * size.width)
                }()
                let stepX: CGFloat = 2.5
                let stepY: CGFloat = 2.2
                let startCol = max(0, Int(floor(splitX / stepX)))
                let endCol = Int(ceil(size.width / stepX))
                let rows = max(1, Int((usableH - 1.5) / stepY))

                var consumedStipple = Path()
                var deficitStipple = Path()

                for ix in startCol...endCol {
                    let baseX = CGFloat(ix) * stepX
                    for iy in 0...rows {
                        let baseY = topPad + 1.0 + CGFloat(iy) * stepY
                        let h = Self.vernierHash(ix, iy, barSeed)
                        let jx = (CGFloat(h & 0xFF) / 255.0 - 0.5) * 1.9
                        let jy = (CGFloat((h >> 8) & 0xFF) / 255.0 - 0.5) * 1.7
                        let px = baseX + jx
                        let py = baseY + jy
                        guard px >= splitX + 0.5, px <= size.width - 0.5,
                              py >= topPad + 0.8, py <= barBottom - 0.8 else { continue }

                        let inDeficit = deficitEndX.map { px <= $0 } ?? false
                        let threshold: UInt32 = inDeficit ? 560 : 340
                        let roll = (h >> 16) & 0x3FF
                        if roll < threshold {
                            let dotRect = CGRect(x: px - 0.45, y: py - 0.45, width: 0.9, height: 0.9)
                            if inDeficit {
                                deficitStipple.addRect(dotRect)
                            } else {
                                consumedStipple.addRect(dotRect)
                            }
                        }
                    }
                }

                if !consumedStipple.isEmpty {
                    context.fill(
                        consumedStipple,
                        with: .color(theme.inkMuted.opacity(theme.isDark ? 0.30 : 0.24))
                    )
                }
                if !deficitStipple.isEmpty {
                    let defColor = isOverPace ? paceMarkerColor : theme.inkSecondary
                    context.fill(
                        deficitStipple,
                        with: .color(defColor.opacity(theme.isDark ? 0.44 : 0.34))
                    )
                }
            }

            // 2. Razor-fine 48-line graduated Swiss caliper ticks (0.9px hairlines, batched into 2 Paths)
            var litPath = Path()
            var dimPath = Path()

            for i in 0..<count {
                let tickFrac = CGFloat(i) / CGFloat(count - 1)
                let isMajor = (i == 0 || i == count - 1 || i % 12 == 0)
                let isMedium = (!isMajor && i % 4 == 0)
                let heightRatio: CGFloat = isMajor ? 1.0 : (isMedium ? 0.68 : 0.42)
                let tickH = usableH * heightRatio
                let y = barBottom - tickH
                let x = tickFrac * usableW
                let rect = CGRect(x: x, y: y, width: tickW, height: tickH)
                if clamped > 0 && tickFrac <= clamped + 0.002 {
                    litPath.addRect(rect)
                } else {
                    dimPath.addRect(rect)
                }
            }

            if !dimPath.isEmpty {
                context.fill(dimPath, with: .color(theme.hairlineStrong.opacity(theme.isDark ? 0.42 : 0.36)))
            }
            if !litPath.isEmpty {
                context.fill(litPath, with: .color(litColor))
            }

            // 3. Hairline caliper datum baseline
            context.fill(
                Path(CGRect(x: 0, y: barBottom, width: size.width, height: 0.6)),
                with: .color(theme.hairlineStrong.opacity(theme.isDark ? 0.50 : 0.45))
            )

            // 4. Crisp 1.1px ▼ calibrated pace plumb line
            if let pace = paceMarkerFraction {
                let pClamped = max(0.015, min(0.985, pace))
                let px = size.width * pClamped

                var marker = Path()
                marker.move(to: CGPoint(x: px - 2.7, y: 0))
                marker.addLine(to: CGPoint(x: px + 2.7, y: 0))
                marker.addLine(to: CGPoint(x: px, y: 3.4))
                marker.closeSubpath()
                marker.addRect(CGRect(x: px - 0.55, y: 3.1, width: 1.1, height: barBottom - 2.5))
                context.fill(marker, with: .color(paceMarkerColor))
            }
        }
    }

    private static func vernierHash(_ x: Int, _ y: Int, _ salt: Int) -> UInt32 {
        var h = UInt32(truncatingIfNeeded: x &* 374761393 &+ y &* 668265263 ^ salt &* 19349663)
        h = (h ^ (h >> 13)) &* 1274126177
        return h ^ (h >> 16)
    }
}

// MARK: - Helpers

private func stripLeadingIndexPrefix(_ raw: String) -> String {
    if let range = raw.range(of: " // "),
       raw.distance(from: raw.startIndex, to: range.lowerBound) <= 4 {
        return String(raw[range.upperBound...])
    }
    return raw
}

private func formatSignedPaceDelta(_ delta: Int) -> String {
    if delta > 0 { return "+\(delta)%" }
    if delta < 0 { return "−\(abs(delta))%" }
    return "0%"
}
