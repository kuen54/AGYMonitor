import Foundation
import SQLite3

/// App version, single-sourced from Info.plist (CFBundleShortVersionString).
fileprivate let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.4"

/// UI-facing subset of QuotaFetchResult.
enum QuotaError: Equatable {
    case unauthorized
    case rateLimited
    case networkFailure
    case decodeFailure
}

/// Result type distinguishing "no Antigravity account/install" from fetch errors.
enum QuotaFetchResult {
    case success(OAuthUsage)
    case noToken
    case unauthorized
    case rateLimited
    case networkFailure
    case decodeFailure
}

// MARK: - Antigravity Local Auth & State Discovery

private enum AGYStateStore {

    static func candidateStateDBPaths(home: String = NSHomeDirectory()) -> [String] {
        let fm = FileManager.default
        let paths = [
            (home as NSString).appendingPathComponent("Library/Application Support/Antigravity/User/globalStorage/state.vscdb"),
            (home as NSString).appendingPathComponent("Library/Application Support/Antigravity IDE/User/globalStorage/state.vscdb"),
        ]
        // Prefer most recently modified existing database first
        return paths
            .filter { fm.fileExists(atPath: $0) }
            .sorted { a, b in
                let ma = (try? fm.attributesOfItem(atPath: a)[.modificationDate] as? Date) ?? .distantPast
                let mb = (try? fm.attributesOfItem(atPath: b)[.modificationDate] as? Date) ?? .distantPast
                return ma > mb
            }
    }

    static func candidateAGYBinaryPaths(home: String = NSHomeDirectory()) -> [String] {
        return [
            (home as NSString).appendingPathComponent(".local/bin/agy"),
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
            "/Applications/Antigravity IDE.app/Contents/Resources/app/extensions/agy/bin/agy",
            "/Applications/Antigravity.app/Contents/Resources/app/bin/agy",
        ]
    }

    static func resolveAGYBinary(home: String = NSHomeDirectory()) -> String? {
        let fm = FileManager.default
        return candidateAGYBinaryPaths(home: home).first { fm.isExecutableFile(atPath: $0) }
    }

    /// Cheap, non-blocking existence check (never spawns processes or prompts Keychain).
    static func probePresenceFast(home: String = NSHomeDirectory()) -> Bool {
        let env = ProcessInfo.processInfo.environment
        if let t = env["AGY_ACCESS_TOKEN"] ?? env["GOOGLE_OAUTH_ACCESS_TOKEN"], !t.isEmpty {
            return true
        }
        if !candidateStateDBPaths(home: home).isEmpty {
            return true
        }
        let fm = FileManager.default
        let cliLogDir = (home as NSString).appendingPathComponent(".gemini/antigravity-cli/log")
        if let files = try? fm.contentsOfDirectory(atPath: cliLogDir),
           files.contains(where: { $0.hasPrefix("cli-") && $0.hasSuffix(".log") }) {
            return true
        }
        let summariesDB = (home as NSString).appendingPathComponent(".gemini/antigravity-cli/conversation_summaries.db")
        if fm.fileExists(atPath: summariesDB) {
            return true
        }
        return resolveAGYBinary(home: home) != nil
    }

