import Foundation
import Testing
@testable import AGYCore

@Suite("Core_Replay")
struct ReplayTests {

    // MARK: - Helpers

    private func baseEpoch() -> Double {
        // 2026-11-22T10:00:00Z
        AppDate.parseISO8601("2026-11-22T10:00:00Z")!.timeIntervalSince1970
    }

    // MARK: - 1. Enums & Value Types

    @Test("SessionTopologyKind badge codes and Codable round-trip cover all 5 topologies")
    func topologyBadgesAndCodable() throws {
        let expected: [(SessionTopologyKind, String)] = [
            (.swarm, "SWARM"),
            (.dynamicWorkflow, "WORKFLOW"),
            (.subagentTree, "SUBAGENT"),
            (.battle, "BATTLE"),
            (.solo, "SOLO"),
        ]
        #expect(SessionTopologyKind.allCases.count == 5)
        for (kind, badge) in expected {
            #expect(kind.badgeCode == badge)
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(SessionTopologyKind.self, from: data)
            #expect(decoded == kind)
        }
    }

    @Test("ReplaySegment durationSec clamps negative spans to zero")
    func segmentDurationClamp() {
        let normal = ReplaySegment(id: "s1", kind: .work, startSec: 10, endSec: 25, stepCount: 3)
        #expect(normal.durationSec == 15)

        let inverted = ReplaySegment(id: "s2", kind: .work, startSec: 30, endSec: 20, stepCount: 1)
        #expect(inverted.durationSec == 0)
    }

    // MARK: - 2. Parsers

    @Test("parseTranscriptSteps extracts steps, tokens, workflow descriptions, subagent targets, and skips sentinels")
    func parseTranscriptStepsComprehensive() {
        let jsonl = """
        {"step_index":0,"type":"USER_INPUT","status":"DONE","created_at":"0001-01-01T00:00:00Z"}
        not-valid-json
        {"step_index":2,"type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-22T10:00:15.123456789Z","model":"gemini-4-carbon-high","input_tokens":1000,"cache_read_tokens":5000,"cache_write_tokens":500,"output_tokens":250,"tool_calls":[{"name":"default_api:run_workflow","arguments":{"Description":"Build & verify shards"}},{"name":"invoke_subagent","args":{"Role":"qa-verifier"}}]}
        {"step_index":1,"type":"USER_INPUT","status":"DONE","created_at":"2026-11-22T18:00:05+08:00"}
        {"step_index":3,"type":"PLANNER_RESPONSE","status":"ERROR","created_at":"2026-11-22T10:00:30Z","model":"gemini-4-hydrogen-medium","input_tokens":800,"cache_read":200,"cache_write":100,"output_tokens":50,"tool_calls":[{"name":"invoke_subagent","arguments":"{\\"TypeName\\":\\"researcher\\"}"}]}
        """

        let steps = ReplayLogic.parseTranscriptSteps(jsonlText: jsonl)
        #expect(steps.count == 3)

        // Sorted chronologically: step 1 (10:00:05Z), step 2 (10:00:15.123Z), step 3 (10:00:30Z)
        #expect(steps[0].stepIndex == 1)
        #expect(steps[0].type == "USER_INPUT")
        #expect(steps[0].status == "DONE")

        #expect(steps[1].stepIndex == 2)
        #expect(steps[1].model == "gemini-4-carbon-high")
        #expect(steps[1].inputTokens == 1000)
        #expect(steps[1].cacheReadTokens == 5000)
        #expect(steps[1].cacheWriteTokens == 500)
        #expect(steps[1].outputTokens == 250)
        #expect(steps[1].toolNames == ["run_workflow", "invoke_subagent"])
        #expect(steps[1].workflowDescriptions == ["Build & verify shards"])
        #expect(steps[1].subagentTargets == ["qa-verifier"])

        #expect(steps[2].stepIndex == 3)
        #expect(steps[2].status == "ERROR")
        #expect(steps[2].cacheReadTokens == 200)
        #expect(steps[2].cacheWriteTokens == 100)
        #expect(steps[2].subagentTargets == ["researcher"])
    }

    @Test("parseSwarmBoard handles local yyyy-MM-dd HH:mm:ss, ISO-8601, and filters invalid timestamps")
    func parseSwarmBoardFormats() {
        let jsonl = """
        {"seq":2,"agent":"worker-a","text":"@coordinator [done] built parser","time":"2026-11-22 18:05:30"}
        {"seq":1,"agent":"coordinator","text":"@worker-a start core layer","time":"2026-11-22 18:00:00"}
        {"seq":3,"agent":"worker-b","text":"@all synced","time":"2026-11-22T10:10:00Z"}
        {"seq":4,"agent":"ghost","text":"sentinel","time":"0001-01-01 00:00:00"}
        {"seq":5,"agent":"ghost2","text":"bad calendar date","time":"2026-02-30 12:00:00"}
        {"seq":6,"agent":"","text":"missing agent","time":"2026-11-22 18:06:00"}
        bad json line
        """

        let events = ReplayLogic.parseSwarmBoard(jsonlText: jsonl)
        #expect(events.count == 3)

        // Verify local board timestamps differ by exact 330 seconds (5m30s)
        let e1 = events.first { $0.seq == 1 }!
        let e2 = events.first { $0.seq == 2 }!
        #expect(abs((e2.timestamp - e1.timestamp) - 330.0) < 0.001)
        #expect(e1.agent == "coordinator")
        #expect(e2.agent == "worker-a")
        #expect(events.contains { $0.seq == 3 && $0.agent == "worker-b" })
    }

    // MARK: - 3. Offline Cost Estimation

    @Test("estimateStepCostUSD matches standard list rates for all 7 ModelClass tiers")
    func costEstimationAllClasses() {
        // 1M of each token channel makes verification exact
        let million = 1_000_000
        #expect(abs(ReplayLogic.estimateStepCostUSD(modelClass: .carbon, inputTokens: million, cacheReadTokens: million, cacheWriteTokens: million, outputTokens: million) - (4.00 + 0.20 + 5.00 + 20.00)) < 1e-9)
        #expect(abs(ReplayLogic.estimateStepCostUSD(modelClass: .argon, inputTokens: million, cacheReadTokens: million, cacheWriteTokens: million, outputTokens: million) - (4.00 + 0.20 + 5.00 + 20.00)) < 1e-9)
        #expect(abs(ReplayLogic.estimateStepCostUSD(modelClass: .neon, inputTokens: million, cacheReadTokens: million, cacheWriteTokens: million, outputTokens: million) - (3.00 + 0.15 + 3.75 + 15.00)) < 1e-9)
        #expect(abs(ReplayLogic.estimateStepCostUSD(modelClass: .hydrogen, inputTokens: million, cacheReadTokens: million, cacheWriteTokens: million, outputTokens: million) - (1.50 + 0.075 + 1.875 + 7.50)) < 1e-9)
        #expect(abs(ReplayLogic.estimateStepCostUSD(modelClass: .flash, inputTokens: million, cacheReadTokens: million, cacheWriteTokens: million, outputTokens: million) - (1.50 + 0.15 + 1.875 + 7.50)) < 1e-9)
        #expect(abs(ReplayLogic.estimateStepCostUSD(modelClass: .claude, inputTokens: million, cacheReadTokens: million, cacheWriteTokens: million, outputTokens: million) - (3.00 + 0.30 + 3.75 + 15.00)) < 1e-9)
        #expect(abs(ReplayLogic.estimateStepCostUSD(modelClass: .other, inputTokens: million, cacheReadTokens: million, cacheWriteTokens: million, outputTokens: million) - (0.15 + 0.0375 + 0.1875 + 0.60)) < 1e-9)

        // Negative values clamp to 0
        #expect(ReplayLogic.estimateStepCostUSD(modelClass: .carbon, inputTokens: -500, cacheReadTokens: -100, cacheWriteTokens: -50, outputTokens: -10) == 0)
    }

