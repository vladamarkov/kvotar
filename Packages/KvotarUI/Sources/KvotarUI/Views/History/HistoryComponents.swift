import SwiftUI
import KvotarCore

// The History window's own primitives (STEP_115). Deliberately **not** in the popover-wide
// `Views/Components.swift`: the popover is a 340-pt column of stacked rows and none of these
// shapes belong there. Everything here draws what `HistoryScreen` already decided — the only
// arithmetic is multiplying a supplied 0…1 fraction by a width.

/// One week of *Week by week* (STEP_160 — REV-84 §5.2; restyled STEP_163 to the prototype's
/// `.kh-week-row` register): the span with tokens **and** Est. token value as separate fields
/// on its baseline, the bar — measured against the same provider's busiest week — on the line
/// below. Two lines rather than four columns because the panel is 300 pt wide and the parity
/// ramp is 16 pt; the bar supplements the numbers and never replaces them, and the
/// `Partial week` note rides under the span it qualifies.
struct WeekRowView: View {
    let row: HistoryExperience.WeekRow
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(row.label)
                    .font(HistoryTheme.body)
                    .foregroundStyle(HistoryTheme.secondary)
                Spacer(minLength: 6)
                Text(row.tokens)
                    .font(HistoryTheme.bodySemibold)
                    .monospacedDigit()
                    .foregroundStyle(row.fraction > 0 ? HistoryTheme.text
                                                      : HistoryTheme.tertiary)
                Text(row.value)
                    .font(HistoryTheme.body)
                    .monospacedDigit()
                    .foregroundStyle(HistoryTheme.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(HistoryTheme.soft)
                    Capsule().fill(accent)
                        .frame(width: max(row.fraction > 0 ? 3 : 0, geo.size.width * row.fraction))
                }
            }
            .frame(height: 6)
            if let note = row.note {
                Text(note)
                    .font(HistoryTheme.note)
                    .foregroundStyle(HistoryTheme.tertiary)
            }
        }
    }
}

/// A list of recorded events in the prototype's `.kh-event` register (STEP_163): hairline
/// separators, a 9-pt rhythm, nothing above the first row or below the last. The rows
/// themselves stay `RankedRowView` — the model already decided their words.
struct HistoryEventList: View {
    let rows: [HistoryScreen.RankedRow]
    /// A week-scoped arrival (STEP_183) lifts the rows recorded inside that week. The list is
    /// still the full 30 days: the banner above it moves the reader's attention rather than the
    /// population, so nothing the surrounding copy counts can disagree with what is drawn.
    var scope: HistoryViewModel.Scope? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    Rectangle().fill(HistoryTheme.line).frame(height: 1)
                }
                RankedRowView(ranked: row)
                    .padding(.top, index == 0 ? 0 : 9)
                    .padding(.bottom, index == rows.count - 1 ? 0 : 9)
                    .padding(.horizontal, 6)
                    .background(scope?.contains(row.at) == true
                                ? HistoryTheme.soft : Color.clear)
                    .padding(.horizontal, -6)
            }
        }
    }
}

/// A ranked row (the prototype's `.kh-row`, STEP_162): label plus optional provider tag, a
/// 6-pt accent track when the model supplied geometry, and the bold value trailing. Rows
/// without a fraction (events, observations, changes) stay text-only. The track is geometry
/// against the same provider's top row — never a cross-provider comparison (REV-70 §4.6).
struct RankedRowView: View {
    let ranked: HistoryScreen.RankedRow

