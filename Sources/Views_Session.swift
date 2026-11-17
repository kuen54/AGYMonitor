import SwiftUI
import AppKit

// Sessions tab (live Google Antigravity CLI / Desktop / IDE sessions).

// MARK: - Sessions tab

/// Grouped list of live interactive Antigravity sessions by workspace folder,
/// with click-to-jump to the owning terminal tab/pane or Antigravity window.
struct SessionTabView: View {
    @ObservedObject var sessionStore: SessionStore
    @Environment(\.localizer) private var loc

    var body: some View {
        VStack(spacing: 8) {
            let groups = sessionStore.groups
            if groups.isEmpty {
                emptyState
            } else {
                if sessionStore.showOldClaudeHint { hintBanner }
                if let jumpHint = sessionStore.jumpHint { jumpHintBanner(jumpHint) }
                ForEach(groups) { group in
                    SessionGroupSection(group: group, sessionStore: sessionStore)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .animation(.easeInOut(duration: 0.2), value: sessionStore.jumpHint)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 20)).foregroundColor(.secondary)
            Text(loc("sessionEmpty"))
                .font(.system(size: 11)).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
    }

    private var hintBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.circle")
                .font(.system(size: 11)).foregroundColor(.secondary)
            Text(loc("sessionOldCCHint"))
                .font(.system(size: 10.5)).foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }

    private func jumpHintBanner(_ key: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11)).foregroundColor(.secondary)
            Text(loc(key))
                .font(.system(size: 10.5)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.08)))
        .transition(.opacity)
    }
}

/// One workspace's card: folder header + count pill + session rows.
struct SessionGroupSection: View {
    let group: SessionGroup
    @ObservedObject var sessionStore: SessionStore
    @Environment(\.localizer) private var loc

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Text(group.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text("\(group.sessions.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                Spacer(minLength: 0)
            }
            .help(group.cwd)

            VStack(spacing: 2) {
                ForEach(group.sessions) { session in
                    SessionRow(session: session, sessionStore: sessionStore)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}

/// One session row: priority status dot + conversation title + latest prompt
/// instruction + relative timestamp + hover jump affordance.
struct SessionRow: View {
    let session: SessionInfo
    @ObservedObject var sessionStore: SessionStore
    @Environment(\.localizer) private var loc
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .accessibilityLabel(statusLabel)
            VStack(alignment: .leading, spacing: 1) {
                Text(titleText)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitleText)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if let updated = session.updatedAt {
                Text(timeAgo(Date(timeIntervalSince1970: updated / 1000), loc))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .opacity(hovering ? 0.9 : 0.0)
                .frame(width: 13)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0.0))
        )
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

    private var statusColor: Color {
        switch dotKind {
        case .busy:       return .agyBrand
        case .waiting:    return Color.agyStatusWaiting
        case .doneUnseen: return .green
        case .grey:       return .gray
        }
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