    // MARK: - 4. Topology Classification Precedence

    @Test("classifyTopology enforces exact priority: battle > swarm > dynamicWorkflow > subagentTree > solo")
    func topologyClassificationPriority() {
        let t0 = baseEpoch()
        let wfStep = ReplayRawStep(stepIndex: 0, timestamp: t0, type: "PLANNER_RESPONSE", status: "DONE", toolNames: ["run_workflow"])
        let subStep = ReplayRawStep(stepIndex: 0, timestamp: t0, type: "PLANNER_RESPONSE", status: "DONE", toolNames: ["invoke_subagent"])
        let plainStep = ReplayRawStep(stepIndex: 0, timestamp: t0, type: "PLANNER_RESPONSE", status: "DONE", toolNames: ["read_file"])

        let board = [ReplayBoardInput(seq: 1, agent: "coordinator", text: "@w1 go", timestamp: t0)]
        let battleChild = ReplayChildInput(conversationId: "b1", name: "Branch A", roleLabel: "Model A", kind: .battleBranch, parentId: "root", depth: 1, steps: [plainStep])
        let swarmChild = ReplayChildInput(conversationId: "w1", name: "worker-1", roleLabel: "Worker", kind: .swarmWorker, parentId: "root", depth: 1, steps: [plainStep])
        let wfChild = ReplayChildInput(conversationId: "wf1", name: "stage-1", roleLabel: "Stage", kind: .workflowStage, parentId: "root", depth: 1, steps: [plainStep])
        let subChild = ReplayChildInput(conversationId: "sub1", name: "helper", roleLabel: "Subagent", kind: .subagent, parentId: "root", depth: 1, steps: [plainStep])

        // 1. battleId beats everything (even swarm + workflow + subagent)
        let battleMeta = ReplayMissionMeta(conversationId: "root", title: "T", workspaceLabel: "W", battleId: "battle-99", hasSwarmDir: true)
        #expect(ReplayLogic.classifyTopology(meta: battleMeta, rootSteps: [wfStep, subStep], children: [swarmChild], boardEvents: board) == .battle)

        // 1b. battleBranch child beats swarm
        let swarmMeta = ReplayMissionMeta(conversationId: "root", title: "T", workspaceLabel: "W", battleId: nil, hasSwarmDir: true)
        #expect(ReplayLogic.classifyTopology(meta: swarmMeta, rootSteps: [wfStep], children: [battleChild], boardEvents: board) == .battle)

        // 2. swarm beats dynamicWorkflow & subagentTree
        #expect(ReplayLogic.classifyTopology(meta: swarmMeta, rootSteps: [wfStep, subStep], children: [wfChild], boardEvents: []) == .swarm)
        let plainMeta = ReplayMissionMeta(conversationId: "root", title: "T", workspaceLabel: "W")
        #expect(ReplayLogic.classifyTopology(meta: plainMeta, rootSteps: [wfStep], children: [], boardEvents: board) == .swarm)
        #expect(ReplayLogic.classifyTopology(meta: plainMeta, rootSteps: [wfStep], children: [swarmChild], boardEvents: []) == .swarm)

        // 3. dynamicWorkflow beats subagentTree
        #expect(ReplayLogic.classifyTopology(meta: plainMeta, rootSteps: [wfStep, subStep], children: [subChild], boardEvents: []) == .dynamicWorkflow)
        #expect(ReplayLogic.classifyTopology(meta: plainMeta, rootSteps: [plainStep], children: [wfChild], boardEvents: []) == .dynamicWorkflow)

        // 4. subagentTree beats solo
        #expect(ReplayLogic.classifyTopology(meta: plainMeta, rootSteps: [subStep], children: [], boardEvents: []) == .subagentTree)
        #expect(ReplayLogic.classifyTopology(meta: plainMeta, rootSteps: [plainStep], children: [subChild], boardEvents: []) == .subagentTree)

        // 5. solo fallback
        #expect(ReplayLogic.classifyTopology(meta: plainMeta, rootSteps: [plainStep], children: [], boardEvents: []) == .solo)
    }

    // MARK: - 5. Timeline Building, Compression, Human Wait & Retry Loops

    @Test("buildTimeline compresses overnight >1800s gaps to 60s while preserving 60s..1800s human waits")
    func idleCompressionAndHumanWait() {
        let t0 = baseEpoch()
        let meta = ReplayMissionMeta(conversationId: "solo-1", title: "Long Session", workspaceLabel: "AGYMonitor")
        let steps: [ReplayRawStep] = [
            // Turn 1: 0s -> 20s
            ReplayRawStep(stepIndex: 0, timestamp: t0, type: "USER_INPUT", status: "DONE"),
            ReplayRawStep(stepIndex: 1, timestamp: t0 + 20, type: "PLANNER_RESPONSE", status: "DONE", model: "gemini-4-carbon", inputTokens: 1000, outputTokens: 200),
            // Human Wait of 300s (5 minutes, preserved 1:1): 20s -> 320s
            ReplayRawStep(stepIndex: 2, timestamp: t0 + 320, type: "USER_INPUT", status: "DONE"),
            ReplayRawStep(stepIndex: 3, timestamp: t0 + 340, type: "PLANNER_RESPONSE", status: "DONE", model: "gemini-4-carbon", inputTokens: 1000, outputTokens: 200),
            // Overnight sleep of 7200s (2 hours > 1800s -> compressed to 60s!): 340s -> 400s
            ReplayRawStep(stepIndex: 4, timestamp: t0 + 340 + 7200, type: "USER_INPUT", status: "DONE"),
            ReplayRawStep(stepIndex: 5, timestamp: t0 + 340 + 7200 + 20, type: "PLANNER_RESPONSE", status: "DONE", model: "gemini-4-carbon", inputTokens: 1000, outputTokens: 200),
        ]

        let timeline = ReplayLogic.buildTimeline(meta: meta, rootSteps: steps, children: [], boardEvents: [])
        #expect(timeline.topology == .solo)
        #expect(timeline.dateLabel == AppDate.dayKey(Date(timeIntervalSince1970: t0)))
        // Expected warped total duration: 20 + 300 + 20 + 60 + 20 = 420s (NOT 7560s)
        #expect(abs(timeline.totalDurationSec - 420.0) < 0.01)
        // Human wait is strictly the 300s pause (not the 7200s overnight sleep!)
        #expect(abs(timeline.humanWaitSec - 300.0) < 0.01)
        #expect(timeline.humanWaitPercent == 71) // 300 / 420 = 71.4%

        let root = timeline.tracks[0]
        let waitSegs = root.segments.filter { $0.kind == .humanWait }
        #expect(waitSegs.count == 1)
        #expect(abs(waitSegs[0].startSec - 20.0) < 0.01)
        #expect(abs(waitSegs[0].endSec - 320.0) < 0.01)
    }

