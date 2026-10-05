import XCTest

// STEP_276 red proof run: a skip that is not in scripts/expected-skips.tsv (throwaway, never merged).
final class Step276RedSkipTests: XCTestCase {
    func testUnlistedSkip() throws {
        throw XCTSkip("STEP_276 red proof run")
    }
}
