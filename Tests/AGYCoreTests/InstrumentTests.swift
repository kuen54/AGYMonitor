import Foundation
import Testing
@testable import AGYCore

@Suite("Core_Instruments")
struct InstrumentTests {

    @Test("TelemetryVisualMode defaults cleanly and toggles between instrument and classic")
    func visualModeToggle() {
        #expect(TelemetryVisualMode.allCases == [.instrument, .classic])
        #expect(TelemetryVisualMode.instrument.toggled == .classic)
        #expect(TelemetryVisualMode.classic.toggled == .instrument)
    }

    @Test("Topographic ridges stay bounded in [0, 1], preserve exact peak day, and stack layers monotonically")
    func topographicRidges() {
        let empty = InstrumentMath.buildTopographicRidges(dailyValues: [])
        #expect(empty.layers.isEmpty)
        #expect(empty.peakIndex == nil)

        let zeroOnly = InstrumentMath.buildTopographicRidges(dailyValues: [0, 0, 0])
        #expect(zeroOnly.layers.isEmpty)

        let daily: [Double] = [10, 40, 250, 90, 15, 0, 120]
        let ridge = InstrumentMath.buildTopographicRidges(dailyValues: daily, layerCount: 6, samplesPerDay: 4)
        #expect(ridge.peakIndex == 2)
        #expect(abs(ridge.peakValue - 250) < 0.001)
        #expect(ridge.layers.count == 6)
        #expect(ridge.dayAnchors.count == daily.count)
        #expect(abs(ridge.dayAnchors[2].y - 1.0) < 0.0001)

        // All sampled points stay strictly within normalized [0, 1] with zero spline overshoot
        for layer in ridge.layers {
            for pt in layer.points {
                #expect(pt.x >= 0.0 && pt.x <= 1.0)
                #expect(pt.y >= 0.0 && pt.y <= 1.0)
            }
        }
        // Lower contour factors sit underneath or equal to upper contour layers
        let topPts = ridge.layers[0].points
        let bottomPts = ridge.layers[5].points
        #expect(topPts.count == bottomPts.count)
        for idx in topPts.indices {
            #expect(bottomPts[idx].y <= topPts[idx].y + 1e-9)
        }
    }

    @Test("Borehole slices normalize contiguous [0, 1] vertical bounds and enforce minimum slice height")
    func boreholeSlices() {
        #expect(InstrumentMath.buildBoreholeSlices(items: []).isEmpty)

        let items: [(id: String, value: Double)] = [
            ("carbon", 100.0),
            ("argon", 50.0),
            ("flash", 0.5),
            ("zero", 0.0),
        ]
        let slices = InstrumentMath.buildBoreholeSlices(items: items, minSliceFraction: 0.08)
        #expect(slices.count == 3)
        #expect(abs(slices.first!.yStart - 0.0) < 1e-9)
        #expect(abs(slices.last!.yEnd - 1.0) < 1e-9)

        // Even tiny positive flash row gets at least ~8% visual thickness
        let flash = slices[2]
        #expect(flash.id == "flash")
        #expect((flash.yEnd - flash.yStart) >= 0.08 - 1e-6)
        #expect(abs(slices.reduce(0.0) { $0 + $1.fraction } - 1.0) < 1e-9)
    }

    @Test("Folded Token Flow links all positive model channels within [0, 1] without crossing bounds")
    func tokenFlowLayout() {
        let m1 = ModelUsage(
            id: "carbon", name: "Carbon", cost: 100, messages: 20,
            inputTokens: 1_000_000, outputTokens: 200_000, cacheRead: 8_000_000, cacheWrite: 100_000
        )
        let m2 = ModelUsage(
            id: "flash", name: "Flash", cost: 5, messages: 10,
            inputTokens: 500_000, outputTokens: 50_000, cacheRead: 1_000_000, cacheWrite: 0
        )
        let flow = InstrumentMath.buildTokenFlowLayout(models: [m2, m1])
        #expect(flow.leftNodes.map(\.id) == ["carbon", "flash"])
        #expect(flow.rightNodes.count == 4)
        // carbon has 4 positive channels, flash has 3 -> 7 links
        #expect(flow.links.count == 7)

        for n in flow.leftNodes + flow.rightNodes {
            #expect(n.y0 >= 0.0 && n.y1 <= 1.0 && n.y1 > n.y0)
        }
        for l in flow.links {
            #expect(l.srcY0 >= 0.0 && l.srcY1 <= 1.0 && l.srcY1 > l.srcY0)
            #expect(l.dstY0 >= 0.0 && l.dstY1 <= 1.0 && l.dstY1 > l.dstY0)
        }
    }