    @Test("buildTimeline detects retry loops (>=2 errors within 180s), computes waste, and ignores isolated single error")
    func retryLoopDetectionAndCostWaste() {
        let t0 = baseEpoch()
        let meta = ReplayMissionMeta(conversationId: "retry-1", title: "Flaky Build", workspaceLabel: "AGYMonitor")
        let steps: [ReplayRawStep] = [
            // Normal work: $0.04 + $0.20 = $0.24
            ReplayRawStep(stepIndex: 0, timestamp: t0, type: "PLANNER_RESPONSE", status: "DONE", model: "gemini-4-carbon", inputTokens: 10_000, outputTokens: 10_000),
            // Retry loop: 3 errors within 120s (3 * ($0.04 + $0.20) = $0.72)
            ReplayRawStep(stepIndex: 1, timestamp: t0 + 30, type: "PLANNER_RESPONSE", status: "ERROR", model: "gemini-4-carbon", inputTokens: 10_000, outputTokens: 10_000),
            ReplayRawStep(stepIndex: 2, timestamp: t0 + 80, type: "ERROR_MESSAGE", status: "ERROR", model: "gemini-4-carbon", inputTokens: 10_000, outputTokens: 10_000),
            ReplayRawStep(stepIndex: 3, timestamp: t0 + 130, type: "PLANNER_RESPONSE", status: "ERROR", model: "gemini-4-carbon", inputTokens: 10_000, outputTokens: 10_000),
            // Isolated single error 400s later (> 180s from previous error) -> NOT a retry loop!
            ReplayRawStep(stepIndex: 4, timestamp: t0 + 530, type: "PLANNER_RESPONSE", status: "ERROR", model: "gemini-4-carbon", inputTokens: 10_000, outputTokens: 10_000),
        ]

        let timeline = ReplayLogic.buildTimeline(meta: meta, rootSteps: steps, children: [], boardEvents: [])
        #expect(timeline.totalRetryLoops == 1)
        #expect(timeline.tracks.count == 1)

        let track = timeline.tracks[0]
        #expect(track.retryCount == 3)
        // Total cost = 5 * 0.24 = 1.20; retry waste = 3 * 0.24 = 0.72 -> 60%
        #expect(abs(timeline.totalCostUSD - 1.20) < 1e-6)
        #expect(abs(timeline.retryWasteUSD - 0.72) < 1e-6)
        #expect(timeline.retryWastePercent == 60)

        let retrySegs = track.segments.filter { $0.kind == .retryLoop }
        #expect(retrySegs.count == 1)
        #expect(retrySegs[0].errorCount == 3)
        #expect(abs(retrySegs[0].startSec - 30.0) < 0.01)
        #expect(abs(retrySegs[0].endSec - 130.0) < 0.01)
    }

    @Test("buildTimeline differentiates verify tracks (qa/verify/test/audit/review) and builds swarm board beams")
    func swarmWithVerifyTrackAndBoardBeams() {
        let t0 = baseEpoch()
        let meta = ReplayMissionMeta(conversationId: "coord-1", title: "Release Swarm", workspaceLabel: "AGYMonitor", hasSwarmDir: true)

        let rootSteps = [
            ReplayRawStep(stepIndex: 0, timestamp: t0, type: "USER_INPUT", status: "DONE"),
            ReplayRawStep(stepIndex: 1, timestamp: t0 + 10, type: "PLANNER_RESPONSE", status: "DONE", model: "gemini-4-carbon", inputTokens: 2000, outputTokens: 500),
            ReplayRawStep(stepIndex: 2, timestamp: t0 + 120, type: "PLANNER_RESPONSE", status: "DONE", model: "gemini-4-carbon", inputTokens: 2000, outputTokens: 500),
        ]
        let workerCore = ReplayChildInput(
            conversationId: "w-core",
            name: "replay-core",
            roleLabel: "Builder",
            kind: .swarmWorker,
            parentId: "coord-1",
            depth: 1,
            steps: [
                ReplayRawStep(stepIndex: 0, timestamp: t0 + 15, type: "PLANNER_RESPONSE", status: "DONE", model: "gemini-4-argon", inputTokens: 3000, outputTokens: 1000),
                ReplayRawStep(stepIndex: 1, timestamp: t0 + 60, type: "PLANNER_RESPONSE", status: "DONE", model: "gemini-4-argon", inputTokens: 3000, outputTokens: 1000),
            ]
        )
        let workerQA = ReplayChildInput(
            conversationId: "w-qa",
            name: "v19-polish-qa",
            roleLabel: "QA Verifier",
            kind: .swarmWorker,
            parentId: "coord-1",
            depth: 1,
            steps: [
                ReplayRawStep(stepIndex: 0, timestamp: t0 + 65, type: "PLANNER_RESPONSE", status: "DONE", model: "gemini-4-hydrogen", inputTokens: 1500, outputTokens: 400),
                ReplayRawStep(stepIndex: 1, timestamp: t0 + 110, type: "PLANNER_RESPONSE", status: "DONE", model: "gemini-4-hydrogen", inputTokens: 1500, outputTokens: 400),
            ]
        )
        let board = [
            ReplayBoardInput(seq: 1, agent: "coordinator", text: "@replay-core build core engine", timestamp: t0 + 12),
            ReplayBoardInput(seq: 2, agent: "replay-core", text: "@v19-polish-qa ready for QA", timestamp: t0 + 62),
            ReplayBoardInput(seq: 3, agent: "v19-polish-qa", text: "@all PASS all gates", timestamp: t0 + 112),
        ]

        let timeline = ReplayLogic.buildTimeline(meta: meta, rootSteps: rootSteps, children: [workerCore, workerQA], boardEvents: board)
        #expect(timeline.topology == .swarm)
        #expect(timeline.tracks.count == 3)

        let qaTrack = timeline.tracks.first { $0.id == "w-qa" }!
        #expect(qaTrack.modelClass == .hydrogen)
        #expect(qaTrack.segments.allSatisfy { $0.kind == .verify })

        let coreTrack = timeline.tracks.first { $0.id == "w-core" }!
        #expect(coreTrack.modelClass == .argon)
        #expect(coreTrack.segments.allSatisfy { $0.kind == .work })

        // Verify beams: 2 spawns + board seq 1 (coord->core) + seq 2 (core->qa) + seq 3 (@all -> coord & core) = 6
        let boardBeams = timeline.beams.filter { $0.kind == .boardPost }
        #expect(boardBeams.count == 4)
        #expect(boardBeams.contains { $0.fromTrackId == "coord-1" && $0.toTrackId == "w-core" })
        #expect(boardBeams.contains { $0.fromTrackId == "w-core" && $0.toTrackId == "w-qa" })
        #expect(boardBeams.filter { $0.fromTrackId == "w-qa" }.count == 2)
        #expect(timeline.beams.filter { $0.kind == .spawn }.count == 2)
    }

    @Test("buildTimeline synthesizes workflowStage tracks from run_workflow calls when no child workflow tracks exist")
    func syntheticWorkflowStages() {
        let t0 = baseEpoch()
        let meta = ReplayMissionMeta(conversationId: "wf-root", title: "Pipeline", workspaceLabel: "AGYMonitor")
        let rootSteps = [
            ReplayRawStep(stepIndex: 0, timestamp: t0, type: "PLANNER_RESPONSE", status: "DONE", model: "gemini-4-neon", toolNames: ["run_workflow"], workflowDescriptions: ["Fan-out lint"]),
            ReplayRawStep(stepIndex: 1, timestamp: t0 + 40, type: "PLANNER_RESPONSE", status: "DONE", model: "gemini-4-neon", toolNames: ["run_workflow"], workflowDescriptions: ["Audit & verify"]),
            ReplayRawStep(stepIndex: 2, timestamp: t0 + 90, type: "PLANNER_RESPONSE", status: "DONE", model: "gemini-4-neon"),
        ]

        let timeline = ReplayLogic.buildTimeline(meta: meta, rootSteps: rootSteps, children: [], boardEvents: [])
        #expect(timeline.topology == .dynamicWorkflow)
        #expect(timeline.tracks.count == 3) // root + 2 synthesized stages

        let stages = timeline.tracks.filter { $0.kind == .workflowStage }
        #expect(stages.count == 2)
        #expect(stages[0].segments.first?.kind == .work)
        #expect(stages[1].segments.first?.kind == .verify) // "Audit & verify" triggers .verify!
        #expect(timeline.beams.filter { $0.kind == .workflowStage }.count == 2)
    }

