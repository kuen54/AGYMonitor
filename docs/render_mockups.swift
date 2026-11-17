// Render real SwiftUI popover views to PNGs with synthetic data, via
// ImageRenderer — so the README screenshots are pixel-faithful to the app
// (native-style segmented controls, real cards, real fonts). Compiled together
// with Sources/*.swift (minus main.swift) into a standalone renderer. Mock data only.
import SwiftUI
import AppKit

// ── Antigravity logo wrapper using AGYLogo's optically-centered rect path ──
private struct DemoAGYLogoShape: Shape {
    func path(in rect: CGRect) -> SwiftUI.Path {
        AGYLogo.swiftUIPath(in: rect)
    }
}

// ── synthetic data builders ──
func m(_ id: String, _ name: String, _ cost: Double, _ msgs: Int,
       _ i: Int, _ o: Int, _ cr: Int, _ cw: Int = 0) -> ModelUsage {
    ModelUsage(id: id, name: name, cost: cost, messages: msgs,
               inputTokens: i, outputTokens: o, cacheRead: cr, cacheWrite: cw)
}

// Scaled copies of one Antigravity model mix for Today / Week / Month
func period(_ scale: Double) -> PeriodUsage {
    let models = [
        m("carbon",   "Carbon",   112.4 * scale, max(1, Int(420 * scale)), Int(9_800_000 * scale), Int(540_000 * scale), Int(68_400_000 * scale)),
        m("hydrogen", "Hydrogen",  64.8 * scale, max(1, Int(135 * scale)), Int(3_200_000 * scale), Int(310_000 * scale), Int(24_600_000 * scale)),
        m("claude",   "Claude",    38.2 * scale, max(1, Int(118 * scale)), Int(2_100_000 * scale), Int(190_000 * scale), Int(18_500_000 * scale)),
        m("argon",    "Argon",     14.6 * scale, max(1, Int(96 * scale)),  Int(1_950_000 * scale), Int(125_000 * scale), Int(11_200_000 * scale)),
        m("flash",    "Flash",      4.2 * scale, max(1, Int(164 * scale)), Int(2_400_000 * scale), Int(140_000 * scale), Int(9_800_000 * scale)),
    ]
    let cost = models.reduce(0) { $0 + $1.cost }
    let msgs = models.reduce(0) { $0 + $1.messages }
    let tk = models.reduce(0) { $0 + $1.totalTokens }
    return PeriodUsage(cost: cost, models: models, totalMessages: msgs, totalTokens: tk)
}

func dailyMock(year: Int, month: Int) -> [DailyUsage] {
    let vals: [Double] = [4, 7, 15, 42, 19, 11, 28, 165, 138, 192, 98, 84, 224, 248, 210, 56, 132, 74,
                          96, 52, 34, 41, 29, 48, 24, 33, 118, 176, 129, 38, 154]
    let cal = Calendar(identifier: .gregorian)
    let comps = DateComponents(year: year, month: month, day: 1)
    let daysInMonth = cal.date(from: comps).flatMap { cal.range(of: .day, in: .month, for: $0)?.count } ?? 30
    return (0..<min(vals.count, daysInMonth)).map { i in
        let v = vals[i]
        func tk(_ s: Double) -> (Int, Int, Int) {
            (Int(v * s * 6_500), Int(v * s * 1_200), Int(v * s * 520_000))
        }
        let c = tk(0.48), h = tk(0.26), cl = tk(0.16), a = tk(0.07), fl = tk(0.03)
        let mm = [
            m("carbon",   "Carbon",   v * 0.48, 0, c.0,  c.1,  c.2),
            m("hydrogen", "Hydrogen", v * 0.26, 0, h.0,  h.1,  h.2),
            m("claude",   "Claude",   v * 0.16, 0, cl.0, cl.1, cl.2),
            m("argon",    "Argon",    v * 0.07, 0, a.0,  a.1,  a.2),
            m("flash",    "Flash",    v * 0.03, 0, fl.0, fl.1, fl.2),
        ]
        let tot = mm.reduce(0) { $0 + $1.totalTokens }
        return DailyUsage(dateString: String(format: "%04d-%02d-%02d", year, month, i + 1),
                          day: i + 1, cost: v, totalTokens: tot, models: mm)
    }
}