    @Test("Density matrix quantizer maps 0 to 0 and positive ratios across 1...5")
    func densityQuantizer() {
        #expect(InstrumentMath.densityLevel(value: 0, maxValue: 100) == 0)
        #expect(InstrumentMath.densityLevel(value: -5, maxValue: 100) == 0)
        #expect(InstrumentMath.densityLevel(value: 1, maxValue: 100) == 1)
        #expect(InstrumentMath.densityLevel(value: 50, maxValue: 100) == 3)
        #expect(InstrumentMath.densityLevel(value: 100, maxValue: 100) == 5)
    }

    @Test("24h Polar Chronometer maps 00h/06h/12h/18h accurately, pads tiny arcs, and hit-tests cleanly")
    func polarChronometerMath() {
        #expect(abs(InstrumentMath.polarAngle(secondsOfDay: 0) - (-Double.pi * 0.5)) < 1e-6)
        #expect(abs(InstrumentMath.polarAngle(secondsOfDay: 21_600) - 0.0) < 1e-6)
        #expect(abs(InstrumentMath.polarAngle(secondsOfDay: 43_200) - (Double.pi * 0.5)) < 1e-6)
        #expect(abs(InstrumentMath.polarAngle(secondsOfDay: 64_800) - Double.pi) < 1e-6)

        let iv1 = ActiveInterval(startSec: 21_600, endSec: 21_660, model: "carbon") // 1 min -> padded
        let dayKey = "2026-11-16"
        let arcs = InstrumentMath.buildPolarWeekArcs(
            dayKeys: [dayKey, "2026-11-17"],
            days: [dayKey: DayTimeUsage(intervals: [iv1], totalSeconds: 60)],
            monthPrefix: "2026-11-"
        )
        #expect(arcs.count == 1)
        #expect(arcs[0].endAngle - arcs[0].startAngle >= (420.0 / 86400.0) * 2.0 * Double.pi - 1e-6)

        // Point right at outer ring (dayIndex = 0, radius = 90) & 06:00 angle (dx = 90, dy = 0)
        let hit = InstrumentMath.hitTestPolarArc(
            dx: 90, dy: 0, outerRadius: 90, ringStep: 10, ringCount: 7, arcs: arcs
        )
        #expect(hit?.dayKey == dayKey)
        // Center miss
        let miss = InstrumentMath.hitTestPolarArc(
            dx: 5, dy: 0, outerRadius: 90, ringStep: 10, ringCount: 7, arcs: arcs
        )
        #expect(miss == nil)
    }

    @Test("Year Marching-Squares field emits closed bounded segments and spaced [H] peaks")
    func yearContourField() {
        let empty = InstrumentMath.buildYearContourField(days: [:], year: 2026)
        #expect(empty.levels.isEmpty)
        #expect(empty.peaks.isEmpty)

        let days: [String: Int] = [
            "2026-03-10": 18_000,
            "2026-03-11": 28_800, // 8h peak
            "2026-03-12": 21_600,
            "2026-09-15": 25_200, // 7h secondary peak far in X
            "2026-09-16": 19_000,
        ]
        let contour = InstrumentMath.buildYearContourField(days: days, year: 2026, levelCount: 5)
        #expect(contour.levels.count == 5)
        #expect(abs(contour.maxHours - 8.0) < 0.001)
        #expect(contour.peaks.count == 2)
        #expect(abs(contour.peaks[0].x - contour.peaks[1].x) >= 0.16)
        let totalSegments = contour.levels.reduce(0) { $0 + $1.segments.count }
        #expect(totalSegments > 10)
        for lvl in contour.levels {
            for seg in lvl.segments {
                #expect(seg.a.x >= 0.0 && seg.a.x <= 1.0 && seg.a.y >= 0.0 && seg.a.y <= 1.0)
                #expect(seg.b.x >= 0.0 && seg.b.x <= 1.0 && seg.b.y >= 0.0 && seg.b.y <= 1.0)
            }
        }
    }