    @Test("buildTimeline attaches explicit workflowStage children without duplicating synthetic tracks")
    func explicitWorkflowChildrenNoDuplication() {
        let t0 = baseEpoch()
        let meta = ReplayMissionMeta(conversationId: "wf-root", title: "Explicit WF", workspaceLabel: "AGYMonitor")
        let rootSteps = [
            ReplayRawStep(stepIndex: 0, timestamp: t0, type: "PLANNER_RESPONSE", status: "DONE", toolNames: ["run_workflow"], workflowDescriptions: ["Stage A"]),
        ]
        let child = ReplayChildInput(
            conversationId: "wf-c1",
            name: "stage-a",
            roleLabel: "Workflow Stage",
            kind: .workflowStage,
            parentId: "wf-root",
            depth: 1,
            steps: [ReplayRawStep(stepIndex: 0, timestamp: t0 + 5, type: "PLANNER_RESPONSE", status: "DONE")]
        )

        let timeline = ReplayLogic.buildTimeline(meta: meta, rootSteps: rootSteps, children: [child], boardEvents: [])
        #expect(timeline.topology == .dynamicWorkflow)
        #expect(timeline.tracks.count == 2)
        #expect(timeline.tracks.filter { $0.kind == .workflowStage }.count == 1)
    }

    @Test("buildTimeline handles multi-depth subagent tree and send_message beams")
    func subagentTreeWithSendMessage() {
        let t0 = baseEpoch()
        let meta = ReplayMissionMeta(conversationId: "root", title: "Subagent Tree", workspaceLabel: "AGYMonitor")
        let rootSteps = [
            ReplayRawStep(stepIndex: 0, timestamp: t0, type: "PLANNER_RESPONSE", status: "DONE", model: "claude-sonnet-4", toolNames: ["invoke_subagent"], subagentTargets: ["lead"]),
            ReplayRawStep(stepIndex: 1, timestamp: t0 + 50, type: "PLANNER_RESPONSE", status: "DONE", model: "claude-sonnet-4", toolNames: ["send_message"], subagentTargets: ["lead"]),
        ]
        let lead = ReplayChildInput(
            conversationId: "sub-lead",
            name: "lead",
            roleLabel: "Subagent Lead",
            kind: .subagent,
            parentId: "root",
            depth: 1,
            steps: [
                ReplayRawStep(stepIndex: 0, timestamp: t0 + 4, type: "PLANNER_RESPONSE", status: "DONE", model: "claude-sonnet-4", toolNames: ["invoke_subagent"], subagentTargets: ["leaf"]),
                ReplayRawStep(stepIndex: 1, timestamp: t0 + 60, type: "PLANNER_RESPONSE", status: "DONE", model: "claude-sonnet-4"),
            ]
        )
        let leaf = ReplayChildInput(
            conversationId: "sub-leaf",
            name: "leaf",
            roleLabel: "Leaf Investigator",
            kind: .subagent,
            parentId: "sub-lead",
            depth: 2,
            steps: [
                ReplayRawStep(stepIndex: 0, timestamp: t0 + 12, type: "PLANNER_RESPONSE", status: "DONE", model: "gemini-2.5-flash"),
                ReplayRawStep(stepIndex: 1, timestamp: t0 + 35, type: "PLANNER_RESPONSE", status: "DONE", model: "gemini-2.5-flash"),
            ]
        )

        let timeline = ReplayLogic.buildTimeline(meta: meta, rootSteps: rootSteps, children: [lead, leaf], boardEvents: [])
        #expect(timeline.topology == .subagentTree)
        #expect(timeline.tracks.count == 3)
        #expect(timeline.tracks.first { $0.id == "sub-leaf" }?.depth == 2)
        #expect(timeline.tracks.first { $0.id == "sub-leaf" }?.parentTrackId == "sub-lead")
        #expect(timeline.beams.contains { $0.kind == .subagentMessage && $0.fromTrackId == "root" && $0.toTrackId == "sub-lead" })
    }

    @Test("buildTimeline handles empty input gracefully")
    func emptyTimeline() {
        let meta = ReplayMissionMeta(conversationId: "empty", title: "Empty", workspaceLabel: "WS")
        let timeline = ReplayLogic.buildTimeline(meta: meta, rootSteps: [], children: [], boardEvents: [])
        #expect(timeline.tracks.isEmpty)
        #expect(timeline.beams.isEmpty)
        #expect(timeline.totalDurationSec == 0)
        #expect(ReplayLogic.radarLayout(timeline: timeline).isEmpty)
    }

    // MARK: - 6. Five-Topology Radar Layout Invariants

    @Test("radarLayout keeps all nodes within [0.14...0.86] and overlap-free even with 10+ tracks across all 5 topologies")
    func radarLayoutAllFiveTopologies() {
        let t0 = baseEpoch()

        func makeSteps(_ offset: Double, model: String = "gemini-4-carbon") -> [ReplayRawStep] {
            [
                ReplayRawStep(stepIndex: 0, timestamp: t0 + offset, type: "PLANNER_RESPONSE", status: "DONE", model: model, inputTokens: 1000, outputTokens: 200),
                ReplayRawStep(stepIndex: 1, timestamp: t0 + offset + 20, type: "PLANNER_RESPONSE", status: "DONE", model: model, inputTokens: 1000, outputTokens: 200),
            ]
        }

        // 1. Solo
        let soloTL = ReplayLogic.buildTimeline(
            meta: ReplayMissionMeta(conversationId: "s", title: "Solo", workspaceLabel: "W"),
            rootSteps: makeSteps(0), children: [], boardEvents: []
        )
        let soloNodes = ReplayLogic.radarLayout(timeline: soloTL)
        #expect(soloNodes.count == 1)
        #expect(soloNodes[0].normX == 0.50 && soloNodes[0].normY == 0.50)

        // 2. Swarm with 10 workers (11 total tracks -> dual concentric ring)
        let swarmChildren = (1...10).map { i in
            ReplayChildInput(conversationId: "w\(i)", name: "worker-\(i)", roleLabel: "Worker", kind: .swarmWorker, parentId: "sw", depth: 1, steps: makeSteps(Double(i * 5)))
        }
        let swarmTL = ReplayLogic.buildTimeline(
            meta: ReplayMissionMeta(conversationId: "sw", title: "Big Swarm", workspaceLabel: "W", hasSwarmDir: true),
            rootSteps: makeSteps(0), children: swarmChildren, boardEvents: []
        )
        verifyRadarNodes(ReplayLogic.radarLayout(timeline: swarmTL), expectedCount: 11, minSeparation: 0.08)

        // 3. Dynamic Workflow with 9 stages across 3 temporal waves
        let wfChildren = (0..<9).map { i in
            let waveOffset = Double((i / 3) * 30)
            return ReplayChildInput(conversationId: "wf\(i)", name: "stage-\(i)", roleLabel: "Stage", kind: .workflowStage, parentId: "wfr", depth: 1, steps: makeSteps(waveOffset + Double(i % 3)))
        }
        let wfTL = ReplayLogic.buildTimeline(
            meta: ReplayMissionMeta(conversationId: "wfr", title: "WF", workspaceLabel: "W"),
            rootSteps: makeSteps(0), children: wfChildren, boardEvents: []
        )
        verifyRadarNodes(ReplayLogic.radarLayout(timeline: wfTL), expectedCount: 10, minSeparation: 0.08)

        // 4. Subagent Tree with 3 depths (1 + 3 + 6 = 10 tracks)
        var subChildren: [ReplayChildInput] = []
        for i in 1...3 {
            subChildren.append(ReplayChildInput(conversationId: "d1-\(i)", name: "mid-\(i)", roleLabel: "Mid", kind: .subagent, parentId: "st", depth: 1, steps: makeSteps(Double(i * 4))))
            for j in 1...2 {
                subChildren.append(ReplayChildInput(conversationId: "d2-\(i)-\(j)", name: "leaf-\(i)-\(j)", roleLabel: "Leaf", kind: .subagent, parentId: "d1-\(i)", depth: 2, steps: makeSteps(Double(i * 4 + j * 2))))
            }
        }
        let subTL = ReplayLogic.buildTimeline(
            meta: ReplayMissionMeta(conversationId: "st", title: "SubTree", workspaceLabel: "W"),
            rootSteps: makeSteps(0), children: subChildren, boardEvents: []
        )
        verifyRadarNodes(ReplayLogic.radarLayout(timeline: subTL), expectedCount: 10, minSeparation: 0.08)

        // 5. Battle with 2 head-to-head branches AND 8 multi-model branches
        let battle2 = ReplayLogic.buildTimeline(
            meta: ReplayMissionMeta(conversationId: "bt2", title: "Duel", workspaceLabel: "W", battleId: "b-2"),
            rootSteps: makeSteps(0),
            children: [
                ReplayChildInput(conversationId: "br-a", name: "Carbon", roleLabel: "Branch A", kind: .battleBranch, parentId: "bt2", depth: 1, steps: makeSteps(2, model: "gemini-4-carbon")),
                ReplayChildInput(conversationId: "br-b", name: "Claude", roleLabel: "Branch B", kind: .battleBranch, parentId: "bt2", depth: 1, steps: makeSteps(2, model: "claude-opus-4")),
            ],
            boardEvents: []
        )
        let b2Nodes = ReplayLogic.radarLayout(timeline: battle2)
        verifyRadarNodes(b2Nodes, expectedCount: 3, minSeparation: 0.20)
        // Left vs right symmetry around 0.50
        let leftBranch = b2Nodes.first { $0.id == "br-a" }!
        let rightBranch = b2Nodes.first { $0.id == "br-b" }!
        #expect(abs((leftBranch.normX + rightBranch.normX) - 1.0) < 1e-6)

        let battle8Children = (1...8).map { i in
            ReplayChildInput(conversationId: "br-\(i)", name: "Model \(i)", roleLabel: "Branch", kind: .battleBranch, parentId: "bt8", depth: 1, steps: makeSteps(Double(i)))
        }
        let battle8 = ReplayLogic.buildTimeline(
            meta: ReplayMissionMeta(conversationId: "bt8", title: "Arena 8", workspaceLabel: "W", battleId: "b-8"),
            rootSteps: makeSteps(0), children: battle8Children, boardEvents: []
        )
        verifyRadarNodes(ReplayLogic.radarLayout(timeline: battle8), expectedCount: 9, minSeparation: 0.08)
    }

