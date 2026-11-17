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
}
