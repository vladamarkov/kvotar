# Changelog

User-facing changes per release. Build numbers are in brackets. Contributors are credited by name on
the line of their change.

## Unreleased

## [0.3.0 beta.10 (19)](https://github.com/vladamarkov/kvotar/releases/tag/v0.3.0-beta.10) — 2026-10-05

- Source published under the Apache License 2.0.
- On an account with only a weekly limit, the "nearly spent" notice arrives with the red state, at
  15 % left.
- The "menu bar item may be hidden" notice is only sent in the first minute after launch.
- The first-run Privacy screen names the calls the app makes: the quota checks to Anthropic and
  OpenAI, and the daily update check.
- The dialog that turns on extended diagnostics says the saved copy of the database is not redacted.
- The support address in the About panel and in saved diagnostics is on kvotar.com.
- A restarted Codex connection is no longer failed by the old one closing.

## 0.3.0 beta.9 (18) — 2026-10-01

- The account's weekly limit warns on the way down: at half left, a quarter left, 10 % left and spent. The
  two early notices come only when you are running ahead of pace, are silent, and give a daily
  budget.
- On an account with only a weekly limit, "nearly spent" comes at 10 % left instead of 15 %.
- Notices that say you are about to be stopped, or just were, play the system sound; the rest stay
  silent.
- **Notify me** says when macOS shows notifications as banners that hide after a few seconds.
- A "quota exceeded" notice no longer lingers after its window has reset.
- The "menu bar item may be hidden" notice no longer appears for a sleeping display, a locked screen
  or a full-screen app.
- The weekly recap in History states its numbers: change against the previous week, tokens,
  estimated value, active days, and how much of each weekly limit was used.
- Claude's five-hour forecast is steadier: the burn rate mixes the last 18 minutes with the last
  hour.
- New models priced for the estimated token value.

## 0.3.0 beta.8 (17) — 2026-09-21

- A blocked header states its reset once, and the block message counts in hours and names the
  limit.
- Claude Team: when the provider switches the credits meter off after the cap, the organization's
  card stays and shows no made-up zero.

## 0.3.0 beta.7 (16) — 2026-09-21

- Claude Team accounts: the "monthly spend limit" is read as organization-paid usage credits, not as
  a limit of its own. The app says when credits are paying and when the cap is spent.
- Money is shown in the currency your provider bills in. Estimated token values stay in US dollars.
- Codex's local databases are read again when Codex is closed.

## 0.3.0 beta.6 (15) — 2026-09-17

- A nearly spent weekly or monthly limit stays in the menu bar, with what is left and when it
  resets.
- The amber reminder fades out over time and stops once you open the popover.
- When macOS hides the menu-bar item, opening Kvotar again shows a window with the same content.
  **Open in Window** is in the right-click menu.
- A five-hour window that has not started shows no verdict. Per-model limits are recorded on every
  check.

## 0.3.0 beta.5 (14) — 2026-09-15

- Weekly and monthly limits that are running out early are shown in their own colour, with a
  sentence naming the limit.
- A notification before a long limit is spent, not after.
- A long block is announced once, however long it lasts.
- Codex usage today is split by app (Desktop, command line).
- Fast-burn warnings are measured between two real readings.

## 0.3.0 beta.4 (13) — 2026-09-11

- The popover names which limit the big number belongs to, and lists every other limit once.
- Today's local work is ranked by project and model.
- The popover fits the screen, with new colours in light and dark.
- History opens on a weekly recap, with new **Explore quota** and **Explore usage** views.
- Codex no longer goes blank on an exhausted account when one reply field changes shape.
- The live Codex connection works again (the app finds Codex where it is installed now).

## 0.3.0 beta.3 (12) — 2026-09-08

- Work in a resumed Codex thread is counted again, and dropped work is recovered.
- Codex work in an editor extension counts as local from the moment it starts.
- Team-plan accounts are no longer locked out for an hour: the app skips a credits check those
  accounts are not entitled to, and honours the provider's requested wait.
- Usage is checked every two minutes instead of every minute, the pace the provider answers
  reliably.
- More models are in the price table. Captured provider replies in diagnostics have account and
  organization UUIDs redacted.

## 0.3.0 beta.2 (11) — 2026-09-07

First public build. (beta.1, build 10, was not released.)

- The Claude tab keeps your last numbers with **Reconnecting…** while the provider asks it to wait,
  instead of going blank.
- Extended diagnostics are off unless you turn them on, for at most 24 hours.
- The app no longer asks Claude Code to refresh an expired sign-in; it tells you the sign-in expired.

## 0.2.0 prealpha.5 (9) — 2026-09-02

- "Off-machine" is now "Elsewhere".
- History rebuilt into three views: Summary, Explore usage, Hard blocks.
- A session started from a parent folder no longer swallows the projects under it.
- One tool in the menu bar renders as a single compact row.

## 0.2.0 prealpha.4 (8) — 2026-08-31

- The app updates itself: a daily check, and nothing installs without a click.
- **Notify me** shows when notifications are off in System Settings.
- Diagnostics: the tool-version probe keeps only a version line, and email and name are redacted
  from captured replies.

## 0.2.0 prealpha.1–3 (5–7) — 2026-08-24 to 2026-08-26

- Renamed to Kvotar; data from the app's earlier name is copied across on first launch, and the old
  copy is left untouched.
- The menu bar and the popover's quota figures show what is left, not what is used.
- A History window with 30 days of your own usage, and what each limit hit cost.
- Hover cards explain every figure; a line on opening says what changed since you last looked.
- Burn rate on weekly and monthly windows is shown per hour against the window's pace.
- Pricing fixes: one-hour cache writes, per-model pricing, duplicates counted once.