    @Test("Orbital gauge angles sweep 270 deg and flag burn deficits")
    func orbitalGaugeMath() {
        let zero = InstrumentMath.orbitalAngleRad(fraction: 0.0)
        let full = InstrumentMath.orbitalAngleRad(fraction: 1.0)
        #expect(abs((full - zero) - 1.5 * Double.pi) < 1e-6)

        let deficit = InstrumentMath.orbitalGaugeAngles(
            remainingFraction: 0.36,
            paceExpectedRemainingFraction: 0.76,
            isOverPaceWarning: true
        )
        #expect(deficit.isDeficit == true)
        #expect(deficit.paceAngle != nil)

        let safe = InstrumentMath.orbitalGaugeAngles(
            remainingFraction: 0.78,
            paceExpectedRemainingFraction: 0.48,
            isOverPaceWarning: false
        )
        #expect(safe.isDeficit == false)
    }

    @Test("Session radar layout clamps all beacons inside viewport and wires parentSessionId links")
    func sessionRadarLayout() {
        let s1 = SessionInfo(pid: 1, sessionId: "coord", cwd: "/dev/app", status: .busy, entrypoint: "cli")
        let s2 = SessionInfo(
            pid: 2, sessionId: "worker", cwd: "/dev/app", status: .idle,
            entrypoint: "antigravity-ide", isInternal: true, parentSessionId: "coord"
        )
        let s3 = SessionInfo(pid: 3, sessionId: "wait", cwd: "/dev/other", status: .waiting, waitingFor: "permission prompt", entrypoint: "cli")

        let layout = InstrumentMath.buildSessionRadarLayout(
            sessions: [s1, s2, s3],
            labels: ["/dev/app": "App", "/dev/other": "Other"]
        )
        #expect(layout.hubs.count == 2)
        #expect(layout.nodes.count == 3)
        let workerNode = layout.nodes.first { $0.id == "worker" }
        #expect(workerNode?.parentNodePos != nil)
        #expect(workerNode?.surfaceCode == "IDE")
        for node in layout.nodes {
            #expect(node.pos.x >= 0.08 && node.pos.x <= 0.92)
            #expect(node.pos.y >= 0.18 && node.pos.y <= 0.82)
        }
    }

    @Test("Deterministic hit-testing selects exact Borehole stratum, Flow label, Radar node, and Year cell")
    func deterministicHitTesting() {
        // 1. Borehole stratum hit-test: top hits carbon, middle hits hydrogen, bottom hits claude
        let slices = InstrumentMath.buildBoreholeSlices(
            items: [("carbon", 15.2), ("argon", 3.4), ("neon", 4.4), ("hydrogen", 8.0), ("claude", 4.9)],
            minSliceFraction: 0.085
        )
        #expect(InstrumentMath.hitTestBoreholeSlice(normalizedY: 0.02, slices: slices) == "carbon")
        #expect(InstrumentMath.hitTestBoreholeSlice(normalizedY: slices[0].midY, slices: slices) == "carbon")
        #expect(InstrumentMath.hitTestBoreholeSlice(normalizedY: slices[3].midY, slices: slices) == "hydrogen")
        #expect(InstrumentMath.hitTestBoreholeSlice(normalizedY: 0.99, slices: slices) == "claude")
        #expect(InstrumentMath.hitTestBoreholeSlice(normalizedY: -0.1, slices: slices) == nil)
        #expect(InstrumentMath.hitTestBoreholeSlice(normalizedY: 1.2, slices: slices) == nil)

        // 2. Relaxed flow label centers hit-test
        let centers = [14.0, 44.0, 74.0, 104.0]
        let ids = ["carbon", "hydrogen", "claude", "flash"]
        #expect(InstrumentMath.hitTestLabelCenters(y: 12.0, centers: centers, ids: ids) == "carbon")
        #expect(InstrumentMath.hitTestLabelCenters(y: 46.0, centers: centers, ids: ids) == "hydrogen")
        #expect(InstrumentMath.hitTestLabelCenters(y: 105.0, centers: centers, ids: ids) == "flash")
        #expect(InstrumentMath.hitTestLabelCenters(y: 140.0, centers: centers, ids: ids, maxDistance: 10.0) == nil)

        // 3. Radar node nearest hit-test
        let s1 = SessionInfo(pid: 1, sessionId: "a", cwd: "/dev/a", status: .busy, entrypoint: "cli")
        let s2 = SessionInfo(pid: 2, sessionId: "b", cwd: "/dev/b", status: .waiting, entrypoint: "cli")
        let radar = InstrumentMath.buildSessionRadarLayout(sessions: [s1, s2], labels: [:])
        let target = radar.nodes[0]
        let hit = InstrumentMath.hitTestRadarNode(
            x: target.pos.x * 392.0 + 3.0,
            y: target.pos.y * 152.0 - 2.0,
            width: 392.0,
            height: 152.0,
            nodes: radar.nodes,
            maxRadius: 18.0
        )
        #expect(hit?.id == target.id)
        let miss = InstrumentMath.hitTestRadarNode(
            x: 0.0, y: 0.0, width: 392.0, height: 152.0, nodes: radar.nodes, maxRadius: 8.0
        )
        #expect(miss == nil)

        // 4. Year contour cell accounts for padY
        let topCell = InstrumentMath.yearContourCell(x: 200.0, y: 16.0, width: 392.0, height: 184.0, padY: 16.0)
        #expect(topCell?.row == 0)
        let botCell = InstrumentMath.yearContourCell(x: 200.0, y: 167.0, width: 392.0, height: 184.0, padY: 16.0)
        #expect(botCell?.row == 6)
    }

