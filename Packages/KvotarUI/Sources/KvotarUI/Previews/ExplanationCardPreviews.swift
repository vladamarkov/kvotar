import SwiftUI
import KvotarCore

// The hover card in isolation (UI Spec Part 3 §5.2 rules 4–5 — STEP_131). A stub popover cannot be
// hovered in a preview, and the E-08 family cards need a live verdict to appear at all, so each
// shape is rendered here against the real registry: the template comes from
// `ExplanationRegistry`, the values are the same kind `DisplayFormatter` supplies live.
//
// The E-08 rows are *whole cards* (D-90) — body only, live line inside — which is why they are
// built through `liveLine` and passed as the body.

@MainActor
private func cardPreview(_ content: ExplanationCardContent, pinned: Bool = false) -> some View {
    ExplanationCardView(content: content, pinned: pinned)
        .frame(width: 340 - 26)
        .padding(13)
        .background(Theme.sectionFill)
}

private func concept(_ element: ExplanationElement, tool: Tool = .claude,
                     grain: String? = nil) -> String {
    ExplanationRegistry.card(element, tool: tool, grain: grain) ?? "(inert)"
}

private func live(_ element: ExplanationElement, _ variant: LiveVariant,
                  tool: Tool = .claude, _ values: [String: String?]) -> String? {
    ExplanationRegistry.liveLine(element, variant: variant, tool: tool,
                                 values: values, missing: .noWindow).text
}

// Concept text alone — every card where the line was dropped, and every element that never had one.
#Preview("Card · body only (line dropped)") {
    cardPreview(ExplanationCardContent(body: concept(.primaryWindow)))
}

// E-01 — the shape the primary quota row and the D-58 caption both show.
#Preview("Card · E-01 window") {
    cardPreview(ExplanationCardContent(
        body: concept(.primaryWindow),
        live: live(.primaryWindow, .live, ["start": "11:29 pm yesterday", "reset": "4:29 am"])))
}

// E-04 — the hero, the longest of the three runway/pace/remaining variants.
#Preview("Card · E-04 hero runway") {
    cardPreview(ExplanationCardContent(
        body: concept(.heroPercent),
        live: live(.heroPercent, .runway,
                   ["used": "56", "remaining": "44", "runway": "3h17m"])))
}

// E-07 — the subtraction, which is the widest live line in the registry.
#Preview("Card · E-07 elsewhere") {
    cardPreview(ExplanationCardContent(
        body: concept(.offMachine),
        live: live(.offMachine, .live, ["total": "56", "local": "55", "off": "1"])))
}

// E-12 — pinned, so the `PINNED · ESC` header and the live line render together.
#Preview("Card · E-12 credits on (pinned)") {
    cardPreview(ExplanationCardContent(
        body: concept(.usageCredits),
        live: live(.usageCredits, .on, ["balance": "$40.00"])),
        pinned: true)
}

// E-08 · exhaustion — the tallest verdict-family card, the one that must fit under line 2 on a
// five-row tab inside the 340 pt popover (rule 5).
#Preview("Card · E-08 exhaustion (tallest)") {
    cardPreview(ExplanationCardContent(
        body: live(.verdictDetail, .exhaustion,
                   ["runway": "18m", "countdown": "2h 14m", "stops": "10:23 pm"]) ?? "(inert)"))
}

// E-08 · weeklyElevated — the family whose card is a different concept ("Two resets"), not a
// longer runway sentence.
#Preview("Card · E-08 weekly elevated") {
    cardPreview(ExplanationCardContent(
        body: live(.verdictDetail, .weeklyElevated,
                   ["wkReset": "Mon 9:00 am", "reset": "4:29 am"]) ?? "(inert)"))
}

// E-08 · monthlyOnPace — the Enterprise monthly family (REV-75 §2's July bundle numbers).
#Preview("Card · E-08 monthly on pace") {
    cardPreview(ExplanationCardContent(
        body: live(.verdictDetail, .monthlyOnPace,
                   ["pace": "$1.51", "limit": "$120.00"]) ?? "(inert)"))
}
