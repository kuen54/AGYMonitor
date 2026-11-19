import Foundation

// MARK: - App-only Data Models
//
// Pure data models (ModelUsage / PeriodUsage / DailyUsage / MonthlySnapshot)
// live in Core_Models.swift (testable SPM core).
// AppDate (Gregorian/POSIX date utilities) lives in Core_DateLogic.swift.

// MARK: - Plan & AI Credits Quota

/// One rolling quota window (e.g. Antigravity's ~5-hour Gemini bucket or Claude & Partner bucket).
/// `utilization` stores used percentage (0..100) so `remaining = 100 - displayPercent`
/// matches the UI's "% left" framing across all SubWindowRow views.
struct OAuthUsageWindow: Codable, Equatable {
    let utilization: Double
    let resets_at: String?         // ISO-8601 timestamp
    let label: String?

    /// Integer percent used, clamped to 0...100.
    var displayPercent: Int { max(0, min(100, Int(utilization.rounded()))) }

    /// Integer percent remaining, clamped to 0...100.
    var remainingPercent: Int { max(0, min(100, 100 - displayPercent)) }

    var resetDate: Date? { OAuthUsage.parseISO(resets_at) }

    init(utilization: Double, resets_at: String? = nil, label: String? = nil) {
        self.utilization = utilization
        self.resets_at = resets_at
        self.label = label
    }
}

struct OAuthExtraUsage: Codable, Equatable {
    let is_enabled: Bool
    let used_credits: Double?
    let monthly_limit: Double?

    init(is_enabled: Bool, used_credits: Double? = nil, monthly_limit: Double? = nil) {
        self.is_enabled = is_enabled
        self.used_credits = used_credits
        self.monthly_limit = monthly_limit
    }
}

/// One model- or family-scoped quota entry (e.g. additional model bucket in Antigravity).
/// Every field is optional so schema drift in one entry never fails the whole snapshot.
struct OAuthUsageLimit: Codable, Equatable {
    let kind: String?
    let group: String?
    let percent: Double?       // used %, 0..100
    let resets_at: String?     // ISO-8601 timestamp
    let scope: OAuthLimitScope?
    let is_active: Bool?

    /// Integer percent used, clamped to 0...100.
    var displayPercent: Int { max(0, min(100, Int((percent ?? 0).rounded()))) }
    var remainingPercent: Int { max(0, min(100, 100 - displayPercent)) }
    var resetDate: Date? { OAuthUsage.parseISO(resets_at) }
    var modelDisplayName: String? { scope?.model?.display_name }

    init(
        kind: String? = nil,
        group: String? = nil,
        percent: Double? = nil,
        resets_at: String? = nil,
        scope: OAuthLimitScope? = nil,
        is_active: Bool? = nil
    ) {
        self.kind = kind
        self.group = group
        self.percent = percent
        self.resets_at = resets_at
        self.scope = scope
        self.is_active = is_active
    }
}

struct OAuthLimitScope: Codable, Equatable {
    let model: OAuthLimitModel?

    init(model: OAuthLimitModel? = nil) {
        self.model = model
    }
}

struct OAuthLimitModel: Codable, Equatable {
    let id: String?
    let display_name: String?

    init(id: String? = nil, display_name: String? = nil) {
        self.id = id
        self.display_name = display_name
    }
}

/// Lossy container for `limits`: decodes element-by-element and drops malformed
/// entries rather than throwing and blanking the primary quota windows.
struct OAuthLimitList: Codable, Equatable {
    let items: [OAuthUsageLimit]
    init(items: [OAuthUsageLimit]) { self.items = items }

    init(from decoder: Decoder) throws {
        guard var c = try? decoder.unkeyedContainer() else { items = []; return }
        var out: [OAuthUsageLimit] = []
        while !c.isAtEnd {
            if let v = try c.decode(FailableLimit.self).value { out.append(v) }
        }
        items = out
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(contentsOf: items)
    }

