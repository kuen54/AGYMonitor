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
}
