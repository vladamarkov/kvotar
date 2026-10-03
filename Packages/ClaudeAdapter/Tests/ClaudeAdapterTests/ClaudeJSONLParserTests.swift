import XCTest
import KvotarCore
@testable import ClaudeAdapter

final class ClaudeJSONLParserTests: XCTestCase {

    private let parser = ClaudeJSONLParser()

    private func jsonlData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "jsonl"),
            "missing fixture: \(name).jsonl"
        )
        return try Data(contentsOf: url)
    }

    // MARK: Normal session — filter + token paths + main-agent bucket

    func testNormalSessionParsesAssistantEventOnly() throws {
        let events = parser.parse(try jsonlData("local_session_normal"))
        XCTAssertEqual(events.count, 1, "human/non-assistant lines are ignored")

        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.tool, .claude)
        XCTAssertEqual(event.sessionId, "s1")
        XCTAssertEqual(event.project, "/home/u/proj")
        XCTAssertEqual(event.model, "claude-sonnet-4-6")
        XCTAssertEqual(event.slug, "my-session")
        XCTAssertEqual(event.surfaceBucket, "Claude Code")
        XCTAssertEqual(event.inputTokens, 100)
        XCTAssertEqual(event.outputTokens, 50)
        XCTAssertEqual(event.cacheCreationTokens, 20)
        XCTAssertEqual(event.cacheReadTokens, 10)
        XCTAssertEqual(event.dedupKey, "m1_req-1")
        XCTAssertEqual(event.legacyDedupKey, "req-1",
                       "pre-STEP_94 key form, carried for the store's legacy guard")
    }

    // MARK: Timestamp honesty (REV-20, STEP_32)

    /// A line carrying its own `timestamp` must be stamped at that instant, not at parse time —
    /// otherwise a catch-up read of backlogged lines lands as a fake "now" spike in the 2-min
    /// rate windows.
    func testRecordedAtUsesLineTimestamp() throws {
        let line = Data("""
        {"type":"assistant","sessionId":"s1","requestId":"req-t","timestamp":"2026-07-06T05:00:00.123Z","message":{"id":"m1","usage":{"input_tokens":1,"output_tokens":1}}}
        """.utf8)
        let parseTime = Date()
        let event = try XCTUnwrap(parser.parseLine(line, recordedAt: parseTime))
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-06T05:00:00Z"))
        XCTAssertEqual(event.recordedAt.timeIntervalSince1970,
                       expected.timeIntervalSince1970 + 0.123, accuracy: 0.01)
        XCTAssertEqual(event.startedAt, event.recordedAt)
        XCTAssertNotEqual(event.recordedAt, parseTime)
    }

    func testRecordedAtFallsBackToParseTimeWithoutTimestamp() throws {
        let parseTime = Date(timeIntervalSince1970: 1_750_000_000)
        let event = try XCTUnwrap(
            parser.parse(try jsonlData("local_session_normal"), recordedAt: parseTime).first)
        XCTAssertEqual(event.recordedAt, parseTime,
                       "no per-line timestamp → parse time preserves pre-STEP_32 behavior")
    }

    // MARK: Subagent — named and unnamed buckets

    func testSubagentNamedBucket() throws {
        let event = try XCTUnwrap(parser.parse(try jsonlData("local_subagent_named")).first)
        XCTAssertEqual(event.surfaceBucket, "Subagent · Explore")
        XCTAssertEqual(event.dedupKey, "m2_req-2")
    }

    func testSubagentUnnamedBucket() throws {
        let event = try XCTUnwrap(parser.parse(try jsonlData("local_subagent_unnamed")).first)
        XCTAssertEqual(event.surfaceBucket, "Subagent · Unknown")
    }

    // MARK: Deduplication key derivation (STEP_94 — `(message.id, requestId)`, session-free)

    /// Pins mechanism (d) as REV-62 §4.1 records it: one API response is written as several
    /// content-block lines — same `message.id`, same `requestId`, 49.81% of raw corpus tokens —
    /// and the key MUST keep collapsing them. If a future change makes these keys differ, it is
    /// re-introducing the near-half-the-corpus double count, not fixing anything.
    func testWithinSessionContentBlockRepeatsShareOneKey() throws {
        let events = parser.parse(try jsonlData("local_dedup"))
        XCTAssertEqual(events.count, 4)

        // First two are one billed message written twice (content-block split).
        XCTAssertEqual(events[0].dedupKey, "m4_dup")
        XCTAssertEqual(events[1].dedupKey, "m4_dup")
        XCTAssertEqual(events[0].sessionId, events[1].sessionId)
        XCTAssertEqual(events[0].legacyDedupKey, "dup")
    }

    func testMessageIdFallbackAndRetryDistinction() throws {
        let events = parser.parse(try jsonlData("local_dedup"))

        // No requestId → message-id-only form, unchanged from pre-STEP_94 (no legacy twin).
        XCTAssertEqual(events[2].dedupKey, "msg:m5")
        XCTAssertNil(events[2].legacyDedupKey)

        // Same requestId but a different message.id is a *different* billed message (a retried
        // request) — the reason the key is the pair and not the bare requestId.
        XCTAssertEqual(events[3].dedupKey, "m4c_dup")
        XCTAssertNotEqual(events[3].dedupKey, events[0].dedupKey)
    }

    // MARK: Cache-creation fallback

    func testCacheCreationSubTierFallbackAndAbsent() throws {
        let events = parser.parse(try jsonlData("local_cache_absent"))
        XCTAssertEqual(events.count, 2)
        // No flat field → sum of 1h + 5m tiers.
        XCTAssertEqual(events[0].cacheCreationTokens, 7)
        XCTAssertEqual(events[0].cacheReadTokens, 2)
        // Neither flat nor tiers → 0.
        XCTAssertEqual(events[1].cacheCreationTokens, 0)

        // STEP_96 — the tier split. Line 1 has no flat field but does break the write down, so
        // the 1-hour slice is known; line 2 has no `cache_creation` object at all, so the split
        // is unknown (nil) and the est-value math prices the whole write at the 5-minute rate,
        // which is what happened everywhere before this step.
        XCTAssertEqual(events[0].cacheCreation1hTokens, 3)
        XCTAssertNil(events[1].cacheCreation1hTokens)
    }

    // MARK: Cache-write tiers (STEP_96)

    /// Anthropic charges 1.25× input for a 5-minute cache write and 2× for a 1-hour one, and
    /// 84.3% of the corpus's writes are 1-hour (REV-62 §4.4). The parser used to sum the tiers
    /// away; it now carries the 1-hour slice as a **subset** of the unchanged total.
    func testCacheWriteTiersAreCarriedAsASubsetOfTheTotal() throws {
        let events = parser.parse(try jsonlData("local_cache_tiers"))
        XCTAssertEqual(events.count, 3)

        // Both tiers present alongside the flat field. The flat field stays the total — verified
        // equal to the tier sum on all 20,481 corpus lines — and the 1-hour slice rides beside it.
        XCTAssertEqual(events[0].cacheCreationTokens, 24576)
        XCTAssertEqual(events[0].cacheCreation1hTokens, 20480)
        // The 5-minute amount is the remainder, never a third stored number.
        XCTAssertEqual(events[0].cacheCreationTokens - (events[0].cacheCreation1hTokens ?? 0), 4096)

        // Object present but no 1-hour field: an explicit zero ("none of it was 1-hour"), which
        // is a different claim from nil ("the split was never recorded").
        XCTAssertEqual(events[1].cacheCreationTokens, 4096)
        XCTAssertEqual(events[1].cacheCreation1hTokens, 0)

        // A 1-hour slice larger than the total is clamped, so the 5-minute remainder can never go
        // negative and credit the user. Never observed; a future payload is not bound by that.
        XCTAssertEqual(events[2].cacheCreationTokens, 1000)
        XCTAssertEqual(events[2].cacheCreation1hTokens, 1000)
    }

    /// The whole safety argument of STEP_96: the tier split changes the price and nothing else.
    /// The four token columns the §4 displayed count sums are byte-identical with and without it.
    func testTierSplitLeavesTheDisplayedTokenColumnsUntouched() throws {
        let tiered = parser.parse(try jsonlData("local_cache_tiers"))[0]
        XCTAssertEqual(tiered.inputTokens, 12)
        XCTAssertEqual(tiered.outputTokens, 340)
        XCTAssertEqual(tiered.cacheReadTokens, 180224)
        // Claude's displayed count is all four columns (§4). The 1-hour value is inside
        // `cacheCreationTokens` already and must never be added on top.
        let displayed = tiered.inputTokens + tiered.outputTokens
            + tiered.cacheCreationTokens + tiered.cacheReadTokens
        XCTAssertEqual(displayed, 12 + 340 + 24576 + 180224)
    }

    // MARK: Non-assistant / malformed handling

    func testMalformedAndNonAssistantLinesIgnored() {
        let data = Data("""
        not json at all
        {"type":"human","sessionId":"x"}
        {"type":"assistant"}
        """.utf8)
        // assistant line lacks sessionId → dropped; others ignored.
        XCTAssertTrue(parser.parse(data).isEmpty)
    }
}
