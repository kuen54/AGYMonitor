import Foundation

// MARK: - Live Antigravity sessions — pure core
//
// Foundation-only (part of AGYCore): decodes, filters, deduplicates, and groups
// live Antigravity CLI (`presence/<conv-id>.lock` via lsof/ps), Desktop, and IDE
// conversations (`conversation_metadata.json` / `conversation_summaries.db`),
// plus terminal ppid-walk targeting and the done-unseen state reducer.
//
// Zero Process, zero SQLite, zero FileManager, zero AppKit/SwiftUI here.

public enum SessionStatus: String, Codable, Equatable, Sendable {
    case busy
    case shell
    case idle
    case waiting
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SessionStatus(rawValue: raw) ?? .unknown
    }
}

/// Coarse UI bucket for `waitingFor`.
public enum SessionWaitReason: Equatable, Sendable {
    case needsConfirmation
    case needsInput
}

/// One live session entry. Preserves every existing property/init parameter
/// expected by `SessionStore`, `SessionMonitor`, `SessionJumper`, and `Views_Session`,
/// with optional Antigravity metadata fields defaulted at the tail.
public struct SessionInfo: Codable, Equatable, Identifiable, Sendable {
    public let pid: Int
    public let sessionId: String
    public let cwd: String
    public let status: SessionStatus
    public let waitingFor: String?
    public let startedAt: Double?       // epoch milliseconds
    public let updatedAt: Double?       // epoch milliseconds
    public let statusUpdatedAt: Double? // epoch milliseconds
    public let version: String?
    public let kind: String?
    public let entrypoint: String?
    /// Antigravity surface (`"antigravity-cli"`, `"antigravity"`, `"antigravity-ide"`).
    public let surface: String?
    /// Optional metadata title (from `conversation_metadata.json` / `conversation_summaries.db`).
    public let title: String?
    /// True for swarm worker / subagent internal conversations.
    public let isInternal: Bool
    /// Parent coordinator conversation UUID when spawned as a subagent/worker.
    public let parentSessionId: String?

    public var id: String { sessionId }
    public var shortId: String { String(sessionId.prefix(8)) }

    public var waitReason: SessionWaitReason? {
        guard status == .waiting else { return nil }
        switch waitingFor {
        case "permission prompt", "tool confirmation", "approval needed":
            return .needsConfirmation
        case "input needed", "dialog open", "worker request", "sandbox request", "ask_question":
            return .needsInput
        default:
            return .needsInput
        }
    }

    enum CodingKeys: String, CodingKey {
        case pid, sessionId, cwd, status, waitingFor
        case startedAt, updatedAt, statusUpdatedAt
        case version, kind, entrypoint
        case surface, title, isInternal, parentSessionId
    }

    public init(
        pid: Int,
        sessionId: String,
        cwd: String,
        status: SessionStatus,
        waitingFor: String? = nil,
        startedAt: Double? = nil,
        updatedAt: Double? = nil,
        statusUpdatedAt: Double? = nil,
        version: String? = nil,
        kind: String? = nil,
        entrypoint: String? = nil,
        surface: String? = nil,
        title: String? = nil,
        isInternal: Bool = false,
        parentSessionId: String? = nil
    ) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.status = status
        self.waitingFor = waitingFor
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.statusUpdatedAt = statusUpdatedAt
        self.version = version
        self.kind = kind
        self.entrypoint = entrypoint
        self.surface = surface
        self.title = title
        self.isInternal = isInternal
        self.parentSessionId = parentSessionId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        guard let pid = (try? c.decodeIfPresent(Int.self, forKey: .pid)) ?? nil else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: c.codingPath, debugDescription: "session file missing pid"))
        }
        guard let sessionId = (try? c.decodeIfPresent(String.self, forKey: .sessionId)) ?? nil,
              !sessionId.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: c.codingPath, debugDescription: "session file missing sessionId"))
        }
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = ((try? c.decodeIfPresent(String.self, forKey: .cwd)) ?? nil) ?? ""
        self.status = ((try? c.decodeIfPresent(SessionStatus.self, forKey: .status)) ?? nil) ?? .unknown
        self.waitingFor = (try? c.decodeIfPresent(String.self, forKey: .waitingFor)) ?? nil
        self.startedAt = (try? c.decodeIfPresent(Double.self, forKey: .startedAt)) ?? nil
        self.updatedAt = (try? c.decodeIfPresent(Double.self, forKey: .updatedAt)) ?? nil
        self.statusUpdatedAt = (try? c.decodeIfPresent(Double.self, forKey: .statusUpdatedAt)) ?? nil
        self.version = (try? c.decodeIfPresent(String.self, forKey: .version)) ?? nil
        self.kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil
        self.entrypoint = (try? c.decodeIfPresent(String.self, forKey: .entrypoint)) ?? nil
        self.surface = (try? c.decodeIfPresent(String.self, forKey: .surface)) ?? nil
        self.title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
        self.isInternal = ((try? c.decodeIfPresent(Bool.self, forKey: .isInternal)) ?? nil) ?? false
        self.parentSessionId = (try? c.decodeIfPresent(String.self, forKey: .parentSessionId)) ?? nil
    }
}

