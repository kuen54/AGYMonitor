import Foundation
import Testing
@testable import AGYCore

@Suite("Core_CraftState")
struct CraftStateTests {

    // MARK: - CraftPreferences

    @Test("CraftPreferences defaults, Codable round-trip, and partial JSON fallback")
    func craftPreferencesCodableRoundTrip() throws {
        let def = CraftPreferences.default
        #expect(def.hapticsEnabled == true)
        #expect(def.acousticChimesEnabled == false)
        #expect(def.dailyWallpaperEnabled == false)
        #expect(def.wallpaperStyle == .darkMonolith)
        #expect(def.lastWallpaperDateKey == nil)
        #expect(def.previousWallpaperPath == nil)

        let custom = CraftPreferences(
            hapticsEnabled: false,
            acousticChimesEnabled: true,
            dailyWallpaperEnabled: true,
            wallpaperStyle: .lightGallery,
            lastWallpaperDateKey: "2026-11-22",
            previousWallpaperPath: "/Users/test/Pictures/orig.png"
        )
        let data = try JSONEncoder().encode(custom)
        let decoded = try JSONDecoder().decode(CraftPreferences.self, from: data)
        #expect(decoded == custom)

        // Forward-compatible decoding from minimal JSON falls back to defaults
        let emptyDecoded = try JSONDecoder().decode(CraftPreferences.self, from: Data("{}".utf8))
        #expect(emptyDecoded == CraftPreferences.default)
    }

    // MARK: - AcousticTriggerState

    @Test("AcousticTriggerState stays silent on startup baseline, fires on new edges, and prioritizes waitingPing")
    func acousticTriggerEdgeDetectionAndPriority() {
        var state = AcousticTriggerState()

        // First call seeds baseline — never chimes on startup even if sessions are already waiting/done
        let bootCue = state.update(waitingIds: ["w1"], doneUnseenIds: ["d1"])
        #expect(bootCue == nil)
        #expect(state.hasBaseline == true)

        // Steady state: no new IDs -> nil
        #expect(state.update(waitingIds: ["w1"], doneUnseenIds: ["d1"]) == nil)

        // New done-unseen session -> .turnDoneChord
        #expect(state.update(waitingIds: ["w1"], doneUnseenIds: ["d1", "d2"]) == .turnDoneChord)

        // Simultaneous new waiting AND new done -> .waitingPing takes higher priority
        #expect(state.update(waitingIds: ["w1", "w2"], doneUnseenIds: ["d1", "d2", "d3"]) == .waitingPing)

        // Next tick with same sets -> nil (d3 was already absorbed into baseline)
        #expect(state.update(waitingIds: ["w1", "w2"], doneUnseenIds: ["d1", "d2", "d3"]) == nil)

        // Removing an ID does not chime; re-entering later DOES chime
        #expect(state.update(waitingIds: ["w1"], doneUnseenIds: ["d1"]) == nil)
        #expect(state.update(waitingIds: ["w1", "w2"], doneUnseenIds: ["d1"]) == .waitingPing)
    }

    // MARK: - DailyWallpaperGate

    @Test("DailyWallpaperGate refreshes only when enabled and date key differs")
    func dailyWallpaperGatePolicy() {
        var prefs = CraftPreferences.default
        #expect(DailyWallpaperGate.shouldRefresh(todayKey: "2026-11-22", preferences: prefs) == false)

        prefs.dailyWallpaperEnabled = true
        #expect(DailyWallpaperGate.shouldRefresh(todayKey: "2026-11-22", preferences: prefs) == true)

        prefs.lastWallpaperDateKey = "2026-11-21"
        #expect(DailyWallpaperGate.shouldRefresh(todayKey: "2026-11-22", preferences: prefs) == true)

        prefs.lastWallpaperDateKey = "2026-11-22"
        #expect(DailyWallpaperGate.shouldRefresh(todayKey: "2026-11-22", preferences: prefs) == false)

        // Sentinel / empty day key never triggers refresh
        prefs.lastWallpaperDateKey = nil
        #expect(DailyWallpaperGate.shouldRefresh(todayKey: "", preferences: prefs) == false)
        #expect(DailyWallpaperGate.shouldRefresh(todayKey: "0001-01-01", preferences: prefs) == false)
    }

    // MARK: - SpecimenLogic.classifyArchetype

