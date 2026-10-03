import XCTest
import KvotarCore
@testable import ClaudeAdapter

/// §17.1 `parse_anomalies` — only a **decode failure** is an anomaly (REV-52, STEP_72).
///
/// The load-bearing case is `testNonAssistantLineIsNotAnAnomaly`. `parseLine` returns nil for every
/// user message, tool result and summary line in a transcript; reporting those would write millions
/// of rows and drown the signal this table exists to carry.
final class ClaudeParseAnomalyTests: XCTestCase {

    private func parser(_ collected: @escaping (ParseAnomaly) -> Void) -> ClaudeJSONLParser {
        ClaudeJSONLParser(onAnomaly: collected)
    }

    func testUndecodableLineReportsAnomaly() {
        var seen: [ParseAnomaly] = []
        let p = parser { seen.append($0) }
        _ = p.parse(Data("{not json at all\n".utf8), sourceFile: "session.jsonl")

        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen[0].tool, .claude)
        XCTAssertEqual(seen[0].sourceFile, "session.jsonl")
        XCTAssertNil(seen[0].lineNumber, "chunk-relative indices are not reported as absolutes")
        XCTAssertNil(seen[0].fieldNames, "a non-object line has no field names")
    }

    func testNonAssistantLineIsNotAnAnomaly() {
        var seen: [ParseAnomaly] = []
        let p = parser { seen.append($0) }
        let line = #"{"type":"user","sessionId":"s1","message":{"role":"user"}}"# + "\n"
        _ = p.parse(Data(line.utf8), sourceFile: "session.jsonl")

        XCTAssertTrue(seen.isEmpty, "ordinary filtering is not an anomaly")
    }

    func testAssistantLineMissingIdentifiersIsNotAnAnomaly() {
        var seen: [ParseAnomaly] = []
        let p = parser { seen.append($0) }
        // Decodes cleanly, but has no sessionId — a known-shape event we simply cannot key.
        _ = p.parse(Data((#"{"type":"assistant"}"# + "\n").utf8), sourceFile: "session.jsonl")

        XCTAssertTrue(seen.isEmpty)
    }

    func testAnomalyCarriesFieldNamesButNeverValues() {
        var seen: [ParseAnomaly] = []
        let p = parser { seen.append($0) }
        // Valid JSON object, but `type` is the wrong type for RawEvent ⇒ decode fails.
        let line = #"{"type":42,"prompt":"secret text"}"# + "\n"
        _ = p.parse(Data(line.utf8), sourceFile: "session.jsonl")

        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen[0].fieldNames, ["prompt", "type"])
        XCTAssertFalse((seen[0].error ?? "").contains("secret text"))
    }

    func testNoSourceFileMeansNoReport() {
        var seen: [ParseAnomaly] = []
        let p = parser { seen.append($0) }
        _ = p.parse(Data("{broken\n".utf8))   // sourceFile omitted
        XCTAssertTrue(seen.isEmpty, "a row that cannot name its origin is not worth writing")
    }

    func testParsingIsUnchangedWhenNoHookIsWired() {
        // The nil-hook default is what keeps every pre-STEP_72 test valid.
        let p = ClaudeJSONLParser()
        let good = #"""
        {"type":"assistant","sessionId":"s1","requestId":"r1","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":5,"output_tokens":7}}}
        """# + "\n"
        let events = p.parse(Data(("{broken\n" + good).utf8), sourceFile: "session.jsonl")
        XCTAssertEqual(events.count, 1, "a malformed line is still skipped, not fatal")
    }
}
