// Render real SwiftUI views to PNGs with synthetic data via ImageRenderer —
// pixel-faithful to the live AGY // TELEMETRY V2 UI. Mock data only.
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

func period(_ scale: Double) -> PeriodUsage {
    let models = [
        m("carbon",   "Carbon",   108.6 * scale, max(1, Int(390 * scale)), Int(9_200_000 * scale), Int(510_000 * scale), Int(64_200_000 * scale)),
        m("argon",    "Argon",     24.2 * scale, max(1, Int(112 * scale)), Int(2_250_000 * scale), Int(145_000 * scale), Int(12_800_000 * scale)),
        m("neon",     "Neon",      31.4 * scale, max(1, Int(148 * scale)), Int(2_850_000 * scale), Int(210_000 * scale), Int(16_400_000 * scale)),
        m("hydrogen", "Hydrogen",  56.8 * scale, max(1, Int(135 * scale)), Int(3_200_000 * scale), Int(310_000 * scale), Int(24_600_000 * scale)),
        m("flash",    "Flash",      4.2 * scale, max(1, Int(164 * scale)), Int(2_400_000 * scale), Int(140_000 * scale), Int(9_800_000 * scale)),
        m("claude",   "Claude",    34.8 * scale, max(1, Int(118 * scale)), Int(2_100_000 * scale), Int(190_000 * scale), Int(18_500_000 * scale)),
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
        let c = tk(0.42), a = tk(0.09), n = tk(0.13), h = tk(0.21), fl = tk(0.03), cl = tk(0.12)
        let mm = [
            m("carbon",   "Carbon",   v * 0.42, 0, c.0,  c.1,  c.2),
            m("argon",    "Argon",    v * 0.09, 0, a.0,  a.1,  a.2),
            m("neon",     "Neon",     v * 0.13, 0, n.0,  n.1,  n.2),
            m("hydrogen", "Hydrogen", v * 0.21, 0, h.0,  h.1,  h.2),
            m("flash",    "Flash",    v * 0.03, 0, fl.0, fl.1, fl.2),
            m("claude",   "Claude",   v * 0.12, 0, cl.0, cl.1, cl.2),
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
    let wd = cal.component(.weekday, from: today)
    let backToMon = (wd + 5) % 7
    let monday = cal.date(byAdding: .day, value: -backToMon, to: today)!
    let C = "carbon", A = "argon", N = "neon", H = "hydrogen", F = "flash", CL = "claude"
    let patterns: [[ActiveInterval]] = [
        [iv(9.2, 10.4, C), iv(10.8, 12.2, N), iv(14.1, 16.4, C), iv(21.0, 22.3, CL)],
        [iv(8.9, 9.4, F), iv(9.7, 12.5, C), iv(13.6, 14.3, A), iv(15.0, 18.0, H), iv(20.4, 21.2, N)],
        [iv(10.0, 10.6, A), iv(11.1, 13.0, C), iv(14.2, 17.6, H), iv(21.8, 23.0, CL)],
        [iv(9.1, 9.5, F), iv(9.8, 12.1, C), iv(13.1, 13.7, N), iv(14.3, 18.8, C)],
        [iv(8.6, 9.2, CL), iv(9.5, 11.7, H), iv(13.2, 16.9, C), iv(17.3, 17.9, F), iv(21.4, 23.2, N)],
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

func sess(_ pid: Int, _ id: String, _ cwd: String, _ status: SessionStatus,
          waitingFor: String? = nil, agoSec: Double, entrypoint: String = "cli",
          parentSessionId: String? = nil) -> SessionInfo {
    let now = Date().timeIntervalSince1970 * 1000
    return SessionInfo(pid: pid, sessionId: id, cwd: cwd, status: status,
                       waitingFor: waitingFor, startedAt: now - agoSec * 1000 - 7_200_000,
                       updatedAt: now - agoSec * 1000, statusUpdatedAt: now - agoSec * 1000,
                       version: "1.5.9", kind: nil, entrypoint: entrypoint,
                       isInternal: parentSessionId != nil, parentSessionId: parentSessionId)
}

@MainActor
func populateSessions(_ s: UsageStore) {
    let agym = "/Users/lijiakun/Developer/AGYMonitor"
    let mia  = "/Users/lijiakun/Developer/mia"
    let hf   = "/Users/lijiakun/Developer/hyperframes"
    s.sessionStore.sessions = [
        sess(6101, "a1aa0001-0000-0000-0000-000000000001", agym, .busy, agoSec: 38, entrypoint: "cli"),
        sess(6102, "a1aa0002-0000-0000-0000-000000000002", agym, .idle, agoSec: 5 * 60, entrypoint: "antigravity-ide",
             parentSessionId: "a1aa0001-0000-0000-0000-000000000001"),
        sess(6201, "b2bb0001-0000-0000-0000-000000000001", hf,   .waiting,
             waitingFor: "permission prompt", agoSec: 2 * 60, entrypoint: "cli"),
        sess(6202, "b2bb0002-0000-0000-0000-000000000002", hf,   .idle, agoSec: 44 * 60, entrypoint: "antigravity"),
        sess(6301, "c3cc0001-0000-0000-0000-000000000001", mia,  .idle, agoSec: 9 * 60, entrypoint: "cli"),
        sess(6302, "c3cc0002-0000-0000-0000-000000000002", mia,  .idle, agoSec: 2 * 3600, entrypoint: "antigravity-ide"),
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
func makeStore(
    tab: DisplayTab,
    range: TimeRange = .week,
    notch: Bool = false,
    preset: TelemetryThemePreset = .monolith,
    visualMode: TelemetryVisualMode = .instrument
) -> UsageStore {
    let s = UsageStore()
    let cal = Calendar(identifier: .gregorian)
    let now = cal.dateComponents([.year, .month], from: Date())
    s.language = .en
    s.themePreset = preset
    s.visualMode = visualMode
    s.displayMode = notch ? .notch : .menubar
    s.hasOAuthToken = true
    s.selectedTab = tab
    s.viewingYear = now.year!
    s.viewingMonth = now.month!
    s.viewingTimeYear = now.year!
    s.isLoading = false
    let tPeriod = period(0.14)
    let wPeriod = period(0.68)
    let mPeriod = period(1.0)
    let daily = dailyMock(year: now.year!, month: now.month!)
    let (td, year) = timeMock()
    s.today = tPeriod
    s.week = wPeriod
    s.month = mPeriod
    s.currentMonthData = mPeriod
    s.dailyBreakdown = daily
    s.lastUpdate = Date()
    s.currentTimeData = td
    s.viewingTimeData = td
    s.yearTimeDays = year
    s.timeRange = range
    s.currentMonthLoadPhase = .loaded(CurrentMonthBundle(
        today: tPeriod,
        week: wPeriod,
        month: mPeriod,
        dailyBreakdown: daily,
        time: td
    ))
    s.yearLoadPhase = .loaded(year)
    let quota = OAuthUsage(
        five_hour: OAuthUsageWindow(utilization: 22, resets_at: resetIn(2.4), label: "Gemini Models"),
        seven_day: OAuthUsageWindow(utilization: 64, resets_at: resetIn(3.8), label: "Claude & GPT · 5h"),
        extra_usage: nil,
        seven_day_sonnet: nil,
        limits: OAuthLimitList(items: [
            scopedCap("gemini_weekly", "Gemini · Weekly", used: 41, resetHours: 120),
            scopedCap("claude_partner_weekly", "Claude & GPT · Weekly", used: 12, resetHours: 144),
        ]),
        accountEmail: "jiakun@google-one.demo",
        planTier: "Google AI Ultra",
        promptCredits: 1850,
        flowCredits: 4200,
        flexCredits: 950
    )
    s.subscriptionQuota = quota
    s.quotaState = .ready(snapshot: quota, source: .live, updatedAt: Date(), notice: .none)
    populateSessions(s)
    return s
}

// MARK: - Pixel-faithful SwiftUI Popover Chrome (for ImageRenderer)

struct DemoPopover: View {
    @ObservedObject var store: UsageStore
    let loc: Localizer
    var dark: Bool = false
    var notch: Bool = false

    private var theme: AGYTheme {
        AGYTheme(preset: store.themePreset, colorScheme: dark || notch ? .dark : .light, isNotch: notch)
    }
    private var visibleTabs: [DisplayTab] { [.cost, .tokens, .time, .session, .subscription] }

    var body: some View {
        VStack(spacing: 0) {
            // Bare Header
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    DemoAGYLogoShape()
                        .fill(theme.accent)
                        .frame(width: 13.5, height: 13.5)
                    Text(loc("title").uppercased())
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .tracking(1.6)
                        .foregroundColor(theme.inkPrimary)

                    HStack(spacing: 4) {
                        Rectangle()
                            .fill(theme.signalAmber)
                            .frame(width: 4.5, height: 4.5)
                            .rotationEffect(.degrees(45))
                        Text(String(format: loc("waitTagFmt"), 1))
                            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                            .tracking(0.4)
                            .foregroundColor(theme.signalAmber)
                    }
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 2)
                    .background(theme.signalAmber.opacity(theme.isDark ? 0.12 : 0.08))
                    .overlay(Rectangle().stroke(theme.signalAmber.opacity(0.48), lineWidth: 0.75))
                }

                Spacer(minLength: 4)

                headerAccessory
            }
            .padding(.horizontal, 14)
            .padding(.top, 11)
            .padding(.bottom, 9)

            // Full-bleed Grid Tab Bar
            TelemetryTabBar(
                items: visibleTabs,
                selection: $store.selectedTab,
                sessionStore: store.sessionStore,
                loc: loc
            )

            // Live production SwiftUI content
            Group {
                switch store.selectedTab {
                case .cost, .tokens:
                    UsageOverviewSection(store: store)
                case .time:
                    TimeTabView(store: store)
                case .session:
                    SessionTabView(sessionStore: store.sessionStore, visualMode: store.visualMode)
                case .subscription:
                    SubscriptionView(store: store)
                }
            }

            HairlineRule(showCrosshairs: true)

            // Bare Statusline Footer
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Text(String(format: loc("updated"), loc("justNow")).uppercased())
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.inkSecondary)
                    Text("· ⌘R · ⌘T · ⌘I")
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.inkMuted)
                }
                Spacer()
                HStack(spacing: 4) {
                    Text("EN")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.inkSecondary)
                        .frame(width: 26, height: 22)
                    Rectangle().fill(theme.hairline).frame(width: 1, height: 11)
                    demoBareIcon("ellipsis")
                    Rectangle().fill(theme.hairline).frame(width: 1, height: 11)
                    demoBareIcon("arrow.clockwise")
                    Rectangle().fill(theme.hairline).frame(width: 1, height: 11)
                    demoBareIcon("power")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .frame(width: AGYTheme.panelWidth)
        .background(
            ZStack {
                notch ? Color.clear : theme.canvas
                ArchivalGrainOverlay()
            }
        )
        .environment(\.localizer, loc)
        .environment(\.agyTheme, theme)
        .environment(\.telemetryStaticRender, true)
        .environment(\.colorScheme, (dark || notch) ? .dark : .light)
    }

    @ViewBuilder
    private var headerAccessory: some View {
        switch store.selectedTab {
        case .cost, .tokens:
            TelemetryStepper(
                label: store.viewingMonthCompactLabel,
                canDecrement: true,
                canIncrement: false,
                onDecrement: {},
                onIncrement: {}
            )
        case .time:
            TelemetryStepper(
                label: store.timeRange == .year ? String(store.viewingTimeYear) : store.viewingMonthCompactLabel,
                canDecrement: true,
                canIncrement: false,
                onDecrement: {},
                onIncrement: {}
            )
        case .session:
            Text(String(format: loc("liveTagFmt"), store.sessionStore.liveCount))
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.inkSecondary)
        case .subscription:
            HStack(spacing: 4) {
                DemoAGYLogoShape().fill(theme.accent).frame(width: 8, height: 8)
                Text("GOOGLE AI ULTRA")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.accent)
            }
        }
    }

    private func demoBareIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundColor(theme.inkSecondary)
            .frame(width: 24, height: 22)
    }
}

