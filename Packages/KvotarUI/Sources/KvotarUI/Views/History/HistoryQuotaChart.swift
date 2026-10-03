import SwiftUI
import KvotarCore

/// The Explore quota trend chart (STEP_183 — REV-93 / UI Spec §6.3): one provider's observed
/// quota windows, drawn against a 0–100 % **used** axis.
///
/// Nothing in the window plotted points before this: the day strip and the hour chart are both
/// bar shapes. So this is a new primitive, built to the conventions those two already set —
/// the block itself is the keyboard stop, `←`/`→` move the selection, and every drawn mark is a
/// value the model already decided (`x`, `fraction`, `kind`, `hitLimit`, `accessibilityValue`).
/// The only arithmetic here is a fraction times a size.
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
    /// The report period, from the window's own header — the axis runs across exactly this span,
    /// and printing it is what gives the horizontal dimension a meaning. The string is the
    /// model's; nothing here formats a date.
    let periodLabel: String
    let onSelect: (String) -> Void

    private let plotHeight: CGFloat = 180
    private let gutter: CGFloat = 34
    /// Room for a mark sitting exactly at the end of the period (the open window usually does).
    private let rightPad: CGFloat = 8
    private let markSize: CGFloat = 9
    /// Half the invisible hit area around a mark: the marks are small and, on a busy Claude
    /// account, close together.
    private let hitInset: CGFloat = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HistoryEyebrow(text: "% used")
            plot
            HStack(spacing: 8) {
                QuotaChartLegend()
                Spacer(minLength: 8)
                Text(periodLabel)
                    .font(HistoryTheme.note)
                    .monospacedDigit()
                    .foregroundStyle(HistoryTheme.tertiary)
            }
            // The unjoined-run sentence is the same one for every such run, so it is stated once
            // under the chart rather than per segment — three copies of one caveat is noise, not
            // three facts.
            if let note = section.segments.compactMap(\.widthNote).first {
                HistoryNote(text: note)
            }
        }
    }

    // MARK: Plot

    private var plot: some View {
        GeometryReader { geo in
            let width = max(geo.size.width - gutter - rightPad, 1)
            ZStack(alignment: .topLeading) {
                axis(width: width)
                ForEach(Array(section.segments.enumerated()), id: \.offset) { index, segment in
                    boundary(segment, isFirst: index == 0, width: width)
                    if segment.connects { line(segment, width: width) }
                }
                ForEach(section.points) { point in
                    mark(point, width: width)
                }
            }
        }
        .frame(height: plotHeight)
        .focusable()
        // Keep the chart as one keyboard stop, but not the chart-sized blue system frame. The
        // selected quota mark retains its own visible outline.
        .focusEffectDisabled()
        .onMoveCommand { direction in
            let points = section.points
            guard !points.isEmpty else { return }
            let index = points.firstIndex { $0.id == selectedID } ?? points.count - 1
            switch direction {
            case .left where index > 0: onSelect(points[index - 1].id)
            case .right where index + 1 < points.count: onSelect(points[index + 1].id)
            default: break
            }
        }
        .accessibilityLabel("\(section.title) chart")
    }

    /// 0 / 50 / 100 gridlines with their labels in the gutter. The 100 % line is the limit and
    /// is drawn solid; 50 % is a hint and is drawn faint.
    private func axis(width: CGFloat) -> some View {
        ForEach([100.0, 50.0, 0.0], id: \.self) { value in
            let y = plotHeight * (1 - value / 100)
            HStack(spacing: 5) {
                Text("\(Int(value))")
                    .font(HistoryTheme.note)
                    .monospacedDigit()
                    .foregroundStyle(HistoryTheme.tertiary)
                    .frame(width: gutter - 5, alignment: .trailing)
                Rectangle()
                    .fill(HistoryTheme.line)
                    .frame(width: width, height: 1)
                    .opacity(value == 50 ? 0.5 : 1)
            }
            .offset(y: y - 5)
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
    /// (`QuotaSegment.connects`). A run whose widths were never recorded has no defensible start,
    /// so it stays a group of separate points.
    private func line(_ segment: HistoryExperience.QuotaSegment, width: CGFloat) -> some View {
        let points = segment.pointIDs.compactMap { id in
            section.points.first { $0.id == id }
        }
        return Path { path in
            for (index, point) in points.enumerated() {
                let position = CGPoint(x: gutter + width * point.x,
                                       y: plotHeight * (1 - point.fraction))
                if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
            }
        }
        .stroke(HistoryTheme.accent(section.provider).opacity(0.72),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        .allowsHitTesting(false)
    }

    private func mark(_ point: HistoryExperience.QuotaPoint, width: CGFloat) -> some View {
        let isSelected = point.id == selectedID
        let dimmed = scope?.hasWeek == true && !(scope?.contains(point.at) ?? false)
        var traits: AccessibilityTraits = [.isButton]
        if isSelected { _ = traits.insert(.isSelected) }
        return QuotaMark(point: point, accent: HistoryTheme.accent(section.provider),
                         size: markSize, isSelected: isSelected)
            .frame(width: markSize + hitInset * 2, height: markSize + hitInset * 2)
            .contentShape(Rectangle())
            .opacity(dimmed ? 0.25 : 1)
            .position(x: gutter + width * point.x, y: plotHeight * (1 - point.fraction))
            .onTapGesture { onSelect(point.id) }
            .help(point.accessibilityValue)
            .accessibilityElement()
            .accessibilityLabel(point.detail.title)
            .accessibilityValue(point.accessibilityValue)
            .accessibilityAddTraits(traits)
    }

}

/// One drawn window. **Shape carries the state and colour only supplements it** (§6.3): a filled
/// dot completed and fully observed, a hollow ring where the figure is a lower bound, a dashed
/// ring for the window still open, and a diamond wherever the limit was reached.
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
        let stateColor = point.hitLimit
            ? HistoryTheme.redAccent
            : (point.kind == .completedPartial ? HistoryTheme.warn : accent)
        switch point.kind {
        case .completedFull:
            outline.fill(stateColor)
        case .completedPartial:
            ZStack {
                outline.fill(HistoryTheme.surface)
                outline.stroke(stateColor,
                               style: StrokeStyle(lineWidth: 2.5, dash: [2, 2]))
            }
        case .current:
            ZStack {
                outline.fill(HistoryTheme.surface)
                outline.stroke(accent, style: StrokeStyle(lineWidth: 1.5, dash: [2.5, 2]))
            }
        }
    }

    /// The limit mark is a diamond, so a blocked window is distinguishable from a busy one with
    /// the colour switched off — and it composes with the fill rules above rather than replacing
    /// them.
    private var outline: AnyShape {
        point.hitLimit
            ? AnyShape(Rectangle().rotation(.degrees(45)))
            : AnyShape(Circle())
    }
}

/// The shape key. Static copy — it names what the marks mean, and says nothing about the data.
private struct QuotaChartLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            entry("Hit the limit", filled: true, dashed: false, diamond: true,
                  color: HistoryTheme.redAccent)
            entry("Partial", filled: false, dashed: true, diamond: false,
                  color: HistoryTheme.warn)
            entry("Completed", filled: false, dashed: false, diamond: false,
                  color: HistoryTheme.claudeAccent)
            entry("So far", filled: false, dashed: true, diamond: false,
                  color: HistoryTheme.secondary)
        }
    }

    private func entry(_ label: String, filled: Bool, dashed: Bool,
                       diamond: Bool, color: Color) -> some View {
        HStack(spacing: 5) {
            Group {
                if diamond {
                    Rectangle().rotation(.degrees(45)).fill(color)
                } else if filled {
                    Circle().fill(color)
                } else if dashed {
                    Circle().stroke(color,
                                    style: StrokeStyle(lineWidth: 1.5, dash: [2.5, 2]))
                } else {
                    Circle().stroke(color, lineWidth: 1.5)
                }
            }
            .frame(width: 8, height: 8)
            Text(label)
                .font(HistoryTheme.note)
                .foregroundStyle(HistoryTheme.tertiary)
        }
    }
}