    private func verifyRadarNodes(_ nodes: [ReplayRadarNode], expectedCount: Int, minSeparation: Double) {
        #expect(nodes.count == expectedCount)
        for n in nodes {
            #expect(n.normX >= 0.14 && n.normX <= 0.86)
            #expect(n.normY >= 0.14 && n.normY <= 0.86)
        }
        for i in 0..<nodes.count {
            for j in (i + 1)..<nodes.count {
                let d = hypot(nodes[i].normX - nodes[j].normX, nodes[i].normY - nodes[j].normY)
                #expect(d >= minSeparation, "Nodes \(nodes[i].id) and \(nodes[j].id) overlapped (dist=\(d))")
            }
        }
    }

    // MARK: - 7. Playhead Frame Evaluation

    @Test("evaluateFrame computes live track states, traveling beam progress, activeFault, and sweepAngleDeg")
    func evaluateFrameStatesBeamsAndFaults() {
        let rootTrack = ReplayTrack(
            id: "root",
            name: "coordinator",
            roleLabel: "Coordinator",
            kind: .root,
            parentTrackId: nil,
            depth: 0,
            modelClass: .carbon,
            segments: [
                ReplaySegment(id: "r0", kind: .work, startSec: 0, endSec: 30, stepCount: 2),
                ReplaySegment(id: "r1", kind: .humanWait, startSec: 30, endSec: 80, stepCount: 0),
                ReplaySegment(id: "r2", kind: .work, startSec: 80, endSec: 100, stepCount: 2),
            ],
            totalTokens: 1000,
            outputTokens: 200,
            estimatedCostUSD: 0.20,
            retryCount: 0,
            retryWasteUSD: 0
        )
        let qaTrack = ReplayTrack(
            id: "qa",
            name: "qa-verifier",
            roleLabel: "QA",
            kind: .swarmWorker,
            parentTrackId: "root",
            depth: 1,
            modelClass: .hydrogen,
            segments: [
                ReplaySegment(id: "q0", kind: .retryLoop, startSec: 40, endSec: 60, stepCount: 3, errorCount: 3, estimatedCostUSD: 0.45),
                ReplaySegment(id: "q1", kind: .verify, startSec: 65, endSec: 85, stepCount: 2),
            ],
            totalTokens: 2000,
            outputTokens: 400,
            estimatedCostUSD: 0.60,
            retryCount: 3,
            retryWasteUSD: 0.45
        )
        let beam = ReplayBeamEvent(
            id: "b1",
            timestampSec: 50,
            fromTrackId: "root",
            toTrackId: "qa",
            kind: .boardPost,
            summary: "@qa-verifier check failure"
        )
        let timeline = ReplayTimeline(
            id: "root",
            title: "Test",
            workspaceLabel: "W",
            topology: .swarm,
            dateLabel: "2026-11-22",
            totalDurationSec: 100,
            tracks: [rootTrack, qaTrack],
            beams: [beam],
            totalCostUSD: 0.80,
            totalTokens: 3000,
            retryWasteUSD: 0.45,
            retryWastePercent: 56,
            humanWaitSec: 50,
            humanWaitPercent: 50,
            totalRetryLoops: 1
        )

        // Frame at t = 10s (progress 0.10): root working, qa idle, no fault, no beam
        let f10 = ReplayLogic.evaluateFrame(timeline: timeline, progress: 0.10)
        #expect(f10.trackStates["root"] == .working)
        #expect(f10.trackStates["qa"] == .idle)
        #expect(f10.activeFault == nil)
        #expect(f10.activeBeams.isEmpty)
        #expect(abs(f10.sweepAngleDeg - 72.0) < 1e-6)

        // Frame at t = 52s (progress 0.52): root waiting, qa retrying, fault active,
        // beam mid-flight (playback-normalized window = max(2.0, 100 * 0.95 / 20) = 4.75 -> progress = 2 / 4.75)
        let f52 = ReplayLogic.evaluateFrame(timeline: timeline, progress: 0.52)
        #expect(f52.trackStates["root"] == .waiting)
        #expect(f52.trackStates["qa"] == .retrying)
        #expect(f52.activeFault == ReplayFaultCallout(trackId: "qa", trackName: "qa-verifier", retryCount: 3, wasteUSD: 0.45))
        #expect(f52.activeBeams.count == 1)
        #expect(abs(f52.activeBeams[0].progress - (2.0 / 4.75)) < 1e-6)

        // Frame at t = 75s (progress 0.75): qa in verify state, fault cleared
        let f75 = ReplayLogic.evaluateFrame(timeline: timeline, progress: 0.75)
        #expect(f75.trackStates["qa"] == .verify)
        #expect(f75.activeFault == nil)
        #expect(f75.activeBeams.isEmpty)

        // Frame at t = 95s (progress 0.95): root working, qa done
        let f95 = ReplayLogic.evaluateFrame(timeline: timeline, progress: 0.95)
        #expect(f95.trackStates["root"] == .working)
        #expect(f95.trackStates["qa"] == .done)

        // Out-of-bounds / NaN progress clamps cleanly
        let fNaN = ReplayLogic.evaluateFrame(timeline: timeline, progress: .nan)
        #expect(fNaN.progress == 0.0)
        let fOver = ReplayLogic.evaluateFrame(timeline: timeline, progress: 2.5)
        #expect(fOver.progress == 1.0)
    }

