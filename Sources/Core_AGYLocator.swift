import Foundation

// MARK: - Google Antigravity data, DB, binary & cache path resolution — pure core
//
// Foundation-only deterministic path generation with `home` / `env` injected.
// Zero FileManager / SQLite / Process I/O in this file — app-side services
// (`UsageStore`, `SessionMonitor`, `AITitleReader`, `QuotaService`) stat/open
// these candidate paths on their own background queues.

/// Antigravity product surfaces sharing the `~/.gemini/` local agent layout.
public enum AGYSurface: String, CaseIterable, Codable, Equatable, Sendable {
    /// `agy` CLI (`~/.gemini/antigravity-cli/`)
    case cli     = "antigravity-cli"
    /// Antigravity 2.0 Desktop (`~/.gemini/antigravity/`)
    case desktop = "antigravity"
    /// Antigravity IDE (`~/.gemini/antigravity-ide/`)
    case ide     = "antigravity-ide"

    public var displayName: String {
        switch self {
        case .cli:     return "Antigravity CLI"
        case .desktop: return "Antigravity"
        case .ide:     return "Antigravity IDE"
        }
    }
}

public enum AGYLocator {
    public static let appName = "AGYMonitor"
    public static let bundleIdentifier = "com.kuen54.AGYMonitor"

    /// `ItemTable` keys inside `User/globalStorage/state.vscdb`.
    public static let userStatusStateKey   = "antigravityUnifiedStateSync.userStatus"
    public static let modelCreditsStateKey = "antigravityUnifiedStateSync.modelCredits"

    private static func join(_ base: String, _ component: String) -> String {
        (base as NSString).appendingPathComponent(component)
    }

    private static func deduplicated(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for p in paths where !p.isEmpty {
            let normalized = (p as NSString).standardizingPath
            if seen.insert(normalized).inserted {
                result.append(normalized)
            }
        }
        return result
    }

    // MARK: - ~/.gemini roots & brain directories

    /// `~/.gemini`
    public static func geminiRoot(home: String) -> String {
        join(home, ".gemini")
    }

    /// Root directory for a single Antigravity surface (e.g. `~/.gemini/antigravity-cli`).
    public static func surfaceRoot(home: String, surface: AGYSurface) -> String {
        join(geminiRoot(home: home), surface.rawValue)
    }

