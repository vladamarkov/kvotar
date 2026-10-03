import SwiftUI
import KvotarCore

/// The status-item content for every §1.0 display mode (Baseline §14.1) — one tool renders as
/// a single reduced-size row (D-107) — the same view renders
/// inside the live `NSStatusItem` (via `NSHostingView`, MenuBarController) and in the Xcode
/// previews, so the previews *are* the implementation. Pure presentation of one `MenuBarRender`;
/// no logic. Monospaced digits throughout (§1.0 width stability).
public struct MenuBarItemView: View {
    /// What this render is for (REV-98 §2.4 — STEP_203).
    ///
    /// **A thing fitted to a measurement cannot be one of the things measured.** Variant D's
    /// headline scales to fill the width the item reserves, so the pass that *computes* that
    /// width has to draw the row form instead — otherwise the reservation would chase the
    /// headline that is chasing the reservation. `.measuring` is therefore not a debug mode: it
    /// is the honest statement that a width pass and a draw pass are different questions.
    ///
    /// `.measuring` also runs no crossfade and holds no state, which is what lets
    /// `MenuBarController` measure five phase candidates through a hosting view without firing
    /// five transitions.
    public enum Layout: Equatable, Sendable {
        /// The row form for every phase, at intrinsic width. Previews, the onboarding strip, the
        /// width pass.
        case measuring
        /// The live item: variant D, the §2.4a crossfade, and the headline fitted into the width
        /// `MenuBarWidth.phaseRenders` already reserved.
        case drawing(width: CGFloat)
    }

    public let render: MenuBarRender
    public let layout: Layout

    public init(render: MenuBarRender, layout: Layout = .measuring) {
        self.render = render
        self.layout = layout
    }

    public var body: some View {
        switch layout {
        case .measuring:
            MenuBarLayers(render: render, headlineWidth: nil, motion: .live(pulseDelay: 0))
        case .drawing(let width):
            MenuBarCrossfade(render: render, width: width)
        }
    }
}

/// How a drawn layer animates.
///
/// The outgoing half of a crossfade is `frozen`: it is an image on its way out, and a pulse on it
/// would be the second opacity animation §2.4a sequences away — the prototype pauses it for the
/// same reason.
enum MenuBarLayerMotion: Equatable {
    case live(pulseDelay: TimeInterval)
    case frozen
}

/// The §2.4a crossfade: two layers, one fixed box (REV-98 §2.4a — STEP_203).
///
/// Written out rather than expressed as `.transition(.opacity)` because §2.4a asks for things a
/// SwiftUI transition does not give: the **outgoing** layer hidden from assistive technology
/// (the status item exposes one accessibility element, and a fading corpse of the previous string
/// must not be the second), unable to receive a pointer, removed once the fade ends, and
/// discarded outright when a newer transition overtakes it.
///
/// **Nothing moves and nothing resizes.** Both layers are drawn inside the width the item already
/// reserved across phases, so the crossfade is bounded by a number computed before it starts.
private struct MenuBarCrossfade: View {
    let render: MenuBarRender
    let width: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var current: MenuBarRender?
    @State private var outgoing: MenuBarRender?
    @State private var outgoingOpacity: Double = 0
    @State private var currentOpacity: Double = 1
    /// The pulse waits for the fade (§2.4a) — zero on an immediate swap, so a block that lands at
    /// once does not also pulse late.
    @State private var pulseDelay: TimeInterval = 0
    /// Bumped by every step. A fade's cleanup checks it, so an overtaken layer is discarded by
    /// the transition that overtook it rather than removed late by its own timer.
    @State private var token: Int = 0