    var body: some View {
        if let fraction = ranked.fraction {
            HStack(spacing: 10) {
                labelBlock.frame(width: 190, alignment: .leading)
                track(fraction)
                valueText
            }
        } else {
            // One line while both halves fit unwrapped; otherwise the value drops to its own
            // line, right-aligned (STEP_163 amendment). The incumbent single `HStack` let a
            // narrow panel wrap *both* halves — the live Summary printed `Reset early · Sep 1`
            // over three lines beside a two-line value.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    labelBlock.fixedSize()
                    Spacer(minLength: 8)
                    valueText.fixedSize()
                }
                VStack(alignment: .leading, spacing: 1) {
                    labelBlock
                    valueText.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private var labelBlock: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(ranked.row.label)
                .font(HistoryTheme.body)
                .foregroundStyle(HistoryTheme.text)
                .fixedSize(horizontal: false, vertical: true)
            if let tag = ranked.tag {
                Text(tag)
                    .font(HistoryTheme.note)
                    .foregroundStyle(HistoryTheme.tertiary)
            }
        }
    }

    private func track(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(HistoryTheme.soft)
                Capsule().fill(HistoryTheme.accent(ranked.accent ?? .claude))
                    .frame(width: max(fraction > 0 ? 3 : 0, geo.size.width * fraction))
            }
        }
        .frame(height: 6)
    }

    private var valueText: some View {
        Text(ranked.row.value)
            .font(HistoryTheme.body)
            .fontWeight(.semibold)
            .monospacedDigit()
            .foregroundStyle(ranked.warn ? HistoryTheme.warn : HistoryTheme.text)
    }
}

/// An opaque panel on the recessed page — the window's unit of content. One hairline border and a
/// modest radius; no inner shadow, nothing that reads as elevation.
struct HistoryPanel<Content: View>: View {
    var title: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(HistoryTheme.panelTitle)
                    .tracking(-0.27)
                    .foregroundStyle(HistoryTheme.text)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(HistoryTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(HistoryTheme.line, lineWidth: 1)
        }
    }
}

// MARK: - Tokens per day (STEP_116)

/// One day column's frame and its card text, reported up to the window root. Mirrors
/// `ExplanationAnchor` — same idea, a different (view-model-free) host.
struct DayHoverAnchor {
    let bounds: Anchor<CGRect>
    let body: String
}

struct DayHoverAnchorKey: PreferenceKey {
    static let defaultValue: [HistoryViewModel.HoverColumn: DayHoverAnchor] = [:]
    static func reduce(value: inout [HistoryViewModel.HoverColumn: DayHoverAnchor],
                       nextValue: () -> [HistoryViewModel.HoverColumn: DayHoverAnchor]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Tokens per day (REV-70 §4.1 item 2, restyled STEP_162 to the REV-84 prototype): one
/// full-height strip **per provider** — a bold lane label when both draw — with 31 rounded
/// columns, the block/change marks under the bars, and week-start axis labels drawn under
/// their own columns (the fixture's space-between axis drifted; quirk fix, user decision
/// 2026-09-01). The only arithmetic here is a supplied 0…1 fraction times a height. On
/// Explore the strip is selectable: click or ←/→ on the focused strip — one focus stop —
/// and the selected day's bar carries a 2-pt outline (the prototype's selection ring).
struct DayStripView: View {
    let strip: HistoryScreen.DayStrip
    @ObservedObject var vm: HistoryViewModel
    /// Explore's selection affordance (STEP_160). All three stay nil on Summary, where the
    /// strip keeps its hover-only behaviour.
    var entries: [HistoryExperience.DayEntry]? = nil
    var selectedID: Date? = nil
    var onSelect: ((Date) -> Void)? = nil

    private var selectable: Bool { entries != nil && onSelect != nil }
    /// Prototype heights: 94 for the selectable Explore strip, 70 for Summary's.
    private var barHeight: CGFloat { selectable ? 94 : 70 }
    private let labelWidth: CGFloat = 58
    private let markerSize: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            lanesBlock
            if !strip.legend.isEmpty { legend }
            if !strip.footer.isEmpty { HistoryNote(text: strip.footer) }
        }
    }