    private struct FailableLimit: Decodable {
        let value: OAuthUsageLimit?
        init(from decoder: Decoder) throws { value = try? OAuthUsageLimit(from: decoder) }
    }
}

/// Complete Plan / Quota snapshot for Antigravity:
/// - `five_hour`: Primary Gemini models rolling ~5h quota bucket
/// - `seven_day`: Secondary Claude & Partner models rolling ~5h quota bucket
/// - `limits`: Optional additional scoped model/bucket caps
/// - AGY account & Google One AI Credits fields (`accountEmail`, `planTier`,
///   `promptCredits`, `flowCredits`, `flexCredits`, `isOfflineCached`)
struct OAuthUsage: Codable, Equatable {
    let five_hour: OAuthUsageWindow
    let seven_day: OAuthUsageWindow
    let extra_usage: OAuthExtraUsage?
    let seven_day_sonnet: OAuthUsageWindow?
    let limits: OAuthLimitList?

    // Antigravity-specific plan & AI Credits metadata (all optional / defaulted)
    let accountEmail: String?
    let planTier: String?
    let promptCredits: Int?
    let flowCredits: Int?
    let flexCredits: Int?
    let isOfflineCached: Bool

    init(
        five_hour: OAuthUsageWindow,
        seven_day: OAuthUsageWindow = OAuthUsageWindow(utilization: 0, resets_at: nil),
        extra_usage: OAuthExtraUsage? = nil,
        seven_day_sonnet: OAuthUsageWindow? = nil,
        limits: OAuthLimitList? = nil,
        accountEmail: String? = nil,
        planTier: String? = nil,
        promptCredits: Int? = nil,
        flowCredits: Int? = nil,
        flexCredits: Int? = nil,
        isOfflineCached: Bool = false
    ) {
        self.five_hour = five_hour
        self.seven_day = seven_day
        self.extra_usage = extra_usage
        self.seven_day_sonnet = seven_day_sonnet
        self.limits = limits
        self.accountEmail = accountEmail
        self.planTier = planTier
        self.promptCredits = promptCredits
        self.flowCredits = flowCredits
        self.flexCredits = flexCredits
        self.isOfflineCached = isOfflineCached
    }

    enum CodingKeys: String, CodingKey {
        case five_hour, seven_day, extra_usage, seven_day_sonnet, limits
        case accountEmail, planTier, promptCredits, flowCredits, flexCredits, isOfflineCached
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.five_hour = try c.decode(OAuthUsageWindow.self, forKey: .five_hour)
        self.seven_day = (try? c.decodeIfPresent(OAuthUsageWindow.self, forKey: .seven_day))
            ?? OAuthUsageWindow(utilization: 0, resets_at: nil)
        self.extra_usage = try? c.decodeIfPresent(OAuthExtraUsage.self, forKey: .extra_usage)
        self.seven_day_sonnet = try? c.decodeIfPresent(OAuthUsageWindow.self, forKey: .seven_day_sonnet)
        self.limits = try? c.decodeIfPresent(OAuthLimitList.self, forKey: .limits)
        self.accountEmail = try? c.decodeIfPresent(String.self, forKey: .accountEmail)
        self.planTier = try? c.decodeIfPresent(String.self, forKey: .planTier)
        self.promptCredits = try? c.decodeIfPresent(Int.self, forKey: .promptCredits)
        self.flowCredits = try? c.decodeIfPresent(Int.self, forKey: .flowCredits)
        self.flexCredits = try? c.decodeIfPresent(Int.self, forKey: .flexCredits)
        self.isOfflineCached = (try? c.decodeIfPresent(Bool.self, forKey: .isOfflineCached)) ?? false
    }

    var fiveHourResetDate: Date? { Self.parseISO(five_hour.resets_at) }
    var sevenDayResetDate: Date? { Self.parseISO(seven_day.resets_at) }
    var sevenDaySonnetResetDate: Date? { Self.parseISO(seven_day_sonnet?.resets_at) }