    @Test("polarRingRadius follows linear 5+2 spacing with extra Fri-to-Sat weekend gap")
    func polarRingRadiusFivePlusTwo() {
        let outer = 82.0
        let step = 7.4
        let gap = 3.2

        let radii = (0..<7).map {
            InstrumentMath.polarRingRadius(dayIndex: $0, outerRadius: outer, ringStep: step, weekendGap: gap)
        }

        // Mon..Fri linear progression
        for idx in 0..<5 {
            #expect(abs(radii[idx] - (outer - Double(idx) * step)) < 1e-9)
        }
        for idx in 0..<4 {
            #expect(abs((radii[idx] - radii[idx + 1]) - step) < 1e-9)
        }

        // Fri (4) -> Sat (5) includes extra weekend gap
        #expect(abs((radii[4] - radii[5]) - (step + gap)) < 1e-9)

        // Sat (5) -> Sun (6) returns to linear step
        #expect(abs((radii[5] - radii[6]) - step) < 1e-9)
        #expect(abs(radii[6] - (outer - 6.0 * step - gap)) < 1e-9)

        // Default weekendGap == 0 matches pure linear spacing
        #expect(abs(InstrumentMath.polarRingRadius(dayIndex: 5, outerRadius: outer, ringStep: step) - (outer - 5.0 * step)) < 1e-9)
    }

