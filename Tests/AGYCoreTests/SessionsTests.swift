import Foundation
import Testing
@testable import AGYCore

@Suite("Core_Sessions")
struct SessionsTests {

    @Test("Parses lsof presence/<conv-id>.lock output in both -F field mode and table mode")
    func lsofPresenceModes() {
        let fieldOut = """
        p66525
        cagy
        fcwd
        n/Users/demo/Documents/mia
        f12
        n/Users/demo/.gemini/antigravity-cli/presence/4f462a45-a4ff-4943-a996-2c0d5220a665.lock
        p79958
        cagy
        fcwd
        n/Users/demo/Developer/My Project
        f9
        n/Users/demo/.gemini/antigravity-cli/presence/88c8ab2e-283a-4fc6-b2df-6171365a11f9.lock
        """
        let locks1 = SessionLogic.parseLsofPresence(fieldOut)
        #expect(locks1.count == 2)
        #expect(locks1[0].pid == 66525)
        #expect(locks1[0].conversationId == "4f462a45-a4ff-4943-a996-2c0d5220a665")
        #expect(locks1[0].cwd == "/Users/demo/Documents/mia")
        #expect(locks1[1].cwd == "/Users/demo/Developer/My Project")

        let tableOut = """
        COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF    NODE NAME
        agy     66525 demo  cwd    DIR   1,15     1472 1234567 /Users/demo/Documents/My Repo
        agy     66525 demo  12u    REG   1,15        0 7654321 /Users/demo/.gemini/antigravity-cli/presence/4f462a45-a4ff-4943-a996-2c0d5220a665.lock
        """
        let locks2 = SessionLogic.parseLsofPresence(tableOut)
        #expect(locks2.count == 1)
        #expect(locks2[0].pid == 66525)
        #expect(locks2[0].cwd == "/Users/demo/Documents/My Repo")
        #expect(locks2[0].conversationId == "4f462a45-a4ff-4943-a996-2c0d5220a665")
    }

    @Test("Parses conversation_metadata.json, filters 0001-01-01 sentinels, and hides swarm workers")
    func conversationMetadataAndVisibility() throws {
        let json = """
        {
          "conversations": {
            "worker-uuid": {
              "is_internal": true,
              "last_modified_time": "2026-11-16T19:52:50.623324036+08:00"
            },
            "empty-uuid": {
              "summary": {
                "ID": "empty-uuid",
                "Title": "",
                "Preview": "",
                "NumSteps": 0,
                "UpdatedAt": "0001-01-01T00:00:00Z",
                "WorkspaceURIs": ["file:///Users/demo"],
                "AppDataDir": "antigravity-cli",
                "Internal": false
              },
              "is_internal": false,
              "last_modified_time": "2026-11-16T15:20:06.616886903+08:00"
            },
            "user-uuid": {
              "summary": {
                "ID": "user-uuid",
                "Title": "Build AGYMonitor",
                "Preview": "Implement Core_QuotaParser",
                "NumSteps": 24,
                "UpdatedAt": "2026-11-16T11:49:08.816501Z",
                "WorkspaceURIs": ["file:///Users/demo/My%20Project"],
                "AppDataDir": "antigravity-cli",
                "Internal": false
              },
              "is_internal": false,
              "last_modified_time": "2026-11-16T19:51:04.433025865+08:00"
            }
          }
        }
        """

        let metas = SessionLogic.parseConversationMetadataJSON(Data(json.utf8))
        #expect(metas.count == 3)

        let worker = try #require(metas["worker-uuid"])
        #expect(SessionLogic.isSubagentOrInternal(worker) == true)
        #expect(SessionLogic.isUserVisibleConversation(worker, hasLiveLock: true) == false)

        let empty = try #require(metas["empty-uuid"])
        #expect(empty.updatedAt == nil)
        #expect(SessionLogic.isUserVisibleConversation(empty, hasLiveLock: false) == false)
        // If actively held open in a live terminal right now, allow showing it
        #expect(SessionLogic.isUserVisibleConversation(empty, hasLiveLock: true) == true)

        let user = try #require(metas["user-uuid"])
        #expect(user.primaryWorkspace == "/Users/demo/My Project")
        #expect(SessionLogic.isUserVisibleConversation(user) == true)
    }

    @Test("Parses swarm/members.json and detects actively working swarm helpers")
    func swarmMembersParsing() throws {
        let raw = """
        {
          "title": "AGYMonitor",
          "members": {
            "core": {
              "conversation_id": "727871e8-2dd2-4f82-a590-0cd1475c6d7d",
              "role": "worker",
              "phase": "RUNNING",
              "wake_mode": "working",
              "killed": false,
              "applied_model": "gemini-4-carbon-medium"
            },
            "verifier": {
              "conversation_id": "11111111-2222-3333-4444-555555555555",
              "role": "worker",
              "phase": "RUNNING",
              "wake_mode": "mentions",
              "killed": false
            }
          }
        }
        """
        let parsed = try #require(SessionLogic.parseSwarmMembersJSON(Data(raw.utf8)))
        #expect(parsed.title == "AGYMonitor")
        #expect(parsed.members.count == 2)
        #expect(SessionLogic.anySwarmWorkerBusy(parsed.members) == true)
    }