    /// Scoped model/bucket caps from `limits` (excluding unnamed entries).
    var scopedModelLimits: [OAuthUsageLimit] {
        (limits?.items ?? [])
            .filter { !($0.modelDisplayName?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
            .sorted { ($0.modelDisplayName ?? "") < ($1.modelDisplayName ?? "") }
    }

    /// True if any Google One AI Credits balance is present on this snapshot.
    var hasCredits: Bool {
        promptCredits != nil || flowCredits != nil || flexCredits != nil
    }

    static func parseISO(_ s: String?) -> Date? {
        if let d = AppDate.parseISO8601(s) { return d }
        guard let s = s, !AppDate.isSentinelTimestamp(s) else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static func formatISO(_ date: Date?) -> String? {
        guard let date = date else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}

typealias QuotaSnapshot = OAuthUsage
typealias QuotaLimit = OAuthUsageLimit
typealias QuotaWindow = OAuthUsageWindow

// MARK: - Tab & Mode Enums

// rawValues are APPENDED, never renumbered: the selected tab's rawValue may be
// persisted (UserDefaults) and renumbering would silently remap saved choices.
// Display order is decoupled from rawValue order — PopoverView.visibleTabs
// lists cost, tokens, time, session, subscription explicitly.
enum DisplayTab: Int, CaseIterable {
    case cost = 0
    case tokens = 1
    case subscription = 2
    case time = 3
    case session = 4

    var icon: String {
        switch self {
        case .cost:         return "dollarsign.circle"
        case .tokens:       return "number.circle"
        case .subscription: return "gauge.with.dots.needle.67percent"
        case .time:         return "clock"
        case .session:      return "bubble.left.and.bubble.right"
        }
    }

    func label(_ loc: Localizer) -> String {
        switch self {
        case .cost:         return loc("cost")
        case .tokens:       return loc("tokens")
        case .subscription: return loc("subTab")
        case .time:         return loc("timeTab")
        case .session:      return loc("sessionTab")
        }
    }
}

/// Inner sub-view switcher of the Time tab (Week / Month / Year). App-only —
/// not persisted, defaults to .week on each launch.
enum TimeRange: Int, CaseIterable {
    case week = 0
    case month = 1
    case year = 2

    func label(_ loc: Localizer) -> String {
        switch self {
        case .week:  return loc("timeWeek")
        case .month: return loc("timeMonth")
        case .year:  return loc("timeYear")
        }
    }
}

/// Where the app surfaces its idle icon+value: the system menu bar (default) or
/// the MacBook notch (a drop-down panel on hover). App-only — must NOT enter
/// any Core_*.swift.
enum DisplayMode: String, CaseIterable {
    case menubar
    case notch

    func label(_ loc: Localizer) -> String {
        switch self {
        case .menubar: return loc("displayModeMenubar")
        case .notch:   return loc("displayModeNotch")
        }
    }
}

extension MenuBarMetricPreference {
    func label(_ loc: Localizer) -> String {
        switch self {
        case .followTab:    return loc("metricFollowTab")
        case .todayCost:    return loc("metricTodayCost")
        case .quota5h:      return loc("metricQuota5h")
        case .liveSessions: return loc("metricLiveSessions")
        case .costAndQuota: return loc("metricCostAndQuota")
        }
    }
}

extension TelemetryThemePreset {
    func label(_ loc: Localizer) -> String {
        switch self {
        case .monolith:  return loc("themeMonolith")
        case .blueprint: return loc("themeBlueprint")
        case .phosphor:  return loc("themePhosphor")
        case .amber:     return loc("themeAmber")
        }
    }
}

extension TelemetryVisualMode {
    func label(_ loc: Localizer) -> String {
        switch self {
        case .instrument: return loc("visualModeInstrument")
        case .classic:    return loc("visualModeClassic")
        }
    }
}
