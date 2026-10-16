import SwiftUI
import KvotarCore

/// The Explore quota trend chart (STEP_183 — REV-93 / UI Spec §6.3): one provider's observed
/// quota windows, drawn against a 0–100 % **used** axis.
///
/// Nothing in the window plotted points before this: the day strip and the hour chart are both
/// bar shapes. So this is a new primitive, built to the conventions those two already set —
/// the block itself is the keyboard stop, `←`/`→` move the selection, and every drawn mark is a
/// value the model already decided (`x`, `fraction`, `kind`, `hitLimit`, `accessibilityValue`,
/// the axis ticks, the in-place labels and the hover card). The
/// only arithmetic here is a fraction times a size, and its inverse for the pointer.
///
/// **No legend.** Every ended window is the same dot, a partly seen one faded; the open window
/// is a ring labelled `So far` beside it; a limit hit is a diamond labelled `Hit the limit`
/// where the model finds room. The sentence above carries the counts and the hover card names
/// the rest, so a key under the chart would only repeat them.
///
/// **`% used`, not `% left`.** This is the narrow retrospective exception (§6.1): the chart shows
/// consumption ending at a limit, so 100 % sits at the top. Every live surface in the app stays
/// `% left`, and the axis is labelled so the two can never be confused.
struct QuotaChartView: View {
    let section: HistoryExperience.QuotaSection
    let selectedID: String?
    /// A week-scoped arrival dims what it is not about. The points themselves are unchanged —
    /// the section's factual sentence still describes all thirty days, which is what it says.
    let scope: HistoryViewModel.Scope?
    @ObservedObject var vm: HistoryViewModel

