import Foundation
import Combine

// MARK: - Data Store

class UsageStore: ObservableObject {
    @Published var today: PeriodUsage?
    @Published var week: PeriodUsage?
    @Published var month: PeriodUsage?
    @Published var isLoading = true
    @Published var lastUpdate: Date?
    @Published var currentMonthLoadPhase: LoadPhase<CurrentMonthBundle> = .loading(cached: nil)
    @Published var historicalMonthLoadPhase: LoadPhase<HistoricalMonthBundle> = .idle
    @Published var yearLoadPhase: LoadPhase<[String: Int]> = .idle
    @Published var selectedTab: DisplayTab = .cost {
        didSet {
            guard selectedTab != oldValue else { return }
            syncActiveLoadingFlag()
            guard selectedTab == .subscription else { return }
            if QuotaStateReducer.shouldAutoRefreshOnTabEntry(
                phase: quotaState,
                cooldownUntil: SubscriptionQuotaService.shared.rateLimitCooldownUntil,
                now: Date()
            ) {
                DispatchQueue.main.async { [weak self] in
                    self?.refreshQuota(force: true)
                }
            }
        }
    }

    // Month navigation
    @Published var viewingYear: Int {
        didSet {
            guard !isSyncingMonthNav else { return }
            monthNav.setViewing(year: viewingYear, month: viewingMonth)
            syncActiveLoadingFlag()
        }
    }
    @Published var viewingMonth: Int {
        didSet {
            guard !isSyncingMonthNav else { return }
            monthNav.setViewing(year: viewingYear, month: viewingMonth)
            syncActiveLoadingFlag()
        }
    }

    // Always holds current month data (for menu bar, unaffected by navigation)
    @Published var currentMonthData: PeriodUsage?
    @Published var dailyBreakdown: [DailyUsage]?

    // MARK: Active time ("Time" tab)

    @Published var currentTimeData: TimeData?
    @Published var viewingTimeData: TimeData?
    @Published var timeTodaySeconds: Int = 0
    @Published var timeRange: TimeRange = .week {
        didSet {
            guard timeRange != oldValue else { return }
            syncActiveLoadingFlag()
        }
    }
    @Published var viewingTimeYear: Int
    @Published var selectedWeekMonday: Date?
    @Published var yearTimeDays: [String: Int]?
    private var yearTimeCache: [Int: [String: Int]] = [:]

    // Localization
    @Published var language: AppLanguage

    /// Durable local archive toggle (default on), stored in Application Support/AGYMonitor/archive/.
    @Published var archiveHistoryLocally: Bool = true

    /// Idle icon+value placement: menu bar (default) or MacBook notch.
    @Published var displayMode: DisplayMode = .menubar

    /// Selected Hero period scope inside Cost / Tokens tabs (Today / Week / Month).
    @Published var selectedPeriodScope: UsagePeriodScope = .today

    /// Menu-bar / compact-notch readout preference.
    @Published var menuBarMetric: MenuBarMetricPreference = .followTab

    /// Whether global hotkey (⌥⇧A) is active.
    @Published var globalHotkeyEnabled: Bool = true

    /// Switchable Swiss Telemetry theme preset (`⌘T` cycles presets).
    @Published var themePreset: TelemetryThemePreset = .monolith

    /// Switchable chart visualization style: scientific Instruments (default) vs Classic.
    @Published var visualMode: TelemetryVisualMode = .instrument

    /// Whether the popover or notch drawer is currently visible on screen.
    /// Gates all live panel animations (TimelineView) so hidden panels run at 0 Hz.
    @Published var isPanelVisible: Bool = false

    // MARK: Live sessions ("Sessions" tab)

    let sessionStore = SessionStore()

    // MARK: App Updates (GitHub Releases + one-time system notification)

    let updateService = UpdateService()

    // MARK: Plan / Quota & AI Credits ("Plan" tab)

    @Published var quotaState: QuotaPhase<OAuthUsage> = .noAccount
    @Published var subscriptionQuota: OAuthUsage?
    @Published var hasOAuthToken: Bool = false {
        didSet {
            if !hasOAuthToken && selectedTab == .subscription {
                selectedTab = .cost
            }
        }
    }
    @Published var quotaError: QuotaError?
    @Published var quotaUpdatedAt: Date?
    @Published var quotaRetryAt: Date?

    /// Notified whenever a refresh starts or is explicitly requested (keeps AppDelegate
    /// FSEvents throttle aligned across ⌘R, wake, popover open, and timer ticks).
    var onRefreshTriggered: ((Date) -> Void)?

    /// Antigravity's three local brain roots across CLI, Desktop, and IDE surfaces.
    static func brainDirectories(home: String = NSHomeDirectory()) -> [String] {
        AGYLocator.brainDirs(home: home)
    }

    var isCurrentMonth: Bool {
        monthNav.isViewingCurrentMonth()
    }

    var effectiveCurrentMonthPhase: LoadPhase<CurrentMonthBundle> {
        if (currentMonthLoadPhase == .idle || currentMonthLoadPhase == .loading(cached: nil)),
           !isLoading,
           let t = today, let w = week, let m = month {
            return .loaded(CurrentMonthBundle(
                today: t, week: w, month: m, dailyBreakdown: dailyBreakdown, time: currentTimeData
            ))
        }
        return currentMonthLoadPhase
    }

