import Foundation

// MARK: - Craft, Acoustic Edge Triggers, Daily Wallpaper Gate & Specimen Archetypes — pure core
//
// Foundation-only (part of AGYCore):
//   - CraftPreferences / BlueprintWallpaperStyle / SpecimenAspect
//   - AcousticCue / AcousticTriggerState: startup-silent edge detector
//   - DailyWallpaperGate: Gregorian day-key refresh guard
//   - OperatorArchetypeKind / OperatorArchetype / SpecimenLogic
//
// Zero AppKit, SwiftUI, CoreGraphics, Combine, SQLite3, Process, or FileManager.

public enum BlueprintWallpaperStyle: String, Codable, CaseIterable, Sendable {
    case darkMonolith
    case lightGallery
}

public enum SpecimenAspect: String, Codable, CaseIterable, Sendable {
    case portrait4x5
    case landscape16x9
}

public struct CraftPreferences: Codable, Equatable, Sendable {
    public var hapticsEnabled: Bool
    public var acousticChimesEnabled: Bool
    public var dailyWallpaperEnabled: Bool
    public var wallpaperStyle: BlueprintWallpaperStyle
    public var lastWallpaperDateKey: String?
    public var previousWallpaperPath: String?

    public static let `default` = CraftPreferences()

    public init(
        hapticsEnabled: Bool = true,
        acousticChimesEnabled: Bool = false,
        dailyWallpaperEnabled: Bool = false,
        wallpaperStyle: BlueprintWallpaperStyle = .darkMonolith,
        lastWallpaperDateKey: String? = nil,
        previousWallpaperPath: String? = nil
    ) {
        self.hapticsEnabled = hapticsEnabled
        self.acousticChimesEnabled = acousticChimesEnabled
        self.dailyWallpaperEnabled = dailyWallpaperEnabled
        self.wallpaperStyle = wallpaperStyle
        self.lastWallpaperDateKey = lastWallpaperDateKey
        self.previousWallpaperPath = previousWallpaperPath
    }

    enum CodingKeys: String, CodingKey {
        case hapticsEnabled
        case acousticChimesEnabled
        case dailyWallpaperEnabled
        case wallpaperStyle
        case lastWallpaperDateKey
        case previousWallpaperPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.hapticsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .hapticsEnabled)) ?? true
        self.acousticChimesEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .acousticChimesEnabled)) ?? false
        self.dailyWallpaperEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .dailyWallpaperEnabled)) ?? false
        self.wallpaperStyle = (try? c.decodeIfPresent(BlueprintWallpaperStyle.self, forKey: .wallpaperStyle)) ?? .darkMonolith
        self.lastWallpaperDateKey = (try? c.decodeIfPresent(String.self, forKey: .lastWallpaperDateKey)) ?? nil
        self.previousWallpaperPath = (try? c.decodeIfPresent(String.self, forKey: .previousWallpaperPath)) ?? nil
    }
}

public enum AcousticCue: String, Equatable, Sendable {
    case waitingPing
    case turnDoneChord
}

/// Pure edge-detector reducer for acoustic chimes.
/// The first `update` seeds the baseline silently so app launch never chimes;
/// subsequent updates fire `.waitingPing` (higher priority) or `.turnDoneChord`
/// only when newly added session IDs appear.
public struct AcousticTriggerState: Equatable, Sendable {
    public private(set) var hasBaseline: Bool
    public private(set) var lastWaitingIds: Set<String>
    public private(set) var lastDoneUnseenIds: Set<String>

    public init(
        hasBaseline: Bool = false,
        lastWaitingIds: Set<String> = [],
        lastDoneUnseenIds: Set<String> = []
    ) {
        self.hasBaseline = hasBaseline
        self.lastWaitingIds = lastWaitingIds
        self.lastDoneUnseenIds = lastDoneUnseenIds
    }

    public mutating func update(
        waitingIds: Set<String>,
        doneUnseenIds: Set<String>
    ) -> AcousticCue? {
        if !hasBaseline {
            hasBaseline = true
            lastWaitingIds = waitingIds
            lastDoneUnseenIds = doneUnseenIds
            return nil
        }

        let newWaiting = waitingIds.subtracting(lastWaitingIds)
        let newDone = doneUnseenIds.subtracting(lastDoneUnseenIds)

        lastWaitingIds = waitingIds
        lastDoneUnseenIds = doneUnseenIds

        if !newWaiting.isEmpty {
            return .waitingPing
        }
        if !newDone.isEmpty {
            return .turnDoneChord
        }
        return nil
    }
}

