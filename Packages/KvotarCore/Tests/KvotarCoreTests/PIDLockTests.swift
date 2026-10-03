import XCTest
@testable import KvotarCore

final class PIDLockTests: XCTestCase {

    private var path: String!

    override func setUp() {
        super.setUp()
        path = NSTemporaryDirectory().appending("kvotar-pidlock-\(UUID().uuidString).pid")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
        path = nil
        super.tearDown()
    }

    func testAcquireOnFreshPathSucceeds() {
        let lock = PIDLock(path: path)
        XCTAssertEqual(lock.acquire(), .acquired)
        let written = try? String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(written, "\(ProcessInfo.processInfo.processIdentifier)")
    }

    func testAcquireIsReentrantForOwnPID() {
        let lock = PIDLock(path: path)
        XCTAssertEqual(lock.acquire(), .acquired)
        XCTAssertEqual(lock.acquire(), .acquired, "our own PID must not block us")
    }

    func testStaleLockReclaimed() throws {
        // PID 999999 is virtually certain not to exist → file is stale.
        try "999999".write(toFile: path, atomically: true, encoding: .utf8)
        let lock = PIDLock(path: path)
        XCTAssertEqual(lock.acquire(), .acquired)
        let written = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(written, "\(ProcessInfo.processInfo.processIdentifier)")
    }

    func testLiveOtherInstanceBlocks() throws {
        // PID 1 (launchd) is always alive and is not us → must report already-running.
        try "1".write(toFile: path, atomically: true, encoding: .utf8)
        let lock = PIDLock(path: path)
        XCTAssertEqual(lock.acquire(), .alreadyRunning(pid: 1))
    }

    func testReleaseRemovesOwnLock() {
        let lock = PIDLock(path: path)
        _ = lock.acquire()
        lock.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testReleaseLeavesForeignLockIntact() throws {
        try "1".write(toFile: path, atomically: true, encoding: .utf8)
        PIDLock(path: path).release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "never delete another PID's lock")
    }

    func testIsProcessAliveForSelf() {
        XCTAssertTrue(PIDLock.isProcessAlive(ProcessInfo.processInfo.processIdentifier))
        XCTAssertFalse(PIDLock.isProcessAlive(999999))
    }
}