    /// All Antigravity surface data roots in priority order (optional env override first,
    /// then CLI, Desktop, IDE).
    public static func surfaceRoots(home: String, envDataDir: String? = nil) -> [String] {
        var roots: [String] = []
        if let env = envDataDir?.trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            roots.append(env)
        }
        for surface in AGYSurface.allCases {
            roots.append(surfaceRoot(home: home, surface: surface))
        }
        return deduplicated(roots)
    }

    /// All `brain` directories across surfaces (`~/.gemini/{antigravity-cli,antigravity,antigravity-ide}/brain`).
    /// Note: if `envDataDir` already ends with `/brain`, it is used directly alongside `<envDataDir>/brain`.
    public static func brainDirs(home: String, envDataDir: String? = nil) -> [String] {
        var dirs: [String] = []
        if let env = envDataDir?.trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            if (env as NSString).lastPathComponent == "brain" {
                dirs.append(env)
            } else {
                dirs.append(join(env, "brain"))
            }
        }
        for surface in AGYSurface.allCases {
            dirs.append(join(surfaceRoot(home: home, surface: surface), "brain"))
        }
        return deduplicated(dirs)
    }

    /// Exact path to a conversation's primary compact step transcript:
    /// `<brainDir>/<conversationId>/.system_generated/logs/transcript.jsonl`
    public static func transcriptPath(brainDir: String, conversationId: String) -> String {
        join(join(join(join(brainDir, conversationId), ".system_generated"), "logs"), "transcript.jsonl")
    }

    /// Candidate `transcript.jsonl` paths for `conversationId`, putting `preferredSurface`
    /// (`"antigravity-cli"` | `"antigravity"` | `"antigravity-ide"`) first when known.
    public static func candidateTranscriptPaths(
        home: String,
        conversationId: String,
        preferredSurface: String? = nil,
        envDataDir: String? = nil
    ) -> [String] {
        guard !conversationId.isEmpty else { return [] }
        var orderedBrains: [String] = []
        if let pref = preferredSurface?.trimmingCharacters(in: .whitespacesAndNewlines),
           let surface = AGYSurface(rawValue: pref) {
            orderedBrains.append(join(surfaceRoot(home: home, surface: surface), "brain"))
        }
        orderedBrains.append(contentsOf: brainDirs(home: home, envDataDir: envDataDir))
        return deduplicated(orderedBrains).map { transcriptPath(brainDir: $0, conversationId: conversationId) }
    }

    /// Swarm roster file for a coordinator conversation:
    /// `<brainDir>/<conversationId>/.system_generated/swarm/members.json`
    public static func swarmMembersPath(brainDir: String, conversationId: String) -> String {
        join(join(join(join(brainDir, conversationId), ".system_generated"), "swarm"), "members.json")
    }

    // MARK: - CLI session, metadata, SQLite & log paths

    /// `~/.gemini/antigravity-cli/presence` (each live `agy` CLI holds `<conv-id>.lock`).
    public static func presenceDir(home: String) -> String {
        join(surfaceRoot(home: home, surface: .cli), "presence")
    }

    /// `~/.gemini/antigravity-cli/presence/<conversationId>.lock`
    public static func presenceLockPath(home: String, conversationId: String) -> String {
        join(presenceDir(home: home), "\(conversationId).lock")
    }

    /// `~/.gemini/antigravity-cli/conversation_summaries.db`
    public static func conversationSummariesDBPath(home: String) -> String {
        join(surfaceRoot(home: home, surface: .cli), "conversation_summaries.db")
    }

    /// `~/.gemini/antigravity-cli/cache/conversation_metadata.json`
    public static func conversationMetadataJSONPath(home: String) -> String {
        join(join(surfaceRoot(home: home, surface: .cli), "cache"), "conversation_metadata.json")
    }

    /// `~/.gemini/antigravity-cli/cache/last_conversations.json`
    public static func lastConversationsJSONPath(home: String) -> String {
        join(join(surfaceRoot(home: home, surface: .cli), "cache"), "last_conversations.json")
    }

    /// `~/.gemini/antigravity-cli/history.jsonl`
    public static func historyJSONLPath(home: String) -> String {
        join(surfaceRoot(home: home, surface: .cli), "history.jsonl")
    }

    /// `~/.gemini/antigravity-cli/annotations`
    public static func annotationsDir(home: String) -> String {
        join(surfaceRoot(home: home, surface: .cli), "annotations")
    }

    /// `~/.gemini/antigravity-cli/annotations/<conversationId>.pbtxt`
    public static func annotationPath(home: String, conversationId: String) -> String {
        join(annotationsDir(home: home), "\(conversationId).pbtxt")
    }

    /// `<surfaceRoot>/conversations/<conversationId>.db`
    public static func conversationDBPath(surfaceRoot: String, conversationId: String) -> String {
        join(join(surfaceRoot, "conversations"), "\(conversationId).db")
    }

    /// Candidate per-conversation SQLite DB paths across surfaces.
    public static func candidateConversationDBPaths(
        home: String,
        conversationId: String,
        envDataDir: String? = nil
    ) -> [String] {
        guard !conversationId.isEmpty else { return [] }
        return surfaceRoots(home: home, envDataDir: envDataDir)
            .map { conversationDBPath(surfaceRoot: $0, conversationId: conversationId) }
    }

    /// `~/.gemini/antigravity-cli/log` (contains `cli-YYYYMMDD_HHMMSS.log`).
    public static func cliLogDir(home: String) -> String {
        join(surfaceRoot(home: home, surface: .cli), "log")
    }

    // MARK: - Desktop / IDE state.vscdb & binary paths

    /// Candidate Electron/VSCode `state.vscdb` files holding `antigravityUnifiedStateSync.*`
    /// (`Antigravity` Desktop first, then `Antigravity IDE`).
    public static func candidateStateVSCDBPaths(home: String) -> [String] {
        let appSupport = join(join(home, "Library"), "Application Support")
        return [
            join(join(join(join(appSupport, "Antigravity"), "User"), "globalStorage"), "state.vscdb"),
            join(join(join(join(appSupport, "Antigravity IDE"), "User"), "globalStorage"), "state.vscdb"),
        ]
    }

    /// Candidate `agy` CLI executable paths in priority order.
    public static func candidateAGYBinaryPaths(home: String, envPath: String? = nil) -> [String] {
        var candidates: [String] = []
        if let envPath = envPath, !envPath.isEmpty {
            for entry in envPath.split(separator: ":") {
                let dir = String(entry).trimmingCharacters(in: .whitespacesAndNewlines)
                if !dir.isEmpty {
                    candidates.append(join(dir, "agy"))
                }
            }
        }
        candidates.append(contentsOf: [
            join(join(home, ".local/bin"), "agy"),
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
            "/Applications/Antigravity.app/Contents/Resources/app/bin/agy",
            "/Applications/Antigravity IDE.app/Contents/Resources/app/extensions/agy/bin/agy",
        ])
        return deduplicated(candidates)
    }

    // MARK: - AGYMonitor own storage paths

    /// `~/Library/Application Support/AGYMonitor`
    public static func appSupportDir(home: String) -> String {
        join(join(join(home, "Library"), "Application Support"), appName)
    }

    /// `~/Library/Application Support/AGYMonitor/archive`
    public static func archiveDir(home: String) -> String {
        join(appSupportDir(home: home), "archive")
    }

    /// `~/Library/Caches/AGYMonitor`
    public static func cacheDir(home: String) -> String {
        join(join(join(home, "Library"), "Caches"), appName)
    }

    // MARK: - SQLite WAL read-only URI helpers

    /// Build SQLite URI filenames for safe read-only opens of WAL-mode databases
    /// (`conversation_summaries.db`, `conversations/<id>.db`, `state.vscdb`).
    ///
    /// Why TWO URIs are returned in order:
    /// 1. `file:<encoded>?mode=ro` — sees live `-wal` frames when a writer is active.
    /// 2. `file:<encoded>?mode=ro&immutable=1` — essential fallback! When the writer
    ///    exited cleanly and removed `-shm`/`-wal`, SQLite's `?mode=ro` on a WAL DB
    ///    fails with `SQLITE_CANTOPEN` because read-only callers cannot create `-shm`.
    ///    Retrying with `immutable=1` succeeds cleanly without modifying disk.
    public static func sqliteReadOnlyURIs(forPath path: String) -> [String] {
        guard !path.isEmpty else { return [] }
        let encoded = encodeSQLiteURIPath(path)
        return [
            "file:\(encoded)?mode=ro",
            "file:\(encoded)?mode=ro&immutable=1",
        ]
    }

    /// Percent-encode `?`, `#`, `%`, and ASCII space per SQLite's URI filename rules
    /// (`https://www.sqlite.org/uri.html`), preserving `/` path separators and UTF-8.
    public static func encodeSQLiteURIPath(_ path: String) -> String {
        var out = ""
        out.reserveCapacity(path.count + 8)
        for scalar in path.unicodeScalars {
            switch scalar {
            case "%": out.append("%25")
            case "?": out.append("%3F")
            case "#": out.append("%23")
            case " ": out.append("%20")
            default:  out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