    @Test("evaluateFrame normalizes beam windows to ~0.95s of 1x playback and supports independent radar sweep")
    func playbackNormalizedBeamWindowAndIndependentSweep() {
        // 5-hour session (18,000s) -> effectivePlaybackDurationSec = 20s -> beamWindow = 855s (= 0.95s of 1x playback)
        let fiveHours = 18_000.0
        let expectedWindow = ReplayLogic.beamWindowSec(timelineDurationSec: fiveHours)
        #expect(abs(expectedWindow - 855.0) < 1e-9)

        let beam = ReplayBeamEvent(
            id: "b-5h",
            timestampSec: 5000.0,
            fromTrackId: "root",
            toTrackId: "w1",
            kind: .boardPost,
            summary: "@w1 sync"
        )
        let longTL = ReplayTimeline(
            id: "long", title: "5h Swarm", workspaceLabel: "W", topology: .swarm, dateLabel: "2026-11-22",
            totalDurationSec: fiveHours, tracks: [], beams: [beam],
            totalCostUSD: 10.0, totalTokens: 1_000_000, retryWasteUSD: 0, retryWastePercent: 0,
            humanWaitSec: 0, humanWaitPercent: 0, totalRetryLoops: 0
        )

        // Halfway through the 855s beam window (t = 5427.5s) -> active beam progress == 0.5
        let midProgress = (5000.0 + expectedWindow * 0.5) / fiveHours
        let midFrame = ReplayLogic.evaluateFrame(timeline: longTL, progress: midProgress)
        #expect(midFrame.activeBeams.count == 1)
        #expect(abs(midFrame.activeBeams[0].progress - 0.5) < 1e-6)

        // Short 30s session -> 30 * (0.95 / 20) = 1.425 -> clamped to floor 2.0s
        #expect(abs(ReplayLogic.beamWindowSec(timelineDurationSec: 30.0) - 2.0) < 1e-9)
        // Mini 12s session -> baseDur = 12 -> 12 * (0.95 / 12) = 0.95 -> clamped to floor 2.0s
        #expect(abs(ReplayLogic.beamWindowSec(timelineDurationSec: 12.0) - 2.0) < 1e-9)

        // Independent radar sweep phase overrides deterministic fallback and normalizes to [0, 360)
        #expect(abs(ReplayLogic.evaluateFrame(timeline: longTL, progress: 0.25, sweepPhaseDeg: nil).sweepAngleDeg - 180.0) < 1e-9)
        #expect(abs(ReplayLogic.evaluateFrame(timeline: longTL, progress: 0.50, sweepPhaseDeg: nil).sweepAngleDeg - 0.0) < 1e-9)
        #expect(abs(ReplayLogic.evaluateFrame(timeline: longTL, progress: 0.75, sweepPhaseDeg: nil).sweepAngleDeg - 180.0) < 1e-9)
        #expect(abs(ReplayLogic.evaluateFrame(timeline: longTL, progress: 0.10, sweepPhaseDeg: 123.5).sweepAngleDeg - 123.5) < 1e-9)
        #expect(abs(ReplayLogic.evaluateFrame(timeline: longTL, progress: 0.10, sweepPhaseDeg: 405.0).sweepAngleDeg - 45.0) < 1e-9)
        #expect(abs(ReplayLogic.evaluateFrame(timeline: longTL, progress: 0.10, sweepPhaseDeg: -45.0).sweepAngleDeg - 315.0) < 1e-9)
        #expect(abs(ReplayLogic.evaluateFrame(timeline: longTL, progress: 0.10, sweepPhaseDeg: 360.0).sweepAngleDeg - 0.0) < 1e-9)
        #expect(ReplayLogic.evaluateFrame(timeline: longTL, progress: 0.10, sweepPhaseDeg: .nan).sweepAngleDeg == 0.0)
    }

    // MARK: - 8. Clock Formatter

    @Test("formatClock formats MM:SS under an hour and H:MM:SS for an hour or more")
    func formatClockEdgeCases() {
        #expect(ReplayLogic.formatClock(-5) == "00:00")
        #expect(ReplayLogic.formatClock(.nan) == "00:00")
        #expect(ReplayLogic.formatClock(0) == "00:00")
        #expect(ReplayLogic.formatClock(9.9) == "00:09")
        #expect(ReplayLogic.formatClock(65) == "01:05")
        #expect(ReplayLogic.formatClock(3599) == "59:59")
        #expect(ReplayLogic.formatClock(3600) == "1:00:00")
        #expect(ReplayLogic.formatClock(3661) == "1:01:01")
        #expect(ReplayLogic.formatClock(36_005) == "10:00:05")
    }

    // MARK: - 9. Adaptive Pacing, Smart Idle Skip, Key Event Stepping & Playback State Machine

    @Test("Adaptive target-duration pacing scales long timelines to 20s and preserves short sessions 1:1")
    func adaptiveTargetDurationPacing() {
        #expect(ReplayLogic.targetBasePlaybackSec == 20.0)
        #expect(ReplaySpeed.allCases == [.x0_5, .x1, .x2, .x4])
        #expect(ReplaySpeed.x0_5.label == "0.5x")
        #expect(ReplaySpeed.x1.label == "1x")
        #expect(ReplaySpeed.x2.label == "2x")
        #expect(ReplaySpeed.x4.label == "4x")

        // Short & degenerate durations
        #expect(ReplayLogic.effectivePlaybackDurationSec(timelineDurationSec: -10.0) == 1.0)
        #expect(ReplayLogic.effectivePlaybackDurationSec(timelineDurationSec: 0.0) == 1.0)
        #expect(ReplayLogic.effectivePlaybackDurationSec(timelineDurationSec: .nan) == 1.0)
        #expect(ReplayLogic.effectivePlaybackDurationSec(timelineDurationSec: 12.0) == 12.0)
        #expect(ReplayLogic.effectivePlaybackDurationSec(timelineDurationSec: 20.0) == 20.0)
        // 40m & 5h timelines both normalize to 20s at 1x
        #expect(ReplayLogic.effectivePlaybackDurationSec(timelineDurationSec: 2400.0) == 20.0)
        #expect(ReplayLogic.effectivePlaybackDurationSec(timelineDurationSec: 18_000.0) == 20.0)

        // Real-time multipliers
        #expect(abs(ReplayLogic.effectiveRealTimeMultiplier(timelineDurationSec: 3600.0, speed: .x1) - 180.0) < 1e-9)
        #expect(abs(ReplayLogic.effectiveRealTimeMultiplier(timelineDurationSec: 3600.0, speed: .x2) - 360.0) < 1e-9)
        #expect(abs(ReplayLogic.effectiveRealTimeMultiplier(timelineDurationSec: 3600.0, speed: .x0_5) - 90.0) < 1e-9)
        #expect(abs(ReplayLogic.effectiveRealTimeMultiplier(timelineDurationSec: 12.0, speed: .x1) - 1.0) < 1e-9)
        #expect(abs(ReplayLogic.effectiveRealTimeMultiplier(timelineDurationSec: 12.0, speed: .x4) - 4.0) < 1e-9)
        #expect(ReplayLogic.effectiveRealTimeMultiplier(timelineDurationSec: 0.0, speed: .x1) == 0.0)
        #expect(ReplayLogic.effectiveRealTimeMultiplier(timelineDurationSec: .nan, speed: .x1) == 0.0)
    }

