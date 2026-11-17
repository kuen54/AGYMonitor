import Foundation
import Testing
@testable import AGYCore

@Suite("Core_ModelClass")
struct ModelClassTests {

    @Test("CaseIterable display order and labels match Antigravity spec")
    func orderAndDisplayNames() {
        #expect(ModelClass.allCases == [.hydrogen, .carbon, .argon, .flash, .claude, .other])
        #expect(ModelClass.hydrogen.displayName == "Hydrogen")
        #expect(ModelClass.carbon.displayName == "Carbon")
        #expect(ModelClass.argon.displayName == "Argon")
        #expect(ModelClass.flash.displayName == "Flash")
        #expect(ModelClass.claude.displayName == "Claude")
        #expect(ModelClass.other.displayName == "Other")

        #expect(ModelClass.hydrogen.fullDisplayName == "Gemini Hydrogen")
        #expect(ModelClass.carbon.fullDisplayName == "Gemini Carbon")
        #expect(ModelClass.argon.fullDisplayName == "Gemini Argon")
        #expect(ModelClass.flash.fullDisplayName == "Gemini Flash")
        #expect(ModelClass.claude.fullDisplayName == "Claude")
        #expect(ModelClass.other.fullDisplayName == "Other")
    }

    @Test("Classifies all 22 live Antigravity model IDs and display labels")
    func classifyLiveCatalog() {
        // Hydrogen family
        for m in ["gemini-4-hydrogen-low", "gemini-4-hydrogen-medium", "gemini-4-hydrogen-high", "gemini-4-hydrogen-xhigh", "Gemini 4 Hydrogen (XHigh)"] {
            #expect(ModelClass.classify(m) == .hydrogen)
        }

        // Argon family — including gemini-pro-orchestrator-argon (argon checked BEFORE orchestrator!)
        for m in ["gemini-4-argon-low", "gemini-4-argon-medium", "gemini-4-argon-high", "gemini-pro-orchestrator-argon", "Orchestrator (Argon)"] {
            #expect(ModelClass.classify(m) == .argon)
        }

        // Carbon / Orchestrator / Gemini Pro / Ultra family
        for m in ["gemini-4-carbon-low", "gemini-4-carbon-medium", "gemini-4-carbon-high", "gemini-pro-orchestrator", "Orchestrator (Carbon)", "gemini-2.5-pro", "gemini-ultra"] {
            #expect(ModelClass.classify(m) == .carbon)
        }

        // Flash / Lite family
        for m in ["gemini-3.8-flash-low", "gemini-3.8-flash-medium", "gemini-3.8-flash-high", "gemini-2.5-flash-lite", "Gemini 3.8 Flash (High)"] {
            #expect(ModelClass.classify(m) == .flash)
        }

        // Claude partner models
        for m in ["claude-opus-5-5-low", "claude-opus-5-5-medium", "claude-opus-5-5-high", "claude-sonnet-5-5-medium", "Claude Haiku 4.5"] {
            #expect(ModelClass.classify(m) == .claude)
        }

        // Open / Other models
        for m in ["gpt-oss-120b-medium", "GPT-OSS 120B (Medium)", "custom-experimental", ""] {
            #expect(ModelClass.classify(m) == .other)
        }
    }

    @Test("parse(_:) accepts exact rawValues case-insensitively and rejects unknown strings")
    func parseExact() {
        #expect(ModelClass.parse("carbon") == .carbon)
        #expect(ModelClass.parse("HYDROGEN") == .hydrogen)
        #expect(ModelClass.parse("gemini-4-carbon-medium") == nil)
    }

    @Test("isGeminiFamily partitions Gemini vs Claude/Partner buckets")
    func geminiFamilyFlag() {
        #expect(ModelClass.hydrogen.isGeminiFamily == true)
        #expect(ModelClass.carbon.isGeminiFamily == true)
        #expect(ModelClass.argon.isGeminiFamily == true)
        #expect(ModelClass.flash.isGeminiFamily == true)
        #expect(ModelClass.claude.isGeminiFamily == false)
        #expect(ModelClass.other.isGeminiFamily == false)
    }
}