/// One cwd's worth of sessions for the grouped Session tab.
public struct SessionGroup: Identifiable, Equatable, Sendable {
    public let cwd: String
    public let label: String
    public let sessions: [SessionInfo]

    public var id: String { cwd }
    public var anyBusy: Bool { sessions.contains { $0.status == .busy } }
    public var mostRecentUpdate: Double { sessions.compactMap { $0.updatedAt }.max() ?? 0 }

    public init(cwd: String, label: String, sessions: [SessionInfo]) {
        self.cwd = cwd
        self.label = label
        self.sessions = sessions
    }
}

// MARK: - Jump targeting types

public enum TerminalKind: String, Equatable, Sendable {
    case otty
    case appleTerminal
    case iterm2
    case ghostty
    case wezterm
    case kitty
    case alacritty
    case antigravity
    case unknown
}

public struct OttyPane: Equatable, Sendable {
    public let id: String
    public let cwd: String
    public let title: String

    public init(id: String, cwd: String, title: String) {
        self.id = id
        self.cwd = cwd
        self.title = title
    }
}

public enum OttyMatch: Equatable, Sendable {
    case exact(paneId: String)
    case ambiguous
    case none
}

// MARK: - Antigravity presence, metadata & swarm models

/// One open `~/.gemini/antigravity-cli/presence/<conv-id>.lock` descriptor
/// extracted from `lsof` output, paired with the owning PID's `cwd` if present.
public struct AGYPresenceLock: Equatable, Sendable {
    public let pid: Int
    public let conversationId: String
    public let cwd: String?
    public let command: String?
    public let lockPath: String

    public init(
        pid: Int,
        conversationId: String,
        cwd: String? = nil,
        command: String? = nil,
        lockPath: String
    ) {
        self.pid = pid
        self.conversationId = conversationId
        self.cwd = cwd
        self.command = command
        self.lockPath = lockPath
    }
}

/// Pure representation of an Antigravity conversation summary from
/// `cache/conversation_metadata.json` or `conversation_summaries.db`.
public struct AGYConversationMeta: Equatable, Sendable {
    public let conversationId: String
    public let title: String?
    public let preview: String?
    public let stepCount: Int
    /// nil when `UpdatedAt` is `"0001-01-01T00:00:00Z"` or absent.
    public let updatedAt: Date?
    /// nil when `last_modified_time` is `"0001-01-01..."` or absent.
    public let lastModifiedAt: Date?
    public let workspacePaths: [String]
    public let appDataDir: String?
    public let status: String?
    public let notFullyIdle: Bool
    public let isInternal: Bool
    public let isKilled: Bool
    public let agentName: String?
    public let parentConversationId: String?
    public let nestingDepth: Int

    public var primaryWorkspace: String? { workspacePaths.first }

    /// Best non-sentinel timestamp in epoch milliseconds (`updatedAt` preferred
    /// over `lastModifiedAt` when `stepCount > 0`, or the newer of the two).
    public var effectiveUpdatedAtMs: Double? {
        switch (updatedAt, lastModifiedAt) {
        case let (u?, m?):
            return max(u.timeIntervalSince1970, m.timeIntervalSince1970) * 1000.0
        case let (u?, nil):
            return u.timeIntervalSince1970 * 1000.0
        case let (nil, m?):
            return stepCount > 0 ? m.timeIntervalSince1970 * 1000.0 : nil
        case (nil, nil):
            return nil
        }
    }

    public init(
        conversationId: String,
        title: String? = nil,
        preview: String? = nil,
        stepCount: Int = 0,
        updatedAt: Date? = nil,
        lastModifiedAt: Date? = nil,
        workspacePaths: [String] = [],
        appDataDir: String? = nil,
        status: String? = nil,
        notFullyIdle: Bool = false,
        isInternal: Bool = false,
        isKilled: Bool = false,
        agentName: String? = nil,
        parentConversationId: String? = nil,
        nestingDepth: Int = 0
    ) {
        self.conversationId = conversationId
        self.title = title
        self.preview = preview
        self.stepCount = stepCount
        self.updatedAt = updatedAt
        self.lastModifiedAt = lastModifiedAt
        self.workspacePaths = workspacePaths
        self.appDataDir = appDataDir
        self.status = status
        self.notFullyIdle = notFullyIdle
        self.isInternal = isInternal
        self.isKilled = isKilled
        self.agentName = agentName
        self.parentConversationId = parentConversationId
        self.nestingDepth = nestingDepth
    }
}

