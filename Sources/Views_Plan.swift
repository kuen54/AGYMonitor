import SwiftUI
import AppKit

// Plan tab: Single-plane dual-track quota instruments with 60-tick Vernier Scale
// & calibrated `▼` Pace Marker, plus flush 3-column AI Credits matrix.

// MARK: - Quota Track Row

private struct QuotaTrackRow: View {
    let label: String
    let usedPercent: Int
    let resetAt: Date?
    let windowDurationSeconds: TimeInterval

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme

    private var remaining: Int { max(0, 100 - usedPercent) }
    private var remainingFraction: CGFloat { max(0, min(1, CGFloat(remaining) / 100.0)) }

    private var pace: QuotaPaceSnapshot? {
        QuotaPaceLogic.compute(
            usedPercent: usedPercent,
            resetAt: resetAt,
            windowDurationSeconds: windowDurationSeconds,
            now: Date()
        )
    }

    private var statusColor: Color {
        switch remaining {
        case 30...:   return theme.accent
        case 10..<30: return theme.signalAmber
        default:      return theme.signalRed
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.inkSecondary)

                Spacer(minLength: 4)

                if let p = pace {
                    let sign = p.paceDeltaPercent > 0 ? "+\(p.paceDeltaPercent)%" : "\(p.paceDeltaPercent)%"
                    let paceLabel = String(format: loc("planPaceFmt"), sign)
                    Text(p.isOverPaceWarning ? "▲ \(paceLabel)" : paceLabel)
                        .font(.system(size: 8.5, weight: p.isOverPaceWarning ? .bold : .medium, design: .monospaced))
                        .foregroundColor(p.isOverPaceWarning ? theme.signalAmber : theme.inkSecondary)
                }

                if let r = resetAt {
                    Text(String(format: loc("planResetShortFmt"), formatQuotaResetDuration(r).uppercased()))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.inkSecondary)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                PrecisionHeroNumber(
                    whole: "\(remaining)",
                    suffix: "% LEFT",
                    size: 24,
                    accentPrimary: remaining < 30 ? statusColor : nil
                )
                Spacer()
                Text(String(format: loc("subUsedFmt"), usedPercent).uppercased())
                    .font(.system(size: 9, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(theme.inkMuted)
            }

            VernierScaleBar(
                fraction: remainingFraction,
                fillColor: statusColor,
                paceMarkerFraction: pace.map { CGFloat($0.expectedRemainingFraction) },
                paceWarning: pace?.isOverPaceWarning == true,
                ticks: 60
            )
        }
    }
}

// MARK: - Plan Family Header (Bare Monospace Codes, Zero Skittles)

struct FamilySectionHeader: View {
    let title: String
    let codes: String
    @Environment(\.agyTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .tracking(0.6)
                .foregroundColor(theme.inkPrimary)
            Spacer()
            Text(codes)
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .foregroundColor(theme.inkMuted)
        }
    }
}

