import Foundation

// MARK: - Helpers

func formatCost(_ value: Double) -> String {
    let v = value.isFinite ? value : 0
    if v >= 100 { return String(format: "$%.0f", v) }
    if v >= 10  { return String(format: "$%.1f", v) }
    return String(format: "$%.2f", v)
}

/// Tabular two-decimal currency formatting for Hero readouts and aligned model ledgers.
func formatCostTabular(_ value: Double) -> String {
    CurrencyFormatting.formatTabular(value)
}

/// Explicit-sign rounded integer percentage (e.g. "+18%", "-12%", "0%").
func formatSignedPercent(_ value: Double) -> String {
    guard value.isFinite else { return "0%" }
    let clamped = min(max(value, -999_999.0), 999_999.0)
    let rounded = Int(clamped.rounded())
    if rounded > 0 { return "+\(rounded)%" }
    return "\(rounded)%"
}

func formatTokensShort(_ count: Int) -> String {
    if count >= 1_000_000_000 { return String(format: "%.1fb", Double(count) / 1_000_000_000) }
    if count >= 1_000_000 { return String(format: "%.1fm", Double(count) / 1_000_000) }
    if count >= 1_000     { return String(format: "%.1fk", Double(count) / 1_000) }
    return "\(count)"
}

func formatNumber(_ n: Int) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    return f.string(from: NSNumber(value: n)) ?? "\(n)"
}

func timeAgo(_ date: Date, _ loc: Localizer) -> String {
    let elapsed = -date.timeIntervalSinceNow
    guard elapsed.isFinite else { return loc("justNow") }
    let clamped = min(max(elapsed, 0.0), Double(Int.max / 2))
    let seconds = Int(clamped)
    if seconds < 60    { return loc("justNow") }
    if seconds < 3600  { return String(format: loc("mAgo"), seconds / 60) }
    if seconds < 86400 { return String(format: loc("hAgo"), seconds / 3600) }
    return String(format: loc("dAgo"), seconds / 86400)
}
