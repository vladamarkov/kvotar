import XCTest

/// REV-99 §2.5 — the request must survive the gap between the observer going up and the surfaces
/// being wired (STEP_205). Without this, a second copy exits after an unheard request and the user
/// has opened Kvotar and got nothing.
@MainActor
final class HandoffInboxTests: XCTestCase {
    func testRequestBeforeWiringIsHeldAndDrainedOnAttach() {
        let inbox = HandoffInbox()
        var opens = 0

        inbox.receive()
        XCTAssertTrue(inbox.hasPendingRequest)
        XCTAssertEqual(opens, 0, "nothing to open yet")

        inbox.attach { opens += 1 }
        XCTAssertEqual(opens, 1, "the held request opens the window the moment it can")
        XCTAssertFalse(inbox.hasPendingRequest)
    }

    func testRequestAfterWiringIsForwardedImmediately() {
        let inbox = HandoffInbox()
        var opens = 0
        inbox.attach { opens += 1 }
        XCTAssertEqual(opens, 0, "attaching alone opens nothing")

        inbox.receive()
        XCTAssertEqual(opens, 1)
        XCTAssertFalse(inbox.hasPendingRequest)
    }

    /// Two copies launching together produce one window, not two openings.
    func testHeldRequestDrainsOnce() {
        let inbox = HandoffInbox()
        var opens = 0
        inbox.receive()
        inbox.receive()
        inbox.attach { opens += 1 }
        XCTAssertEqual(opens, 1)
    }

    func testEveryLaterRequestStillOpens() {
        let inbox = HandoffInbox()
        var opens = 0
        inbox.attach { opens += 1 }
        inbox.receive()
        inbox.receive()
        XCTAssertEqual(opens, 2, "a hand-off is a reopen — each one shows the window")
    }
}
