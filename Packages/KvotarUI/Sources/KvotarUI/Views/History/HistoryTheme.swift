import SwiftUI
import KvotarCore

/// Design tokens for the History window only (STEP_162 — visual parity with
/// `docs/Kvotar_History_Prototype_REV84.html`, user decision 2026-09-01): the window adopts
/// the prototype's exact palette and type ramp while the popover and menu bar keep `Theme`.
/// Light values are the prototype hexes; dark values are the prototype's own dark set.
/// Pure constants — no logic.
enum HistoryTheme {

    // MARK: Surfaces

    /// The scroll body behind panels (`--kh-page`).
    static let page = Theme.dyn(light: 0xF4F3F1, dark: 0x1D1D1F)
    /// The window fill — footer strip and pre-content states (`--kh-window`).
    static let window = Theme.dyn(light: 0xF7F7F6, dark: 0x242426)
    /// Panels, toolbar, tab bar, stat cards (`--kh-surface`).
    static let surface = Theme.dyn(light: 0xFFFFFF, dark: 0x303033)
    /// Bar tracks, metric tiles, unselected segment fill (`--kh-soft`).
    static let soft = Theme.dyn(light: 0xF8F7F5, dark: 0x29292C)
    /// Every hairline border and divider (`--kh-line`).
    static let line = Theme.dyn(light: 0xD9D7D3, dark: 0x49494D)

    // MARK: Text

    static let text = Theme.dyn(light: 0x222321, dark: 0xF2F2F3)
    static let secondary = Theme.dyn(light: 0x6F6E69, dark: 0xC8C5C2)
    static let tertiary = Theme.dyn(light: 0x99968F, dark: 0x9D9996)
    /// `Reset unknown` values (`--kh-warn`).
    static let warn = Theme.dyn(light: 0x9A650D, dark: 0xE0BD69)
    static let amberSoft = Theme.dyn(light: 0xFFF4DA, dark: 0x44371F)
    static let amberText = Theme.dyn(light: 0x6F531C, dark: 0xE8CF93)
    static let redAccent = Theme.dyn(light: 0xB4443C, dark: 0xE77B73)
    static let redSoft = Theme.dyn(light: 0xFFF0EE, dark: 0x472C2A)

    // MARK: Provider accents and tints (prototype `--kh-blue` / `--kh-green` families)

    static let claudeAccent = Theme.dyn(light: 0x286DAC, dark: 0x5C9FE4)
    static let codexAccent = Theme.dyn(light: 0x188473, dark: 0x43B8AA)
    static let claudeSoft = Theme.dyn(light: 0xEAF3FB, dark: 0x273B4E)
    static let codexSoft = Theme.dyn(light: 0xE9F6F2, dark: 0x263F3B)
    static let claudeVerdictBorder = Theme.dyn(light: 0xCADCEA, dark: 0x36516B)
    static let codexVerdictBorder = Theme.dyn(light: 0xC8DFDA, dark: 0x36574F)

    /// The accent for a tool's bars, tracks and tags.
    static func accent(_ tool: Tool) -> Color {
        tool == .codex ? codexAccent : claudeAccent
    }

    /// The verdict-card / limit-box tinted background for a tool.
    static func softTint(_ tool: Tool) -> Color {
        tool == .codex ? codexSoft : claudeSoft
    }

    /// The verdict-card border for a tool.
    static func verdictBorder(_ tool: Tool) -> Color {
        tool == .codex ? codexVerdictBorder : claudeVerdictBorder
    }

    // MARK: Type ramp (prototype px rendered as pt; fixed sizes are the parity trade-off —
    // the window opts out of Dynamic Type the way the prototype's px ladder does)