    var effectiveHistoricalMonthPhase: LoadPhase<HistoricalMonthBundle> {
        if (historicalMonthLoadPhase == .idle || historicalMonthLoadPhase == .loading(cached: nil)),
           !isLoading,
           let m = month {
            return .loaded(HistoricalMonthBundle(
                month: m, dailyBreakdown: dailyBreakdown, time: viewingTimeData
            ))
        }
        return historicalMonthLoadPhase
    }

    var effectiveYearPhase: LoadPhase<[String: Int]> {
        if (yearLoadPhase == .idle || yearLoadPhase == .loading(cached: nil)),
           let days = yearTimeDays {
            return .loaded(days)
        }
        return yearLoadPhase
    }

    var effectiveQuotaPhase: QuotaPhase<OAuthUsage> {
        if (quotaState == .noAccount || quotaState == .loading),
           let sub = subscriptionQuota {
            let notice: QuotaRefreshNotice = quotaError.map {
                $0 == .rateLimited ? .rateLimited(retryAt: quotaRetryAt) : .staleError($0)
            } ?? .none
            return .ready(
                snapshot: sub,
                source: sub.isOfflineCached ? .offlineCache : .live,
                updatedAt: quotaUpdatedAt,
                notice: notice
            )
        }
        return quotaState
    }

    private static let monthLabelLock = NSLock()
    private static var monthLabelFormatters: [String: DateFormatter] = [:]

    var viewingMonthLabel: String {
        var comps = DateComponents()
        comps.year = viewingYear
        comps.month = viewingMonth
        comps.day = 1
        guard let date = AppDate.gregorian.date(from: comps) else { return "" }
        let localeId = language.rawValue
        Self.monthLabelLock.lock()
        defer { Self.monthLabelLock.unlock() }
        let df: DateFormatter
        if let cached = Self.monthLabelFormatters[localeId] {
            df = cached
        } else {
            let created = DateFormatter()
            created.calendar = AppDate.gregorian
            created.dateFormat = "MMMM yyyy"
            created.locale = Locale(identifier: localeId)
            Self.monthLabelFormatters[localeId] = created
            df = created
        }
        return df.string(from: date)
    }

    var viewingMonthCompactLabel: String {
        String(format: "%04d.%02d", viewingYear, viewingMonth)
    }

    var canDisplayMenuBarValue: Bool {
        MenuBarAnchorState.shouldPublishMenuBarValue(
            metric: menuBarMetric,
            tabRawValue: selectedTab.rawValue,
            hasTodayData: today != nil,
            hasCurrentMonthData: currentMonthData != nil,
            hasSubscriptionQuota: subscriptionQuota != nil
        )
    }

    /// Menu-bar / compact-notch value string respecting `menuBarMetric`.
    var menuBarValue: String {
        switch menuBarMetric {
        case .followTab:
            return followTabMenuBarValue
        case .todayCost:
            if let t = today { return formatCost(t.cost) }
            if let m = currentMonthData { return formatCost(m.cost) }
            return "…"
        case .quota5h:
            if let q = subscriptionQuota {
                let rem = max(0, 100 - q.five_hour.displayPercent)
                return q.five_hour.resets_at != nil ? "5h \(rem)%" : "\(rem)%"
            }
            return "—"
        case .liveSessions:
            let count = sessionStore.liveCount
            if sessionStore.anyWaiting { return "▲\(count)" }
            if sessionStore.anyBusy { return "▸\(count)" }
            return "\(count)"
        case .costAndQuota:
            let costStr = (today.map { formatCost($0.cost) } ?? currentMonthData.map { formatCost($0.cost) })
            let quotaStr = subscriptionQuota.map { "\(max(0, 100 - $0.five_hour.displayPercent))%" }
            if let c = costStr, let q = quotaStr { return "\(c) · \(q)" }
            return costStr ?? quotaStr ?? "…"
        }
    }

    private var followTabMenuBarValue: String {
        switch selectedTab {
        case .cost:
            guard let monthData = currentMonthData else { return "…" }
            return formatCost(monthData.cost)
        case .tokens:
            guard let monthData = currentMonthData else { return "…" }
            return formatTokensShort(monthData.totalTokens)
        case .subscription:
            if let q = subscriptionQuota {
                let rem = max(0, 100 - q.five_hour.displayPercent)
                return q.five_hour.resets_at != nil ? "5h \(rem)%" : "\(rem)%"
            }
            guard let monthData = currentMonthData else { return "…" }
            return formatCost(monthData.cost)
        case .time:
            guard currentMonthData != nil || currentTimeData != nil else { return "…" }
            return TimeLogic.formatDurationShort(timeTodaySeconds)
        case .session:
            if sessionStore.anyWaiting { return "▲\(sessionStore.liveCount)" }
            return sessionStore.anyBusy ? "▸\(sessionStore.liveCount)" : "\(sessionStore.liveCount)"
        }
    }

    private let scriptClient = UsageScriptClient()
    private let archive = UsageArchive()

    private let scriptQueue = DispatchQueue(label: "com.kuen54.AGYMonitor.scripts", qos: .utility)
    private var historicalLoadGate = HistoricalMonthLoadGate()
    private var refreshQueue = RefreshQueueState()
    private var monthNav: MonthNavigationState
    private var yearLoadGate = YearLoadGate()
    private var archiveSweepGate = ArchiveSweepGate()
    private var isSyncingMonthNav = false