func formatQuotaResetDuration(_ date: Date) -> String {
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

// MARK: - Plan Account Strip

struct PlanAccountStrip: View {
    let email: String?
    let isOfflineCached: Bool
    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            if let mail = email?.trimmingCharacters(in: .whitespacesAndNewlines), !mail.isEmpty {
                Text("USER // \(mail)")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if isOfflineCached {
                Text(loc("subOfflineCached").uppercased())
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.signalAmber)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

// MARK: - AI Credits Matrix Section

struct AICreditsSection: View {
    let promptCredits: Int?
    let flowCredits: Int?
    let flexCredits: Int?
    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme

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
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(theme.accent)
                    Text(loc("subCreditsTitle").uppercased())
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .tracking(0.6)
                        .foregroundColor(theme.inkPrimary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)

                Rectangle().fill(theme.hairline).frame(height: 1)

                HStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { idx, pool in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pool.label.uppercased())
                                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(theme.inkMuted)
                            Text(formatNumber(pool.value))
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .monospacedDigit()
                                .foregroundColor(theme.inkPrimary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)

                        if idx < items.count - 1 {
                            Rectangle().fill(theme.hairline).frame(width: 1)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Plan Tab View

struct SubscriptionView: View {
    @ObservedObject var store: UsageStore
    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme

    private func nonEmpty(_ s: String?) -> String? {
        guard let trimmed = s?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    var body: some View {
        VStack(spacing: 0) {
            switch store.effectiveQuotaPhase {
            case .ready(let q, _, _, let notice):
                quotaSections(q, notice: notice)
            case .failed(let err, let retryAt):
                stateMessage(
                    icon: "exclamationmark.triangle",
                    text: errorText(for: err, retryAt: retryAt),
                    showRetry: true
                )
            case .noAccount:
                stateMessage(
                    icon: "person.crop.circle.badge.questionmark",
                    text: loc("subNoToken"),
                    showRetry: true
                )
            case .loading:
                TelemetrySkeleton()
            }
        }
    }

    @ViewBuilder
    private func quotaSections(_ q: OAuthUsage, notice: QuotaRefreshNotice) -> some View {
        let geminiWeeklyLimits = q.scopedModelLimits.filter { $0.scope?.model?.id == "gemini_weekly" }
        let claudeWeeklyLimits = q.scopedModelLimits.filter { $0.scope?.model?.id == "claude_partner_weekly" }
        let customScopedLimits = q.scopedModelLimits.filter {
            let mid = $0.scope?.model?.id ?? ""
            return mid != "gemini_weekly" && mid != "claude_partner_weekly"
        }

        if nonEmpty(q.accountEmail) != nil || q.isOfflineCached {
            PlanAccountStrip(email: q.accountEmail, isOfflineCached: q.isOfflineCached)
            HairlineRule(showCrosshairs: true)
        }

        if store.visualMode == .instrument {
            OrbitalPlanDeck(
                quota: q,
                geminiWeeklyLimits: geminiWeeklyLimits,
                claudeWeeklyLimits: claudeWeeklyLimits,
                hasGemini5h: q.five_hour.resets_at != nil
                    || q.five_hour.displayPercent > 0
                    || nonEmpty(q.five_hour.label) != nil
                    || q.scopedModelLimits.isEmpty,
                hasClaude5h: q.seven_day.resets_at != nil
                    || q.seven_day.displayPercent > 0
                    || nonEmpty(q.seven_day.label) != nil
            )
        } else {
            // Section 01: Gemini Family
            let hasGemini5h = q.five_hour.resets_at != nil
                || q.five_hour.displayPercent > 0
                || nonEmpty(q.five_hour.label) != nil
                || q.scopedModelLimits.isEmpty
            if hasGemini5h || !geminiWeeklyLimits.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    FamilySectionHeader(
                        title: loc("planGeminiFamily"),
                        codes: "CRB · ARG · NEO · HYD · FLS"
                    )
                    if hasGemini5h {
                        QuotaTrackRow(
                            label: loc("planWindow5h"),
                            usedPercent: q.five_hour.displayPercent,
                            resetAt: q.fiveHourResetDate,
                            windowDurationSeconds: QuotaPaceLogic.fiveHourWindowSeconds
                        )
                    }
                    ForEach(Array(geminiWeeklyLimits.enumerated()), id: \.offset) { _, lim in
                        Rectangle().fill(theme.hairline).frame(height: 1)
                        QuotaTrackRow(
                            label: loc("planWindow7d"),
                            usedPercent: lim.displayPercent,
                            resetAt: lim.resetDate,
                            windowDurationSeconds: QuotaPaceLogic.sevenDayWindowSeconds
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                HairlineRule(showCrosshairs: true)
            }

            // Section 02: Claude & GPT Family
            let hasClaude5h = q.seven_day.resets_at != nil
                || q.seven_day.displayPercent > 0
                || nonEmpty(q.seven_day.label) != nil
            if hasClaude5h || !claudeWeeklyLimits.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    FamilySectionHeader(
                        title: loc("planClaudeFamily"),
                        codes: "CLD · OTH"
                    )
                    if hasClaude5h {
                        QuotaTrackRow(
                            label: loc("planWindow5h"),
                            usedPercent: q.seven_day.displayPercent,
                            resetAt: q.sevenDayResetDate,
                            windowDurationSeconds: QuotaPaceLogic.fiveHourWindowSeconds
                        )
                    }
                    ForEach(Array(claudeWeeklyLimits.enumerated()), id: \.offset) { _, lim in
                        Rectangle().fill(theme.hairline).frame(height: 1)
                        QuotaTrackRow(
                            label: loc("planWindow7d"),
                            usedPercent: lim.displayPercent,
                            resetAt: lim.resetDate,
                            windowDurationSeconds: QuotaPaceLogic.sevenDayWindowSeconds
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                HairlineRule(showCrosshairs: true)
            }
        }

        ForEach(Array(customScopedLimits.enumerated()), id: \.offset) { _, lim in
            let rawName = lim.modelDisplayName ?? ""
            let classified = ModelClass.classify(rawName)
            VStack(alignment: .leading, spacing: 8) {
                FamilySectionHeader(title: rawName.uppercased(), codes: classified.shortCode)
                QuotaTrackRow(
                    label: String(format: loc("sub7dScopedFmt"), rawName),
                    usedPercent: lim.displayPercent,
                    resetAt: lim.resetDate,
                    windowDurationSeconds: QuotaPaceLogic.sevenDayWindowSeconds
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            HairlineRule(showCrosshairs: true)
        }

        if let sonnet = q.seven_day_sonnet,
           sonnet.displayPercent > 0 || sonnet.resets_at != nil,
           !q.scopedModelLimits.contains(where: {
               $0.modelDisplayName?.caseInsensitiveCompare("Claude") == .orderedSame }) {
            QuotaTrackRow(
                label: nonEmpty(sonnet.label) ?? loc("sub7dSonnetLabel"),
                usedPercent: sonnet.displayPercent,
                resetAt: q.sevenDaySonnetResetDate,
                windowDurationSeconds: QuotaPaceLogic.fiveHourWindowSeconds
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            HairlineRule(showCrosshairs: true)
        }

        if q.hasCredits {
            AICreditsSection(
                promptCredits: q.promptCredits,
                flowCredits: q.flowCredits,
                flexCredits: q.flexCredits
            )
        }

        if q.extra_usage?.is_enabled == true {
            HairlineRule(showCrosshairs: false)
            HStack(spacing: 6) {
                Image(systemName: "creditcard")
                    .font(.system(size: 9.5))
                    .foregroundColor(theme.inkSecondary)
                Text(loc("subExtraOn"))
                    .font(.system(size: 9.5))
                    .foregroundColor(theme.inkSecondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }

        switch notice {
        case .none:
            EmptyView()
        case .rateLimited(let retryAt):
            HairlineRule(showCrosshairs: false)
            noticeRow(text: errorText(for: .rateLimited, retryAt: retryAt), showRetry: false)
        case .staleError(let err):
            HairlineRule(showCrosshairs: false)
            noticeRow(text: errorText(for: err, retryAt: nil), showRetry: err != .rateLimited)
        }
    }

    private func noticeRow(text: String, showRetry: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 9.5))
                .foregroundColor(theme.signalAmber)
            Text(text)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundColor(theme.inkSecondary)
            Spacer()
            if showRetry {
                Text(loc("retry").uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.accent)
                    .contentShape(Rectangle())
                    .onTapGesture { store.refreshQuota(force: true) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func stateMessage(icon: String, text: String, showRetry: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(theme.signalAmber)
            Text(text)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if showRetry {
                Text(loc("retry").uppercased())
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.invertedInk)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(theme.invertedBg)
                    .contentShape(Rectangle())
                    .onTapGesture { store.refreshQuota(force: true) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
    }

    private func errorText(for error: CoreQuotaError?, retryAt: Date?) -> String {
        switch error {
        case .unauthorized:
            return loc("quotaTokenExpired")
        case .rateLimited:
            if let retryAt = retryAt, retryAt > Date() {
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