    /// The lanes; when selectable, the block itself is the keyboard stop and arrows move the
    /// selection (`.onMoveCommand` — the native radio-group idiom).
    @ViewBuilder private var lanesBlock: some View {
        let lanes = VStack(alignment: .leading, spacing: 11) {
            ForEach(Array(laneTools.enumerated()), id: \.offset) { position, tool in
                lane(tool, showsAxis: selectable || position == laneTools.count - 1)
            }
        }
        if let entries, let onSelect, !entries.isEmpty {
            lanes
                .focusable()
                // The selected bar already carries the prototype's visible outline. Suppress the
                // system effect, which otherwise frames the whole multi-lane chart in blue.
                .focusEffectDisabled()
                .onMoveCommand { direction in
                    let index = entries.firstIndex { $0.id == selectedID }
                        ?? entries.count - 1
                    switch direction {
                    case .left where index > 0:
                        onSelect(entries[index - 1].id)
                    case .right where index + 1 < entries.count:
                        onSelect(entries[index + 1].id)
                    default:
                        break
                    }
                }
        } else {
            lanes
        }
    }

    /// The token-active providers of this strip, in stacking order — one full strip each
    /// (REV-84 §3.1): fractions are already normalised per provider, so two providers on one
    /// axis would imply a token comparison.
    private var laneTools: [Tool] {
        var seen: [Tool] = []
        for point in strip.points {
            for bar in point.bars where !seen.contains(bar.tool) { seen.append(bar.tool) }
        }
        return seen
    }

    /// One provider's strip (the prototype's `.kh-lane`): bold label at left when both
    /// providers draw, then the 31 columns over one continuous baseline hairline.
    private func lane(_ tool: Tool, showsAxis: Bool) -> some View {
        HStack(alignment: .top, spacing: 9) {
            if laneTools.count > 1 {
                Text(tool.tabLabel)
                    .font(HistoryTheme.bodySemibold)
                    .foregroundStyle(HistoryTheme.text)
                    .frame(width: labelWidth, height: barHeight, alignment: .leading)
            }
            HStack(alignment: .top, spacing: 3) {
                ForEach(Array(strip.points.enumerated()), id: \.offset) { index, point in
                    column(index: index, point: point, tool: tool, showsAxis: showsAxis)
                }
            }
            .overlay(alignment: .top) {
                Rectangle().fill(HistoryTheme.line)
                    .frame(height: 1)
                    .offset(y: barHeight)
            }
        }
    }

    private func column(index: Int, point: HistoryScreen.DayPoint, tool: Tool,
                        showsAxis: Bool) -> some View {
        let id: Date? = entries?.indices.contains(index) == true ? entries?[index].id : nil
        let isSelected = id != nil && id == selectedID
        let fraction = point.bars.first { $0.tool == tool }?.fraction ?? 0
        var traits: AccessibilityTraits = []
        if onSelect != nil, id != nil { _ = traits.insert(.isButton) }
        if isSelected { _ = traits.insert(.isSelected) }
        return VStack(spacing: 5) {
            ZStack(alignment: .bottom) {
                Color.clear
                // Every day draws at least the prototype's 2-pt nub, so the selection ring
                // always has something to hold onto.
                UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2,
                                       style: .continuous)
                    .fill(HistoryTheme.accent(tool))
                    .frame(height: max(2, barHeight * fraction))
                    .frame(maxWidth: 18)
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(HistoryTheme.text, lineWidth: 2)
                                .padding(-4)
                        }
                    }
            }
            .frame(height: barHeight)
            .frame(maxWidth: .infinity)

            // The block dot is the text colour and the change diamond the provider accent
            // (prototype marks); a day can carry both, and each lane shows only its own.
            HStack(spacing: 2) {
                if point.hitLimitTools.contains(tool) {
                    Circle().fill(HistoryTheme.text)
                        .frame(width: markerSize, height: markerSize)
                }
                if point.changeTools.contains(tool) {
                    ChangeMarker(color: HistoryTheme.accent(tool), side: markerSize)
                }
            }
            .frame(height: markerSize + 2)

            if showsAxis {
                Text(point.tickLabel ?? "")
                    .font(HistoryTheme.note)
                    .foregroundStyle(HistoryTheme.tertiary)
                    .fixedSize()
                    .frame(height: 14)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { vm.dayHover(index, hovering: $0) }
        .onTapGesture {
            if let id, let onSelect { onSelect(id) }
        }
        .anchorPreference(key: DayHoverAnchorKey.self, value: .bounds) {
            [.day(index): DayHoverAnchor(bounds: $0, body: point.hoverBody)]
        }
        // The model-supplied spoken value (REV-84 §8): date, activity, block/change facts and
        // partial/no-activity state — the visual marks have no text of their own.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(point.accessibilityValue)
        .accessibilityAddTraits(traits)
    }

    private var legend: some View { ChartLegendView(entries: strip.legend) }
}

