import SwiftUI
import AppKit

// Universal Session Black Box Replay (Tab 04 — Flight Recorder).
// Visual architecture aligned with AGY // TELEMETRY Swiss precision instrumentation:
//   - Mission Selector Strip with 5-topology badge (SWARM / WORKFLOW / SUBAGENT / BATTLE / SOLO)
//   - 04.1 Agent Telemetry Radar · Replay (~168pt): concentric dashed rings, sweeping cobalt
//     sector wedge, topology-aware link & pulse rendering, crimson target-lock fault callout,
//     and collision-free radial node labels (top 5 salient nodes).
//   - Precision Time Scrubber Rail: [|◀] [▶/❚❚] [▶|] [0.5×/1×/2×/4×] + anomaly-mapped interactive rail
//     with WAIT/RETRY spans, Force Touch chronometer haptics, smart-skip indicator, and tabular clock readout.
//   - 04.2 Waterfall & Waste Forensics: multi-track Gantt waterfall with amber/crimson 45°
//     diagonal hatching, slicing vertical cobalt playhead, and click-to-seek tracks.
//   - Bottom 3-Box Forensics KPI Strip: TOTAL SPEND · RETRY WASTE · HUMAN WAIT.
//
// Zero SwiftUI `Button`s inside charts/scrubber/radar (`ImageRenderer`-safe across all 7 themes
// + Light/Dark/Notch), strictly 0% idle CPU when paused, in LIVE mode, or panel hidden.

// MARK: - Top-Level Replay Deck View

struct SessionReplayDeckView: View {
    private enum Source {
        case store(SessionStore, isActiveMode: Bool)
        case standalone(timeline: ReplayTimeline, missions: [ReplayMissionSummary], initialProgress: Double?)
    }

    private let source: Source

    /// Store-connected initializer for `SessionTabView`.
    init(sessionStore: SessionStore, isActiveMode: Bool = true) {
        self.source = .store(sessionStore, isActiveMode: isActiveMode)
    }

    /// Standalone deterministic initializer for `ImageRenderer` QA snapshots & previews.
    init(
        timeline: ReplayTimeline,
        initialProgress: Double? = nil,
        missions: [ReplayMissionSummary]? = nil
    ) {
        let fallbackSummary = ReplayMissionSummary(
            id: timeline.id,
            title: timeline.title,
            workspaceLabel: timeline.workspaceLabel,
            topology: timeline.topology,
            startedAt: 0,
            lastActiveAt: timeline.totalDurationSec,
            durationSec: timeline.totalDurationSec,
            trackCount: timeline.tracks.count,
            stepCount: timeline.tracks.flatMap(\.segments).reduce(0) { $0 + $1.stepCount },
            isLive: false
        )
        self.source = .standalone(
            timeline: timeline,
            missions: missions ?? [fallbackSummary],
            initialProgress: initialProgress
        )
    }

    var body: some View {
        switch source {
        case .store(let store, let isActiveMode):
            StoreBoundReplayDeck(sessionStore: store, isActiveMode: isActiveMode)
        case .standalone(let timeline, let missions, let initialProgress):
            ReplayDeckContent(
                missions: missions,
                selectedMissionId: timeline.id,
                timeline: timeline,
                isIndexLoading: false,
                isTimelineLoading: false,
                isActiveMode: true,
                pinnedInitialProgress: initialProgress,
                onSelectMission: { _ in }
            )
        }
    }
}

private struct StoreBoundReplayDeck: View {
    @ObservedObject var sessionStore: SessionStore
    let isActiveMode: Bool

    var body: some View {
        ReplayDeckContent(
            missions: sessionStore.replayMissions,
            selectedMissionId: sessionStore.selectedReplayMissionId,
            timeline: sessionStore.activeReplay,
            isIndexLoading: sessionStore.isReplayIndexLoading,
            isTimelineLoading: sessionStore.isReplayTimelineLoading,
            isActiveMode: isActiveMode,
            pinnedInitialProgress: nil,
            onSelectMission: { id in
                sessionStore.selectReplayMission(id)
            }
        )
    }
}

// MARK: - Stateful Replay Deck Content (Playback Engine + Mission Selector + Canvas)

private struct ReplayDeckContent: View {
    let missions: [ReplayMissionSummary]
    let selectedMissionId: String?
    let timeline: ReplayTimeline?
    let isIndexLoading: Bool
    let isTimelineLoading: Bool
    let isActiveMode: Bool
    let pinnedInitialProgress: Double?
    let onSelectMission: (String) -> Void

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @Environment(\.telemetryStaticRender) private var isStaticRender
    @Environment(\.telemetryPanelVisible) private var isPanelVisible
    @Environment(\.craftHapticsEnabled) private var hapticsEnabled

    @State private var playback: ReplayPlaybackState
    @State private var tickTimer: Timer? = nil
    @State private var lastTickUptime: TimeInterval = 0
    @State private var liveSweepDeg: Double = 0
    @State private var lastLoadedTimelineId: String? = nil

    init(
        missions: [ReplayMissionSummary],
        selectedMissionId: String?,
        timeline: ReplayTimeline?,
        isIndexLoading: Bool,
        isTimelineLoading: Bool,
        isActiveMode: Bool,
        pinnedInitialProgress: Double?,
        onSelectMission: @escaping (String) -> Void
    ) {
        self.missions = missions
        self.selectedMissionId = selectedMissionId
        self.timeline = timeline
        self.isIndexLoading = isIndexLoading
        self.isTimelineLoading = isTimelineLoading
        self.isActiveMode = isActiveMode
        self.pinnedInitialProgress = pinnedInitialProgress
        self.onSelectMission = onSelectMission

        let startProgress: Double
        if let pinned = pinnedInitialProgress {
            startProgress = min(1.0, max(0.0, pinned))
        } else if let tl = timeline {
            startProgress = ReplayPlaybackState.suggestedInitialProgress(for: tl)
        } else {
            startProgress = 0.0
        }
        _playback = State(initialValue: ReplayPlaybackState(
            progress: startProgress,
            isPlaying: false,
            speed: .x1
        ))
        _lastLoadedTimelineId = State(initialValue: timeline?.id)
    }

    private var shouldTick: Bool {
        playback.isPlaying && isActiveMode && isPanelVisible && !isStaticRender && timeline != nil
    }

    private var currentMissionIndex: Int? {
        if let selId = selectedMissionId ?? timeline?.id,
           let idx = missions.firstIndex(where: { $0.id == selId }) {
            return idx
        }
        return missions.isEmpty ? nil : 0
    }

    private var currentSummary: ReplayMissionSummary? {
        guard let idx = currentMissionIndex, missions.indices.contains(idx) else { return nil }
        return missions[idx]
    }

    var body: some View {
        VStack(spacing: 0) {
            if isIndexLoading && missions.isEmpty && timeline == nil {
                loadingBanner(loc("replayLoadingIndex"))
            } else if missions.isEmpty && timeline == nil {
                emptyReplayState
            } else {
                missionSelectorStrip
                HairlineRule(showCrosshairs: true)

                if let tl = timeline {
                    SessionReplayCanvas(
                        timeline: tl,
                        progress: playback.progress,
                        isPlaying: playback.isPlaying,
                        isSkippingIdle: playback.isPlaying && playback.isSkippingIdle,
                        speed: playback.speed,
                        sweepPhaseDeg: playback.isPlaying ? liveSweepDeg : nil,
                        onScrub: { newProgress in
                            playback.scrub(to: newProgress)
                        },
                        onTogglePlay: {
                            playback.togglePlay()
                            CraftEngine.shared.perform(.chronometerPin, enabled: hapticsEnabled)
                        },
                        onPrevEvent: {
                            let event = playback.stepToPreviousEvent(in: tl)
                            CraftEngine.shared.perform(
                                event?.kind == .retryStart ? .chronometerPin : .chronometerCrown,
                                enabled: hapticsEnabled
                            )
                        },
                        onNextEvent: {
                            let event = playback.stepToNextEvent(in: tl)
                            CraftEngine.shared.perform(
                                event?.kind == .retryStart ? .chronometerPin : .chronometerCrown,
                                enabled: hapticsEnabled
                            )
                        },
                        onCycleSpeed: {
                            playback.cycleSpeed()
                            CraftEngine.shared.perform(.tabDetent, enabled: hapticsEnabled)
                        }
                    )
                } else if isTimelineLoading {
                    loadingBanner(loc("replayLoadingTimeline"))
                } else {
                    emptyReplayState
                }
            }

            HairlineRule(showCrosshairs: false)
            replayColophonFooter
        }
        .onChange(of: missions.first?.id) { firstId in
            if let firstId = firstId,
               selectedMissionId == nil,
               timeline == nil,
               !isTimelineLoading {
                onSelectMission(firstId)
            }
        }
        .onChange(of: timeline?.id) { newId in
            guard newId != lastLoadedTimelineId else { return }
            lastLoadedTimelineId = newId
            stopPlaybackTimer()
            liveSweepDeg = 0
            if let pinned = pinnedInitialProgress {
                playback.reset(initialProgress: pinned)
            } else if let tl = timeline {
                playback.reset(initialProgress: ReplayPlaybackState.suggestedInitialProgress(for: tl))
            } else {
                playback.reset(initialProgress: 0.0)
            }
        }
        .onChange(of: isPanelVisible) { visible in
            if !visible {
                playback.pause()
                stopPlaybackTimer()
            }
        }
        .onChange(of: isActiveMode) { active in
            if !active {
                playback.pause()
                stopPlaybackTimer()
            }
        }
        .onChange(of: shouldTick) { running in
            if running {
                startPlaybackTimer()
            } else {
                stopPlaybackTimer()
            }
        }
        .onAppear {
            if shouldTick {
                startPlaybackTimer()
            }
        }
        .onDisappear {
            playback.pause()
            stopPlaybackTimer()
        }
    }

    // MARK: Strict 0% Idle CPU 60fps Adaptive Playback Timer

