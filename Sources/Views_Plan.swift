import SwiftUI
import AppKit

// Plan tab: Antigravity rolling quota buckets (Gemini & Claude/Partner), account tier,
// Google One AI Credits (Prompt / Flow / Flex), and Desktop offline-cache badge.

// MARK: - Quota Window Row

/// One quota window rendered with "remaining" framing (`"99% left"`), matching how
/// Antigravity `/usage` presents rolling ~5h model buckets.
struct SubWindowRow: View {
    let label: String
    let usedPercent: Int          // 0-100+ used percentage
    let resetAt: Date?
    var accentModelClasses: [ModelClass] = []
    @Environment(\.localizer) private var loc

    private var remaining: Int { max(0, 100 - usedPercent) }
    private var remainingFraction: CGFloat { max(0, min(1, CGFloat(remaining) / 100.0)) }

    /// Green >=30% left, amber 10–29% left, coral <10% left.
    private var color: Color {
        switch remaining {
        case 30...:   return Color(red: 0.20, green: 0.78, blue: 0.45) // green
        case 10..<30: return Color(red: 0.95, green: 0.70, blue: 0.25) // amber
        default:      return Color(red: 0.90, green: 0.40, blue: 0.30) // coral
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if !accentModelClasses.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(accentModelClasses, id: \.rawValue) { mc in
                            Circle()
                                .fill(modelClassColor(mc))
                                .frame(width: 5.5, height: 5.5)
                        }
                    }
                }
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer()
                if let r = resetAt {
                    Text(String(format: loc("subResetFmt"), shortDuration(r)))
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: loc("subRemaining"), "\(remaining)%"))
                    .font(.system(size: 20, weight: .bold).monospacedDigit())
                    .foregroundColor(color)
                Spacer()
                Text(String(format: loc("subUsedFmt"), usedPercent))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundColor(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.18))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(width: max(2, geo.size.width * remainingFraction))
                }
            }
            .frame(height: 8)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private func shortDuration(_ date: Date) -> String {
        let s = max(0, date.timeIntervalSinceNow)
        if s < 60 { return "<1m" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 {
            let h = Int(s / 3600), m = Int((s.truncatingRemainder(dividingBy: 3600)) / 60)
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        let d = Int(s / 86400), h = Int((s.truncatingRemainder(dividingBy: 86400)) / 3600)
        return h > 0 ? "\(d)d \(h)h" : "\(d)d"
    }
}

// MARK: - Plan Account & Tier Header

private struct PlanAccountHeader: View {
    let email: String?
    let tier: String?
    let isOfflineCached: Bool
    @Environment(\.localizer) private var loc

    private var formattedTier: String? {
        guard let raw = tier?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        switch raw.uppercased() {
        case "G1_PRO_TIER", "G1_PRO_LITE_TIER":     return "Google AI Pro"
        case "G1_ULTRA_TIER", "G1_ULTRA_LITE_TIER": return "Google AI Ultra"
        case "FREE_TIER":                           return "Free"
        case "ENTERPRISE_AGENT_TIER":               return "Enterprise"
        default:                                    return raw
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if let badge = formattedTier {
                HStack(spacing: 4) {
                    LogoShape()
                        .fill(Color.agyBrand)
                        .frame(width: 9, height: 9)
                    Text(badge)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.agyBrand)
                        .lineLimit(1)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.agyBrand.opacity(0.12)))
            }

            if let mail = email?.trimmingCharacters(in: .whitespacesAndNewlines), !mail.isEmpty {
                Text(mail)
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            if isOfflineCached {
                HStack(spacing: 3) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 9))
                    Text(loc("subOfflineCached"))
                        .font(.system(size: 9.5, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
        }
        .padding(.horizontal, 2)
    }
}

// MARK: - AI Credits Card

private struct AICreditsCard: View {
    let promptCredits: Int?
    let flowCredits: Int?
    let flexCredits: Int?
    @Environment(\.localizer) private var loc

    private var pools: [(label: String, value: Int)] {
        var out: [(String, Int)] = []
        if let p = promptCredits { out.append((loc("subPromptCredits"), p)) }
        if let f = flowCredits   { out.append((loc("subFlowCredits"), f)) }
        if let x = flexCredits   { out.append((loc("subFlexCredits"), x)) }
        return out
    }

    var body: some View {
        let items = pools
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.agyBrand)
                    Text(loc("subCreditsTitle"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                    Spacer()
                }
                HStack(spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, pool in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pool.label)
                                .font(.system(size: 9.5))
                                .foregroundColor(.secondary)
                            Text(formatNumber(pool.value))
                                .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundColor(.primary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(0.035))
                        )
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        }
    }
}

// MARK: - Plan Tab View

struct SubscriptionView: View {
    @ObservedObject var store: UsageStore
    @Environment(\.localizer) private var loc

