import SwiftUI
import AppKit
import KvotarCore

/// Adaptive design-token layer for the popover. Each token is a dynamic colour that follows the
/// macOS appearance, so the popover is opaque and legible in both modes and a mode switch while it
/// is open resolves on its own — nothing here observes appearance. Pure constants, no logic.
///
/// **The values are the reviewed REV-92 §4 palette (STEP_180).** They replace the hand-picked hexes
/// derived from UI Prototype v6.1, which four REV-92 steps shipped underneath. Two deliberate
/// departures from the literal table, both measured and both recorded in REV-92 §4:
///
/// 1. **The tint fills are re-derived** (`greenBg` … `blueBg`). The table names no value for them,
///    the old light amber pair measured 4.41:1, and the old dark tints sit within 1.2:1 of the new
///    base — invisible. Each is now the strongest tint of its own hue that still clears 4.5:1
///    against that hue's text.
/// 2. **The chrome band takes supporting text, not tertiary.** The reviewed tertiary reads 4.81:1
///    on `card` and only 4.31:1 on `sectionFill`, so the two things drawn there — the inactive tab
///    labels and the History footer — use `textSecondary` (6.17:1). Tertiary keeps the reviewed
///    hex everywhere it belongs: provenance text on the popover base.
///
/// `HistoryTheme` is a separate palette and is out of scope; it borrows only `dyn` as a hex helper,
/// so that helper's behaviour must not change.
enum Theme {

    // MARK: Surfaces

    /// Opaque popover base — covers the default vibrant NSPopover material (no desktop bleed-through).
    static let card = dyn(light: 0xFFFFFF, dark: 0x282725)
    /// Slightly recessed fill — tab bar background and inactive chrome.
    static let sectionFill = dyn(light: 0xF4F2F0, dark: 0x302E2C)
    static let border = dyn(light: 0xDCD7D3, dark: 0x4A4642)
    static let borderLight = dyn(light: 0xEBE7E3, dark: 0x403C39)
    /// Behind a clickable row under the pointer (tabs, the History footer, the projects overflow).
    static let hoverFill = dyn(light: 0xF2EFEC, dark: 0x35322F)
    /// Behind the one `OTHER LIMITS` row the §2.2 strip is about (REV-96 §2.4 — STEP_195). A
    /// named fill rather than `badgeFill.opacity(0.55)`: an unnamed computed fill is a colour
    /// nobody has measured, which is exactly what STEP_180 found under the burn pill. Neutral by
    /// construction — the row already carries its own tier hue on the value, and a tinted chip
    /// under it would state the tier twice and disagree the moment one of them moved.
    static let rowHighlight = dyn(light: 0xF5F3F1, dark: 0x32302E)
    /// The 2 pt underline under the active provider tab. Neutral by REV-92 §4 — selection is not
    /// a status, so it must not borrow a status hue or the hero's ink.
    static let tabUnderline = dyn(light: 0x302C29, dark: 0xE8E2DC)
    /// The unfilled part of the header quota meter.
    static let meterTrack = dyn(light: 0xDFDBD7, dark: 0x4A4642)

    // MARK: Text

    static let textPrimary = dyn(light: 0x242220, dark: 0xF3F0ED)
    static let textSecondary = dyn(light: 0x5F5955, dark: 0xC5BEB8)
    static let textTertiary = dyn(light: 0x77716C, dark: 0xA49D97)

    // MARK: Status hues

    static let green = dyn(light: 0x347A19, dark: 0x8FC86B)
    static let amber = dyn(light: 0xA95A00, dark: 0xE3A14A)
    static let red = dyn(light: 0xA32929, dark: 0xF08A8A)
    static let blue = dyn(light: 0x145FA8, dark: 0x74AFE5)
    /// A link under the pointer. Action/information blue stays blue; only its weight changes.
    static let blueHover = dyn(light: 0x0F4F91, dark: 0x8BC0EE)
    static let grey = dyn(light: 0x77716C, dark: 0xA49D97)

    // MARK: Tinted backgrounds (hint boxes / burn pill / delta line)
    // Re-derived in STEP_180 — see departure 1 in the type comment. `ThemeContrastTests` pins the
    // pairing of each fill with its own hue; changing one without the other is what it catches.

    static let greenBg = dyn(light: 0xEBF2E8, dark: 0x363E2F)
    static let amberBg = dyn(light: 0xF8F2EB, dark: 0x42382A)
    static let redBg = dyn(light: 0xF6EAEA, dark: 0x443533)
    static let blueBg = dyn(light: 0xE8EFF6, dark: 0x333A40)

    // MARK: Plan badge (neutral — STEP_180)
    // The badge names the plan and nothing else. Its three `PlanBadgeKind` cases used to colour it
    // green / blue / grey, which made it assert account health, credits and freshness at a glance;
    // REV-92 §4 neutralises it and keeps each of those facts in the field that owns it.