public enum DailyWallpaperGate {
    /// True iff daily blueprint wallpaper is enabled and has not yet rendered for `todayKey`.
    public static func shouldRefresh(todayKey: String, preferences: CraftPreferences) -> Bool {
        let trimmed = todayKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !AppDate.isSentinelDayKey(trimmed) else { return false }
        return preferences.dailyWallpaperEnabled && preferences.lastWallpaperDateKey != trimmed
    }
}

public enum OperatorArchetypeKind: String, Codable, Equatable, Sendable {
    case nocturnalArchitect
    case dawnSynthesizer
    case daylightCraftsman
    case marathonOperator
    case steadyPilot
}

public struct OperatorArchetype: Equatable, Sendable {
    public let kind: OperatorArchetypeKind
    public let peakWindowLabel: String
    public let cacheGrade: String
    public let cacheHitPercent: Int?

    public init(
        kind: OperatorArchetypeKind,
        peakWindowLabel: String,
        cacheGrade: String,
        cacheHitPercent: Int?
    ) {
        self.kind = kind
        self.peakWindowLabel = peakWindowLabel
        self.cacheGrade = cacheGrade
        self.cacheHitPercent = cacheHitPercent
    }
}

public enum SpecimenLogic {
    /// Classify operator archetype, diurnal peak window label, and cache efficiency grade.
    public static func classifyArchetype(
        diurnalProfile: MonthDiurnalProfile,
        activeHours: Double,
        totalInputTokens: Int,
        totalCacheReadTokens: Int
    ) -> OperatorArchetype {
        let safeHours = activeHours.isFinite ? max(0.0, activeHours) : 0.0
        let binCount = diurnalProfile.bins.isEmpty ? 48 : diurnalProfile.bins.count

        let peakWindowLabel: String
        let peakStartHour: Int?

        if let rawStart = diurnalProfile.peakWindowStartBin, binCount > 0 {
            let startBin = ((rawStart % binCount) + binCount) % binCount
            let defaultSpan = max(1, binCount / 12)
            let endBin = diurnalProfile.peakWindowEndBin ?? (startBin + defaultSpan)

            let startMinutes = minutesOfDay(forBin: startBin, binCount: binCount)
            let endMinutes = minutesOfDay(forBin: endBin, binCount: binCount)
            peakStartHour = startMinutes / 60
            peakWindowLabel = "\(formatHHMM(startMinutes))–\(formatHHMM(endMinutes))"
        } else {
            peakStartHour = nil
            peakWindowLabel = "--"
        }

        let kind: OperatorArchetypeKind
        if safeHours >= 120.0 {
            kind = .marathonOperator
        } else if let h = peakStartHour, (h >= 21 || h < 5) {
            kind = .nocturnalArchitect
        } else if let h = peakStartHour, (5..<9).contains(h) {
            kind = .dawnSynthesizer
        } else if safeHours >= 20.0 {
            kind = .daylightCraftsman
        } else {
            kind = .steadyPilot
        }

        let safeInput = max(0, totalInputTokens)
        let safeCacheRead = max(0, totalCacheReadTokens)
        let denom = safeInput + safeCacheRead
        let cacheGrade: String
        let cacheHitPercent: Int?

        if denom > 0 {
            let ratio = Double(safeCacheRead) / Double(denom)
            let hitPct = min(100, max(0, Int((ratio * 100.0).rounded())))
            cacheHitPercent = hitPct
            if hitPct >= 90 {
                cacheGrade = "A+"
            } else if hitPct >= 80 {
                cacheGrade = "A"
            } else if hitPct >= 65 {
                cacheGrade = "B+"
            } else if hitPct >= 45 {
                cacheGrade = "B"
            } else {
                cacheGrade = "C"
            }
        } else {
            cacheGrade = "--"
            cacheHitPercent = nil
        }

        return OperatorArchetype(
            kind: kind,
            peakWindowLabel: peakWindowLabel,
            cacheGrade: cacheGrade,
            cacheHitPercent: cacheHitPercent
        )
    }

    private static func minutesOfDay(forBin bin: Int, binCount: Int) -> Int {
        let raw = Int((Double(bin) * 1440.0 / Double(max(1, binCount))).rounded())
        return ((raw % 1440) + 1440) % 1440
    }

    private static func formatHHMM(_ minutes: Int) -> String {
        let clamped = ((minutes % 1440) + 1440) % 1440
        let h = clamped / 60
        let m = clamped % 60
        return String(format: "%02d:%02d", h, m)
    }
}
