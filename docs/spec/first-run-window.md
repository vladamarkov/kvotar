---
summary: The current rules for the first-run window — when it opens, its five screens with their exact copy, Skip and completion, reopening, the notification permission request and launch at login — with the reasons behind them.
read_when: Changing OnboardingView, OnboardingGate, OnboardingWindowController, OnboardingActions, the Welcome to Kvotar… menu item, the notification groups' first-run switches, or the first-run Privacy screen copy.
---

# First-run window

This page is the specification for the first-run window. It replaces the private UI Spec Part 3
§3a and the parts of decisions D-100 and D-105 that concern it. Change this page in the same commit
as the code it describes. The copy below is the shipped copy; a change to it is a change to this
page.

## Why it exists

A stranger has three questions before they have seen a single number: *what is this*, *how do I
read the menu bar*, and *is it safe*. The popover's own teaching (hover cards, the verdict's
anatomy) cannot reach the menu bar, which is outside the popover, and cannot come before the first
number. So the window answers those three questions, once, and teaches nothing the popover
teaches. Each screen is either a decision the user makes anyway (notifications, launch at login)
or something nothing else can show. (D-100)

Why five screens and not three (intro, menu bar, privacy): *Found* is the proof behind the intro's
promise of zero setup, and the state most users see in their first second. *Notifications* gives
the system permission prompt its context.

**Rejected, don't re-propose:**

- Onboarding inside the popover: it closes when focus leaves, competes with the numbers, and
  cannot survive the macOS permission dialog.
- A screen to pick a menu-bar mode: the default is already right and comes from what was detected.
- A feature grid: it repeats screens 3 to 5.
- Teaching `⚠wk` or `est` on screen 3: four variants stop being calm; hover cards cover them.
- An "AI intelligence" style tagline: a category claim with no noun.
- A Settings window for the four notification switches: they live in the right-click menu instead.
- Reopening this window as the only way to change a notification switch: five screens to flip one
  switch.

## When it opens

- **Automatically, once:** on the first launch where `settings.onboarding_completed` is absent
  **and** a tool has been detected. The check runs once per process, when the poll coordinator
  first reports a detected tool (the first poll outcome that is not "no credential and no local
  activity"). (`App/OnboardingGate.swift`: `OnboardingGate.decide`; `App/AppDelegate.swift`:
  `coordinator.onFirstToolDetected`)
- **Neither tool detected:** it does not open. The popover's setup welcome is the first-run surface
  instead, and the window opens on the first later launch that finds a tool.
- **Already onboarded:** at that same moment the app requests notification permission instead. macOS
  never asks twice, so for most launches this does nothing; for a user who skipped at screen 1 it is
  the prompt they never reached.
- **A store migrated from the app's former name** still opens it: migrated is not onboarded. Only
  this window writes the key.
- **By hand, any time:** the right-click item **Welcome to Kvotar…** reopens it at screen 1. It doubles
  as the "how do I read this" reference. (`OnboardingWindowController.show`, which resets to
  screen 1 on every show)

## Completion and Skip

- **Skip** (screen 1) and **Open Kvotar** (screen 5) both complete the flow: the window closes and
  `onboarding_completed = "1"` is written. It never opens on its own again.
- **Only when a tool is detected at that moment.** Dismissing the window opened by hand on a machine
  with neither tool closes it but writes nothing, so the automatic showing is still owed.
  (`OnboardingGate.shouldPersistCompletion`; the `complete` closure in `AppDelegate`)
- **Closing the window with its close button** completes nothing: no key is written, so it opens
  again on the next launch that finds a tool.
- **Open Kvotar** applies the launch-at-login checkbox, completes, then opens the active quota
  surface: the popover, or the quota window when the menu-bar item is known to be hidden.
  (`openPopover` → `QuotaSurfacePresenter.present`)

## Chrome

A standalone window titled *Welcome to Kvotar*, 480 × 440 pt, not resizable, closable. Light and
dark. Progress dots in the footer; **Skip** on screen 1 and **Back** after it on the left;
**Continue** on the right of screens 1 to 3, **Allow & continue** on screen 4; screen 5 has its own
button row. Return triggers the right-hand button. The mark is `KvotarMarkView(style: .brand)`.
(`App/OnboardingWindowController.swift`;
`Packages/KvotarUI/Sources/KvotarUI/Views/Onboarding/OnboardingView.swift`: `OnboardingView`,
`OnboardingLayout`)

## The five screens

All copy lives in `OnboardingView.swift`, one view per screen. It is quoted here exactly.

### Screen 1 — Intro (`OnboardingIntroScreen`)

- Mark, the word **Kvotar**, and the tagline *Your quota keeper for Claude and Codex*
- Headline: **Am I safe, or should I slow down?**
- Support: *Kvotar keeps the answer in your menu bar: how much is left, when it resets, and whether
  your pace gets you to the reset.*
- Three checkmarked lines:
  - *Forecasts when you'll run out — from your live burn rate, not just the count.*
  - *Every verdict shows its work — click to see why.*
  - *Local only. Your prompts and code never leave this Mac.*
- Buttons: **Skip** · **Continue**

The headline is the user's own question; its two halves are the green and amber that screen 3
names.

### Screen 2 — Found (`OnboardingFoundScreen`)

