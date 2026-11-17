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
}