func iv(_ sh: Double, _ eh: Double, _ model: String?) -> ActiveInterval {
    ActiveInterval(startSec: Int(sh * 3600), endSec: Int(eh * 3600), model: model)
}
func day(_ ivs: [ActiveInterval]) -> DayTimeUsage {
    DayTimeUsage(intervals: ivs, totalSeconds: ivs.reduce(0) { $0 + $1.durationSeconds })
}

func dayKey(_ d: Date) -> String {
    let c = Calendar(identifier: .gregorian)
    let p = c.dateComponents([.year, .month, .day], from: d)
    return String(format: "%04d-%02d-%02d", p.year!, p.month!, p.day!)
}

func timeMock() -> (TimeData, [String: Int]) {
    let cal = Calendar(identifier: .gregorian)
    let today = Date()
    let wd = cal.component(.weekday, from: today) // 1=Sun..7=Sat
    let backToMon = (wd + 5) % 7
    let monday = cal.date(byAdding: .day, value: -backToMon, to: today)!
    let C = "carbon", H = "hydrogen", CL = "claude", A = "argon", F = "flash"
    let patterns: [[ActiveInterval]] = [
        [iv(9.2, 10.4, C), iv(10.8, 12.2, H), iv(14.1, 16.4, C), iv(21.0, 22.3, CL)],
        [iv(8.9, 9.4, F), iv(9.7, 12.5, C), iv(13.6, 14.3, A), iv(15.0, 18.0, H), iv(20.4, 21.2, C)],
        [iv(10.0, 10.6, A), iv(11.1, 13.0, C), iv(14.2, 17.6, H), iv(21.8, 23.0, CL)],
        [iv(9.1, 9.5, F), iv(9.8, 12.1, C), iv(13.1, 13.7, A), iv(14.3, 18.8, C)],
        [iv(8.6, 9.2, CL), iv(9.5, 11.7, H), iv(13.2, 16.9, C), iv(17.3, 17.9, F), iv(21.4, 23.2, C)],
        [iv(10.8, 12.4, C), iv(15.2, 16.3, H)],
        [iv(19.8, 20.5, A), iv(21.0, 22.7, C)],
    ]
    var days: [String: DayTimeUsage] = [:]
    for i in 0..<7 {
        let d = cal.date(byAdding: .day, value: i, to: monday)!
        days[dayKey(d)] = day(patterns[i])
    }
    let comps = cal.dateComponents([.year, .month], from: today)
    let monthStart = cal.date(from: comps)!
    let range = cal.range(of: .day, in: .month, for: today)!
    for dnum in range {
        let d = cal.date(byAdding: .day, value: dnum - 1, to: monthStart)!
        let k = dayKey(d)
        if days[k] == nil {
            let r = Double((dnum * 37) % 11) / 11.0
            if r > 0.3 {
                days[k] = day([iv(9 + r * 2, 11 + r * 4, C), iv(15 + r, 16 + r * 2, r > 0.65 ? H : CL)])
            }
        }
    }
    var year: [String: Int] = [:]
    let y = comps.year!
    for mo in 1...12 {
        let mc = DateComponents(year: y, month: mo)
        let md = cal.date(from: mc)!
        let mr = cal.range(of: .day, in: .month, for: md)!
        for dnum in mr {
            let d = cal.date(from: DateComponents(year: y, month: mo, day: dnum))!
            if d > today { continue }
            let weekday = cal.component(.weekday, from: d)
            let weekend = (weekday == 1 || weekday == 7)
            let base = 0.22 + 0.68 * (Double(mo) / 12.0)
            let noise = Double((dnum * 53 + mo * 17) % 100) / 100.0
            var hrs = base * noise * (weekend ? 0.4 : 1.0) * 8
            if mo < 4 { hrs *= 0.35 }
            year[dayKey(d)] = Int(hrs * 3600)
        }
    }
    return (TimeData(gapMinutes: 10, days: days), year)
}