/// One chart column's bar area: a **lane per provider**, each with its own baseline, dividing
/// `totalHeight` (REV-84 §3.1 / UI Spec §6.1 — on `All` every fraction is against that
/// provider's own busiest bucket, so lanes never share a scale and no drawn height implies a
/// token comparison). One provider collapses to a single full-height lane, which is exactly
/// the legacy geometry. The selected column's bottom baseline thickens into a primary-colour
/// bar — a shape, not a colour swap (REV-84 §8).
struct ChartColumnLanes: View {
    let lanes: [Tool]
    let bars: [HistoryScreen.DayBar]
    let totalHeight: CGFloat
    let emphasiseBaseline: Bool

    var body: some View {
        let count = max(1, lanes.count)
        let laneHeight = (totalHeight - CGFloat(count - 1) * 2) / CGFloat(count)
        VStack(spacing: 2) {
            ForEach(Array(lanes.enumerated()), id: \.offset) { position, tool in
                ZStack(alignment: .bottom) {
                    Color.clear
                    if let bar = bars.first(where: { $0.tool == tool }) {
                        // A day with work is never invisible, however small its share.
                        Rectangle().fill(HistoryTheme.accent(tool))
                            .frame(height: max(2, laneHeight * bar.fraction))
                            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 2,
                                                              topTrailingRadius: 2,
                                                              style: .continuous))
                    }
                }
                .frame(height: laneHeight)
                .overlay(alignment: .bottom) {
                    let isLast = position == count - 1
                    Rectangle()
                        .fill(isLast && emphasiseBaseline ? HistoryTheme.text : HistoryTheme.line)
                        .frame(height: isLast && emphasiseBaseline ? 2 : 1)
                }
            }
        }
        .frame(height: totalHeight)
    }
}

/// The day strip's second marker shape (STEP_121): a small diamond, drawn wherever the limit-hit
/// dot is drawn and in the same accent. A rotated square rather than another round dot — two
/// meanings on one axis have to be told apart at 5 points without reading the legend.
struct ChangeMarker: View {
    let color: Color
    var side: CGFloat = 5

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: side, height: side)
            .rotationEffect(.degrees(45))
            // The rotation is drawn outside the frame, so the row reserves the diagonal.
            .frame(width: side * 1.42, height: side * 1.42)
    }
}

/// The swatch row under a chart. Shared by both charts on the page so a provider's colour and the
/// two marker shapes mean the same thing wherever they appear.
struct ChartLegendView: View {
    let entries: [HistoryScreen.DayLegendEntry]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                HStack(spacing: 4) {
                    switch entry.marker {
                    case .limitHit:
                        Circle().fill(HistoryTheme.text).frame(width: 5, height: 5)
                    case .accountChange:
                        ChangeMarker(color: HistoryTheme.secondary)
                    case .none:
                        EmptyView()
                    }
                    if entry.marker == nil, let tool = entry.tool {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(HistoryTheme.accent(tool)).frame(width: 8, height: 8)
                    }
                    Text(entry.label)
                        .font(HistoryTheme.note)
                        .foregroundStyle(HistoryTheme.tertiary)
                }
            }
        }
    }
}

// MARK: - Work by hour of day (STEP_120)

