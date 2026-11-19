import SwiftUI
import AppKit

// Sessions tab (live Antigravity CLI / Desktop / IDE command deck).
// Zero duplicate waiting rows, zero gray card boxes, crisp aligned columns.

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

    @State private var filter: SessionStatusFilter = .all
    @State private var selectedSessionId: String? = nil
    @State private var hoveredRadarSessionId: String? = nil
    @State private var hostWindow: NSWindow? = nil
    @State private var keyMonitor: Any? = nil

    private var allSessions: [SessionInfo] { sessionStore.sessions }
    private var waitingSessions: [SessionInfo] { allSessions.filter { $0.status == .waiting } }
    private var runningCount: Int { allSessions.filter { $0.status == .busy }.count }
    private var doneCount: Int { sessionStore.doneUnseen.count }

    private var filteredGroups: [SessionGroup] {
        let baseGroups: [SessionGroup]
        if filter == .all {
            baseGroups = SessionFilterLogic.nonWaitingGroups(from: sessionStore.groups)
        } else {
            baseGroups = sessionStore.groups
        }
        return baseGroups.compactMap { group in
            let filtered = group.sessions.filter { matchesFilter($0) }
            guard !filtered.isEmpty else { return nil }
            return SessionGroup(cwd: group.cwd, label: group.label, sessions: filtered)
        }
    }

    private var orderedVisibleSessionIds: [String] {
        var ids: [String] = []
        if (filter == .all || filter == .waiting) && !waitingSessions.isEmpty {
            ids.append(contentsOf: waitingSessions.map(\.sessionId))
        }
        if filter != .waiting {
            for group in filteredGroups {
                for s in group.sessions where !ids.contains(s.sessionId) {
                    ids.append(s.sessionId)
                }
            }
        }
        return ids
    }

    private func matchesFilter(_ s: SessionInfo) -> Bool {
        switch filter {
        case .all:     return true
        case .running: return s.status == .busy
        case .waiting: return s.status == .waiting
        case .done:    return sessionStore.doneUnseen.contains(s.sessionId)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if allSessions.isEmpty {
                emptyState
            } else {
                filterStrip
                HairlineRule(showCrosshairs: true)

                if visualMode == .instrument {
                    AgentTelemetryRadarView(
                        sessions: allSessions,
                        sessionStore: sessionStore,
                        visibleSessionIds: Set(orderedVisibleSessionIds),
                        selectedSessionId: selectedSessionId,
                        hoveredSessionId: $hoveredRadarSessionId
                    )
                    HairlineRule(showCrosshairs: true)
                }

                if let jumpHint = sessionStore.jumpHint {
                    jumpHintBanner(jumpHint)
                    HairlineRule(showCrosshairs: false)
                }

                if (filter == .all || filter == .waiting) && !waitingSessions.isEmpty {
                    needsAttentionSection
                    HairlineRule(showCrosshairs: true)
                }

                if filter != .waiting {
                    ForEach(Array(filteredGroups.enumerated()), id: \.element.id) { idx, group in
                        SessionGroupSection(
                            group: group,
                            sessionStore: sessionStore,
                            selectedSessionId: selectedSessionId,
                            hoveredRadarSessionId: hoveredRadarSessionId
                        )
                        if idx < filteredGroups.count - 1 {
                            HairlineRule(showCrosshairs: true)
                        }
                    }
                }

                HStack {
                    Spacer()
                    Text(loc("navKeyHint"))
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.inkMuted)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
        }
        .background {
            if !isStaticRender {
                HostWindowProbe { w in hostWindow = w }
                    .frame(width: 0, height: 0)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: sessionStore.jumpHint)
        .onAppear { if !isStaticRender { installKeyMonitor() } }
        .onDisappear { removeKeyMonitor() }
    }

    private var filterStrip: some View {
        let pills: [(SessionStatusFilter, String, Int, Color?)] = [
            (.all,     loc("filterAll"),     allSessions.count, nil),
            (.running, loc("filterRunning"), runningCount,      theme.accent),
            (.waiting, loc("filterWaiting"), waitingSessions.count, theme.signalAmber),
            (.done,    loc("filterDone"),    doneCount,         theme.signalGreen),
        ]

        return HStack(spacing: 4) {
            ForEach(pills, id: \.0) { item in
                let isSelected = (filter == item.0)
                let tint = item.3
                HStack(spacing: 4) {
                    if let dot = tint {
                        Circle().fill(dot).frame(width: 4.5, height: 4.5)
                    }
                    Text("\(item.1) \(item.2)")
                        .font(.system(size: 9.5, weight: isSelected ? .bold : .medium, design: .monospaced))
                }
                .foregroundColor(isSelected ? theme.invertedInk : theme.inkSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background(isSelected ? theme.invertedBg : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        filter = item.0
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var needsAttentionSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text("▲ \(loc("needsAttention"))")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundColor(theme.signalAmber)
                Spacer()
                Text("\(waitingSessions.count)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.signalAmber)
            }

            ForEach(waitingSessions) { session in
                let wsLabel = sessionStore.labels[session.cwd] ?? SessionLogic.basename(session.cwd)
                SessionRow(
                    session: session,
                    sessionStore: sessionStore,
                    workspacePrefix: wsLabel,
                    isSelected: selectedSessionId == session.sessionId || hoveredRadarSessionId == session.sessionId
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(theme.signalAmber.opacity(theme.isDark ? 0.08 : 0.07))
        .overlay(alignment: .leading) {
            Rectangle().fill(theme.signalAmber).frame(width: 2)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 18)).foregroundColor(theme.inkMuted)
            Text(loc("sessionEmpty"))
                .font(.system(size: 10.5, design: .monospaced)).foregroundColor(theme.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 130)
    }

    private func jumpHintBanner(_ key: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10)).foregroundColor(theme.accent)
            Text(loc(key))
                .font(.system(size: 9.5, design: .monospaced)).foregroundColor(theme.inkPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(theme.accentSoft)
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
                selectedSessionId = SessionNavLogic.moveSelection(
                    currentId: selectedSessionId,
                    orderedIds: orderedVisibleSessionIds,
                    delta: 1
                )
                return nil
            case 126:
                selectedSessionId = SessionNavLogic.moveSelection(
                    currentId: selectedSessionId,
                    orderedIds: orderedVisibleSessionIds,
                    delta: -1
                )
                return nil
            case 36, 76:
                let targetId = selectedSessionId ?? orderedVisibleSessionIds.first
                if let sid = targetId,
                   let match = sessionStore.sessions.first(where: { $0.sessionId == sid }) {
                    sessionStore.jump(match)
                    return nil
                }
                return event
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
            HStack(spacing: 6) {
                Text("+")
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.accent)
                Text(group.label)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.inkPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(String(format: "%02d", group.sessions.count))
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.inkMuted)
            }
            .help(group.cwd)

            VStack(spacing: 2) {
                ForEach(group.sessions) { session in
                    SessionRow(
                        session: session,
                        sessionStore: sessionStore,
                        isSelected: selectedSessionId == session.sessionId || hoveredRadarSessionId == session.sessionId
                    )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

/// One session row: RadarStatusDot + title + aligned bare surface tag + prompt + action/time.
struct SessionRow: View {
    let session: SessionInfo
    @ObservedObject var sessionStore: SessionStore
    var workspacePrefix: String? = nil
    var isSelected: Bool = false

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @State private var hovering = false

    private var isActiveHighlight: Bool { hovering || isSelected }

    var body: some View {
        HStack(spacing: 8) {
            RadarStatusDot(kind: dotKind)
                .accessibilityLabel(statusLabel)

            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 6) {
                    Text(titleText)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(theme.inkPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let surfaceCode = surfaceCode {
                        Text(surfaceCode)
                            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(theme.inkMuted)
                            .fixedSize()
                    }
                }

                Text(workspacePrefix.map { "\($0) · \(subtitleText)" } ?? subtitleText)
                    .font(.system(size: 10))
                    .foregroundColor(theme.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            if dotKind == .waiting {
                let tag = session.waitReason == .needsConfirmation ? loc("badgeConfirm") : loc("badgeInput")
                Text("\(tag) ↗")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundColor(.black)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(theme.signalAmber)
            } else if dotKind == .doneUnseen {
                Text(loc("badgeDone"))
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.signalGreen)
            } else if let updated = session.updatedAt {
                Text(timeAgo(Date(timeIntervalSince1970: updated / 1000), loc))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(theme.inkMuted)
            }

            Text(isActiveHighlight ? "↵" : "")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(theme.accent)
                .frame(width: 11)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .background(isActiveHighlight ? theme.surfaceRaised.opacity(0.9) : Color.clear)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle().fill(theme.accent).frame(width: 2)
            }
        }
        .onHover { inside in
            guard inside != hovering else { return }
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear {
            if hovering { NSCursor.pop(); hovering = false }
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