    /// Read `antigravityUnifiedStateSync.userStatus`, `antigravityUnifiedStateSync.modelCredits`,
    /// and any plain OAuth access token from Desktop/IDE `state.vscdb` (using `immutable=1`
    /// read-only SQLite fallback so missing `-wal`/`-shm` files never fail).
    static func readCachedDesktopState(home: String = NSHomeDirectory()) -> (
        userStatus: AGYDecodedUserStatus?,
        modelCredits: Int?,
        accessToken: String?
    ) {
        var bestStatus: AGYDecodedUserStatus? = nil
        var bestCredits: Int? = nil
        var foundToken: String? = nil

        for dbPath in candidateStateDBPaths(home: home) {
            guard let db = SessionMonitor.openReadOnlySQLite(at: dbPath) else { continue }
            defer { sqlite3_close_v2(db) }

            let sql = """
                SELECT key, value FROM ItemTable
                WHERE key IN (
                    'antigravityUnifiedStateSync.userStatus',
                    'antigravityUnifiedStateSync.modelCredits',
                    'antigravityAuthStatus'
                )
                """
            var stmt: OpaquePointer? = nil
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
                sqlite3_finalize(stmt)
                continue
            }
            defer { sqlite3_finalize(s) }

            while sqlite3_step(s) == SQLITE_ROW {
                guard let keyC = sqlite3_column_text(s, 0) else { continue }
                let key = String(cString: keyC)
                let valLen = Int(sqlite3_column_bytes(s, 1))
                guard valLen > 0 else { continue }

                let rawValue: String
                if let textPtr = sqlite3_column_text(s, 1) {
                    rawValue = String(cString: textPtr)
                } else if let blobPtr = sqlite3_column_blob(s, 1) {
                    let data = Data(bytes: blobPtr, count: valLen)
                    rawValue = String(decoding: data, as: UTF8.self)
                } else {
                    continue
                }

                let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                switch key {
                case "antigravityUnifiedStateSync.userStatus":
                    if let decoded = AGYQuotaParser.parseUserStatusValue(trimmed) {
                        if bestStatus == nil
                            || (bestStatus?.buckets.isEmpty == true && !decoded.buckets.isEmpty) {
                            bestStatus = decoded
                        }
                    }
                case "antigravityUnifiedStateSync.modelCredits":
                    if bestCredits == nil, let credits = AGYQuotaParser.parseModelCreditsValue(trimmed) {
                        bestCredits = credits
                    }
                case "antigravityAuthStatus":
                    if foundToken == nil, let tok = extractOAuthAccessToken(from: trimmed) {
                        foundToken = tok
                    }
                default:
                    break
                }
            }

            if bestStatus != nil && !(bestStatus?.buckets.isEmpty ?? true) {
                break
            }
        }