struct DemoNotch: View {
    @ObservedObject var store: UsageStore
    let loc: Localizer

    private let menuBarHeight: CGFloat = 28

    private var wallpaper: some View {
        LinearGradient(
            colors: [
                Color(red: 0.02, green: 0.04, blue: 0.12),
                Color(red: 0.08, green: 0.14, blue: 0.36),
                Color(red: 0.19, green: 0.34, blue: 0.78),
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
        .background(Color.black.opacity(0.28))
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var liveWingPreview: some View {
        let vm = NotchViewModel()
        vm.closedNotchSize = CGSize(width: 185, height: 28)
        vm.activeWing = .waiting(
            sessionId: "b2bb0001-0000-0000-0000-000000000001",
            workspace: "hyperframes",
            surface: "CLI",
            needsConfirm: true
        )
        return VStack(spacing: 5) {
            Text("LIVE WING // ALERT STATE")
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .tracking(0.8)
                .foregroundColor(.white.opacity(0.75))
            CompactNotchView(
                store: store,
                sessionStore: store.sessionStore,
                vm: vm,
                notchWidth: 185,
                notchHeight: 28
            )
            .environment(\.telemetryStaticRender, true)
            .background(Color.black)
            .overlay(
                NotchShape(topCornerRadius: 6, bottomCornerRadius: 11)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .clipShape(NotchShape(topCornerRadius: 6, bottomCornerRadius: 11))
        }
    }

    var body: some View {
        let shape = NotchShape(topCornerRadius: 11, bottomCornerRadius: 20)
        ZStack(alignment: .top) {
            wallpaper
            menuBar
            VStack(spacing: 14) {
                DemoPopover(store: store, loc: loc, dark: true, notch: true)
                    .padding(.horizontal, 18)
                    .padding(.top, menuBarHeight + 4)
                    .padding(.bottom, 14)
                    .background(Color.black)
                    .overlay(shape.stroke(Color.white.opacity(0.14), lineWidth: 1))
                    .clipShape(shape)
                    .environment(\.colorScheme, .dark)

                liveWingPreview
                    .environment(\.colorScheme, .dark)
            }
        }
        .frame(width: 720, height: 760)
    }
}

@MainActor
func render(_ name: String, _ view: some View, to dir: String, scale: CGFloat = 2) {
    let r = ImageRenderer(content: view)
    r.scale = scale
    guard let img = r.nsImage,
          let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("FAILED \(name)"); return
    }
    let out = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
    try? png.write(to: out)
    print("wrote \(name).png \(Int(img.size.width))x\(Int(img.size.height))")
}

@main
struct RenderApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let loc = Localizer(language: .en)
        let args = Array(CommandLine.arguments.dropFirst())

        if let themeIdx = args.firstIndex(of: "--themes"), themeIdx + 1 < args.count {
            let dir = args[themeIdx + 1]
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for preset in TelemetryThemePreset.allCases {
                render("theme-\(preset.rawValue)-light",
                       DemoPopover(store: makeStore(tab: .cost, preset: preset), loc: loc, dark: false),
                       to: dir)
                render("theme-\(preset.rawValue)-dark",
                       DemoPopover(store: makeStore(tab: .cost, preset: preset), loc: loc, dark: true),
                       to: dir)
            }
            return
        }

        if let classicIdx = args.firstIndex(of: "--classic"), classicIdx + 1 < args.count {
            let dir = args[classicIdx + 1]
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            render("classic-cost", DemoPopover(store: makeStore(tab: .cost, visualMode: .classic), loc: loc), to: dir)
            render("classic-tokens", DemoPopover(store: makeStore(tab: .tokens, visualMode: .classic), loc: loc), to: dir)
            render("classic-plan", DemoPopover(store: makeStore(tab: .subscription, visualMode: .classic), loc: loc), to: dir)
            render("classic-time-week", DemoPopover(store: makeStore(tab: .time, range: .week, visualMode: .classic), loc: loc), to: dir)
            render("classic-time-year", DemoPopover(store: makeStore(tab: .time, range: .year, visualMode: .classic), loc: loc), to: dir)
            render("classic-session", DemoPopover(store: makeStore(tab: .session, visualMode: .classic), loc: loc), to: dir)
            return
        }

        if let darkIdx = args.firstIndex(of: "--dark-instruments"), darkIdx + 1 < args.count {
            let dir = args[darkIdx + 1]
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            render("dark-cost-blueprint", DemoPopover(store: makeStore(tab: .cost, preset: .blueprint), loc: loc, dark: true), to: dir)
            render("dark-tokens-phosphor", DemoPopover(store: makeStore(tab: .tokens, preset: .phosphor), loc: loc, dark: true), to: dir)
            render("dark-plan-amber", DemoPopover(store: makeStore(tab: .subscription, preset: .amber), loc: loc, dark: true), to: dir)
            render("dark-time-week-phosphor", DemoPopover(store: makeStore(tab: .time, range: .week, preset: .phosphor), loc: loc, dark: true), to: dir)
            render("dark-time-year-blueprint", DemoPopover(store: makeStore(tab: .time, range: .year, preset: .blueprint), loc: loc, dark: true), to: dir)
            render("dark-session-monolith", DemoPopover(store: makeStore(tab: .session, preset: .monolith), loc: loc, dark: true), to: dir)
            return
        }

        let dir = args.first ?? "."
        render("cost", DemoPopover(store: makeStore(tab: .cost), loc: loc), to: dir)
        render("tokens", DemoPopover(store: makeStore(tab: .tokens), loc: loc), to: dir)
        render("plan", DemoPopover(store: makeStore(tab: .subscription), loc: loc), to: dir)
        render("time-week", DemoPopover(store: makeStore(tab: .time, range: .week), loc: loc), to: dir)
        render("time-month", DemoPopover(store: makeStore(tab: .time, range: .month), loc: loc), to: dir)
        render("time-year", DemoPopover(store: makeStore(tab: .time, range: .year), loc: loc), to: dir)
        render("session", DemoPopover(store: makeStore(tab: .session), loc: loc), to: dir)
        render("notch", DemoNotch(store: makeStore(tab: .cost, notch: true), loc: loc), to: dir)
    }
}
