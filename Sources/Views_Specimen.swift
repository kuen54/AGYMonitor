import SwiftUI

// MARK: - Archival Specimen Card Snapshot & View (ImageRenderer-Safe: ZERO SwiftUI Buttons)

struct SpecimenModelEntry: Equatable {
    let code: String
    let name: String
    let share: Double
    let modelClass: ModelClass
}

/// Immutable value snapshot rendered identically in both the live floating preview
/// and the @2x ImageRenderer PNG export.
struct SpecimenCardSnapshot: Equatable {
    let year: Int
    let month: Int
    let periodLabel: String
    let generatedDateKey: String
    let themePreset: TelemetryThemePreset
    let isDark: Bool
    let language: AppLanguage

    let totalTokens: Int
    let totalCost: Double
    let activeHours: Double
    let activeDays: Int
    let longestStreakDays: Int
    let archetype: OperatorArchetype

    let polarArcs: [PolarArc]
    let weekDayKeys: [String]
    let todayKey: String

    let yearContourField: ContourFieldResult
    let yearMonthlyHours: [Double]
    let yearLabel: Int
    let topModels: [SpecimenModelEntry]

    @MainActor
    static func from(store: UsageStore, isDark: Bool) -> SpecimenCardSnapshot {
        let now = Date()
        let todayKey = AppDate.dayKey(now)
        let year = store.viewingYear
        let month = store.viewingMonth
        let monthPrefix = String(format: "%04d-%02d-", year, month)

        let activePeriod: PeriodUsage? = store.month ?? store.currentMonthData ?? store.week ?? store.today
        let totalTokens = activePeriod?.totalTokens ?? 0
        let totalCost = activePeriod?.cost ?? 0.0

        let models = activePeriod?.models ?? []
        let totalInputTokens = models.reduce(0) { $0 + max(0, $1.inputTokens) }
        let totalCacheReadTokens = models.reduce(0) { $0 + max(0, $1.cacheRead) }

        let topModels: [SpecimenModelEntry] = {
            let positive = models.filter { $0.totalTokens > 0 }.sorted { $0.totalTokens > $1.totalTokens }
            let sum = Double(max(1, positive.reduce(0) { $0 + $1.totalTokens }))
            return positive.prefix(4).map { m in
                let mc = ModelClass(rawValue: m.id.lowercased()) ?? ModelClass.classify(m.id)
                return SpecimenModelEntry(
                    code: mc.shortCode,
                    name: m.name,
                    share: Double(m.totalTokens) / sum,
                    modelClass: mc
                )
            }
        }()

        let timeData = store.viewingTimeData ?? store.currentTimeData
        let monthDaysMap = timeData?.days ?? [:]
        let monthTimeKeys = monthDaysMap.keys.filter { $0.hasPrefix(monthPrefix) }
        let monthSeconds = TimeLogic.totalSeconds(in: monthDaysMap, dayKeys: monthTimeKeys)

        let yearLabel = year
        let yearPrefix = String(format: "%04d-", yearLabel)
        let yearDays: [String: Int] = {
            if store.viewingTimeYear == yearLabel,
               let yd = store.yearTimeDays,
               !yd.isEmpty {
                return yd
            }
            var fallback: [String: Int] = [:]
            for (k, d) in monthDaysMap where k.hasPrefix(yearPrefix) && d.totalSeconds > 0 {
                fallback[k] = d.totalSeconds
            }
            return fallback
        }()

        let yearSeconds = yearDays.reduce(0) { acc, pair in
            pair.key.hasPrefix(yearPrefix) ? acc + max(0, pair.value) : acc
        }
        let yearActiveDays = yearDays.reduce(0) { acc, pair in
            (pair.key.hasPrefix(yearPrefix) && pair.value > 0) ? acc + 1 : acc
        }
        let monthActiveDays = monthTimeKeys.reduce(0) { acc, key in
            (monthDaysMap[key]?.totalSeconds ?? 0) > 0 ? acc + 1 : acc
        }

        let displayActiveHours = monthSeconds > 0
            ? Double(monthSeconds) / 3600.0
            : Double(yearSeconds) / 3600.0
        let displayActiveDays = monthActiveDays > 0 ? monthActiveDays : yearActiveDays
        let yearSummary = TimeLogic.yearSummary(days: yearDays, year: yearLabel)
        let streak = yearSummary.longestStreakDays

        let diurnalProfile = InstrumentMath.buildMonthDiurnalProfile(
            days: monthDaysMap,
            year: year,
            month: month,
            binCount: 48,
            peakWindowBins: 4
        )
        let archetype = SpecimenLogic.classifyArchetype(
            diurnalProfile: diurnalProfile,
            activeHours: displayActiveHours,
            totalInputTokens: totalInputTokens,
            totalCacheReadTokens: totalCacheReadTokens
        )

        let weekDayKeys = store.resolvedWeekMonday.map(TimeLogic.weekDayKeys) ?? []
        let polarArcs = InstrumentMath.buildPolarWeekArcs(
            dayKeys: weekDayKeys,
            days: monthDaysMap,
            monthPrefix: monthPrefix,
            minAngularSeconds: 420
        )

        let currentYear = AppDate.gregorian.component(.year, from: now)
        let cutoffKey: String? = (yearLabel == currentYear) ? todayKey : nil
        let contourField = YearContourFieldCache.field(
            days: yearDays,
            year: yearLabel,
            totalSeconds: yearSummary.totalSeconds,
            cutoffDayKey: cutoffKey
        )
        let monthlyHours = InstrumentMath.yearMonthlyHours(days: yearDays, year: yearLabel)

        return SpecimenCardSnapshot(
            year: year,
            month: month,
            periodLabel: String(format: "%04d.%02d", year, month),
            generatedDateKey: todayKey,
            themePreset: store.themePreset,
            isDark: isDark,
            language: store.language,
            totalTokens: totalTokens,
            totalCost: totalCost,
            activeHours: displayActiveHours,
            activeDays: displayActiveDays,
            longestStreakDays: streak,
            archetype: archetype,
            polarArcs: polarArcs,
            weekDayKeys: weekDayKeys,
            todayKey: todayKey,
            yearContourField: contourField,
            yearMonthlyHours: monthlyHours,
            yearLabel: yearLabel,
            topModels: topModels
        )
    }
}

