import Foundation
import Testing
@testable import AGYCore

@Suite("Core_Transcript")
struct TranscriptTests {

    @Test("Extracts clean prompt inside <USER_REQUEST> and strips Antigravity metadata tags")
    func extractUserRequestFromAGYStep() throws {
        let line = #"""
        {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-11-16T11:46:38Z","content":"<USER_REQUEST>\n请你检查一下这个仓库的架构与核心模块\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nThe current local time is: 2026-11-16T19:46:38+08:00.\n</ADDITIONAL_METADATA>\n<USER_SETTINGS_CHANGE>\nChanged model to Carbon.\n</USER_SETTINGS_CHANGE>"}
        """#

        let step = try #require(TranscriptParse.parseStep(line))
        #expect(step.type == .userInput)
        #expect(step.status == .done)
        #expect(step.userInstruction == "请你检查一下这个仓库的架构与核心模块")
        #expect(step.createdAt != nil)
    }

    @Test("Tracks PLANNER_RESPONSE tokens, multi-tool completion, and ask_question waiting state")
    func scanPlannerResponseAndAskQuestion() {
        let transcript = """
        {"step_index":0,"source":"SYSTEM","type":"SYSTEM_MESSAGE","status":"DONE","created_at":"2026-11-16T12:00:00Z","content":"<SYSTEM_MESSAGE>init</SYSTEM_MESSAGE>"}
        {"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-11-16T12:00:01Z","content":"<USER_REQUEST>Refactor quota parser</USER_REQUEST>"}
        {"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-16T12:00:05Z","model":"gemini-4-carbon-medium","input_tokens":5939,"cache_read_tokens":13476,"output_tokens":596,"tool_calls":[{"name":"read_file","args":{}},{"name":"ask_question","args":{}}]}
        {"step_index":3,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"2026-11-16T12:00:06Z","content":"file contents"}
        """

        let summary = TranscriptParse.scan(text: transcript)
        #expect(summary.instruction == "Refactor quota parser")
        #expect(summary.lastModel == "gemini-4-carbon-medium")
        #expect(summary.isWaitingForQuestion == true)
        #expect(summary.pendingToolNames == ["ask_question"])

        let now = AppDate.parseISO8601("2026-11-16T12:00:10Z")!
        let inferred = summary.inferredStatus(now: now)
        #expect(inferred.status == .waiting)
        #expect(inferred.waitingFor == "input needed")

        // Once the second tool output lands and final PLANNER_RESPONSE finishes with no tool_calls -> idle
        let finishedTranscript = transcript + "\n" + """
        {"step_index":4,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"2026-11-16T12:01:00Z","content":"answered"}
        {"step_index":5,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-16T12:01:05Z","model":"gemini-4-carbon-medium","input_tokens":800,"cache_read_tokens":19415,"output_tokens":210}
        """
        let doneSummary = TranscriptParse.scan(text: finishedTranscript)
        #expect(doneSummary.isWaitingForQuestion == false)
        #expect(doneSummary.pendingToolNames.isEmpty)
        #expect(doneSummary.inferredStatus(now: now).status == .idle)
    }

    @Test("Filters 0001-01-01 sentinel dates on steps and detects RUNNING status")
    func runningStepAndSentinelDate() throws {
        let line = #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"RUNNING","created_at":"0001-01-01T00:00:00Z","model":"gemini-4-hydrogen-high"}"#
        let step = try #require(TranscriptParse.parseStep(line))
        #expect(step.createdAt == nil)
        #expect(step.status == .running)

        let sum = TranscriptParse.scan(text: line)
        #expect(sum.inferredStatus().status == .busy)
    }

    @Test("Parses annotations/<conv-id>.pbtxt titles including UTF-8 octal escapes")
    func annotationPbtxtTitle() {
        let ascii = #"title:"Understanding Project Structure And Files""#
        #expect(TranscriptParse.parseAnnotationTitle(ascii) == "Understanding Project Structure And Files")

        // "\344\270\255\346\226\207" == UTF-8 bytes of "中文"
        let octal = #"title: "\344\270\255\346\226\207 Title \"Quoted\"""#
        #expect(TranscriptParse.parseAnnotationTitle(octal) == #"中文 Title "Quoted""#)
    }

    @Test("Handles SYSTEM_MESSAGE followup with/without tools, >600s rejection, <1.0s nil duration, clock skew, and sentinel fileMtime")
    func outputSampleDurationInferenceEdgeCases() throws {
        // 1. SYSTEM_MESSAGE after tool-calling PLANNER_RESPONSE closes sample & computes duration
        let sysWithTools = """
        {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-23T04:00:00Z","model":"gemini-4-carbon-high","output_tokens":900,"tool_calls":[{"name":"run_command"}]}
        {"step_index":2,"source":"SYSTEM","type":"SYSTEM_MESSAGE","status":"DONE","created_at":"2026-11-23T04:00:15Z","content":"tool output"}
        """
        let sumWithTools = TranscriptParse.scan(text: sysWithTools)
        let sWithTools = try #require(sumWithTools.recentOutputSamples.last)
        let t15 = try #require(AppDate.parseISO8601("2026-11-23T04:00:15Z")).timeIntervalSince1970
        #expect(abs(sWithTools.timestamp - t15) < 1e-6)
        #expect(abs((sWithTools.durationSeconds ?? 0) - 15.0) < 1e-6)

        // 2. SYSTEM_MESSAGE after tool-LESS PLANNER_RESPONSE must NOT close sample or invent duration
        let sysWithoutTools = """
        {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-23T04:00:00Z","model":"gemini-4-carbon-high","output_tokens":900}
        {"step_index":2,"source":"SYSTEM","type":"SYSTEM_MESSAGE","status":"DONE","created_at":"2026-11-23T04:00:15Z","content":"background notice"}
        """
        let sumWithoutTools = TranscriptParse.scan(text: sysWithoutTools)
        let sWithoutTools = try #require(sumWithoutTools.recentOutputSamples.last)
        let t0 = try #require(AppDate.parseISO8601("2026-11-23T04:00:00Z")).timeIntervalSince1970
        #expect(abs(sWithoutTools.timestamp - t0) < 1e-6)
        #expect(sWithoutTools.durationSeconds == nil)

        // 3. Followup > 600s after PLANNER_RESPONSE is rejected (keeps start timestamp & nil duration)
        let over600s = """
        {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-23T04:00:00Z","model":"gemini-4-carbon-high","output_tokens":1200,"tool_calls":[{"name":"run_command"}]}
        {"step_index":2,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"2026-11-23T04:10:01Z","content":"slow"}
        """
        let sumOver600 = TranscriptParse.scan(text: over600s)
        let sOver600 = try #require(sumOver600.recentOutputSamples.last)
        #expect(abs(sOver600.timestamp - t0) < 1e-6)
        #expect(sOver600.durationSeconds == nil)

        // 4. Sub-second (< 1.0s) followup updates timestamp but keeps durationSeconds == nil
        let subSecond = """
        {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-23T04:00:00.000Z","model":"gemini-4-carbon-high","output_tokens":50,"tool_calls":[{"name":"read_file"}]}
        {"step_index":2,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"2026-11-23T04:00:00.600Z","content":"ok"}
        """
        let sumSubSec = TranscriptParse.scan(text: subSecond)
        let sSubSec = try #require(sumSubSec.recentOutputSamples.last)
        let t06 = try #require(AppDate.parseISO8601("2026-11-23T04:00:00.600Z")).timeIntervalSince1970
        #expect(abs(sSubSec.timestamp - t06) < 1e-6)
        #expect(sSubSec.durationSeconds == nil)

        // 5. Negative clock skew on followup step is rejected cleanly
        let negSkewStep = """
        {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-23T04:00:10Z","model":"gemini-4-carbon-high","output_tokens":200,"tool_calls":[{"name":"read_file"}]}
        {"step_index":2,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"2026-11-23T04:00:05Z","content":"clock jumped back"}
        """
        let sumNegSkew = TranscriptParse.scan(text: negSkewStep)
        let sNegSkew = try #require(sumNegSkew.recentOutputSamples.last)
        let t10 = try #require(AppDate.parseISO8601("2026-11-23T04:00:10Z")).timeIntervalSince1970
        #expect(abs(sNegSkew.timestamp - t10) < 1e-6)
        #expect(sNegSkew.durationSeconds == nil)

        // 6. Negative clock skew, sentinel (<= 2000-01-01), >600s, <1.0s, and non-finite fileMtime
        let trailing = """
        {"step_index":5,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-23T04:00:10Z","model":"gemini-4-carbon-high","output_tokens":400}
        """
        for badMtime in [t10 - 5.0, 0.0, 946_684_799.0, t10 + 601.0, Double.nan, Double.infinity] {
            let sum = TranscriptParse.scan(text: trailing, fileMtime: badMtime)
            let sample = try #require(sum.recentOutputSamples.last)
            #expect(abs(sample.timestamp - t10) < 1e-6)
            #expect(sample.durationSeconds == nil)
        }
        // Sub-second fileMtime (< 1.0s) updates timestamp but keeps durationSeconds == nil
        let subMtimeSum = TranscriptParse.scan(text: trailing, fileMtime: t10 + 0.4)
        let subMtimeSample = try #require(subMtimeSum.recentOutputSamples.last)
        #expect(abs(subMtimeSample.timestamp - (t10 + 0.4)) < 1e-6)
        #expect(subMtimeSample.durationSeconds == nil)
    }
}