    private var lastScanFingerprint: String?
    private var lastScanResults: ScanResults?

    private struct ScanResults {
        let today: PeriodUsage
        let week: PeriodUsage
        let month: PeriodUsage
        let daily: [DailyUsage]?
        let time: TimeData?
    }

    /// Snapshot cache directory: ~/Library/Caches/AGYMonitor/snapshots/
    private var cacheDir: String {
        let root = AGYLocator.cacheDir(home: NSHomeDirectory())
        let dir = (root as NSString).appendingPathComponent("snapshots")
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: nil)
        return dir
    }

    init() {
        let nav = MonthNavigationState()
        monthNav = nav
        viewingYear = nav.viewingYear
        viewingMonth = nav.viewingMonth
        viewingTimeYear = nav.viewingYear

        if let saved = UserDefaults.standard.string(forKey: "appLanguage"),
           let lang = AppLanguage(rawValue: saved) {
            language = lang
        } else {
            language = AppLanguage.fromSystem()
        }

        if UserDefaults.standard.object(forKey: "archiveHistoryLocally") != nil {
            archiveHistoryLocally = UserDefaults.standard.bool(forKey: "archiveHistoryLocally")
        }

        if let savedMode = UserDefaults.standard.string(forKey: "displayMode"),
           let mode = DisplayMode(rawValue: savedMode) {
            displayMode = mode
        }

        if let savedMetric = UserDefaults.standard.string(forKey: "menuBarMetric"),
           let metric = MenuBarMetricPreference(rawValue: savedMetric) {
            menuBarMetric = metric
        }

        if UserDefaults.standard.object(forKey: "globalHotkeyEnabled") != nil {
            globalHotkeyEnabled = UserDefaults.standard.bool(forKey: "globalHotkeyEnabled")
        }

        if let savedTheme = UserDefaults.standard.string(forKey: "themePreset"),
           let preset = TelemetryThemePreset(rawValue: savedTheme) {
            themePreset = preset
        }

        if let savedVisual = UserDefaults.standard.string(forKey: "visualMode"),
           let visual = TelemetryVisualMode(rawValue: savedVisual) {
            visualMode = visual
        }

        let initialToken = SubscriptionQuotaService.shared.hasOAuthToken
        applyQuotaEvent(.tokenPresenceChanged(initialToken))

        updateService.languageProvider = { [weak self] in
            self?.language ?? .en
        }
    }

    func startUpdateChecking() {
        updateService.start()
    }

    func stopUpdateChecking() {
        updateService.stop()
    }

    func handleSystemWakeForUpdates() {
        updateService.handleWake()
    }

    func checkForUpdatesManually() {
        updateService.checkForUpdatesManually()
    }

    private func applyQuotaEvent(_ event: QuotaStateEvent<OAuthUsage>) {
        let next = QuotaStateReducer.reduce(quotaState, event: event)
        if quotaState != next { quotaState = next }
        let nextHasAccount = next.hasAccountSurface
        if hasOAuthToken != nextHasAccount { hasOAuthToken = nextHasAccount }
        if subscriptionQuota != next.snapshot { subscriptionQuota = next.snapshot }
        if quotaError != next.error { quotaError = next.error }
        if quotaUpdatedAt != next.updatedAt { quotaUpdatedAt = next.updatedAt }
        if quotaRetryAt != next.retryAt { quotaRetryAt = next.retryAt }
        syncActiveLoadingFlag()
    }

    /// Reconciles expired HTTP 429 cooldowns so the Plan tab banner & Retry button
    /// recover immediately once `retryAt` passes.
    func reconcileQuotaCooldown(now: Date = Date()) {
        applyQuotaEvent(.cooldownExpired(now: now))
    }

    private func syncActiveLoadingFlag() {
        let active: Bool
        if selectedTab == .subscription {
            active = (quotaState == .loading)
        } else if selectedTab == .time && timeRange == .year {
            active = yearLoadPhase.isLoading
        } else {
            active = isCurrentMonth ? currentMonthLoadPhase.isLoading : historicalMonthLoadPhase.isLoading
        }
        if isLoading != active { isLoading = active }
    }

    /// Fetch Antigravity plan quota & AI Credits and update @Published state.
    func refreshQuota(force: Bool = false) {
        let probedHasToken = force
            ? SubscriptionQuotaService.shared.probeTokenPresenceNow()
            : SubscriptionQuotaService.shared.hasOAuthToken
        if !probedHasToken {
            applyQuotaEvent(.tokenPresenceChanged(false))
            return
        }
        applyQuotaEvent(.tokenPresenceChanged(true))
        applyQuotaEvent(.beginFetch)
        SubscriptionQuotaService.shared.fetch(forceRefresh: force) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let now = Date()
                switch result {
                case .success(let quota):
                    let source: QuotaSource = quota.isOfflineCached ? .offlineCache : .live
                    let at = SubscriptionQuotaService.shared.lastSuccessAt ?? now
                    self.applyQuotaEvent(.fetched(quota, source: source, at: at, notice: .none))
                case .fallbackWithNotice(let quota, let err, let retryAt):
                    let at = SubscriptionQuotaService.shared.lastSuccessAt ?? now
                    let notice: QuotaRefreshNotice = (err == .rateLimited)
                        ? .rateLimited(retryAt: retryAt)
                        : .staleError(err)
                    self.applyQuotaEvent(.fetched(quota, source: .offlineCache, at: at, notice: notice))
                case .noToken:
                    self.applyQuotaEvent(.tokenPresenceChanged(false))
                case .unauthorized:
                    self.applyQuotaEvent(.fetchFailed(.unauthorized, retryAt: nil, at: now))
                case .rateLimited:
                    let retryAt = SubscriptionQuotaService.shared.rateLimitCooldownUntil
                    self.applyQuotaEvent(.fetchFailed(.rateLimited, retryAt: retryAt, at: now))
                case .networkFailure:
                    self.applyQuotaEvent(.fetchFailed(.networkFailure, retryAt: nil, at: now))
                case .decodeFailure:
                    self.applyQuotaEvent(.fetchFailed(.decodeFailure, retryAt: nil, at: now))
                }
            }
        }
    }

    func setLanguage(_ lang: AppLanguage) {
        language = lang
        UserDefaults.standard.set(lang.rawValue, forKey: "appLanguage")
    }

    func setDisplayMode(_ mode: DisplayMode) {
        guard displayMode != mode else { return }
        displayMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "displayMode")
    }

    func setMenuBarMetric(_ metric: MenuBarMetricPreference) {
        guard menuBarMetric != metric else { return }
        menuBarMetric = metric
        UserDefaults.standard.set(metric.rawValue, forKey: "menuBarMetric")
    }

    func setGlobalHotkeyEnabled(_ enabled: Bool) {
        guard globalHotkeyEnabled != enabled else { return }
        globalHotkeyEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "globalHotkeyEnabled")
    }

    func setPeriodScope(_ scope: UsagePeriodScope) {
        guard selectedPeriodScope != scope else { return }
        selectedPeriodScope = scope
    }

    func setThemePreset(_ preset: TelemetryThemePreset) {
        guard themePreset != preset else { return }
        themePreset = preset
        UserDefaults.standard.set(preset.rawValue, forKey: "themePreset")
    }

    func cycleThemePreset() {
        setThemePreset(themePreset.next)
    }

    func setVisualMode(_ mode: TelemetryVisualMode) {
        guard visualMode != mode else { return }
        visualMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "visualMode")
    }

    func toggleVisualMode() {
        setVisualMode(visualMode.toggled)
    }

    // MARK: - Live session monitoring (forwarded to sessionStore)

    func startSessionMonitoring() { sessionStore.startMonitoring() }
    func setSessionMonitorActive(_ active: Bool) {
        if isPanelVisible != active {
            isPanelVisible = active
        }
        sessionStore.setActive(active)
    }
    func stopSessionMonitoring() { sessionStore.stopMonitoring() }

    // MARK: - Local archive (durable history)

    func setArchiveHistoryLocally(_ on: Bool) {
        guard archiveHistoryLocally != on else { return }
        archiveHistoryLocally = on
        UserDefaults.standard.set(on, forKey: "archiveHistoryLocally")
        yearTimeCache.removeAll()
        yearLoadGate.invalidateAll()
        if on {
            archiveSweepIfNeeded(force: true)
        } else {
            archiveSweepGate.reset()
        }
        republishAfterArchiveChange()
    }

    func clearArchive() {
        archiveSweepGate.reset()
        UserDefaults.standard.removeObject(forKey: "archiveSweptThrough")
        yearTimeCache.removeAll()
        yearLoadGate.invalidateAll()
        archive.clear()
        republishAfterArchiveChange()
    }

    var archivedDayCount: Int { archive.dayCount }

    private func republishAfterArchiveChange() {
        if !isCurrentMonth { loadHistoricalMonth(force: false) }
        if selectedTab == .time && timeRange == .year {
            loadYearTime(viewingTimeYear, force: true)
        }
    }

    private func archiveOverlayHistorical(
        month: PeriodUsage?, daily: [DailyUsage]?, time: TimeData?, yearMonth: String
    ) -> (PeriodUsage?, [DailyUsage]?, TimeData?) {
        guard archiveHistoryLocally else { return (month, daily, time) }
        let (archivedDaily, archivedTimeDays) = archive.overlay(
            mergingDaily: daily, time: time, yearMonth: yearMonth)
        let finalDaily = archivedDaily.isEmpty ? daily : archivedDaily
        let finalTime: TimeData? = archivedTimeDays.isEmpty
            ? time
            : TimeData(gapMinutes: time?.gapMinutes ?? 10, days: archivedTimeDays)
        let finalMonth: PeriodUsage? = (finalDaily?.isEmpty == false)
            ? UsageParser.mergeDailyUsages(finalDaily!)
            : month
        return (finalMonth, finalDaily, finalTime)
    }

    func archiveSweepIfNeeded(force: Bool = false) {
        guard let sweepGen = archiveSweepGate.beginSweep(
            force: force,
            enabled: archiveHistoryLocally
        ) else { return }
        let cal = AppDate.gregorian
        let now = Date()
        let todayKey = AppDate.dayKey(now)
        let startKey: String
        if let hwm = UserDefaults.standard.string(forKey: "archiveSweptThrough"),
           let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: now) {
            startKey = min(hwm, AppDate.dayKey(twoDaysAgo))
        } else if let wide = cal.date(byAdding: .day, value: -200, to: now) {
            startKey = AppDate.dayKey(wide)
        } else {
            startKey = todayKey
        }
        scriptQueue.async { [weak self] in
            guard let self = self else { return }
            let range = "\(startKey):\(todayKey)"
            let json = self.scriptClient.runScript(["--json", "--no-sessions", "--range", range])
            let daily = json.flatMap { UsageParser.parseAllDailyBreakdown($0) }
            let time = json.flatMap { UsageParser.parseTimeSection($0) }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // Only commit & advance watermark if this sweep was NOT invalidated mid-flight
                // by `clearArchive()` or toggling `archiveHistoryLocally` off.
                guard self.archiveSweepGate.finish(generation: sweepGen, succeeded: json != nil),
                      self.archiveHistoryLocally,
                      json != nil else { return }
                self.archive.merge(daily: daily, time: time)
                UserDefaults.standard.set(todayKey, forKey: "archiveSweptThrough")
            }
        }
    }

    // MARK: - Navigation

    func navigateMonth(offset: Int) {
        guard monthNav.navigate(offset: offset) else { return }
        isSyncingMonthNav = true
        viewingYear = monthNav.viewingYear
        viewingMonth = monthNav.viewingMonth
        isSyncingMonthNav = false

        selectedWeekMonday = nil
        historicalLoadGate.invalidate()

        if isCurrentMonth {
            refresh()
        } else {
            loadHistoricalMonth(force: false)
        }
        syncActiveLoadingFlag()
    }

    func loadHistoricalMonth(force: Bool = false) {
        let y = viewingYear, m = viewingMonth
        let ym = String(format: "%04d-%02d", y, m)
        if !force,
           let snapshot = loadCacheSnapshot(year: y, month: m),
           snapshot.dailyBreakdown != nil, snapshot.time != nil,
           SnapshotFreshnessPolicy.isCompleteHistoricalSnapshot(
               year: y, month: m, lastUpdated: snapshot.lastUpdated
           ) {
            historicalLoadGate.invalidate()
            let (om, od, ot) = archiveOverlayHistorical(
                month: snapshot.data, daily: snapshot.dailyBreakdown,
                time: snapshot.time, yearMonth: ym)
            let phase = UsageStateLogic.classifyHistoricalMonth(
                month: om, dailyBreakdown: od, time: ot, scriptSucceeded: true, cached: nil)
            self.historicalMonthLoadPhase = phase
            self.today = nil
            self.week = nil
            self.month = phase.value?.month
            self.dailyBreakdown = phase.value?.dailyBreakdown
            self.viewingTimeData = phase.value?.time
            self.syncActiveLoadingFlag()
            return
        }
        guard let generation = historicalLoadGate.beginLoad(yearMonth: ym, force: force) else {
            return
        }
        historicalMonthLoadPhase = force
            ? historicalMonthLoadPhase.transitioningToLoading()
            : .loading(cached: nil)
        syncActiveLoadingFlag()
        scriptQueue.async { [weak self] in
            guard let self = self else { return }
            let range = AppDate.monthDateRange(year: y, month: m)
            let (data, daily, time) = self.fetchMonthData(range, yearMonth: ym)
            DispatchQueue.main.async {
                self.historicalLoadGate.completeLoad(generation: generation)
                let currentYM = String(format: "%04d-%02d", self.viewingYear, self.viewingMonth)
                guard self.historicalLoadGate.isCurrent(
                    generation: generation, yearMonth: ym, currentYearMonth: currentYM
                ) else { return }
                let phase: LoadPhase<HistoricalMonthBundle>
                if let data = data {
                    self.saveCache(year: y, month: m, data: data, daily: daily, time: time)
                    let (om, od, ot) = self.archiveOverlayHistorical(
                        month: data, daily: daily, time: time, yearMonth: ym)
                    phase = UsageStateLogic.classifyHistoricalMonth(
                        month: om, dailyBreakdown: od, time: ot,
                        scriptSucceeded: true, cached: self.historicalMonthLoadPhase.value)
                } else {
                    phase = UsageStateLogic.classifyHistoricalMonth(
                        month: nil, dailyBreakdown: nil, time: nil,
                        scriptSucceeded: false, cached: self.historicalMonthLoadPhase.value)
                }
                self.historicalMonthLoadPhase = phase
                self.today = nil
                self.week = nil
                self.month = phase.value?.month
                self.dailyBreakdown = phase.value?.dailyBreakdown
                self.viewingTimeData = phase.value?.time
                self.syncActiveLoadingFlag()
            }
        }
    }

    // MARK: - Refresh (current month)

    func refresh(force: Bool = false) {
        onRefreshTriggered?(Date())

        if monthNav.syncClock() {
            isSyncingMonthNav = true
            viewingYear = monthNav.viewingYear
            viewingMonth = monthNav.viewingMonth
            isSyncingMonthNav = false
            selectedWeekMonday = nil
            historicalLoadGate.invalidate()
        }

        refreshQuota(force: force)

        if force {
            yearTimeCache.removeAll()
            yearLoadGate.invalidateAll()
            if selectedTab == .time && timeRange == .year {
                loadYearTime(viewingTimeYear, force: true)
            }
        }

        if isCurrentMonth {
            if self.today == nil {
                loadCacheForCurrentMonth()
            }
            if currentMonthLoadPhase.value == nil || force {
                currentMonthLoadPhase = currentMonthLoadPhase.transitioningToLoading()
                syncActiveLoadingFlag()
            }
        } else {
            // Queue visible historical-month scan ahead of background archive sweep.
            if force || historicalMonthLoadPhase == .idle {
                loadHistoricalMonth(force: force)
            }
        }

        let req = refreshQueue.request(force: force)
        if req.shouldStartNow {
            startCurrentMonthScriptRefresh(force: req.effectiveForce)
        }
        archiveSweepIfNeeded(force: force)
    }

    private func startCurrentMonthScriptRefresh(force: Bool) {
        scriptQueue.async { [weak self] in
            guard let self = self else { return }
            let cal = AppDate.gregorian
            let now = Date()
            let nowYear = cal.component(.year, from: now)
            let nowMonth = cal.component(.month, from: now)
            let ym = String(format: "%04d-%02d", nowYear, nowMonth)

            let weekMonday = AppDate.mondayOfWeek(containing: now)
            let weekCrossesMonth = weekMonday.map { AppDate.monthKey($0) != ym } ?? false
            var fingerprint = self.computeScanFingerprint(
                monthKey: ym, dayKey: AppDate.dayKey(now), weekCrossesMonth: weekCrossesMonth)
            if !force,
               let fp = fingerprint,
               fp == self.lastScanFingerprint,
               let cached = self.lastScanResults {
                let phase = UsageStateLogic.classifyCurrentMonth(
                    today: cached.today, week: cached.week, month: cached.month,
                    dailyBreakdown: cached.daily, time: cached.time,
                    scriptSucceeded: true, cached: nil)
                DispatchQueue.main.async {
                    self.currentMonthData = cached.month
                    self.currentTimeData = cached.time
                    self.currentMonthLoadPhase = phase
                    self.recomputeTimeToday()
                    self.lastUpdate = Date()
                    if self.isCurrentMonth {
                        self.today = cached.today
                        self.week = cached.week
                        self.month = cached.month
                        self.dailyBreakdown = cached.daily
                        self.viewingTimeData = cached.time
                    }
                    self.completeRefreshQueueAndCheckFollowUp()
                }
                return
            }

            let (m, daily, monthTime) = self.fetchMonthData("month", yearMonth: ym)
            guard let validMonth = m else {
                self.lastScanFingerprint = nil
                self.lastScanResults = nil
                DispatchQueue.main.async {
                    let cachedBundle = self.currentMonthLoadPhase.value
                    self.currentMonthLoadPhase = UsageStateLogic.classifyCurrentMonth(
                        today: cachedBundle?.today,
                        week: cachedBundle?.week,
                        month: nil,
                        dailyBreakdown: cachedBundle?.dailyBreakdown,
                        time: cachedBundle?.time,
                        scriptSucceeded: false,
                        cached: cachedBundle
                    )
                    self.completeRefreshQueueAndCheckFollowUp()
                }
                return
            }
            let t = AppDate.deriveToday(daily)
            var w = AppDate.deriveWeek(daily)
            var crossWeekTime: TimeData? = nil
            var weekStartKey: String? = nil
            if let monday = AppDate.mondayOfWeek(containing: now) {
                weekStartKey = AppDate.dayKey(monday)
                if AppDate.monthKey(monday) != ym {
                    let range = "\(weekStartKey!):\(AppDate.dayKey(now))"
                    if let json = self.scriptClient.runScript(["--json", "--no-sessions", "--range", range]),
                       let crossWeek = UsageParser.parsePeriod(json),
                       crossWeek.cost >= w.cost {
                        w = crossWeek
                        crossWeekTime = UsageParser.parseTimeSection(json)
                    } else {
                        fingerprint = nil
                    }
                }
            }
            let mergedTime = UsageParser.mergeTimeData(base: monthTime, override: crossWeekTime)
            self.lastScanFingerprint = fingerprint
            self.lastScanResults = ScanResults(today: t, week: w, month: validMonth, daily: daily,
                                               time: mergedTime)
            let phase = UsageStateLogic.classifyCurrentMonth(
                today: t, week: w, month: validMonth,
                dailyBreakdown: daily, time: mergedTime,
                scriptSucceeded: true, cached: nil)
            DispatchQueue.main.async {
                self.currentMonthData = validMonth
                self.currentTimeData = mergedTime
                self.currentMonthLoadPhase = phase
                if self.archiveHistoryLocally {
                    self.archive.merge(daily: daily, time: mergedTime)
                }
                self.recomputeTimeToday()
                self.lastUpdate = Date()
                self.saveCache(
                    year: nowYear, month: nowMonth,
                    data: validMonth, daily: daily,
                    week: w, weekStart: weekStartKey,
                    time: mergedTime)
                if self.isCurrentMonth {
                    self.today = t
                    self.week = w
                    self.month = validMonth
                    self.dailyBreakdown = daily
                    self.viewingTimeData = mergedTime
                }
                self.completeRefreshQueueAndCheckFollowUp()
            }
        }
    }

    private func completeRefreshQueueAndCheckFollowUp() {
        let next = refreshQueue.complete()
        if next.shouldRunFollowUp {
            currentMonthLoadPhase = currentMonthLoadPhase.transitioningToLoading()
            syncActiveLoadingFlag()
            startCurrentMonthScriptRefresh(force: next.followUpForce)
        } else {
            syncActiveLoadingFlag()
        }
    }

    // MARK: - Cache I/O

    private func cachePath(year: Int, month: Int) -> String {
        return (cacheDir as NSString).appendingPathComponent(
            String(format: "%04d-%02d.json", year, month))
    }

    private func saveCache(year: Int, month: Int, data: PeriodUsage, daily: [DailyUsage]? = nil,
                           week: PeriodUsage? = nil, weekStart: String? = nil,
                           time: TimeData? = nil) {
        var snapshot = MonthlySnapshot(year: year, month: month, data: data, lastUpdated: Date())
        snapshot.dailyBreakdown = daily
        snapshot.week = week
        snapshot.weekStart = weekStart
        snapshot.time = time
        scriptQueue.async { [weak self] in
            guard let self = self,
                  let jsonData = UsageParser.encodeSnapshot(snapshot) else { return }
            try? jsonData.write(to: URL(fileURLWithPath: self.cachePath(year: year, month: month)), options: .atomic)
        }
    }

    private func loadCache(year: Int, month: Int) -> PeriodUsage? {
        return loadCacheSnapshot(year: year, month: month)?.data
    }

    private func loadCacheSnapshot(year: Int, month: Int) -> MonthlySnapshot? {
        let path = cachePath(year: year, month: month)
        guard let rawData = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return UsageParser.decodeSnapshot(rawData)
    }

    func loadCacheForCurrentMonth() {
        let cal = AppDate.gregorian
        let now = Date()
        let y = cal.component(.year, from: now)
        let m = cal.component(.month, from: now)
        guard let snapshot = loadCacheSnapshot(year: y, month: m) else {
            self.today = nil
            self.week = nil
            self.month = nil
            self.dailyBreakdown = nil
            self.currentTimeData = nil
            self.viewingTimeData = nil
            self.currentMonthLoadPhase = .loading(cached: nil)
            self.recomputeTimeToday()
            self.syncActiveLoadingFlag()
            return
        }
        let daily = snapshot.dailyBreakdown
        let resolvedToday: PeriodUsage
        let resolvedWeek: PeriodUsage
        if daily != nil {
            resolvedToday = AppDate.deriveToday(daily)
            let derivedWeek = AppDate.deriveWeek(daily)
            if let cachedWeek = snapshot.week,
               let cachedStart = snapshot.weekStart,
               let monday = AppDate.mondayOfWeek(containing: now),
               cachedStart == AppDate.dayKey(monday),
               cachedWeek.cost >= derivedWeek.cost {
                resolvedWeek = cachedWeek
            } else {
                resolvedWeek = derivedWeek
            }
        } else {
            let empty = PeriodUsage(cost: 0, models: [], totalMessages: 0, totalTokens: 0)
            resolvedToday = empty
            resolvedWeek = empty
        }
        self.today = resolvedToday
        self.week = resolvedWeek
        self.month = snapshot.data
        self.dailyBreakdown = daily
        self.currentMonthData = snapshot.data
        self.currentTimeData = snapshot.time
        self.viewingTimeData = snapshot.time
        self.currentMonthLoadPhase = .loaded(CurrentMonthBundle(
            today: resolvedToday,
            week: resolvedWeek,
            month: snapshot.data,
            dailyBreakdown: daily,
            time: snapshot.time
        ))
        self.recomputeTimeToday()
        self.lastUpdate = snapshot.lastUpdated
        self.syncActiveLoadingFlag()
    }

    private func recomputeTimeToday(now: Date = Date()) {
        let seconds = currentTimeData?.days[AppDate.dayKey(now)]?.totalSeconds ?? 0
        if timeTodaySeconds != seconds { timeTodaySeconds = seconds }
    }

    // MARK: - Year time loading (--time-year)

    func loadYearTime(_ year: Int, force: Bool = false) {
        let clampedYear = SnapshotFreshnessPolicy.clampedYear(year)
        viewingTimeYear = clampedYear
        let cached = yearTimeCache[clampedYear]
        guard let generation = yearLoadGate.beginLoad(
            year: clampedYear, force: force, hasCachedValue: cached != nil
        ) else {
            if let cached = cached {
                yearTimeDays = cached
                yearLoadPhase = .loaded(cached)
                syncActiveLoadingFlag()
            }
            return
        }
        if !force {
            yearTimeDays = nil
        }
        yearLoadPhase = .loading(cached: force ? cached : nil)
        syncActiveLoadingFlag()
        scriptQueue.async { [weak self] in
            guard let self = self else { return }
            let json = self.scriptClient.runScript(["--time-year", "\(clampedYear)"])
            let parsed = json.flatMap { UsageParser.parseYearTime($0) }
            DispatchQueue.main.async {
                self.yearLoadGate.completeLoad(generation: generation)
                guard generation == self.yearLoadGate.generation,
                      self.viewingTimeYear == clampedYear else { return }
                let latestCached = self.yearTimeCache[clampedYear]
                if let parsed = parsed, parsed.year == clampedYear {
                    let final: [String: Int]
                    if self.archiveHistoryLocally {
                        self.archive.mergeYearSeconds(parsed.days)
                        let overlaid = self.archive.yearSeconds(year: clampedYear)
                        final = overlaid.isEmpty ? parsed.days : overlaid
                    } else {
                        final = parsed.days
                    }
                    self.yearTimeCache[clampedYear] = final
                    self.yearTimeDays = final
                    self.yearLoadPhase = .loaded(final)
                } else if self.archiveHistoryLocally {
                    let archived = self.archive.yearSeconds(year: clampedYear)
                    if !archived.isEmpty {
                        self.yearTimeCache[clampedYear] = archived
                        self.yearTimeDays = archived
                        self.yearLoadPhase = .loaded(archived)
                    } else {
                        self.yearLoadPhase = (json == nil || parsed == nil)
                            ? .failed(.scriptFailed, cached: latestCached)
                            : .loaded([:])
                        self.yearTimeDays = self.yearLoadPhase.value
                    }
                } else {
                    self.yearLoadPhase = (json == nil || parsed == nil)
                        ? .failed(.scriptFailed, cached: latestCached)
                        : .loaded([:])
                    self.yearTimeDays = self.yearLoadPhase.value
                }
                self.syncActiveLoadingFlag()
            }
        }
    }

    func navigateTimeYear(offset: Int) {
        let target = SnapshotFreshnessPolicy.clampedYear(viewingTimeYear + offset)
        guard target != viewingTimeYear else { return }
        loadYearTime(target)
    }

    // MARK: - Week sub-view navigation

    var resolvedWeekMonday: Date? {
        selectedWeekMonday ?? TimeLogic.defaultWeekMonday(
            year: viewingYear, month: viewingMonth, today: Date())
    }

    func navigateTimeWeek(offset: Int) {
        let weeks = TimeLogic.weeksOfMonth(year: viewingYear, month: viewingMonth)
        guard !weeks.isEmpty else { return }
        let current = resolvedWeekMonday.flatMap { TimeLogic.weekIndex(of: $0, in: weeks) } ?? 0
        selectedWeekMonday = weeks[min(max(current + offset, 0), weeks.count - 1)]
    }

    // MARK: - Script execution

    private func fetchPeriod(_ range: String) -> PeriodUsage? {
        guard let json = scriptClient.runScript(["--json", "--no-sessions", "--range", range]) else { return nil }
        return UsageParser.parsePeriod(json)
    }

    private func fetchMonthData(_ range: String, yearMonth: String) -> (PeriodUsage?, [DailyUsage]?, TimeData?) {
        guard let json = scriptClient.runScript(["--json", "--no-sessions", "--range", range]) else { return (nil, nil, nil) }
        let period = UsageParser.parsePeriod(json)
        let daily = UsageParser.parseDailyBreakdown(json, yearMonth: yearMonth)
        let time = UsageParser.parseTimeSection(json)
        return (period, daily, time)
    }

    // MARK: - Scan fingerprint (Antigravity 3 brain roots)

    /// Stat-walk over `<brainRoot>/<conv-id>/.system_generated/logs/transcript.jsonl`
    /// (plus sibling `conversations/<conv-id>.db` / `-wal` when present) across all
    /// 3 Antigravity surfaces (`antigravity-cli`, `antigravity`, `antigravity-ide`).
    /// Missing optional surface directories are skipped cleanly; any stat/read error
    /// on an existing directory returns nil so the caller falls back to a real scan.
    private func computeScanFingerprint(monthKey: String, dayKey: String,
                                        weekCrossesMonth: Bool) -> String? {
        let fm = FileManager.default
        var entries: [String] = []
        var sawAnyRoot = false

        for brainRoot in Self.brainDirectories() {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: brainRoot, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            sawAnyRoot = true
            guard let convIds = try? fm.contentsOfDirectory(atPath: brainRoot) else {
                return nil
            }
            let surfaceRoot = (brainRoot as NSString).deletingLastPathComponent
            let convDbDir = (surfaceRoot as NSString).appendingPathComponent("conversations")

            for convId in convIds where !convId.hasPrefix(".") {
                let convDir = (brainRoot as NSString).appendingPathComponent(convId)
                let transcript = (convDir as NSString)
                    .appendingPathComponent(".system_generated/logs/transcript.jsonl")
                if let entry = statEntry(path: transcript, fm: fm) {
                    entries.append(entry)
                }
                let dbPath = (convDbDir as NSString).appendingPathComponent("\(convId).db")
                if let entry = statEntry(path: dbPath, fm: fm) {
                    entries.append(entry)
                }
                let walPath = dbPath + "-wal"
                if let entry = statEntry(path: walPath, fm: fm) {
                    entries.append(entry)
                }
            }
        }

        if !sawAnyRoot { return nil }
        entries.sort()
        var hasher = Hasher()
        for entry in entries { hasher.combine(entry) }
        let fileDigest = hasher.finalize()
        return "\(fileDigest)|n=\(entries.count)|\(monthKey)|\(dayKey)|w=\(weekCrossesMonth)|\(scriptClient.scriptPath)"
    }

    private func statEntry(path: String, fm: FileManager) -> String? {
        guard fm.fileExists(atPath: path),
              let attrs = try? fm.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? NSNumber else {
            return nil
        }
        return "\(path)|\(mtime.timeIntervalSinceReferenceDate)|\(size.int64Value)"
    }
}