        return (bestStatus, bestCredits, foundToken)
    }

    /// Extract account email & tier from recent `~/.gemini/antigravity-cli/log/cli-*.log` files.
    static func readCLILogAccountInfo(home: String = NSHomeDirectory()) -> (email: String?, tier: String?) {
        let fm = FileManager.default
        let logDir = (home as NSString).appendingPathComponent(".gemini/antigravity-cli/log")
        guard let names = try? fm.contentsOfDirectory(atPath: logDir) else { return (nil, nil) }

        let logFiles = names
            .filter { $0.hasPrefix("cli-") && $0.hasSuffix(".log") }
            .sorted { a, b in
                let pa = (logDir as NSString).appendingPathComponent(a)
                let pb = (logDir as NSString).appendingPathComponent(b)
                let ma = (try? fm.attributesOfItem(atPath: pa)[.modificationDate] as? Date) ?? .distantPast
                let mb = (try? fm.attributesOfItem(atPath: pb)[.modificationDate] as? Date) ?? .distantPast
                if ma != mb { return ma > mb }
                return a > b
            }

        var email: String? = nil
        var tier: String? = nil

        for name in logFiles.prefix(5) {
            let path = (logDir as NSString).appendingPathComponent(name)
            guard let sample = readBoundedLogText(at: path, maxBytes: 512 * 1024) else { continue }
            let parsed = AGYQuotaParser.parseCLILogAccountInfo(sample)
            if email == nil, let e = parsed.email, !e.isEmpty { email = e }
            if tier == nil, let t = parsed.tier, !t.isEmpty { tier = t }
            if email != nil && tier != nil { break }
        }
        return (email, tier)
    }

    /// Look for a non-prompting local OAuth bearer token (env var, `antigravityAuthStatus`,
    /// or plaintext JSON credential file in `~/.gemini`). Never invokes `security -w`
    /// on unowned Keychain items so the user never receives unexpected password prompts.
    static func resolveAccessibleOAuthToken(cachedToken: String?, home: String = NSHomeDirectory()) -> String? {
        let env = ProcessInfo.processInfo.environment
        for key in ["AGY_ACCESS_TOKEN", "CLOUDCODE_ACCESS_TOKEN", "GOOGLE_OAUTH_ACCESS_TOKEN"] {
            if let v = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                return v
            }
        }
        if let t = cachedToken, !t.isEmpty { return t }

        let candidateFiles = [
            (home as NSString).appendingPathComponent(".gemini/oauth_creds.json"),
            (home as NSString).appendingPathComponent(".gemini/antigravity-cli/oauth_creds.json"),
        ]
        for path in candidateFiles {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let exp = json["expiry_date"] as? Double {
                // expiry_date in ms; skip clearly expired tokens
                if exp > 10_000_000_000 && Date().timeIntervalSince1970 * 1000 >= exp - 30_000 {
                    continue
                }
            }
            if let tok = (json["access_token"] as? String) ?? (json["accessToken"] as? String),
               !tok.isEmpty {
                return tok
            }
        }
        return nil
    }

    /// Non-interactive CLI auth/model probe (`agy models`) used when neither live PA HTTP
    /// nor `state.vscdb` buckets were available, confirming active CLI login.
    static func probeAGYModelsAvailable(home: String = NSHomeDirectory()) -> Bool {
        guard let bin = resolveAGYBinary(home: home),
              let res = ProcessRunner.run(bin, ["models"], timeout: 6.0) else {
            return false
        }
        return res.status == 0 && res.output.contains("gemini")
    }

    /// Read `agy` CLI's live OAuth payload stored in macOS Keychain under
    /// `service="gemini"`, `account="antigravity"` via `/usr/bin/security`
    /// (`go-keyring-base64:` wrapper).
    static func readCLIKeychainAuth() -> (accessToken: String?, expiry: Date?, email: String?)? {
        guard let res = ProcessRunner.run(
            "/usr/bin/security",
            ["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"],
            timeout: 4.0
        ), res.status == 0 else {
            return nil
        }
        return AGYQuotaParser.parseGoKeyringAuthPayload(res.output)
    }

    /// Resolve an active OAuth bearer token (and account email when known):
    /// 1. Explicit environment override (`AGY_ACCESS_TOKEN`, etc.)
    /// 2. `agy` CLI Keychain entry (`service="gemini", account="antigravity"`),
    ///    auto-refreshing once via `agy models` if expired or near expiry.
    /// 3. `~/.gemini/oauth_creds.json` or Desktop `antigravityAuthStatus` fallback.
    static func resolveLiveAuth(
        cachedDesktopToken: String?,
        now: Date = Date(),
        home: String = NSHomeDirectory()
    ) -> (token: String?, email: String?) {
        let env = ProcessInfo.processInfo.environment
        for key in ["AGY_ACCESS_TOKEN", "CLOUDCODE_ACCESS_TOKEN", "GOOGLE_OAUTH_ACCESS_TOKEN"] {
            if let v = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                return (v, nil)
            }
        }

        if let kc = readCLIKeychainAuth() {
            let freshEnough: Bool = {
                guard let exp = kc.expiry else { return true }
                return exp > now.addingTimeInterval(30)
            }()
            if let tok = kc.accessToken, !tok.isEmpty, freshEnough {
                return (tok, kc.email)
            }
            if let bin = resolveAGYBinary(home: home),
               let res = ProcessRunner.run(bin, ["models"], timeout: 8.0),
               res.status == 0,
               let refreshed = readCLIKeychainAuth(),
               let tok = refreshed.accessToken,
               !tok.isEmpty {
                let refreshedValid: Bool = {
                    guard let exp = refreshed.expiry else { return true }
                    return exp > Date().addingTimeInterval(5)
                }()
                if refreshedValid {
                    return (tok, refreshed.email ?? kc.email)
                }
            }
            if let mail = kc.email, !mail.isEmpty {
                if let fallback = resolveAccessibleOAuthToken(cachedToken: cachedDesktopToken, home: home) {
                    return (fallback, mail)
                }
                return (nil, mail)
            }
        }

        return (resolveAccessibleOAuthToken(cachedToken: cachedDesktopToken, home: home), nil)
    }

    private static func extractOAuthAccessToken(from text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for k in ["accessToken", "access_token", "apiKey", "oauthToken"] {
            if let tok = obj[k] as? String, tok.hasPrefix("ya29.") {
                return tok
            }
        }
        return nil
    }

    private static func readBoundedLogText(at path: String, maxBytes: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end > 0 else { return nil }
        if end <= UInt64(maxBytes) {
            try? handle.seek(toOffset: 0)
            return String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        }
        // Read head (startup auth/tier log lines) + tail (latest quota/account lines)
        let half = maxBytes / 2
        try? handle.seek(toOffset: 0)
        let head = handle.readData(ofLength: half)
        try? handle.seek(toOffset: end - UInt64(half))
        let tail = handle.readData(ofLength: half)
        return String(decoding: head, as: UTF8.self) + "\n" + String(decoding: tail, as: UTF8.self)
    }
}

