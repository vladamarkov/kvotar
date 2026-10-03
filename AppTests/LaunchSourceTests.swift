import XCTest


/// What Kvotar does about the launch it just went through (REV-99 §2.4, contract §7 — STEP_204).
///
/// Every shape below was observed on a real machine, including a genuine logout and sign-in:
/// `docs/spikes/SPIKE_E_status_item_visibility_2026-09-15.md`, raw logs in
/// `docs/evidence/SPIKE_E/`. The whole decision hangs on one parameter, so it is worth four tests.
final class LaunchSourceTests: XCTestCase {

    /// `loginwindow`, `'prdt':'lgit'` — the login row at `09:51:16.921` in `probe_login_run.log`.
    /// **Login stays silent**, and that contract does not bend: a window opening by itself at
    /// every sign-in would undermine the behaviour the rest of REV-99 rests on.
    func testLaunchAtLoginStaysQuiet() {
        let event = LaunchSource.Event(eventClass: "aevt", eventID: "oapp", propertyData: "lgit")
        XCTAssertEqual(LaunchSource.decide(event: event), .stayQuiet)
    }

    /// Finder / Spotlight / `open` — an empty parameter list, the rows at `09:39:42.236` and
    /// `09:39:57.852`. This is the one thing a person does when the item is not where they
    /// expected it, so it opens the window.
    func testDeliberateLaunchShowsTheWindow() {
        let event = LaunchSource.Event(eventClass: "aevt", eventID: "oapp")
        XCTAssertEqual(LaunchSource.decide(event: event), .showWindow)
    }

    /// No launch event at all. Conservative on purpose — silence is the safe failure.
    func testNoLaunchEventStaysQuiet() {
        XCTAssertEqual(LaunchSource.decide(event: nil), .stayQuiet)
    }

    /// A reopen (`rapp`) is not a cold launch. It has its own path —
    /// `applicationShouldHandleReopen` — and must not be answered twice.
    func testAReopenEventIsNotAColdLaunch() {
        let event = LaunchSource.Event(eventClass: "aevt", eventID: "rapp")
        XCTAssertEqual(LaunchSource.decide(event: event), .stayQuiet)
    }

    /// The four-character codes the rule compares are read off `FourCharCode`s, so the conversion
    /// is part of the rule rather than plumbing around it.
    func testFourCharCodesDecodeToTheirCharacters() {
        XCTAssertEqual(LaunchSource.code(0x6165_7674), "aevt")
        XCTAssertEqual(LaunchSource.code(0x6F61_7070), "oapp")
        XCTAssertEqual(LaunchSource.code(0x6C67_6974), "lgit")
    }
}