// MARK: - Archetype Localization Helper

extension OperatorArchetypeKind {
    func localizedTitle(_ loc: Localizer) -> String {
        switch self {
        case .nocturnalArchitect: return loc("archetypeNocturnalArchitect")
        case .dawnSynthesizer:    return loc("archetypeDawnSynthesizer")
        case .daylightCraftsman:  return loc("archetypeDaylightCraftsman")
        case .marathonOperator:   return loc("archetypeMarathonOperator")
        case .steadyPilot:        return loc("archetypeSteadyPilot")
        }
    }
}

// MARK: - Specimen Aspect Geometry

extension SpecimenAspect {
    /// Logical point dimensions rendered at @2x (scale = 2.0):
    /// - 4:5 Portrait: 600 × 750 pt -> 1200 × 1500 px
    /// - 16:9 Wide:    800 × 450 pt -> 1600 × 900 px
    var logicalSize: CGSize {
        switch self {
        case .portrait4x5:   return CGSize(width: 600, height: 750)
        case .landscape16x9: return CGSize(width: 800, height: 450)
        }
    }

    var exportPixelLabel: String {
        switch self {
        case .portrait4x5:   return "1200 × 1500 PX · @2X PNG"
        case .landscape16x9: return "1600 × 900 PX · @2X PNG"
        }
    }

    func label(_ loc: Localizer) -> String {
        switch self {
        case .portrait4x5:   return loc("specimenAspectPortrait")
        case .landscape16x9: return loc("specimenAspectWide")
        }
    }
}

// MARK: - Archival Specimen Card View (Pure Swiss Lithograph — Zero Buttons)

struct ArchivalSpecimenCardView: View {
    let snapshot: SpecimenCardSnapshot
    let aspect: SpecimenAspect

    private var theme: AGYTheme {
        AGYTheme(
            preset: snapshot.themePreset,
            colorScheme: snapshot.isDark ? .dark : .light,
            isNotch: false
        )
    }

    private var loc: Localizer {
        Localizer(language: snapshot.language)
    }