// MARK: - Quota & AI Credits Service

/// Reads Google Antigravity quota buckets, plan tier, account email, and AI Credits:
/// 1. Live Cloud Code PA endpoints (`v1internal:retrieveUserQuotaSummary` / `fetchAvailableModels`
///    + `loadCodeAssist`) whenever a local OAuth bearer token is accessible.
/// 2. Seamless offline/desktop fallback from `state.vscdb` (`antigravityUnifiedStateSync.userStatus`
///    & `modelCredits`) + `~/.gemini/antigravity-cli/log/cli-*.log` + `agy models` liveness check.
final class SubscriptionQuotaService {
    static let shared = SubscriptionQuotaService()

    private let aicodeQuotaURL = URL(string: "https://aicode.googleapis.com/v1alpha:fetchQuotaStatus")!
    private let quotaSummaryURL = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!
    private let availableModelsURL = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels")!
    private let loadCodeAssistURL = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!

    private let ttl: TimeInterval = 60
    private var cached: (quota: OAuthUsage, at: Date)?
    private var rateLimitedUntil: Date?
    private let lock = NSLock()

    private let workQueue = DispatchQueue(label: "com.kuen54.AGYMonitor.quota.work", qos: .utility)
    private var fetchInFlight = false
    private var pendingCompletions: [(QuotaFetchResult) -> Void] = []

    private var tokenPresenceCache: (value: Bool, at: Date)?
    private var tokenProbeInFlight = false
    private let tokenPresenceLock = NSLock()
    private static let tokenPresenceTTL: TimeInterval = 60

    var hasOAuthToken: Bool {
        tokenPresenceLock.lock()
        if let cached = tokenPresenceCache {
            let isFresh = Date().timeIntervalSince(cached.at) < Self.tokenPresenceTTL
            let shouldProbe = !isFresh && !tokenProbeInFlight
            if shouldProbe { tokenProbeInFlight = true }
            tokenPresenceLock.unlock()
            if shouldProbe {
                workQueue.async { [weak self] in
                    guard let self = self else { return }
                    let value = AGYStateStore.probePresenceFast()
                    self.tokenPresenceLock.lock()
                    self.tokenPresenceCache = (value, Date())
                    self.tokenProbeInFlight = false
                    self.tokenPresenceLock.unlock()
                }
            }
            return cached.value
        }
        tokenPresenceLock.unlock()
        let value = AGYStateStore.probePresenceFast()
        tokenPresenceLock.lock()
        tokenPresenceCache = (value, Date())
        tokenPresenceLock.unlock()
        return value
    }

    @discardableResult
    func probeTokenPresenceNow() -> Bool {
        let value = AGYStateStore.probePresenceFast()
        tokenPresenceLock.lock()
        tokenPresenceCache = (value, Date())
        tokenPresenceLock.unlock()
        return value
    }

