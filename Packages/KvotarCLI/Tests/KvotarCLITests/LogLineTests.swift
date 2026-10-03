import XCTest
@testable import KvotarCLI

/// The `kvotar logs` grammar after STEP_135 put the PID in the prefix. The ring holds ten
/// generations, so both grammars are on disk at once for weeks and both must parse — a reader whose
/// filter silently drops half the history is the failure this whole step exists to remove.
final class LogLineTests: XCTestCase {

    private let stamp = "2026-08-22T12:29:03.893Z"

    func testTheNewPrefixParsesWithItsPID() {
        let line = "\(stamp) [INFO]     [4821][PollEngine] Poll complete · tool=claude util=7%"
        let parsed = LogLine.parse(line)

        XCTAssertTrue(parsed.isStructured)
        XCTAssertEqual(parsed.pid, 4821)
        XCTAssertEqual(parsed.component, "PollEngine")
        XCTAssertEqual(parsed.message, "Poll complete")
        XCTAssertEqual(parsed.metadata["tool"], "claude")
    }

    /// A pre-STEP_135 line has no `[pid]` group. It must still parse fully — only `pid` is nil.
    func testAPreStepLineStillParsesWithoutAPID() {
        let line = "\(stamp) [WARNING]  [ClaudeAccountAdapter] Claude poll 429 · retry_after=0s"
        let parsed = LogLine.parse(line)

        XCTAssertTrue(parsed.isStructured)
        XCTAssertNil(parsed.pid)
        XCTAssertEqual(parsed.component, "ClaudeAccountAdapter")
        XCTAssertEqual(parsed.metadata["retry_after"], "0s")
    }

    /// A component name is never all digits, which is what makes the optional group unambiguous.
    func testANumericLookingComponentIsNotMistakenForAPID() {
        let line = "\(stamp) [INFO]     [SQLiteStore] Migrations applied"
        let parsed = LogLine.parse(line)

        XCTAssertNil(parsed.pid)
        XCTAssertEqual(parsed.component, "SQLiteStore")
    }

    /// The reason the writer collapses newlines: an active filter drops any line the grammar does
    /// not fully recognise, so a network error split across file lines used to lose everything after
    /// its first. Collapsed, the whole record survives a `--level warning` read.
    func testACollapsedErrorRecordSurvivesALevelFilterWhole() throws {
        let line = "\(stamp) [WARNING]  [4821][PollEngine] Poll failed · error=The Internet "
            + "connection appears ⏎ to be offline. error_code=-1009 "
            + "error_domain=NSURLErrorDomain tool=claude"
        let filter = try LogFilter(level: "warning", component: nil, tool: "claude", since: nil)
        let parsed = LogLine.parse(line)

        XCTAssertTrue(filter.matches(parsed))
        XCTAssertEqual(parsed.metadata["error_domain"], "NSURLErrorDomain")
        XCTAssertEqual(parsed.metadata["error_code"], "-1009")
    }

    /// The other half of `Logger.metadataValue`. Without quote-aware tokenising, the live log's
    /// `error=unable to open database file table=thread_goals` read as `error=unable` — the value
    /// was not truncated, it was replaced by its first word, and the four dropped words looked like
    /// nothing had gone wrong.
    func testAQuotedValueKeepsItsSpacesAndTheNextPairStillParses() {
        let line = "\(stamp) [WARNING]  [4821][CodexLocalAdapter] Codex SQLite query unavailable · "
            + #"error="unable to open database file" table=thread_goals"#
        let parsed = LogLine.parse(line)

        XCTAssertEqual(parsed.metadata["error"], "unable to open database file")
        XCTAssertEqual(parsed.metadata["table"], "thread_goals")
    }

    func testAnEscapedQuoteInsideAValueRoundTrips() {
        let line = "\(stamp) [INFO]     [4821][AppLifecycle] Started · " + #"note="he said \"go\" once""#
        XCTAssertEqual(LogLine.parse(line).metadata["note"], #"he said "go" once"#)
    }

    /// A pre-STEP_135 line carries the unquoted form. It parses as badly as it always did — the
    /// point is that it still parses at all, and that the new form is not read as the old one.
    func testAnUnquotedLegacySpacedValueStillParsesToItsFirstWord() {
        let line = "\(stamp) [WARNING]  [CodexLocalAdapter] Codex SQLite query unavailable · "
            + "error=unable to open database file table=thread_goals"
        let parsed = LogLine.parse(line)

        XCTAssertEqual(parsed.metadata["error"], "unable")
        XCTAssertEqual(parsed.metadata["table"], "thread_goals")
    }

    func testABareMarkerLineIsStillUnstructuredAndUnfiltered() throws {
        let parsed = LogLine.parse("[DEBUG MODE]")
        XCTAssertFalse(parsed.isStructured)
        XCTAssertTrue(try LogFilter(level: nil, component: nil, tool: nil, since: nil)
            .matches(parsed))
    }

    func testTheJSONFormCarriesThePID() {
        let line = "\(stamp) [INFO]     [4821][StateEngine] Transition: healthy→elevated"
        XCTAssertTrue(LogLine.parse(line).jsonLine.contains("\"pid\":4821"))
    }
}