    private func startPlaybackTimer() {
        guard tickTimer == nil, shouldTick, let activeTimeline = timeline, activeTimeline.totalDurationSec > 0 else { return }
        // Seed live sweep from deterministic paused angle so playhead starts with zero jump
        liveSweepDeg = (playback.progress * 720.0).truncatingRemainder(dividingBy: 360.0)
        lastTickUptime = ProcessInfo.processInfo.systemUptime
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            let dt = min(0.05, max(0.0, now - lastTickUptime))
            lastTickUptime = now
            playback.step(deltaWallSec: dt, timeline: activeTimeline, smartSkipIdle: true)
            if playback.isPlaying {
                liveSweepDeg = (liveSweepDeg + dt * 90.0).truncatingRemainder(dividingBy: 360.0)
            } else {
                stopPlaybackTimer()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopPlaybackTimer() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // MARK: Mission Selector Strip

    private var missionSelectorStrip: some View {
        let topology = timeline?.topology ?? currentSummary?.topology ?? .solo
        let title = timeline?.title ?? currentSummary?.title ?? loc("sessionUntitled")
        let trackCount = timeline?.tracks.count ?? currentSummary?.trackCount ?? 1
        let durationSec = timeline?.totalDurationSec ?? currentSummary?.durationSec ?? 0
        let dateLabel = timeline?.dateLabel ?? formattedDateLabel(from: currentSummary?.startedAt)
        let isLiveMission = currentSummary?.isLive ?? false
        let idx = currentMissionIndex ?? 0
        let canGoNewer = idx > 0
        let canGoOlder = idx + 1 < missions.count

        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    ReplayTopologyBadge(topology: topology, theme: theme)
                        .fixedSize()

                    Text(title)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.inkPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if isLiveMission {
                        Text(loc("replayLivePill"))
                            .font(.system(size: 6.5, weight: .semibold, design: .monospaced))
                            .tracking(0.5)
                            .foregroundColor(theme.signalGreen)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(theme.signalGreen.opacity(theme.isDark ? 0.14 : 0.10))
                            .overlay(Rectangle().stroke(theme.signalGreen.opacity(0.45), lineWidth: 0.6))
                            .fixedSize()
                    }
                }

                HStack(spacing: 5) {
                    Text(replayTrackCountText(topology: topology, trackCount: trackCount, loc: loc))
                        .font(.system(size: 8, weight: .regular, design: .monospaced))
                        .foregroundColor(theme.inkSecondary)

                    Text("·")
                        .font(.system(size: 8, weight: .regular, design: .monospaced))
                        .foregroundColor(theme.inkMuted.opacity(0.6))

                    Text(formatReplayDuration(durationSec))
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(theme.inkSecondary)

                    if !dateLabel.isEmpty {
                        Text("·")
                            .font(.system(size: 8, weight: .regular, design: .monospaced))
                            .foregroundColor(theme.inkMuted.opacity(0.6))

                        Text(dateLabel)
                            .font(.system(size: 8, weight: .regular, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(theme.inkMuted)
                    }

                    if let ws = timeline?.workspaceLabel ?? currentSummary?.workspaceLabel, !ws.isEmpty {
                        Text("·")
                            .font(.system(size: 8, weight: .regular, design: .monospaced))
                            .foregroundColor(theme.inkMuted.opacity(0.6))

                        Text(ws)
                            .font(.system(size: 8, weight: .regular, design: .monospaced))
                            .foregroundColor(theme.inkMuted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }

            Spacer(minLength: 4)

            if missions.count > 1 {
                HStack(spacing: 3) {
                    ReplayStepperBox(
                        glyph: "‹",
                        enabled: canGoNewer,
                        token: "replay-mission-prev",
                        helpText: loc("replayPrevMissionHelp")
                    ) {
                        guard canGoNewer else { return }
                        CraftEngine.shared.perform(.tabDetent, enabled: hapticsEnabled)
                        onSelectMission(missions[idx - 1].id)
                    }

                    Text(String(format: "%02d/%02d", idx + 1, missions.count))
                        .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(theme.inkMuted)
                        .frame(minWidth: 28, alignment: .center)

                    ReplayStepperBox(
                        glyph: "›",
                        enabled: canGoOlder,
                        token: "replay-mission-next",
                        helpText: loc("replayNextMissionHelp")
                    ) {
                        guard canGoOlder else { return }
                        CraftEngine.shared.perform(.tabDetent, enabled: hapticsEnabled)
                        onSelectMission(missions[idx + 1].id)
                    }
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Empty & Loading States

    private func loadingBanner(_ label: String) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Rectangle()
                    .fill(theme.accent)
                    .frame(width: 4, height: 4)
                Text(label)
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .tracking(0.85)
                    .foregroundColor(theme.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 180)
    }

    private var emptyReplayState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 16, weight: .light))
                .foregroundColor(theme.inkMuted)
            Text(loc("replayEmpty"))
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(theme.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: 180)
    }

    private var replayColophonFooter: some View {
        HStack(spacing: 5) {
            Text(loc("replayColophonHint"))
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

            Text("BLACK BOX")
                .font(.system(size: 7.5, weight: .regular, design: .monospaced))
                .tracking(0.8)
                .foregroundColor(theme.inkMuted.opacity(0.78))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6.5)
    }

    private func formattedDateLabel(from unixSec: Double?) -> String {
        guard let ts = unixSec, ts > 0 else { return "" }
        let comps = AppDate.gregorian.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: ts))
        guard let y = comps.year, let m = comps.month, let d = comps.day else { return "" }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }
}

// MARK: - Stateless / Interactive Session Replay Canvas (ImageRenderer-Safe)

struct SessionReplayCanvas: View {
    let timeline: ReplayTimeline
    let progress: Double
    var isPlaying: Bool = false
    var isSkippingIdle: Bool = false
    var speed: ReplaySpeed = .x1
    var sweepPhaseDeg: Double? = nil
    var onScrub: (Double) -> Void = { _ in }
    var onTogglePlay: () -> Void = {}
    var onPrevEvent: () -> Void = {}
    var onNextEvent: () -> Void = {}
    var onCycleSpeed: () -> Void = {}

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @Environment(\.telemetryStaticRender) private var isStaticRender
    @Environment(\.craftHapticsEnabled) private var hapticsEnabled

    var body: some View {
        let clampedProgress = progress.isFinite ? min(1.0, max(0.0, progress)) : 0.0
        let nodes = ReplayLogic.radarLayout(timeline: timeline)
        let snapshot = ReplayLogic.evaluateFrame(
            timeline: timeline,
            progress: clampedProgress,
            sweepPhaseDeg: (isPlaying && !isStaticRender) ? sweepPhaseDeg : nil
        )

        VStack(spacing: 0) {
            // Upper Deck — 04.1 Agent Telemetry Radar · Replay
            ReplayRadarDeckView(
                timeline: timeline,
                nodes: nodes,
                snapshot: snapshot,
                onSelectTrack: { trackId in
                    seekToTrack(trackId)
                }
            )

            HairlineRule(showCrosshairs: true)

            // Middle Precision Time Scrubber Rail
            ReplayScrubberRailView(
                timeline: timeline,
                progress: clampedProgress,
                currentSec: snapshot.currentSec,
                isPlaying: isPlaying,
                isSkippingIdle: isPlaying && !isStaticRender && isSkippingIdle,
                speed: speed,
                onScrub: onScrub,
                onTogglePlay: onTogglePlay,
                onPrevEvent: onPrevEvent,
                onNextEvent: onNextEvent,
                onCycleSpeed: onCycleSpeed
            )

            HairlineRule(showCrosshairs: true)

            // Lower Deck — 04.2 Waterfall & Waste Forensics
            ReplayWaterfallDeckView(
                timeline: timeline,
                progress: clampedProgress,
                snapshot: snapshot,
                isStaticRender: isStaticRender,
                onSeekProgress: { p in
                    onScrub(p)
                    CraftEngine.shared.perform(.chronometerPin, enabled: hapticsEnabled)
                },
                onSelectTrack: { trackId in
                    seekToTrack(trackId)
                }
            )

            HairlineRule(showCrosshairs: false)

            // Bottom 3-Box Forensics KPI Strip
            ReplayForensicsKPIStrip(timeline: timeline)
        }
    }

    private func seekToTrack(_ trackId: String) {
        guard timeline.totalDurationSec > 0,
              let track = timeline.tracks.first(where: { $0.id == trackId }) else { return }
        let targetSec: Double
        if let retry = track.segments.first(where: { $0.kind == .retryLoop }) {
            targetSec = (retry.startSec + retry.endSec) * 0.5
        } else if let wait = track.segments.first(where: { $0.kind == .humanWait }) {
            targetSec = (wait.startSec + wait.endSec) * 0.5
        } else if let first = track.segments.first {
            targetSec = first.startSec
        } else {
            return
        }
        let nextProgress = min(1.0, max(0.0, targetSec / timeline.totalDurationSec))
        onScrub(nextProgress)
        CraftEngine.shared.perform(.chronometerPin, enabled: hapticsEnabled)
    }
}

// MARK: - 04.1 Agent Telemetry Radar · Replay (~168pt)

private struct ReplayRadarDeckView: View {
    let timeline: ReplayTimeline
    let nodes: [ReplayRadarNode]
    let snapshot: ReplayPlayheadSnapshot
    let onSelectTrack: (String) -> Void

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @Environment(\.craftHapticsEnabled) private var hapticsEnabled

    @State private var hoveredNodeId: String? = nil

    private let radarHeight: CGFloat = 168

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            radarHeaderRow

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height

                ZStack {
                    ReplayRadarCanvas(
                        timeline: timeline,
                        nodes: nodes,
                        snapshot: snapshot,
                        hoveredNodeId: hoveredNodeId,
                        theme: theme,
                        loc: loc
                    )
                    .allowsHitTesting(false)

                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover(coordinateSpace: .local) { phase in
                            switch phase {
                            case .active(let pt):
                                let hit = hitTestNode(at: pt, size: CGSize(width: w, height: h))
                                if hoveredNodeId != hit?.id {
                                    hoveredNodeId = hit?.id
                                    if hit != nil {
                                        CraftEngine.shared.perform(.radarBeaconLock, enabled: hapticsEnabled)
                                    }
                                }
                                PointingCursorCoordinator.shared.setPointing(hit != nil, token: "replay-radar")
                            case .ended:
                                if hoveredNodeId != nil { hoveredNodeId = nil }
                                PointingCursorCoordinator.shared.setPointing(false, token: "replay-radar")
                            }
                        }
                        .onTapGesture(coordinateSpace: .local) { pt in
                            if let hit = hitTestNode(at: pt, size: CGSize(width: w, height: h)) {
                                onSelectTrack(hit.id)
                            }
                        }
                        .onDisappear {
                            hoveredNodeId = nil
                            PointingCursorCoordinator.shared.setPointing(false, token: "replay-radar")
                        }
                }
            }
            .frame(height: radarHeight)
            .background(theme.surface.opacity(theme.isDark ? 0.88 : 0.65))
            .overlay(Rectangle().stroke(theme.hairline, lineWidth: 0.85).allowsHitTesting(false))
            .overlay(CornerReticleOverlay(color: theme.reticle.opacity(0.65), length: 6, lineWidth: 0.85))
        }
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 9)
    }

    private var radarHeaderRow: some View {
        let nonRootCount = max(0, timeline.tracks.filter { $0.kind != .root }.count)
        let faultCount = timeline.totalRetryLoops
        let hasFault = faultCount > 0 || snapshot.activeFault != nil

        return HStack(spacing: 5) {
            Text("04.1")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.accent.opacity(0.92))
                .fixedSize()

            Text(loc("replayRadarTitle"))
                .font(.system(size: 8, weight: .regular, design: .monospaced))
                .tracking(0.8)
                .foregroundColor(theme.inkSecondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            HStack(spacing: 4) {
                Text(radarCountSummary(nonRootCount: nonRootCount))
                    .font(.system(size: 7.5, weight: .regular, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(theme.inkMuted)

                Text("·")
                    .font(.system(size: 7.5, weight: .regular, design: .monospaced))
                    .foregroundColor(theme.inkMuted.opacity(0.55))

                if hasFault {
                    let countVal = max(1, faultCount)
                    let fmt = (countVal == 1) ? loc("replayFaultTagFmt") : loc("replayFaultsTagFmt")
                    Text(String(format: fmt, countVal))
                        .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(theme.signalRed)
                } else {
                    Text(loc("replayNominalTag"))
                        .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.inkSecondary)
                }
            }
            .fixedSize()
        }
    }

    private func radarCountSummary(nonRootCount: Int) -> String {
        switch timeline.topology {
        case .swarm:
            return String(format: "01 HUB · %02d WRK", nonRootCount)
        case .dynamicWorkflow:
            return String(format: "%02d STG", max(1, nonRootCount))
        case .subagentTree:
            return String(format: "%02d AGT", timeline.tracks.count)
        case .battle:
            return String(format: "%02d BRN", max(1, nonRootCount))
        case .solo:
            return "01 CORE"
        }
    }

    private func hitTestNode(at pt: CGPoint, size: CGSize) -> ReplayRadarNode? {
        guard size.width > 10, size.height > 10 else { return nil }
        var best: ReplayRadarNode? = nil
        var bestDist: CGFloat = 18.0
        for node in nodes {
            let nx = CGFloat(node.normX) * size.width
            let ny = CGFloat(node.normY) * size.height
            let d = hypot(pt.x - nx, pt.y - ny)
            if d < bestDist {
                bestDist = d
                best = node
            }
        }
        return best
    }
}

private struct ReplayRadarCanvas: View {
    let timeline: ReplayTimeline
    let nodes: [ReplayRadarNode]
    let snapshot: ReplayPlayheadSnapshot
    let hoveredNodeId: String?
    let theme: AGYTheme
    let loc: Localizer