// ── synthetic live Antigravity session data ──
func sess(_ pid: Int, _ id: String, _ cwd: String, _ status: SessionStatus,
          waitingFor: String? = nil, agoSec: Double) -> SessionInfo {
    let now = Date().timeIntervalSince1970 * 1000
    return SessionInfo(pid: pid, sessionId: id, cwd: cwd, status: status,
                       waitingFor: waitingFor, startedAt: now - agoSec * 1000 - 7_200_000,
                       updatedAt: now - agoSec * 1000, statusUpdatedAt: now - agoSec * 1000,
                       version: "1.5.9", kind: nil, entrypoint: "cli")
}

@MainActor
func populateSessions(_ s: UsageStore) {
    let agym = "/Users/lijiakun/Developer/AGYMonitor"
    let mia  = "/Users/lijiakun/Developer/mia"
    let hf   = "/Users/lijiakun/Developer/hyperframes"
    s.sessionStore.sessions = [
        sess(6101, "a1aa0001-0000-0000-0000-000000000001", agym, .busy, agoSec: 38),
        sess(6102, "a1aa0002-0000-0000-0000-000000000002", agym, .idle, agoSec: 5 * 60),
        sess(6201, "b2bb0001-0000-0000-0000-000000000001", hf,   .waiting,
             waitingFor: "input needed", agoSec: 2 * 60),
        sess(6202, "b2bb0002-0000-0000-0000-000000000002", hf,   .idle, agoSec: 44 * 60),
        sess(6301, "c3cc0001-0000-0000-0000-000000000001", mia,  .idle, agoSec: 9 * 60),
        sess(6302, "c3cc0002-0000-0000-0000-000000000002", mia,  .idle, agoSec: 2 * 3600),
    ]
    s.sessionStore.labels = [agym: "AGYMonitor", mia: "mia", hf: "hyperframes"]
    s.sessionStore.titles = [
        "a1aa0001-0000-0000-0000-000000000001": "Swarm coordinator: Notch & Plan UI",
        "a1aa0002-0000-0000-0000-000000000002": "SQLite WAL immutable fallback",
        "b2bb0001-0000-0000-0000-000000000001": "Launch film keyframe choreography",
        "b2bb0002-0000-0000-0000-000000000002": "Deterministic GSAP seek adapter",
        "c3cc0001-0000-0000-0000-000000000001": "Gemini 4 Carbon nutrition pipeline",
        "c3cc0002-0000-0000-0000-000000000002": "Multi-agent verification workflow",
    ]
    s.sessionStore.instructions = [
        "a1aa0001-0000-0000-0000-000000000001": "Sync Gemini & Claude rolling 5h quota buckets and AI Credits into the Plan tab",
        "a1aa0002-0000-0000-0000-000000000002": "Add unit tests for conversation_summaries.db read-only fallback",
        "b2bb0001-0000-0000-0000-000000000001": "Confirm target aspect ratio and 60fps render preset before exporting",
        "b2bb0002-0000-0000-0000-000000000002": "Audit frame-0 initial transforms across sub-compositions",
        "c3cc0001-0000-0000-0000-000000000001": "Benchmark structured output latency across Carbon vs Flash",
        "c3cc0002-0000-0000-0000-000000000002": "Run parallel review workflow on PR #42",
    ]
    s.sessionStore.doneUnseen = [
        "a1aa0002-0000-0000-0000-000000000002",
        "c3cc0001-0000-0000-0000-000000000001",
    ]
    s.sessionStore.anyDoneUnseen = true
}

func resetIn(_ hours: Double) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: Date().addingTimeInterval(hours * 3600))
}

func scopedCap(_ id: String?, _ model: String, used: Double, resetHours: Double) -> OAuthUsageLimit {
    OAuthUsageLimit(kind: "weekly_scoped", group: "weekly", percent: used,
                    resets_at: resetIn(resetHours),
                    scope: OAuthLimitScope(model: OAuthLimitModel(id: id, display_name: model)),
                    is_active: true)
}

