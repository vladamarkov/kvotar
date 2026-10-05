import XCTest

/// The zone the display fixtures' expected strings were written in (STEP_277). `DisplayFormatter`
/// reads `Calendar.current`, so a clock, a date or a "tomorrow" in those strings depends on the
/// machine's zone: in UTC "11:30 pm tomorrow" became "11:30 pm", and other zones broke about twenty
/// more. A class whose strings name a local clock or day pins this zone for each of its tests.
enum FixtureTimeZone {
    static let zone = TimeZone(identifier: "Europe/Berlin")!

    /// Makes `zone` the process default for one test and restores the previous one after it.
    static func pin(_ test: XCTestCase) {
        let previous = NSTimeZone.default
        NSTimeZone.default = zone
        test.addTeardownBlock { NSTimeZone.default = previous }
    }
}