    var body: some View {
        Canvas { context, size in
            let cw = size.width
            let ch = size.height
            guard cw > 24, ch > 24 else { return }

            let center = CGPoint(x: cw * 0.5, y: ch * 0.5)
            let nodeById = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
            let trackById = Dictionary(uniqueKeysWithValues: timeline.tracks.map { ($0.id, $0) })

            func pt(_ node: ReplayRadarNode) -> CGPoint {
                CGPoint(x: CGFloat(node.normX) * cw, y: CGFloat(node.normY) * ch)
            }

            // 1. Subtle radial optical wash + dark scanlines + batched dot graticule
            let outerR = min(cw * 0.36, ch * 0.44)
            context.fill(
                Path(CGRect(x: 0, y: 0, width: cw, height: ch)),
                with: .radialGradient(
                    Gradient(colors: [
                        theme.accent.opacity(theme.isDark ? 0.065 : 0.028),
                        Color.clear,
                    ]),
                    center: center,
                    startRadius: 4,
                    endRadius: outerR * 1.45
                )
            )

            if theme.isDark {
                var scanLines = Path()
                var sy: CGFloat = 4
                while sy < ch - 2 {
                    scanLines.move(to: CGPoint(x: 4, y: sy))
                    scanLines.addLine(to: CGPoint(x: cw - 4, y: sy))
                    sy += 4
                }
                context.stroke(scanLines, with: .color(theme.inkPrimary.opacity(0.028)), lineWidth: 0.5)
            }

            var graticuleDots = Path()
            let spacing: CGFloat = 14
            var gy: CGFloat = spacing * 0.5
            while gy < ch {
                var gx: CGFloat = spacing * 0.5
                while gx < cw {
                    graticuleDots.addRect(CGRect(x: gx, y: gy, width: 1, height: 1))
                    gx += spacing
                }
                gy += spacing
            }
            context.fill(graticuleDots, with: .color(theme.hairline.opacity(0.42)))

            // 2. Vernier edge ticks (left/right/top/bottom)
            var edgeTicks = Path()
            var ty: CGFloat = 12
            var tIdx = 0
            while ty <= ch - 12 {
                let len: CGFloat = (tIdx % 4 == 0) ? 5.0 : 2.5
                edgeTicks.move(to: CGPoint(x: 0, y: ty))
                edgeTicks.addLine(to: CGPoint(x: len, y: ty))
                edgeTicks.move(to: CGPoint(x: cw - len, y: ty))
                edgeTicks.addLine(to: CGPoint(x: cw, y: ty))
                ty += 7
                tIdx += 1
            }
            for frac in [0.25, 0.5, 0.75] as [CGFloat] {
                let tx = cw * frac
                edgeTicks.move(to: CGPoint(x: tx, y: 0))
                edgeTicks.addLine(to: CGPoint(x: tx, y: 3.5))
                edgeTicks.move(to: CGPoint(x: tx, y: ch - 3.5))
                edgeTicks.addLine(to: CGPoint(x: tx, y: ch))
            }
            context.stroke(edgeTicks, with: .color(theme.hairlineStrong.opacity(0.55)), lineWidth: 0.65)

            // 3. Concentric dashed calibration rings + 30° azimuth ticks + cardinal axes
            let ringRadii: [CGFloat] = [outerR * 0.36, outerR * 0.68, outerR]
            var rangeCircles = Path()
            var azimuthTicks = Path()
            for (rIdx, radius) in ringRadii.enumerated() {
                rangeCircles.addEllipse(in: CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                ))
                if rIdx >= 1 {
                    let tickLen: CGFloat = rIdx == 1 ? 2.2 : 2.8
                    for deg in stride(from: 0, to: 360, by: 30) where deg % 90 != 0 {
                        let rad = Double(deg) * .pi / 180.0
                        let ca = CGFloat(cos(rad))
                        let sa = CGFloat(sin(rad))
                        azimuthTicks.move(to: CGPoint(x: center.x + ca * (radius - tickLen * 0.5), y: center.y + sa * (radius - tickLen * 0.5)))
                        azimuthTicks.addLine(to: CGPoint(x: center.x + ca * (radius + tickLen * 0.5), y: center.y + sa * (radius + tickLen * 0.5)))
                    }
                }
            }
            let ringColor = theme.isMultiColorSpectrum ? theme.accent : theme.accentSecondary
            context.stroke(
                rangeCircles,
                with: .color(ringColor.opacity(theme.isDark ? 0.28 : 0.24)),
                style: StrokeStyle(lineWidth: 0.65, dash: [2.5, 3.0])
            )
            context.stroke(azimuthTicks, with: .color(ringColor.opacity(theme.isDark ? 0.42 : 0.34)), lineWidth: 0.6)

            var axes = Path()
            axes.move(to: CGPoint(x: 8, y: center.y))
            axes.addLine(to: CGPoint(x: cw - 8, y: center.y))
            axes.move(to: CGPoint(x: center.x, y: 6))
            axes.addLine(to: CGPoint(x: center.x, y: ch - 6))
            context.stroke(axes, with: .color(theme.hairline.opacity(0.40)), lineWidth: 0.6)

            // 4. Sweeping cobalt radar sector wedge tied to `snapshot.sweepAngleDeg`
            let sweepRad = (snapshot.sweepAngleDeg - 90.0) * .pi / 180.0
            let trailRad = 48.0 * .pi / 180.0
            let sliceCount = 14
            let maxWedgeAlpha: Double = theme.isDark ? 0.22 : 0.14
            for s in 0..<sliceCount {
                let f0 = Double(s) / Double(sliceCount)
                let f1 = Double(s + 1) / Double(sliceCount)
                let a0 = sweepRad - trailRad * (1.0 - f0)
                let a1 = sweepRad - trailRad * (1.0 - f1)
                var wedge = Path()
                wedge.move(to: center)
                wedge.addArc(
                    center: center,
                    radius: outerR,
                    startAngle: .radians(a0),
                    endAngle: .radians(a1),
                    clockwise: false
                )
                wedge.closeSubpath()
                let alpha = pow(f1, 1.8) * maxWedgeAlpha
                context.fill(wedge, with: .color(theme.accent.opacity(alpha)))
            }
            var sweepArm = Path()
            sweepArm.move(to: center)
            sweepArm.addLine(to: CGPoint(
                x: center.x + CGFloat(cos(sweepRad)) * outerR,
                y: center.y + CGFloat(sin(sweepRad)) * outerR
            ))
            context.stroke(sweepArm, with: .color(theme.accent.opacity(theme.isDark ? 0.55 : 0.38)), lineWidth: 0.85)

            // 5. Cardinal calibration labels (000° / 090° / 180° / 270°)
            let compassColor = theme.inkMuted.opacity(theme.isDark ? 0.82 : 0.78)
            let northPos = CGPoint(x: center.x, y: 9)
            let southPos = CGPoint(x: center.x, y: ch - 9)
            let eastPos  = CGPoint(x: cw - 9, y: center.y - 6)
            let westPos  = CGPoint(x: 9, y: center.y - 6)
            context.draw(Text("000°").font(.system(size: 6.2, weight: .medium, design: .monospaced)).foregroundColor(compassColor), at: northPos)
            context.draw(Text("180°").font(.system(size: 6.2, weight: .medium, design: .monospaced)).foregroundColor(compassColor), at: southPos)
            context.draw(Text("090°").font(.system(size: 6.2, weight: .medium, design: .monospaced)).foregroundColor(compassColor), at: eastPos, anchor: .trailing)
            context.draw(Text("270°").font(.system(size: 6.2, weight: .medium, design: .monospaced)).foregroundColor(compassColor), at: westPos, anchor: .leading)

            // 6. Topology-aware links & structural guides
            drawTopologyLinks(
                in: &context,
                size: size,
                center: center,
                outerR: outerR,
                nodes: nodes,
                nodeById: nodeById,
                trackById: trackById,
                pt: pt
            )

            // 7. Traveling pulse packets for `snapshot.activeBeams`
            for beam in snapshot.activeBeams {
                guard let fromNode = nodeById[beam.fromTrackId],
                      let toNode = nodeById[beam.toTrackId],
                      fromNode.id != toNode.id else { continue }
                let p0 = pt(fromNode)
                let p1 = pt(toNode)
                let t = CGFloat(min(1.0, max(0.0, beam.progress)))
                let bx = p0.x + (p1.x - p0.x) * t
                let by = p0.y + (p1.y - p0.y) * t
                let head = CGPoint(x: bx, y: by)

                let targetState = snapshot.trackStates[toNode.id] ?? .idle
                let beamColor: Color = (targetState == .retrying)
                    ? theme.signalRed
                    : (timeline.topology == .battle
                        ? theme.signalAmber
                        : (beam.kind == .subagentMessage ? replayVerifyColor(theme) : theme.accent))

                // Smoothly tapered luminous trailing wake behind the pulse packet
                let wakeStart = max(0.0, t - 0.26)
                if t > wakeStart + 0.005 {
                    let tailOrigin = CGPoint(
                        x: p0.x + (p1.x - p0.x) * wakeStart,
                        y: p0.y + (p1.y - p0.y) * wakeStart
                    )
                    var wake = Path()
                    wake.move(to: tailOrigin)
                    wake.addLine(to: head)

                    // Soft outer trail glow
                    context.stroke(
                        wake,
                        with: .linearGradient(
                            Gradient(colors: [
                                beamColor.opacity(0.0),
                                beamColor.opacity(theme.isDark ? 0.34 : 0.24),
                            ]),
                            startPoint: tailOrigin,
                            endPoint: head
                        ),
                        style: StrokeStyle(lineWidth: 3.4, lineCap: .round)
                    )
                    // Crisp bright inner wake filament
                    context.stroke(
                        wake,
                        with: .linearGradient(
                            Gradient(colors: [
                                beamColor.opacity(0.0),
                                beamColor.opacity(theme.isDark ? 0.92 : 0.80),
                            ]),
                            startPoint: tailOrigin,
                            endPoint: head
                        ),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                    )
                }

                // Multi-layer luminous packet bloom + glowing core + bright pinpoint center
                context.fill(
                    Path(ellipseIn: CGRect(x: bx - 6.5, y: by - 6.5, width: 13.0, height: 13.0)),
                    with: .color(beamColor.opacity(theme.isDark ? 0.22 : 0.14))
                )
                context.fill(
                    Path(ellipseIn: CGRect(x: bx - 3.8, y: by - 3.8, width: 7.6, height: 7.6)),
                    with: .color(beamColor.opacity(theme.isDark ? 0.44 : 0.30))
                )
                context.fill(
                    Path(ellipseIn: CGRect(x: bx - 2.3, y: by - 2.3, width: 4.6, height: 4.6)),
                    with: .color(beamColor)
                )
                context.fill(
                    Path(ellipseIn: CGRect(x: bx - 1.0, y: by - 1.0, width: 2.0, height: 2.0)),
                    with: .color(Color.white.opacity(theme.isDark ? 0.92 : 0.86))
                )
            }

            // Track occupied bounding boxes for guaranteed non-overlapping labels & fault callout
            var occupiedRects: [CGRect] = [
                CGRect(x: northPos.x - 16, y: northPos.y - 6, width: 32, height: 12),
                CGRect(x: southPos.x - 16, y: southPos.y - 6, width: 32, height: 12),
                CGRect(x: eastPos.x - 24,  y: eastPos.y - 6,  width: 24, height: 12),
                CGRect(x: westPos.x,       y: westPos.y - 6,  width: 24, height: 12),
            ]
            for node in nodes {
                let np = pt(node)
                let state = snapshot.trackStates[node.id] ?? .idle
                let pad: CGFloat = (state == .retrying) ? 14.0 : (node.kind == .root ? 11.0 : 9.5)
                occupiedRects.append(CGRect(x: np.x - pad, y: np.y - pad, width: pad * 2, height: pad * 2))
            }

            // 8. Draw Node Beacons
            let rootNode = nodes.first(where: { $0.kind == .root }) ?? nodes.first
            for node in nodes {
                let np = pt(node)
                let state = snapshot.trackStates[node.id] ?? .idle
                let isHovered = (hoveredNodeId == node.id)
                let isFaultTarget = (snapshot.activeFault?.trackId == node.id)

                if node.kind == .root {
                    drawRootNode(in: &context, at: np, state: state, isHovered: isHovered, isFaultTarget: isFaultTarget)
                } else {
                    drawWorkerNode(in: &context, at: np, state: state, isHovered: isHovered, isFaultTarget: isFaultTarget)
                }
            }

            // 9. Root Hub Pill Badge (e.g. COORD / COORDINATOR / ORCHESTRATOR)
            if let root = rootNode {
                let rp = pt(root)
                let rootLabel = shortDisplayLabel(root.name.uppercased(), maxLen: 12)
                let badgeW = max(34, CGFloat(rootLabel.count) * 4.9 + 10)
                let badgeH: CGFloat = 12
                let badgeY = min(ch - 8 - badgeH, rp.y + 10.5)
                let badgeX = min(max(8, rp.x - badgeW * 0.5), cw - 8 - badgeW)
                let badgeRect = CGRect(x: badgeX, y: badgeY, width: badgeW, height: badgeH)

                context.fill(Path(badgeRect), with: .color(theme.isDark ? theme.canvas.opacity(0.94) : theme.surfaceRaised.opacity(0.96)))
                context.stroke(Path(badgeRect), with: .color(theme.hairlineStrong.opacity(0.85)), lineWidth: 0.7)
                let rootText = Text(rootLabel)
                    .font(.system(size: 6.8, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundColor(theme.inkPrimary)
                context.draw(rootText, at: CGPoint(x: badgeRect.midX, y: badgeRect.midY))
                occupiedRects.append(badgeRect.insetBy(dx: -2, dy: -1.5))
            }

            // 10. Active Fault Target-Lock Callout (`LOOP ×N · -$X.XX`, strictly clamped inside bounds)
            var labeledIds = Set<String>()
            if let root = rootNode { labeledIds.insert(root.id) }

            if let fault = snapshot.activeFault,
               let faultNode = nodeById[fault.trackId] {
                let fp = pt(faultNode)
                let line1 = String(
                    format: loc("replayLoopCalloutFmt"),
                    max(1, fault.retryCount),
                    formatCostTabular(fault.wasteUSD)
                )
                let coordStr = String(format: "X%.2f Y%.2f", faultNode.normX, faultNode.normY)
                let line2 = "\(shortDisplayLabel(fault.trackName, maxLen: 11)) · \(coordStr)"

                let boxW = min(cw - 16, max(98, max(CGFloat(line1.count) * 4.9 + 14, CGFloat(line2.count) * 4.2 + 12)))
                let boxH: CGFloat = 25.0
                let placement = placeReplayLabelBox(
                    near: fp,
                    awayFrom: center,
                    boxSize: CGSize(width: boxW, height: boxH),
                    reticleGap: 15.0,
                    bounds: CGSize(width: cw, height: ch),
                    occupied: occupiedRects
                )
                occupiedRects.append(placement.rect.insetBy(dx: -3, dy: -2))
                labeledIds.insert(faultNode.id)

                drawReplayLeaderLine(
                    in: &context,
                    from: fp,
                    to: placement.rect,
                    reticleRadius: 12.0,
                    color: theme.signalRed.opacity(0.82),
                    lineWidth: 0.85
                )

                // Top crimson framed callout header
                let topRect = CGRect(x: placement.rect.minX, y: placement.rect.minY, width: placement.rect.width, height: 13.0)
                let botRect = CGRect(x: placement.rect.minX, y: placement.rect.minY + 13.0, width: placement.rect.width, height: 12.0)

                context.fill(Path(placement.rect), with: .color(theme.isDark ? theme.canvas.opacity(0.94) : theme.surfaceRaised.opacity(0.96)))
                context.fill(Path(topRect), with: .color(theme.signalRed.opacity(theme.isDark ? 0.20 : 0.11)))
                context.stroke(Path(topRect), with: .color(theme.signalRed.opacity(0.88)), lineWidth: 0.85)
                context.stroke(Path(botRect), with: .color(theme.hairline.opacity(0.85)), lineWidth: 0.55)

                let topText = Text(line1)
                    .font(.system(size: 7.0, weight: .bold, design: .monospaced))
                    .tracking(0.35)
                    .foregroundColor(theme.signalRed)
                context.draw(topText, at: CGPoint(x: topRect.midX, y: topRect.midY))

                let botText = Text(line2)
                    .font(.system(size: 6.3, weight: .regular, design: .monospaced))
                    .foregroundColor(theme.inkSecondary)
                context.draw(botText, at: CGPoint(x: botRect.midX, y: botRect.midY))
            }

            // 11. Top-5 Compact Non-Overlapping Node Telemetry Labels
            let candidateNodes = nodes
                .filter { !labeledIds.contains($0.id) }
                .sorted { a, b in
                    let pa = labelSaliencePriority(a, state: snapshot.trackStates[a.id] ?? .idle)
                    let pb = labelSaliencePriority(b, state: snapshot.trackStates[b.id] ?? .idle)
                    if pa != pb { return pa < pb }
                    return a.estimatedCostUSD > b.estimatedCostUSD
                }
                .prefix(5)

            for node in candidateNodes {
                let np = pt(node)
                let state = snapshot.trackStates[node.id] ?? .idle
                let nameStr = shortDisplayLabel(node.name, maxLen: 12)
                let stateTag = localizedLiveStateTag(state, loc: loc)
                let costStr = formatCostTabular(node.estimatedCostUSD)
                let subStr = "\(stateTag) · \(costStr)"

                let boxW = max(58, min(92, max(CGFloat(nameStr.count) * 4.8 + 10, CGFloat(subStr.count) * 4.1 + 10)))
                let boxH: CGFloat = 20.5

                let placement = placeReplayLabelBox(
                    near: np,
                    awayFrom: center,
                    boxSize: CGSize(width: boxW, height: boxH),
                    reticleGap: 11.5,
                    bounds: CGSize(width: cw, height: ch),
                    occupied: occupiedRects
                )
                // Skip if severely crowded on dense 10+ worker swarms
                if placement.overlapArea > 32 && nodes.count > 7 {
                    continue
                }
                occupiedRects.append(placement.rect.insetBy(dx: -2, dy: -1.5))

                let backingRect = placement.rect.insetBy(dx: -2, dy: -1)
                context.fill(
                    Path(backingRect),
                    with: .color(theme.isDark ? theme.canvas.opacity(0.90) : theme.surfaceRaised.opacity(0.92))
                )
                context.stroke(
                    Path(backingRect),
                    with: .color(theme.hairline.opacity(0.75)),
                    lineWidth: 0.55
                )

                let tx = placement.alignRight ? placement.rect.maxX - 1 : placement.rect.minX + 1
                let anchor: UnitPoint = placement.alignRight ? .trailing : .leading

                let nameText = Text(nameStr)
                    .font(.system(size: 7.0, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.inkPrimary)
                let subColor: Color = {
                    switch state {
                    case .retrying: return theme.signalRed
                    case .waiting:  return theme.signalAmber
                    case .working:  return theme.accent
                    case .verify:   return replayVerifyColor(theme)
                    case .done:     return theme.signalGreen
                    case .idle:     return theme.inkMuted
                    }
                }()
                let subText = Text(subStr)
                    .font(.system(size: 6.2, weight: .regular, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(subColor)

                context.draw(nameText, at: CGPoint(x: tx, y: placement.rect.minY + 5.5), anchor: anchor)
                context.draw(subText, at: CGPoint(x: tx, y: placement.rect.minY + 14.5), anchor: anchor)
            }
        }
    }

    // MARK: Topology-Aware Link Drawing

    private func drawTopologyLinks(
        in context: inout GraphicsContext,
        size: CGSize,
        center: CGPoint,
        outerR: CGFloat,
        nodes: [ReplayRadarNode],
        nodeById: [String: ReplayRadarNode],
        trackById: [String: ReplayTrack],
        pt: (ReplayRadarNode) -> CGPoint
    ) {
        let rootNode = nodes.first(where: { $0.kind == .root }) ?? nodes.first

        switch timeline.topology {
        case .swarm:
            // Dashed coordinator -> worker spokes styled by live worker state
            for node in nodes where node.id != rootNode?.id {
                guard let parent = node.parentId.flatMap({ nodeById[$0] }) ?? rootNode else { continue }
                let p0 = pt(parent)
                let p1 = pt(node)
                let state = snapshot.trackStates[node.id] ?? .idle
                var spoke = Path()
                spoke.move(to: p0)
                spoke.addLine(to: p1)
                let (color, lw) = linkStyle(for: state, activeDefault: theme.accent)
                context.stroke(
                    spoke,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: lw, dash: [3.2, 2.4])
                )
            }

        case .dynamicWorkflow:
            // Solid directed stage arcs lighting up wave-by-wave
            let stageNodes = nodes.filter { $0.id != rootNode?.id }
            let groupedByX = Dictionary(grouping: stageNodes) { Int(($0.normX * 12.0).rounded()) }
            let sortedCols = groupedByX.keys.sorted()

            if let root = rootNode, let firstCol = sortedCols.first, let wave0 = groupedByX[firstCol] {
                let rp = pt(root)
                for target in wave0 {
                    drawDirectedArc(
                        in: &context,
                        from: rp,
                        to: pt(target),
                        state: snapshot.trackStates[target.id] ?? .idle
                    )
                }
            }
            for idx in 0..<max(0, sortedCols.count - 1) {
                let prevWave = groupedByX[sortedCols[idx]] ?? []
                let nextWave = groupedByX[sortedCols[idx + 1]] ?? []
                for target in nextWave {
                    // Connect from nearest preceding wave node to keep DAG ultra-clean
                    let tp = pt(target)
                    let source = prevWave.min { a, b in
                        abs(pt(a).y - tp.y) < abs(pt(b).y - tp.y)
                    }
                    if let src = source {
                        drawDirectedArc(
                            in: &context,
                            from: pt(src),
                            to: tp,
                            state: snapshot.trackStates[target.id] ?? .idle
                        )
                    }
                }
            }

        case .subagentTree:
            // Depth tier horizontal/radial guide lines (`D0 / D1 / D2`) + parent->child delegation lines
            let treeTint = replayVerifyColor(theme)
            let depths = Array(Set(nodes.map(\.depth))).sorted()
            for depth in depths {
                let levelNodes = nodes.filter { $0.depth == depth }
                guard let first = levelNodes.first else { continue }
                let y = CGFloat(first.normY) * size.height
                var guide = Path()
                guide.move(to: CGPoint(x: 16, y: y))
                guide.addLine(to: CGPoint(x: size.width - 16, y: y))
                context.stroke(
                    guide,
                    with: .color(treeTint.opacity(theme.isDark ? 0.16 : 0.13)),
                    style: StrokeStyle(lineWidth: 0.6, dash: [2, 3])
                )
                let dTag = Text("D\(depth)")
                    .font(.system(size: 5.8, weight: .semibold, design: .monospaced))
                    .foregroundColor(treeTint.opacity(0.72))
                // Avoid collision with the `270°` cardinal compass label at `y = center.y - 6`
                let tagY: CGFloat = abs(y - size.height * 0.5) < 16 ? (y + 7.5) : (y - 5.5)
                context.draw(dTag, at: CGPoint(x: 11, y: tagY), anchor: .leading)
            }

            for node in nodes where node.id != rootNode?.id {
                guard let parent = node.parentId.flatMap({ nodeById[$0] }) ?? rootNode else { continue }
                let p0 = pt(parent)
                let p1 = pt(node)
                let state = snapshot.trackStates[node.id] ?? .idle
                let midY = (p0.y + p1.y) * 0.5
                var line = Path()
                line.move(to: p0)
                line.addCurve(
                    to: p1,
                    control1: CGPoint(x: p0.x, y: midY),
                    control2: CGPoint(x: p1.x, y: midY)
                )
                let (color, lw) = linkStyle(for: state, activeDefault: treeTint)
                context.stroke(line, with: .color(color), lineWidth: lw)
            }

        case .battle:
            // Split opposing curved arena arcs + horizontal comparison bridge
            let branches = nodes.filter { $0.id != rootNode?.id }
            if let root = rootNode {
                let rp = pt(root)
                for branch in branches {
                    let bp = pt(branch)
                    let state = snapshot.trackStates[branch.id] ?? .idle
                    let ctrl = CGPoint(x: bp.x, y: rp.y + (bp.y - rp.y) * 0.25)
                    var arc = Path()
                    arc.move(to: rp)
                    arc.addQuadCurve(to: bp, control: ctrl)
                    let (color, lw) = linkStyle(for: state, activeDefault: theme.signalAmber)
                    context.stroke(arc, with: .color(color), lineWidth: lw + 0.15)
                }
            }
            if branches.count >= 2 {
                let pA = pt(branches[0])
                let pB = pt(branches[branches.count - 1])
                var bridge = Path()
                bridge.move(to: pA)
                bridge.addLine(to: pB)
                context.stroke(
                    bridge,
                    with: .color(theme.signalAmber.opacity(theme.isDark ? 0.28 : 0.24)),
                    style: StrokeStyle(lineWidth: 0.7, dash: [2, 2.5])
                )
            }

        case .solo:
            // Centered pulse core with work / wait / retry / verify phase arc ring
            if let root = rootNode, let track = trackById[root.id], timeline.totalDurationSec > 0 {
                let rp = pt(root)
                let phaseRadius = outerR * 0.58
                let total = max(1.0, timeline.totalDurationSec)
                for seg in track.segments {
                    let a0 = (seg.startSec / total) * 2.0 * .pi - .pi * 0.5
                    let a1 = (seg.endSec / total) * 2.0 * .pi - .pi * 0.5
                    guard a1 > a0 + 0.01 else { continue }
                    var arc = Path()
                    arc.addArc(
                        center: rp,
                        radius: phaseRadius,
                        startAngle: .radians(a0),
                        endAngle: .radians(a1),
                        clockwise: false
                    )
                    let color: Color = {
                        switch seg.kind {
                        case .work:      return theme.accent.opacity(0.75)
                        case .humanWait: return theme.signalAmber.opacity(0.82)
                        case .retryLoop: return theme.signalRed.opacity(0.92)
                        case .verify:    return replayVerifyColor(theme).opacity(0.82)
                        }
                    }()
                    context.stroke(arc, with: .color(color), style: StrokeStyle(lineWidth: 3.0, lineCap: .butt))
                }
            }
        }
    }

    private func drawDirectedArc(
        in context: inout GraphicsContext,
        from p0: CGPoint,
        to p1: CGPoint,
        state: ReplayTrackLiveState
    ) {
        let midX = (p0.x + p1.x) * 0.5
        let curveLift: CGFloat = (p1.y - p0.y) * 0.14
        var arc = Path()
        arc.move(to: p0)
        arc.addCurve(
            to: p1,
            control1: CGPoint(x: midX, y: p0.y - curveLift),
            control2: CGPoint(x: midX, y: p1.y + curveLift)
        )
        let (color, lw) = linkStyle(for: state, activeDefault: theme.accent)
        context.stroke(arc, with: .color(color), lineWidth: lw)

        // Crisp micro directional chevron near destination
        let dx = p1.x - midX
        let dy = -curveLift
        let angle = atan2(dy, max(1.0, dx))
        let tip = CGPoint(x: p1.x - cos(angle) * 8.0, y: p1.y - sin(angle) * 8.0)
        var chev = Path()
        chev.move(to: CGPoint(x: tip.x - cos(angle - 0.55) * 3.8, y: tip.y - sin(angle - 0.55) * 3.8))
        chev.addLine(to: tip)
        chev.addLine(to: CGPoint(x: tip.x - cos(angle + 0.55) * 3.8, y: tip.y - sin(angle + 0.55) * 3.8))
        context.stroke(chev, with: .color(color), lineWidth: 0.85)
    }

    private func linkStyle(for state: ReplayTrackLiveState, activeDefault: Color) -> (Color, CGFloat) {
        switch state {
        case .retrying:
            return (theme.signalRed.opacity(0.88), 1.2)
        case .working:
            return (activeDefault.opacity(0.80), 1.05)
        case .waiting:
            return (theme.signalAmber.opacity(0.68), 0.95)
        case .verify:
            return (replayVerifyColor(theme).opacity(0.78), 1.0)
        case .done:
            return (replayVerifyColor(theme).opacity(theme.isDark ? 0.36 : 0.32), 0.75)
        case .idle:
            return (theme.hairlineStrong.opacity(theme.isDark ? 0.34 : 0.28), 0.7)
        }
    }

    // MARK: Node Beacon Drawing

    private func drawRootNode(
        in context: inout GraphicsContext,
        at pt: CGPoint,
        state: ReplayTrackLiveState,
        isHovered: Bool,
        isFaultTarget: Bool
    ) {
        let tint: Color = {
            switch state {
            case .retrying: return theme.signalRed
            case .waiting:  return theme.signalAmber
            case .verify:   return replayVerifyColor(theme)
            case .done:     return theme.signalGreen
            case .working, .idle: return theme.accent
            }
        }()

        // Halo luminescence
        context.fill(
            Path(ellipseIn: CGRect(x: pt.x - 13, y: pt.y - 13, width: 26, height: 26)),
            with: .color(tint.opacity(theme.isDark ? 0.16 : 0.08))
        )

        if isFaultTarget {
            drawReplayCornerReticle(in: &context, center: pt, radius: 12.0, len: 4.0, color: theme.signalRed.opacity(0.38), lineWidth: 0.8)
            drawReplayCornerReticle(in: &context, center: pt, radius: 8.5, len: 3.2, color: theme.signalRed, lineWidth: 1.0)
        } else if isHovered {
            drawReplayCornerReticle(in: &context, center: pt, radius: 10.0, len: 3.4, color: tint, lineWidth: 0.9)
        }

        // Crisp Swiss diamond hub (`COORD`)
        let r: CGFloat = 6.2
        var outer = Path()
        outer.move(to: CGPoint(x: pt.x, y: pt.y - r))
        outer.addLine(to: CGPoint(x: pt.x + r, y: pt.y))
        outer.addLine(to: CGPoint(x: pt.x, y: pt.y + r))
        outer.addLine(to: CGPoint(x: pt.x - r, y: pt.y))
        outer.closeSubpath()
        context.fill(outer, with: .color(theme.isDark ? theme.canvas : theme.surfaceRaised))
        context.stroke(outer, with: .color(theme.inkPrimary), lineWidth: 1.1)

        let ir: CGFloat = 2.8
        var inner = Path()
        inner.move(to: CGPoint(x: pt.x, y: pt.y - ir))
        inner.addLine(to: CGPoint(x: pt.x + ir, y: pt.y))
        inner.addLine(to: CGPoint(x: pt.x, y: pt.y + ir))
        inner.addLine(to: CGPoint(x: pt.x - ir, y: pt.y))
        inner.closeSubpath()
        context.fill(inner, with: .color(tint))
    }

    private func drawWorkerNode(
        in context: inout GraphicsContext,
        at pt: CGPoint,
        state: ReplayTrackLiveState,
        isHovered: Bool,
        isFaultTarget: Bool
    ) {
        switch state {
        case .retrying:
            let red = theme.signalRed
            context.fill(
                Path(ellipseIn: CGRect(x: pt.x - 16, y: pt.y - 16, width: 32, height: 32)),
                with: .color(red.opacity(theme.isDark ? 0.16 : 0.09))
            )
            context.fill(
                Path(ellipseIn: CGRect(x: pt.x - 9.5, y: pt.y - 9.5, width: 19, height: 19)),
                with: .color(red.opacity(theme.isDark ? 0.26 : 0.16))
            )
            // Hairline crosshairs + dual nested crimson target-lock brackets
            var cross = Path()
            cross.move(to: CGPoint(x: pt.x - 15, y: pt.y)); cross.addLine(to: CGPoint(x: pt.x - 5.5, y: pt.y))
            cross.move(to: CGPoint(x: pt.x + 5.5, y: pt.y)); cross.addLine(to: CGPoint(x: pt.x + 15, y: pt.y))
            cross.move(to: CGPoint(x: pt.x, y: pt.y - 15)); cross.addLine(to: CGPoint(x: pt.x, y: pt.y - 5.5))
            cross.move(to: CGPoint(x: pt.x, y: pt.y + 5.5)); cross.addLine(to: CGPoint(x: pt.x, y: pt.y + 15))
            context.stroke(cross, with: .color(red.opacity(0.45)), lineWidth: 0.65)

            drawReplayCornerReticle(in: &context, center: pt, radius: 12.0, len: 4.0, color: red.opacity(isFaultTarget ? 0.44 : 0.30), lineWidth: 0.8)
            drawReplayCornerReticle(in: &context, center: pt, radius: 7.5, len: 3.2, color: red, lineWidth: 1.05)

            let dr: CGFloat = 3.6
            var dia = Path()
            dia.move(to: CGPoint(x: pt.x, y: pt.y - dr))
            dia.addLine(to: CGPoint(x: pt.x + dr, y: pt.y))
            dia.addLine(to: CGPoint(x: pt.x, y: pt.y + dr))
            dia.addLine(to: CGPoint(x: pt.x - dr, y: pt.y))
            dia.closeSubpath()
            context.fill(dia, with: .color(red))

        case .working:
            let c = theme.accent
            context.fill(
                Path(ellipseIn: CGRect(x: pt.x - 10, y: pt.y - 10, width: 20, height: 20)),
                with: .color(c.opacity(theme.isDark ? 0.22 : 0.12))
            )
            drawReplayCornerReticle(in: &context, center: pt, radius: isHovered ? 9.0 : 7.0, len: 2.8, color: c.opacity(isHovered ? 0.95 : 0.65), lineWidth: 0.85)
            context.fill(
                Path(ellipseIn: CGRect(x: pt.x - 3.0, y: pt.y - 3.0, width: 6.0, height: 6.0)),
                with: .color(c)
            )

        case .waiting:
            let amb = theme.signalAmber
            context.fill(
                Path(ellipseIn: CGRect(x: pt.x - 10, y: pt.y - 10, width: 20, height: 20)),
                with: .color(amb.opacity(theme.isDark ? 0.20 : 0.12))
            )
            drawReplayCornerReticle(in: &context, center: pt, radius: isHovered ? 9.0 : 7.0, len: 2.8, color: amb.opacity(0.85), lineWidth: 0.85)
            let dr: CGFloat = 3.2
            var dia = Path()
            dia.move(to: CGPoint(x: pt.x, y: pt.y - dr))
            dia.addLine(to: CGPoint(x: pt.x + dr, y: pt.y))
            dia.addLine(to: CGPoint(x: pt.x, y: pt.y + dr))
            dia.addLine(to: CGPoint(x: pt.x - dr, y: pt.y))
            dia.closeSubpath()
            context.fill(dia, with: .color(amb))

        case .verify:
            let v = replayVerifyColor(theme)
            context.fill(
                Path(ellipseIn: CGRect(x: pt.x - 8, y: pt.y - 8, width: 16, height: 16)),
                with: .color(v.opacity(theme.isDark ? 0.22 : 0.13))
            )
            drawReplayCornerReticle(in: &context, center: pt, radius: isHovered ? 8.5 : 6.5, len: 2.6, color: v.opacity(0.75), lineWidth: 0.8)
            context.fill(
                Path(ellipseIn: CGRect(x: pt.x - 2.6, y: pt.y - 2.6, width: 5.2, height: 5.2)),
                with: .color(v)
            )

        case .done:
            let g = theme.signalGreen
            if isHovered {
                drawReplayCornerReticle(in: &context, center: pt, radius: 8.0, len: 2.6, color: g, lineWidth: 0.85)
            }
            context.stroke(
                Path(ellipseIn: CGRect(x: pt.x - 4.8, y: pt.y - 4.8, width: 9.6, height: 9.6)),
                with: .color(g.opacity(0.65)),
                lineWidth: 0.8
            )
            context.fill(
                Path(ellipseIn: CGRect(x: pt.x - 2.2, y: pt.y - 2.2, width: 4.4, height: 4.4)),
                with: .color(g)
            )

        case .idle:
            let m = theme.inkMuted.opacity(theme.isDark ? 0.70 : 0.62)
            if isHovered {
                drawReplayCornerReticle(in: &context, center: pt, radius: 7.5, len: 2.5, color: theme.inkSecondary, lineWidth: 0.8)
            }
            var cross = Path()
            cross.move(to: CGPoint(x: pt.x - 3.0, y: pt.y)); cross.addLine(to: CGPoint(x: pt.x + 3.0, y: pt.y))
            cross.move(to: CGPoint(x: pt.x, y: pt.y - 3.0)); cross.addLine(to: CGPoint(x: pt.x, y: pt.y + 3.0))
            context.stroke(cross, with: .color(m), lineWidth: 0.85)
            context.stroke(
                Path(ellipseIn: CGRect(x: pt.x - 2.1, y: pt.y - 2.1, width: 4.2, height: 4.2)),
                with: .color(m),
                lineWidth: 0.65
            )
        }
    }

    private func labelSaliencePriority(_ node: ReplayRadarNode, state: ReplayTrackLiveState) -> Int {
        switch state {
        case .retrying: return 0
        case .waiting:  return 1
        case .working:  return 2
        case .verify:   return 3
        case .done:     return 4
        case .idle:     return 5
        }
    }

    private func localizedLiveStateTag(_ state: ReplayTrackLiveState, loc: Localizer) -> String {
        switch state {
        case .working:  return loc("replayStatusActive")
        case .waiting:  return loc("replayStatusWait")
        case .retrying: return loc("replayLegendRetry")
        case .verify:   return loc("replayStatusVerify")
        case .done:     return loc("replayStatusDone")
        case .idle:     return loc("replayStatusIdle")
        }
    }
}

// MARK: - Middle Precision Time Scrubber Rail

private struct ReplayScrubberRailView: View {
    let timeline: ReplayTimeline
    let progress: Double
    let currentSec: Double
    let isPlaying: Bool
    let isSkippingIdle: Bool
    let speed: ReplaySpeed
    let onScrub: (Double) -> Void
    let onTogglePlay: () -> Void
    let onPrevEvent: () -> Void
    let onNextEvent: () -> Void
    let onCycleSpeed: () -> Void

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @Environment(\.craftHapticsEnabled) private var hapticsEnabled

    @State private var lastScrubBucket: Int = -1
    @State private var wasInsideAnomaly: Bool = false

    private var waitSpans: [ReplaySegment] {
        timeline.tracks.flatMap(\.segments).filter { $0.kind == .humanWait }
    }

    private var retrySpans: [ReplaySegment] {
        timeline.tracks.flatMap(\.segments).filter { $0.kind == .retryLoop }
    }

    private var speedHelpText: String {
        guard timeline.totalDurationSec > 0 else {
            return loc("replaySpeedHelp")
        }
        let mult = ReplayLogic.effectiveRealTimeMultiplier(
            timelineDurationSec: timeline.totalDurationSec,
            speed: speed
        )
        let baseDur = ReplayLogic.effectivePlaybackDurationSec(
            timelineDurationSec: timeline.totalDurationSec
        )
        let wallSec = max(1.0, baseDur / max(0.1, speed.rawValue))
        let speedDisplay = speed.label.replacingOccurrences(of: "x", with: "×")
        return String(
            format: loc("replaySpeedTooltipFmt"),
            speedDisplay,
            formatSpeedMultiplier(mult),
            formatReplayDuration(wallSec)
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // Compact 4-Button Transport Controls (zero SwiftUI Buttons — ImageRenderer-safe Swiss boxes)
            HStack(spacing: 3) {
                ReplayTransportBox(
                    token: "replay-ctrl-prev",
                    width: 22,
                    isActive: false,
                    helpText: loc("replayPrevEventHelp"),
                    onTap: onPrevEvent
                ) {
                    HStack(spacing: 0.5) {
                        Rectangle()
                            .fill(theme.inkPrimary)
                            .frame(width: 1.2, height: 6.5)
                        Text("◀")
                            .font(.system(size: 6.8, weight: .semibold, design: .monospaced))
                            .foregroundColor(theme.inkPrimary)
                    }
                }

                ReplayTransportBox(
                    token: "replay-ctrl-play",
                    width: 24,
                    isActive: isPlaying,
                    helpText: loc("replayPlayPauseHelp"),
                    onTap: onTogglePlay
                ) {
                    Text(isPlaying ? "❚❚" : "▶")
                        .font(.system(size: isPlaying ? 7.5 : 8.5, weight: .bold, design: .monospaced))
                        .foregroundColor(isPlaying ? theme.accent : theme.inkPrimary)
                }

                ReplayTransportBox(
                    token: "replay-ctrl-next",
                    width: 22,
                    isActive: false,
                    helpText: loc("replayNextEventHelp"),
                    onTap: onNextEvent
                ) {
                    HStack(spacing: 0.5) {
                        Text("▶")
                            .font(.system(size: 6.8, weight: .semibold, design: .monospaced))
                            .foregroundColor(theme.inkPrimary)
                        Rectangle()
                            .fill(theme.inkPrimary)
                            .frame(width: 1.2, height: 6.5)
                    }
                }

                ReplayTransportBox(
                    token: "replay-ctrl-speed",
                    width: 32,
                    isActive: false,
                    helpText: speedHelpText,
                    onTap: onCycleSpeed
                ) {
                    Text(speed.label.replacingOccurrences(of: "x", with: "×"))
                        .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(theme.inkPrimary)
                }
            }
            .fixedSize()

            // Interactive Anomaly-Mapped Scrubber Rail + Tabular Clock Readout
            VStack(spacing: 2) {
                GeometryReader { geo in
                    let w = geo.size.width
                    let h = geo.size.height

                    ZStack {
                        scrubberCanvas(width: w, height: h)
                            .allowsHitTesting(false)

                        Color.clear
                            .contentShape(Rectangle())
                            .onHover { inside in
                                PointingCursorCoordinator.shared.setPointing(inside, token: "replay-scrubber")
                            }
                            .onDisappear {
                                PointingCursorCoordinator.shared.setPointing(false, token: "replay-scrubber")
                            }
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        guard w > 1 else { return }
                                        let rawP = Double(value.location.x / w)
                                        let clampedP = min(1.0, max(0.0, rawP))
                                        onScrub(clampedP)
                                        emitScrubHaptics(for: clampedP)
                                    }
                                    .onEnded { _ in
                                        lastScrubBucket = -1
                                    }
                            )
                    }
                }
                .frame(height: 30)

                // Clock Readout Row (+ Subtle Smart-Skip Micro-Tag during active dead-air acceleration)
                HStack(spacing: 4) {
                    Text("00:00")
                        .font(.system(size: 7.5, weight: .regular, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(theme.inkMuted)

                    Spacer(minLength: 4)

                    HStack(spacing: 4) {
                        Text("▲ \(ReplayLogic.formatClock(currentSec)) / \(ReplayLogic.formatClock(timeline.totalDurationSec))")
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(theme.accent)
                            .lineLimit(1)

                        if isPlaying && isSkippingIdle {
                            Text(loc("replaySmartSkipPill"))
                                .font(.system(size: 6.4, weight: .bold, design: .monospaced))
                                .monospacedDigit()
                                .tracking(0.3)
                                .foregroundColor(theme.signalAmber)
                                .padding(.horizontal, 3.5)
                                .padding(.vertical, 0.75)
                                .background(theme.signalAmber.opacity(theme.isDark ? 0.16 : 0.11))
                                .overlay(Rectangle().stroke(theme.signalAmber.opacity(0.55), lineWidth: 0.6))
                                .fixedSize()
                        }
                    }

                    Spacer(minLength: 4)

                    Text(ReplayLogic.formatClock(timeline.totalDurationSec))
                        .font(.system(size: 7.5, weight: .regular, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(theme.inkMuted)
                }
                .frame(height: 11)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func scrubberCanvas(width: CGFloat, height: CGFloat) -> some View {
        Canvas { context, size in
            let cw = size.width
            let ch = size.height
            guard cw > 10, ch > 10 else { return }

            let totalDur = max(1.0, timeline.totalDurationSec)
            // Vertical layout bands (30pt total):
            //   0..9   : anomaly micro-labels (`WAIT 4.5m`, `RETRY ×7`)
            //   10..15 : anomaly diamond pips above rail
            //   19..23 : scrubber rail (`railY = 21`)
            //   24..29 : cobalt upward playhead pointer (`▲`) + quarter ticks (zero overlap with top anomalies)
            let railY: CGFloat = ch - 9.0
            let railH: CGFloat = 4.0

            // 1. Base hairline rail track
            let trackRect = CGRect(x: 0, y: railY - railH * 0.5, width: cw, height: railH)
            context.fill(Path(trackRect), with: .color(theme.hairline.opacity(theme.isDark ? 0.90 : 0.78)))

            // Subtle quarter ticks beneath rail
            var ticks = Path()
            for frac in [0.0, 0.25, 0.5, 0.75, 1.0] as [CGFloat] {
                let tx = min(cw - 0.5, max(0.5, frac * cw))
                ticks.move(to: CGPoint(x: tx, y: railY + railH * 0.5 + 1.0))
                ticks.addLine(to: CGPoint(x: tx, y: railY + railH * 0.5 + 3.0))
            }
            context.stroke(ticks, with: .color(theme.hairlineStrong.opacity(0.65)), lineWidth: 0.7)

            // 2. Overlaid Amber WAIT spans
            var largestWait: ReplaySegment? = nil
            for seg in waitSpans {
                let x0 = CGFloat(seg.startSec / totalDur) * cw
                let x1 = CGFloat(seg.endSec / totalDur) * cw
                let spanW = max(2.5, x1 - x0)
                let rect = CGRect(x: x0, y: railY - railH * 0.5, width: min(spanW, cw - x0), height: railH)
                context.fill(Path(rect), with: .color(theme.signalAmber.opacity(theme.isDark ? 0.60 : 0.55)))
                if seg.durationSec > (largestWait?.durationSec ?? -1) {
                    largestWait = seg
                }
            }

            // 3. Overlaid Crimson RETRY spans
            var largestRetry: ReplaySegment? = nil
            for seg in retrySpans {
                let x0 = CGFloat(seg.startSec / totalDur) * cw
                let x1 = CGFloat(seg.endSec / totalDur) * cw
                let spanW = max(3.0, x1 - x0)
                let rect = CGRect(x: x0, y: railY - railH * 0.5, width: min(spanW, cw - x0), height: railH)
                context.fill(Path(rect), with: .color(theme.signalRed.opacity(theme.isDark ? 0.72 : 0.62)))
                if seg.estimatedCostUSD > (largestRetry?.estimatedCostUSD ?? -1)
                    || (largestRetry == nil) {
                    largestRetry = seg
                }
            }

            // 4. Anomaly callout diamonds + micro tags cleanly in upper bands (zero overlap with playhead)
            let pipY: CGFloat = railY - 8.0
            let labelY: CGFloat = 4.2
            var waitLabelRect: CGRect? = nil
            if let lw = largestWait {
                let midX = CGFloat(((lw.startSec + lw.endSec) * 0.5) / totalDur) * cw
                let pip = CGPoint(x: min(max(4, midX), cw - 4), y: pipY)
                drawSmallDiamond(in: &context, at: pip, r: 2.2, color: theme.signalAmber)

                let tag = "\(loc("replayLegendWait")) \(formatWaitKPI(timeline.humanWaitSec))"
                let estW = CGFloat(tag.count) * 4.2 + 4
                let tx = min(max(estW * 0.5 + 2, pip.x), cw - estW * 0.5 - 2)
                waitLabelRect = CGRect(x: tx - estW * 0.5, y: 0, width: estW, height: 9)
                context.draw(
                    Text(tag)
                        .font(.system(size: 6.5, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(theme.signalAmber),
                    at: CGPoint(x: tx, y: labelY)
                )
            }

            if let lr = largestRetry {
                let midX = CGFloat(((lr.startSec + lr.endSec) * 0.5) / totalDur) * cw
                let pip = CGPoint(x: min(max(4, midX), cw - 4), y: pipY)
                drawSmallDiamond(in: &context, at: pip, r: 2.2, color: theme.signalRed)

                let loops = max(1, timeline.totalRetryLoops)
                let tag = "\(loc("replayLegendRetry")) ×\(loops)"
                let estW = CGFloat(tag.count) * 4.4 + 4
                let tx = min(max(estW * 0.5 + 2, pip.x), cw - estW * 0.5 - 2)
                let candidateRect = CGRect(x: tx - estW * 0.5, y: 0, width: estW, height: 9)
                let overlapsWait = waitLabelRect.map { $0.intersects(candidateRect.insetBy(dx: -3, dy: 0)) } ?? false
                if !overlapsWait {
                    context.draw(
                        Text(tag)
                            .font(.system(size: 6.5, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(theme.signalRed),
                        at: CGPoint(x: tx, y: labelY)
                    )
                }
            }

            // 5. Cobalt Played Fill
            let playX = min(max(0, CGFloat(progress) * cw), cw)
            if playX > 0.5 {
                context.fill(
                    Path(CGRect(x: 0, y: railY - 1.25, width: playX, height: 2.5)),
                    with: .color(theme.accent)
                )
            }

            // 6. Vertical Cobalt Playhead Stem + Upward Index Finial below rail (clears anomaly tags & diamonds)
            let clampedX = min(max(3.5, playX), cw - 3.5)
            var stem = Path()
            stem.move(to: CGPoint(x: clampedX, y: railY - 4.2))
            stem.addLine(to: CGPoint(x: clampedX, y: railY + 4.0))
            context.stroke(stem, with: .color(theme.accent), lineWidth: 1.5)

            var finial = Path()
            finial.move(to: CGPoint(x: clampedX, y: railY + 3.2))
            finial.addLine(to: CGPoint(x: clampedX - 3.3, y: railY + 7.6))
            finial.addLine(to: CGPoint(x: clampedX + 3.3, y: railY + 7.6))
            finial.closeSubpath()
            context.fill(finial, with: .color(theme.accent))
        }
    }

    private func emitScrubHaptics(for newProgress: Double) {
        let bucket = Int((newProgress * 20.0).rounded(.down))
        let sec = newProgress * max(0.0, timeline.totalDurationSec)
        let inAnomaly = retrySpans.contains { sec >= $0.startSec && sec <= $0.endSec }
            || waitSpans.contains { sec >= $0.startSec && sec <= $0.endSec }

        if inAnomaly && !wasInsideAnomaly {
            wasInsideAnomaly = true
            lastScrubBucket = bucket
            CraftEngine.shared.perform(.chronometerPin, enabled: hapticsEnabled)
        } else {
            wasInsideAnomaly = inAnomaly
            if bucket != lastScrubBucket {
                lastScrubBucket = bucket
                CraftEngine.shared.perform(.chronometerCrown, enabled: hapticsEnabled)
            }
        }
    }
}

// MARK: - 04.2 Waterfall & Waste Forensics

private struct ReplayWaterfallDeckView: View {
    let timeline: ReplayTimeline
    let progress: Double
    let snapshot: ReplayPlayheadSnapshot
    let isStaticRender: Bool
    let onSeekProgress: (Double) -> Void
    let onSelectTrack: (String) -> Void

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme

    private let labelColWidth: CGFloat = 76
    private let costColWidth: CGFloat = 42

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow

            if timeline.tracks.count > 5 && !isStaticRender {
                ScrollView(.vertical, showsIndicators: true) {
                    trackRowsStack
                }
                .frame(maxHeight: 116)
            } else {
                trackRowsStack
            }

            timeAxisRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var headerRow: some View {
        HStack(spacing: 5) {
            Text("04.2")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.accent.opacity(0.92))
                .fixedSize()

            Text(loc("replayWaterfallTitle"))
                .font(.system(size: 8, weight: .regular, design: .monospaced))
                .tracking(0.8)
                .foregroundColor(theme.inkSecondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                legendChip(label: loc("replayLegendWork"), color: theme.accent, pattern: .solid)
                legendChip(label: loc("replayLegendWait"), color: theme.signalAmber, pattern: .diagonalHatch)
                legendChip(label: loc("replayLegendRetry"), color: theme.signalRed, pattern: .diagonalHatch)
                legendChip(label: loc("replayLegendVerify"), color: replayVerifyColor(theme), pattern: .solid)
            }
            .fixedSize()
        }
    }

    private func legendChip(label: String, color: Color, pattern: StrataPattern) -> some View {
        HStack(spacing: 3) {
            StrataSwatch(color: color, pattern: pattern, size: 6.5)
                .overlay(Rectangle().stroke(color.opacity(pattern == .diagonalHatch ? 0.8 : 0.0), lineWidth: 0.5))
            Text(label)
                .font(.system(size: 6.8, weight: .regular, design: .monospaced))
                .tracking(0.35)
                .foregroundColor(theme.inkMuted)
        }
    }

    private var trackRowsStack: some View {
        VStack(spacing: 4) {
            ForEach(Array(timeline.tracks.enumerated()), id: \.element.id) { idx, track in
                ReplayWaterfallTrackRow(
                    track: track,
                    isFirstRow: idx == 0,
                    totalDurationSec: max(1.0, timeline.totalDurationSec),
                    progress: progress,
                    liveState: snapshot.trackStates[track.id] ?? .idle,
                    labelColWidth: labelColWidth,
                    costColWidth: costColWidth,
                    onSeekProgress: onSeekProgress,
                    onSelectTrack: { onSelectTrack(track.id) }
                )
            }
        }
    }

    private var timeAxisRow: some View {
        let total = max(0.0, timeline.totalDurationSec)
        return HStack(spacing: 6) {
            Spacer().frame(width: labelColWidth)

            HStack(spacing: 0) {
                Text("00:00")
                    .font(.system(size: 7, weight: .regular, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(theme.inkMuted)
                Spacer(minLength: 2)
                Text(ReplayLogic.formatClock(total * 0.25))
                    .font(.system(size: 7, weight: .regular, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(theme.inkMuted)
                Spacer(minLength: 2)
                Text(ReplayLogic.formatClock(total * 0.50))
                    .font(.system(size: 7, weight: .regular, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(theme.inkMuted)
                Spacer(minLength: 2)
                Text(ReplayLogic.formatClock(total * 0.75))
                    .font(.system(size: 7, weight: .regular, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(theme.inkMuted)
                Spacer(minLength: 2)
                Text(ReplayLogic.formatClock(total))
                    .font(.system(size: 7, weight: .regular, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(theme.inkMuted)
            }

            Spacer().frame(width: costColWidth)
        }
    }
}

private struct ReplayWaterfallTrackRow: View {
    let track: ReplayTrack
    let isFirstRow: Bool
    let totalDurationSec: Double
    let progress: Double
    let liveState: ReplayTrackLiveState
    let labelColWidth: CGFloat
    let costColWidth: CGFloat
    let onSeekProgress: (Double) -> Void
    let onSelectTrack: () -> Void

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme
    @State private var hovering = false

    private var hasRetryWaste: Bool { track.retryWasteUSD > 0.0001 || track.retryCount > 0 }

    private var dotColor: Color {
        if liveState == .retrying || hasRetryWaste { return theme.signalRed }
        switch liveState {
        case .retrying: return theme.signalRed
        case .waiting:  return theme.signalAmber
        case .working:  return theme.accent
        case .verify:   return replayVerifyColor(theme)
        case .done:
            if track.segments.contains(where: { $0.kind == .humanWait }) { return theme.signalAmber }
            if track.segments.contains(where: { $0.kind == .verify }) { return replayVerifyColor(theme) }
            return theme.accent
        case .idle:
            return theme.inkMuted.opacity(0.65)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            // Track Name + Status Dot (clicking jumps to track's anomaly / start)
            HStack(spacing: 5) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 4.5, height: 4.5)

                Text(track.name)
                    .font(.system(size: 8.5, weight: (liveState == .retrying || hovering) ? .semibold : .regular, design: .monospaced))
                    .foregroundColor(liveState == .retrying ? theme.inkPrimary : theme.inkPrimary.opacity(0.90))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: labelColWidth, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onSelectTrack() }

            // Interactive Gantt Bar Canvas
            GeometryReader { geo in
                let w = geo.size.width

                Canvas { context, size in
                    let cw = size.width
                    let ch = size.height
                    guard cw > 4, ch > 4 else { return }

                    let barInsetY: CGFloat = 1.5
                    let barH = max(4.0, ch - barInsetY * 2.0)

                    // Recessed lane trough
                    context.fill(
                        Path(CGRect(x: 0, y: barInsetY, width: cw, height: barH)),
                        with: .color(theme.surface.opacity(theme.isDark ? 0.60 : 0.80))
                    )

                    // Draw each segment
                    for seg in track.segments {
                        let x0 = CGFloat(seg.startSec / totalDurationSec) * cw
                        let x1 = CGFloat(seg.endSec / totalDurationSec) * cw
                        let segW = max(2.2, min(cw - x0, x1 - x0))
                        let rect = CGRect(x: x0, y: barInsetY, width: segW, height: barH)
                        var ctx = context

                        switch seg.kind {
                        case .work:
                            context.fill(Path(rect), with: .color(theme.accent.opacity(theme.isDark ? 0.88 : 0.90)))

                        case .humanWait:
                            drawStrataRect(in: &ctx, rect: rect, color: theme.signalAmber, pattern: .diagonalHatch)
                            context.stroke(Path(rect.insetBy(dx: 0.4, dy: 0.4)), with: .color(theme.signalAmber.opacity(0.85)), lineWidth: 0.8)
                            if segW >= 54 {
                                drawBarPill(in: &context, rect: rect, text: loc("replayHumanWaitBar"), tint: theme.signalAmber)
                            }

                        case .retryLoop:
                            drawStrataRect(in: &ctx, rect: rect, color: theme.signalRed, pattern: .diagonalHatch)
                            context.stroke(Path(rect.insetBy(dx: 0.4, dy: 0.4)), with: .color(theme.signalRed.opacity(0.92)), lineWidth: 0.85)
                            if segW >= 44 {
                                let label = seg.errorCount > 0
                                    ? "\(loc("replayLegendRetry")) ×\(seg.errorCount)"
                                    : loc("replayLegendRetry")
                                drawBarPill(in: &context, rect: rect, text: label, tint: theme.signalRed)
                            }

                        case .verify:
                            context.fill(Path(rect), with: .color(replayVerifyColor(theme).opacity(theme.isDark ? 0.78 : 0.84)))
                            if segW >= 42 {
                                let vText = Text(loc("replayVerifyBar"))
                                    .font(.system(size: 6.2, weight: .semibold, design: .monospaced))
                                    .tracking(0.4)
                                    .foregroundColor(theme.isDark ? theme.canvas : Color.white)
                                context.draw(vText, at: CGPoint(x: rect.midX, y: rect.midY))
                            }
                        }
                    }

                    // Slicing Vertical Cobalt Playhead Line across every track
                    let px = min(max(1.0, CGFloat(progress) * cw), cw - 1.0)
                    var needle = Path()
                    needle.move(to: CGPoint(x: px, y: 0))
                    needle.addLine(to: CGPoint(x: px, y: ch))
                    context.stroke(needle, with: .color(theme.accent), lineWidth: 1.25)

                    if isFirstRow {
                        var tri = Path()
                        tri.move(to: CGPoint(x: px - 2.6, y: 0))
                        tri.addLine(to: CGPoint(x: px + 2.6, y: 0))
                        tri.addLine(to: CGPoint(x: px, y: 3.0))
                        tri.closeSubpath()
                        context.fill(tri, with: .color(theme.accent))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { pt in
                    guard w > 1 else { return }
                    let p = min(1.0, max(0.0, Double(pt.x / w)))
                    onSeekProgress(p)
                }
            }
            .frame(height: 17)

            // Right-Aligned Tabular Track Cost (Crimson when track has retry waste)
            Text(formatCostTabular(track.estimatedCostUSD))
                .font(.system(size: 8.5, weight: hasRetryWaste ? .semibold : .regular, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(hasRetryWaste ? theme.signalRed : theme.inkPrimary.opacity(0.88))
                .frame(width: costColWidth, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture { onSelectTrack() }
        }
        .padding(.vertical, 1)
        .background(hovering ? theme.surfaceRaised.opacity(theme.isDark ? 0.25 : 0.45) : Color.clear)
        .onHover { inside in
            hovering = inside
            PointingCursorCoordinator.shared.setPointing(inside, token: "replay-track-\(track.id)")
        }
        .onDisappear {
            hovering = false
            PointingCursorCoordinator.shared.setPointing(false, token: "replay-track-\(track.id)")
        }
    }

    private func drawBarPill(
        in context: inout GraphicsContext,
        rect: CGRect,
        text: String,
        tint: Color
    ) {
        let pillW = min(rect.width - 6, CGFloat(text.count) * 4.3 + 8)
        let pillH = min(rect.height - 3, 9.5)
        guard pillW >= 24, pillH >= 7 else { return }
        let pillRect = CGRect(
            x: rect.midX - pillW * 0.5,
            y: rect.midY - pillH * 0.5,
            width: pillW,
            height: pillH
        )
        context.fill(Path(pillRect), with: .color(theme.isDark ? theme.canvas.opacity(0.92) : theme.surfaceRaised.opacity(0.95)))
        let label = Text(text)
            .font(.system(size: 6.0, weight: .bold, design: .monospaced))
            .tracking(0.3)
            .foregroundColor(tint)
        context.draw(label, at: CGPoint(x: pillRect.midX, y: pillRect.midY))
    }
}

// MARK: - Bottom 3-Box Forensics KPI Strip

private struct ReplayForensicsKPIStrip: View {
    let timeline: ReplayTimeline

    @Environment(\.localizer) private var loc
    @Environment(\.agyTheme) private var theme

    var body: some View {
        let hasWaste = timeline.retryWasteUSD > 0.0001
        let hasWait = timeline.humanWaitSec > 0.5

        HStack(spacing: 0) {
            kpiBox(
                title: loc("replayKpiTotalSpend"),
                value: formatCostTabular(timeline.totalCostUSD),
                subline: "\(formatTokensShort(timeline.totalTokens).uppercased()) TOK",
                topRuleColor: nil,
                tintBg: nil,
                titleColor: theme.inkSecondary,
                valueColor: theme.inkPrimary,
                sublineColor: theme.inkMuted
            )

            Rectangle()
                .fill(theme.hairline)
                .frame(width: 1)

            kpiBox(
                title: loc("replayKpiRetryWaste"),
                value: formatCostTabular(timeline.retryWasteUSD),
                subline: hasWaste
                    ? String(format: loc("replayOfTotalFmt"), timeline.retryWastePercent)
                    : loc("replayCleanRun"),
                topRuleColor: hasWaste ? theme.signalRed : nil,
                tintBg: hasWaste ? theme.signalRed.opacity(theme.isDark ? 0.08 : 0.055) : nil,
                titleColor: hasWaste ? theme.signalRed : theme.inkSecondary,
                valueColor: hasWaste ? theme.signalRed : theme.inkPrimary,
                sublineColor: hasWaste ? theme.signalRed.opacity(0.88) : theme.signalGreen
            )

            Rectangle()
                .fill(theme.hairline)
                .frame(width: 1)

            kpiBox(
                title: loc("replayKpiHumanWait"),
                value: formatWaitKPI(timeline.humanWaitSec),
                subline: hasWait
                    ? String(format: loc("replayOfWallFmt"), timeline.humanWaitPercent)
                    : loc("replayNoWait"),
                topRuleColor: hasWait ? theme.signalAmber : nil,
                tintBg: hasWait ? theme.signalAmber.opacity(theme.isDark ? 0.08 : 0.055) : nil,
                titleColor: hasWait ? theme.signalAmber : theme.inkSecondary,
                valueColor: hasWait ? theme.signalAmber : theme.inkPrimary,
                sublineColor: hasWait ? theme.signalAmber.opacity(0.88) : theme.inkMuted
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func kpiBox(
        title: String,
        value: String,
        subline: String,
        topRuleColor: Color?,
        tintBg: Color?,
        titleColor: Color,
        valueColor: Color,
        sublineColor: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 7.2, weight: .medium, design: .monospaced))
                .tracking(0.75)
                .foregroundColor(titleColor)
                .lineLimit(1)

            Text(value)
                .font(.system(size: 16.5, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            Text(subline)
                .font(.system(size: 7.2, weight: .regular, design: .monospaced))
                .monospacedDigit()
                .tracking(0.35)
                .foregroundColor(sublineColor)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(tintBg ?? Color.clear)
        .overlay(alignment: .top) {
            if let ruleColor = topRuleColor {
                Rectangle()
                    .fill(ruleColor)
                    .frame(height: 1.5)
            }
        }
    }
}

// MARK: - Sharp Swiss Badges & Controls (Zero SwiftUI Buttons)

private struct ReplayTopologyBadge: View {
    let topology: SessionTopologyKind
    let theme: AGYTheme

    private var badgeColor: Color {
        switch topology {
        case .swarm:
            return theme.accent
        case .dynamicWorkflow:
            return theme.isDark
                ? Color(red: 0.46, green: 0.66, blue: 0.90)
                : Color(red: 0.24, green: 0.42, blue: 0.66)
        case .subagentTree:
            return replayVerifyColor(theme)
        case .battle:
            return theme.signalAmber
        case .solo:
            return theme.inkSecondary
        }
    }

    var body: some View {
        HStack(spacing: 3.5) {
            Rectangle()
                .fill(badgeColor)
                .frame(width: 4, height: 4)
            Text(topology.badgeCode)
                .font(.system(size: 7.0, weight: .semibold, design: .monospaced))
                .tracking(0.55)
                .foregroundColor(badgeColor)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(badgeColor.opacity(theme.isDark ? 0.14 : 0.09))
        .overlay(Rectangle().stroke(badgeColor.opacity(0.52), lineWidth: 0.7))
    }
}

private struct ReplayStepperBox: View {
    let glyph: String
    let enabled: Bool
    let token: String
    let helpText: String
    let onTap: () -> Void

    @Environment(\.agyTheme) private var theme
    @State private var hovering = false

    var body: some View {
        Text(glyph)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(enabled ? (hovering ? theme.accent : theme.inkPrimary) : theme.inkMuted.opacity(0.35))
            .frame(width: 19, height: 18)
            .background(
                enabled && hovering
                    ? theme.accent.opacity(theme.isDark ? 0.14 : 0.08)
                    : theme.surfaceRaised.opacity(theme.isDark ? 0.55 : 0.85)
            )
            .overlay(Rectangle().stroke(enabled && hovering ? theme.accent.opacity(0.7) : theme.hairlineStrong.opacity(enabled ? 0.8 : 0.35), lineWidth: 0.75))
            .contentShape(Rectangle())
            .help(helpText)
            .onHover { inside in
                hovering = inside && enabled
                PointingCursorCoordinator.shared.setPointing(inside && enabled, token: token)
            }
            .onDisappear {
                hovering = false
                PointingCursorCoordinator.shared.setPointing(false, token: token)
            }
            .onTapGesture {
                if enabled { onTap() }
            }
    }
}

private struct ReplayTransportBox<Content: View>: View {
    let token: String
    let width: CGFloat
    let isActive: Bool
    let helpText: String
    let onTap: () -> Void
    let content: () -> Content

    @Environment(\.agyTheme) private var theme
    @State private var hovering = false

    var body: some View {
        content()
            .frame(width: width, height: 22)
            .background(
                isActive
                    ? theme.accent.opacity(theme.isDark ? 0.22 : 0.13)
                    : (hovering
                        ? theme.surfaceRaised.opacity(theme.isDark ? 0.85 : 1.0)
                        : theme.surfaceRaised.opacity(theme.isDark ? 0.55 : 0.88))
            )
            .overlay(
                Rectangle().stroke(
                    isActive ? theme.accent : (hovering ? theme.accent.opacity(0.65) : theme.hairlineStrong.opacity(0.85)),
                    lineWidth: isActive ? 1.0 : 0.8
                )
            )
            .contentShape(Rectangle())
            .help(helpText)
            .onHover { inside in
                hovering = inside
                PointingCursorCoordinator.shared.setPointing(inside, token: token)
            }
            .onDisappear {
                hovering = false
                PointingCursorCoordinator.shared.setPointing(false, token: token)
            }
            .onTapGesture { onTap() }
    }
}

// MARK: - Formatting & Canvas Geometry Helpers

private func formatSpeedMultiplier(_ mult: Double) -> String {
    guard mult.isFinite, mult > 0 else { return "1×" }
    if mult >= 10.0 || abs(mult - mult.rounded()) < 0.05 {
        return "\(Int(mult.rounded()))×"
    }
    return String(format: "%.1f×", locale: Locale(identifier: "en_US_POSIX"), mult)
}

private func formatReplayDuration(_ sec: Double) -> String {
    guard sec.isFinite, sec > 0 else { return "0s" }
    let total = Int(sec.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return "\(h)h \(m)m" }
    if m > 0 { return "\(m)m \(String(format: "%02d", s))s" }
    return "\(s)s"
}

private func formatWaitKPI(_ sec: Double) -> String {
    guard sec.isFinite, sec > 0.5 else { return "0s" }
    if sec < 60 { return "\(Int(sec.rounded()))s" }
    if sec < 3600 {
        return String(format: "%.1fm", locale: Locale(identifier: "en_US_POSIX"), sec / 60.0)
    }
    return String(format: "%.1fh", locale: Locale(identifier: "en_US_POSIX"), sec / 3600.0)
}

private func replayTrackCountText(
    topology: SessionTopologyKind,
    trackCount: Int,
    loc: Localizer
) -> String {
    let n = max(1, trackCount)
    switch topology {
    case .swarm:
        return String(format: loc("replayWorkersUnitFmt"), max(1, n > 1 ? n - 1 : n))
    case .dynamicWorkflow:
        return String(format: loc("replayStagesUnitFmt"), max(1, n > 1 ? n - 1 : n))
    case .subagentTree:
        return String(format: loc("replayAgentsUnitFmt"), n)
    case .battle:
        return String(format: loc("replayBranchesUnitFmt"), max(1, n > 1 ? n - 1 : n))
    case .solo:
        return String(format: loc("replayTracksUnitFmt"), n)
    }
}

private func shortDisplayLabel(_ raw: String, maxLen: Int) -> String {
    if raw.count <= maxLen { return raw }
    return String(raw.prefix(max(1, maxLen - 1))) + "…"
}

private func drawSmallDiamond(
    in context: inout GraphicsContext,
    at pt: CGPoint,
    r: CGFloat,
    color: Color
) {
    var d = Path()
    d.move(to: CGPoint(x: pt.x, y: pt.y - r))
    d.addLine(to: CGPoint(x: pt.x + r, y: pt.y))
    d.addLine(to: CGPoint(x: pt.x, y: pt.y + r))
    d.addLine(to: CGPoint(x: pt.x - r, y: pt.y))
    d.closeSubpath()
    context.fill(d, with: .color(color))
}

private func drawReplayCornerReticle(
    in context: inout GraphicsContext,
    center: CGPoint,
    radius: CGFloat,
    len: CGFloat,
    color: Color,
    lineWidth: CGFloat
) {
    let minX = center.x - radius, maxX = center.x + radius
    let minY = center.y - radius, maxY = center.y + radius
    var p = Path()
    p.move(to: CGPoint(x: minX, y: minY + len)); p.addLine(to: CGPoint(x: minX, y: minY)); p.addLine(to: CGPoint(x: minX + len, y: minY))
    p.move(to: CGPoint(x: maxX - len, y: minY)); p.addLine(to: CGPoint(x: maxX, y: minY)); p.addLine(to: CGPoint(x: maxX, y: minY + len))
    p.move(to: CGPoint(x: minX, y: maxY - len)); p.addLine(to: CGPoint(x: minX, y: maxY)); p.addLine(to: CGPoint(x: minX + len, y: maxY))
    p.move(to: CGPoint(x: maxX - len, y: maxY)); p.addLine(to: CGPoint(x: maxX, y: maxY)); p.addLine(to: CGPoint(x: maxX, y: maxY - len))
    context.stroke(p, with: .color(color), lineWidth: lineWidth)
}

private struct ReplayLabelPlacement {
    let rect: CGRect
    let alignRight: Bool
    let overlapArea: CGFloat
}

private func placeReplayLabelBox(
    near np: CGPoint,
    awayFrom center: CGPoint,
    boxSize: CGSize,
    reticleGap: CGFloat,
    bounds: CGSize,
    occupied: [CGRect]
) -> ReplayLabelPlacement {
    let padX: CGFloat = 8
    let padY: CGFloat = 6
    let outX = np.x - center.x
    let outY = np.y - center.y
    let w = boxSize.width
    let h = boxSize.height

    let candidates: [(x: CGFloat, y: CGFloat, alignRight: Bool, dirX: CGFloat, dirY: CGFloat)] = [
        (np.x + reticleGap,           np.y - h - 2,          false,  1, -1),
        (np.x - reticleGap - w,       np.y - h - 2,          true,  -1, -1),
        (np.x + reticleGap,           np.y + 2,              false,  1,  1),
        (np.x - reticleGap - w,       np.y + 2,              true,  -1,  1),
        (np.x + reticleGap + 2,       np.y - h * 0.5,        false,  1,  0),
        (np.x - reticleGap - w - 2,   np.y - h * 0.5,        true,  -1,  0),
        (np.x - w * 0.5,              np.y - reticleGap - h, false,  0, -1),
        (np.x - w * 0.5,              np.y + reticleGap,     false,  0,  1),
    ]

    var best: ReplayLabelPlacement?
    var bestScore = CGFloat.greatestFiniteMagnitude

    for c in candidates {
        let clampedX = min(max(c.x, padX), max(padX, bounds.width - padX - w))
        let clampedY = min(max(c.y, padY), max(padY, bounds.height - padY - h))
        let rect = CGRect(x: clampedX, y: clampedY, width: w, height: h)

        var overlap: CGFloat = 0
        for occ in occupied {
            let inter = rect.intersection(occ)
            if !inter.isNull && !inter.isEmpty {
                overlap += inter.width * inter.height
            }
        }

        let clampPenalty = (abs(clampedX - c.x) + abs(clampedY - c.y)) * 1.8
        let dot = c.dirX * outX + c.dirY * outY
        let outwardBonus: CGFloat = dot > 0 ? -6.0 : 2.5
        let score = overlap * 42.0 + clampPenalty + outwardBonus

        if score < bestScore {
            bestScore = score
            best = ReplayLabelPlacement(rect: rect, alignRight: c.alignRight, overlapArea: overlap)
        }
    }

    return best ?? ReplayLabelPlacement(
        rect: CGRect(x: padX, y: padY, width: w, height: h),
        alignRight: false,
        overlapArea: 0
    )
}

/// Semantic `VERIFY` / calm secondary telemetry color: uses Google Green (`accentQuaternary`)
/// on multi-color Google themes so `VERIFY` never collides with crimson `RETRY` errors, while
/// preserving `accentSecondary` across all other 6 duotone themes.
private func replayVerifyColor(_ theme: AGYTheme) -> Color {
    theme.isMultiColorSpectrum ? theme.accentQuaternary : theme.accentSecondary
}

private func drawReplayLeaderLine(
    in context: inout GraphicsContext,
    from np: CGPoint,
    to rect: CGRect,
    reticleRadius: CGFloat,
    color: Color,
    lineWidth: CGFloat
) {
    // When the callout sits vertically above or below the target node (`np.x` within
    // the callout's horizontal span), anchor cleanly to the nearest horizontal edge so
    // no sideways elbow spike ever protrudes past `rect.minX` or `rect.maxX`.
    if np.x >= rect.minX - 4.0 && np.x <= rect.maxX + 4.0 {
        let targetX = min(max(rect.minX + 10.0, np.x), rect.maxX - 10.0)
        let targetY = (rect.midY < np.y) ? (rect.maxY + 1.5) : (rect.minY - 1.5)
        let dx = targetX - np.x
        let dy = targetY - np.y
        let dist = hypot(dx, dy)
        guard dist > reticleRadius + 2.0 else { return }

        let startX = np.x + (dx / dist) * reticleRadius
        let startY = np.y + (dy / dist) * reticleRadius
        var path = Path()
        path.move(to: CGPoint(x: startX, y: startY))
        path.addLine(to: CGPoint(x: targetX, y: targetY))
        context.stroke(path, with: .color(color), lineWidth: lineWidth)
        return
    }

    let boxIsRight = rect.midX >= np.x
    let targetX = boxIsRight ? rect.minX - 1.5 : rect.maxX + 1.5
    let targetY = rect.minY + 6.5
    let dx = targetX - np.x
    let dy = targetY - np.y
    let dist = hypot(dx, dy)
    guard dist > reticleRadius + 2.0 else { return }

    let startX = np.x + (dx / dist) * reticleRadius
    let startY = np.y + (dy / dist) * reticleRadius
    let horizGap = abs(targetX - startX)
    let elbowInset = min(5.0, max(0.0, horizGap * 0.45))
    let elbowX = targetX + (boxIsRight ? -elbowInset : elbowInset)

    var path = Path()
    path.move(to: CGPoint(x: startX, y: startY))
    path.addLine(to: CGPoint(x: elbowX, y: targetY))
    path.addLine(to: CGPoint(x: targetX, y: targetY))
    context.stroke(path, with: .color(color), lineWidth: lineWidth)
}