@MainActor
func makeStore(tab: DisplayTab, range: TimeRange = .week) -> UsageStore {
    let s = UsageStore()
    let cal = Calendar(identifier: .gregorian)
    let now = cal.dateComponents([.year, .month], from: Date())
    s.language = .en
    s.isLoading = false
    s.hasOAuthToken = true
    s.selectedTab = tab
    s.viewingYear = now.year!
    s.viewingMonth = now.month!
    s.viewingTimeYear = now.year!
    s.today = period(0.14)
    s.week = period(0.68)
    s.month = period(1.0)
    s.currentMonthData = s.month
    s.dailyBreakdown = dailyMock(year: now.year!, month: now.month!)
    s.lastUpdate = Date()
    let (td, year) = timeMock()
    s.currentTimeData = td
    s.viewingTimeData = td
    s.yearTimeDays = year
    s.timeRange = range
    s.subscriptionQuota = OAuthUsage(
        five_hour: OAuthUsageWindow(utilization: 9, resets_at: resetIn(4.6), label: "Gemini Models"),
        seven_day: OAuthUsageWindow(utilization: 14, resets_at: resetIn(4.9), label: "Claude & GPT · 5h"),
        extra_usage: nil,
        seven_day_sonnet: nil,
        limits: OAuthLimitList(items: [
            scopedCap("gemini_weekly", "Gemini · Weekly", used: 41, resetHours: 147),
            scopedCap("claude_partner_weekly", "Claude & GPT · Weekly", used: 12, resetHours: 164),
        ]),
        accountEmail: "jiakun@google-one.demo",
        planTier: "Google AI Ultra",
        promptCredits: 1850,
        flowCredits: 4200,
        flexCredits: 950
    )
    populateSessions(s)
    return s
}

struct SegmentedBar: View {
    let items: [(label: String, icon: String?)]
    let selected: Int
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                HStack(spacing: 3) {
                    if let ic = it.icon {
                        Image(systemName: ic).font(.system(size: 10.5, weight: .regular))
                    }
                    Text(it.label)
                        .font(.system(size: 11.5, weight: i == selected ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .foregroundColor(i == selected ? .primary : .secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(i == selected ? Color(nsColor: .controlColor) : .clear)
                        .shadow(color: .black.opacity(i == selected ? 0.12 : 0), radius: 1, y: 0.5)
                        .padding(1.5)
                )
            }
        }
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08)))
    }
}