    @Test("dedupBySessionId, grouped ordering, dotKind priority, and stepDoneUnseen reducer")
    func sessionGroupingDedupAndDoneUnseen() {
        let stale = SessionInfo(pid: 100, sessionId: "s1", cwd: "/repo/a", status: .busy, updatedAt: 1_000, entrypoint: "cli")
        let fresh = SessionInfo(pid: 200, sessionId: "s1", cwd: "/repo/a", status: .idle, updatedAt: 2_000, entrypoint: "cli")
        let busyOther = SessionInfo(pid: 300, sessionId: "s2", cwd: "/repo/b", status: .busy, updatedAt: 1_500, entrypoint: "cli")

        let deduped = SessionLogic.dedupBySessionId([stale, fresh, busyOther])
        #expect(deduped.count == 2)
        #expect(deduped.first(where: { $0.sessionId == "s1" })?.status == .idle)

        let groups = SessionLogic.grouped(deduped)
        // Busy group (/repo/b) sorts ahead of idle group (/repo/a)
        #expect(groups.map(\.cwd) == ["/repo/b", "/repo/a"])

        // Priority: busy > waiting > doneUnseen > grey
        #expect(SessionLogic.dotKind(status: .busy, doneUnseen: true) == .busy)
        #expect(SessionLogic.dotKind(status: .waiting, doneUnseen: true) == .waiting)
        #expect(SessionLogic.dotKind(status: .idle, doneUnseen: true) == .doneUnseen)
        #expect(SessionLogic.dotKind(status: .idle, doneUnseen: false) == .grey)

        // Done-unseen transition: s1 went .busy -> .idle, s2 still .busy
        let step1 = SessionLogic.stepDoneUnseen(
            prev: ["s1": .busy, "s2": .busy],
            current: deduped,
            doneUnseen: [:],
            seenAll: false,
            now: 500.0
        )
        #expect(step1.doneUnseen == ["s1": 500.0])

        // If s1 goes busy again, it auto-evicts from doneUnseen
        let reactivated = [
            SessionInfo(pid: 200, sessionId: "s1", cwd: "/repo/a", status: .busy, updatedAt: 3_000, entrypoint: "cli"),
            busyOther,
        ]
        let step2 = SessionLogic.stepDoneUnseen(
            prev: step1.prev,
            current: reactivated,
            doneUnseen: step1.doneUnseen,
            seenAll: false,
            now: 600.0
        )
        #expect(step2.doneUnseen.isEmpty)
    }

    @Test("Proc table ppid walk resolves Otty, Antigravity IDE, and tmux multiplexers")
    func procTargetResolution() {
        let psOut = """
          500     1 ??      /Applications/Otty.app/Contents/MacOS/Otty
          600   500 ttys003 /opt/homebrew/bin/tmux
          700   600 ttys003 -zsh
          800   700 ttys003 /Users/demo/.local/bin/agy
          900     1 ??      /Applications/Antigravity IDE.app/Contents/MacOS/Antigravity IDE
          950   900 ttys008 /Applications/Antigravity IDE.app/Contents/Resources/app/extensions/agy/bin/agy
        """
        let table = SessionLogic.parseProcTable(psOut)
        let ottyTarget = SessionLogic.resolveTarget(table: table, pid: 800)
        #expect(ottyTarget.pidPresent == true)
        #expect(ottyTarget.terminal == .otty)
        #expect(ottyTarget.multiplexed == true)
        #expect(ottyTarget.appBundlePath == "/Applications/Otty.app")
        #expect(SessionLogic.devTTY(ottyTarget.tty) == "/dev/ttys003")

        let ideTarget = SessionLogic.resolveTarget(table: table, pid: 950)
        #expect(ideTarget.terminal == .antigravity)
        #expect(ideTarget.appBundlePath == "/Applications/Antigravity IDE.app")
    }

    @Test("JumpRequestGate supersedes older requests and matchWeztermPaneId matches TTY JSON cleanly")
    func jumpRequestGateAndWeztermMatcher() {
        var gate = JumpRequestGate()
        let g1 = gate.beginRequest()
        #expect(gate.isLatest(g1))
        let g2 = gate.beginRequest()
        #expect(!gate.isLatest(g1))
        #expect(gate.isLatest(g2))

        let json = """
        [
          {"pane_id": 7, "tty_name": "/dev/ttys004"},
          {"pane_id": 12, "tty_name": "ttys009"}
        ]
        """
        #expect(SessionLogic.matchWeztermPaneId(devTTY: "/dev/ttys004", jsonString: json) == "7")
        #expect(SessionLogic.matchWeztermPaneId(devTTY: "/dev/ttys009", jsonString: json) == "12")
        #expect(SessionLogic.matchWeztermPaneId(devTTY: "/dev/ttys099", jsonString: json) == nil)
    }