    @Test("ReplayPlaybackState transitions, speed cycling, adaptive step, scrubbing, and auto-pause at 1.0")
    func playbackStateMachine() {
        var state = ReplayPlaybackState()
        #expect(state.progress == 0.0)
        #expect(state.isPlaying == false)
        #expect(state.speed == .x1)
        #expect(state.isSkippingIdle == false)

        // Stepping while paused is a no-op
        state.step(deltaWallSec: 1.0, timelineDurationSec: 100.0)
        #expect(state.progress == 0.0)

        // Toggle play & step at 1x on 100s timeline (effective baseDur = 20s -> 1s wall = +0.05)
        state.togglePlay()
        #expect(state.isPlaying == true)
        state.step(deltaWallSec: 1.0, timelineDurationSec: 100.0)
        #expect(abs(state.progress - 0.05) < 1e-9)

        // Cycle speeds: x1 -> x2 -> x4 -> x0_5 -> x1
        state.cycleSpeed()
        #expect(state.speed == .x2)
        state.step(deltaWallSec: 1.0, timelineDurationSec: 100.0)
        #expect(abs(state.progress - 0.15) < 1e-9)

        state.cycleSpeed()
        #expect(state.speed == .x4)
        state.step(deltaWallSec: 1.0, timelineDurationSec: 100.0)
        #expect(abs(state.progress - 0.35) < 1e-9)

        state.cycleSpeed()
        #expect(state.speed == .x0_5)
        state.step(deltaWallSec: 2.0, timelineDurationSec: 100.0)
        #expect(abs(state.progress - 0.40) < 1e-9)

        state.cycleSpeed()
        #expect(state.speed == .x1)

        // Mini 12s session plays 1:1 (6s wall = +0.50 -> 0.90)
        state.step(deltaWallSec: 6.0, timelineDurationSec: 12.0)
        #expect(abs(state.progress - 0.90) < 1e-9)

        // Auto-pauses cleanly at 1.0
        state.step(deltaWallSec: 5.0, timelineDurationSec: 100.0)
        #expect(state.progress == 1.0)
        #expect(state.isPlaying == false)
        #expect(state.isSkippingIdle == false)

        // Toggling play when already at 1.0 restarts from 0.0 and plays
        state.togglePlay()
        #expect(state.progress == 0.0)
        #expect(state.isPlaying == true)

        // Pause & scrub clamping clear isSkippingIdle
        state.isSkippingIdle = true
        state.pause()
        #expect(state.isPlaying == false)
        #expect(state.isSkippingIdle == false)

        state.isSkippingIdle = true
        state.scrub(to: 0.75)
        #expect(state.progress == 0.75)
        #expect(state.isSkippingIdle == false)
        state.scrub(to: -0.5)
        #expect(state.progress == 0.0)
        state.togglePlay()
        state.scrub(to: 1.5)
        #expect(state.progress == 1.0)
        #expect(state.isPlaying == false)

        // jumpToStart & reset clear isSkippingIdle
        state.isSkippingIdle = true
        state.jumpToStart()
        #expect(state.progress == 0.0)
        #expect(state.isSkippingIdle == false)

        state.togglePlay()
        state.isSkippingIdle = true
        state.reset(initialProgress: 0.42)
        #expect(state.progress == 0.42)
        #expect(state.isPlaying == false)
        #expect(state.isSkippingIdle == false)
    }

    @Test("Smart Skip Idle detects pure dead air, accelerates 3.2x, and clamps cleanly onto next non-idle boundary")
    func smartSkipIdleAndBoundaryClamping() {
        let rootTrack = ReplayTrack(
            id: "root", name: "coordinator", roleLabel: "Coordinator", kind: .root,
            parentTrackId: nil, depth: 0, modelClass: .carbon,
            segments: [
                ReplaySegment(id: "r0", kind: .work, startSec: 0, endSec: 20, stepCount: 2),
                ReplaySegment(id: "r1", kind: .humanWait, startSec: 20, endSec: 60, stepCount: 0),
                ReplaySegment(id: "r2", kind: .work, startSec: 80, endSec: 100, stepCount: 2),
            ],
            totalTokens: 1000, outputTokens: 200, estimatedCostUSD: 0.2, retryCount: 0, retryWasteUSD: 0
        )
        let workerTrack = ReplayTrack(
            id: "w1", name: "qa-worker", roleLabel: "QA", kind: .swarmWorker,
            parentTrackId: "root", depth: 1, modelClass: .hydrogen,
            segments: [
                ReplaySegment(id: "w0", kind: .retryLoop, startSec: 60, endSec: 75, stepCount: 3, errorCount: 3, estimatedCostUSD: 0.3),
                ReplaySegment(id: "w1", kind: .verify, startSec: 85, endSec: 95, stepCount: 2),
            ],
            totalTokens: 800, outputTokens: 150, estimatedCostUSD: 0.4, retryCount: 3, retryWasteUSD: 0.3
        )
        let midWaitBeam = ReplayBeamEvent(
            id: "b-wait", timestampSec: 40, fromTrackId: "root", toTrackId: "w1",
            kind: .boardPost, summary: "@qa-worker wake up"
        )
        let tl = ReplayTimeline(
            id: "root", title: "Smart Skip Test", workspaceLabel: "W", topology: .swarm,
            dateLabel: "2026-11-22", totalDurationSec: 100,
            tracks: [rootTrack, workerTrack], beams: [midWaitBeam],
            totalCostUSD: 0.6, totalTokens: 1800, retryWasteUSD: 0.3, retryWastePercent: 50,
            humanWaitSec: 40, humanWaitPercent: 40, totalRetryLoops: 1
        )

        // isIdleDeadAir truth table across every segment kind + active beam window (4.75s)
        #expect(ReplayLogic.isIdleDeadAir(timeline: tl, progress: 0.10) == false) // .work
        #expect(ReplayLogic.isIdleDeadAir(timeline: tl, progress: 0.30) == true)  // pure .humanWait
        #expect(ReplayLogic.isIdleDeadAir(timeline: tl, progress: 0.42) == false) // .humanWait but beam active [40..44.75]
        #expect(ReplayLogic.isIdleDeadAir(timeline: tl, progress: 0.50) == true)  // pure .humanWait after beam
        #expect(ReplayLogic.isIdleDeadAir(timeline: tl, progress: 0.65) == false) // .retryLoop
        #expect(ReplayLogic.isIdleDeadAir(timeline: tl, progress: 0.77) == true)  // empty dead air [75..80]
        #expect(ReplayLogic.isIdleDeadAir(timeline: tl, progress: 0.90) == false) // .work + .verify

        // 1. Inside .work -> normal 1x pacing (baseDur = 20s -> 1s wall = +0.05)
        var state = ReplayPlaybackState(progress: 0.05, isPlaying: true, speed: .x1)
        state.step(deltaWallSec: 1.0, timeline: tl, smartSkipIdle: true)
        #expect(abs(state.progress - 0.10) < 1e-9)
        #expect(state.isSkippingIdle == false)

        // 2. Inside pure .humanWait -> 3.2x acceleration (0.5s wall -> 0.025 * 3.2 = +0.08)
        state.scrub(to: 0.25)
        state.step(deltaWallSec: 0.5, timeline: tl, smartSkipIdle: true)
        #expect(abs(state.progress - 0.33) < 1e-9)
        #expect(state.isSkippingIdle == true)

        // 3. Approaching beam at t=40 (p=0.40): big 1s step (+0.16 raw) clamps cleanly onto 0.40!
        state.scrub(to: 0.38)
        state.step(deltaWallSec: 1.0, timeline: tl, smartSkipIdle: true)
        #expect(abs(state.progress - 0.40) < 1e-9)
        #expect(state.isSkippingIdle == true)
        // Next tick lands inside active beam window -> resumes normal 1x pacing!
        state.step(deltaWallSec: 0.2, timeline: tl, smartSkipIdle: true)
        #expect(abs(state.progress - 0.41) < 1e-9)
        #expect(state.isSkippingIdle == false)

        // 4. Approaching .retryLoop at t=60 (p=0.60): clamps cleanly onto retry boundary!
        state.scrub(to: 0.55)
        state.step(deltaWallSec: 1.0, timeline: tl, smartSkipIdle: true)
        #expect(abs(state.progress - 0.60) < 1e-9)
        // Next tick inside .retryLoop resumes normal 1x pacing!
        state.step(deltaWallSec: 1.0, timeline: tl, smartSkipIdle: true)
        #expect(abs(state.progress - 0.65) < 1e-9)
        #expect(state.isSkippingIdle == false)

        // 5. smartSkipIdle = false disables idle acceleration
        state.scrub(to: 0.25)
        state.step(deltaWallSec: 1.0, timeline: tl, smartSkipIdle: false)
        #expect(abs(state.progress - 0.30) < 1e-9)
        #expect(state.isSkippingIdle == false)
    }