    static let badgeText = dyn(light: 0x514C48, dark: 0xD8D1CB)
    static let badgeFill = dyn(light: 0xECE9E6, dark: 0x3B3835)

    // MARK: Provider accents (STEP_115 — REV-70 §4.4)
    // The History window is the first surface that draws one tool's figures beside the other's, so
    // it needs a per-tool identity colour. These are **not** status hues and must never be read as
    // one: `Theme.green` means calm, `amber` elevated, `red` critical, everywhere in the app. Used
    // only for week bars, the STEP_116 day strip, and the small provider tags on the All tab.
    // (The §0.7 categorical palette retired with D-71 — these are new tokens, not its revival.)
    static let claudeAccent = dyn(light: 0x185FA5, dark: 0x6FB0EE)
    static let codexAccent = dyn(light: 0x0F766E, dark: 0x5EC4B6)

    /// The accent for a tool's bars and tags.
    static func accent(_ tool: Tool) -> Color {
        switch tool {
        case .claude: return claudeAccent
        case .codex:  return codexAccent
        }
    }

    // The §0.7 attribution-bar palette (off-machine gray + categorical surface hues, STEP_27)
    // lived here until D-71: REV-28 removed Claude's gray split bar, D-67 the burn card's surface
    // bar, and D-71 the §2.6 surface bar (shares render as plain rows) — no bar remains in the
    // popover body, so the palette retired with its last caller.

    // MARK: Semantic mappings

    /// The colour for a status dot / value cue (single source shared with `StatusDot.color`).
    static func status(_ dot: StatusDot) -> Color {
        switch dot {
        case .green:   return green
        case .amber:   return amber
        case .red:     return red
        case .grey:    return grey
        case .neutral: return blue
        }
    }

    /// Foreground + tinted background for a hint / recommendation box.
    static func hint(_ severity: HintSeverity) -> (fg: Color, bg: Color) {
        switch severity {
        case .danger:  return (red, redBg)
        case .warning: return (amber, amberBg)
        case .info:    return (blue, blueBg)
        }
    }

    /// The tinted fill behind a status-coloured chip (the §2.4 burn pill). Shares the `hint` fills
    /// deliberately: the burn pill used to compute its own `dot.color.opacity(0.16)`, which put
    /// light amber text at 4.09:1 on white — a fill nobody had measured because nobody had named it.
    static func tint(_ dot: StatusDot) -> Color {
        switch dot {
        case .green:   return greenBg
        case .amber:   return amberBg
        case .red:     return redBg
        case .grey:    return badgeFill
        case .neutral: return blueBg
        }
    }

    /// Foreground + background for a plan badge. **Neutral on every kind since STEP_180** (REV-92
    /// §4): the badge says `Pro`, `Team`, `Enterprise` and asserts nothing about the account's
    /// health. `PlanBadgeKind` still arrives from `DisplayFormatter` and still rides the
    /// diagnostics bundle, so it is kept rather than deleted — it simply no longer picks a colour.
    /// Where each fact went: **credits** to the §2.4a credits card, which keeps information blue;
    /// **staleness** to the source tag's age stamp and the stale-keep verdict grammar.
    static func badge(_ kind: PlanBadgeKind) -> (fg: Color, bg: Color) {
        switch kind {
        case .exact, .credit, .stale: return (badgeText, badgeFill)
        }
    }

    // MARK: Menu-bar colours (STEP_29 — §0.2 tier ramp, §1.5 glyph)
    // System hues, not the popover hexes above: the menu bar is translucent/vibrancy-tinted
    // (and opaque under reduced transparency), and the system colours adapt to both — the
    // popover palette is tuned for an opaque card. Never `isTemplate`-tint these.

    /// Status-dot colour in the menu bar (matches the pre-v4.6 status-item dot mapping).
    static func menuBarStatus(_ dot: StatusDot) -> Color {
        switch dot {
        case .green:   return Color(nsColor: .systemGreen)
        case .amber:   return Color(nsColor: .systemOrange)
        case .red:     return Color(nsColor: .systemRed)
        case .grey:    return Color(nsColor: .secondaryLabelColor)
        case .neutral: return Color(nsColor: .systemBlue)
        }
    }

    /// §1.6 money-glyph colour — amber armed (money imminent), red charging (money leaving).
    /// `.none` returns nil so the caller draws no glyph. System hues, per the menu-bar note above.
    static func money(_ glyph: MoneyGlyph) -> Color? {
        switch glyph {
        case .none:     return nil
        case .armed:    return Color(nsColor: .systemOrange)
        case .charging: return Color(nsColor: .systemRed)
        }
    }

    // MARK: Dynamic colour helper

    static func dyn(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(hex: Int) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}
