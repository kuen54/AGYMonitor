import SwiftUI
import AppKit

// Plan Tab (FIG. 05): Specimen account header, dual drafting protractor gauges (or classic
// 60-tick vernier tracks), flush 3-column AI Credits pool ledger, and editorial colophon.

// MARK: - Quota Track Row (Classic Mode & Custom Scoped Limits)

private struct QuotaTrackRow: View {
    let label: String
    let usedPercent: Int
    let resetAt: Date?
    let windowDurationSeconds: TimeInterval
    var useSecondaryAccent: Bool = false

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme

    private var remaining: Int { max(0, 100 - usedPercent) }
    private var remainingFraction: CGFloat { max(0, min(1, CGFloat(remaining) / 100.0)) }

    private var statusColor: Color {
        switch remaining {
        case 30...:   return useSecondaryAccent ? theme.accentSecondary : theme.accent
        case 10..<30: return theme.signalAmber
        default:      return theme.signalRed
        }
    }

    var body: some View {
        let currentPace = QuotaPaceLogic.compute(
            usedPercent: usedPercent,
            resetAt: resetAt,
            windowDurationSeconds: windowDurationSeconds,
            now: Date()
        )

        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label.uppercased())
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .tracking(0.6)
                    .foregroundColor(theme.inkSecondary)

                Spacer(minLength: 4)