    var lastSuccessAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return cached?.at
    }

    var rateLimitCooldownUntil: Date? {
        lock.lock(); defer { lock.unlock() }
        guard let until = rateLimitedUntil, until > Date() else { return nil }
        return until
    }

    func fetch(forceRefresh: Bool = false, completion: @escaping (QuotaFetchResult) -> Void) {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            if !forceRefresh, let c = self.cached, Date().timeIntervalSince(c.at) < self.ttl {
                let q = c.quota
                self.lock.unlock()
                DispatchQueue.main.async { completion(.success(q)) }
                return
            }
            if let until = self.rateLimitedUntil, Date() < until {
                self.lock.unlock()
                DispatchQueue.main.async { completion(.rateLimited) }
                return
            }
            self.lock.unlock()

            self.pendingCompletions.append(completion)
            guard !self.fetchInFlight else { return }
            self.fetchInFlight = true

            self.performAGYFetch(forceRefresh: forceRefresh) { result in
                self.finishFetch(result)
            }
        }
    }

    private func finishFetch(_ result: QuotaFetchResult) {
        workQueue.async {
            let completions = self.pendingCompletions
            self.pendingCompletions = []
            self.fetchInFlight = false
            DispatchQueue.main.async { completions.forEach { $0(result) } }
        }
    }

    // MARK: - Multi-Source AGY Quota Pipeline

    private func performAGYFetch(forceRefresh: Bool, completion: @escaping (QuotaFetchResult) -> Void) {
        let now = Date()
        let desktop = AGYStateStore.readCachedDesktopState()
        let cliAccount = AGYStateStore.readCLILogAccountInfo()
        let liveAuth = AGYStateStore.resolveLiveAuth(cachedDesktopToken: desktop.accessToken, now: now)

        let mergedEmail = Self.nonEmpty(liveAuth.email)
            ?? Self.nonEmpty(cliAccount.email)
            ?? Self.nonEmpty(desktop.userStatus?.email)
        let mergedRawTier = Self.nonEmpty(cliAccount.tier) ?? Self.nonEmpty(desktop.userStatus?.planName)
        let promptCredits = desktop.userStatus?.promptCredits ?? desktop.modelCredits
        let flowCredits = desktop.userStatus?.flowCredits
        let flexCredits = desktop.userStatus?.flexCredits

        // 1. Attempt live Cloud Code PA HTTP fetch if an OAuth token is accessible
        if let token = liveAuth.token {
            fetchLiveCloudCodeQuota(bearerToken: token) { [weak self] liveOutcome in
                guard let self = self else { return }
                self.workQueue.async {
                    switch liveOutcome {
                    case .live(let liveBuckets, let liveTier):
                        let snapshot = Self.buildQuotaSnapshot(
                            buckets: liveBuckets,
                            email: mergedEmail,
                            rawTier: Self.nonEmpty(liveTier) ?? mergedRawTier,
                            promptCredits: promptCredits,
                            flowCredits: flowCredits,
                            flexCredits: flexCredits,
                            isOfflineCached: false,
                            now: now
                        )
                        self.storeSuccess(snapshot)
                        completion(.success(snapshot))
                        return
                    case .rateLimited(let deadline):
                        self.lock.lock()
                        self.rateLimitedUntil = deadline
                        self.lock.unlock()
                        // If we have valid local state, still populate initial snapshot if nil
                        if let fallback = Self.buildOfflineSnapshotIfAvailable(
                            desktop: desktop,
                            email: mergedEmail,
                            rawTier: mergedRawTier,
                            promptCredits: promptCredits,
                            flowCredits: flowCredits,
                            flexCredits: flexCredits,
                            allowCLIProbe: forceRefresh,
                            now: now
                        ) {
                            self.storeSuccess(fallback)
                            completion(.success(fallback))
                        } else {
                            completion(.rateLimited)
                        }
                        return
                    case .unavailable:
                        // Fall through seamlessly to offline Desktop `state.vscdb` + CLI state!
                        self.completeWithLocalFallback(
                            desktop: desktop,
                            email: mergedEmail,
                            rawTier: mergedRawTier,
                            promptCredits: promptCredits,
                            flowCredits: flowCredits,
                            flexCredits: flexCredits,
                            allowCLIProbe: forceRefresh,
                            now: now,
                            completion: completion
                        )
                    }
                }
            }
            return
        }

        // 2. Seamless local `state.vscdb` + `cli-*.log` + `agy models` path
        completeWithLocalFallback(
            desktop: desktop,
            email: mergedEmail,
            rawTier: mergedRawTier,
            promptCredits: promptCredits,
            flowCredits: flowCredits,
            flexCredits: flexCredits,
            allowCLIProbe: forceRefresh || desktop.userStatus == nil,
            now: now,
            completion: completion
        )
    }

    private func completeWithLocalFallback(
        desktop: (userStatus: AGYDecodedUserStatus?, modelCredits: Int?, accessToken: String?),
        email: String?,
        rawTier: String?,
        promptCredits: Int?,
        flowCredits: Int?,
        flexCredits: Int?,
        allowCLIProbe: Bool,
        now: Date,
        completion: @escaping (QuotaFetchResult) -> Void
    ) {
        if let snapshot = Self.buildOfflineSnapshotIfAvailable(
            desktop: desktop,
            email: email,
            rawTier: rawTier,
            promptCredits: promptCredits,
            flowCredits: flowCredits,
            flexCredits: flexCredits,
            allowCLIProbe: allowCLIProbe,
            now: now
        ) {
            storeSuccess(snapshot)
            completion(.success(snapshot))
        } else {
            completion(.noToken)
        }
    }

    private func storeSuccess(_ quota: OAuthUsage) {
        lock.lock()
        cached = (quota, Date())
        rateLimitedUntil = nil
        lock.unlock()
    }

    private enum LivePAOutcome {
        case live(buckets: [AGYModelQuotaBucket], tier: String?)
        case rateLimited(Date)
        case unavailable
    }

    private func fetchLiveCloudCodeQuota(
        bearerToken: String,
        completion: @escaping (LivePAOutcome) -> Void
    ) {
        let lcaBody: [String: Any] = [
            "metadata": [
                "ideType": "ANTIGRAVITY",
                "pluginType": "GEMINI",
            ]
        ]
        postJSON(url: loadCodeAssistURL, bearerToken: bearerToken, bodyObject: lcaBody) { [weak self] lcaData, lcaHTTP in
            guard let self = self else { completion(.unavailable); return }
            let lcaStatus = lcaHTTP?.statusCode ?? -1
            if lcaStatus == 429 {
                completion(.rateLimited(Self.retryDeadline(from: lcaHTTP, default: 60)))
                return
            }

            let lcaInfo: (tier: String?, projectId: String?) = (lcaStatus == 200)
                ? (lcaData.map(AGYQuotaParser.parseLoadCodeAssistJSON) ?? (nil, nil))
                : (nil, nil)

            let projectBody: [String: Any] = lcaInfo.projectId.map { ["project": $0] } ?? [:]

            let group = DispatchGroup()
            let stateLock = NSLock()
            var aicodeData: Data?
            var modelsData: Data?
            var summaryData: Data?
            var aicodeStatus = -1
            var modelsStatus = -1
            var summaryStatus = -1
            var rateLimitDeadline: Date?

            group.enter()
            self.getJSON(url: self.aicodeQuotaURL, bearerToken: bearerToken) { data, http in
                stateLock.lock()
                aicodeStatus = http?.statusCode ?? -1
                if aicodeStatus == 200 {
                    aicodeData = data
                } else if aicodeStatus == 429 {
                    let dl = Self.retryDeadline(from: http, default: 60)
                    rateLimitDeadline = rateLimitDeadline.map { max($0, dl) } ?? dl
                }
                stateLock.unlock()
                group.leave()
            }

            group.enter()
            self.postJSON(url: self.availableModelsURL, bearerToken: bearerToken, bodyObject: projectBody) { data, http in
                stateLock.lock()
                modelsStatus = http?.statusCode ?? -1
                if modelsStatus == 200 {
                    modelsData = data
                } else if modelsStatus == 429 {
                    let dl = Self.retryDeadline(from: http, default: 60)
                    rateLimitDeadline = rateLimitDeadline.map { max($0, dl) } ?? dl
                }
                stateLock.unlock()
                group.leave()
            }

            group.enter()
            self.postJSON(url: self.quotaSummaryURL, bearerToken: bearerToken, bodyObject: projectBody) { data, http in
                stateLock.lock()
                summaryStatus = http?.statusCode ?? -1
                if summaryStatus == 200 {
                    summaryData = data
                } else if summaryStatus == 429 {
                    let dl = Self.retryDeadline(from: http, default: 60)
                    rateLimitDeadline = rateLimitDeadline.map { max($0, dl) } ?? dl
                }
                stateLock.unlock()
                group.leave()
            }

            group.notify(queue: self.workQueue) {
                let merged = AGYQuotaParser.mergeLiveQuotaBuckets(
                    availableModelsData: modelsData,
                    quotaSummaryData: summaryData,
                    aicodeQuotaData: aicodeData
                )
                if !merged.isEmpty {
                    completion(.live(buckets: merged, tier: lcaInfo.tier))
                } else if aicodeStatus == 429 || modelsStatus == 429 || summaryStatus == 429 {
                    completion(.rateLimited(rateLimitDeadline ?? Date().addingTimeInterval(60)))
                } else {
                    completion(.unavailable)
                }
            }
        }
    }

    private func getJSON(
        url: URL,
        bearerToken: String,
        completion: @escaping (Data?, HTTPURLResponse?) -> Void
    ) {
        guard url.scheme == "https" else {
            completion(nil, nil)
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 8
        req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        req.setValue("antigravity/1.5.9 darwin/arm64", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { data, resp, _ in
            completion(data, resp as? HTTPURLResponse)
        }.resume()
    }

    private func postJSON(
        url: URL,
        bearerToken: String,
        bodyObject: [String: Any] = [:],
        completion: @escaping (Data?, HTTPURLResponse?) -> Void
    ) {
        guard url.scheme == "https" else {
            completion(nil, nil)
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("antigravity/1.5.9 darwin/arm64", forHTTPHeaderField: "User-Agent")
        req.httpBody = (try? JSONSerialization.data(withJSONObject: bodyObject)) ?? Data("{}".utf8)

        URLSession.shared.dataTask(with: req) { data, resp, _ in
            completion(data, resp as? HTTPURLResponse)
        }.resume()
    }

    // MARK: - Snapshot Construction & Bucket Normalization

    private static func buildOfflineSnapshotIfAvailable(
        desktop: (userStatus: AGYDecodedUserStatus?, modelCredits: Int?, accessToken: String?),
        email: String?,
        rawTier: String?,
        promptCredits: Int?,
        flowCredits: Int?,
        flexCredits: Int?,
        allowCLIProbe: Bool,
        now: Date
    ) -> OAuthUsage? {
        let rawBuckets = desktop.userStatus?.buckets ?? []
        // Normalize cached buckets: if a cached 5-hour rolling reset timestamp is already
        // in the past (`resetAt <= now`), that rolling window has already replenished to 100%.
        let normalizedBuckets: [AGYModelQuotaBucket] = rawBuckets.map { b in
            if let r = b.resetAt, r <= now {
                return AGYModelQuotaBucket(
                    id: b.id,
                    title: b.title,
                    remainingFraction: 1.0,
                    resetAt: nil,
                    modelClasses: b.modelClasses
                )
            }
            return b
        }

        let hasAnyLocalData = !normalizedBuckets.isEmpty
            || email != nil
            || rawTier != nil
            || promptCredits != nil
            || flowCredits != nil
            || flexCredits != nil
            || (allowCLIProbe && AGYStateStore.probeAGYModelsAvailable())

        guard hasAnyLocalData else { return nil }

        return buildQuotaSnapshot(
            buckets: normalizedBuckets,
            email: email,
            rawTier: rawTier,
            promptCredits: promptCredits,
            flowCredits: flowCredits,
            flexCredits: flexCredits,
            isOfflineCached: true,
            now: now
        )
    }

    static func buildQuotaSnapshot(
        buckets: [AGYModelQuotaBucket],
        email: String?,
        rawTier: String?,
        promptCredits: Int?,
        flowCredits: Int?,
        flexCredits: Int?,
        isOfflineCached: Bool,
        now: Date
    ) -> OAuthUsage {
        // Partition into primary Gemini 5h bucket, secondary Claude & GPT 5h bucket,
        // and any extra/weekly scoped buckets (`claude_partner_weekly`, `gemini_weekly`, etc.).
        var geminiBucket: AGYModelQuotaBucket? = nil
        var claudeBucket: AGYModelQuotaBucket? = nil
        var extraBuckets: [AGYModelQuotaBucket] = []

        for b in buckets {
            let lowerId = (b.id + " " + b.title).lowercased()
            let isWeekly = b.id.lowercased().contains("weekly") || b.title.lowercased().contains("weekly")
            let hasGeminiClass = b.modelClasses.contains(where: \.isGeminiFamily)
            let hasClaudeOrOtherClass = b.modelClasses.contains(where: {
                $0 == .claude || $0 == .other
            })

            if b.id == "gemini" || (geminiBucket == nil && !isWeekly && (lowerId.contains("gemini") || hasGeminiClass)) {
                if geminiBucket == nil {
                    geminiBucket = b
                } else {
                    extraBuckets.append(b)
                }
            } else if b.id == "claude_partner" || (claudeBucket == nil && !isWeekly && (lowerId.contains("claude") || lowerId.contains("partner") || lowerId.contains("anthropic") || lowerId.contains("gpt") || hasClaudeOrOtherClass)) {
                if claudeBucket == nil {
                    claudeBucket = b
                } else {
                    extraBuckets.append(b)
                }
            } else {
                extraBuckets.append(b)
            }
        }

        if geminiBucket == nil, let idx = extraBuckets.firstIndex(where: { !$0.id.lowercased().contains("weekly") }) {
            geminiBucket = extraBuckets.remove(at: idx)
        }
        if claudeBucket == nil, let idx = extraBuckets.firstIndex(where: { !$0.id.lowercased().contains("weekly") }) {
            claudeBucket = extraBuckets.remove(at: idx)
        }

        let geminiUsed = usedPercent(fromRemainingFraction: geminiBucket?.remainingFraction ?? 1.0)
        let geminiReset = validFutureISO(geminiBucket?.resetAt, now: now)
        let fiveHour = OAuthUsageWindow(
            utilization: geminiUsed,
            resets_at: geminiReset,
            label: geminiBucket?.title ?? "Gemini Models"
        )

        let claudeUsed = usedPercent(fromRemainingFraction: claudeBucket?.remainingFraction ?? 1.0)
        let claudeReset = validFutureISO(claudeBucket?.resetAt, now: now)
        let sevenDay = OAuthUsageWindow(
            utilization: claudeUsed,
            resets_at: claudeReset,
            label: claudeBucket?.title ?? "Claude & GPT · 5h"
        )

        let scopedItems: [OAuthUsageLimit] = extraBuckets.map { b in
            OAuthUsageLimit(
                kind: "weekly_scoped",
                group: "session",
                percent: usedPercent(fromRemainingFraction: b.remainingFraction),
                resets_at: validFutureISO(b.resetAt, now: now),
                scope: OAuthLimitScope(model: OAuthLimitModel(id: b.id, display_name: b.title)),
                is_active: true
            )
        }

        return OAuthUsage(
            five_hour: fiveHour,
            seven_day: sevenDay,
            extra_usage: nil,
            seven_day_sonnet: nil,
            limits: scopedItems.isEmpty ? nil : OAuthLimitList(items: scopedItems),
            accountEmail: email,
            planTier: prettyPlanTier(rawTier),
            promptCredits: promptCredits,
            flowCredits: flowCredits,
            flexCredits: flexCredits,
            isOfflineCached: isOfflineCached
        )
    }

    private static func usedPercent(fromRemainingFraction rem: Double) -> Double {
        let clampedRem = min(1.0, max(0.0, rem))
        return min(100.0, max(0.0, (1.0 - clampedRem) * 100.0))
    }

    private static func validFutureISO(_ date: Date?, now: Date) -> String? {
        guard let date = date, date > now else { return nil }
        return OAuthUsage.formatISO(date)
    }

    private static func prettyPlanTier(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        switch raw.uppercased() {
        case "G1_PRO_TIER", "G1_PRO_LITE_TIER", "GOOGLE_ONE_AI_PRO", "GOOGLE_AI_PRO", "GOOGLE AI PRO", "PRO", "PRO_TIER":
            return "Google AI Pro"
        case "G1_ULTRA_TIER", "G1_ULTRA_LITE_TIER", "GOOGLE_ONE_AI_ULTRA", "GOOGLE_AI_ULTRA", "GOOGLE AI ULTRA", "ULTRA", "ULTRA_TIER":
            return "Google AI Ultra"
        case "ENTERPRISE_AGENT_TIER", "ENTERPRISE_TIER", "ENTERPRISE":
            return "Enterprise"
        case "FREE_TIER", "FREE":
            return "Free"
        default:
            return raw
        }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
            return nil
        }
        return t
    }

    private static func retryDeadline(from http: HTTPURLResponse?,
                                      default defaultCooldown: TimeInterval) -> Date {
        let now = Date()
        let cap: TimeInterval = 3600
        if let raw = http?.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            if let secs = TimeInterval(raw) {
                return now.addingTimeInterval(min(cap, max(0, secs)))
            }
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = TimeZone(identifier: "GMT")
            fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            if let d = fmt.date(from: raw), d > now {
                return min(d, now.addingTimeInterval(cap))
            }
        }
        return now.addingTimeInterval(defaultCooldown)
    }
}

typealias QuotaService = SubscriptionQuotaService
