import XCTest
import KvotarUI

/// REV-99 §2.5 — what a copy of Kvotar that lost the §9.2 lock does about it (STEP_205).
final class SecondInstanceActionTests: XCTestCase {
    func testDeliberateKvotarCollisionHandsOff() {
        XCTAssertEqual(
            SecondInstanceAction.decide(conflict: .kvotarInstance, launch: .showWindow),
            .handOffAndQuit,
            "the user opened Kvotar — the running copy shows itself and this one goes away")
    }

    func testLoginLaunchedKvotarCollisionPostsNothing() {
        XCTAssertEqual(
            SecondInstanceAction.decide(conflict: .kvotarInstance, launch: .stayQuiet),
            .quitSilently,
            "launch at login is silent by contract, and two registered copies do not bend it")
    }

    func testLegacyConflictIsShownWhateverTheLaunch() {
        for launch: LaunchSource.Decision in [.showWindow, .stayQuiet] {
            XCTAssertEqual(
                SecondInstanceAction.decide(conflict: .legacyAgentPilot, launch: launch),
                .showConflict,
                "there is no running Kvotar to hand off to, and the window is the only place the "
                    + "user learns which app to quit")
        }
    }

    /// The pairing that must never exist: a hand-off posted from a login launch.
    func testNoLoginLaunchEverHandsOff() {
        for conflict: AlreadyRunningView.Conflict in [.kvotarInstance, .legacyAgentPilot] {
            XCTAssertNotEqual(
                SecondInstanceAction.decide(conflict: conflict, launch: .stayQuiet),
                .handOffAndQuit)
        }
    }
}
