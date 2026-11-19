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
}