- Headline: **It's already working.**
- Support: *No sign-in, no keys. Kvotar reads what your CLI tools already know.*
- One row per **detected** tool (`OnboardingToolRow`): status dot, the tool's name in its accent
  colour (*Claude Code*, *Codex*), the plan badge once the first poll has landed, *found*, then
  either the live line (`86% left · resets in 2h 17m`, built from the menu-bar percentage and the
  header's reset line) or *Reading your quota…* until the first poll lands. On the right, the tool's
  real menu-bar string as a pill (`CX ––` while waiting), drawn through
  `DisplayFormatter.menuBarRender`.
- Footer: *Found from the sign-ins your tools already have. Sign in to a tool later and it appears on
  its own.*
- **Empty state** (only reachable by hand, neither tool detected): headline **Nothing found yet.**,
  support *Kvotar reads the sign-ins your CLI tools already have. Sign in to Claude Code or Codex and
  it appears here on its own.*, no rows, same footer.

**Rule:** the screen never waits for the network. Detection is the promise; the number appears when
it arrives. An undetected tool has no row.

### Screen 3 — Read it without clicking (`OnboardingMenuBarScreen`)

- Headline: **Read it without clicking**
- Support: *The answer lives in the menu bar. Three slots, always in the same place.*
- A strip showing the real status item for both tools (`CL` over `CX`) beside neighbouring system
  glyphs. Each tool shows its live value once polled, otherwise the fixture `CL 86% ↻2h17m` /
  `CX 93% ↻7d` with green dots.
- Three cards:
  - **Will I make it?** — *Green: on pace to reset. Amber: at this pace, not. Red: out.*
  - **How much is left** — *Claude on top, Codex below. The number is % of quota left.*
  - **Until it resets** — *The clock you are racing. Hours for the session, days for the week.*
- An amber strip with `CL 14% ◔~40m` and *When you're burning fast, the last slot switches to
  runway: how long until you run out at this pace.*
- Footer: *Click the item for the why — reset time, burn rate, and which project is using it.*
- Second footer line: *Can't find the item? Open Kvotar again from Applications or Spotlight and it
  opens a window.* This is the one lasting place that teaches the way back when macOS hides the item
  in a full menu bar, on the screen already about where the item lives. (D-122)

**Rule:** the strip is rendered by `DisplayFormatter.menuBarRender`, the same function as the real
item, so the screen can never disagree with the item next to it, and it can never show a reminder
phase.

### Screen 4 — When should Kvotar interrupt you? (`OnboardingNotificationsScreen`)

- Headline: **When should Kvotar interrupt you?**
- Support: *A few moments matter. Everything else stays in the menu bar.*
- Four rows, each with a switch:

| Row | Line | Default | Settings key (absent ⇒ default) | Engine events |
|---|---|---|---|---|
| **At risk** | *At this pace you run out before the window resets.* | on | `notification_at_risk_enabled` | `at_risk`, `bad_timing`, `limit_nearly_spent`, `limit_ahead_of_pace` (the weekly notices) |
| **Fast burn** | *A big jump in a couple of minutes — a runaway agent or a loop.* | on | `notification_fast_burn_enabled` | `fast_burn_spike`, `off_machine_burn`, `multi_surface` |
| **Over quota** | *The tool has stopped. Tells you when it comes back.* | on | `notification_over_quota_enabled` | `over_quota`, `spend_control` |
| **Window reset** | *Fresh quota, only after a window where you were warned.* | off | `notification_window_reset_enabled` | `window_reset_pre`, `window_reset_post` |

- Footer: *macOS will ask once for permission next. Respects Focus and Do Not Disturb.*
- Button: **Allow & continue**. This button makes the app's notification permission request
  (`UNUserNotificationCenter`). The app never asks at launch itself. It asks when the poll
  coordinator first reports a detected tool, and only if onboarding is already complete or was
  skipped (see *When it opens*); macOS shows the prompt at most once.

Each switch is saved the moment it flips, so Back or Skip afterwards keeps it. Stored values are
`"true"` / `"false"`. After the first run the same four switches live in the right-click
**Notify me ▸** submenu; there is no Settings window for them. The groups are a user-facing
grouping over the engine's events, not an engine change; the window-changed notice is outside all
four groups and always on. (`Packages/KvotarCore/Sources/KvotarCore/Notifications/NotificationTypes.swift`:
`NotificationGroup`; `AppDelegate.setNotificationGroup`)

**Why here:** the permission dialog used to fire at launch with no context. This screen turns a
cold system prompt into a choice the user has just read about, and a window, unlike the popover,
survives the dialog.

### Screen 5 — What Kvotar never sees (`OnboardingPrivacyScreen`)

- Headline: **What Kvotar never sees**
- Support: *Local only. Read only. It asks Anthropic and OpenAI for your quota with your own sign-in,
  and once a day asks kvotar.com for updates. Nothing else leaves your Mac.* (See
  [credentials and privacy](../credentials-and-privacy.md#the-network) for each call.)
- Two columns:
  - **READS**: *Your official quota from Claude and OpenAI* · *Token counts from local session logs* ·
    *Project folder names, to attribute usage* · *The sign-in token your CLI already holds*
  - **NEVER STORES**: *Your prompts or conversations* · *Your code or tool output* · *Tokens,
    passwords or refresh keys* · *Anything on a server — there is none*
- Footer: *It never writes to your Claude or Codex sign-in, and never refreshes a token for you. Its
  own data lives in ~/Library/Application Support/Kvotar.*
- Checkbox **Start Kvotar when I log in**, checked by default (and checked if the login item is
  already registered), bound to the same `SMAppService` login item as the right-click **Open at
  Login**. The checkbox is local until **Open Kvotar** applies it, so until then the two can
  differ (a fresh install shows it checked while the login item is not yet registered). Skip, Back
  and the close button leave the registration untouched.
- Button: **Open Kvotar**

The sign-in-token line stays on purpose: hiding it would undercut the screen. The privacy story is
the product's argument, so every sentence on this screen must be literally true. (D-105)

## Known gaps

None.

Checked against the code at 02b738e + STEP_242.