    /// Stable window title, 22/650.
    static let title = Font.system(size: 22, weight: .semibold)
    /// Body and labels — Variant A's unstyled 15-px default.
    static let body = Font.system(size: 15)
    static let bodyMedium = Font.system(size: 15, weight: .medium)
    static let bodySemibold = Font.system(size: 15, weight: .semibold)
    /// Primary mode navigation, 16.
    static let tab = Font.system(size: 16)
    static let tabSelected = Font.system(size: 16, weight: .semibold)
    /// Evidence-page heading, 26.
    static let modeTitle = Font.system(size: 26, weight: .semibold)
    /// Selected-day and pinned-detail heading, 20–22.
    static let h2 = Font.system(size: 22, weight: .semibold)
    /// Editorial lead, 31/1.16.
    static let editorialLead = Font.system(size: 31, weight: .semibold)
    /// Insight and panel titles, 18.
    static let panelTitle = Font.system(size: 18, weight: .semibold)
    /// Week navigation and compact stat figures, 19–20.
    static let statFigure = Font.system(size: 20, weight: .semibold)
    /// The Known-consequence figure, 27.
    static let big = Font.system(size: 27, weight: .semibold)
    /// Captions (`.kh-small`), 12.
    static let small = Font.system(size: 12)
    /// Notes, axis labels, footer, provider tags (`.kh-note`), 11.
    static let note = Font.system(size: 11)
    /// Uppercase eyebrows, 11/650 + 0.08em tracking (apply `.tracking(0.88)`).
    static let eyebrow = Font.system(size: 11, weight: .semibold)
}

/// The uppercase eyebrow line (`.kh-eyebrow`): 11/650, +0.08em, tertiary. The transform is
/// visual — the model string stays sentence case, so the byte-pinned fixtures hold.
struct HistoryEyebrow: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(HistoryTheme.eyebrow)
            .tracking(0.88)
            .foregroundStyle(HistoryTheme.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A panel note (`.kh-note`): 11 pt, tertiary unless overridden, wrapping.
struct HistoryNote: View {
    let text: String
    var color: Color = HistoryTheme.tertiary

    var body: some View {
        Text(text)
            .font(HistoryTheme.note)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The underline tab bar, shared by the window's mode navigation and Explore's `30-day
/// breakdown` dimension control (STEP_163 — the prototype's `.kh-tabs` and `.kh-dimensions`
/// are the same shape). One idiom in two hosts rather than two copies: 16-pt labels, the
/// selected one primary + semibold over a 2-pt underline. `showsBaseline` draws the
/// container hairline the dimension row needs; the mode row sits on the header's own divider.
struct UnderlineTabBar<Item: Hashable>: View {
    let items: [Item]
    let label: (Item) -> String
    @Binding var selection: Item
    var spacing: CGFloat = 18
    var showsBaseline: Bool = false
    var compact: Bool = false

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(items, id: \.self) { item in
                let selected = item == selection
                Button {
                    selection = item
                } label: {
                    Text(label(item))
                        .font(compact
                              ? Font.system(size: 14,
                                            weight: selected ? .semibold : .regular)
                              : (selected ? HistoryTheme.tabSelected : HistoryTheme.tab))
                        .foregroundStyle(selected ? HistoryTheme.text : HistoryTheme.secondary)
                        .padding(.top, compact ? 8 : 11)
                        .padding(.bottom, compact ? 10 : 13)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(selected ? HistoryTheme.text : Color.clear)
                                .frame(height: compact ? 2 : 3)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) {
            if showsBaseline {
                Rectangle().fill(HistoryTheme.line).frame(height: 1)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// One soft metric tile (the prototype's `.kh-day-metric`, STEP_163): an 11-pt tertiary label
/// over the figure, on the recessed fill. The selected day's per-provider measures.
struct HistoryMetricTile: View {
    let label: String
    let figure: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(HistoryTheme.note)
                .foregroundStyle(HistoryTheme.tertiary)
            Text(figure)
                .font(HistoryTheme.bodySemibold)
                .monospacedDigit()
                .foregroundStyle(HistoryTheme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(HistoryTheme.soft)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// The tinted, left-bordered box (the prototype's `.kh-limit-state`, STEP_163): recorded
/// events beside the day they belong to, in the filter's own accent. A container only — what
/// it holds is decided by the model.
struct HistoryTintedBox<Content: View>: View {
    var tint: Tool = .claude
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(HistoryTheme.accent(tint))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 4) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
        }
        .background(HistoryTheme.softTint(tint))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