/// The hour-of-day chart inside *When did I hit limits?* (REV-73/D-80): 24 columns of work with
/// **every block drawn as its own mark** under the axis. Deliberately the `DayStripView` vocabulary
/// — same bar geometry, same baseline rule, same marker band, same hover card — because a second
/// chart language on one page would make the reader learn twice. The only arithmetic here is a
/// supplied 0…1 fraction times a height.
struct HourChartView: View {
    let chart: HistoryScreen.HourChart
    @ObservedObject var vm: HistoryViewModel

    /// Prototype metrics (STEP_163): a 110-pt bar area with 3-pt gaps, the marks in their own
    /// band under the baseline, tick labels drawn under their own columns.
    private let barHeight: CGFloat = 110
    private let markerHeight: CGFloat = 8
    private let tickHeight: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(chart.points.enumerated()), id: \.offset) { index, point in
                    column(index: index, point: point)
                }
            }
            if !chart.legend.isEmpty { ChartLegendView(entries: chart.legend) }
            HistoryNote(text: chart.caption)
        }
    }

    /// One lane per token-active provider — same rule as `DayStripView.laneTools`.
    private var laneTools: [Tool] {
        var seen: [Tool] = []
        for point in chart.points {
            for bar in point.bars where !seen.contains(bar.tool) { seen.append(bar.tool) }
        }
        return seen
    }

    private func column(index: Int, point: HistoryScreen.HourPoint) -> some View {
        VStack(spacing: 3) {
            ChartColumnLanes(lanes: laneTools, bars: point.bars, totalHeight: barHeight,
                             emphasiseBaseline: false)

            // One mark per block, never one per hour that had any: three blocks in an hour are
            // three dots, which is what makes the drawing a set of facts rather than a claim.
            HStack(spacing: 2) {
                ForEach(Array(point.blockTools.enumerated()), id: \.offset) { _, tool in
                    Circle().fill(HistoryTheme.accent(tool)).frame(width: 6, height: 6)
                }
            }
            .frame(height: markerHeight)

            Text(point.tickLabel ?? "")
                .font(HistoryTheme.note)
                .foregroundStyle(HistoryTheme.tertiary)
                .fixedSize()
                .frame(height: tickHeight)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { vm.hourHover(index, hovering: $0) }
        .anchorPreference(key: DayHoverAnchorKey.self, value: .bounds) {
            [.hour(index): DayHoverAnchor(bounds: $0, body: point.hoverBody)]
        }
    }
}

/// The day card. Reuses `ExplanationCardView` — the same chrome, the same markdown register — but
/// is a **tooltip**, not a target: it never takes hits, so the pointer can slide straight onto the
/// next day, and there is nothing to pin.
struct DayHoverOverlay: View {
    let anchors: [HistoryViewModel.HoverColumn: DayHoverAnchor]
    @ObservedObject var vm: HistoryViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A card is transparent until its own height lands — the flip decision needs it, and it is
    /// only known after a layout pass. Keyed per column, and the card `.id`-ed the same way, so
    /// two cards of equal length both measure (the bug STEP_111 hit live on 2026-08-16).
    @State private var heights: [HistoryViewModel.HoverColumn: CGFloat] = [:]

    private let cardWidth: CGFloat = 210

    var body: some View {
        GeometryReader { geo in
            if let column = vm.peekedDay, let anchor = anchors[column] {
                let rect = geo[anchor.bounds]
                let height = heights[column]
                let below = rect.maxY + 6
                let y = below + (height ?? 0) <= geo.size.height
                    ? below : max(0, rect.minY - 6 - (height ?? 0))
                let x = min(max(rect.midX - cardWidth / 2, 8), max(8, geo.size.width - cardWidth - 8))
                ExplanationCardView(markdown: anchor.body)
                    .frame(width: cardWidth)
                    .background(GeometryReader { card in
                        Color.clear.preference(key: DayCardHeightKey.self, value: card.size.height)
                    })
                    .onPreferenceChange(DayCardHeightKey.self) { heights[column] = $0 }
                    .id(column)
                    .opacity(height == nil ? 0 : 1)
                    .offset(x: x, y: y)
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: vm.peekedDay)
    }
}

private struct DayCardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