/// One swarm member decoded from `.system_generated/swarm/members.json`.
public struct AGYSwarmMember: Equatable, Sendable {
    public let name: String
    public let conversationId: String
    public let role: String
    public let phase: String
    public let wakeMode: String?
    public let killed: Bool
    public let appliedModel: String?

    public var isActivelyWorking: Bool {
        !killed && phase.uppercased() == "RUNNING" && wakeMode?.lowercased() == "working"
    }

    public init(
        name: String,
        conversationId: String,
        role: String,
        phase: String,
        wakeMode: String? = nil,
        killed: Bool = false,
        appliedModel: String? = nil
    ) {
        self.name = name
        self.conversationId = conversationId
        self.role = role
        self.phase = phase
        self.wakeMode = wakeMode
        self.killed = killed
        self.appliedModel = appliedModel
    }
}

// MARK: - Pure session logic

public enum SessionLogic {

    private static let listableEntrypoints: Set<String> = [
        "cli", "agy", "ide", "desktop", "antigravity-cli", "antigravity", "antigravity-ide"
    ]

    public static func parse(jsonData: Data) -> SessionInfo? {
        try? JSONDecoder().decode(SessionInfo.self, from: jsonData)
    }

    /// Whether a session entry belongs in the interactive user session list.
    /// Excludes internal swarm workers, background forks (`kind == "bg"`),
    /// headless SDK invocations (`entrypoint == "sdk-cli"`), and `.unknown` status.
    public static func listable(_ s: SessionInfo) -> Bool {
        guard !s.isInternal,
              (s.parentSessionId ?? "").isEmpty,
              let ep = s.entrypoint,
              listableEntrypoints.contains(ep),
              s.status != .unknown,
              s.kind != "bg" else {
            return false
        }
        return true
    }

    public static func basename(_ path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }

    public static func grouped(_ sessions: [SessionInfo]) -> [SessionGroup] {
        var byCwd: [String: [SessionInfo]] = [:]
        var order: [String] = []
        for s in sessions {
            if byCwd[s.cwd] == nil { order.append(s.cwd) }
            byCwd[s.cwd, default: []].append(s)
        }
        var groups: [SessionGroup] = order.map { cwd in
            let sorted = (byCwd[cwd] ?? []).sorted(by: sessionOrder)
            return SessionGroup(cwd: cwd, label: basename(cwd), sessions: sorted)
        }
        groups.sort(by: groupOrder)
        return groups
    }

    public static func sessionOrder(_ a: SessionInfo, _ b: SessionInfo) -> Bool {
        let ab = a.status == .busy, bb = b.status == .busy
        if ab != bb { return ab }
        let au = a.updatedAt ?? 0, bu = b.updatedAt ?? 0
        if au != bu { return au > bu }
        return a.sessionId < b.sessionId
    }

    public static func groupOrder(_ a: SessionGroup, _ b: SessionGroup) -> Bool {
        if a.anyBusy != b.anyBusy { return a.anyBusy }
        if a.mostRecentUpdate != b.mostRecentUpdate { return a.mostRecentUpdate > b.mostRecentUpdate }
        return a.cwd < b.cwd
    }

    // MARK: - Duplicate-session collapse

    public static func dedupBySessionId(_ sessions: [SessionInfo]) -> [SessionInfo] {
        var winner: [String: SessionInfo] = [:]
        var order: [String] = []
        for s in sessions {
            if let cur = winner[s.sessionId] {
                if isFresher(s, than: cur) { winner[s.sessionId] = s }
            } else {
                winner[s.sessionId] = s
                order.append(s.sessionId)
            }
        }
        return order.compactMap { winner[$0] }
    }

    public static func isFresher(_ a: SessionInfo, than b: SessionInfo) -> Bool {
        let af = freshness(a), bf = freshness(b)
        if af != bf { return af > bf }
        return a.pid > b.pid
    }

    public static func freshness(_ s: SessionInfo) -> Double {
        max(s.updatedAt ?? 0, s.statusUpdatedAt ?? 0, s.startedAt ?? 0)
    }

    // MARK: - Antigravity presence lock & lsof parsers