    @Test("hitTestPolarArc with 5+2 weekendGap hits Mon/Fri/Sat/Sun accurately and rejects weekend gap")
    func hitTestPolarArcWithWeekendGap() {
        let outer = 82.0
        let step = 7.4
        let gap = 3.2
        let weekKeys = [
            "2026-11-16", // Mon (0)
            "2026-11-17", // Tue (1)
            "2026-11-18", // Wed (2)
            "2026-11-19", // Thu (3)
            "2026-11-20", // Fri (4)
            "2026-11-21", // Sat (5)
            "2026-11-22", // Sun (6)
        ]
        // Place a 05:30–06:30 arc (straddling 06:00 -> angle 0, positive +X axis) on every day
        let iv = ActiveInterval(startSec: 19_800, endSec: 23_400, model: "carbon")
        var dayMap: [String: DayTimeUsage] = [:]
        for key in weekKeys {
            dayMap[key] = DayTimeUsage(intervals: [iv], totalSeconds: 3600)
        }
        let arcs = InstrumentMath.buildPolarWeekArcs(
            dayKeys: weekKeys,
            days: dayMap,
            monthPrefix: "2026-11-"
        )

        // Direct hits on Mon (0), Fri (4), Sat (5), Sun (6)
        for targetIdx in [0, 4, 5, 6] {
            let r = InstrumentMath.polarRingRadius(dayIndex: targetIdx, outerRadius: outer, ringStep: step, weekendGap: gap)
            let hit = InstrumentMath.hitTestPolarArc(
                dx: r, dy: 0, outerRadius: outer, ringStep: step, ringCount: 7, weekendGap: gap, arcs: arcs
            )
            #expect(hit?.dayIndex == targetIdx)
            #expect(hit?.dayKey == weekKeys[targetIdx])
        }

        // No dead zone at midpoint between adjacent weekday rings (Mon & Tue)
        let rMon = InstrumentMath.polarRingRadius(dayIndex: 0, outerRadius: outer, ringStep: step, weekendGap: gap)
        let rTue = InstrumentMath.polarRingRadius(dayIndex: 1, outerRadius: outer, ringStep: step, weekendGap: gap)
        let midWeekdayHit = InstrumentMath.hitTestPolarArc(
            dx: (rMon + rTue) * 0.5, dy: 0, outerRadius: outer, ringStep: step, ringCount: 7, weekendGap: gap, arcs: arcs
        )
        #expect(midWeekdayHit != nil)

        // Midpoint inside the Fri->Sat weekend gap (distance 5.3 > 7.4 * 0.55 = 4.07) must be rejected
        let rFri = InstrumentMath.polarRingRadius(dayIndex: 4, outerRadius: outer, ringStep: step, weekendGap: gap)
        let rSat = InstrumentMath.polarRingRadius(dayIndex: 5, outerRadius: outer, ringStep: step, weekendGap: gap)
        let gapMidR = (rFri + rSat) * 0.5
        let gapHit = InstrumentMath.hitTestPolarArc(
            dx: gapMidR, dy: 0, outerRadius: outer, ringStep: step, ringCount: 7, weekendGap: gap, arcs: arcs
        )
        #expect(gapHit == nil)
    }

    @Test("buildYearContourField with cutoffDayKey sets cutoffNormX, excludes future peaks, and eliminates right-edge cliff")
    func yearContourFieldHonestCutoff() throws {
        let year = 2026
        let cutoffKey = "2026-11-18" // Wed in mid-November
        let startMonday = try #require(TimeLogic.yearGridStartMonday(year: year))
        let cutoffPos = try #require(TimeLogic.gridPosition(dayKey: cutoffKey, startMonday: startMonday))
        let expectedNormX = Double(cutoffPos.col + 1) / 53.0

        // Build a steady 6h/day plateau from Jan 1 through cutoffKey, plus a massive future spike
        // in December to verify future dates never leak into peaks or maxHours.
        var days: [String: Int] = [:]
        for col in 0..<53 {
            for row in 0..<7 {
                guard let key = TimeLogic.dayKey(col: col, row: row, startMonday: startMonday),
                      key.hasPrefix("2026-") else { continue }
                if key <= cutoffKey {
                    days[key] = 21_600 // 6.0h steady plateau
                }
            }
        }
        days["2026-12-10"] = 43_200 // 12.0h future day — must be ignored when cutoffKey is set

        let honest = InstrumentMath.buildYearContourField(
            days: days,
            year: year,
            levelCount: 5,
            cutoffDayKey: cutoffKey
        )
        let normX = try #require(honest.cutoffNormX)
        #expect(abs(normX - expectedNormX) < 1e-9)
        #expect(abs(honest.maxHours - 6.0) < 1e-6)
        #expect(!honest.peaks.isEmpty)
        for peak in honest.peaks {
            #expect(peak.dayKey <= cutoffKey)
            #expect(peak.x <= normX)
        }

        // Compare against un-clamped zero-padded future (without the Dec spike) to verify
        // Neumann right-boundary extension eliminates the artificial vertical cliff at cutoffNormX.
        var plateauOnly = days
        plateauOnly.removeValue(forKey: "2026-12-10")
        let zeroPadded = InstrumentMath.buildYearContourField(
            days: plateauOnly,
            year: year,
            levelCount: 5,
            cutoffDayKey: nil
        )
        let honestPlateau = InstrumentMath.buildYearContourField(
            days: plateauOnly,
            year: year,
            levelCount: 5,
            cutoffDayKey: cutoffKey
        )

        func countRightEdgeCliffSegments(_ field: ContourFieldResult, around cutX: Double) -> Int {
            var count = 0
            for lvl in field.levels {
                for seg in lvl.segments {
                    let mx = (seg.a.x + seg.b.x) * 0.5
                    let my = (seg.a.y + seg.b.y) * 0.5
                    let dx = abs(seg.b.x - seg.a.x)
                    let dy = abs(seg.b.y - seg.a.y)
                    if mx >= cutX - 0.05 && mx <= cutX + 0.02 && my >= 0.25 && my <= 0.75 && dy > dx {
                        count += 1
                    }
                }
            }
            return count
        }

        let zeroPaddedCliff = countRightEdgeCliffSegments(zeroPadded, around: expectedNormX)
        let honestCliff = countRightEdgeCliffSegments(honestPlateau, around: expectedNormX)
        #expect(zeroPaddedCliff >= 10)
        #expect(honestCliff == 0)
    }

