import Foundation

// MARK: - Model class (pure core)
//
// Single source of truth for the Google Antigravity model-class taxonomy that
// `analyze_usage.py` emits (`totals_by_model` / `daily_breakdown.*.models` keys)
// and that `AGYQuotaParser` assigns to per-model quota buckets.
//
// CaseIterable order IS the display/iteration order (ordered from highest to
// lowest model tier: Carbon, Argon, Neon, Hydrogen, Flash Gemini tiers, then
// Claude partner models, and Other last).
// Color mapping deliberately lives in Views_Common.swift so SwiftUI never enters
// the pure core.
public enum ModelClass: String, Codable, CaseIterable, Sendable {
    case carbon   = "carbon"
    case argon    = "argon"
    case neon     = "neon"
    case hydrogen = "hydrogen"
    case flash    = "flash"
    case claude   = "claude"
    case other    = "other"

    /// Concise human-facing label used in compact model rows and chips.
    public var displayName: String {
        switch self {
        case .carbon:   return "Carbon"
        case .argon:    return "Argon"
        case .neon:     return "Neon"
        case .hydrogen: return "Hydrogen"
        case .flash:    return "Flash"
        case .claude:   return "Claude"
        case .other:    return "Other"
        }
    }

    /// Full provider-qualified display name.
    public var fullDisplayName: String {
        switch self {
        case .carbon:   return "Gemini Carbon"
        case .argon:    return "Gemini Argon"
        case .neon:     return "Gemini Neon"
        case .hydrogen: return "Gemini Hydrogen"
        case .flash:    return "Gemini Flash"
        case .claude:   return "Claude"
        case .other:    return "Other"
        }
    }

    /// Three-letter telemetry channel code used in compact ledgers and charts.
    public var shortCode: String {
        switch self {
        case .carbon:   return "CRB"
        case .argon:    return "ARG"
        case .neon:     return "NEO"
        case .hydrogen: return "HYD"
        case .flash:    return "FLS"
        case .claude:   return "CLD"
        case .other:    return "OTH"
        }
    }

    /// True when this class belongs to Google's first-party Gemini quota family.
    public var isGeminiFamily: Bool {
        switch self {
        case .carbon, .argon, .neon, .hydrogen, .flash:
            return true
        case .claude, .other:
            return false
        }
    }

    /// Exact rawValue lookup (case-insensitive). Returns nil for unknown keys.
    public static func parse(_ key: String) -> ModelClass? {
        ModelClass(rawValue: key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Classify any raw model identifier or display label into a `ModelClass`.
    /// Must stay in lockstep with `classify_model(raw)` in `analyze_usage.py`.
    public static func classify(_ raw: String) -> ModelClass {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty { return .other }
        if lower.contains("hydrogen") || lower.contains("flash-worker-agy") {
            return .hydrogen
        }
        // Check "argon" and "neon" BEFORE "orchestrator" so
        // "gemini-pro-orchestrator-argon" / "Orchestrator (Argon)" classify as `.argon`
        // and "gemini-pro-orchestrator-neon" / "Orchestrator (Neon)" classify as `.neon`.
        if lower.contains("argon") {
            return .argon
        }
        if lower.contains("neon") {
            return .neon
        }
        if lower.contains("carbon")
            || lower.contains("orchestrator")
            || (lower.contains("gemini") && lower.contains("pro"))
            || lower.contains("ultra") {
            return .carbon
        }
        if lower.contains("flash") || lower.contains("lite") {
            return .flash
        }
        if lower.contains("claude")
            || lower.contains("opus")
            || lower.contains("sonnet")
            || lower.contains("haiku") {
            return .claude
        }
        return .other
    }
}
