import SwiftUI
import KvotarCore

/// The first-run window (UI Spec Part 3 §3a, REV-79 / D-100 — STEP_143): five screens, shown
/// once, in a window of their own. It answers the three questions a stranger has before the first
/// number — what is this, how do I read the menu bar, is it safe — and teaches nothing the popover
/// teaches (D-74 narrowed: hover cards, anatomy and coach marks stay in place).
///
/// Copy is locked in §3a and lives in the five screen views. The only live data on the way
/// through is what the status item already shows (`AppViewModel.toolMenuBar`, `detectedTools`,
/// the header's plan badge and reset text) — screen 2 never waits for the network and screen 3
/// renders through the same `DisplayFormatter.menuBarRender` as the item beside it.
public struct OnboardingView: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var step = 0
    private let actions: OnboardingActions

    static let stepCount = 5

    public init(actions: OnboardingActions) {
        self.actions = actions
    }

    public var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: OnboardingIntroScreen()
                case 1: OnboardingFoundScreen()
                case 2: OnboardingMenuBarScreen()
                case 3: OnboardingNotificationsScreen(actions: actions)
                default: OnboardingPrivacyScreen(actions: actions)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, OnboardingLayout.sidePadding)
            .padding(.top, 26)

            footer
        }
        .frame(width: OnboardingLayout.width, height: OnboardingLayout.height)
        .background(Theme.card)
        .onReceive(NotificationCenter.default.publisher(for: .onboardingReset)) { _ in step = 0 }
    }

    /// Dots in the middle; Skip (screen 1) or Back on the left; Continue / Allow & continue on
    /// the right. Screen 5 owns its own button row (the checkbox sits beside it).
    private var footer: some View {
        HStack {
            if step == 0 {
                Button("Skip") { actions.complete() }
                    .buttonStyle(OnboardingSecondaryButtonStyle())
            } else {
                Button("Back") { step -= 1 }
                    .buttonStyle(OnboardingSecondaryButtonStyle())
            }
            Spacer()
            OnboardingDots(count: Self.stepCount, current: step)
            Spacer()
            if step < Self.stepCount - 1 {
                Button(step == 3 ? "Allow & continue" : "Continue") {
                    if step == 3 { actions.requestNotifications() }
                    step += 1
                }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            } else {
                // Placeholder keeping the dots centred; the real button is on the screen.
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .padding(.horizontal, OnboardingLayout.sidePadding - 10)
        .padding(.vertical, 14)
        .background(Theme.sectionFill)
        .overlay(alignment: .top) { Rectangle().fill(Theme.borderLight).frame(height: 1) }
    }
}

public extension Notification.Name {
    /// Posted by the window controller on every `show()` so a re-open starts at screen 1.
    static let onboardingReset = Notification.Name("Kvotar.onboardingReset")
}

// MARK: - Shared screen scaffolding

/// Headline + support paragraph at the top of every screen but the intro.
struct OnboardingHeading: View {
    let headline: String
    let support: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headline)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(support)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The quiet last line of a screen.
struct OnboardingFooterNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Screen 1 — Intro

struct OnboardingIntroScreen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                KvotarMarkView(style: .brand).frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Kvotar")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Your quota keeper for Claude and Codex")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Text("Am I safe, or should I slow down?")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 34)
            Text("Kvotar keeps the answer in your menu bar: how much is left, when it resets, "
                 + "and whether your pace gets you to the reset.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 10) {
                OnboardingCheckLine(text: "Forecasts when you'll run out — from your live burn rate, not just the count.")
                OnboardingCheckLine(text: "Every verdict shows its work — click to see why.")
                OnboardingCheckLine(text: "Local only. Your prompts and code never leave this Mac.")
            }
            .padding(.top, 26)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Screen 2 — Found

struct OnboardingFoundScreen: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if vm.detectedTools.isEmpty {
                // Empty state (STEP_145): the window opened by hand on a machine with neither
                // tool. Says so instead of an empty list; the rows appear on the next launch
                // that finds a tool.
                OnboardingHeading(headline: "Nothing found yet.",
                                  support: "Kvotar reads the sign-ins your CLI tools already have. "
                                  + "Sign in to Claude Code or Codex and it appears here on its own.")
            } else {
                OnboardingHeading(headline: "It's already working.",
                                  support: "No sign-in, no keys. Kvotar reads what your CLI tools already know.")

                VStack(spacing: 8) {
                    // An undetected tool renders no row (§1.0 / D-78); a tool not yet classified
                    // counts as detected and shows "Reading…" until its first poll lands.
                    ForEach(vm.detectedTools, id: \.self) { tool in
                        OnboardingToolRow(tool: tool)
                    }
                }
                .padding(.top, 22)
            }

            Spacer(minLength: 12)
            OnboardingFooterNote(text: "Found from the sign-ins your tools already have. "
                                 + "Sign in to a tool later and it appears on its own.")
                .padding(.bottom, 16)
        }
    }
}

