import XCTest
@testable import KvotarCore

/// §17.1 `payload_shapes` — the shape hash must key on **structure, never values** (REV-52, STEP_72).
///
/// This is the one place STEP_72 can silently invert its own spec: if values entered the hash,
/// every poll would register as a shape change, every row would become a permanent
/// durable field-name-only shape record without making any response body permanent
/// *while appearing to work*. Hence the value-invariance cases below, not just the drift ones.
final class PayloadShapeTests: XCTestCase {

    private func shape(_ json: String) -> PayloadShape {
        PayloadShape.of(Data(json.utf8))
    }

    // MARK: - Value invariance (the retention-defeating failure)

    func testNumbersChangingDoesNotChangeShape() {
        let a = shape(#"{"five_hour":{"used_pct":12,"resets_at":1750000000}}"#)
        let b = shape(#"{"five_hour":{"used_pct":97,"resets_at":1750018000}}"#)
        XCTAssertEqual(a.hash, b.hash, "a utilization reading is a value, not a structure")
    }

    func testStringsAndBoolsChangingDoesNotChangeShape() {
        let a = shape(#"{"plan_type":"max","extra_usage":{"is_enabled":true}}"#)
        let b = shape(#"{"plan_type":"enterprise","extra_usage":{"is_enabled":false}}"#)
        XCTAssertEqual(a.hash, b.hash)
    }

    func testNullingAFieldDoesNotChangeShape() {
        // Claude nulls the five-hour window every idle night (§8.3). Treating that as drift would
        // fire the permanent-keep path on a schedule.
        let a = shape(#"{"five_hour":{"used_pct":40}}"#)
        let b = shape(#"{"five_hour":{"used_pct":null}}"#)
        XCTAssertEqual(a.hash, b.hash)
    }

    func testArrayLengthDoesNotChangeShape() {
        let a = shape(#"{"items":[{"id":1}]}"#)
        let b = shape(#"{"items":[{"id":1},{"id":2},{"id":3}]}"#)
        XCTAssertEqual(a.hash, b.hash, "element count is a value; element paths are the structure")
    }

    func testKeyOrderDoesNotChangeShape() {
        let a = shape(#"{"a":1,"b":2}"#)
        let b = shape(#"{"b":2,"a":1}"#)
        XCTAssertEqual(a.hash, b.hash)
    }

    // MARK: - Real drift (what must be caught)

    func testAddedFieldChangesShape() {
        let a = shape(#"{"five_hour":{"used_pct":12}}"#)
        let b = shape(#"{"five_hour":{"used_pct":12,"amber_ladder":3}}"#)
        XCTAssertNotEqual(a.hash, b.hash)
    }

    func testRemovedFieldChangesShape() {
        let a = shape(#"{"spend":{"limit":120,"used":69}}"#)
        let b = shape(#"{"spend":{"limit":120}}"#)
        XCTAssertNotEqual(a.hash, b.hash)
    }

    func testRenamedFieldChangesShape() {
        let a = shape(#"{"individual_limit":{"used":10}}"#)
        let b = shape(#"{"individualLimit":{"used":10}}"#)
        XCTAssertNotEqual(a.hash, b.hash)
    }

    func testNestingDepthChangeIsDrift() {
        let a = shape(#"{"limit":600}"#)
        let b = shape(#"{"limit":{"amount":600}}"#)
        XCTAssertNotEqual(a.hash, b.hash)
    }

    // MARK: - Degenerate bodies

    func testUnparseableBodyGetsItsOwnStableShape() {
        // An endpoint that starts returning an HTML error page *is* a shape change worth keeping.
        let a = PayloadShape.of(Data("<html>502 Bad Gateway</html>".utf8))
        let b = PayloadShape.of(Data("<html>503 unavailable</html>".utf8))
        XCTAssertEqual(a.fieldPaths, ["<unparseable>"])
        XCTAssertEqual(a.hash, b.hash, "unparseable is one shape, not one per error page")
        XCTAssertNotEqual(a.hash, shape(#"{"ok":true}"#).hash)
    }

    func testEmptyObjectIsDistinctFromUnparseable() {
        XCTAssertNotEqual(shape("{}").hash, PayloadShape.of(Data("nonsense".utf8)).hash)
    }

    func testFieldPathsAreSortedAndDeduplicated() {
        let s = shape(#"{"b":{"y":1,"x":2},"a":3}"#)
        XCTAssertEqual(s.fieldPaths, ["a", "b", "b.x", "b.y"])
        XCTAssertEqual(s.fieldPaths.count, Set(s.fieldPaths).count)
    }

    func testHashIsStableAcrossCalls() {
        XCTAssertEqual(shape(#"{"a":{"b":1}}"#).hash, shape(#"{"a":{"b":1}}"#).hash)
    }
}
