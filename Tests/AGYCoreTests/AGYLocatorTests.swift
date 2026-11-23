import Foundation
import Testing
@testable import AGYCore

@Suite("Core_AGYLocator")
struct AGYLocatorTests {

    @Test("Resolves Antigravity surface roots, brain directories, and preferred transcript paths")
    func surfaceAndBrainPaths() {
        let home = "/Users/demo"
        let brains = AGYLocator.brainDirs(home: home)
        #expect(brains == [
            "/Users/demo/.gemini/antigravity-cli/brain",
            "/Users/demo/.gemini/antigravity/brain",
            "/Users/demo/.gemini/antigravity-ide/brain",
        ])

        let candidates = AGYLocator.candidateTranscriptPaths(
            home: home,
            conversationId: "abc-123",
            preferredSurface: "antigravity-ide"
        )
        #expect(candidates.first == "/Users/demo/.gemini/antigravity-ide/brain/abc-123/.system_generated/logs/transcript.jsonl")
        #expect(candidates.count == 3)

        #expect(AGYLocator.presenceLockPath(home: home, conversationId: "abc-123") ==
                "/Users/demo/.gemini/antigravity-cli/presence/abc-123.lock")
        #expect(AGYLocator.annotationPath(home: home, conversationId: "abc-123") ==
                "/Users/demo/.gemini/antigravity-cli/annotations/abc-123.pbtxt")
        #expect(AGYLocator.archiveDir(home: home) ==
                "/Users/demo/Library/Application Support/AGYMonitor/archive")
        #expect(AGYLocator.cacheDir(home: home) ==
                "/Users/demo/Library/Caches/AGYMonitor")
    }

    @Test("Builds candidate state.vscdb, agy binary paths, and WAL-safe SQLite read-only URIs")
    func stateDBAndSQLiteReadOnlyURIs() {
        let home = "/Users/demo"
        let dbs = AGYLocator.candidateStateVSCDBPaths(home: home)
        #expect(dbs == [
            "/Users/demo/Library/Application Support/Antigravity/User/globalStorage/state.vscdb",
            "/Users/demo/Library/Application Support/Antigravity IDE/User/globalStorage/state.vscdb",
        ])

        let uris = AGYLocator.sqliteReadOnlyURIs(forPath: dbs[1])
        #expect(uris == [
            "file:/Users/demo/Library/Application%20Support/Antigravity%20IDE/User/globalStorage/state.vscdb?mode=ro",
            "file:/Users/demo/Library/Application%20Support/Antigravity%20IDE/User/globalStorage/state.vscdb?mode=ro&immutable=1",
        ])

        let bins = AGYLocator.candidateAGYBinaryPaths(home: home, envPath: "/custom/bin:/opt/homebrew/bin")
        #expect(bins.first == "/custom/bin/agy")
        #expect(bins.contains("/Users/demo/.local/bin/agy"))
    }

    @Test("Resolves subagentsDir and deduplicated multi-surface conversationSummariesDBPaths")
    func subagentsDirAndMultiSurfaceSummariesDBPaths() {
        let home = "/Users/demo"

        #expect(
            AGYLocator.subagentsDir(
                brainDir: "/Users/demo/.gemini/antigravity-cli/brain",
                conversationId: "parent-123"
            ) == "/Users/demo/.gemini/antigravity-cli/brain/parent-123/.system_generated/subagents"
        )

        // Default: all 3 surfaces in AGYSurface.allCases order
        let defaultDBs = AGYLocator.conversationSummariesDBPaths(home: home)
        #expect(defaultDBs.count == 3)
        #expect(defaultDBs.map(\.surface) == [.cli, .desktop, .ide])
        #expect(defaultDBs.map(\.path) == [
            "/Users/demo/.gemini/antigravity-cli/conversation_summaries.db",
            "/Users/demo/.gemini/antigravity/conversation_summaries.db",
            "/Users/demo/.gemini/antigravity-ide/conversation_summaries.db",
        ])

        // Distinct envDataDir is prepended as .cli before the 3 standard surfaces
        let customDBs = AGYLocator.conversationSummariesDBPaths(home: home, envDataDir: "/custom/agy-data/")
        #expect(customDBs.count == 4)
        #expect(customDBs[0].surface == .cli)
        #expect(customDBs[0].path == "/custom/agy-data/conversation_summaries.db")
        #expect(customDBs.dropFirst().map(\.surface) == [.cli, .desktop, .ide])

        // envDataDir matching CLI root deduplicates by standardized path
        let dedupedDBs = AGYLocator.conversationSummariesDBPaths(
            home: home,
            envDataDir: "  /Users/demo/.gemini/antigravity-cli/  "
        )
        #expect(dedupedDBs.count == 3)
        #expect(dedupedDBs.map(\.surface) == [.cli, .desktop, .ide])
        #expect(dedupedDBs[0].path == "/Users/demo/.gemini/antigravity-cli/conversation_summaries.db")

        // Empty / whitespace envDataDir is ignored
        let blankEnvDBs = AGYLocator.conversationSummariesDBPaths(home: home, envDataDir: "   \n ")
        #expect(blankEnvDBs.count == 3)
        #expect(blankEnvDBs.map(\.path) == defaultDBs.map(\.path))
    }

    @Test("Validates safe conversation IDs and builds candidateAnnotationPaths & oauthCredsPaths")
    func safeConversationIdAnnotationAndOAuthPaths() {
        let home = "/Users/demo"

        // Safe IDs
        #expect(AGYLocator.isSafeConversationId("abc-123"))
        #expect(AGYLocator.isSafeConversationId("c4dbb06e-b69b-4244-9f28-9cff30589065"))
        #expect(AGYLocator.isSafeConversationId("conv_1.v2"))

        // Unsafe IDs: empty, traversal, slashes, NUL, leading dot, control chars
        for bad in ["", ".", "..", ".hidden", "../evil", "a/b", "a\\b", "a..b", "bad\0id", "bad\nid"] {
            #expect(!AGYLocator.isSafeConversationId(bad))
            #expect(AGYLocator.candidateAnnotationPaths(home: home, conversationId: bad).isEmpty)
            #expect(AGYLocator.candidateTranscriptPaths(home: home, conversationId: bad).isEmpty)
            #expect(AGYLocator.candidateConversationDBPaths(home: home, conversationId: bad).isEmpty)
        }

        // candidateAnnotationPaths spans all 3 surfaces (+ optional envDataDir first)
        let annots = AGYLocator.candidateAnnotationPaths(home: home, conversationId: "abc-123")
        #expect(annots == [
            "/Users/demo/.gemini/antigravity-cli/annotations/abc-123.pbtxt",
            "/Users/demo/.gemini/antigravity/annotations/abc-123.pbtxt",
            "/Users/demo/.gemini/antigravity-ide/annotations/abc-123.pbtxt",
        ])
        let annotsEnv = AGYLocator.candidateAnnotationPaths(
            home: home,
            conversationId: "abc-123",
            envDataDir: "/custom/agy"
        )
        #expect(annotsEnv.first == "/custom/agy/annotations/abc-123.pbtxt")
        #expect(annotsEnv.count == 4)

        // oauthCredsPaths checks ~/.gemini/oauth_creds.json then CLI surface
        #expect(AGYLocator.oauthCredsPaths(home: home) == [
            "/Users/demo/.gemini/oauth_creds.json",
            "/Users/demo/.gemini/antigravity-cli/oauth_creds.json",
        ])
    }
}