    @Test("buildYearContourField returns nil cutoffNormX for past years, mismatched cutoff years, and Dec 31")
    func yearContourFieldPastAndCompleteYears() {
        let days2025: [String: Int] = [
            "2025-05-10": 18_000,
            "2025-05-11": 21_600,
        ]
        let pastNil = InstrumentMath.buildYearContourField(days: days2025, year: 2025, levelCount: 5, cutoffDayKey: nil)
        #expect(pastNil.cutoffNormX == nil)
        #expect(!pastNil.levels.isEmpty)

        // Cutoff belongs to 2026 while building 2025 -> ignored
        let mismatched = InstrumentMath.buildYearContourField(days: days2025, year: 2025, levelCount: 5, cutoffDayKey: "2026-11-18")
        #expect(mismatched.cutoffNormX == nil)
        #expect(mismatched == pastNil)

        // Cutoff on Dec 31 of the same year -> complete year, nil cutoffNormX
        let dec31 = InstrumentMath.buildYearContourField(days: days2025, year: 2025, levelCount: 5, cutoffDayKey: "2025-12-31")
        #expect(dec31.cutoffNormX == nil)
    }

    @Test("yearMonthlyHours aggregates 12 calendar months and ignores other years or negative seconds")
    func yearMonthlyHoursAggregation() {
        let days: [String: Int] = [
            "2026-01-02": 3_600,   // Jan +1.0h
            "2026-01-15": 5_400,   // Jan +1.5h -> 2.5h
            "2026-06-20": 10_800,  // Jun 3.0h
            "2026-12-31": 7_200,   // Dec 2.0h
            "2026-03-10": -3_600,  // negative -> ignored
            "2026-03-11": 0,       // zero -> ignored
            "2025-01-10": 36_000,  // other year -> ignored
            "2027-12-01": 14_400,  // other year -> ignored
            "2026-13-01": 3_600,   // invalid month -> ignored
            "2026-bad": 3_600,     // malformed -> ignored
        ]

        let monthly = InstrumentMath.yearMonthlyHours(days: days, year: 2026)
        #expect(monthly.count == 12)
        #expect(abs(monthly[0] - 2.5) < 1e-9)   // Jan
        #expect(abs(monthly[1] - 0.0) < 1e-9)   // Feb
        #expect(abs(monthly[2] - 0.0) < 1e-9)   // Mar
        #expect(abs(monthly[5] - 3.0) < 1e-9)   // Jun
        #expect(abs(monthly[11] - 2.0) < 1e-9)  // Dec
        #expect(abs(monthly.reduce(0.0, +) - 7.5) < 1e-9)
    }