    var body: some View {
        let size = aspect.logicalSize
        ZStack {
            theme.canvas
            ArchivalGrainOverlay()
                .environment(\.agyTheme, theme)

            // Outer Swiss print crop marks (+) & framing border
            SpecimenCropMarksCanvas(theme: theme)

            Group {
                switch aspect {
                case .portrait4x5:
                    portraitBody
                case .landscape16x9:
                    landscapeBody
                }
            }
            .padding(24)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .environment(\.agyTheme, theme)
        .environment(\.localizer, loc)
    }

    // MARK: 4:5 Portrait Composition (600 × 750 @2x = 1200 × 1500)

    private var portraitBody: some View {
        VStack(spacing: 0) {
            masthead(compact: false)

            specimenRule

            kpiStrip(compact: false)

            specimenRule

            // Plate 01: 24H Polar Chronometer
            VStack(alignment: .leading, spacing: 8) {
                plateHeader(index: "01", title: loc("specimenPolarLabel"), rightTag: peakWindowTag)
                SpecimenPolarCanvas(
                    arcs: snapshot.polarArcs,
                    dayKeys: snapshot.weekDayKeys,
                    todayKey: snapshot.todayKey,
                    peakWindowLabel: snapshot.archetype.peakWindowLabel,
                    theme: theme
                )
                .frame(maxWidth: .infinity)
                .frame(height: 256)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            specimenRule

            // Plate 02: Annual Topographic Contour Strip + Monthly Elevation
            VStack(alignment: .leading, spacing: 8) {
                plateHeader(
                    index: "02",
                    title: "\(loc("specimenTopographyLabel")) // \(snapshot.yearLabel)",
                    rightTag: String(format: "%@ %dD", loc("timeStreak").uppercased(), snapshot.longestStreakDays)
                )
                SpecimenContourStripCanvas(
                    field: snapshot.yearContourField,
                    monthlyHours: snapshot.yearMonthlyHours,
                    year: snapshot.yearLabel,
                    theme: theme
                )
                .frame(maxWidth: .infinity)
                .frame(height: 148)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Spacer(minLength: 0)

            specimenRule

            colophonBar(compact: false)
        }
        .background(theme.surfaceRaised.opacity(theme.isDark ? 0.14 : 0.35))
        .overlay(Rectangle().stroke(theme.hairlineStrong, lineWidth: 1))
    }

    // MARK: 16:9 Wide Composition (800 × 450 @2x = 1600 × 900)

    private var landscapeBody: some View {
        VStack(spacing: 0) {
            masthead(compact: true)

            specimenRule

            HStack(spacing: 0) {
                // Left column: 24H Polar Chronometer centerpiece
                VStack(alignment: .leading, spacing: 6) {
                    plateHeader(index: "01", title: loc("specimenPolarLabel"), rightTag: snapshot.archetype.peakWindowLabel)
                    SpecimenPolarCanvas(
                        arcs: snapshot.polarArcs,
                        dayKeys: snapshot.weekDayKeys,
                        todayKey: snapshot.todayKey,
                        peakWindowLabel: snapshot.archetype.peakWindowLabel,
                        theme: theme
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(width: 304)

                Rectangle()
                    .fill(theme.hairline)
                    .frame(width: 1)

                // Right column: KPI Strip + Annual Topographic Contour Strip
                VStack(spacing: 0) {
                    kpiStrip(compact: true)

                    specimenRule

                    VStack(alignment: .leading, spacing: 8) {
                        plateHeader(
                            index: "02",
                            title: "\(loc("specimenTopographyLabel")) // \(snapshot.yearLabel)",
                            rightTag: String(format: "%@ %dD", loc("timeStreak").uppercased(), snapshot.longestStreakDays)
                        )
                        SpecimenContourStripCanvas(
                            field: snapshot.yearContourField,
                            monthlyHours: snapshot.yearMonthlyHours,
                            year: snapshot.yearLabel,
                            theme: theme
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)

            specimenRule

            colophonBar(compact: true)
        }
        .background(theme.surfaceRaised.opacity(theme.isDark ? 0.14 : 0.35))
        .overlay(Rectangle().stroke(theme.hairlineStrong, lineWidth: 1))
    }

    // MARK: Shared Archival Sub-Blocks

    private var specimenRule: some View {
        Rectangle()
            .fill(theme.hairline)
            .frame(height: 1)
    }

    private var peakWindowTag: String {
        "\(loc("specimenPeakWindow").uppercased()) \(snapshot.archetype.peakWindowLabel)"
    }

    private func masthead(compact: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 9) {
                LogoShape()
                    .fill(theme.accent)
                    .frame(width: compact ? 16 : 19, height: compact ? 16 : 19)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("AGY // TELEMETRY SPECIMEN")
                            .font(.system(size: compact ? 10 : 11, weight: .bold, design: .monospaced))
                            .tracking(1.6)
                            .foregroundColor(theme.inkPrimary)
                        Text(snapshot.periodLabel)
                            .font(.system(size: compact ? 9.5 : 10.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(theme.accent)
                    }
                    Text("\(loc("specimenSubtitle")) · \(snapshot.generatedDateKey)")
                        .font(.system(size: compact ? 7.5 : 8, weight: .regular, design: .monospaced))
                        .tracking(0.9)
                        .foregroundColor(theme.inkMuted)
                }
            }

            Spacer(minLength: 8)

            // Inverted carbon operator archetype stamp
            HStack(spacing: 6) {
                Rectangle()
                    .fill(theme.accent)
                    .frame(width: 4.5, height: 4.5)
                    .rotationEffect(.degrees(45))
                Text(snapshot.archetype.kind.localizedTitle(loc).uppercased())
                    .font(.system(size: compact ? 8.5 : 9.5, weight: .bold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundColor(theme.invertedInk)
            }
            .padding(.horizontal, compact ? 9 : 11)
            .padding(.vertical, compact ? 5 : 6)
            .background(theme.invertedBg)
        }
        .padding(.horizontal, compact ? 16 : 18)
        .padding(.vertical, compact ? 11 : 14)
    }

    private func kpiStrip(compact: Bool) -> some View {
        let tokStr = formatTokensShort(snapshot.totalTokens).uppercased()
        let hrsStr = snapshot.activeHours >= 10
            ? String(format: "%.0fH", snapshot.activeHours)
            : String(format: "%.1fH", snapshot.activeHours)
        let daysStr = "\(snapshot.activeDays)D"
        let cacheSub = snapshot.archetype.cacheHitPercent.map { "\($0)% HIT" } ?? "--"

        return HStack(spacing: 0) {
            kpiCell(
                label: loc("specimenTokensLabel"),
                value: tokStr,
                sub: formatCost(snapshot.totalCost),
                accentValue: false,
                compact: compact
            )
            Rectangle().fill(theme.hairline).frame(width: 1)
            kpiCell(
                label: loc("specimenHoursLabel"),
                value: hrsStr,
                sub: snapshot.archetype.peakWindowLabel,
                accentValue: false,
                compact: compact
            )
            Rectangle().fill(theme.hairline).frame(width: 1)
            kpiCell(
                label: loc("specimenDaysLabel"),
                value: daysStr,
                sub: "\(snapshot.longestStreakDays)D MAX",
                accentValue: false,
                compact: compact
            )
            Rectangle().fill(theme.hairline).frame(width: 1)
            kpiCell(
                label: loc("specimenCacheLabel"),
                value: snapshot.archetype.cacheGrade,
                sub: cacheSub,
                accentValue: true,
                compact: compact
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func kpiCell(
        label: String,
        value: String,
        sub: String,
        accentValue: Bool,
        compact: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 3) {
            Text(label.uppercased())
                .font(.system(size: compact ? 7.2 : 7.8, weight: .medium, design: .monospaced))
                .tracking(0.9)
                .foregroundColor(theme.inkMuted)
                .lineLimit(1)
            Text(value)
                .font(.system(size: compact ? 22 : 27, weight: .ultraLight, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(accentValue ? theme.accent : theme.inkPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(sub.uppercased())
                .font(.system(size: compact ? 7.2 : 7.8, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(theme.inkSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, compact ? 12 : 16)
        .padding(.vertical, compact ? 9 : 12)
    }

    private func plateHeader(index: String, title: String, rightTag: String) -> some View {
        HStack(spacing: 6) {
            Text(index)
                .font(.system(size: 8.2, weight: .bold, design: .monospaced))
                .foregroundColor(theme.accent)
                .lineLimit(1)
                .fixedSize()
            Text(title.uppercased())
                .font(.system(size: 8.2, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundColor(theme.inkSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 6)
            Text(rightTag.uppercased())
                .font(.system(size: 7.8, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(theme.inkMuted)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private func colophonBar(compact: Bool) -> some View {
        HStack(spacing: 8) {
            if !snapshot.topModels.isEmpty {
                HStack(spacing: 7) {
                    Text(loc("specimenModelMixLabel").uppercased())
                        .font(.system(size: 7.4, weight: .semibold, design: .monospaced))
                        .tracking(0.7)
                        .foregroundColor(theme.inkMuted)
                        .lineLimit(1)
                        .fixedSize()
                    ForEach(Array(snapshot.topModels.prefix(3).enumerated()), id: \.offset) { _, entry in
                        HStack(spacing: 3.5) {
                            Rectangle()
                                .fill(theme.modelColor(entry.modelClass))
                                .frame(width: 5.5, height: 5.5)
                            Text("\(entry.code) \(Int((entry.share * 100.0).rounded()))%")
                                .font(.system(size: 7.8, weight: .medium, design: .monospaced))
                                .monospacedDigit()
                                .foregroundColor(theme.inkSecondary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                }
            }

            Spacer(minLength: 6)

            Text("\(snapshot.themePreset.rawValue.uppercased()) · AGYMONITOR")
                .font(.system(size: 7.6, weight: .medium, design: .monospaced))
                .tracking(0.8)
                .foregroundColor(theme.inkMuted)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, compact ? 16 : 18)
        .padding(.vertical, compact ? 9 : 11)
    }
}

// MARK: - Swiss Print Crop Marks Canvas (+)

private struct SpecimenCropMarksCanvas: View {
    let theme: AGYTheme

    var body: some View {
        Canvas { context, size in
            let inset: CGFloat = 12.0
            let arm: CGFloat = 5.5
            let points = [
                CGPoint(x: inset, y: inset),
                CGPoint(x: size.width - inset, y: inset),
                CGPoint(x: inset, y: size.height - inset),
                CGPoint(x: size.width - inset, y: size.height - inset),
            ]
            var marks = Path()
            for pt in points {
                marks.move(to: CGPoint(x: pt.x - arm, y: pt.y))
                marks.addLine(to: CGPoint(x: pt.x + arm, y: pt.y))
                marks.move(to: CGPoint(x: pt.x, y: pt.y - arm))
                marks.addLine(to: CGPoint(x: pt.x, y: pt.y + arm))
            }
            context.stroke(marks, with: .color(theme.reticle.opacity(0.85)), lineWidth: 0.9)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Specimen Polar Chronometer Canvas (Static Archival Plate)

private struct SpecimenPolarCanvas: View {
    let arcs: [PolarArc]
    let dayKeys: [String]
    let todayKey: String
    let peakWindowLabel: String
    let theme: AGYTheme

    var body: some View {
        Canvas { context, size in
            let cx = size.width * 0.5
            let cy = size.height * 0.5
            let center = CGPoint(x: cx, y: cy)
            let fitRadius = min(size.width, size.height) * 0.5
            let outerR = max(44.0, fitRadius - 24.0)
            let ringStep = outerR * 0.088
            let weekendGap = ringStep * 0.42
            let bezelR = outerR + 8.5
            let compassR = bezelR + 4.5
            let sunR = CGFloat(InstrumentMath.polarRingRadius(
                dayIndex: 6,
                outerRadius: Double(outerR),
                ringStep: Double(ringStep),
                weekendGap: Double(weekendGap)
            ))
            let hubR = max(14.0, sunR - ringStep * 0.95)

            // 1. Cardinal & octant spokes
            var cardinal = Path()
            var octant = Path()
            for hour in [0, 6, 12, 18] {
                let ang = InstrumentMath.polarAngle(secondsOfDay: hour * 3600)
                cardinal.move(to: CGPoint(x: cx + CGFloat(cos(ang)) * hubR, y: cy + CGFloat(sin(ang)) * hubR))
                cardinal.addLine(to: CGPoint(x: cx + CGFloat(cos(ang)) * bezelR, y: cy + CGFloat(sin(ang)) * bezelR))
            }
            for hour in [3, 9, 15, 21] {
                let ang = InstrumentMath.polarAngle(secondsOfDay: hour * 3600)
                octant.move(to: CGPoint(x: cx + CGFloat(cos(ang)) * hubR, y: cy + CGFloat(sin(ang)) * hubR))
                octant.addLine(to: CGPoint(x: cx + CGFloat(cos(ang)) * bezelR, y: cy + CGFloat(sin(ang)) * bezelR))
            }
            context.stroke(octant, with: .color(theme.hairline.opacity(0.42)), style: StrokeStyle(lineWidth: 0.55, dash: [2, 3]))
            context.stroke(cardinal, with: .color(theme.hairlineStrong.opacity(0.45)), lineWidth: 0.65)

            // 2. Bezel & chapter rings + 24h ticks
            context.stroke(
                Path(ellipseIn: CGRect(x: cx - compassR, y: cy - compassR, width: compassR * 2, height: compassR * 2)),
                with: .color(theme.hairline.opacity(0.45)),
                lineWidth: 0.5
            )
            context.stroke(
                Path(ellipseIn: CGRect(x: cx - bezelR, y: cy - bezelR, width: bezelR * 2, height: bezelR * 2)),
                with: .color(theme.hairlineStrong.opacity(0.85)),
                lineWidth: 0.85
            )

            var majorTicks = Path()
            var minorTicks = Path()
            for h in 0..<24 {
                let ang = InstrumentMath.polarAngle(secondsOfDay: h * 3600)
                let isMajor = (h % 6 == 0)
                let tIn = bezelR - (isMajor ? 4.2 : 2.0)
                let tOut = bezelR + (isMajor ? 3.2 : 1.2)
                let p0 = CGPoint(x: cx + CGFloat(cos(ang)) * tIn, y: cy + CGFloat(sin(ang)) * tIn)
                let p1 = CGPoint(x: cx + CGFloat(cos(ang)) * tOut, y: cy + CGFloat(sin(ang)) * tOut)
                if isMajor {
                    majorTicks.move(to: p0)
                    majorTicks.addLine(to: p1)
                } else {
                    minorTicks.move(to: p0)
                    minorTicks.addLine(to: p1)
                }
            }
            context.stroke(minorTicks, with: .color(theme.hairlineStrong.opacity(0.65)), lineWidth: 0.55)
            context.stroke(majorTicks, with: .color(theme.inkPrimary.opacity(0.8)), lineWidth: 1.0)

            // 3. Hour numerals (00 / 06 / 12 / 18)
            let labelR = bezelR + 12.0
            for (h, txt) in [(0, "00"), (6, "06"), (12, "12"), (18, "18")] {
                let ang = InstrumentMath.polarAngle(secondsOfDay: h * 3600)
                let pos = CGPoint(x: cx + CGFloat(cos(ang)) * labelR, y: cy + CGFloat(sin(ang)) * labelR)
                context.draw(
                    Text(txt)
                        .font(.system(size: 8.0, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.inkSecondary),
                    at: pos
                )
            }

            // 4. Seven 5+2 concentric rings
            var rings = Path()
            for idx in 0..<7 {
                let r = CGFloat(InstrumentMath.polarRingRadius(
                    dayIndex: idx,
                    outerRadius: Double(outerR),
                    ringStep: Double(ringStep),
                    weekendGap: Double(weekendGap)
                ))
                rings.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            }
            context.stroke(rings, with: .color(theme.hairline.opacity(0.75)), lineWidth: 0.65)

            // 5. Activity arcs
            var weekdayArcs = Path()
            var weekendArcs = Path()
            var highlightArcs = Path()
            let peakArc = arcs.filter { $0.inMonth }.max { $0.interval.durationSeconds < $1.interval.durationSeconds }

            for arc in arcs {
                let r = CGFloat(InstrumentMath.polarRingRadius(
                    dayIndex: arc.dayIndex,
                    outerRadius: Double(outerR),
                    ringStep: Double(ringStep),
                    weekendGap: Double(weekendGap)
                ))
                var target = Path()
                let s = arc.startAngle
                let e = arc.endAngle
                target.move(to: CGPoint(x: cx + CGFloat(cos(s)) * r, y: cy + CGFloat(sin(s)) * r))
                target.addArc(center: center, radius: r, startAngle: .radians(s), endAngle: .radians(e), clockwise: false)

                if arc.dayKey == todayKey || arc == peakArc {
                    highlightArcs.addPath(target)
                } else if arc.dayIndex >= 5 {
                    weekendArcs.addPath(target)
                } else {
                    weekdayArcs.addPath(target)
                }
            }

            if !weekdayArcs.isEmpty {
                context.stroke(
                    weekdayArcs,
                    with: .color(theme.accentSecondary.opacity(theme.isDark ? 0.86 : 0.80)),
                    style: StrokeStyle(lineWidth: 2.8, lineCap: .butt)
                )
            }
            if !weekendArcs.isEmpty {
                context.stroke(
                    weekendArcs,
                    with: .color(theme.inkSecondary.opacity(0.65)),
                    style: StrokeStyle(lineWidth: 2.3, lineCap: .butt)
                )
            }
            if !highlightArcs.isEmpty {
                if theme.isDark {
                    context.stroke(
                        highlightArcs,
                        with: .color(theme.accent.opacity(0.24)),
                        style: StrokeStyle(lineWidth: 6.0, lineCap: .round)
                    )
                }
                context.stroke(
                    highlightArcs,
                    with: .color(theme.accent),
                    style: StrokeStyle(lineWidth: 3.1, lineCap: .butt)
                )
            }

            // 6. Center Horological Hub
            let hubRect = CGRect(x: cx - hubR, y: cy - hubR, width: hubR * 2, height: hubR * 2)
            context.fill(Path(ellipseIn: hubRect), with: .color(theme.canvas.opacity(0.95)))
            context.stroke(Path(ellipseIn: hubRect), with: .color(theme.hairlineStrong), lineWidth: 0.75)

            context.draw(
                Text("24H")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.accent),
                at: CGPoint(x: cx, y: cy - 4.5)
            )
            context.draw(
                Text(peakWindowLabel == "--" ? "MON–SUN" : peakWindowLabel)
                    .font(.system(size: 6.6, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.inkMuted),
                at: CGPoint(x: cx, y: cy + 5.5)
            )
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Specimen Year Topographic Contour + Monthly Elevation Canvas

private struct SpecimenContourStripCanvas: View {
    let field: ContourFieldResult
    let monthlyHours: [Double]
    let year: Int
    let theme: AGYTheme

    var body: some View {
        Canvas { context, size in
            let monthlyStripH: CGFloat = 34.0
            let gapH: CGFloat = 8.0
            let topoH = max(44.0, size.height - monthlyStripH - gapH)
            let topoRect = CGRect(x: 0, y: 0, width: size.width, height: topoH)
            let monthRect = CGRect(x: 0, y: topoH + gapH, width: size.width, height: monthlyStripH)

            // 1. Topographic Plot Box
            context.fill(Path(topoRect), with: .color(theme.surface.opacity(theme.isDark ? 0.40 : 0.45)))

            let monthCols = TimeLogic.monthLabelColumns(year: year).map(\.col)
            var meridians = Path()
            for col in monthCols where col > 0 {
                let mx = topoRect.minX + topoRect.width * CGFloat(col) / 53.0
                meridians.move(to: CGPoint(x: mx, y: topoRect.minY))
                meridians.addLine(to: CGPoint(x: mx, y: topoRect.maxY))
            }
            context.stroke(meridians, with: .color(theme.hairline.opacity(0.65)), lineWidth: 0.6)

            let padY: CGFloat = 8.0
            let innerH = max(20.0, topoRect.height - padY * 2)
            let cutoffX = field.cutoffNormX.map { CGFloat($0) * topoRect.width } ?? topoRect.width

            func pt(_ p: Point2D) -> CGPoint {
                CGPoint(x: CGFloat(p.x) * topoRect.width, y: padY + CGFloat(p.y) * innerH)
            }

            if !field.levels.isEmpty {
                var clipped = context
                clipped.clip(to: Path(CGRect(x: 0, y: 0, width: cutoffX, height: topoH)))

                let totalLevels = field.levels.count
                for lvl in field.levels {
                    guard !lvl.segments.isEmpty else { continue }
                    var path = Path()
                    for seg in lvl.segments {
                        path.move(to: pt(seg.a))
                        path.addLine(to: pt(seg.b))
                    }
                    let norm = totalLevels > 1 ? Double(lvl.level) / Double(totalLevels - 1) : 1.0
                    let isPeak = (lvl.level == totalLevels - 1)
                    if isPeak {
                        if theme.isDark {
                            clipped.stroke(path, with: .color(theme.accent.opacity(0.22)), lineWidth: 3.2)
                        }
                        clipped.stroke(path, with: .color(theme.accent), lineWidth: 1.2)
                    } else if norm >= 0.55 {
                        let t = (norm - 0.55) / 0.45
                        clipped.stroke(path, with: .color(theme.accent.opacity(0.45 + t * 0.35)), lineWidth: 0.85)
                    } else {
                        let t = norm / 0.55
                        clipped.stroke(path, with: .color(theme.accentSecondary.opacity(0.24 + t * 0.52)), lineWidth: 0.65)
                    }
                }

                // Peak markers (H)
                for (idx, peak) in field.peaks.enumerated() {
                    let p = pt(Point2D(x: peak.x, y: peak.y))
                    let r: CGFloat = idx == 0 ? 4.5 : 3.6
                    let circle = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
                    clipped.fill(circle, with: .color(theme.canvas.opacity(0.92)))
                    clipped.stroke(circle, with: .color(theme.accent.opacity(idx == 0 ? 1.0 : 0.78)), lineWidth: 0.85)
                }
            }

            // Future hatch & NOW datum
            if field.cutoffNormX != nil && cutoffX < topoRect.width - 1.0 {
                let futureRect = CGRect(x: cutoffX, y: 0, width: topoRect.width - cutoffX, height: topoH)
                context.fill(Path(futureRect), with: .color(theme.hairline.opacity(0.14)))
                var hatch = Path()
                var hx = futureRect.minX - futureRect.height
                while hx < futureRect.maxX {
                    let x0 = max(futureRect.minX, hx)
                    let y0 = futureRect.maxY - max(0, futureRect.minX - hx)
                    let x1 = min(futureRect.maxX, hx + futureRect.height)
                    let y1 = futureRect.minY + max(0, (hx + futureRect.height) - futureRect.maxX)
                    if x1 > x0 {
                        hatch.move(to: CGPoint(x: x0, y: y0))
                        hatch.addLine(to: CGPoint(x: x1, y: y1))
                    }
                    hx += 6.0
                }
                context.stroke(hatch, with: .color(theme.hairline.opacity(0.45)), lineWidth: 0.55)

                var datum = Path()
                datum.move(to: CGPoint(x: cutoffX, y: 0))
                datum.addLine(to: CGPoint(x: cutoffX, y: topoH))
                context.stroke(datum, with: .color(theme.accentSecondary.opacity(0.85)), style: StrokeStyle(lineWidth: 0.9, dash: [2.5, 2.0]))
            }

            context.stroke(Path(topoRect), with: .color(theme.hairlineStrong.opacity(0.75)), lineWidth: 0.75)

            // 2. 12-Month Micro-Elevation Strip
            let maxMo = max(1.0, monthlyHours.max() ?? 0.0)
            let peakMoIdx = monthlyHours.enumerated().max { $0.element < $1.element }?.offset
            let monthLabels = ["J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D"]
            let barZoneH = max(12.0, monthRect.height - 12.0)
            let cellW = monthRect.width / 12.0

            for m in 0..<12 {
                let hrs = m < monthlyHours.count ? monthlyHours[m] : 0.0
                let x0 = monthRect.minX + CGFloat(m) * cellW
                let isPeak = (m == peakMoIdx && hrs > 0)
                if hrs > 0 {
                    let frac = CGFloat(min(1.0, max(0.08, hrs / maxMo)))
                    let bh = barZoneH * frac
                    let barRect = CGRect(
                        x: x0 + 2.5,
                        y: monthRect.minY + (barZoneH - bh),
                        width: max(2.0, cellW - 5.0),
                        height: bh
                    )
                    context.fill(
                        Path(barRect),
                        with: .color((isPeak ? theme.accent : theme.accentSecondary).opacity(isPeak ? 0.85 : 0.36))
                    )
                    context.fill(
                        Path(CGRect(x: barRect.minX, y: barRect.minY, width: barRect.width, height: 1.5)),
                        with: .color(isPeak ? theme.accent : theme.accentSecondary.opacity(0.85))
                    )
                }
                context.draw(
                    Text(monthLabels[m])
                        .font(.system(size: 7.0, weight: isPeak ? .bold : .regular, design: .monospaced))
                        .foregroundColor(isPeak ? theme.accent : theme.inkMuted),
                    at: CGPoint(x: x0 + cellW * 0.5, y: monthRect.maxY - 4.5)
                )
            }
        }
        .allowsHitTesting(false)
    }
}