    @Test("Classifies all 5 operator archetypes and peak window labels")
    func specimenArchetypeClassification() {
        let bins48 = Array(repeating: 0.0, count: 48)

        // 1. Marathon Operator (>= 120h overrides nocturnal peak)
        let nocturnalProfile = MonthDiurnalProfile(
            bins: bins48,
            maxBinHours: 5.0,
            peakWindowStartBin: 45, // 22:30
            peakWindowEndBin: 49    // 00:30
        )
        let marathon = SpecimenLogic.classifyArchetype(
            diurnalProfile: nocturnalProfile,
            activeHours: 128.5,
            totalInputTokens: 100_000,
            totalCacheReadTokens: 900_000
        )
        #expect(marathon.kind == .marathonOperator)
        #expect(marathon.peakWindowLabel == "22:30–00:30")
        #expect(marathon.cacheGrade == "A+")
        #expect(marathon.cacheHitPercent == 90)

        // 2. Nocturnal Architect (late night >= 21:00 or early morning < 05:00)
        let nocturnalLate = SpecimenLogic.classifyArchetype(
            diurnalProfile: nocturnalProfile,
            activeHours: 48.0,
            totalInputTokens: 150_000,
            totalCacheReadTokens: 850_000
        )
        #expect(nocturnalLate.kind == .nocturnalArchitect)
        #expect(nocturnalLate.peakWindowLabel == "22:30–00:30")

        let afterMidnightProfile = MonthDiurnalProfile(
            bins: bins48,
            maxBinHours: 3.0,
            peakWindowStartBin: 2, // 01:00
            peakWindowEndBin: 6    // 03:00
        )
        let nocturnalEarly = SpecimenLogic.classifyArchetype(
            diurnalProfile: afterMidnightProfile,
            activeHours: 12.0,
            totalInputTokens: 0,
            totalCacheReadTokens: 0
        )
        #expect(nocturnalEarly.kind == .nocturnalArchitect)
        #expect(nocturnalEarly.peakWindowLabel == "01:00–03:00")
        #expect(nocturnalEarly.cacheGrade == "--")
        #expect(nocturnalEarly.cacheHitPercent == nil)

        // 3. Dawn Synthesizer (05:00..<09:00)
        let dawnProfile = MonthDiurnalProfile(
            bins: bins48,
            maxBinHours: 4.0,
            peakWindowStartBin: 12, // 06:00
            peakWindowEndBin: 16    // 08:00
        )
        let dawn = SpecimenLogic.classifyArchetype(
            diurnalProfile: dawnProfile,
            activeHours: 35.0,
            totalInputTokens: 200_000,
            totalCacheReadTokens: 800_000
        )
        #expect(dawn.kind == .dawnSynthesizer)
        #expect(dawn.peakWindowLabel == "06:00–08:00")
        #expect(dawn.cacheGrade == "A")
        #expect(dawn.cacheHitPercent == 80)

        // 4. Daylight Craftsman (09:00..<21:00 with >= 20h)
        let dayProfile = MonthDiurnalProfile(
            bins: bins48,
            maxBinHours: 6.0,
            peakWindowStartBin: 28, // 14:00
            peakWindowEndBin: 32    // 16:00
        )
        let craftsman = SpecimenLogic.classifyArchetype(
            diurnalProfile: dayProfile,
            activeHours: 42.0,
            totalInputTokens: 350_000,
            totalCacheReadTokens: 650_000
        )
        #expect(craftsman.kind == .daylightCraftsman)
        #expect(craftsman.peakWindowLabel == "14:00–16:00")
        #expect(craftsman.cacheGrade == "B+")
        #expect(craftsman.cacheHitPercent == 65)

        // 5. Steady Pilot (daytime < 20h, or empty diurnal profile < 20h)
        let steady = SpecimenLogic.classifyArchetype(
            diurnalProfile: dayProfile,
            activeHours: 14.0,
            totalInputTokens: 550_000,
            totalCacheReadTokens: 450_000
        )
        #expect(steady.kind == .steadyPilot)
        #expect(steady.cacheGrade == "B")
        #expect(steady.cacheHitPercent == 45)

        let emptyProfile = MonthDiurnalProfile(
            bins: bins48,
            maxBinHours: 0,
            peakWindowStartBin: nil,
            peakWindowEndBin: nil
        )
        let emptyPilot = SpecimenLogic.classifyArchetype(
            diurnalProfile: emptyProfile,
            activeHours: 5.0,
            totalInputTokens: 700_000,
            totalCacheReadTokens: 300_000
        )
        #expect(emptyPilot.kind == .steadyPilot)
        #expect(emptyPilot.peakWindowLabel == "--")
        #expect(emptyPilot.cacheGrade == "C")
        #expect(emptyPilot.cacheHitPercent == 30)

        // Rounding boundary: 0.8974 rounds to displayed 90% and must receive A+ (no A + 90% mismatch)
        let boundaryAPlus = SpecimenLogic.classifyArchetype(
            diurnalProfile: nocturnalProfile,
            activeHours: 40.0,
            totalInputTokens: 1_026,
            totalCacheReadTokens: 8_974
        )
        #expect(boundaryAPlus.cacheHitPercent == 90)
        #expect(boundaryAPlus.cacheGrade == "A+")
    }
}