    @Test("extractPresenceLockId validates presence lock paths and stays in parity with parseLsofPresence")
    func extractPresenceLockIdAndParity() {
        // Valid CLI presence lock paths
        #expect(
            SessionLogic.extractPresenceLockId(
                fromPath: "/Users/demo/.gemini/antigravity-cli/presence/4f462a45-a4ff-4943-a996-2c0d5220a665.lock"
            ) == "4f462a45-a4ff-4943-a996-2c0d5220a665"
        )
        #expect(
            SessionLogic.extractPresenceLockId(
                fromPath: "/Users/demo/My Project/.gemini/antigravity-cli/presence/conv_123-abc.lock"
            ) == "conv_123-abc"
        )
        #expect(
            SessionLogic.extractPresenceLockId(fromPath: "/presence/abc123.lock") == "abc123"
        )
        #expect(
            SessionLogic.extractPresenceLockId(
                fromPath: "  /Users/demo/.gemini/antigravity-cli/presence/trimmed-id.lock\n"
            ) == "trimmed-id"
        )

        // Non-lock and non-presence paths
        #expect(SessionLogic.extractPresenceLockId(fromPath: "/Users/demo/.gemini/antigravity-cli/presence/4f462a45.txt") == nil)
        #expect(SessionLogic.extractPresenceLockId(fromPath: "/Users/demo/.gemini/antigravity-cli/presence/4f462a45.lock.tmp") == nil)
        #expect(SessionLogic.extractPresenceLockId(fromPath: "/Users/demo/.gemini/antigravity-cli/presence/4f462a45.lock/") == nil)
        #expect(SessionLogic.extractPresenceLockId(fromPath: "/Users/demo/project/Cargo.lock") == nil)
        #expect(SessionLogic.extractPresenceLockId(fromPath: "/tmp/session.lock") == nil)
        #expect(SessionLogic.extractPresenceLockId(fromPath: "/Users/demo/mypresence/abc-123.lock") == nil)

        // Nested directories under /presence/
        #expect(
            SessionLogic.extractPresenceLockId(
                fromPath: "/Users/demo/.gemini/antigravity-cli/presence/nested/4f462a45-a4ff-4943-a996-2c0d5220a665.lock"
            ) == nil
        )
        #expect(SessionLogic.extractPresenceLockId(fromPath: "/presence/a/b/abc-123.lock") == nil)
        #expect(SessionLogic.extractPresenceLockId(fromPath: "/presence/../abc-123.lock") == nil)

        // Empty and malformed paths
        #expect(SessionLogic.extractPresenceLockId(fromPath: "") == nil)
        #expect(SessionLogic.extractPresenceLockId(fromPath: "   \n") == nil)
        #expect(SessionLogic.extractPresenceLockId(fromPath: "/presence/") == nil)
        #expect(SessionLogic.extractPresenceLockId(fromPath: "/presence/.lock") == nil)
        #expect(SessionLogic.extractPresenceLockId(fromPath: "/presence/.hidden.lock") == nil)
        #expect(SessionLogic.extractPresenceLockId(fromPath: "presence/abc-123.lock") == nil)
        #expect(SessionLogic.extractPresenceLockId(fromPath: "/presence/bad name.lock") == nil)
        #expect(SessionLogic.extractPresenceLockId(fromPath: "/presence/bad.id.lock") == nil)
        #expect(SessionLogic.extractPresenceLockId(fromPath: "/presence/bad$id.lock") == nil)

        // Parity with parseLsofPresence in both -F field mode and table mode
        let samplePaths = [
            "/Users/demo/.gemini/antigravity-cli/presence/11111111-2222-3333-4444-555555555555.lock",
            "/Users/demo/project/Cargo.lock",
            "/Users/demo/.gemini/antigravity-cli/presence/nested/66666666-7777-8888-9999-aaaaaaaaaaaa.lock",
            "/Users/demo/.gemini/antigravity-cli/presence/not-a-lock.txt",
            "/Users/demo/.gemini/antigravity-cli/presence/.hidden.lock",
            "/presence/direct_id-99.lock",
        ]
        let expectedIds = samplePaths.compactMap(SessionLogic.extractPresenceLockId(fromPath:))
        #expect(expectedIds == ["11111111-2222-3333-4444-555555555555", "direct_id-99"])

        var fieldLines = ["p4242", "cagy", "fcwd", "n/Users/demo/project"]
        for (idx, p) in samplePaths.enumerated() {
            fieldLines.append("f\(idx + 10)")
            fieldLines.append("n\(p)")
        }
        let fieldLocks = SessionLogic.parseLsofPresence(fieldLines.joined(separator: "\n"))
        #expect(fieldLocks.map(\.conversationId) == expectedIds)
        #expect(fieldLocks.allSatisfy { $0.cwd == "/Users/demo/project" && $0.pid == 4242 })

        var tableLines = [
            "COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF    NODE NAME",
            "agy      4242 demo  cwd    DIR   1,15     1472 1234567 /Users/demo/project",
        ]
        for (idx, p) in samplePaths.enumerated() {
            tableLines.append("agy      4242 demo  \(idx + 10)u    REG   1,15        0 765432\(idx) \(p)")
        }
        let tableLocks = SessionLogic.parseLsofPresence(tableLines.joined(separator: "\n"))
        #expect(tableLocks.map(\.conversationId) == expectedIds)
        #expect(tableLocks.allSatisfy { $0.cwd == "/Users/demo/project" && $0.pid == 4242 })
    }

    @Test("Parses subagent descriptor JSON and validates SubagentRecord.isAlive")
    func subagentRecordParsing() throws {
        let aliveJSON = """
        {
          "conversationId": "44f622bb-0d8d-4aef-9c29-0b3b020d48dd",
          "subagentDescriptor": {
            "typeName": "image-generator",
            "role": "Generate cover asset"
          },
          "state": "SUBAGENT_STATE_ALIVE",
          "spawnStepIndex": 511
        }
        """
        let alive = try #require(SessionLogic.parseSubagentRecordJSON(Data(aliveJSON.utf8)))
        #expect(alive.conversationId == "44f622bb-0d8d-4aef-9c29-0b3b020d48dd")
        #expect(alive.state == "SUBAGENT_STATE_ALIVE")
        #expect(alive.typeName == "image-generator")
        #expect(alive.role == "Generate cover asset")
        #expect(alive.isAlive == true)

        let deadJSON = """
        {
          "conversationId": "dead-sub-1",
          "state": "SUBAGENT_STATE_DEAD"
        }
        """
        let dead = try #require(SessionLogic.parseSubagentRecordJSON(Data(deadJSON.utf8)))
        #expect(dead.conversationId == "dead-sub-1")
        #expect(dead.typeName == nil)
        #expect(dead.role == nil)
        #expect(dead.isAlive == false)

        // Case-insensitive isAlive check
        let lowercaseAlive = SubagentRecord(conversationId: "sub-2", state: "subagent_state_alive")
        #expect(lowercaseAlive.isAlive == true)

        // Rejects empty/missing conversationId and invalid JSON
        let emptyIdJSON = #"{"conversationId":"   ","state":"SUBAGENT_STATE_ALIVE"}"#
        let missingIdJSON = #"{"state":"SUBAGENT_STATE_ALIVE"}"#
        #expect(SessionLogic.parseSubagentRecordJSON(Data(emptyIdJSON.utf8)) == nil)
        #expect(SessionLogic.parseSubagentRecordJSON(Data(missingIdJSON.utf8)) == nil)
        #expect(SessionLogic.parseSubagentRecordJSON(Data("not json".utf8)) == nil)
    }

    @Test("resolveRootAncestor walks multi-depth parent chains safely with cycle and depth guards")
    func resolveRootAncestorChainsAndCycles() {
        // Direct root
        #expect(SessionLogic.resolveRootAncestor(for: "root", parentById: [:]) == "root")

        // Multi-depth D3 -> D2 -> D1 -> D0
        let chain = [
            "d3": "d2",
            "d2": "d1",
            "d1": "d0",
        ]
        #expect(SessionLogic.resolveRootAncestor(for: "d3", parentById: chain) == "d0")
        #expect(SessionLogic.resolveRootAncestor(for: "d2", parentById: chain) == "d0")
        #expect(SessionLogic.resolveRootAncestor(for: "d0", parentById: chain) == "d0")

        // Empty parent stops cleanly
        #expect(SessionLogic.resolveRootAncestor(for: "d2", parentById: ["d2": "d1", "d1": "   "]) == "d1")

        // Self-cycle and 2/3-node cycles terminate without infinite recursion
        #expect(SessionLogic.resolveRootAncestor(for: "a", parentById: ["a": "a"]) == "a")
        #expect(SessionLogic.resolveRootAncestor(for: "a", parentById: ["a": "b", "b": "a"]) == "b")
        #expect(SessionLogic.resolveRootAncestor(for: "a", parentById: ["a": "b", "b": "c", "c": "b"]) == "c")

        // maxDepth bound
        let deep = ["n4": "n3", "n3": "n2", "n2": "n1", "n1": "n0"]
        #expect(SessionLogic.resolveRootAncestor(for: "n4", parentById: deep, maxDepth: 2) == "n2")
        #expect(SessionLogic.resolveRootAncestor(for: "n4", parentById: deep, maxDepth: 0) == "n4")
    }

    @Test("isSubagentActivelyGenerating respects killed override, running signals, and alive-descriptor heuristics")
    func subagentActivelyGeneratingHeuristics() {
        let now = 1_700_000_000.0

        let runningSummary = TranscriptSummary(
            title: nil,
            instruction: nil,
            lastStepType: .plannerResponse,
            lastStepStatus: .running,
            lastStepAt: Date(timeIntervalSince1970: now - 2.0)
        )
        let errorSummary = TranscriptSummary(
            title: nil,
            instruction: nil,
            lastStepType: .plannerResponse,
            lastStepStatus: .error,
            lastStepAt: Date(timeIntervalSince1970: now - 5.0)
        )
        let pendingToolRecent = TranscriptSummary(
            title: nil,
            instruction: nil,
            lastStepType: .plannerResponse,
            lastStepStatus: .done,
            lastStepAt: Date(timeIntervalSince1970: now - 120.0),
            pendingToolNames: ["run_command"]
        )
        let pendingToolStale = TranscriptSummary(
            title: nil,
            instruction: nil,
            lastStepType: .plannerResponse,
            lastStepStatus: .done,
            lastStepAt: Date(timeIntervalSince1970: now - 240.0),
            pendingToolNames: ["run_command"]
        )
        let recentSampleSummary = TranscriptSummary(
            title: nil,
            instruction: nil,
            lastStepType: .plannerResponse,
            lastStepStatus: .done,
            lastStepAt: Date(timeIntervalSince1970: now - 20.0),
            recentOutputSamples: [OutputTokenSample(stepIndex: 1, timestamp: now - 20.0, outputTokens: 400)]
        )
        let staleSampleSummary = TranscriptSummary(
            title: nil,
            instruction: nil,
            lastStepType: .plannerResponse,
            lastStepStatus: .done,
            lastStepAt: Date(timeIntervalSince1970: now - 60.0),
            recentOutputSamples: [OutputTokenSample(stepIndex: 1, timestamp: now - 60.0, outputTokens: 400)]
        )

        // 1. Killed overrides every positive signal
        #expect(SessionLogic.isSubagentActivelyGenerating(
            rawStatus: "CASCADE_RUN_STATUS_RUNNING",
            notFullyIdle: true,
            killed: true,
            isAliveDescriptor: true,
            transcriptSummary: runningSummary,
            transcriptFileMtime: now - 1.0,
            now: now
        ) == false)

        // 2. Direct active signals (notFullyIdle, RUNNING status, .running step)
        #expect(SessionLogic.isSubagentActivelyGenerating(
            rawStatus: nil,
            notFullyIdle: true,
            killed: false,
            isAliveDescriptor: false,
            transcriptSummary: nil,
            transcriptFileMtime: nil,
            now: now
        ) == true)

        #expect(SessionLogic.isSubagentActivelyGenerating(
            rawStatus: "CASCADE_RUN_STATUS_RUNNING",
            notFullyIdle: false,
            killed: false,
            isAliveDescriptor: false,
            transcriptSummary: nil,
            transcriptFileMtime: nil,
            now: now
        ) == true)

        #expect(SessionLogic.isSubagentActivelyGenerating(
            rawStatus: "CASCADE_RUN_STATUS_IDLE",
            notFullyIdle: false,
            killed: false,
            isAliveDescriptor: false,
            transcriptSummary: runningSummary,
            transcriptFileMtime: nil,
            now: now
        ) == true)

        // 3. Alive descriptor heuristics: recent transcript write (excluding .error)
        #expect(SessionLogic.isSubagentActivelyGenerating(
            rawStatus: "CASCADE_RUN_STATUS_IDLE",
            notFullyIdle: false,
            killed: false,
            isAliveDescriptor: true,
            transcriptSummary: nil,
            transcriptFileMtime: now - 35.0,
            now: now
        ) == true)

        #expect(SessionLogic.isSubagentActivelyGenerating(
            rawStatus: "CASCADE_RUN_STATUS_IDLE",
            notFullyIdle: false,
            killed: false,
            isAliveDescriptor: true,
            transcriptSummary: errorSummary,
            transcriptFileMtime: now - 5.0,
            now: now
        ) == false)

        #expect(SessionLogic.isSubagentActivelyGenerating(
            rawStatus: "CASCADE_RUN_STATUS_IDLE",
            notFullyIdle: false,
            killed: false,
            isAliveDescriptor: true,
            transcriptSummary: nil,
            transcriptFileMtime: now - 36.0,
            now: now
        ) == false)

        // 4. Alive descriptor: pending tool within 180s vs stale
        #expect(SessionLogic.isSubagentActivelyGenerating(
            rawStatus: nil,
            notFullyIdle: false,
            killed: false,
            isAliveDescriptor: true,
            transcriptSummary: pendingToolRecent,
            transcriptFileMtime: now - 120.0,
            now: now
        ) == true)

        #expect(SessionLogic.isSubagentActivelyGenerating(
            rawStatus: nil,
            notFullyIdle: false,
            killed: false,
            isAliveDescriptor: true,
            transcriptSummary: pendingToolStale,
            transcriptFileMtime: now - 240.0,
            now: now
        ) == false)

        // 5. Alive descriptor: recent output sample within 35s vs stale zombie
        #expect(SessionLogic.isSubagentActivelyGenerating(
            rawStatus: nil,
            notFullyIdle: false,
            killed: false,
            isAliveDescriptor: true,
            transcriptSummary: recentSampleSummary,
            transcriptFileMtime: now - 100.0,
            now: now
        ) == true)

        #expect(SessionLogic.isSubagentActivelyGenerating(
            rawStatus: nil,
            notFullyIdle: false,
            killed: false,
            isAliveDescriptor: true,
            transcriptSummary: staleSampleSummary,
            transcriptFileMtime: now - 60.0,
            now: now
        ) == false)

        // 6. Non-alive descriptor ignores mtime / pending / recent-sample heuristics
        #expect(SessionLogic.isSubagentActivelyGenerating(
            rawStatus: "CASCADE_RUN_STATUS_IDLE",
            notFullyIdle: false,
            killed: false,
            isAliveDescriptor: false,
            transcriptSummary: recentSampleSummary,
            transcriptFileMtime: now - 2.0,
            now: now
        ) == false)

        // 7. Crashed/abandoned RUNNING / notFullyIdle / .running rows with stale transcript are rejected
        let crashedDoneSummary = TranscriptSummary(
            title: nil,
            instruction: nil,
            lastStepType: .plannerResponse,
            lastStepStatus: .done,
            lastStepAt: Date(timeIntervalSince1970: now - 1200.0),
            recentOutputSamples: [OutputTokenSample(stepIndex: 1, timestamp: now - 1200.0, outputTokens: 400)]
        )
        let crashedRunningSummary = TranscriptSummary(
            title: nil,
            instruction: nil,
            lastStepType: .plannerResponse,
            lastStepStatus: .running,
            lastStepAt: Date(timeIntervalSince1970: now - 3600.0)
        )
        #expect(SessionLogic.isSubagentActivelyGenerating(
            rawStatus: "CASCADE_RUN_STATUS_RUNNING",
            notFullyIdle: true,
            killed: false,
            isAliveDescriptor: true,
            transcriptSummary: crashedDoneSummary,
            transcriptFileMtime: now - 1200.0,
            now: now,
            hasLiveRoot: true,
            metaUpdatedAt: now - 10.0
        ) == false)

        #expect(SessionLogic.isSubagentActivelyGenerating(
            rawStatus: "CASCADE_RUN_STATUS_IDLE",
            notFullyIdle: false,
            killed: false,
            isAliveDescriptor: false,
            transcriptSummary: crashedRunningSummary,
            transcriptFileMtime: now - 3600.0,
            now: now
        ) == false)

        // 8. Live subagent with stale/sentinel SQLite updatedAt BUT fresh transcript still counts
        #expect(SessionLogic.isSubagentActivelyGenerating(
            rawStatus: "CASCADE_RUN_STATUS_RUNNING",
            notFullyIdle: true,
            killed: false,
            isAliveDescriptor: true,
            transcriptSummary: recentSampleSummary,
            transcriptFileMtime: now - 25.0,
            now: now,
            hasLiveRoot: true,
            metaUpdatedAt: now - 35_000.0
        ) == true)

        // 9. No transcript yet: allowed with live root or fresh metaUpdatedAt; rejected when orphaned & stale
        #expect(SessionLogic.isSubagentActivelyGenerating(
            rawStatus: "CASCADE_RUN_STATUS_RUNNING",
            notFullyIdle: true,
            killed: false,
            isAliveDescriptor: false,
            transcriptSummary: nil,
            transcriptFileMtime: nil,
            now: now,
            hasLiveRoot: false,
            metaUpdatedAt: now - 3600.0
        ) == false)

        #expect(SessionLogic.isSubagentActivelyGenerating(
            rawStatus: "CASCADE_RUN_STATUS_RUNNING",
            notFullyIdle: true,
            killed: false,
            isAliveDescriptor: false,
            transcriptSummary: nil,
            transcriptFileMtime: nil,
            now: now,
            hasLiveRoot: false,
            metaUpdatedAt: now - 60.0
        ) == true)

        // 10. Orphan freshness gate rejects stale/missing/error transcripts and accepts fresh output
        #expect(SessionLogic.isOrphanSubagentFresh(
            transcriptSummary: recentSampleSummary,
            transcriptFileMtime: now - 400.0,
            now: now
        ) == true)
        #expect(SessionLogic.isOrphanSubagentFresh(
            transcriptSummary: nil,
            transcriptFileMtime: now - 120.0,
            now: now
        ) == true)
        #expect(SessionLogic.isOrphanSubagentFresh(
            transcriptSummary: errorSummary,
            transcriptFileMtime: now - 5.0,
            now: now
        ) == false)
        #expect(SessionLogic.isOrphanSubagentFresh(
            transcriptSummary: crashedDoneSummary,
            transcriptFileMtime: now - 600.0,
            now: now
        ) == false)
        #expect(SessionLogic.isOrphanSubagentFresh(
            transcriptSummary: nil,
            transcriptFileMtime: nil,
            now: now
        ) == false)

        // 11. Long-turn DB generating step (status == 8) & dbActivityMtime support
        // Live DB generating step keeps subagent active through 1800s even with stale transcript
        #expect(SessionLogic.isSubagentActivelyGenerating(
            rawStatus: "CASCADE_RUN_STATUS_IDLE",
            notFullyIdle: false,
            killed: false,
            isAliveDescriptor: false,
            transcriptSummary: crashedDoneSummary,
            transcriptFileMtime: now - 1200.0,
            now: now,
            hasLiveGeneratingDBStep: true,
            dbActivityMtime: now - 1500.0
        ) == true)

        // Killed still overrides live DB generating step
        #expect(SessionLogic.isSubagentActivelyGenerating(
            rawStatus: "CASCADE_RUN_STATUS_IDLE",
            notFullyIdle: false,
            killed: true,
            isAliveDescriptor: true,
            transcriptSummary: nil,
            transcriptFileMtime: nil,
            now: now,
            hasLiveGeneratingDBStep: true,
            dbActivityMtime: now - 5.0
        ) == false)

        // Hung DB generating step (> 1800s) is rejected
        #expect(SessionLogic.isSubagentActivelyGenerating(
            rawStatus: "CASCADE_RUN_STATUS_IDLE",
            notFullyIdle: false,
            killed: false,
            isAliveDescriptor: false,
            transcriptSummary: nil,
            transcriptFileMtime: nil,
            now: now,
            hasLiveGeneratingDBStep: true,
            dbActivityMtime: now - 1850.0
        ) == false)

        // Fresh dbActivityMtime satisfies RUNNING / notFullyIdle recency when transcript lags
        #expect(SessionLogic.isSubagentActivelyGenerating(
            rawStatus: "CASCADE_RUN_STATUS_RUNNING",
            notFullyIdle: true,
            killed: false,
            isAliveDescriptor: true,
            transcriptSummary: crashedDoneSummary,
            transcriptFileMtime: now - 1200.0,
            now: now,
            hasLiveGeneratingDBStep: false,
            dbActivityMtime: now - 15.0
        ) == true)

        // Orphan freshness accepts dbActivityMtime <= 300s and live DB generating step <= 600s, rejects > 600s
        #expect(SessionLogic.isOrphanSubagentFresh(
            transcriptSummary: nil,
            transcriptFileMtime: nil,
            now: now,
            hasLiveGeneratingDBStep: false,
            dbActivityMtime: now - 250.0
        ) == true)
        #expect(SessionLogic.isOrphanSubagentFresh(
            transcriptSummary: errorSummary,
            transcriptFileMtime: nil,
            now: now,
            hasLiveGeneratingDBStep: false,
            dbActivityMtime: now - 10.0
        ) == false)
        #expect(SessionLogic.isOrphanSubagentFresh(
            transcriptSummary: nil,
            transcriptFileMtime: nil,
            now: now,
            hasLiveGeneratingDBStep: true,
            dbActivityMtime: now - 550.0
        ) == true)
        #expect(SessionLogic.isOrphanSubagentFresh(
            transcriptSummary: nil,
            transcriptFileMtime: nil,
            now: now,
            hasLiveGeneratingDBStep: true,
            dbActivityMtime: now - 650.0
        ) == false)
    }

    @Test("Cross-surface SQLite merge preserves live CLI RUNNING/killed state over newer Desktop mirrors and accepts sentinel subagent timestamps")
    func crossSurfaceMergeAndSentinelSubagentProbe() {
        let nowMs: Double = 1_795_405_000_000

        // Real-world conflict: CLI DB reports newly spawned subagent RUNNING with sentinel 0001-01-01 (nil),
        // while Desktop DB passively mirrors it as IDLE with CORTEX_TRAJECTORY_SOURCE_CLI and newer updatedAtMs.
        let cliSubagent = SessionLogic.SurfaceConversationSummary(
            id: "sub-b4dc",
            title: "",
            preview: "",
            stepCount: 0,
            updatedAtMs: nil,
            cwd: "/Users/test/repo",
            rawStatus: "CASCADE_RUN_STATUS_RUNNING",
            notFullyIdle: true,
            killed: false,
            isInternal: true,
            parentConversationId: "coord-7d4b",
            appDataDir: "antigravity-cli",
            source: "",
            dbSurface: "antigravity-cli"
        )
        let desktopMirror = SessionLogic.SurfaceConversationSummary(
            id: "sub-b4dc",
            title: "Polisher",
            preview: "Polishing slides",
            stepCount: 57,
            updatedAtMs: nowMs - 2_000,
            cwd: "/Users/test/repo",
            rawStatus: "CASCADE_RUN_STATUS_IDLE",
            notFullyIdle: false,
            killed: false,
            isInternal: true,
            parentConversationId: "coord-7d4b",
            appDataDir: "antigravity",
            source: "CORTEX_TRAJECTORY_SOURCE_CLI",
            dbSurface: "antigravity"
        )

        // Order-independent: CLI authoritative lifecycle ALWAYS wins over Desktop passive mirror
        for merged in [
            SessionLogic.mergeConversationSummaryRows(cliSubagent, desktopMirror),
            SessionLogic.mergeConversationSummaryRows(desktopMirror, cliSubagent),
        ] {
            #expect(merged.rawStatus == "CASCADE_RUN_STATUS_RUNNING")
            #expect(merged.notFullyIdle == true)
            #expect(merged.killed == false)
            #expect(merged.appDataDir == "antigravity-cli")
            #expect(merged.stepCount == 57)
            #expect(merged.title == "Polisher")
            #expect(merged.updatedAtMs == nowMs - 2_000)
        }

        // Killed worker in CLI DB must NEVER be resurrected by killed=false Desktop mirror
        let cliKilled = SessionLogic.SurfaceConversationSummary(
            id: "sub-5758",
            title: "QA",
            preview: "",
            stepCount: 159,
            updatedAtMs: nowMs - 10_000,
            cwd: "/Users/test/repo",
            rawStatus: "CASCADE_RUN_STATUS_IDLE",
            notFullyIdle: false,
            killed: true,
            isInternal: true,
            parentConversationId: "coord-7d4b",
            appDataDir: "antigravity-cli",
            source: "",
            dbSurface: "antigravity-cli"
        )
        let desktopUnkilledMirror = SessionLogic.SurfaceConversationSummary(
            id: "sub-5758",
            title: "QA",
            preview: "",
            stepCount: 159,
            updatedAtMs: nowMs - 5_000,
            cwd: "/Users/test/repo",
            rawStatus: "CASCADE_RUN_STATUS_IDLE",
            notFullyIdle: false,
            killed: false,
            isInternal: true,
            parentConversationId: "coord-7d4b",
            appDataDir: "antigravity",
            source: "CORTEX_TRAJECTORY_SOURCE_CLI",
            dbSurface: "antigravity"
        )
        let mergedKilled = SessionLogic.mergeConversationSummaryRows(desktopUnkilledMirror, cliKilled)
        #expect(mergedKilled.killed == true)

        // Symmetric mirror check: a CLI DB passive mirror (dbSurface=antigravity-cli, appDataDir=antigravity)
        // must never clobber a live Desktop RUNNING row even when its updatedAtMs is newer.
        let desktopLive = SessionLogic.SurfaceConversationSummary(
            id: "desk-1",
            title: "Desktop Task",
            preview: "",
            stepCount: 10,
            updatedAtMs: nowMs - 8_000,
            cwd: "/Users/test/repo",
            rawStatus: "CASCADE_RUN_STATUS_RUNNING",
            notFullyIdle: true,
            killed: false,
            isInternal: false,
            parentConversationId: "",
            appDataDir: "antigravity",
            source: "",
            dbSurface: "antigravity"
        )
        let cliMirrorOfDesktop = SessionLogic.SurfaceConversationSummary(
            id: "desk-1",
            title: "Desktop Task",
            preview: "",
            stepCount: 12,
            updatedAtMs: nowMs - 1_000,
            cwd: "/Users/test/repo",
            rawStatus: "",
            notFullyIdle: false,
            killed: false,
            isInternal: false,
            parentConversationId: "",
            appDataDir: "antigravity",
            source: "",
            dbSurface: "antigravity-cli"
        )
        #expect(cliMirrorOfDesktop.isCrossSurfaceMirror == true)
        #expect(desktopLive.isCrossSurfaceMirror == false)
        for merged in [
            SessionLogic.mergeConversationSummaryRows(desktopLive, cliMirrorOfDesktop),
            SessionLogic.mergeConversationSummaryRows(cliMirrorOfDesktop, desktopLive),
        ] {
            #expect(merged.rawStatus == "CASCADE_RUN_STATUS_RUNNING")
            #expect(merged.notFullyIdle == true)
            #expect(merged.appDataDir == "antigravity")
            #expect(merged.stepCount == 12)
        }

        // Sentinel 0001-01-01 (updatedAtMs == nil) RUNNING subagent is probed; stale (>15m) is skipped
        #expect(SessionLogic.shouldProbeRunningSubagentMeta(updatedAtMs: nil, nowMs: nowMs) == true)
        #expect(SessionLogic.shouldProbeRunningSubagentMeta(updatedAtMs: nowMs - 60_000, nowMs: nowMs) == true)
        #expect(SessionLogic.shouldProbeRunningSubagentMeta(updatedAtMs: nowMs - 20 * 60_000, nowMs: nowMs) == false)
    }

    @Test("devTTY enforces strict allowlist and AppleScript builders escape backslashes and strip quotes/controls")
    func devTTYAllowlistAndAppleScriptSanitization() {
        // Allowed TTY patterns
        #expect(SessionLogic.devTTY("ttys004") == "/dev/ttys004")
        #expect(SessionLogic.devTTY("/dev/ttys004") == "/dev/ttys004")
        #expect(SessionLogic.devTTY("tty_usb0") == "/dev/tty_usb0")
        #expect(SessionLogic.devTTY("pts/12") == "/dev/pts/12")
        #expect(SessionLogic.devTTY("/dev/pts/0") == "/dev/pts/0")
        #expect(SessionLogic.devTTY("console") == "/dev/console")
        #expect(SessionLogic.devTTY("/dev/console") == "/dev/console")

        // Disallowed TTY patterns
        for bad in [nil, "", "??", "tty", "pts/", "pts/abc", "/dev/tty/foo", "../etc/passwd", "ttys004\" & do shell script \"id", "ttys004\n", "s004"] {
            #expect(SessionLogic.devTTY(bad) == nil)
        }

        // AppleScript sanitization escapes \ and strips " and control characters (< 0x20, 0x7F)
        let malicious = "/dev/ttys004\\\" \n\r\t\u{00}\u{7F}& do shell script \"id"
        let termScript = SessionLogic.appleTerminalFocusScript(devTTY: malicious)
        let itermScript = SessionLogic.itermFocusScript(devTTY: malicious)
        let expectedLiteral = "if tty of t is \"/dev/ttys004\\\\ & do shell script id\" then"
        let expectedItermLiteral = "if tty of s is \"/dev/ttys004\\\\ & do shell script id\" then"
        #expect(termScript.contains(expectedLiteral))
        #expect(itermScript.contains(expectedItermLiteral))
        #expect(!termScript.contains("\u{00}") && !termScript.contains("\u{7F}"))
        #expect(!itermScript.contains("\u{00}") && !itermScript.contains("\u{7F}"))
    }
}