struct DemoYearHeatmap: View {
    let year: Int
    let days: [String: Int]
    let loc: Localizer
    private let cell: CGFloat = 7, sp: CGFloat = 1
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 20, alignment: .leading).foregroundColor(.primary)
                Spacer()
                Text(String(year)).font(.system(size: 12, weight: .semibold)).foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 20, alignment: .trailing).foregroundColor(.primary).opacity(0.3)
            }
            Color.clear.frame(height: 12)
            let startMonday = TimeLogic.yearGridStartMonday(year: year)
            let yearPrefix = String(format: "%04d-", year)
            VStack(alignment: .leading, spacing: sp) {
                ForEach(0..<7, id: \.self) { row in
                    HStack(spacing: sp) {
                        ForEach(0..<53, id: \.self) { col in
                            let key = startMonday.flatMap { TimeLogic.dayKey(col: col, row: row, startMonday: $0) }
                            if let key = key, key.hasPrefix(yearPrefix) {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(YearHeatmap.levelColor(TimeLogic.heatLevel(days[key] ?? 0), dark: false))
                                    .frame(width: cell, height: cell)
                            } else {
                                Color.clear.frame(width: cell, height: cell)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 3) {
                Spacer()
                Text(loc("timeLess")).font(.system(size: 8)).foregroundColor(.secondary)
                ForEach(0..<5, id: \.self) { l in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(YearHeatmap.levelColor(l, dark: false)).frame(width: cell, height: cell)
                }
                Text(loc("timeMore")).font(.system(size: 8)).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
    }
}

struct DemoWeekTimeChart: View {
    @ObservedObject var store: UsageStore
    let timeData: TimeData
    let loc: Localizer

    private let rowHeight: CGFloat = 20
    private let labelWidth: CGFloat = 34
    private let totalWidth: CGFloat = 40
    private let gridHours = [0, 6, 12, 18, 24]

    private var monthPrefix: String {
        String(format: "%04d-%02d-", store.viewingYear, store.viewingMonth)
    }
    private var weeks: [Date] {
        TimeLogic.weeksOfMonth(year: store.viewingYear, month: store.viewingMonth)
    }
    private var selectedWeekIndex: Int? {
        store.resolvedWeekMonday.flatMap { TimeLogic.weekIndex(of: $0, in: weeks) }
    }
    private var dayKeys: [String] {
        store.resolvedWeekMonday.map(TimeLogic.weekDayKeys) ?? []
    }
    private var renderedDayKeys: [String] {
        TimeLogic.renderedDayKeys(dayKeys, monthPrefix: monthPrefix, days: timeData.days)
    }
    private var todayKey: String { AppDate.dayKey(Date()) }
    private var weekTotal: Int {
        TimeLogic.totalSeconds(in: timeData.days, dayKeys: renderedDayKeys)
    }
    private var avgDivisor: Int {
        TimeLogic.avgDivisor(dayKeys: dayKeys, todayKey: todayKey, renderedCount: renderedDayKeys.count)
    }
    private var weekdaySymbols: [String] {
        let df = DateFormatter()
        df.locale = Locale(identifier: loc.language.rawValue)
        let s = df.shortWeekdaySymbols ?? []
        guard s.count == 7 else { return ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] }
        return (0..<7).map { s[($0 + 1) % 7] }
    }

    private func shortDate(_ key: String) -> String {
        guard let d = TimeLogic.date(fromDayKey: key) else { return key }
        let cal = AppDate.gregorian
        return "\(cal.component(.month, from: d))/\(cal.component(.day, from: d))"
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundColor(.secondary)
            Text(value).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(.primary)
        }
    }

    var body: some View {
        let index = selectedWeekIndex
        let atFirst = (index ?? 0) <= 0
        let atLast = index.map { $0 >= weeks.count - 1 } ?? true
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 20, alignment: .leading)
                    .foregroundColor(.primary).opacity(atFirst ? 0.3 : 1)
                Spacer()
                Text("\(shortDate(dayKeys.first ?? "")) – \(shortDate(dayKeys.last ?? ""))")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 20, alignment: .trailing)
                    .foregroundColor(.primary).opacity(atLast ? 0.3 : 1)
            }
            HStack(spacing: 18) {
                stat(loc("timeWeekTotal"), TimeLogic.formatDurationShort(weekTotal))
                stat(loc("timeDailyAvg"), TimeLogic.formatDurationShort(weekTotal / avgDivisor))
                stat(loc("timeLongest"), TimeLogic.formatDurationShort(
                    TimeLogic.longestIntervalSeconds(in: timeData.days, dayKeys: renderedDayKeys)))
                Spacer()
            }
            Color.clear.frame(height: 12)
            VStack(spacing: 2) {
                ForEach(Array(dayKeys.enumerated()), id: \.element) { idx, key in
                    let inMonth = key.hasPrefix(monthPrefix)
                    let d = timeData.days[key]
                    let total = d?.totalSeconds ?? 0
                    let isToday = key == todayKey
                    HStack(spacing: 6) {
                        Text(weekdaySymbols.indices.contains(idx) ? weekdaySymbols[idx] : "")
                            .font(.system(size: 9, weight: isToday ? .semibold : .regular))
                            .foregroundColor(isToday ? .primary : .secondary)
                            .frame(width: labelWidth, alignment: .leading)
                        GeometryReader { geo in
                            let w = geo.size.width
                            ZStack(alignment: .leading) {
                                if !inMonth {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.primary.opacity(0.025))
                                        .frame(width: max(0, w - 2), height: rowHeight - 2)
                                        .offset(x: 1)
                                }
                                ForEach(gridHours, id: \.self) { h in
                                    Rectangle()
                                        .fill(Color.primary.opacity(0.07))
                                        .frame(width: 1)
                                        .offset(x: min(w - 1, w * CGFloat(h) / 24.0))
                                }
                                ForEach(Array((d?.intervals ?? []).enumerated()), id: \.offset) { _, iv in
                                    let capW = max(2, w * CGFloat(max(iv.durationSeconds, 120)) / 86400.0)
                                    let x = min(max(0, w * CGFloat(iv.startSec) / 86400.0), w - capW)
                                    Capsule()
                                        .fill(modelClassColor(iv.model).opacity(0.85))
                                        .frame(width: capW, height: 8)
                                        .offset(x: x)
                                }
                            }
                        }
                        .frame(height: rowHeight)
                        Text(inMonth || d != nil ? TimeLogic.formatDurationShort(total) : "")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(total > 0 ? .primary : .secondary.opacity(0.6))
                            .frame(width: totalWidth, alignment: .trailing)
                    }
                    .padding(.vertical, 1)
                    .background(isToday ? RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.04)) : nil)
                }
            }
            HStack(spacing: 6) {
                Color.clear.frame(width: labelWidth, height: 1)
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        ForEach(gridHours, id: \.self) { h in
                            Text("\(h)")
                                .font(.system(size: 8))
                                .foregroundColor(.secondary.opacity(0.7))
                                .position(x: min(max(w * CGFloat(h) / 24.0, 4), w - 7), y: 5)
                        }
                    }
                }
                .frame(height: 10)
                Color.clear.frame(width: totalWidth, height: 1)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
    }
}

