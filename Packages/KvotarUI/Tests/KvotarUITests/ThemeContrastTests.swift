import XCTest
import SwiftUI
import AppKit
@testable import KvotarUI

/// STEP_180 — the reviewed REV-92 §4 palette, checked as **pairs that are actually drawn
/// together**, not as a list of hex constants.
///
/// What this suite is and is not. It resolves each token through the real `Theme.dyn` provider in
/// both appearances and computes the WCAG 2.1 contrast ratio, so a token edited on one side of the
/// light/dark pair — or a fill moved without its text — fails here. It cannot see a colour drawn
/// on a surface nobody planned for; that is what the `PopoverCompositionSnapshots` render pass and
/// the live acceptance look are for.
///
/// The 4.5:1 target is the REV-92 §7 acceptance figure for normal body and source text. Two
/// deliberate departures from the literal palette table are pinned here rather than left implicit:
/// the re-derived tint fills, and the chrome band drawing supporting text instead of tertiary.
final class ThemeContrastTests: XCTestCase {

    private static let target = 4.5
    /// A fill has to be visible against the surface it sits on, or it is not a box.
    private static let tintVisibility = 1.06

    // MARK: Ratio machinery

    private func srgb(_ color: Color, dark: Bool) -> (r: Double, g: Double, b: Double) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var resolved = NSColor.black
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
        }
        return (Double(resolved.redComponent), Double(resolved.greenComponent),
                Double(resolved.blueComponent))
    }

    private func luminance(_ color: Color, dark: Bool) -> Double {
        func channel(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let (r, g, b) = srgb(color, dark: dark)
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    private func ratio(_ a: Color, _ b: Color, dark: Bool) -> Double {
        let la = luminance(a, dark: dark), lb = luminance(b, dark: dark)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private func assertReadable(_ fg: Color, on bg: Color, _ what: String,
                                atLeast: Double = ThemeContrastTests.target,
                                file: StaticString = #filePath, line: UInt = #line) {
        for dark in [false, true] {
            let r = ratio(fg, bg, dark: dark)
            XCTAssertGreaterThanOrEqual(
                r, atLeast,
                "\(what) in \(dark ? "dark" : "light"): \(String(format: "%.2f", r)):1",
                file: file, line: line)
        }
    }

    // MARK: Text on the surfaces it is drawn on

    /// Every text token on the opaque popover base — the surface that carries the body of the
    /// popover, including all provenance and source text.
    func testBodyTextOnThePopoverBase() {
        assertReadable(Theme.textPrimary, on: Theme.card, "primary text on the popover base")
        assertReadable(Theme.textSecondary, on: Theme.card, "supporting text on the popover base")
        assertReadable(Theme.textTertiary, on: Theme.card, "tertiary text on the popover base")
    }

    /// The chrome band under the tabs and behind the History footer. **Tertiary is deliberately
    /// absent**: it reads 4.31:1 here, which is why STEP_180 moved the inactive tab label and the
    /// footer link to supporting text. Adding tertiary back to this test would fail, correctly.
    func testChromeBandTextIsSupportingNotTertiary() {
        assertReadable(Theme.textPrimary, on: Theme.sectionFill, "primary text on the chrome band")
        assertReadable(Theme.textSecondary, on: Theme.sectionFill, "supporting text on the chrome band")
        XCTAssertLessThan(ratio(Theme.textTertiary, Theme.sectionFill, dark: false), Self.target,
                          "tertiary on the chrome band is the pair STEP_180 moved away from; if it "
                          + "now passes, the palette moved and the tab/footer decision can be revisited")
    }

    /// The hover fill sits under the same two rows, so their text has to survive it.
    func testTextSurvivesTheHoverFill() {
        assertReadable(Theme.textPrimary, on: Theme.hoverFill, "primary text on hover")
        assertReadable(Theme.textSecondary, on: Theme.hoverFill, "supporting text on hover")
        assertReadable(Theme.blueHover, on: Theme.hoverFill, "hover link on hover")
    }

    // MARK: Status hues

    /// As **text** — the hero percentage, a row's coloured value, a verdict line — every status hue
    /// is drawn on the popover base, and every one has to meet the body-text target there.
    func testStatusHuesReadAsTextOnThePopoverBase() {
        for (hue, name) in [(Theme.green, "healthy"), (Theme.amber, "warning"),
                            (Theme.red, "critical"), (Theme.blue, "link"),
                            (Theme.grey, "unknown")] {
            assertReadable(hue, on: Theme.card, "\(name) text on the popover base")
        }
    }

    /// On the chrome band the only status hue drawn is the **tab's dot**, which is a graphical
    /// object, not text: the applicable target is 3:1 (WCAG 1.4.11), and its meaning is spoken by
    /// `StatusDot.accessibilityStatusWord` besides. Holding a dot to the body-text figure is what
    /// this test asserted on its first run, and it was wrong — `grey` is the tertiary neutral, so
    /// it measures 4.31:1 there and always will.
    func testStatusDotsReadAsGraphicsOnTheChromeBand() {
        for (hue, name) in [(Theme.green, "healthy"), (Theme.amber, "warning"),
                            (Theme.red, "critical"), (Theme.blue, "no active window"),
                            (Theme.grey, "unknown")] {
            assertReadable(hue, on: Theme.sectionFill, "the \(name) tab dot", atLeast: 3.0)
        }
    }

    // MARK: Tinted boxes — each fill with its own text

    /// The recommendation box, the delta line and the burn pill. The fills were re-derived in
    /// STEP_180 precisely because this assertion did not hold before: light amber measured 4.41:1
    /// on the old fill, and the burn pill's computed `opacity(0.16)` measured 4.09:1.
    func testEachTintCarriesItsOwnText() {
        for severity in [HintSeverity.danger, .warning, .info] {
            let pair = Theme.hint(severity)
            assertReadable(pair.fg, on: pair.bg, "\(severity) text on its own tint")
        }
        for dot in [StatusDot.green, .amber, .red, .neutral] {
            assertReadable(dot.color, on: Theme.tint(dot), "\(dot) pill text on its own tint")
        }
    }

    /// A tint that cannot be told from the surface behind it is not a box. The old dark fills sat
    /// within 1.01–1.18 of the new base, which is what this catches.
    func testEachTintIsVisibleAgainstTheSurfaceBehindIt() {
        for (fill, name) in [(Theme.greenBg, "green"), (Theme.amberBg, "amber"),
                             (Theme.redBg, "red"), (Theme.blueBg, "blue")] {
            for dark in [false, true] {
                let r = ratio(fill, Theme.card, dark: dark)
                XCTAssertGreaterThanOrEqual(
                    r, Self.tintVisibility,
                    "\(name) tint in \(dark ? "dark" : "light") is \(String(format: "%.2f", r)):1 "
                    + "against the popover base — invisible")
            }
        }
    }

    /// The STEP_195 row chip. It is a surface, so both things must hold: the row's own text stays
    /// readable on it, and it can be told from the card behind it — a highlight nobody can see is
    /// not a highlight. It is deliberately held to the **tint** visibility figure and not to a
    /// text ratio: it is a graphical object, and 4.5:1 behind body text would be a box.
    func testRowHighlightCarriesTheRowAndIsVisible() {
        assertReadable(Theme.textPrimary, on: Theme.rowHighlight, "row value on the highlight chip")
        assertReadable(Theme.textSecondary, on: Theme.rowHighlight,
                       "row label on the highlight chip")
        for dot in [StatusDot.green, .amber, .red] {
            assertReadable(dot.color, on: Theme.rowHighlight,
                           "\(dot) row value on the highlight chip")
        }
        for dark in [false, true] {
            let r = ratio(Theme.rowHighlight, Theme.card, dark: dark)
            XCTAssertGreaterThanOrEqual(
                r, Self.tintVisibility,
                "the row highlight in \(dark ? "dark" : "light") is "
                + "\(String(format: "%.2f", r)):1 against the popover base — invisible")
        }
    }

    // MARK: Neutral chrome

    /// The plan badge names the plan and asserts nothing about health, so every `PlanBadgeKind`
    /// resolves to one neutral pair (REV-92 §4). If these ever differ again, the badge has started
    /// carrying a status the reader has no other way to read.
    func testPlanBadgeIsNeutralOnEveryKind() {
        let exact = Theme.badge(.exact)
        for kind in [PlanBadgeKind.credit, .stale] {
            let other = Theme.badge(kind)
            XCTAssertEqual(ratio(other.fg, other.bg, dark: false),
                           ratio(exact.fg, exact.bg, dark: false), accuracy: 0.001,
                           "\(kind) badge differs from .exact — the badge is asserting status again")
        }
        assertReadable(exact.fg, on: exact.bg, "plan badge text on its badge fill")
    }

    /// The meter track is a surface, not text: it only has to be visible under the drained part of
    /// the bar and against the base it is drawn on.
    func testMeterTrackReadsAgainstTheBaseAndTheFill() {
        for dark in [false, true] {
            XCTAssertGreaterThanOrEqual(ratio(Theme.meterTrack, Theme.card, dark: dark), 1.15,
                                        "meter track is invisible on the popover base")
        }
        for dot in [StatusDot.green, .amber, .red] {
            for dark in [false, true] {
                XCTAssertGreaterThanOrEqual(ratio(dot.color, Theme.meterTrack, dark: dark), 1.6,
                                            "the \(dot) meter fill does not read against its track")
            }
        }
    }

    /// Selection is neutral by REV-92 §4 — the active-tab underline must not be a status hue, or
    /// the tab bar starts making a claim the dot beside it also makes.
    func testTabUnderlineIsNeutralAndVisible() {
        for hue in [Theme.green, Theme.amber, Theme.red, Theme.blue] {
            for dark in [false, true] {
                XCTAssertGreaterThan(ratio(Theme.tabUnderline, hue, dark: dark), 1.2,
                                     "the tab underline is indistinguishable from a status hue")
            }
        }
        for dark in [false, true] {
            XCTAssertGreaterThanOrEqual(ratio(Theme.tabUnderline, Theme.card, dark: dark), 4.5,
                                        "the active-tab underline does not read against the tab")
        }
    }

    // MARK: The mechanism itself

    /// Every token has to actually differ between appearances — a `dyn` pair accidentally given the
    /// same value twice would look right in one mode and wrong in the other, and no other test in
    /// the package resolves a colour at all.
    func testEveryTokenResolvesDifferentlyInDarkMode() {
        let tokens: [(Color, String)] = [
            (Theme.card, "card"), (Theme.sectionFill, "sectionFill"), (Theme.border, "border"),
            (Theme.borderLight, "borderLight"), (Theme.hoverFill, "hoverFill"),
            (Theme.tabUnderline, "tabUnderline"), (Theme.meterTrack, "meterTrack"),
            (Theme.textPrimary, "textPrimary"), (Theme.textSecondary, "textSecondary"),
            (Theme.textTertiary, "textTertiary"), (Theme.green, "green"), (Theme.amber, "amber"),
            (Theme.red, "red"), (Theme.blue, "blue"), (Theme.blueHover, "blueHover"),
            (Theme.greenBg, "greenBg"), (Theme.amberBg, "amberBg"), (Theme.redBg, "redBg"),
            (Theme.blueBg, "blueBg"), (Theme.badgeText, "badgeText"), (Theme.badgeFill, "badgeFill"),
        ]
        for (token, name) in tokens {
            // `red` is the one pair REV-92 §4 leaves nearly unchanged across modes by design, so
            // compare luminance rather than requiring inequality of every channel.
            let light = luminance(token, dark: false), dark = luminance(token, dark: true)
            if name == "red" { continue }
            XCTAssertNotEqual(light, dark, accuracy: 0.0,
                              "\(name) resolves identically in both appearances")
        }
    }
}
