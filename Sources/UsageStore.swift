import Foundation
import Combine

// MARK: - Data Store

class UsageStore: ObservableObject {
    @Published var today: PeriodUsage?
    @Published var week: PeriodUsage?
    @Published var month: PeriodUsage?
    @Published var isLoading = true
    @Published var lastUpdate: Date?
    @Published var selectedTab: DisplayTab = .cost

    // Month navigation
    @Published var viewingYear: Int
    @Published var viewingMonth: Int

    // Always holds current month data (for menu bar, unaffected by navigation)
    @Published var currentMonthData: PeriodUsage?
    @Published var dailyBreakdown: [DailyUsage]?

    // MARK: Active time ("Time" tab)

    @Published var currentTimeData: TimeData?
    @Published var viewingTimeData: TimeData?
    @Published var timeTodaySeconds: Int = 0
    @Published var timeRange: TimeRange = .week {
        didSet {
            guard timeRange == .year, oldValue != .year else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.loadYearTime(self.viewingTimeYear)
            }
        }
    }
    @Published var viewingTimeYear: Int
    @Published var selectedWeekMonday: Date?
    @Published var yearTimeDays: [String: Int]?
    private var yearTimeCache: [Int: [String: Int]] = [:]
    private var yearFetchGeneration = 0

    // Localization
    @Published var language: AppLanguage

    /// Durable local archive toggle (default on), stored in Application Support/AGYMonitor/archive/.
    @Published var archiveHistoryLocally: Bool = true

    /// Idle icon+value placement: menu bar (default) or MacBook notch.
    @Published var displayMode: DisplayMode = .menubar

    // MARK: Live sessions ("Sessions" tab)

    let sessionStore = SessionStore()

    // MARK: Plan / Quota & AI Credits ("Plan" tab)

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

    /// Antigravity's three local brain roots across CLI, Desktop, and IDE surfaces.
    static func brainDirectories(home: String = NSHomeDirectory()) -> [String] {
        let base = (home as NSString).appendingPathComponent(".gemini")
        return [
            (base as NSString).appendingPathComponent("antigravity-cli/brain"),
            (base as NSString).appendingPathComponent("antigravity/brain"),
            (base as NSString).appendingPathComponent("antigravity-ide/brain"),
        ]
    }

    var isCurrentMonth: Bool {
        let cal = AppDate.gregorian
        let now = Date()
        return viewingYear == cal.component(.year, from: now)
            && viewingMonth == cal.component(.month, from: now)
    }

    var viewingMonthLabel: String {
        let df = DateFormatter()
        df.dateFormat = "MMMM yyyy"
        df.locale = Locale(identifier: language.rawValue)
        var comps = DateComponents()
        comps.year = viewingYear
        comps.month = viewingMonth
        comps.day = 1
        guard let date = AppDate.gregorian.date(from: comps) else { return "" }
        return df.string(from: date)
    }

    /// Menu-bar / compact-notch value string for the CURRENT month + selected tab.
    var menuBarValue: String {
        guard let monthData = currentMonthData else { return "…" }
        switch selectedTab {
        case .cost:
            return formatCost(monthData.cost)
        case .tokens:
            return formatTokensShort(monthData.totalTokens)
        case .subscription:
            if let q = subscriptionQuota {
                let rem = max(0, 100 - q.five_hour.displayPercent)
                return q.five_hour.resets_at != nil ? "5h \(rem)%" : "\(rem)%"
            }
            return formatCost(monthData.cost)
        case .time:
            return TimeLogic.formatDurationShort(timeTodaySeconds)
        case .session:
            return sessionStore.anyBusy ? "▸\(sessionStore.liveCount)" : "\(sessionStore.liveCount)"
        }
    }

    private let scriptClient = UsageScriptClient()
    private let archive = UsageArchive()
    private var lastArchiveSweep: Date?

    private let scriptQueue = DispatchQueue(label: "com.kuen54.AGYMonitor.scripts", qos: .utility)
    private var fetchGeneration = 0
    private var isRefreshInFlight = false

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
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent("Library/Caches"))
        let dir = base.appendingPathComponent("AGYMonitor/snapshots", isDirectory: true).path
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: nil)
        return dir
    }

    init() {
        let cal = AppDate.gregorian
        let now = Date()
        viewingYear = cal.component(.year, from: now)
        viewingMonth = cal.component(.month, from: now)
        viewingTimeYear = cal.component(.year, from: now)

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

        hasOAuthToken = SubscriptionQuotaService.shared.hasOAuthToken
    }

    /// Fetch Antigravity plan quota & AI Credits and update @Published state.
    func refreshQuota(force: Bool = false) {
        let probedHasToken = force
            ? SubscriptionQuotaService.shared.probeTokenPresenceNow()
            : SubscriptionQuotaService.shared.hasOAuthToken
        if !probedHasToken {
            if hasOAuthToken || subscriptionQuota != nil || quotaError != nil {
                hasOAuthToken = false
                subscriptionQuota = nil
                quotaError = nil
            }
            return
        }
        SubscriptionQuotaService.shared.fetch(forceRefresh: force) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if !self.hasOAuthToken { self.hasOAuthToken = true }
                switch result {
                case .success(let quota):
                    if self.subscriptionQuota != quota { self.subscriptionQuota = quota }
                    if self.quotaError != nil { self.quotaError = nil }
                    let fetchedAt = SubscriptionQuotaService.shared.lastSuccessAt
                    if self.quotaUpdatedAt != fetchedAt { self.quotaUpdatedAt = fetchedAt }
                case .noToken:
                    self.hasOAuthToken = false
                    self.subscriptionQuota = nil
                    self.quotaError = nil
                case .unauthorized:
                    if self.quotaError != .unauthorized { self.quotaError = .unauthorized }
                case .rateLimited:
                    if self.quotaError != .rateLimited { self.quotaError = .rateLimited }
                case .networkFailure:
                    if self.quotaError != .networkFailure { self.quotaError = .networkFailure }
                case .decodeFailure:
                    if self.quotaError != .decodeFailure { self.quotaError = .decodeFailure }
                }
                let retryAt: Date? = self.quotaError == .rateLimited
                    ? SubscriptionQuotaService.shared.rateLimitCooldownUntil
                    : nil
                if self.quotaRetryAt != retryAt { self.quotaRetryAt = retryAt }
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

    // MARK: - Live session monitoring (forwarded to sessionStore)

    func startSessionMonitoring() { sessionStore.startMonitoring() }
    func setSessionMonitorActive(_ active: Bool) { sessionStore.setActive(active) }
    func stopSessionMonitoring() { sessionStore.stopMonitoring() }

    // MARK: - Local archive (durable history)

    func setArchiveHistoryLocally(_ on: Bool) {
        guard archiveHistoryLocally != on else { return }
        archiveHistoryLocally = on
        UserDefaults.standard.set(on, forKey: "archiveHistoryLocally")
        if on {
            archiveSweepIfNeeded(force: true)
        }
        republishAfterArchiveChange()
    }

    func clearArchive() {
        archive.clear()
        republishAfterArchiveChange()
    }

    var archivedDayCount: Int { archive.dayCount }

    private func republishAfterArchiveChange() {
        if !isCurrentMonth { loadHistoricalMonth() }
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
        guard archiveHistoryLocally else { return }
        if !force, let last = lastArchiveSweep,
           Date().timeIntervalSince(last) < 6 * 3600 { return }
        lastArchiveSweep = Date()
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
            guard let json = self.scriptClient.runScript(
                ["--json", "--no-sessions", "--range", range]) else { return }
            let daily = UsageParser.parseAllDailyBreakdown(json)
            let time = UsageParser.parseTimeSection(json)
            self.archive.merge(daily: daily, time: time)
            UserDefaults.standard.set(todayKey, forKey: "archiveSweptThrough")
        }
    }

    // MARK: - Navigation

    func navigateMonth(offset: Int) {
        var comps = DateComponents()
        comps.year = viewingYear
        comps.month = viewingMonth + offset
        comps.day = 1
        guard let date = AppDate.gregorian.date(from: comps) else { return }
        let cal = AppDate.gregorian
        viewingYear = cal.component(.year, from: date)
        viewingMonth = cal.component(.month, from: date)

        selectedWeekMonday = nil
        fetchGeneration += 1

        if isCurrentMonth {
            refresh()
        } else {
            loadHistoricalMonth()
        }
    }

    func loadHistoricalMonth() {
        let y = viewingYear, m = viewingMonth
        if let snapshot = loadCacheSnapshot(year: y, month: m),
           snapshot.dailyBreakdown != nil, snapshot.time != nil {
            let ym = String(format: "%04d-%02d", y, m)
            let (om, od, ot) = archiveOverlayHistorical(
                month: snapshot.data, daily: snapshot.dailyBreakdown,
                time: snapshot.time, yearMonth: ym)
            self.today = nil
            self.week = nil
            self.month = om
            self.dailyBreakdown = od
            self.viewingTimeData = ot
            self.isLoading = false
            return
        }
        isLoading = true
        fetchGeneration += 1
        let generation = fetchGeneration
        scriptQueue.async { [weak self] in
            guard let self = self else { return }
            let range = AppDate.monthDateRange(year: y, month: m)
            let ym = String(format: "%04d-%02d", y, m)
            let (data, daily, time) = self.fetchMonthData(range, yearMonth: ym)
            DispatchQueue.main.async {
                guard generation == self.fetchGeneration,
                      self.viewingYear == y && self.viewingMonth == m else { return }
                if let data = data {
                    self.saveCache(year: y, month: m, data: data, daily: daily, time: time)
                }
                let ym = String(format: "%04d-%02d", y, m)
                let (om, od, ot) = self.archiveOverlayHistorical(
                    month: data, daily: daily, time: time, yearMonth: ym)
                self.today = nil
                self.week = nil
                self.month = om
                self.dailyBreakdown = od
                self.viewingTimeData = ot
                self.isLoading = false
            }
        }
    }

    // MARK: - Refresh (current month)

    func refresh(force: Bool = false) {
        refreshQuota(force: force)
        archiveSweepIfNeeded(force: force)

        if force {
            yearTimeCache.removeAll()
            if selectedTab == .time && timeRange == .year {
                loadYearTime(viewingTimeYear, force: true)
            }
        }

        if isCurrentMonth {
            if self.today == nil {
                loadCacheForCurrentMonth()
            }
            if self.month == nil {
                DispatchQueue.main.async { self.isLoading = true }
            }
        } else {
            loadHistoricalMonth()
        }
        guard !isRefreshInFlight else { return }
        isRefreshInFlight = true
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
                DispatchQueue.main.async {
                    self.isRefreshInFlight = false
                    self.currentMonthData = cached.month
                    self.currentTimeData = cached.time
                    self.recomputeTimeToday()
                    self.lastUpdate = Date()
                    guard self.isCurrentMonth else {
                        self.isLoading = false
                        return
                    }
                    self.today = cached.today
                    self.week = cached.week
                    self.month = cached.month
                    self.dailyBreakdown = cached.daily
                    self.viewingTimeData = cached.time
                    self.isLoading = false
                }
                return
            }

            let (m, daily, monthTime) = self.fetchMonthData("month", yearMonth: ym)
            guard m != nil else {
                self.lastScanFingerprint = nil
                self.lastScanResults = nil
                DispatchQueue.main.async {
                    self.isRefreshInFlight = false
                    self.isLoading = false
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
            if let m = m {
                self.lastScanResults = ScanResults(today: t, week: w, month: m, daily: daily,
                                                   time: mergedTime)
            }
            DispatchQueue.main.async {
                self.isRefreshInFlight = false
                self.currentMonthData = m
                self.currentTimeData = mergedTime
                if self.archiveHistoryLocally {
                    self.archive.merge(daily: daily, time: mergedTime)
                }
                self.recomputeTimeToday()
                self.lastUpdate = Date()
                if let m = m {
                    self.saveCache(
                        year: nowYear, month: nowMonth,
                        data: m, daily: daily,
                        week: w, weekStart: weekStartKey,
                        time: mergedTime)
                }
                guard self.isCurrentMonth else {
                    self.isLoading = false
                    return
                }
                self.today = t
                self.week = w
                self.month = m
                self.dailyBreakdown = daily
                self.viewingTimeData = mergedTime
                self.isLoading = false
            }
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
            try? jsonData.write(to: URL(fileURLWithPath: self.cachePath(year: year, month: month)))
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
            self.recomputeTimeToday()
            return
        }
        let daily = snapshot.dailyBreakdown
        if daily != nil {
            self.today = AppDate.deriveToday(daily)
            let derivedWeek = AppDate.deriveWeek(daily)
            if let cachedWeek = snapshot.week,
               let cachedStart = snapshot.weekStart,
               let monday = AppDate.mondayOfWeek(containing: now),
               cachedStart == AppDate.dayKey(monday),
               cachedWeek.cost >= derivedWeek.cost {
                self.week = cachedWeek
            } else {
                self.week = derivedWeek
            }
        } else {
            let empty = PeriodUsage(cost: 0, models: [], totalMessages: 0, totalTokens: 0)
            self.today = empty
            self.week = empty
        }
        self.month = snapshot.data
        self.dailyBreakdown = daily
        self.currentMonthData = snapshot.data
        self.currentTimeData = snapshot.time
        self.viewingTimeData = snapshot.time
        self.recomputeTimeToday()
        self.lastUpdate = snapshot.lastUpdated
        self.isLoading = false
    }

    private func recomputeTimeToday(now: Date = Date()) {
        let seconds = currentTimeData?.days[AppDate.dayKey(now)]?.totalSeconds ?? 0
        if timeTodaySeconds != seconds { timeTodaySeconds = seconds }
    }

    // MARK: - Year time loading (--time-year)

    func loadYearTime(_ year: Int, force: Bool = false) {
        viewingTimeYear = year
        if !force, let cached = yearTimeCache[year] {
            yearTimeDays = cached
            return
        }
        yearTimeDays = nil
        yearFetchGeneration += 1
        let generation = yearFetchGeneration
        scriptQueue.async { [weak self] in
            guard let self = self else { return }
            let json = self.scriptClient.runScript(["--time-year", "\(year)"])
            let parsed = json.flatMap { UsageParser.parseYearTime($0) }
            DispatchQueue.main.async {
                guard generation == self.yearFetchGeneration,
                      self.viewingTimeYear == year else { return }
                if let parsed = parsed, parsed.year == year {
                    let final: [String: Int]
                    if self.archiveHistoryLocally {
                        self.archive.mergeYearSeconds(parsed.days)
                        let overlaid = self.archive.yearSeconds(year: year)
                        final = overlaid.isEmpty ? parsed.days : overlaid
                    } else {
                        final = parsed.days
                    }
                    self.yearTimeCache[year] = final
                    self.yearTimeDays = final
                } else if self.archiveHistoryLocally {
                    let archived = self.archive.yearSeconds(year: year)
                    if !archived.isEmpty {
                        self.yearTimeCache[year] = archived
                        self.yearTimeDays = archived
                    } else {
                        self.yearTimeDays = [:]
                    }
                } else {
                    self.yearTimeDays = [:]
                }
            }
        }
    }

    func navigateTimeYear(offset: Int) {
        loadYearTime(viewingTimeYear + offset)
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