    var body: some View {
        ZStack(alignment: .leading) {
            if let outgoing {
                MenuBarLayers(render: outgoing, headlineWidth: width, motion: .frozen)
                    .opacity(outgoingOpacity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            MenuBarLayers(render: current ?? render, headlineWidth: width,
                          motion: .live(pulseDelay: pulseDelay))
                .opacity(currentOpacity)
        }
        .frame(width: width, alignment: .leading)
        .onAppear { settle(render) }
        .onChange(of: render) { old, new in step(from: current ?? old, to: new) }
        // §2.4a's hard case: the preference changing *while a fade is running*, which the obvious
        // implementation misses. The corpse goes at once and the incoming layer is already whole.
        .onChange(of: reduceMotion) { _, reduced in if reduced { settle(nil) } }
    }

    private func step(from old: MenuBarRender, to new: MenuBarRender) {
        guard MenuBarReminder.fades(from: old, to: new, reduceMotion: reduceMotion) else {
            log(faded: false, from: old, to: new)
            settle(new)
            return
        }
        log(faded: true, from: old, to: new)
        token &+= 1
        let mine = token
        outgoing = old
        outgoingOpacity = 1
        current = new
        currentOpacity = 0
        pulseDelay = MenuBarReminder.transitionSeconds
        withAnimation(.easeInOut(duration: MenuBarReminder.transitionSeconds)) {
            outgoingOpacity = 0
            currentOpacity = 1
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(MenuBarReminder.transitionSeconds * 1_000_000_000))
            // Overtaken: the newer step already owns `outgoing`, and clearing it here would take
            // that one's layer away mid-fade.
            guard mine == token else { return }
            outgoing = nil
        }
    }

    /// One layer, whole, no corpse — the immediate path, the first appearance, and reduce motion
    /// turning on mid-fade.
    private func settle(_ new: MenuBarRender?) {
        token &+= 1
        if let new { current = new }
        outgoing = nil
        outgoingOpacity = 0
        currentOpacity = 1
        pulseDelay = 0
    }

    /// One DEBUG line per **phase edge**, for the reason STEP_199's phase line exists: the three
    /// immediate exemptions and the four entry paths are watchable on a real bar and provable
    /// only from a log.
    ///
    /// A render that changed nothing about the phase writes no line — otherwise every poll would
    /// log `immediate` and the word would stop meaning "an exemption fired".
    private func log(faded: Bool, from old: MenuBarRender, to new: MenuBarRender) {
        guard new.lines.contains(where: { !$0.reminders.isEmpty }) else { return }
        let before = old.lines.map(\.reminderIndex), after = new.lines.map(\.reminderIndex)
        guard before != after else { return }
        Logger.debug("Menu-bar transition · " + (faded ? "faded" : "immediate") + " · "
            + after.map { $0.map { i in "reminder\(i)" } ?? "steady" }.joined(separator: " "),
            component: .appLifecycle)
    }
}

/// One render, drawn. Row form when `headlineWidth` is nil; variant D when it is not and a line
/// is reminding.
///
/// Internal rather than private because it is one **layer** of the §2.4a crossfade, and a still
/// of two layers coexisting inside one reserved width is the only evidence of that rule a PNG can
/// carry — `MenuBarSnapshots` composes the midpoint from two of these.
struct MenuBarLayers: View {
    let render: MenuBarRender
    /// The width to fit the variant-D headline into. `nil` = the width pass, which draws the row
    /// form for every phase (see `MenuBarItemView.Layout`).
    let headlineWidth: CGFloat?
    let motion: MenuBarLayerMotion

