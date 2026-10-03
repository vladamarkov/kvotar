import XCTest
import KvotarCore
@testable import CodexAdapter

/// §17.1 `parse_anomalies` on the Codex substrate — only a **decode failure** is an anomaly
/// (REV-52, STEP_72). Twin of `ClaudeParseAnomalyTests`; the same trap applies, and harder: a Codex
/// rollout file is overwhelmingly non-`token_count` events.
final class CodexParseAnomalyTests: XCTestCase {

    private func events(_ parser: CodexJSONLParser, _ text: String,
                        sourceFile: String? = "rollout.jsonl") -> [TokenEvent] {
        parser.parseTokenEvents(
            Data(text.utf8), sessionId: "s1", surfaceBucket: "CLI", originator: "codex_cli_rs",
            sourceFile: sourceFile).events
    }

    func testUndecodableLineReportsAnomaly() {
        var seen: [ParseAnomaly] = []
        _ = events(CodexJSONLParser(onAnomaly: { seen.append($0) }), "{not json\n")

        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen[0].tool, .codex)
        XCTAssertEqual(seen[0].sourceFile, "rollout.jsonl")
        XCTAssertNil(seen[0].lineNumber)
    }

    func testNonTokenCountLineIsNotAnAnomaly() {
        var seen: [ParseAnomaly] = []
        let line = #"{"type":"response_item","payload":{"type":"message"}}"# + "\n"
        _ = events(CodexJSONLParser(onAnomaly: { seen.append($0) }), line)

        XCTAssertTrue(seen.isEmpty, "ordinary filtering is not an anomaly")
    }

    func testTokenCountWithNoUsableUsageIsNotAnAnomaly() {
        var seen: [ParseAnomaly] = []
        // The known "null-info token event" case (§8.4) — a shape we understand and skip.
        let line = #"{"type":"event_msg","payload":{"type":"token_count","info":null}}"# + "\n"
        _ = events(CodexJSONLParser(onAnomaly: { seen.append($0) }), line)

        XCTAssertTrue(seen.isEmpty)
    }

    func testAnomalyCarriesFieldNamesButNeverValues() {
        var seen: [ParseAnomaly] = []
        let line = #"{"type":42,"payload":"secret text"}"# + "\n"
        _ = events(CodexJSONLParser(onAnomaly: { seen.append($0) }), line)

        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen[0].fieldNames, ["payload", "type"])
    }

    func testNoSourceFileMeansNoReport() {
        var seen: [ParseAnomaly] = []
        _ = events(CodexJSONLParser(onAnomaly: { seen.append($0) }), "{broken\n", sourceFile: nil)
        XCTAssertTrue(seen.isEmpty)
    }

    func testParsingIsUnchangedWhenNoHookIsWired() {
        let good = #"""
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":3,"output_tokens":4,"total_tokens":7}}}}
        """# + "\n"
        let parsed = events(CodexJSONLParser(), "{broken\n" + good)
        XCTAssertEqual(parsed.count, 1, "a malformed line is still skipped, not fatal")
    }
}