struct DemoTimeTab: View {
    @ObservedObject var store: UsageStore
    let loc: Localizer
    var body: some View {
        VStack(spacing: 8) {
            SegmentedBar(items: TimeRange.allCases.map { ($0.label(loc), nil) },
                         selected: store.timeRange.rawValue)
            switch store.timeRange {
            case .week:  DemoWeekTimeChart(store: store, timeData: store.viewingTimeData!, loc: loc)
            case .month: MonthTimeChart(timeData: store.viewingTimeData!,
                                        year: store.viewingYear, month: store.viewingMonth)
            case .year:  DemoYearHeatmap(year: store.viewingTimeYear,
                                         days: store.yearTimeDays ?? [:], loc: loc)
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 6)
        .environment(\.localizer, loc)
    }
}

struct DemoPopover: View {
    @ObservedObject var store: UsageStore
    let loc: Localizer
    var bg: Color = Color(nsColor: .windowBackgroundColor)
    var notch: Bool = false
    private var visibleTabs: [DisplayTab] { [.cost, .tokens, .time, .session, .subscription] }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                DemoAGYLogoShape().fill(Color.agyBrand)
                    .frame(width: 14, height: 14)
                Text(loc("title")).font(.system(size: 13, weight: .bold)).foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 6)

            HStack {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28, alignment: .leading).foregroundColor(.primary)
                Spacer()
                Text(store.viewingMonthLabel).font(.system(size: 14, weight: .semibold)).foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28, alignment: .trailing).foregroundColor(.primary).opacity(0.3)
            }
            .padding(.horizontal, 14).padding(.bottom, 8)

            Group {
                if notch {
                    TabSelector(isNotch: true, items: visibleTabs,
                                selection: $store.selectedTab, label: { $0.label(loc) })
                } else {
                    SegmentedBar(items: visibleTabs.map { ($0.label(loc), $0.icon) },
                                 selected: visibleTabs.firstIndex(of: store.selectedTab) ?? 0)
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 8)

            content

            Divider().padding(.horizontal, 10)

            HStack(spacing: 12) {
                Text(String(format: loc("updated"), loc("justNow")))
                    .font(.system(size: 10.5)).foregroundColor(.secondary)
                Spacer()
                Image(systemName: "globe").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                Image(systemName: "ellipsis.circle").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                Image(systemName: "power").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: (store.selectedTab == .time || store.selectedTab == .session) ? 480 : 360)
        .background(bg)
        .environment(\.localizer, loc)
    }

    @ViewBuilder private var content: some View {
        if store.selectedTab == .time {
            DemoTimeTab(store: store, loc: loc)
        } else if store.selectedTab == .session {
            SessionTabView(sessionStore: store.sessionStore)
                .environment(\.localizer, loc)
        } else if store.selectedTab == .subscription {
            SubscriptionView(store: store)
        } else {
            VStack(spacing: 8) {
                PeriodCard(metric: store.selectedTab, icon: "calendar", title: loc("today"), usage: store.today!)
                PeriodCard(metric: store.selectedTab, icon: "calendar.badge.clock", title: loc("thisWeek"), usage: store.week!)
                PeriodCard(metric: store.selectedTab, icon: "chart.bar", title: loc("thisMonth"), usage: store.month!, showStats: true)
                DailyChart(data: store.dailyBreakdown!, mode: store.selectedTab, year: store.viewingYear, month: store.viewingMonth)
            }
            .padding(.horizontal, 10).padding(.bottom, 6)
        }
    }
}

