import SwiftUI
import AppKit

// Sessions tab (04 — Live Antigravity CLI / Desktop / IDE command deck).
// Archival hairline filter index, airy editorial ledger rows with 01/02 indexing,
// precision optical alert rows, zero heavy slabs, italic serif colophon,
// and intact window-scoped ↑/↓/Return keyboard navigation.

// MARK: - Host Window Probe (for safe window-scoped ↑/↓/Return navigation)

private struct HostWindowProbe: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}

// MARK: - Sessions Tab

struct SessionTabView: View {
    @ObservedObject var sessionStore: SessionStore
    var visualMode: TelemetryVisualMode = .instrument
    var onClose: (() -> Void)? = nil

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @Environment(\.telemetryStaticRender) private var isStaticRender

    @State private var deck = SessionDeckState()
    @State private var hoveredFilter: SessionStatusFilter? = nil
    @State private var hostWindow: NSWindow? = nil
    @State private var keyMonitor: Any? = nil

    private var allSessions: [SessionInfo] { sessionStore.sessions }
    private var waitingSessions: [SessionInfo] { allSessions.filter { $0.status == .waiting } }
    private var runningCount: Int { allSessions.filter { $0.status == .busy }.count }
    private var doneCount: Int { sessionStore.doneUnseen.count }

    private var filteredGroups: [SessionGroup] {
        let baseGroups: [SessionGroup]
        if deck.filter == .all {
            baseGroups = SessionFilterLogic.nonWaitingGroups(from: sessionStore.groups)
        } else {
            baseGroups = sessionStore.groups
        }
        return baseGroups.compactMap { group in
            let filtered = group.sessions.filter { matchesFilter($0, filter: deck.filter) }
            guard !filtered.isEmpty else { return nil }
            return SessionGroup(cwd: group.cwd, label: group.label, sessions: filtered)
        }
    }

    private func visibleSessionIds(for activeFilter: SessionStatusFilter) -> [String] {
        var ids: [String] = []
        if (activeFilter == .all || activeFilter == .waiting) && !waitingSessions.isEmpty {
            ids.append(contentsOf: waitingSessions.map(\.sessionId))
        }
        if activeFilter != .waiting {
            let baseGroups = (activeFilter == .all)
                ? SessionFilterLogic.nonWaitingGroups(from: sessionStore.groups)
                : sessionStore.groups
            for group in baseGroups {
                for s in group.sessions where matchesFilter(s, filter: activeFilter) && !ids.contains(s.sessionId) {
                    ids.append(s.sessionId)
                }
            }
        }
        return ids
    }

    private var orderedVisibleSessionIds: [String] {
        visibleSessionIds(for: deck.filter)
    }

    private func matchesFilter(_ s: SessionInfo, filter: SessionStatusFilter) -> Bool {
        switch filter {
        case .all:     return true
        case .running: return s.status == .busy
        case .waiting: return s.status == .waiting
        case .done:    return sessionStore.doneUnseen.contains(s.sessionId)
        }
    }

    private func dispatchDeck(_ event: SessionDeckEvent) {
        let effects = SessionDeckMachine.reduce(&deck, event: event)
        for effect in effects {
            switch effect {
            case .jumpToSession(let sid):
                if let match = sessionStore.sessions.first(where: { $0.sessionId == sid }) {
                    sessionStore.jump(match)
                }
            }
        }
    }