/// One detected tool: dot, name in the tool's accent, plan badge, "found", the live line or
/// *Reading your quota…*, and the tool's actual menu-bar string as a pill on the right.
struct OnboardingToolRow: View {
    let tool: Tool
    @EnvironmentObject private var vm: AppViewModel

    private var menu: ToolMenuBarDisplay? { vm.toolMenuBar(tool) }

    private var header: HeaderSection? {
        switch tool {
        case .claude: return vm.claudeState.header
        case .codex:  return vm.codexState.header
        }
    }

    private var toolName: String {
        switch tool {
        case .claude: return "Claude Code"
        case .codex:  return "Codex"
        }
    }

    /// `86% left · resets in 2h 17m` once the first poll has landed; nil while loading.
    private var liveLine: String? {
        guard vm.hasSucceeded(tool), let menu else { return nil }
        var line = "\(menu.percentText) left"
        // The reset moved from the D-58 caption to its own detail line under the verdict
        // (STEP_178); the line already reads `resets in 2h 17m`, so no substring hunt is needed.
        if let reset = header?.heroDetails.first(where: { $0.text.hasPrefix("resets in") }) {
            line += " · " + reset.text
        }
        return line
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            StatusDotView(dot: menu?.dot ?? .grey)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(toolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent(tool))
                    if let header, vm.hasSucceeded(tool) {
                        PlanBadgeView(text: header.planBadge, kind: header.badgeKind)
                    }
                    Text("found")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                if let liveLine {
                    Text(liveLine)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Text("Reading your quota…")
                        .font(.system(size: 12))
                        // STEP_180: this row's card is `sectionFill`, where the reviewed tertiary
                        // reads 4.31:1 — the same pair the popover's chrome band moved off.
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            OnboardingMenuBarStrip(
                render: DisplayFormatter.menuBarRender(
                    mode: tool == .claude ? .claudeOnly : .codexOnly,
                    claude: tool == .claude ? (menu ?? waitingDisplay) : nil,
                    codex: tool == .codex ? (menu ?? waitingDisplay) : nil),
                showsNeighbours: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.sectionFill, in: RoundedRectangle(cornerRadius: 8))
    }

    /// `CX ––` while the first poll is in flight (§3a screen 2).
    private var waitingDisplay: ToolMenuBarDisplay {
        ToolMenuBarDisplay(prefix: tool.menuBarPrefix, dot: .grey, percentText: "––", timeSlot: nil)
    }
}

// MARK: - Screen 3 — Read it without clicking

struct OnboardingMenuBarScreen: View {
    @EnvironmentObject private var vm: AppViewModel

    /// The live item where a tool has a value; the §3a fixture for the rest, so the strip is
    /// never blank and never a mock that disagrees with a value the user can see.
    private var render: MenuBarRender {
        let claude = vm.hasSucceeded(.claude) ? vm.toolMenuBar(.claude)
            : ToolMenuBarDisplay(prefix: "CL", dot: .green, percentText: "86%", timeSlot: "↻2h17m")
        let codex = vm.hasSucceeded(.codex) ? vm.toolMenuBar(.codex)
            : ToolMenuBarDisplay(prefix: "CX", dot: .green, percentText: "93%", timeSlot: "↻7d")
        return DisplayFormatter.menuBarRender(mode: .bothStacked, claude: claude, codex: codex)
    }

    private static let amberFixture = DisplayFormatter.menuBarRender(
        mode: .claudeOnly,
        claude: ToolMenuBarDisplay(prefix: "CL", dot: .amber, percentText: "14%", timeSlot: "◔~40m"),
        codex: nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingHeading(headline: "Read it without clicking",
                              support: "The answer lives in the menu bar. Three slots, always in the same place.")

            OnboardingMenuBarStrip(render: render)
                .padding(.top, 16)

            HStack(alignment: .top, spacing: 8) {
                OnboardingCard(title: "Will I make it?",
                               text: "Green: on pace to reset. Amber: at this pace, not. Red: out.")
                OnboardingCard(title: "How much is left",
                               text: "Claude on top, Codex below. The number is % of quota left.")
                OnboardingCard(title: "Until it resets",
                               text: "The clock you are racing. Hours for the session, days for the week.")
            }
            .padding(.top, 12)

            HStack(spacing: 10) {
                OnboardingMenuBarStrip(render: Self.amberFixture, showsNeighbours: false)
                Text("When you're burning fast, the last slot switches to runway: "
                     + "how long until you run out at this pace.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(Theme.amberBg, in: RoundedRectangle(cornerRadius: 8))
            .padding(.top, 12)

            Spacer(minLength: 8)
            OnboardingFooterNote(text: "Click the item for the why — reset time, burn rate, "
                                 + "and which project is using it.")
            // REV-99 §2.8 (STEP_204): macOS hides the item when the menu bar is full, and this is
            // the only durable teaching moment for the way back in — on the one screen already
            // about where the item lives.
            OnboardingFooterNote(text: "Can't find the item? Open Kvotar again from Applications "
                                 + "or Spotlight and it opens a window.")
                .padding(.top, 4)
                .padding(.bottom, 16)
        }
    }
}

// MARK: - Screen 4 — When should Kvotar interrupt you?

struct OnboardingNotificationsScreen: View {
    let actions: OnboardingActions
    /// Seeded from the store on appear; each flip persists at once (STEP_144), so Back/Skip
    /// after a flip still leaves the switch as set — the same row the right-click submenu reads.
    @State private var enabled: [NotificationGroup: Bool] = [:]