    var body: some View {
        HStack(spacing: 5) {
            switch render.content {
            case .nothingDetected:
                undetectedMark
            case .tools(let lines):
                if headlineWidth != nil,
                   let focus = lines.firstIndex(where: { $0.reminderIndex != nil }) {
                    // **Variant D** (REV-98 §2.4 — STEP_203). For its five seconds the item is
                    // one vertically-centred line naming the limit and what is left of it, at up
                    // to 13 pt in place of the stacked 9 pt rows — and the other tool's row is
                    // **hidden**, which is the cost the revision states rather than hides: five
                    // seconds of invisibility per reminder, 0.14 % of an amber hour once the
                    // cadence has decayed.
                    MenuBarLineView(line: lines[focus],
                                    size: MenuBarReminder.headlineMaxSize,
                                    dotDiameter: 6,
                                    minimumScale: baseSize(lines.count)
                                        / MenuBarReminder.headlineMaxSize,
                                    motion: motion)
                } else {
                    switch lines.count {
                    case 0:
                        // A tool *is* detected, it simply has nothing to say right now — a
                        // single-tool mode whose chosen tool is the undetected one. Distinct from
                        // `.nothingDetected` above, and deliberately still empty.
                        EmptyView()
                    case 1:
                        // Single-tool row (D-107 — supersedes the one-day D-106 stack): the full
                        // §1.1 string in one row at 11pt/6pt, between the 9pt stacked rows and
                        // the ~13pt system items. Keeps the dense instrument look the old 12.5pt
                        // row lacked, without the stack's orphaned time slot (the in-situ verdict
                        // on D-106). The §1.6 glyph stays appended after the string, as everywhere.
                        MenuBarLineView(line: lines[0], size: 11, dotDiameter: 6, motion: motion)
                    default:
                        // Both-stacked: two ~9pt rows, a status dot each (§1.0).
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                MenuBarLineView(line: line, size: 9, dotDiameter: 5, motion: motion)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .frame(maxHeight: .infinity)
    }

    /// The size the headline may shrink *to* — its display mode's ordinary row size. It never
    /// goes below the string the bar would have drawn anyway.
    private func baseSize(_ lineCount: Int) -> CGFloat { lineCount == 1 ? 11 : 9 }

    /// No tool detected: the neutral one-colour Kvotar mark (D-78). It names the app and claims
    /// nothing about any tool.
    private var undetectedMark: some View {
        KvotarMarkView(style: .template(Theme.menuBarStatus(.grey)))
            .frame(width: 14, height: 14)
    }
}

/// One tool's row — and, at `size: MenuBarReminder.headlineMaxSize`, variant D's headline.
///
/// Its own `View` because the pulse is per-row state: one tool reminding must leave the other's
/// line exactly as it was (REV-97 §2.1), and a shared `@State` on the parent would animate both.
/// Internal rather than private so `MenuBarWidthTests` can lay out the headline on its own and
/// measure how far it has to scale — the fit is the whole of §2.4's "never widens the item", and
/// a fit checked by eye is not checked.
struct MenuBarLineView: View {
    let line: MenuBarRender.TextLine
    let size: CGFloat
    let dotDiameter: CGFloat
    /// How far the text may scale down to fit its box — variant D's headline only (§2.4). `1`
    /// means "do not scale", which is every row.
    var minimumScale: CGFloat = 1
    var motion: MenuBarLayerMotion = .live(pulseDelay: 0)

    /// Reduced motion keeps the colour and drops the pulse (REV-97 §2.8): the reminder carries
    /// information, and the pulse only draws the eye to it.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    private var isReminding: Bool { line.reminderIndex != nil }

    /// **The account's colour, not the displayed limit's** (§2.2) — which is the colour the dot
    /// already carries, so the reminder needs no palette of its own. Between reminders the text
    /// is `Color.primary`, exactly as it has always been.
    private var ink: Color {
        guard isReminding, let dot = line.dot else { return Color.primary }
        return Theme.menuBarStatus(dot)
    }

    var body: some View {
        HStack(spacing: 4) {
            if let dot = line.dot {
                Circle()
                    .fill(Theme.menuBarStatus(dot))
                    .frame(width: dotDiameter, height: dotDiameter)
            }
            Text(line.text)
                .font(.system(size: size, weight: .regular).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(minimumScale)
                .foregroundStyle(ink)
            // §1.6 money glyph: the account's currency symbol appended after the string, in its own amber/red colour —
            // except inside a reminder, where the whole row takes the account colour (§2.1).
            if let moneyColour = Theme.money(line.glyph) {
                Text(line.moneySymbol)
                    .font(.system(size: size, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(minimumScale)
                    .foregroundStyle(isReminding ? ink : moneyColour)
            }
        }
        // The whole row dims together, dot included — the prototype's variant A.
        .opacity(dimmed ? MenuBarReminder.pulseFloorOpacity : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(line.accessibilityLabel))
        .onAppear { pulse() }
        .onChange(of: line.reminderIndex) { _, _ in pulse() }
    }

    /// Three opacity cycles at the top of each reminder, then still — **after** the fade (§2.4a).
    ///
    /// The completion handler is not decoration: `repeatCount(_:autoreverses:)` restores the
    /// *presentation* value when it ends but leaves the model value at the target, so without it
    /// the row would finish every pulse stuck at the floor opacity and stay dimmed for the rest
    /// of the phase.
    ///
    /// **The delay is the whole of the sequencing rule.** 350 ms + three 1.6 s cycles runs 150 ms
    /// past the five-second phase, which is accepted (REV-98 §5 item 7): the fade animates the
    /// *layer's* opacity and this animates the *row's*, two properties on two views that
    /// multiply. That is not the model-versus-presentation trap STEP_199 paid for — that one was
    /// a single value with two owners.
    private func pulse() {
        guard case let .live(delay) = motion,
              MenuBarReminder.pulses(reminderIndex: line.reminderIndex,
                                     reduceMotion: reduceMotion) else {
            dimmed = false
            return
        }
        dimmed = false
        withAnimation(.easeInOut(duration: MenuBarReminder.pulseCycleSeconds / 2)
            .repeatCount(MenuBarReminder.pulseCycles * 2, autoreverses: true)
            .delay(delay)) {
            dimmed = true
        } completion: {
            dimmed = false
        }
    }
}
