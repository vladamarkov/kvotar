import XCTest
import KvotarCore
@testable import KvotarCLI

/// `import`'s argument guards (STEP_74). These are the refusals that keep the project's
/// read-only-on-the-app's-data posture true for a command that, uniquely, creates a database.
final class ImportCommandTests: XCTestCase {

    /// The app's own database is never the corpus. This is the guard the whole command rests on.
    func testWritingTheCorpusOverTheAppDatabaseIsRefused() {
        XCTAssertThrowsError(
            try Import.parse(["--tester", "alice",
                              "--analysis-db", SQLiteStore.expectedDatabasePath(),
                              "/tmp/some-bundle"]))
    }

    /// `--database` means "the app's database" everywhere else in the CLI and means nothing here;
    /// silently ignoring it would be the kind of surprise that costs an afternoon.
    func testTheAppDatabaseFlagIsRefusedRatherThanIgnored() {
        XCTAssertThrowsError(
            try Import.parse(["--tester", "alice",
                              "--database", "/tmp/kvotar.db",
                              "--analysis-db", "/tmp/corpus.db",
                              "/tmp/some-bundle"]))
    }

    /// Bundles carry no machine identity, so the corpus cannot work out whose rows these are.
    func testMissingTesterIsRefused() {
        XCTAssertThrowsError(
            try Import.parse(["--analysis-db", "/tmp/corpus.db", "/tmp/some-bundle"]))
    }

    func testBlankTesterIsRefused() {
        XCTAssertThrowsError(
            try Import.parse(["--tester", "   ",
                              "--analysis-db", "/tmp/corpus.db",
                              "/tmp/some-bundle"]))
    }

    func testNoBundlesIsRefused() {
        XCTAssertThrowsError(
            try Import.parse(["--tester", "alice", "--analysis-db", "/tmp/corpus.db"]))
    }

    /// `--print-queries` is a reference lookup, not an import — it needs neither a tester nor a
    /// bundle.
    func testPrintQueriesNeedsNothingElse() throws {
        XCTAssertNoThrow(try Import.parse(["--print-queries"]))
    }

    func testValidInvocationParses() throws {
        let command = try Import.parse(["--tester", "Alice",
                                        "--analysis-db", "/tmp/corpus.db",
                                        "/tmp/some-bundle"])
        XCTAssertEqual(command.tester, "Alice")
        XCTAssertEqual(command.resolvedAnalysisPath, "/tmp/corpus.db")
    }

    /// The corpus defaults beside the app's database but emphatically is not it.
    func testDefaultCorpusPathIsNotTheAppDatabase() {
        XCTAssertNotEqual(Import.defaultAnalysisPath(), SQLiteStore.expectedDatabasePath())
        XCTAssertTrue(Import.defaultAnalysisPath().hasSuffix("Kvotar/analysis/analysis.db"))
    }

    /// Every starter query must at least be syntactically whole — they ship as the reference an
    /// operator pastes into `sqlite3`.
    func testStarterQueriesAreShippedAndComplete() {
        let text = StarterQueries.text
        XCTAssertTrue(text.contains("FROM bundles"))
        XCTAssertTrue(text.contains("FROM payload_shapes"), "the account-shape answer must ship")
        XCTAssertTrue(text.contains("FROM forecast_log"), "the verdict-correctness answer must ship")
        // Count statements, not semicolons — the commentary prose contains semicolons of its own.
        let lines = text.components(separatedBy: .newlines)
        XCTAssertEqual(lines.filter { $0.hasPrefix("SELECT ") }.count, 6,
                       "six starter queries should ship")
        XCTAssertEqual(lines.filter { $0.hasSuffix(";") && !$0.hasPrefix("--") }.count, 6,
                       "each starter query should be terminated")
    }
}