    /// The four user-facing groups over the nine engine events (§3a screen 4 table). Names come
    /// from `NotificationGroup.label`; the one-line bodies are this screen's only copy.
    private static func body(of group: NotificationGroup) -> String {
        switch group {
        case .atRisk: return "At this pace you run out before the window resets."
        case .fastBurn: return "A big jump in a couple of minutes — a runaway agent or a loop."
        case .overQuota: return "The tool has stopped. Tells you when it comes back."
        case .windowReset: return "Fresh quota, only after a window where you were warned."
        }
    }

    private func binding(_ group: NotificationGroup) -> Binding<Bool> {
        Binding(
            get: { enabled[group] ?? group.defaultEnabled },
            set: { value in
                enabled[group] = value
                actions.setNotificationGroup(group, value)
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingHeading(headline: "When should Kvotar interrupt you?",
                              support: "A few moments matter. Everything else stays in the menu bar.")
            VStack(spacing: 6) {
                ForEach(NotificationGroup.allCases, id: \.self) { group in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.label).font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(Self.body(of: group)).font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Toggle("", isOn: binding(group))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Theme.sectionFill, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.top, 16)

            Spacer(minLength: 8)
            OnboardingFooterNote(text: "macOS will ask once for permission next. "
                                 + "Respects Focus and Do Not Disturb.")
                .padding(.bottom, 16)
        }
        .onAppear {
            for group in NotificationGroup.allCases {
                enabled[group] = actions.isNotificationGroupEnabled(group)
            }
        }
    }
}

// MARK: - Screen 5 — What Kvotar never sees

struct OnboardingPrivacyScreen: View {
    let actions: OnboardingActions
    @State private var launchAtLogin = true

    private static let reads = [
        "Your official quota from Claude and OpenAI",
        "Token counts from local session logs",
        "Project folder names, to attribute usage",
        "The sign-in token your CLI already holds",
    ]
    private static let neverStores = [
        "Your prompts or conversations",
        "Your code or tool output",
        "Tokens, passwords or refresh keys",
        "Anything on a server — there is none",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // D-105e (REV-83): the support line names everything the app sends — the quota
            // requests to Anthropic and OpenAI, made with the user's own sign-in on every poll,
            // and the daily update check to kvotar.com — instead of claiming nothing leaves.
            OnboardingHeading(headline: "What Kvotar never sees",
                              support: "Local only. Read only. It asks Anthropic and OpenAI for your "
                                  + "quota with your own sign-in, and once a day asks kvotar.com for "
                                  + "updates. Nothing else leaves your Mac.")

            HStack(alignment: .top, spacing: 16) {
                column(title: "Reads", lines: Self.reads, symbol: "eye", tint: Theme.textSecondary)
                column(title: "Never stores", lines: Self.neverStores, symbol: "xmark", tint: Theme.red)
            }
            .padding(.top, 16)

            Spacer(minLength: 8)
            OnboardingFooterNote(text: "It never writes to your Claude or Codex sign-in, and never "
                                 + "refreshes a token for you. Its own data lives in "
                                 + "~/Library/Application Support/Kvotar.")

            HStack {
                OnboardingCheckbox(label: "Start Kvotar when I log in", isOn: $launchAtLogin)
                Spacer()
                Button("Open Kvotar") {
                    actions.setLaunchAtLogin(launchAtLogin)
                    actions.complete()
                    actions.openPopover()
                }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        // On by default (§3a); a user who already registered the login item sees it checked
        // for the same reason. Skip never reaches here, so it leaves the registration alone.
        .onAppear { launchAtLogin = actions.isLaunchAtLoginEnabled() || launchAtLogin }
    }

    private func column(title: String, lines: [String], symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.textTertiary)
            ForEach(lines, id: \.self) { line in
                OnboardingCheckLine(text: line, symbol: symbol, tint: tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Previews

#Preview("Onboarding") {
    OnboardingView(actions: OnboardingActions())
        .environmentObject(AppViewModel())
}