                if let p = currentPace {
                    let sign = p.paceDeltaPercent > 0
                        ? "+\(p.paceDeltaPercent)%"
                        : (p.paceDeltaPercent < 0 ? "−\(abs(p.paceDeltaPercent))%" : "0%")
                    let paceLabel = String(format: loc("planPaceFmt"), sign)
                    if p.isOverPaceWarning {
                        HStack(spacing: 3.5) {
                            Rectangle()
                                .fill(theme.signalAmber)
                                .frame(width: 4.5, height: 4.5)
                                .rotationEffect(.degrees(45))
                            Text(paceLabel)
                                .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                                .monospacedDigit()
                                .foregroundColor(theme.signalAmber)
                        }
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1.5)
                        .background(theme.signalAmber.opacity(theme.isDark ? 0.11 : 0.08))
                        .overlay(
                            Rectangle()
                                .strokeBorder(theme.signalAmber.opacity(0.5), lineWidth: 0.75)
                        )
                    } else {
                        Text(paceLabel)
                            .font(.system(size: 8, weight: .regular, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(theme.inkSecondary)
                    }
                }

                if let r = resetAt {
                    Text(String(format: loc("planResetShortFmt"), formatQuotaResetDuration(r).uppercased()))
                        .font(.system(size: 8, weight: .regular, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(theme.inkMuted)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                PrecisionHeroNumber(
                    whole: "\(remaining)",
                    suffix: "% LEFT",
                    size: 24,
                    weight: .ultraLight,
                    accentPrimary: remaining < 30 ? statusColor : nil
                )
                Spacer()
                Text(String(format: loc("subUsedFmt"), usedPercent).uppercased())
                    .font(.system(size: 8.5, weight: .regular, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(theme.inkMuted)
            }

            VernierScaleBar(
                fraction: remainingFraction,
                fillColor: statusColor,
                paceMarkerFraction: currentPace.map { CGFloat($0.expectedRemainingFraction) },
                paceWarning: currentPace?.isOverPaceWarning == true,
                ticks: 60
            )
        }
    }
}

// MARK: - Plan Family Header (Bare Monospace Codes, Zero Skittles)

struct FamilySectionHeader: View {
    var indexTag: String? = nil
    let title: String
    let codes: String
    var useSecondaryAccent: Bool = false
    @Environment(\.agyTheme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            if let tag = indexTag {
                Text(tag)
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor((useSecondaryAccent ? theme.accentSecondary : theme.accent).opacity(0.9))
            }
            Text(title)
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .tracking(0.6)
                .foregroundColor(theme.inkPrimary)
            Spacer()
            Text(codes)
                .font(.system(size: 7.5, weight: .regular, design: .monospaced))
                .tracking(0.4)
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
        HStack(spacing: 5) {
            Text("05.")
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.accent)

            if let mail = email?.trimmingCharacters(in: .whitespacesAndNewlines), !mail.isEmpty {
                Text("USER // \(mail)")
                    .font(.system(size: 8.5, weight: .regular, design: .monospaced))
                    .tracking(0.6)
                    .foregroundColor(theme.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            if isOfflineCached {
                HStack(spacing: 4) {
                    Rectangle()
                        .fill(theme.signalAmber)
                        .frame(width: 4.5, height: 4.5)
                        .rotationEffect(.degrees(45))
                    Text(loc("subOfflineCached").uppercased())
                        .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                        .tracking(0.6)
                        .foregroundColor(theme.signalAmber)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(theme.signalAmber.opacity(theme.isDark ? 0.11 : 0.08))
                .overlay(
                    Rectangle()
                        .strokeBorder(theme.signalAmber.opacity(0.5), lineWidth: 0.75)
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// MARK: - AI Credits Matrix Section (05.3 Pool Ledger)

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
                    Text("05.3")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.accent.opacity(0.9))
                    Text(loc("subCreditsTitle").uppercased())
                        .font(.system(size: 8, weight: .regular, design: .monospaced))
                        .tracking(0.8)
                        .foregroundColor(theme.inkSecondary)
                    Spacer(minLength: 4)
                    Text("POOL LEDGER")
                        .font(.system(size: 7.5, weight: .regular, design: .monospaced))
                        .tracking(0.7)
                        .foregroundColor(theme.inkMuted)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)

                Rectangle().fill(theme.hairline).frame(height: 1)

                let maxPool = items.map(\.value).max() ?? 0
                let largestIdx: Int? = maxPool > 0 ? items.firstIndex(where: { $0.value == maxPool }) : nil

                HStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { idx, pool in
                        let ratio: CGFloat = maxPool > 0
                            ? max(0, min(1, CGFloat(pool.value) / CGFloat(maxPool)))
                            : 0
                        let isLargest = (idx == largestIdx)

                        VStack(alignment: .leading, spacing: 5) {
                            Text(pool.label.uppercased())
                                .font(.system(size: 7.5, weight: .regular, design: .monospaced))
                                .tracking(0.8)
                                .foregroundColor(theme.inkMuted)
                            Text(formatNumber(pool.value))
                                .font(.system(size: 21, weight: .ultraLight, design: .monospaced))
                                .monospacedDigit()
                                .foregroundColor(theme.inkPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            CreditHorizonHairline(
                                ratio: ratio,
                                fillColor: isLargest ? theme.accent : theme.accentSecondary.opacity(0.65),
                                trackColor: theme.hairline.opacity(theme.isDark ? 0.80 : 0.85)
                            )
                            .equatable()
                            .padding(.top, 1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)

                        if idx < items.count - 1 {
                            Rectangle().fill(theme.hairline.opacity(0.85)).frame(width: 1)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct CreditHorizonHairline: View, Equatable {
    let ratio: CGFloat
    let fillColor: Color
    let trackColor: Color

    var body: some View {
        let clamped = max(0, min(1, ratio))
        Canvas { context, size in
            context.fill(
                Path(CGRect(x: 0, y: 0, width: size.width, height: size.height)),
                with: .color(trackColor)
            )
            if clamped > 0 {
                let fillW = min(size.width, max(2.0, size.width * clamped))
                context.fill(
                    Path(CGRect(x: 0, y: 0, width: fillW, height: size.height)),
                    with: .color(fillColor)
                )
            }
        }
        .frame(height: 1.5)
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

    private func stripLeadingIndexPrefix(_ raw: String) -> String {
        if let range = raw.range(of: " // "),
           raw.distance(from: raw.startIndex, to: range.lowerBound) <= 4 {
            return String(raw[range.upperBound...])
        }
        return raw
    }

    var body: some View {
        VStack(spacing: 0) {
            switch store.effectiveQuotaPhase {
            case .ready(let q, _, _, let notice):
                quotaSections(q, notice: notice)
            case .failed(let err, let retryAt):
                stateMessage(
                    text: errorText(for: err, retryAt: retryAt),
                    showRetry: true
                )
            case .noAccount:
                stateMessage(
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

        let hasGemini5h = q.five_hour.resets_at != nil
            || q.five_hour.displayPercent > 0
            || nonEmpty(q.five_hour.label) != nil
            || q.scopedModelLimits.isEmpty
        let hasClaude5h = q.seven_day.resets_at != nil
            || q.seven_day.displayPercent > 0
            || nonEmpty(q.seven_day.label) != nil
        let hasPrimaryQuota = hasGemini5h || hasClaude5h || !geminiWeeklyLimits.isEmpty || !claudeWeeklyLimits.isEmpty

        let showSonnet = {
            if let sonnet = q.seven_day_sonnet,
               sonnet.displayPercent > 0 || sonnet.resets_at != nil,
               !q.scopedModelLimits.contains(where: {
                   $0.modelDisplayName?.caseInsensitiveCompare("Claude") == .orderedSame }) {
                return true
            }
            return false
        }()

        if nonEmpty(q.accountEmail) != nil || q.isOfflineCached {
            PlanAccountStrip(email: q.accountEmail, isOfflineCached: q.isOfflineCached)
            HairlineRule(showCrosshairs: true)
        }

        if store.visualMode == .instrument {
            if hasPrimaryQuota {
                OrbitalPlanDeck(
                    quota: q,
                    geminiWeeklyLimits: geminiWeeklyLimits,
                    claudeWeeklyLimits: claudeWeeklyLimits,
                    hasGemini5h: hasGemini5h,
                    hasClaude5h: hasClaude5h
                )
            }
        } else {
            let showGeminiClassic = hasGemini5h || !geminiWeeklyLimits.isEmpty
            let showClaudeClassic = hasClaude5h || !claudeWeeklyLimits.isEmpty

            if showGeminiClassic {
                VStack(alignment: .leading, spacing: 10) {
                    FamilySectionHeader(
                        indexTag: "05.1",
                        title: stripLeadingIndexPrefix(loc("planGeminiFamily")),
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
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                if showClaudeClassic {
                    HairlineRule(showCrosshairs: true)
                }
            }

            if showClaudeClassic {
                VStack(alignment: .leading, spacing: 10) {
                    FamilySectionHeader(
                        indexTag: "05.2",
                        title: stripLeadingIndexPrefix(loc("planClaudeFamily")),
                        codes: "CLD · OTH",
                        useSecondaryAccent: true
                    )
                    if hasClaude5h {
                        QuotaTrackRow(
                            label: loc("planWindow5h"),
                            usedPercent: q.seven_day.displayPercent,
                            resetAt: q.sevenDayResetDate,
                            windowDurationSeconds: QuotaPaceLogic.fiveHourWindowSeconds,
                            useSecondaryAccent: true
                        )
                    }
                    ForEach(Array(claudeWeeklyLimits.enumerated()), id: \.offset) { _, lim in
                        Rectangle().fill(theme.hairline).frame(height: 1)
                        QuotaTrackRow(
                            label: loc("planWindow7d"),
                            usedPercent: lim.displayPercent,
                            resetAt: lim.resetDate,
                            windowDurationSeconds: QuotaPaceLogic.sevenDayWindowSeconds,
                            useSecondaryAccent: true
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }

        ForEach(Array(customScopedLimits.enumerated()), id: \.offset) { idx, lim in
            if idx > 0 || hasPrimaryQuota {
                HairlineRule(showCrosshairs: true)
            }
            let rawName = lim.modelDisplayName ?? ""
            let classified = ModelClass.classify(rawName)
            let isSecondary = (classified == .claude)
            VStack(alignment: .leading, spacing: 8) {
                FamilySectionHeader(
                    title: rawName.uppercased(),
                    codes: classified.shortCode,
                    useSecondaryAccent: isSecondary
                )
                QuotaTrackRow(
                    label: String(format: loc("sub7dScopedFmt"), rawName),
                    usedPercent: lim.displayPercent,
                    resetAt: lim.resetDate,
                    windowDurationSeconds: QuotaPaceLogic.sevenDayWindowSeconds,
                    useSecondaryAccent: isSecondary
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }

        if showSonnet, let sonnet = q.seven_day_sonnet {
            if hasPrimaryQuota || !customScopedLimits.isEmpty {
                HairlineRule(showCrosshairs: true)
            }
            QuotaTrackRow(
                label: nonEmpty(sonnet.label) ?? loc("sub7dSonnetLabel"),
                usedPercent: sonnet.displayPercent,
                resetAt: q.sevenDaySonnetResetDate,
                windowDurationSeconds: QuotaPaceLogic.fiveHourWindowSeconds,
                useSecondaryAccent: true
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }

        if q.hasCredits {
            if hasPrimaryQuota || !customScopedLimits.isEmpty || showSonnet {
                HairlineRule(showCrosshairs: true)
            }
            AICreditsSection(
                promptCredits: q.promptCredits,
                flowCredits: q.flowCredits,
                flexCredits: q.flexCredits
            )
        }

        if q.extra_usage?.is_enabled == true {
            HairlineRule(showCrosshairs: false)
            HStack(spacing: 6) {
                Rectangle()
                    .fill(theme.accent)
                    .frame(width: 4, height: 4)
                Text(loc("subExtraOn"))
                    .font(.system(size: 8.5, weight: .regular, design: .monospaced))
                    .foregroundColor(theme.inkSecondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
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

        HairlineRule(showCrosshairs: false)
        specimenColophon
    }

    // MARK: Editorial Specimen Colophon

    private var specimenColophon: some View {
        HStack(spacing: 6) {
            Text("* Rolling 5h & 7d quota buckets synced from Antigravity quota service")
                .font(.system(size: 8.5, weight: .regular, design: .serif))
                .italic()
                .foregroundColor(theme.inkMuted)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("FIG. 05")
                .font(.system(size: 7.5, weight: .regular, design: .monospaced))
                .tracking(0.8)
                .foregroundColor(theme.inkMuted.opacity(0.75))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func noticeRow(text: String, showRetry: Bool) -> some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(theme.signalAmber)
                .frame(width: 4.5, height: 4.5)
                .rotationEffect(.degrees(45))
            Text(text)
                .font(.system(size: 8.5, weight: .regular, design: .monospaced))
                .foregroundColor(theme.inkSecondary)
            Spacer()
            if showRetry {
                Text(loc("retry").uppercased())
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .tracking(0.7)
                    .foregroundColor(theme.accent)
                    .contentShape(Rectangle())
                    .onTapGesture { store.refreshQuota(force: true) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func stateMessage(text: String, showRetry: Bool = false) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(theme.signalAmber)
                .frame(width: 5, height: 5)
                .rotationEffect(.degrees(45))
            Text(text)
                .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                .foregroundColor(theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if showRetry {
                Text(loc("retry").uppercased())
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .tracking(0.8)
                    .foregroundColor(theme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(theme.surfaceRaised.opacity(theme.isDark ? 0.35 : 0.55))
                    .overlay(
                        Rectangle()
                            .strokeBorder(theme.accent.opacity(0.55), lineWidth: 0.75)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { store.refreshQuota(force: true) }
            }
        }
        .padding(.horizontal, 14)
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