    /// Extract `<conv-id>` from `~/.gemini/antigravity-cli/presence/<conv-id>.lock`
    /// (or any `/presence/<conv-id>.lock` / `<conv-id>.lock` filename).
    public static func conversationId(fromLockPath path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(".lock") else { return nil }
        let file = (trimmed as NSString).lastPathComponent
        guard !file.hasPrefix(".") else { return nil }
        let stem = String(file.dropLast(".lock".count))
        guard !stem.isEmpty,
              stem.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == "-" || $0.isLetter || $0.isNumber || $0 == "_") }) else {
            return nil
        }
        return stem
    }

    /// True when a `ps` `comm` string belongs to the Antigravity CLI (`agy`) or app.
    public static func isAGYProcess(comm: String) -> Bool {
        let trimmed = comm.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (trimmed as NSString).lastPathComponent.lowercased()
        if base == "agy" || base == "antigravity" || base == "antigravity-cli" {
            return true
        }
        let lower = trimmed.lowercased()
        return lower.contains("/antigravity.app/") || lower.contains("/antigravity ide.app/")
    }

    /// True when a bundle path or bundle identifier belongs to Antigravity Desktop / IDE.
    public static func isAntigravityDesktopApp(pathOrBundleId: String) -> Bool {
        let lower = pathOrBundleId.lowercased()
        return lower.contains("antigravity.app")
            || lower.contains("antigravity ide.app")
            || lower.contains("google.antigravity")
            || lower.contains("antigravity-ide")
    }

    /// Candidate `(bundleId, appName, appPath)` tuples for activating Antigravity Desktop / IDE.
    public static func antigravityAppCandidates(
        forSurface surface: String?
    ) -> [(bundleId: String, appName: String, appPath: String)] {
        let ide = ("com.google.antigravity.ide", "Antigravity IDE", "/Applications/Antigravity IDE.app")
        let desktop = ("com.google.antigravity", "Antigravity", "/Applications/Antigravity.app")
        if surface == AGYSurface.ide.rawValue {
            return [ide, desktop]
        }
        return [desktop, ide]
    }

    /// Parse `lsof` output (supports BOTH machine-readable `lsof -F pcfn` output AND
    /// default tabular `lsof -n -P` output!) to discover live PIDs holding open
    /// `presence/<conv-id>.lock` files plus their `cwd` working directories.
    public static func parseLsofPresence(_ output: String) -> [AGYPresenceLock] {
        guard !output.isEmpty else { return [] }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let first = lines.first else { return [] }

        // Detect `lsof -F` field-per-line mode: first line starts with `p<digits>`.
        if first.first == "p", Int(first.dropFirst()) != nil {
            return parseLsofFieldMode(lines)
        }
        return parseLsofTableMode(lines)
    }

    private static func parseLsofFieldMode(_ lines: [String]) -> [AGYPresenceLock] {
        var currentPid: Int? = nil
        var currentCmd: String? = nil
        var currentFD: String? = nil
        var cwdsByPid: [Int: String] = [:]
        var rawLocks: [(pid: Int, cmd: String?, convId: String, lockPath: String)] = []

        for line in lines {
            guard let prefix = line.first else { continue }
            let payload = String(line.dropFirst())
            switch prefix {
            case "p":
                currentPid = Int(payload)
                currentCmd = nil
                currentFD = nil
            case "c":
                currentCmd = payload
            case "f":
                currentFD = payload
            case "n":
                guard let pid = currentPid else { continue }
                if currentFD == "cwd" {
                    cwdsByPid[pid] = payload
                } else if payload.contains("/presence/") || payload.hasSuffix(".lock"),
                          let convId = conversationId(fromLockPath: payload) {
                    rawLocks.append((pid: pid, cmd: currentCmd, convId: convId, lockPath: payload))
                }
            default:
                break
            }
        }

        return deduplicateLocks(rawLocks.map { item in
            AGYPresenceLock(
                pid: item.pid,
                conversationId: item.convId,
                cwd: cwdsByPid[item.pid],
                command: item.cmd,
                lockPath: item.lockPath
            )
        })
    }

    private static func parseLsofTableMode(_ lines: [String]) -> [AGYPresenceLock] {
        var cwdsByPid: [Int: String] = [:]
        var rawLocks: [(pid: Int, cmd: String?, convId: String, lockPath: String)] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("COMMAND ") { continue }
            let cols = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // Standard lsof columns: COMMAND(0) PID(1) USER(2) FD(3) TYPE(4) DEVICE(5) SIZE/OFF(6) NODE(7) NAME(8...)
            guard cols.count >= 9, let pid = Int(cols[1]) else { continue }
            let cmd = cols[0]
            let fd = cols[3]
            // Extract path starting at first `/` after the metadata columns so paths with spaces survive!
            guard let path = extractTrailingAbsolutePath(fromLsofTableLine: trimmed) else { continue }
            if fd == "cwd" {
                cwdsByPid[pid] = path
            } else if path.contains("/presence/") || path.hasSuffix(".lock"),
                      let convId = conversationId(fromLockPath: path) {
                rawLocks.append((pid: pid, cmd: cmd, convId: convId, lockPath: path))
            }
        }

        return deduplicateLocks(rawLocks.map { item in
            AGYPresenceLock(
                pid: item.pid,
                conversationId: item.convId,
                cwd: cwdsByPid[item.pid],
                command: item.cmd,
                lockPath: item.lockPath
            )
        })
    }

    private static func extractTrailingAbsolutePath(fromLsofTableLine line: String) -> String? {
        // Walk past first 8 whitespace-separated tokens, then take the remainder from `/`.
        var idx = line.startIndex
        var tokenCount = 0
        while idx < line.endIndex && tokenCount < 8 {
            while idx < line.endIndex && (line[idx] == " " || line[idx] == "\t") {
                idx = line.index(after: idx)
            }
            guard idx < line.endIndex else { return nil }
            while idx < line.endIndex && line[idx] != " " && line[idx] != "\t" {
                idx = line.index(after: idx)
            }
            tokenCount += 1
        }
        let remainder = line[idx...].trimmingCharacters(in: .whitespaces)
        guard let slash = remainder.firstIndex(of: "/") else { return nil }
        var path = String(remainder[slash...])
        // Strip optional ` (deleted)` / lock mode suffix if lsof appended one after `.lock`.
        if let lockRange = path.range(of: ".lock ") {
            path = String(path[..<lockRange.lowerBound]) + ".lock"
        }
        return path
    }

    private static func deduplicateLocks(_ locks: [AGYPresenceLock]) -> [AGYPresenceLock] {
        var seen = Set<String>()
        var out: [AGYPresenceLock] = []
        for l in locks {
            let key = "\(l.pid):\(l.conversationId)"
            if seen.insert(key).inserted {
                out.append(l)
            }
        }
        return out
    }

    /// Parse `lsof -a -p <pids> -d cwd -Fpn` into `[pid: cwd]`.
    public static func parseLsofCwds(_ output: String) -> [Int: String] {
        var cwds: [Int: String] = [:]
        var currentPid: Int? = nil
        for sub in output.split(separator: "\n") {
            guard let first = sub.first else { continue }
            let rest = String(sub.dropFirst())
            if first == "p" {
                currentPid = Int(rest)
            } else if first == "n", let pid = currentPid, !rest.isEmpty {
                cwds[pid] = rest
            }
        }
        return cwds
    }

    /// Parse single-process `lsof -a -p <pid> -d cwd -Fn` output.
    public static func parseSingleLsofCwd(_ output: String) -> String? {
        for line in output.split(separator: "\n") where line.hasPrefix("n") {
            let p = String(line.dropFirst())
            if !p.isEmpty { return p }
        }
        return nil
    }

    // MARK: - Antigravity conversation metadata, workspace URI & swarm parsers

    /// Convert `"file:///Users/name/My%20Repo"` (or a bare path) into a clean POSIX path.
    public static func workspacePath(fromURI uri: String) -> String? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let path: String
        if trimmed.lowercased().hasPrefix("file://") {
            if let url = URL(string: trimmed), url.isFileURL {
                path = url.path
            } else {
                var stripped = String(trimmed.dropFirst("file://".count))
                if stripped.hasPrefix("localhost/") {
                    stripped = "/" + stripped.dropFirst("localhost/".count)
                }
                path = stripped.removingPercentEncoding ?? stripped
            }
        } else if trimmed.hasPrefix("/") {
            path = trimmed
        } else {
            return nil
        }
        guard !path.isEmpty else { return nil }
        if path.count > 1 && path.hasSuffix("/") {
            return String(path.dropLast())
        }
        return path
    }

    /// Parse SQLite `workspace_uris` JSON array column (e.g. `'["file:///Users/x/proj"]'`).
    public static func parseWorkspaceURIsJSON(_ jsonString: String?) -> [String] {
        guard let s = jsonString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty,
              let data = s.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return arr.compactMap(workspacePath(fromURI:))
    }

    /// Parse `~/.gemini/antigravity-cli/cache/conversation_metadata.json` into
    /// `[conversationId: AGYConversationMeta]`. Automatically filters `0001-01-01`
    /// sentinel timestamps to `nil`.
    public static func parseConversationMetadataJSON(_ data: Data) -> [String: AGYConversationMeta] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        let convDict = (root["conversations"] as? [String: Any]) ?? root
        var out: [String: AGYConversationMeta] = [:]

        for (convId, rawEntry) in convDict {
            guard !convId.isEmpty, let entry = rawEntry as? [String: Any] else { continue }
            let summary = entry["summary"] as? [String: Any]
            let id = (summary?["ID"] as? String) ?? convId

            let rawTitle = (summary?["Title"] as? String) ?? (entry["title"] as? String)
            let rawPreview = (summary?["Preview"] as? String) ?? (entry["preview"] as? String)
            let numSteps = (summary?["NumSteps"] as? Int) ?? (entry["step_count"] as? Int) ?? 0

            let updatedAt = AppDate.parseISO8601(
                (summary?["UpdatedAt"] as? String) ?? (entry["updated_at"] as? String)
            )
            let lastModAt = AppDate.parseISO8601(entry["last_modified_time"] as? String)

            var workspaces: [String] = []
            if let uris = summary?["WorkspaceURIs"] as? [String] {
                workspaces = uris.compactMap(workspacePath(fromURI:))
            } else if let urisJSON = entry["workspace_uris"] as? String {
                workspaces = parseWorkspaceURIsJSON(urisJSON)
            }

            let appDataDir = (summary?["AppDataDir"] as? String) ?? (entry["app_data_dir"] as? String)
            let status = (summary?["Status"] as? String) ?? (entry["status"] as? String)
            let notFullyIdle: Bool = {
                if let b = entry["not_fully_idle"] as? Bool { return b }
                if let i = entry["not_fully_idle"] as? Int { return i != 0 }
                if let b = summary?["NotFullyIdle"] as? Bool { return b }
                return false
            }()
            let isInternal = (entry["is_internal"] as? Bool)
                ?? (summary?["Internal"] as? Bool)
                ?? false
            let isKilled: Bool = {
                if let b = entry["killed"] as? Bool { return b }
                if let i = entry["killed"] as? Int { return i != 0 }
                if let b = summary?["Killed"] as? Bool { return b }
                return false
            }()
            let agentName = (summary?["AgentName"] as? String) ?? (entry["agent_name"] as? String)
            let parentId = (summary?["ParentConversationID"] as? String)
                ?? (entry["parent_conversation_id"] as? String)
            let nestingDepth = (summary?["NestingDepth"] as? Int)
                ?? (entry["nesting_depth"] as? Int)
                ?? 0

            out[id] = AGYConversationMeta(
                conversationId: id,
                title: TranscriptParse.cleaned(rawTitle),
                preview: TranscriptParse.cleaned(rawPreview),
                stepCount: numSteps,
                updatedAt: updatedAt,
                lastModifiedAt: lastModAt,
                workspacePaths: workspaces,
                appDataDir: (appDataDir?.isEmpty == true) ? nil : appDataDir,
                status: (status?.isEmpty == true) ? nil : status,
                notFullyIdle: notFullyIdle,
                isInternal: isInternal,
                isKilled: isKilled,
                agentName: (agentName?.isEmpty == true) ? nil : agentName,
                parentConversationId: (parentId?.isEmpty == true) ? nil : parentId,
                nestingDepth: nestingDepth
            )
        }
        return out
    }

    /// True when a conversation is an internal swarm worker or nested subagent.
    public static func isSubagentOrInternal(_ meta: AGYConversationMeta) -> Bool {
        if meta.isInternal || meta.nestingDepth > 0 {
            return true
        }
        if let parent = meta.parentConversationId, !parent.isEmpty {
            return true
        }
        return false
    }

    /// True when a conversation should appear as a top-level user session in the
    /// Sessions tab: excludes killed conversations, internal swarm workers / subagents,
    /// and abandoned 0-step sentinel conversations (unless actively held open via
    /// `hasLiveLock == true` in a live `agy` terminal).
    public static func isUserVisibleConversation(
        _ meta: AGYConversationMeta,
        hasLiveLock: Bool = false
    ) -> Bool {
        if meta.isKilled || isSubagentOrInternal(meta) {
            return false
        }
        if meta.stepCount <= 0 && meta.updatedAt == nil && !hasLiveLock {
            return false
        }
        return true
    }

    /// Combine DB/cache `CASCADE_RUN_STATUS_*` + `notFullyIdle` + `TranscriptSummary`
    /// into `(SessionStatus, waitingFor)`.
    public static func mapCascadeStatus(
        _ rawStatus: String?,
        notFullyIdle: Bool = false,
        transcriptSummary: TranscriptSummary? = nil,
        now: Date = Date()
    ) -> (status: SessionStatus, waitingFor: String?) {
        if transcriptSummary?.isWaitingForQuestion == true {
            return (.waiting, "input needed")
        }
        if let raw = rawStatus?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !raw.isEmpty {
            if raw.contains("WAITING") || raw.contains("CONFIRM") || raw.contains("PERMISSION") || raw.contains("APPROVAL") {
                let reason = (raw.contains("CONFIRM") || raw.contains("PERMISSION") || raw.contains("APPROVAL"))
                    ? "permission prompt"
                    : "input needed"
                return (.waiting, reason)
            }
            if raw.contains("RUNNING") || raw.contains("BUSY") || raw.contains("EXECUTING") {
                return (.busy, nil)
            }
            if raw.contains("IDLE") && !notFullyIdle {
                if let ts = transcriptSummary {
                    let inferred = ts.inferredStatus(notFullyIdle: false, now: now)
                    if inferred.status == .waiting { return inferred }
                }
                return (.idle, nil)
            }
        }
        if let ts = transcriptSummary {
            return ts.inferredStatus(notFullyIdle: notFullyIdle ? true : nil, now: now)
        }
        return notFullyIdle ? (.busy, nil) : (.idle, nil)
    }

    /// Parse `.system_generated/swarm/members.json` for a coordinator conversation.
    public static func parseSwarmMembersJSON(_ data: Data) -> (title: String?, members: [AGYSwarmMember])? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let membersDict = root["members"] as? [String: Any] else {
            return nil
        }
        let title = TranscriptParse.cleaned(root["title"] as? String)
        var members: [AGYSwarmMember] = []
        for name in membersDict.keys.sorted() {
            guard let m = membersDict[name] as? [String: Any],
                  let convId = m["conversation_id"] as? String else { continue }
            members.append(AGYSwarmMember(
                name: name,
                conversationId: convId,
                role: (m["role"] as? String) ?? "worker",
                phase: (m["phase"] as? String) ?? "UNKNOWN",
                wakeMode: m["wake_mode"] as? String,
                killed: (m["killed"] as? Bool) ?? false,
                appliedModel: m["applied_model"] as? String
            ))
        }
        return (title: title, members: members)
    }

    /// True if any non-killed worker in a swarm is actively executing a turn (`wake_mode == "working"`).
    public static func anySwarmWorkerBusy(_ members: [AGYSwarmMember]) -> Bool {
        members.contains { $0.isActivelyWorking }
    }

    // MARK: - Jump targeting (pure helpers)

    public static func appBundlePath(fromExecPath path: String) -> String? {
        if let r = path.range(of: ".app/") {
            return String(path[path.startIndex..<path.index(r.lowerBound, offsetBy: 4)])
        }
        return path.hasSuffix(".app") ? path : nil
    }

    public static func isMultiplexer(comm: String) -> Bool {
        let base = (comm as NSString).lastPathComponent.lowercased()
        return base == "tmux" || base.hasPrefix("tmux:")
            || base == "screen" || base == "screen-256color"
    }

    public static func classifyTerminal(commPath: String) -> TerminalKind {
        let p = commPath.lowercased()
        if p.contains("/antigravity ide.app/") || p.contains("/antigravity.app/") { return .antigravity }
        if p.contains("/otty.app/")      || p.hasSuffix("/otty") { return .otty }
        if p.contains("/ghostty.app/")   || p.contains("ghostty") { return .ghostty }
        if p.contains("/iterm.app/")     || p.contains("/iterm2") { return .iterm2 }
        if p.contains("/wezterm.app/")   || p.contains("wezterm") { return .wezterm }
        if p.contains("/kitty.app/")     || p.hasSuffix("/kitty") { return .kitty }
        if p.contains("/alacritty.app/") || p.contains("alacritty") { return .alacritty }
        if p.contains("/terminal.app/") { return .appleTerminal }
        return .unknown
    }

    public static func devTTY(_ tty: String?) -> String? {
        guard let t = tty, !t.isEmpty, t != "??" else { return nil }
        return t.hasPrefix("/dev/") ? t : "/dev/\(t)"
    }

    public static func normalizeOttyTitle(_ s: String) -> String {
        var out = s
        while let f = out.unicodeScalars.first,
              !(CharacterSet.alphanumerics.contains(f)) {
            out.removeFirst()
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func matchOttyPane(cwd: String, title: String?, panes: [OttyPane]) -> OttyMatch {
        let byCwd = panes.filter { $0.cwd == cwd }
        if byCwd.isEmpty { return .none }
        if let t = title.map(normalizeOttyTitle), !t.isEmpty {
            let hits = byCwd.filter { normalizeOttyTitle($0.title) == t }
            if hits.count == 1 { return .exact(paneId: hits[0].id) }
        }
        if byCwd.count == 1 { return .exact(paneId: byCwd[0].id) }
        return .ambiguous
    }

    public static func parseOttyPanes(_ json: String) -> [OttyPane]? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = root["data"] as? [[String: Any]] else { return nil }
        return arr.compactMap { p in
            guard let id = p["id"] as? String, let cwd = p["cwd"] as? String else { return nil }
            return OttyPane(id: id, cwd: cwd, title: (p["process"] as? String) ?? "")
        }
    }

    // MARK: - Process table parsing + ppid-chain targeting

    public struct ProcRow: Equatable, Sendable {
        public let ppid: Int
        public let tty: String
        public let comm: String

        public init(ppid: Int, tty: String, comm: String) {
            self.ppid = ppid
            self.tty = tty
            self.comm = comm
        }
    }

    public static func parseProcTable(_ out: String) -> [Int: ProcRow] {
        var table: [Int: ProcRow] = [:]
        for line in out.split(separator: "\n") {
            let toks = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard toks.count >= 4, let pid = Int(toks[0]), let ppid = Int(toks[1]) else { continue }
            let comm = toks[3...].joined(separator: " ")
            table[pid] = ProcRow(ppid: ppid, tty: toks[2], comm: comm)
        }
        return table
    }

    public static func parsePsLine(_ line: String) -> (pid: Int, lstart: String, comm: String)? {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.count >= 7, let pid = Int(tokens[0]) else { return nil }
        let lstart = tokens[1...5].joined(separator: " ")
        let comm = tokens[6...].joined(separator: " ")
        return (pid, lstart, comm)
    }

    public struct ProcTarget: Equatable, Sendable {
        public let tty: String?
        public let terminal: TerminalKind
        public let appBundlePath: String?
        public let appPid: Int?
        public let multiplexed: Bool
        public let pidPresent: Bool

        public init(
            tty: String?,
            terminal: TerminalKind,
            appBundlePath: String?,
            appPid: Int?,
            multiplexed: Bool,
            pidPresent: Bool
        ) {
            self.tty = tty
            self.terminal = terminal
            self.appBundlePath = appBundlePath
            self.appPid = appPid
            self.multiplexed = multiplexed
            self.pidPresent = pidPresent
        }
    }

    public static func resolveTarget(table: [Int: ProcRow], pid: Int) -> ProcTarget {
        let own = table[pid]
        var multiplexed = false
        var terminal: TerminalKind = .unknown
        var appPid: Int? = nil
        var appBundle: String? = nil
        var cursor = own?.ppid ?? 0
        var hops = 0
        while let row = table[cursor], hops < 12 {
            hops += 1
            if isMultiplexer(comm: row.comm) { multiplexed = true }
            if let bundle = appBundlePath(fromExecPath: row.comm) {
                appBundle = bundle
                appPid = cursor
                terminal = classifyTerminal(commPath: row.comm)
                break
            }
            if row.ppid <= 1 { break }
            cursor = row.ppid
        }
        return ProcTarget(
            tty: own?.tty,
            terminal: terminal,
            appBundlePath: appBundle,
            appPid: appPid,
            multiplexed: multiplexed,
            pidPresent: own != nil
        )
    }

    // MARK: - Status dot (pure decision)

    public enum SessionDotKind: Equatable, Sendable {
        case busy
        case waiting
        case doneUnseen
        case grey
    }

    public static func dotKind(status: SessionStatus, doneUnseen: Bool) -> SessionDotKind {
        switch status {
        case .busy:    return .busy
        case .waiting: return .waiting
        case .idle, .shell, .unknown:
            return doneUnseen ? .doneUnseen : .grey
        }
    }

    // MARK: - AppleScript builders

    public static func appleTerminalFocusScript(devTTY: String) -> String {
        let tty = devTTY.replacingOccurrences(of: "\"", with: "")
        return """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected of t to true
                        set index of w to 1
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "notfound"
        """
    }

    public static func itermFocusScript(devTTY: String) -> String {
        let tty = devTTY.replacingOccurrences(of: "\"", with: "")
        return """
        tell application "iTerm2"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select s
                            select t
                            select w
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "notfound"
        """
    }

    // MARK: - Done-unseen reducer

    public static func justFinished(
        previous: [String: SessionStatus],
        current: [SessionInfo]
    ) -> [String] {
        current.compactMap { s in
            guard let prev = previous[s.sessionId] else { return nil }
            let wasActive = (prev == .busy || prev == .waiting)
            let nowDone = (s.status == .idle || s.status == .shell)
            return (wasActive && nowDone) ? s.sessionId : nil
        }
    }

    public static func stepDoneUnseen(
        prev: [String: SessionStatus],
        current: [SessionInfo],
        doneUnseen: [String: Double],
        seenAll: Bool,
        now: Double
    ) -> (prev: [String: SessionStatus], doneUnseen: [String: Double]) {
        let curStatus = Dictionary(
            current.map { ($0.sessionId, $0.status) },
            uniquingKeysWith: { _, b in b }
        )
        guard !seenAll else { return (curStatus, [:]) }

        var next = doneUnseen
        for id in justFinished(previous: prev, current: current) {
            next[id] = now
        }
        let currentIds = Set(curStatus.keys)
        for (id, _) in next {
            if let st = curStatus[id], st == .busy || st == .waiting {
                next.removeValue(forKey: id)
            } else if !currentIds.contains(id) {
                next.removeValue(forKey: id)
            }
        }
        return (curStatus, next)
    }
}