    @Test("keyEvents extracts prioritized, deduplicated moments and stepToNext/PreviousEvent navigates cleanly")
    func keyEventsAndStepping() {
        let rootTrack = ReplayTrack(
            id: "root", name: "coordinator", roleLabel: "Coordinator", kind: .root,
            parentTrackId: nil, depth: 0, modelClass: .carbon,
            segments: [
                ReplaySegment(id: "r0", kind: .work, startSec: 0, endSec: 35, stepCount: 2),
                ReplaySegment(id: "r1", kind: .retryLoop, startSec: 40, endSec: 52, stepCount: 3, errorCount: 3, estimatedCostUSD: 0.5, label: "3x retry loop"),
            ],
            totalTokens: 1000, outputTokens: 200, estimatedCostUSD: 0.7, retryCount: 3, retryWasteUSD: 0.5
        )
        let workerA = ReplayTrack(
            id: "w-a", name: "core-builder", roleLabel: "Worker", kind: .swarmWorker,
            parentTrackId: "root", depth: 1, modelClass: .argon,
            segments: [ReplaySegment(id: "wa0", kind: .work, startSec: 15, endSec: 35, stepCount: 2)],
            totalTokens: 500, outputTokens: 100, estimatedCostUSD: 0.1, retryCount: 0, retryWasteUSD: 0
        )
        // Worker B starts at t=41 (within 0.02 of retryLoop at 0.40) -> deduplicated in favor of .retryStart
        let workerB = ReplayTrack(
            id: "w-b", name: "near-retry", roleLabel: "Worker", kind: .swarmWorker,
            parentTrackId: "root", depth: 1, modelClass: .hydrogen,
            segments: [ReplaySegment(id: "wb0", kind: .work, startSec: 41, endSec: 55, stepCount: 1)],
            totalTokens: 200, outputTokens: 40, estimatedCostUSD: 0.05, retryCount: 0, retryWasteUSD: 0
        )
        let stageTrack = ReplayTrack(
            id: "wf-1", name: "QA Wave", roleLabel: "Stage", kind: .workflowStage,
            parentTrackId: "root", depth: 1, modelClass: .neon,
            segments: [ReplaySegment(id: "wf0", kind: .verify, startSec: 65, endSec: 80, stepCount: 2)],
            totalTokens: 300, outputTokens: 60, estimatedCostUSD: 0.08, retryCount: 0, retryWasteUSD: 0
        )
        let beams = [
            // At t=15: within 0.02 of workerA spawn -> deduplicated
            ReplayBeamEvent(id: "b0", timestampSec: 15, fromTrackId: "root", toTrackId: "w-a", kind: .spawn, summary: "Spawn core-builder"),
            // At t=25: kept
            ReplayBeamEvent(id: "b1", timestampSec: 25, fromTrackId: "root", toTrackId: "w-a", kind: .boardPost, summary: "@core-builder spec"),
            // At t=26.5: only 0.015 after b1 (< 0.03) -> deduplicated
            ReplayBeamEvent(id: "b2", timestampSec: 26.5, fromTrackId: "w-a", toTrackId: "root", kind: .boardPost, summary: "ack"),
            // At t=29: 0.04 after b1 (>= 0.03) -> kept
            ReplayBeamEvent(id: "b3", timestampSec: 29, fromTrackId: "w-a", toTrackId: "root", kind: .boardPost, summary: "@coordinator update"),
            // At t=66: within 0.02 of workflowWave at 0.65 -> deduplicated
            ReplayBeamEvent(id: "b4", timestampSec: 66, fromTrackId: "root", toTrackId: "wf-1", kind: .workflowStage, summary: "Dispatch QA"),
            // At t=85: kept
            ReplayBeamEvent(id: "b5", timestampSec: 85, fromTrackId: "wf-1", toTrackId: "root", kind: .boardPost, summary: "@coordinator PASS"),
        ]
        let tl = ReplayTimeline(
            id: "root", title: "Key Events", workspaceLabel: "W", topology: .swarm,
            dateLabel: "2026-11-22", totalDurationSec: 100,
            tracks: [rootTrack, workerA, workerB, stageTrack], beams: beams,
            totalCostUSD: 0.93, totalTokens: 2000, retryWasteUSD: 0.5, retryWastePercent: 54,
            humanWaitSec: 0, humanWaitPercent: 0, totalRetryLoops: 1
        )

        let events = ReplayLogic.keyEvents(for: tl)
        #expect(events.count == 6)
        #expect(events.map(\.kind) == [.workerSpawn, .beamBurst, .beamBurst, .retryStart, .workflowWave, .beamBurst])
        #expect(abs(events[0].progress - 0.15) < 1e-9)
        #expect(abs(events[1].progress - 0.25) < 1e-9)
        #expect(abs(events[2].progress - 0.29) < 1e-9)
        #expect(abs(events[3].progress - 0.40) < 1e-9)
        #expect(abs(events[4].progress - 0.65) < 1e-9)
        #expect(abs(events[5].progress - 0.85) < 1e-9)

        // Forward stepping from 0.0 walks every event, clears isSkippingIdle, then reaches 1.0 and pauses
        var state = ReplayPlaybackState(progress: 0.0, isPlaying: true, speed: .x1, isSkippingIdle: true)
        for expected in events {
            let jumped = state.stepToNextEvent(in: tl)
            #expect(jumped == expected)
            #expect(abs(state.progress - expected.progress) < 1e-9)
            #expect(state.isSkippingIdle == false)
            #expect(state.isPlaying == true)
        }
        let endJump = state.stepToNextEvent(in: tl)
        #expect(endJump == nil)
        #expect(state.progress == 1.0)
        #expect(state.isPlaying == false)

        // Backward stepping from 1.0 walks back in reverse order, then jumps to 0.0
        for expected in events.reversed() {
            state.isSkippingIdle = true
            let jumped = state.stepToPreviousEvent(in: tl)
            #expect(jumped == expected)
            #expect(abs(state.progress - expected.progress) < 1e-9)
            #expect(state.isSkippingIdle == false)
        }
        let startJump = state.stepToPreviousEvent(in: tl)
        #expect(startJump == nil)
        #expect(state.progress == 0.0)
    }

    @Test("ReplayPlaybackState.suggestedInitialProgress focuses first retry loop or beam")
    func suggestedInitialProgressHelper() {
        let retryTrack = ReplayTrack(
            id: "t1", name: "w1", roleLabel: "W", kind: .root, parentTrackId: nil, depth: 0,
            modelClass: .carbon,
            segments: [
                ReplaySegment(id: "s0", kind: .work, startSec: 0, endSec: 20, stepCount: 1),
                ReplaySegment(id: "s1", kind: .retryLoop, startSec: 40, endSec: 60, stepCount: 2, errorCount: 2, estimatedCostUSD: 0.5),
            ],
            totalTokens: 100, outputTokens: 20, estimatedCostUSD: 0.5, retryCount: 2, retryWasteUSD: 0.5
        )
        let tl = ReplayTimeline(
            id: "t1", title: "T", workspaceLabel: "W", topology: .solo, dateLabel: "2026-11-22",
            totalDurationSec: 100, tracks: [retryTrack], beams: [],
            totalCostUSD: 0.5, totalTokens: 100, retryWasteUSD: 0.5, retryWastePercent: 100,
            humanWaitSec: 0, humanWaitPercent: 0, totalRetryLoops: 1
        )
        #expect(abs(ReplayPlaybackState.suggestedInitialProgress(for: tl) - 0.50) < 1e-6)
    }
}
