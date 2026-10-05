# STEP_277 — The tests pass in any time zone and on a slow machine, and a restarted Codex app-server is never failed by the old one's exit

**refs:**
- [STEP_276_github_checks.md](STEP_276_github_checks.md) — contract item 5: a test that fails only
  on the runner is recorded and stopped on, never skipped or listed.
- [docs/spec/codex-account.md](../docs/spec/codex-account.md) — "Persistent process".
- [docs/spec/explanations.md](../docs/spec/explanations.md) — peek and grace timings (unchanged).
- [PATTERNS.md](../PATTERNS.md) — "drive the clock and the inputs by injection".
- `Packages/CodexAdapter/Sources/CodexAdapter/CodexRPCClient.swift` (`startReader`,
  `handleTransportClosed`, `ensureStarted`), `Packages/CodexAdapter/Tests/CodexAdapterTests/Mocks.swift`
  (`FakeCodexTransport`), `CodexRPCClientTests.swift`.
- `Packages/KvotarUI/Sources/KvotarUI/ViewModel/HistoryViewModel.swift` (`hover`),
  `AppViewModel.swift`, `AppViewModel+ExplanationLayer.swift` (`explanationHover`,
  `scheduleExplanationPeekEnd`).
- `Packages/KvotarUI/Tests/KvotarUITests/`: `DisplayFormatterV46Tests`, `DisplayFormatterMonthlyTests`,
  `DisplayFormatterWindowGrainTests`, `HistoryViewModelDestinationTests`,
  `LongLimitSurfaceAgreementTests`, `HistoryDayHoverTests`, `AppViewModelHoverCardTests`.

**Approval:** the maintainer, 2026-10-05 (option B after the first STEP_276 runs). Touches nothing
on the [VISION.md](../VISION.md) approval list: the Codex change is a fix with a clear cause shown
by a test, and it sends nothing new.

**blocked_by:** none. STEP_276 lands after this step.

## Goal

The first GitHub runs of STEP_276 (macOS, time zone UTC, a slow shared machine) failed tests that
pass on the maintainer's Mac. Three causes:

1. **Time zone.** Display tests take their dates from fixed instants and expect clock and date text
   as it reads in Central European time. `DisplayFormatter` reads `Calendar.current`, so in UTC
   `testVerdictCrossMidnightAppendsTomorrow` loses its "tomorrow"; in other zones (checked:
   America/Los_Angeles, Pacific/Kiritimati, Pacific/Pago_Pago) about twenty tests in five
   KvotarUI classes fail. No other package fails in those zones.
2. **Wall-clock sleeps.** The hover-card tests shrink the peek delay and the grace to 20 ms and then
   sleep 60 ms, hoping the timer has fired. On a busy runner it has not, so a different set of them
   fails on each run.
3. **A real race in the Codex client.** On a restart, the old reader task is cancelled, but its loop
   still ends and calls `handleTransportClosed()`, which fails every waiting call. If that happens
   after the new process's first call is waiting, the call fails with `transportClosed` (and the
   client marks itself not started). `testRestartAfterCrash` failed once on the runner and 1 in 40
   locally under CPU load.

After this step the suites give the same result in any time zone and at any machine speed, and a
restarted app-server is failed only by its own exit.

## Contract

1. **Time zone pinned in the fixtures.** A test-only helper in `KvotarUITests` names the fixture
   zone (`Europe/Berlin`, the zone the expected strings were written in) and pins it as the
   process default zone (`NSTimeZone.default`) in `setUp`, restoring the previous one in `tearDown`.
   The five classes in refs use it. No expected string changes. App code is unchanged.
2. **Hover timers driven by an injected clock.** `HistoryViewModel` and `AppViewModel` gain one
   property each, `hoverClock: any Clock<Duration>`, defaulting to `ContinuousClock()`; their peek
   and grace timers sleep on it instead of on `Task.sleep`. The timings, the rules and the app's
   behavior do not change. A test-only manual clock in `KvotarUITests` lets a test wait until a timer
   is waiting, advance time by an exact amount, and let the woken timers finish.
   `HistoryDayHoverTests` and `AppViewModelHoverCardTests` use it in place of every fixed sleep; each
   test keeps its name and asserts the same thing, including the "not before the delay" and
   ordering assertions.
3. **The old reader's exit is ignored after a restart.** `CodexRPCClient` numbers each started
   process; the reader passes its number to `handleTransportClosed`, which fails waiting calls and
   clears `started` only when that number is the current one. `shutdown()` still fails waiting
   calls (its reader is still current). Nothing sent changes.
4. **A test that reproduces the race.** `FakeCodexTransport` gains an option that keeps the old
   stream open on `terminate()` and finishes it when the new process's first request is sent, and
   answers that request a moment later. A new `CodexRPCClientTests` test uses it: the restart poll
   succeeds and the client stays started. It fails before item 3 and passes after it.
5. **Spec page.** `docs/spec/codex-account.md` "Persistent process": "A child that exits fails every
   waiting call" becomes "A child that exits fails every call waiting on it; the exit of a child
   that has already been replaced fails nothing." Its `Checked against` line becomes
   `Checked against the code at <parent> + STEP_277`. No other spec page changes.

## Proof

1. The new Codex test fails on the parent commit and passes after item 3.
2. Locally, the seven named KvotarUI classes and `CodexRPCClientTests` pass 50 times in a row, with
   the CPU loaded, and the KvotarUI suite passes with `TZ` set to UTC, America/Los_Angeles,
   Pacific/Kiritimati and Pacific/Pago_Pago.
3. `make test` (only expected skips) and `make check` pass locally.
4. A GitHub run of the STEP_276 workflow on a branch with this step is green; its link goes in the
   commit message body.

## Deliberately untouched

The expected strings in every test; the hover timings and rules; `DisplayFormatter`'s use of the
user's zone; `HeaderSectionView`'s own hover sleeps; other tests that sleep (they have not failed
on the runner; a later step if they do); the scripts, the expected-skips list and the STEP_276
workflow; anything sent to the Codex app-server.

## Definition of done

- The proof items hold.
- `docs/spec/codex-account.md` describes the restart behavior.
- One commit lands for the step (`STEP_277: …`), before STEP_276, and work stops.