    private func nonEmpty(_ s: String?) -> String? {
        guard let trimmed = s?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func primaryWindowLabel(
        _ window: OAuthUsageWindow,
        defaultKey: String,
        canonicalEnglishLabels: [String]
    ) -> String {
        guard let custom = nonEmpty(window.label) else { return loc(defaultKey) }
        if canonicalEnglishLabels.contains(custom) {
            return loc(defaultKey)
        }
        return custom
    }

    var body: some View {
        VStack(spacing: 8) {
            if let q = store.subscriptionQuota {
                let geminiWeeklyLimits = q.scopedModelLimits.filter { $0.scope?.model?.id == "gemini_weekly" }
                let otherScopedLimits = q.scopedModelLimits.filter { $0.scope?.model?.id != "gemini_weekly" }

                // Account email, plan tier badge, and optional Desktop offline-cache badge
                if nonEmpty(q.planTier) != nil || nonEmpty(q.accountEmail) != nil || q.isOfflineCached {
                    PlanAccountHeader(
                        email: q.accountEmail,
                        tier: q.planTier,
                        isOfflineCached: q.isOfflineCached
                    )
                }

                // 1. Primary Gemini rolling ~5h bucket
                if q.five_hour.resets_at != nil
                    || q.five_hour.displayPercent > 0
                    || nonEmpty(q.five_hour.label) != nil
                    || q.scopedModelLimits.isEmpty {
                    SubWindowRow(
                        label: primaryWindowLabel(
                            q.five_hour,
                            defaultKey: "sub5hLabel",
                            canonicalEnglishLabels: ["Gemini Models", "Gemini · 5h limit"]
                        ),
                        usedPercent: q.five_hour.displayPercent,
                        resetAt: q.fiveHourResetDate,
                        accentModelClasses: ModelClass.allCases.filter(\.isGeminiFamily)
                    )
                }

                // 2. Gemini 7-day rolling bucket (grouped directly under Gemini 5h)
                ForEach(Array(geminiWeeklyLimits.enumerated()), id: \.offset) { _, lim in
                    SubWindowRow(
                        label: loc("sub1pWeeklyLabel"),
                        usedPercent: lim.displayPercent,
                        resetAt: lim.resetDate,
                        accentModelClasses: ModelClass.allCases.filter(\.isGeminiFamily)
                    )
                }

                // 3. Secondary Claude & GPT rolling ~5h bucket
                if q.seven_day.resets_at != nil
                    || q.seven_day.displayPercent > 0
                    || nonEmpty(q.seven_day.label) != nil {
                    SubWindowRow(
                        label: primaryWindowLabel(
                            q.seven_day,
                            defaultKey: "sub7dLabel",
                            canonicalEnglishLabels: ["Claude & GPT · 5h", "Claude & Partner", "Claude & GPT · 5h limit"]
                        ),
                        usedPercent: q.seven_day.displayPercent,
                        resetAt: q.sevenDayResetDate,
                        accentModelClasses: [.claude, .other]
                    )
                }

                // 4. Claude & GPT 7-day rolling bucket + any other scoped limits
                ForEach(Array(otherScopedLimits.enumerated()), id: \.offset) { _, lim in
                    let limitId = lim.scope?.model?.id ?? ""
                    if limitId == "claude_partner_weekly" {
                        SubWindowRow(
                            label: loc("sub3pWeeklyLabel"),
                            usedPercent: lim.displayPercent,
                            resetAt: lim.resetDate,
                            accentModelClasses: [.claude, .other]
                        )
                    } else {
                        let rawName = lim.modelDisplayName ?? ""
                        let classified = ModelClass.classify(rawName)
                        SubWindowRow(
                            label: String(format: loc("sub7dScopedFmt"), rawName),
                            usedPercent: lim.displayPercent,
                            resetAt: lim.resetDate,
                            accentModelClasses: [classified]
                        )
                    }
                }

                // Legacy optional secondary bucket fallback
                if let sonnet = q.seven_day_sonnet,
                   sonnet.displayPercent > 0 || sonnet.resets_at != nil,
                   !q.scopedModelLimits.contains(where: {
                       $0.modelDisplayName?.caseInsensitiveCompare("Claude") == .orderedSame }) {
                    SubWindowRow(
                        label: nonEmpty(sonnet.label) ?? loc("sub7dSonnetLabel"),
                        usedPercent: sonnet.displayPercent,
                        resetAt: q.sevenDaySonnetResetDate,
                        accentModelClasses: [.claude]
                    )
                }

                // Google One AI Credits (Prompt / Flow / Flex)
                if q.hasCredits {
                    AICreditsCard(
                        promptCredits: q.promptCredits,
                        flowCredits: q.flowCredits,
                        flexCredits: q.flexCredits
                    )
                }

                if q.extra_usage?.is_enabled == true {
                    HStack(spacing: 6) {
                        Image(systemName: "creditcard")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(loc("subExtraOn"))
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 2)
                }

                if store.quotaError != nil {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(errorText)
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 2)
                }
            } else if store.quotaError != nil {
                stateMessage(icon: "exclamationmark.triangle", text: errorText)
            } else {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(loc("subWaitData"))
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                .frame(height: 80)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private func stateMessage(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundColor(.secondary)
            Text(text).font(.system(size: 11)).foregroundColor(.secondary)
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private var errorText: String {
        switch store.quotaError {
        case .unauthorized:
            return loc("quotaTokenExpired")
        case .rateLimited:
            if let retryAt = store.quotaRetryAt, retryAt > Date() {
                return String(format: loc("quotaRateLimitedRetry"), retryCountdown(retryAt))
            }
            return loc("quotaRateLimited")
        case .decodeFailure:
            return loc("quotaDecodeFail")
        case .networkFailure, nil:
            return loc("quotaFetchFail")
        }
    }

    private func retryCountdown(_ date: Date) -> String {
        let s = max(0, date.timeIntervalSinceNow)
        if s < 60 { return "<1m" }
        if s < 3600 { return "\(Int(s / 60))m" }
        let h = Int(s / 3600), m = Int((s.truncatingRemainder(dividingBy: 3600)) / 60)
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }
}