struct DemoNotch: View {
    @ObservedObject var store: UsageStore
    let loc: Localizer

    private let menuBarHeight: CGFloat = 28

    private var wallpaper: some View {
        LinearGradient(
            colors: [
                Color(red: 0.05, green: 0.08, blue: 0.22),
                Color(red: 0.16, green: 0.24, blue: 0.56),
                Color(red: 0.31, green: 0.49, blue: 1.00),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var menuBar: some View {
        HStack(spacing: 16) {
            Image(systemName: "apple.logo")
            Text("Antigravity").fontWeight(.semibold)
            Spacer()
            Image(systemName: "battery.100")
            Image(systemName: "wifi")
            Text("Mon 16:30")
        }
        .font(.system(size: 12))
        .foregroundColor(.white.opacity(0.9))
        .padding(.horizontal, 16)
        .frame(height: menuBarHeight)
        .background(Color.black.opacity(0.24))
        .frame(maxHeight: .infinity, alignment: .top)
    }

    var body: some View {
        ZStack(alignment: .top) {
            wallpaper
            menuBar
            DemoPopover(store: store, loc: loc, bg: .clear, notch: true)
                .padding(.horizontal, 18)
                .padding(.top, menuBarHeight)
                .padding(.bottom, 14)
                .background(Color.black)
                .clipShape(NotchShape(topCornerRadius: 10, bottomCornerRadius: 22))
                .environment(\.colorScheme, .dark)
        }
        .frame(width: 720, height: 920)
    }
}

@MainActor
func render(_ name: String, _ view: some View, scale: CGFloat = 2) {
    let r = ImageRenderer(content: view)
    r.scale = scale
    guard let img = r.nsImage,
          let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("FAILED \(name)"); return
    }
    let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
        .appendingPathComponent("\(name).png")
    try? png.write(to: out)
    print("wrote \(name).png \(Int(img.size.width))x\(Int(img.size.height))")
}

@main
struct RenderApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let loc = Localizer(language: .en)
        render("cost", DemoPopover(store: makeStore(tab: .cost), loc: loc))
        render("tokens", DemoPopover(store: makeStore(tab: .tokens), loc: loc))
        render("plan", DemoPopover(store: makeStore(tab: .subscription), loc: loc))
        render("time-week", DemoPopover(store: makeStore(tab: .time, range: .week), loc: loc))
        render("time-month", DemoPopover(store: makeStore(tab: .time, range: .month), loc: loc))
        render("time-year", DemoPopover(store: makeStore(tab: .time, range: .year), loc: loc))
        render("session", DemoPopover(store: makeStore(tab: .session), loc: loc))
        render("notch", DemoNotch(store: makeStore(tab: .cost), loc: loc))
    }
}