    /// The short-window strip: dense, so low. The dates under it carry the horizontal meaning.
    private let plotHeight: CGFloat = 130
    /// Room under the plot for the tick marks and their labels.
    private let axisHeight: CGFloat = 26
    private let gutter: CGFloat = 34
    /// The margin the model reserves to the right of the period's end for the open window's
    /// label (`QuotaSection.rightMargin`).
    private var rightPad: CGFloat { HistoryExperience.QuotaSection.rightMargin }
    private let markSize: CGFloat = 9
    private var tickLabelWidth: CGFloat { HistoryExperience.QuotaSection.tickLabelWidth }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HistoryEyebrow(text: "% used")
            plot
            // The unjoined-run sentence is the same one for every such run, so it is stated once
            // under the chart rather than per segment — three copies of one caveat is noise, not
            // three facts.
            if let note = section.segments.compactMap(\.widthNote).first {
                HistoryNote(text: note)
            }
        }
    }

    // MARK: Plot

    private var hover: HistoryExperience.QuotaHover? {
        vm.quotaHover?.provider == section.provider ? vm.quotaHover : nil
    }

    private var plot: some View {
        GeometryReader { geo in
            let width = max(geo.size.width - gutter - rightPad, 1)
            let labelSides = section.inPlaceLabelSides(plotWidth: width)
            ZStack(alignment: .topLeading) {
                axis(width: width)
                ForEach(Array(section.segments.enumerated()), id: \.offset) { index, segment in
                    boundary(segment, isFirst: index == 0, width: width)
                    if segment.connects { line(segment, width: width) }
                }
                ForEach(section.points) { point in
                    mark(point, width: width)
                    if let text = point.inPlaceLabel, let side = labelSides[point.id] {
                        inPlaceLabel(text, for: point, side: side, width: width)
                    }
                }
                if let hover { cursor(hover, width: width) }
            }
            .contentShape(Rectangle())
            // The pointer anywhere over the plot resolves to the nearest window, at once — the
            // macOS tooltip appeared late and only over a 9 pt mark.
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    vm.quotaHover(section, atX: fraction(of: location.x, width: width))
                case .ended:
                    vm.quotaHoverEnded()
                }
            }
            .onTapGesture(coordinateSpace: .local) { location in
                vm.selectQuotaPoint(nearestTo: section, atX: fraction(of: location.x, width: width))
            }
        }
        .frame(height: plotHeight + axisHeight)
        .focusable()
        // Keep the chart as one keyboard stop, but not the chart-sized blue system frame. The
        // selected quota mark retains its own visible outline.
        .focusEffectDisabled()
        .onMoveCommand { direction in
            let points = section.points
            guard !points.isEmpty else { return }
            let index = points.firstIndex { $0.id == selectedID } ?? points.count - 1
            switch direction {
            case .left where index > 0: vm.selectQuotaPoint(points[index - 1].id)
            case .right where index + 1 < points.count: vm.selectQuotaPoint(points[index + 1].id)
            default: break
            }
        }
        .accessibilityLabel("\(section.title) chart")
    }

    /// The inverse of `gutter + width × x`: where the pointer is across the period, 0…1.
    private func fraction(of pointX: CGFloat, width: CGFloat) -> Double {
        min(max((pointX - gutter) / width, 0), 1)
    }

    /// The gridlines the model named: `% used` lines with their gutter labels, and the date
    /// ticks under the baseline — a faint gridline, a 7 pt mark and a label at a labelled tick,
    /// a 3 pt mark at a midnight.
    @ViewBuilder
    private func axis(width: CGFloat) -> some View {
        ForEach(section.valueLabels, id: \.fraction) { value in
            let y = plotHeight * (1 - value.fraction)
            HStack(spacing: 5) {
                Text(value.label)
                    .font(HistoryTheme.note)
                    .monospacedDigit()
                    .foregroundStyle(HistoryTheme.tertiary)
                    .frame(width: gutter - 5, alignment: .trailing)
                Rectangle()
                    .fill(HistoryTheme.line)
                    .frame(width: width, height: 1)
                    .opacity(value.prominent ? 1 : 0.5)
            }
            .offset(y: y - 5)
        }
        let labelled = section.labelledTickIDs(plotWidth: width)
        ForEach(section.ticks) { tick in
            let x = gutter + width * tick.x
            if let label = tick.label {
                Rectangle()
                    .fill(HistoryTheme.line.opacity(0.45))
                    .frame(width: 1, height: plotHeight)
                    .offset(x: x)
                Rectangle()
                    .fill(HistoryTheme.secondary)
                    .frame(width: 1, height: 7)
                    .offset(x: x, y: plotHeight)
                if labelled.contains(tick.id) {
                    let center = HistoryExperience.QuotaSection.tickLabelCenter(
                        x: tick.x, plotWidth: width)
                    Text(label)
                        .font(HistoryTheme.note)
                        .monospacedDigit()
                        .foregroundStyle(HistoryTheme.secondary)
                        .fixedSize()
                        .frame(width: tickLabelWidth)
                        .offset(x: gutter + center - tickLabelWidth / 2, y: plotHeight + 10)
                }
            } else {
                Rectangle()
                    .fill(HistoryTheme.line)
                    .frame(width: 1, height: 3)
                    .offset(x: x, y: plotHeight)
            }
        }
    }

    /// Where a segment begins — a dashed hairline carrying the reason as its hover and spoken
    /// text. The first segment of a section starts at the edge of the evidence and needs none.
    @ViewBuilder
    private func boundary(_ segment: HistoryExperience.QuotaSegment, isFirst: Bool,
                          width: CGFloat) -> some View {
        if !isFirst, let note = segment.boundaryNote,
           let first = section.points.first(where: { $0.id == segment.pointIDs.first }) {
            Rectangle()
                .fill(HistoryTheme.line)
                .frame(width: 1, height: plotHeight)
                .offset(x: gutter + width * first.x)
                .help(note)
                .accessibilityElement()
                .accessibilityLabel(note)
        }
    }

    /// The connecting line, drawn only where the model says these windows abut
    /// (`QuotaSegment.connects`), and only through ended windows — the open one stands at its
    /// last reading, not at a reset, so a line to it would join unlike instants. Thin and faint:
    /// on a strip of ninety windows the line is the eye's guide through the run, not the figure.
    /// A run whose widths were never recorded has no defensible start, so it stays a group of
    /// separate points.
    private func line(_ segment: HistoryExperience.QuotaSegment, width: CGFloat) -> some View {
        let points = segment.pointIDs.compactMap { id in
            section.points.first { $0.id == id && $0.kind != .current }
        }
        return Path { path in
            for (index, point) in points.enumerated() {
                let position = CGPoint(x: gutter + width * point.x,
                                       y: plotHeight * (1 - point.fraction))
                if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
            }
        }
        .stroke(HistoryTheme.accent(section.provider).opacity(0.4),
                style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        .allowsHitTesting(false)
    }

    private func mark(_ point: HistoryExperience.QuotaPoint, width: CGFloat) -> some View {
        let isSelected = point.id == selectedID
        let dimmed = scope?.hasWeek == true && !(scope?.contains(point.at) ?? false)
        var traits: AccessibilityTraits = [.isButton]
        if isSelected { _ = traits.insert(.isSelected) }
        return QuotaMark(point: point, accent: HistoryTheme.accent(section.provider),
                         size: markSize, isSelected: isSelected)
            .opacity(dimmed ? 0.25 : 1)
            .position(x: gutter + width * point.x, y: plotHeight * (1 - point.fraction))
            // The pointer is handled by the plot (nearest window on x); the mark itself takes
            // no hits, and VoiceOver selects it through its action.
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(point.detail.title)
            .accessibilityValue(point.accessibilityValue)
            .accessibilityAddTraits(traits)
            .accessibilityAction { vm.selectQuotaPoint(point.id) }
    }

    /// The words beside a mark, on the side the model chose. The mark's own accessibility value
    /// already says the same thing, so the label is decoration to VoiceOver.
    private func inPlaceLabel(_ text: String, for point: HistoryExperience.QuotaPoint,
                              side: HistoryExperience.QuotaSection.LabelSide,
                              width: CGFloat) -> some View {
        let gap = HistoryExperience.QuotaSection.inPlaceLabelGap
        let labelWidth = HistoryExperience.QuotaSection.inPlaceLabelWidth
        let markX = gutter + width * point.x
        let center = side == .right ? markX + gap + labelWidth / 2 : markX - gap - labelWidth / 2
        return Text(text)
            .font(HistoryTheme.note)
            .foregroundStyle(HistoryTheme.secondary)
            .fixedSize()
            .frame(width: labelWidth, alignment: side == .right ? .leading : .trailing)
            .position(x: center, y: plotHeight * (1 - point.fraction))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// The hover: a faint cursor line through the plot and the axis, a ring on the nearest mark,
    /// and the card — the day strip's own overlay, anchored to the line so it sits just under the
    /// axis and flips above or slides in from the window's edge when there is no room. The line
    /// is placed with `position`, not `offset`: the overlay reads the anchor's layout frame, and
    /// an offset is not part of it.
    @ViewBuilder
    private func cursor(_ hover: HistoryExperience.QuotaHover, width: CGFloat) -> some View {
        Rectangle()
            .fill(HistoryTheme.text.opacity(0.2))
            .frame(width: 1, height: plotHeight + axisHeight)
            .position(x: gutter + width * hover.cursorX, y: (plotHeight + axisHeight) / 2)
            .allowsHitTesting(false)
            .anchorPreference(key: DayHoverAnchorKey.self, value: .bounds) {
                [.quota(hover.pointID): DayHoverAnchor(bounds: $0, body: hover.body)]
            }
        if let point = section.points.first(where: { $0.id == hover.pointID }) {
            Circle()
                .strokeBorder(HistoryTheme.text.opacity(0.65), lineWidth: 1.5)
                .frame(width: markSize + 8, height: markSize + 8)
                .position(x: gutter + width * point.x, y: plotHeight * (1 - point.fraction))
                .allowsHitTesting(false)
        }
    }
}

/// One drawn window. **One shape for every ended window** (§6.3 as redrawn): a filled dot in
/// the provider's colour; a window Kvotar saw only part of is the same dot faded, with the fact
/// in the hover, the detail and the sentence; the open window is a hollow ring; and a window
/// seen at the limit is a red diamond whatever else it is. Shape and colour carry the state
/// together, and the labels beside the ring and the diamond say what they are.
private struct QuotaMark: View {
    let point: HistoryExperience.QuotaPoint
    let accent: Color
    let size: CGFloat
    let isSelected: Bool

    var body: some View {
        shape
            .frame(width: size, height: size)
            .overlay {
                if isSelected {
                    Circle()
                        .strokeBorder(HistoryTheme.text, lineWidth: 2)
                        .frame(width: size + 7, height: size + 7)
                }
            }
    }

    @ViewBuilder private var shape: some View {
        if point.hitLimit {
            Rectangle().rotation(.degrees(45)).fill(HistoryTheme.redAccent)
                .opacity(point.kind == .completedPartial ? 0.4 : 1)
        } else {
            switch point.kind {
            case .completedFull:
                Circle().fill(accent)
            case .completedPartial:
                Circle().fill(accent).opacity(0.4)
            case .current:
                ZStack {
                    Circle().fill(HistoryTheme.surface)
                    Circle().strokeBorder(accent, lineWidth: 1.5)
                }
            }
        }
    }
}