    @Test("buildDayDiurnalBins splits multi-boundary, sub-bin, and clamped intervals accurately")
    func dayDiurnalBinsCalculation() {
        let intervals: [ActiveInterval] = [
            // Spans multiple 30-min boundaries: 09:15 (33_300) .. 11:45 (42_300) = 2.5h
            ActiveInterval(startSec: 33_300, endSec: 42_300, model: "carbon"),
            // Sub-bin interval inside bin 28 (14:00..14:30): 14:05 (50_700) .. 14:20 (51_600) = 0.25h
            ActiveInterval(startSec: 50_700, endSec: 51_600, model: "argon"),
            // Clamped across midnight start: -600 .. 900 -> 0 .. 900 = 0.25h in bin 0
            ActiveInterval(startSec: -600, endSec: 900, model: "flash"),
            // Clamped across midnight end: 85_500 .. 90_000 -> 85_500 .. 86_400 = 0.25h in bin 47
            ActiveInterval(startSec: 85_500, endSec: 90_000, model: "neon"),
            // Invalid / out-of-range / zero-length intervals (all ignored)
            ActiveInterval(startSec: -3_600, endSec: -600, model: nil),
            ActiveInterval(startSec: 86_400, endSec: 90_000, model: nil),
            ActiveInterval(startSec: 3_600, endSec: 3_600, model: nil),
            ActiveInterval(startSec: 7_200, endSec: 3_600, model: nil),
        ]

        let bins = InstrumentMath.buildDayDiurnalBins(intervals: intervals)
        #expect(bins.count == 48)
        for v in bins {
            #expect(v >= 0.0 && v <= 0.5 + 1e-12)
        }

        // Clamped start & end bins
        #expect(abs(bins[0] - 0.25) < 1e-9)
        #expect(abs(bins[47] - 0.25) < 1e-9)

        // Multi-boundary 09:15..11:45 -> bins 18..23
        #expect(abs(bins[17] - 0.0) < 1e-9)
        #expect(abs(bins[18] - 0.25) < 1e-9)
        #expect(abs(bins[19] - 0.50) < 1e-9)
        #expect(abs(bins[20] - 0.50) < 1e-9)
        #expect(abs(bins[21] - 0.50) < 1e-9)
        #expect(abs(bins[22] - 0.50) < 1e-9)
        #expect(abs(bins[23] - 0.25) < 1e-9)
        #expect(abs(bins[24] - 0.0) < 1e-9)

        // Sub-bin 14:05..14:20 -> bin 28
        #expect(abs(bins[27] - 0.0) < 1e-9)
        #expect(abs(bins[28] - 0.25) < 1e-9)
        #expect(abs(bins[29] - 0.0) < 1e-9)

        // Total active hours matches sum of clamped positive durations: 2.5 + 0.25 + 0.25 + 0.25 = 3.25h
        #expect(abs(bins.reduce(0.0, +) - 3.25) < 1e-9)

        // Custom bin count (24 one-hour bins) and zero bin count
        let hourly = InstrumentMath.buildDayDiurnalBins(intervals: [
            ActiveInterval(startSec: 3_600, endSec: 9_000, model: "carbon"), // 01:00..02:30
        ], binCount: 24)
        #expect(hourly.count == 24)
        #expect(abs(hourly[1] - 1.0) < 1e-9)
        #expect(abs(hourly[2] - 0.5) < 1e-9)
        #expect(InstrumentMath.buildDayDiurnalBins(intervals: intervals, binCount: 0).isEmpty)
    }

