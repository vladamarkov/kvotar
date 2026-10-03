import XCTest
@testable import KvotarCore

/// Pins the six STEP_135 defects in the log writer. Every one of these was reproducible on the
/// dogfood machine before this step; see Baseline §20 P1-24 and the REV-13 row in `TASKS.md`.
final class LogFileWriterTests: XCTestCase {

    // MARK: - Test isolation (the defect that hid the others)

    /// The suite must never write into the user's real log. `Logger`'s `fileWriter` is a
    /// process-wide static, so before STEP_135 every SPM test target appended fixture polls to
    /// `~/Library/Logs/Kvotar/kvotar.log` and burned a ring generation per run — on the dogfood
    /// machine `kvotar.1.log` was two seconds of `plan=enterprise primary=100%` test output.
    /// This assertion is what keeps that from coming back.
    func testLogDirectoryIsRedirectedAwayFromTheProductPathUnderTests() {
        XCTAssertNotEqual(Logger.logDirectoryURL.standardizedFileURL,
                          ProductIdentity.logDirectory().standardizedFileURL)
        XCTAssertFalse(Logger.logFileURL().path.contains("/Library/Logs/Kvotar/"))
    }

    // MARK: - Rotation

    /// A launch must not rotate. Rotate-on-launch, five deep, meant five launches erased the ring
    /// no matter how little had been written — the P1-24 mechanism.
    func testAFreshWriterAppendsToAnExistingLogInsteadOfRotatingIt() throws {
        let (directory, basename) = try makeScratch()
        let logURL = directory.appendingPathComponent("\(basename).log")
        try Data("earlier run\n".utf8).write(to: logURL)

        let writer = LogFileWriter(basename: basename)
        writer.writeLine("later run")
        drain(writer)

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("earlier run"), "the previous run's lines must survive")
        XCTAssertTrue(contents.contains("later run"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("\(basename).1.log").path),
            "a launch must not produce a rotated generation")
    }

    func testCrossingTheSizeThresholdRotates() throws {
        let (directory, basename) = try makeScratch()
        let logURL = directory.appendingPathComponent("\(basename).log")
        // One byte over the 5 MB threshold; rotation is checked before the next write.
        try Data(repeating: UInt8(ascii: "x"), count: 5 * 1024 * 1024 + 1).write(to: logURL)

        let writer = LogFileWriter(basename: basename)
        writer.writeLine("after rotation")
        drain(writer)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("\(basename).1.log").path))
        XCTAssertEqual(try String(contentsOf: logURL, encoding: .utf8), "after rotation\n")
    }

    /// Ten generations, not five — the depth the ring was raised to once launch rotation stopped
    /// consuming it.
    func testTheRingKeepsTenGenerationsAndDropsTheEleventh() throws {
        let (directory, basename) = try makeScratch()
        let fm = FileManager.default
        for index in 1...10 {
            try Data("generation \(index)\n".utf8)
                .write(to: directory.appendingPathComponent("\(basename).\(index).log"))
        }
        try Data(repeating: UInt8(ascii: "x"), count: 5 * 1024 * 1024 + 1)
            .write(to: directory.appendingPathComponent("\(basename).log"))

        let writer = LogFileWriter(basename: basename)
        writer.writeLine("fresh")
        drain(writer)

        XCTAssertFalse(fm.fileExists(atPath:
            directory.appendingPathComponent("\(basename).11.log").path),
            "the ring must not grow past its depth")
        // The oldest generation is gone; every other one shifted down by exactly one.
        XCTAssertEqual(try String(contentsOf:
            directory.appendingPathComponent("\(basename).10.log"), encoding: .utf8),
            "generation 9\n")
        XCTAssertEqual(try String(contentsOf:
            directory.appendingPathComponent("\(basename).2.log"), encoding: .utf8),
            "generation 1\n")
    }

    /// REV-13: a concurrent instance renames the file out from under an open handle, and the handle
    /// follows the rename — so the older process keeps appending into a file already shifted down
    /// the ring. The writer must notice the inode changed and reopen.
    func testARotationUnderneathAnOpenHandleIsFollowedByAReopen() throws {
        let (directory, basename) = try makeScratch()
        let logURL = directory.appendingPathComponent("\(basename).log")
        let writer = LogFileWriter(basename: basename)

        writer.writeLine("before the other instance rotated")
        drain(writer)

        // Stand in for the concurrent instance: move the live file down the ring.
        try FileManager.default.moveItem(
            at: logURL, to: directory.appendingPathComponent("\(basename).1.log"))

        writer.writeLine("after the other instance rotated")
        drain(writer)

        let current = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(current, "after the other instance rotated\n",
                       "the write must land in the current file, not the rotated inode")
        let rotated = try String(contentsOf:
            directory.appendingPathComponent("\(basename).1.log"), encoding: .utf8)
        XCTAssertEqual(rotated, "before the other instance rotated\n")
    }

    // MARK: - The one-line invariant

    /// An `NSError` description spans lines, so one `Poll failed` became several file lines of which
    /// only the first parsed — and `LogFilter.matches` then discarded the rest. One record is now
    /// always one line, enforced at the writer so all 59 call sites that interpolate an error are
    /// covered without being touched.
    func testARecordContainingNewlinesIsWrittenAsOneLine() throws {
        let (directory, basename) = try makeScratch()
        let writer = LogFileWriter(basename: basename)

        writer.writeLine("Poll failed · error=Error Domain=NSURLErrorDomain Code=-1009 UserInfo={\n"
                         + "    _kCFStreamErrorCodeKey=50,\n\tNSUnderlyingError=0x600001\n}")
        drain(writer)

        let contents = try String(
            contentsOf: directory.appendingPathComponent("\(basename).log"), encoding: .utf8)
        XCTAssertEqual(contents.filter(\.isNewline).count, 1, "exactly one terminating newline")
        XCTAssertTrue(contents.contains("_kCFStreamErrorCodeKey=50"),
                      "nothing may be dropped — only joined")
    }

    /// The level field is padded on purpose and the `LogLine` grammar reads that padding, so the
    /// invariant must leave space runs alone.
    func testThePaddedLevelFieldSurvivesTheInvariant() {
        let line = "2026-08-22T12:00:00.000Z [INFO]     [123][PollEngine] Poll complete · util=7%"
        XCTAssertEqual(Logger.singleLine(line), line)
    }

    // MARK: - Helpers

    // MARK: - Two instances, one file

    /// Two live instances share `kvotar.log` — that is the whole point of the §9.2 process guard,
    /// and the PID prefix exists precisely so their lines can be told apart. Each writer holds its
    /// own file offset, so a handle opened without `O_APPEND` writes wherever *it* last left off and
    /// silently overwrites whatever the other instance put there.
    ///
    /// Found on 2026-08-24: a blocked second instance logged `CRITICAL Another compatible instance
    /// is already running` and the line never reached the file, because the primary was polling and
    /// writing over it. The guard's one forensic record was lost in exactly the situation it
    /// documents.
    func testAConcurrentWriterDoesNotOverwriteTheOtherInstancesLines() throws {
        let (directory, basename) = try makeScratch()
        let logURL = directory.appendingPathComponent("\(basename).log")

        // Two writers on one path, as two processes would be. Interleaved, with the "primary"
        // writing longer lines either side of the "second instance" record.
        let primary = LogFileWriter(basename: basename)
        let secondInstance = LogFileWriter(basename: basename)

        primary.writeLine(String(repeating: "primary poll complete ", count: 8))
        drain(primary)
        secondInstance.writeLine("CRITICAL guard fired")
        drain(secondInstance)
        primary.writeLine(String(repeating: "primary poll complete ", count: 8))
        drain(primary)

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("CRITICAL guard fired"),
                      "the second instance's record was overwritten by the primary's next write")
        XCTAssertEqual(contents.components(separatedBy: "primary poll complete").count - 1, 16,
                       "and the primary's own lines must survive the second instance's write")
        XCTAssertFalse(contents.contains("\0"), "no write landed at a stale offset")
    }

    private func makeScratch() throws -> (URL, String) {
        // `LogFileWriter` derives its directory from `Logger.logDirectoryURL`, which is already the
        // per-process temp directory under XCTest — a unique basename is all the isolation each
        // test needs, and it exercises the real path derivation rather than bypassing it.
        let directory = Logger.logDirectoryURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let basename = "test-\(UUID().uuidString.prefix(8))"
        addTeardownBlock {
            let stale = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in stale where name.hasPrefix(basename) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        return (directory, basename)
    }

    /// Writes are dispatched to the writer's serial queue; a barrier on it is the synchronisation
    /// point. Reaching through `writeLine` twice would only queue more work behind the first.
    private func drain(_ writer: LogFileWriter) {
        let done = expectation(description: "log write drained")
        writer.drainForTesting { done.fulfill() }
        wait(for: [done], timeout: 5)
    }
}
