import SwiftUI
import KvotarCore

/// Popover header (UI Spec §2.2): hero % + progress bar + subtitles + plan badge (+ email, Claude).
/// Rendered as the first section of the unified card. A placeholder hero (`——` / `––` / `—`) is a
/// null-window / idle marker, not a number — it renders small and muted so it never reads as a bar.
struct HeaderSectionView: View {
    let header: HeaderSection
    let dot: StatusDot
    /// Which tab this header belongs to — the anatomy pin is keyed per tool (STEP_110).
    let tool: Tool

    /// The hero number's and the meter's ink. The account's status dot everywhere except under a
    /// long-limit rank, where those two elements are about the five-hour window and the account's
    /// colour belongs to the strip and the dots instead (REV-96 §5.7 — STEP_195).
    private var heroCue: StatusDot { header.heroCue ?? dot }

    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.explanationContext) private var explanation
    // The hover *peek* (UI Spec Part 3 §5.1 — hover = peek, click = pin): all view-local,
    // transient state, which PATTERNS.md blesses for `@State`. The pin itself lives on the view
    // model because AppKit and the tab bar must be able to release it.
    /// Pointer over line 1 — the only tell on a clickable verdict (nothing at rest).
    @State private var hoveringVerdict = false
    /// Pointer over the card itself — keeps a peek alive while the user reads it.
    @State private var hoveringCard = false
    /// The peek is showing (after `ExplanationTiming.peekDelay`); dropped `.graceLeave` after the pointer
    /// leaves both the line and the card.
    @State private var peeking = false
    @State private var peekTimer: Task<Void, Never>?
    /// The header's rendered height — the card hangs directly under it (measured, not guessed).
    @State private var headerHeight: CGFloat = 0
    /// When this header last appeared. AppKit re-evaluates mouse-tracking areas while the popover
    /// window re-frames for a taller tab, and for a few hundred milliseconds the pointer's
    /// window-relative position is wrong — the verdict line receives a hover-enter although the
    /// pointer is on the tab bar (log-verified 2026-08-16: enter 15 ms after `onAppear`, exit
    /// ~250–380 ms later, Codex→Claude only, i.e. only when the popover grows). Hover-enters
    /// inside `ExplanationTiming.settle` of appearing are ignored; nobody rests on a line that fast.
    @State private var appearedAt = Date.distantPast

    private var heroIsPlaceholder: Bool {
        header.heroText.allSatisfy { $0 == "—" || $0 == "–" || $0 == " " }
    }

    private var pinned: Bool { vm.pinnedAnatomy == tool }
    private var cardShowing: Bool { header.verdict?.anatomy != nil && (pinned || peeking) }

    var body: some View {
        SectionCard {
            headerContent
        }
        .background(GeometryReader { geo in
            Color.clear.preference(key: HeaderHeightKey.self, value: geo.size.height)
        })
        .onPreferenceChange(HeaderHeightKey.self) { headerHeight = $0 }
        // The anatomy is the biggest hover card (UI Spec Part 3 §5.1/§5.3): it hangs directly under
        // the header, over the rows beneath, *inside the popover's existing bounds* — the popover
        // never changes size or position (growing it moved the whole window on 2026-08-16: an
        // NSPopover that outgrows the space under the menu bar is re-fitted by AppKit). Hover =
        // peek, click = pin. While pinned, a transparent scrim behind the card catches the next
        // click anywhere in the content — including on the verdict line itself — and releases the
        // pin. `zIndex` lifts card and scrim above the sibling sections that follow.
        .overlay(alignment: .top) {
            ZStack(alignment: .top) {
                if pinned {
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(height: 4000)
                        .onTapGesture { vm.releasePinnedAnatomy() }
                }
                if let anatomy = header.verdict?.anatomy, pinned || peeking {
                    VerdictAnatomyView(anatomy: anatomy, pinned: pinned)
                        .padding(.horizontal, 13)
                        .padding(.top, headerHeight + 4)
                        .onHover { hovering in
                            hoveringCard = hovering
                            if hovering { peekTimer?.cancel() } else { schedulePeekEnd() }
                        }
                        .transition(reduceMotion ? .identity : .opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .zIndex(1)
        .onAppear { appearedAt = Date() }
        .onChange(of: pinned) { _, isPinned in
            // Pinning ends the peek machinery; releasing does not re-peek until the pointer moves.
            if isPinned { peekTimer?.cancel(); peeking = false }
        }
        .onChange(of: vm.activeTab) { _, _ in
            peekTimer?.cancel(); peeking = false
        }
    }

    /// Pointer entered line 1: peek after `ExplanationTiming.peekDelay`. Left it: end the peek after
    /// `.graceLeave` unless the pointer went into the card.
    private func verdictHoverChanged(_ hovering: Bool) {
        // Phantom enter during the window re-frame (see `appearedAt`): not a hover.
        if hovering, Date().timeIntervalSince(appearedAt) < ExplanationTiming.settle { return }
        hoveringVerdict = hovering
        guard header.verdict?.anatomy != nil, !pinned else { return }
        peekTimer?.cancel()
        if hovering {
            peekTimer = Task { @MainActor in
                try? await Task.sleep(for: ExplanationTiming.peekDelay)
                guard !Task.isCancelled else { return }
                if reduceMotion { peeking = true } else {
                    withAnimation(.easeInOut(duration: 0.12)) { peeking = true }
                }
            }
        } else {
            schedulePeekEnd()
        }
    }

    private func schedulePeekEnd() {
        peekTimer?.cancel()
        peekTimer = Task { @MainActor in
            try? await Task.sleep(for: ExplanationTiming.graceLeave)
            guard !Task.isCancelled, !hoveringVerdict, !hoveringCard else { return }
            if reduceMotion { peeking = false } else {
                withAnimation(.easeInOut(duration: 0.12)) { peeking = false }
            }
        }
    }

    private var headerContent: some View {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .bottom) {
                    if heroIsPlaceholder {
                        Text(header.heroText)
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textTertiary)
                    } else {
                        // E-04 (STEP_111): the hero % explains itself; a placeholder hero does not.
                        // Which element it is comes from the formatter — E-15 on the monthly
                        // layout, where the hero is a spend meter (STEP_128). No hover tell here
                        // (§5.1) — a 30 pt number changing on hover is noise; the card is the tell.
                        Text(header.heroText)
                            .font(.system(size: 30, weight: .semibold, design: .rounded)
                                .monospacedDigit())
                            .foregroundStyle(heroCue.color)
                            .explainable(header.heroExplanation,
                                         body: registryCard(header.heroExplanation),
                                         live: header.heroLive?.text,
                                         bridge: header.heroBridge?.text)
                            // STEP_180: the hero's colour is the account's status and nothing
                            // spoken carries it. The caption below already names the limit and
                            // the number reads itself, so only the missing channel is added.
                            .accessibilityValue(Text(heroCue.accessibilityStatusWord))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        PlanBadgeView(text: header.planBadge, kind: header.badgeKind)
                        if let email = header.email {
                            Text(email)
                                .font(.caption2)
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }

                // Hidden from VoiceOver on purpose (STEP_180): the meter is the hero number and
                // the caption drawn as geometry, and it has no fact of its own to add.
                ProgressBarView(progress: header.progress, dot: heroCue)
                    .accessibilityHidden(true)

                // The caption names the limit the number above it describes — `5-hour quota
                // left`, `Weekly quota left`, `GPT-5.3-Codex-Spark · Weekly quota left` (UI Spec
                // §REV92). It replaced the D-58 grain-and-reset pair at the STEP_178 cutover; the
                // reset moved to its own detail line under the verdict, so the pair is still
                // stated once. Under a primary hero the caption is still E-01 and carries E-01's
                // live line; under a promoted hero the hero number above already carries that
                // limit's card, so the caption is inert rather than a second copy of it.
                if let caption = header.limitCaption {
                    if header.limit?.id == .primaryWindow {
                        HeaderCaptionText(text: caption, restColour: Theme.textSecondary)
                            .explainable(.primaryWindow, site: "caption",
                                         body: registryCard(.primaryWindow),
                                         live: header.windowScopeLive?.text)
                    } else {
                        HeaderCaptionText(text: caption, restColour: Theme.textSecondary)
                    }
                }

                // Runway verdict (UI Spec §2.2a, REV-25; advisory voice v5.1/REV-34): two lines
                // directly under the progress bar — line 1 the state-coloured verdict, line 2
                // the muted clock-first detail. Supersedes the v4.6 weekly bar + runway timeline
                // + subtitle slots.
                // Absent on the §11.3 low-allowance shape (D-60, STEP_88) — the block is removed,
                // not filled with a placeholder.
                if let verdict = header.verdict {
                    VStack(alignment: .leading, spacing: 2) {
                        // The verdict shows its work (UI Spec Part 3 §5.3, D-73 — STEP_110): on a
                        // computed family line 1 is a plain button that toggles the anatomy block
                        // below; the only tell is an underline in the state colour while the
                        // pointer rests on it. Condition verdicts keep the inert Text.
                        if verdict.anatomy != nil {
                            Button {
                                if reduceMotion {
                                    vm.togglePinnedAnatomy(tool)
                                } else {
                                    withAnimation(.easeInOut(duration: 0.12)) { vm.togglePinnedAnatomy(tool) }
                                }
                            } label: {
                                verdictLine1(verdict, underline: hoveringVerdict || pinned)
                                    .padding(.horizontal, 3)
                                    .background(pinned ? Theme.blueBg : .clear,
                                                in: RoundedRectangle(cornerRadius: 3))
                                    .padding(.horizontal, -3)
                            }
                            .buttonStyle(.plain)
                            .onHover(perform: verdictHoverChanged)
                        } else {
                            verdictLine1(verdict, underline: false)
                        }
                        // nil on the long-window calm family (REV-66/D-70) — the row is removed,
                        // not dashed: the D-58 caption above already carries its only number.
                        // E-08 (STEP_111, whole cards since REV-75/D-90 — STEP_130): the detail
                        // line's card is *one card per verdict family*, so `detailLive` is the
                        // entire body — lead, sentence and live segment, already filled — and
                        // `card(.verdictDetail)` is nil by D-90. No `—` guard here: the formatter
                        // already returns nil wherever line 2 reads `—`, and one rule owned in one
                        // place is what keeps an inert target from recording a drop (STEP_133).
                        if let line2 = verdict.line2 {
                            HeaderCaptionText(text: line2, restColour: Theme.textTertiary)
                                .explainable(.verdictDetail, body: verdict.detailLive?.text)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }

                // The long-limit strip (UI Spec §2.2 / REV-96 §2.4 — STEP_195): one line
                // directly under line 2, because the hero above answers *am I safe right now*
                // and this answers *and is the week going to hold*. Absent in green, absent
                // while stale, absent whenever the limit already has the hero — and when it is
                // absent nothing reserves its height, so a calm header is unchanged to the pixel.
                if let strip = header.longLimitStrip {
                    LongLimitStripView(strip: strip, card: registryCard(strip.explanation))
                }

                // The hero's own detail lines (STEP_178): its reset, or on a monthly meter the
                // organisation-and-pace note. Each carries the card its retired row had.
                ForEach(Array(header.heroDetails.enumerated()), id: \.offset) { _, detail in
                    if let element = detail.explanation {
                        HeaderCaptionText(text: detail.text, restColour: Theme.textTertiary)
                            .explainable(element, site: "hero detail",
                                         body: registryCard(element))
                    } else {
                        HeaderCaptionText(text: detail.text, restColour: Theme.textTertiary)
                    }
                }

                // Model-scoped constraints never replace the account summary (REV-94). They
                // remain separately explainable and also remain present in Other Limits.
                ForEach(header.modelWarnings, id: \.id) { warning in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(warning.headline)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(warning.cue.color)
                        Text(warning.detail)
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Theme.tint(warning.cue), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .leading) {
                        Rectangle().fill(warning.cue.color).frame(width: 3)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .explainable(warning.explanation, site: "model warning",
                                 body: registryCard(warning.explanation),
                                 bridge: warning.explanationBridge?.text)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(Text(warning.resetAccessibilityText ?? ""))
                    .help(warning.resetAccessibilityText ?? warning.detail)
                }

                // `Quota burn` → `Low · 0.9%/min` and `Not seen locally` → `≈10% (est.)`
                // — one compact line each, each naming its own interval when that is not the
                // hero's (Baseline §15.2). An `.inapplicable` fact is hidden, not dashed; the
                // cards are the burn card's own, which is where they went when it was retired.
                VStack(alignment: .leading, spacing: 3) {
                    headerFactLine(header.accountBurn)
                    headerFactLine(header.notSeenLocally)
                }

                if let tag = header.sourceTag {
                    SourceTagView(tag: tag)
                }
                // D-08 header extra-usage alert row retired in v4.8 (REV-29): dollars live only in
                // the §2.4a Usage-credits card; the verdict line above carries the dollarless urgency.
            }
    }

    /// One header fact. An `.inapplicable` fact renders nothing — the shape cannot support the
    /// quantity, and a dash there would read as *we failed to fetch it* (Baseline §15.2).
    @ViewBuilder
    private func headerFactLine(_ fact: HeaderFact?) -> some View {
        if let fact, fact.isApplicable {
            HeaderFactRow(fact: fact)
                .explainable(fact.explanation, site: "header fact",
                             body: fact.explanationBody ?? registryCard(fact.explanation))
        }
    }

    /// The registry card for `element` on this tab, `nil` outside an `ExplanationContext`.
    private func registryCard(_ element: ExplanationElement) -> String? {
        explanation.flatMap { ExplanationRegistry.card(element, tool: $0.tool, grain: $0.grain) }
    }

    /// Line 1 with its optional §1.6 money-glyph prefix — one builder for the clickable and the
    /// inert form so the two can never drift apart in type or colour.
    @ViewBuilder
    private func verdictLine1(_ verdict: HeaderVerdict, underline: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            // §1.6 money glyph as a verdict prefix (accruing row, D-31): charging colour semantics
            // via the shared Theme.money path, independent of the sentence colour. A glyph, never
            // an amount (D-24).
            if verdict.moneyPrefix, let money = Theme.money(.charging) {
                Text(verdict.moneySymbol)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(money)
            }
            Text(verdict.line1)
                .font(.caption.weight(.medium))
                .foregroundStyle(verdict.colour.color)
                .underline(underline, color: verdict.colour.color)
        }
        .contentShape(Rectangle())
    }
}

/// A fact is a real label/value row, not a middot sentence. It wraps under accessibility sizes
/// but keeps the numeric edge aligned at the standard popover width.
private struct HeaderFactRow: View {
    let fact: HeaderFact
    @Environment(\.explanationHovered) private var hovered

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(fact.label)
                .explanationLabelTell(hovered, restColour: Theme.textSecondary)
            Spacer(minLength: 8)
            Text(fact.value)
                .fontWeight(.medium)
                .monospacedDigit()
                .foregroundStyle(fact.dot == .grey ? Theme.textPrimary : fact.dot.color)
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The expanded anatomy block (UI Spec Part 3 §5.3): the inputs as rows, the comparison, and the
/// flip line — verdict tier, so it may say "you". Renders exactly what `VerdictAnatomy` carries;
/// nothing is computed here (PATTERNS.md: views hold no business logic). The `*…*` in the flip
/// line marks the quoted next verdict and renders as emphasis.
struct VerdictAnatomyView: View {
    let anatomy: VerdictAnatomy
    var pinned: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if pinned {
                Text("PINNED · ESC")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Theme.blue)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            ForEach(Array(anatomy.rows.enumerated()), id: \.offset) { _, row in
                RowView(row: row, font: .caption)
            }
            Divider().padding(.vertical, 3)
            Text(anatomy.comparison)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let flip = anatomy.flip {
                Text(emphasised(flip))
                    .font(.caption)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .hoverCardChrome()
    }

    private func emphasised(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }
}

/// The §2.2 long-limit strip: a dot and a sentence on the tier's own tinted wash (REV-96 §2.4 —
/// STEP_195). Drawn exactly as the mockup has it and with the tokens the model-warning box
/// already uses, so `ThemeContrastTests` covers the pair without a new one.
///
/// **No motion.** The strip appears and disappears with a state change like every other element
/// on this header; nothing pulses, and the menu bar next to it does not either (D-117 keeps the
/// rotating reminder out of this revision).
private struct LongLimitStripView: View {
    let strip: LongLimitStrip
    let card: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            StatusDotView(dot: strip.cue, diameter: 6)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text(strip.text)
                .font(.caption.weight(.medium))
                .foregroundStyle(strip.cue.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.tint(strip.cue), in: RoundedRectangle(cornerRadius: 6))
        .explainable(strip.explanation, site: "long limit strip",
                     body: card, live: strip.explanationLive?.text)
        // STEP_180: the tier is carried by hue here, so the spoken form says it in words.
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(strip.cue.accessibilityStatusWord))
    }
}

/// A muted header caption (the D-58 window scope, verdict line 2) that carries the label tell
/// while hovered (STEP_111).
private struct HeaderCaptionText: View {
    let text: String
    let restColour: Color
    @Environment(\.explanationHovered) private var hovered

    var body: some View {
        Text(text)
            .explanationLabelTell(hovered, restColour: restColour)
            .monospacedDigit()
            .font(.caption2)
    }
}

/// The header's rendered height, so the anatomy card can hang exactly under it.
private struct HeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