    @Test("buildMonthDiurnalProfile filters YYYY-MM-, sums across days, finds peak window, breaks ties deterministically, and handles empty months")
    func monthDiurnalProfileAggregation() {
        let days: [String: DayTimeUsage] = [
            // In-month (2026-11): heavy 14:00..16:00 (bins 28..31) + lighter 09:00..11:00 (bins 18..21)
            "2026-11-01": DayTimeUsage(
                intervals: [
                    ActiveInterval(startSec: 32_400, endSec: 39_600, model: "carbon"), // 09:00..11:00 (2h)
                    ActiveInterval(startSec: 50_400, endSec: 57_600, model: "carbon"), // 14:00..16:00 (2h)
                ],
                totalSeconds: 14_400
            ),
            "2026-11-15": DayTimeUsage(
                intervals: [
                    ActiveInterval(startSec: 50_400, endSec: 57_600, model: "hydrogen"), // 14:00..16:00 (2h)
                ],
                totalSeconds: 7_200
            ),
            "2026-11-30": DayTimeUsage(
                intervals: [
                    ActiveInterval(startSec: 52_200, endSec: 55_800, model: "claude"), // 14:30..15:30 (1h)
                ],
                totalSeconds: 3_600
            ),
            // Out-of-month / other-year / malformed keys — MUST be ignored
            "2026-10-31": DayTimeUsage(
                intervals: [ActiveInterval(startSec: 0, endSec: 28_800, model: "carbon")],
                totalSeconds: 28_800
            ),
            "2026-12-01": DayTimeUsage(
                intervals: [ActiveInterval(startSec: 0, endSec: 28_800, model: "carbon")],
                totalSeconds: 28_800
            ),
            "2025-11-15": DayTimeUsage(
                intervals: [ActiveInterval(startSec: 0, endSec: 28_800, model: "carbon")],
                totalSeconds: 28_800
            ),
            "2026-1-15": DayTimeUsage(
                intervals: [ActiveInterval(startSec: 0, endSec: 28_800, model: "carbon")],
                totalSeconds: 28_800
            ),
        ]

        let profile = InstrumentMath.buildMonthDiurnalProfile(days: days, year: 2026, month: 11)
        #expect(profile.bins.count == 48)
        // Out-of-month 00:00..08:00 intervals must not leak into bins 0..15
        for b in 0..<16 {
            #expect(abs(profile.bins[b] - 0.0) < 1e-9)
        }
        // 09:00..11:00 (bins 18..21): 0.5h each from day 01
        for b in 18..<22 {
            #expect(abs(profile.bins[b] - 0.5) < 1e-9)
        }
        // 14:00..16:00 (bins 28..31): bin 28 = 1.0h, bin 29 = 1.5h, bin 30 = 1.5h, bin 31 = 1.0h
        #expect(abs(profile.bins[28] - 1.0) < 1e-9)
        #expect(abs(profile.bins[29] - 1.5) < 1e-9)
        #expect(abs(profile.bins[30] - 1.5) < 1e-9)
        #expect(abs(profile.bins[31] - 1.0) < 1e-9)
        #expect(abs(profile.maxBinHours - 1.5) < 1e-9)
        #expect(profile.peakWindowStartBin == 28)
        #expect(profile.peakWindowEndBin == 32)

        // Deterministic tie-breaking: identical 2-hour windows at 08:00..10:00 (bins 16..20)
        // and 18:00..20:00 (bins 36..40) must always pick the earliest window [16, 20).
        let tiedDays: [String: DayTimeUsage] = [
            "2026-11-02": DayTimeUsage(
                intervals: [
                    ActiveInterval(startSec: 28_800, endSec: 31_200, model: "carbon"), // 40m
                    ActiveInterval(startSec: 31_200, endSec: 36_000, model: "carbon"), // 80m -> total 2.0h in 08:00..10:00
                ],
                totalSeconds: 7_200
            ),
            "2026-11-03": DayTimeUsage(
                intervals: [
                    ActiveInterval(startSec: 64_800, endSec: 72_000, model: "carbon"), // 2.0h in 18:00..20:00
                ],
                totalSeconds: 7_200
            ),
        ]
        let tiedProfile = InstrumentMath.buildMonthDiurnalProfile(days: tiedDays, year: 2026, month: 11)
        #expect(tiedProfile.peakWindowStartBin == 16)
        #expect(tiedProfile.peakWindowEndBin == 20)

        // Empty month returns zeroed bins + nil peak window
        let empty = InstrumentMath.buildMonthDiurnalProfile(days: days, year: 2026, month: 2)
        #expect(empty.bins.count == 48)
        #expect(empty.bins.allSatisfy { $0 == 0.0 })
        #expect(empty.maxBinHours == 0.0)
        #expect(empty.peakWindowStartBin == nil)
        #expect(empty.peakWindowEndBin == nil)

        // binCount < peakWindowBins yields nil window while preserving bin sums
        let tooNarrow = InstrumentMath.buildMonthDiurnalProfile(
            days: tiedDays, year: 2026, month: 11, binCount: 2, peakWindowBins: 4
        )
        #expect(tooNarrow.bins.count == 2)
        #expect(tooNarrow.maxBinHours > 0)
        #expect(tooNarrow.peakWindowStartBin == nil)
        #expect(tooNarrow.peakWindowEndBin == nil)
    }
}