    private var radarHoveredBinding: Binding<String?> {
        Binding(
            get: { deck.hoveredSessionId },
            set: { next in
                dispatchDeck(.setHoveredSession(next, visibleIds: orderedVisibleSessionIds))
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if allSessions.isEmpty {
                emptyState
                HairlineRule(showCrosshairs: false)
                colophonFooter
            } else {
                filterStrip
                HairlineRule(showCrosshairs: true)

                if visualMode == .instrument {
                    AgentTelemetryRadarView(
                        sessions: allSessions,
                        sessionStore: sessionStore,
                        visibleSessionIds: Set(orderedVisibleSessionIds),
                        selectedSessionId: deck.selectedSessionId,
                        hoveredSessionId: radarHoveredBinding
                    )
                    HairlineRule(showCrosshairs: true)
                }

                if let jumpHint = sessionStore.jumpHint {
                    jumpHintBanner(jumpHint)
                    HairlineRule(showCrosshairs: false)
                }

                if (deck.filter == .all || deck.filter == .waiting) && !waitingSessions.isEmpty {
                    needsAttentionSection
                    HairlineRule(showCrosshairs: true)
                }

                if deck.filter != .waiting {
                    ForEach(Array(filteredGroups.enumerated()), id: \.element.id) { idx, group in
                        SessionGroupSection(
                            group: group,
                            sessionStore: sessionStore,
                            selectedSessionId: deck.selectedSessionId,
                            hoveredRadarSessionId: deck.hoveredSessionId
                        )
                        if idx < filteredGroups.count - 1 {
                            HairlineRule(showCrosshairs: true)
                        }
                    }
                }

                HairlineRule(showCrosshairs: false)
                colophonFooter
            }
        }
        .background {
            if !isStaticRender {
                HostWindowProbe { w in hostWindow = w }
                    .frame(width: 0, height: 0)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: sessionStore.jumpHint)
        .onChange(of: orderedVisibleSessionIds) { ids in
            dispatchDeck(.reconcileVisibleIds(ids))
        }
        .onAppear { if !isStaticRender { installKeyMonitor() } }
        .onDisappear { removeKeyMonitor() }
    }

    // MARK: De-Slabbed Hairline Filter Index Strip

    private var filterStrip: some View {
        let chips: [(kind: SessionStatusFilter, label: String, count: Int, tint: Color?)] = [
            (.all,     loc("filterAll"),     allSessions.count,     nil),
            (.running, loc("filterRunning"), runningCount,          theme.accent),
            (.waiting, loc("filterWaiting"), waitingSessions.count, theme.signalAmber),
            (.done,    loc("filterDone"),    doneCount,             theme.signalGreen),
        ]

        return HStack(spacing: 4) {
            ForEach(chips, id: \.kind) { item in
                let isSelected = (deck.filter == item.kind)
                let isHovered = (hoveredFilter == item.kind)
                let squareColor = item.tint ?? theme.accent

                HStack(spacing: 4.5) {
                    if isSelected {
                        Rectangle()
                            .fill(squareColor)
                            .frame(width: 4, height: 4)
                            .rotationEffect(item.kind == .waiting ? .degrees(45) : .zero)
                    } else if let dotTint = item.tint {
                        Rectangle()
                            .fill(dotTint.opacity(item.count > 0 ? 0.72 : 0.25))
                            .frame(width: 3.5, height: 3.5)
                            .rotationEffect(item.kind == .waiting ? .degrees(45) : .zero)
                    }

                    Text(item.label)
                        .font(.system(size: 8.5, weight: isSelected ? .semibold : .regular, design: .monospaced))
                        .tracking(0.7)
                        .foregroundColor(
                            isSelected
                                ? theme.inkPrimary
                                : (isHovered ? theme.inkPrimary.opacity(0.85) : theme.inkSecondary)
                        )

                    Text("\(item.count)")
                        .font(.system(size: 8.5, weight: isSelected ? .medium : .regular, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(
                            isSelected
                                ? (item.kind == .waiting ? theme.signalAmber : theme.accent)
                                : theme.inkMuted
                        )
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    ZStack(alignment: .bottom) {
                        if isSelected {
                            Rectangle()
                                .fill(theme.surfaceRaised.opacity(theme.isDark ? 0.35 : 0.55))
                            Rectangle()
                                .fill(theme.accent)
                                .frame(height: 1.5)
                        } else if isHovered {
                            Rectangle()
                                .fill(theme.surfaceRaised.opacity(0.32))
                        }
                    }
                )
                .contentShape(Rectangle())
                .onHover { inside in
                    hoveredFilter = inside ? item.kind : (hoveredFilter == item.kind ? nil : hoveredFilter)
                }
                .onTapGesture {
                    dispatchDeck(.selectFilter(item.kind, visibleIds: visibleSessionIds(for: item.kind)))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    // MARK: Precision Optical Alert Section (04.2)

    private var needsAttentionSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Rectangle()
                    .fill(theme.signalAmber)
                    .frame(width: 4, height: 4)
                    .rotationEffect(.degrees(45))

                Text("04.2")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.signalAmber.opacity(0.92))

                Text(loc("needsAttention"))
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .tracking(0.95)
                    .foregroundColor(theme.signalAmber)

                Spacer(minLength: 4)

                Text(String(format: "%02d", waitingSessions.count))
                    .font(.system(size: 8, weight: .regular, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(theme.signalAmber.opacity(0.9))
            }

            VStack(spacing: 0) {
                ForEach(Array(waitingSessions.enumerated()), id: \.element.id) { idx, session in
                    let wsLabel = sessionStore.labels[session.cwd] ?? SessionLogic.basename(session.cwd)
                    SessionRow(
                        session: session,
                        sessionStore: sessionStore,
                        rowIndex: idx + 1,
                        workspacePrefix: wsLabel,
                        isSelected: deck.selectedSessionId == session.sessionId || deck.hoveredSessionId == session.sessionId
                    )
                    if idx < waitingSessions.count - 1 {
                        Rectangle()
                            .fill(theme.signalAmber.opacity(theme.isDark ? 0.16 : 0.14))
                            .frame(height: 0.5)
                            .padding(.leading, 22)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(theme.signalAmber.opacity(theme.isDark ? 0.055 : 0.045))
        .overlay(alignment: .leading) {
            Rectangle().fill(theme.signalAmber).frame(width: 1.5)
        }
    }

    // MARK: Editorial Colophon Footer

    private var colophonFooter: some View {
        HStack(spacing: 5) {
            Text(loc("navKeyHint"))
                .font(.system(size: 7.5, weight: .regular, design: .monospaced))
                .tracking(0.45)
                .foregroundColor(theme.inkMuted)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text("Plate IV")
                .font(.system(size: 8.5, weight: .regular, design: .serif))
                .italic()
                .foregroundColor(theme.inkMuted.opacity(0.75))

            Text("·")
                .font(.system(size: 7.5, weight: .regular, design: .monospaced))
                .foregroundColor(theme.inkMuted.opacity(0.45))

            Text("FIG. 04")
                .font(.system(size: 7.5, weight: .regular, design: .monospaced))
                .tracking(0.8)
                .foregroundColor(theme.inkMuted.opacity(0.78))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6.5)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 16, weight: .light))
                .foregroundColor(theme.inkMuted)
            Text(loc("sessionEmpty"))
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(theme.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: 130)
    }

    private func jumpHintBanner(_ key: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 9.5, weight: .regular))
                .foregroundColor(theme.accent)
            Text(loc(key))
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundColor(theme.inkPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(theme.accent.opacity(theme.isDark ? 0.10 : 0.06))
        .overlay(alignment: .leading) {
            Rectangle().fill(theme.accent).frame(width: 1.5)
        }
        .transition(.opacity)
    }

    // MARK: - Keyboard ↑/↓/Return Navigation

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let hw = hostWindow, event.window === hw else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods.isEmpty || mods == .numericPad || mods == .function else { return event }

            switch event.keyCode {
            case 125:
                dispatchDeck(.moveKeyboardSelection(delta: 1, visibleIds: orderedVisibleSessionIds))
                return nil
            case 126:
                dispatchDeck(.moveKeyboardSelection(delta: -1, visibleIds: orderedVisibleSessionIds))
                return nil
            case 36, 76:
                let ids = orderedVisibleSessionIds
                guard !ids.isEmpty else { return event }
                dispatchDeck(.activateSelected(visibleIds: ids))
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }
}

/// Workspace section separated cleanly by hairlines (zero gray boxes).
struct SessionGroupSection: View {
    let group: SessionGroup
    @ObservedObject var sessionStore: SessionStore
    var selectedSessionId: String? = nil
    var hoveredRadarSessionId: String? = nil

    @Environment(\.agyTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text("+")
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundColor((theme.isMultiColorSpectrum ? theme.accentQuaternary : theme.accentSecondary).opacity(0.9))
                Text(group.label.uppercased())
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .tracking(0.95)
                    .foregroundColor(theme.inkSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(String(format: "%02d", group.sessions.count))
                    .font(.system(size: 8, weight: .regular, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(theme.inkMuted)
            }
            .help(group.cwd)

            VStack(spacing: 0) {
                ForEach(Array(group.sessions.enumerated()), id: \.element.id) { idx, session in
                    SessionRow(
                        session: session,
                        sessionStore: sessionStore,
                        rowIndex: idx + 1,
                        isSelected: selectedSessionId == session.sessionId || hoveredRadarSessionId == session.sessionId
                    )
                    if idx < group.sessions.count - 1 {
                        Rectangle()
                            .fill(theme.hairline.opacity(0.45))
                            .frame(height: 0.5)
                            .padding(.leading, 22)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// One session ledger row: 01/02 monospaced index + RadarStatusDot + airy .medium/.regular title
/// + quiet monospace surface tag + hairline telemetry badge.
struct SessionRow: View {
    let session: SessionInfo
    @ObservedObject var sessionStore: SessionStore
    var rowIndex: Int? = nil
    var workspacePrefix: String? = nil
    var isSelected: Bool = false

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @State private var hovering = false

    private var isActiveHighlight: Bool { hovering || isSelected }

    var body: some View {
        let isWaiting = (dotKind == .waiting)
        let focusTint = isWaiting ? theme.signalAmber : theme.accent

        HStack(spacing: 7) {
            if let rowIndex = rowIndex {
                Text(String(format: "%02d", rowIndex))
                    .font(.system(size: 7.5, weight: .regular, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(isActiveHighlight ? focusTint : theme.inkMuted.opacity(0.72))
                    .frame(width: 14, alignment: .leading)
            }

            RadarStatusDot(kind: dotKind)
                .accessibilityLabel(statusLabel)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5.5) {
                    Text(titleText)
                        .font(.system(size: 11, weight: isWaiting ? .medium : .regular))
                        .foregroundColor(
                            isActiveHighlight || isWaiting
                                ? theme.inkPrimary
                                : theme.inkPrimary.opacity(0.90)
                        )
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let surfaceCode = surfaceCode {
                        Text(surfaceCode)
                            .font(.system(size: 7, weight: .regular, design: .monospaced))
                            .tracking(0.55)
                            .foregroundColor(theme.inkMuted)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(theme.surfaceRaised.opacity(theme.isDark ? 0.25 : 0.42))
                            .overlay(Rectangle().stroke(theme.hairline.opacity(0.80), lineWidth: 0.55))
                            .fixedSize()
                    }
                }

                Text(workspacePrefix.map { "\($0) · \(subtitleText)" } ?? subtitleText)
                    .font(.system(size: 9.5, weight: .regular))
                    .foregroundColor(theme.inkSecondary.opacity(0.86))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            if isWaiting {
                let tag = session.waitReason == .needsConfirmation ? loc("badgeConfirm") : loc("badgeInput")
                Text("\(tag) ↗")
                    .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                    .tracking(0.45)
                    .foregroundColor(theme.signalAmber)
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 2)
                    .background(theme.signalAmber.opacity(theme.isDark ? 0.11 : 0.09))
                    .overlay(Rectangle().stroke(theme.signalAmber.opacity(0.62), lineWidth: 0.75))
            } else if dotKind == .doneUnseen {
                Text(loc("badgeDone"))
                    .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                    .tracking(0.45)
                    .foregroundColor(theme.signalGreen)
                    .padding(.horizontal, 4.5)
                    .padding(.vertical, 1.5)
                    .background(theme.signalGreen.opacity(theme.isDark ? 0.10 : 0.07))
                    .overlay(Rectangle().stroke(theme.signalGreen.opacity(0.42), lineWidth: 0.65))
            } else if let updated = session.updatedAt {
                Text(timeAgo(Date(timeIntervalSince1970: updated / 1000), loc))
                    .font(.system(size: 8, weight: .regular, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(theme.inkMuted)
            }

            Text(isActiveHighlight ? "↵" : "")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(focusTint)
                .frame(width: 11)
        }
        .padding(.vertical, 6.5)
        .padding(.horizontal, 5)
        .contentShape(Rectangle())
        .background(
            isActiveHighlight
                ? focusTint.opacity(theme.isDark ? 0.11 : 0.06)
                : Color.clear
        )
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle().fill(focusTint).frame(width: 1.5)
            }
        }
        .onHover { inside in
            guard inside != hovering else { return }
            hovering = inside
            PointingCursorCoordinator.shared.setPointing(inside, token: "session-row-\(session.sessionId)")
        }
        .onDisappear {
            if hovering {
                hovering = false
                PointingCursorCoordinator.shared.setPointing(false, token: "session-row-\(session.sessionId)")
            }
        }
        .onTapGesture { sessionStore.jump(session) }
    }

    private var surfaceCode: String? {
        guard let b = SessionSurfaceBadge.from(entrypoint: session.entrypoint, surface: session.surface) else { return nil }
        switch b {
        case .cli:     return "CLI"
        case .desktop: return "DESK"
        case .ide:     return "IDE"
        }
    }

    private var titleText: String {
        if let t = sessionStore.titles[session.sessionId], !t.isEmpty { return t }
        let base = SessionLogic.basename(session.cwd)
        return base.isEmpty ? loc("sessionUntitled") : base
    }

    private var subtitleText: String {
        if let i = sessionStore.instructions[session.sessionId], !i.isEmpty { return i }
        return loc("sessionNoPrompt")
    }

    private var isDoneUnseen: Bool { sessionStore.doneUnseen.contains(session.sessionId) }

    private var dotKind: SessionLogic.SessionDotKind {
        SessionLogic.dotKind(status: session.status, doneUnseen: isDoneUnseen)
    }

    private var statusLabel: String {
        if dotKind == .doneUnseen { return loc("sessionFinishedUnread") }
        switch session.status {
        case .busy:
            return loc("sessionWorking")
        case .waiting:
            switch session.waitReason {
            case .needsConfirmation:    return loc("sessionNeedsConfirm")
            case .needsInput, .none:    return loc("sessionWaitingInput")
            }
        case .idle, .shell:
            return loc("sessionIdle")
        case .unknown:
            return loc("sessionRunning")
        }
    }
}
