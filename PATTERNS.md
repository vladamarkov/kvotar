---
summary: How code is written in this repository — concurrency, state and view rules, storage, logging, JSONL parsing, watching, naming, testing — with the reason behind each rule.
read_when: Before writing or reviewing any code change.
---

# Kvotar — PATTERNS.md

## Async model

Use `async/await` for all network calls, subprocess I/O, and Keychain reads. Use `AsyncStream` for event streams: the local adapters' `tokenEvents`, `deltaSignals` and `localWrites`, and `StateEngine.windowResets`. No Combine in Core, adapters, or engines — async/await and `AsyncStream` only. The UI bridging layer (`AppViewModel`'s `@Published` properties, and AppKit observers of those properties such as `MenuBarController`'s `.sink`) is the sole sanctioned Combine surface — `@Published`/`ObservableObject` are Combine under the hood, so a literal "no Combine anywhere" was never satisfiable. *(Rule clarified 2026-07-04.)*

```swift
// Event stream — StateEngine publishes, a consumer subscribes
let windowResets: AsyncStream<Tool>

// Adapters return values, not publishers
func fetchQuotaSnapshot() async throws -> QuotaSnapshot
```

State transitions are the deliberate exception to the bus pattern *(STEP_28, 2026-07-05)*:
`StateEngine.evaluate` **returns** the `StateChange` (`StateEvaluation.change`) and the caller
hands it to `NotificationEngine.evaluateCycle` together with the same cycle's poll signal. A
`stateChanges` stream delivered Path 1 asynchronously, racing Path 2's direct call and making
the §16 one-notification-per-cycle arbitration impossible to guarantee.

---

## Actor usage

Types that hold mutable state across calls are Swift actors. Everything else is a `struct` or `final class`. *(Inventory updated 2026-07-04 — the original "exactly five actors" list predated Swift 6 strict concurrency; adapters and later engines legitimately became actors too.)*

| Actor | Owns |
|---|---|
| `SQLiteStore` | Single GRDB `DatabasePool`; all reads and writes |
| `StateEngine` | Current state, previous state, transition logic, the `windowResets` stream |
| `NotificationEngine` | Cooldown timers, fired counts, re-arm flags, per-window state |
| `ForecastEngine` | The utilization sample buffers the burn rate is read from (samples age out at `sampleMaxAge`) |
| `AttributionEngine` | Token-event ingestion, per-window attribution caches |
| `EstimatedValueEngine` | Pricing table cache; per-`(provider, model)` WARNING dedup — *documented here since STEP_13 but only implemented in STEP_91, by the `NSLock`-guarded `PricingWarningLog` beside the engine (the callers are `static` pure functions and must not become `await` points). STEP_92 added the sibling `UnpricedModelCollector` on the same construction: it buffers the fallback observations and `PollCoordinator` drains it into the permanent `unpriced_models` table once per poll cycle* |
| `RetentionScheduler` | Repeating cleanup timer |
| `LimitsDatabaseAdapter` | Cached community limits seed + source (actor since STEP_25 — read by `ForecastEngine` across isolation domains) |
| `ClaudeAccountAdapter`, `CodexAccountAdapter`, `ClaudeLocalAdapter`, `CodexLocalAdapter` | Cached credential/session state, watcher sources, file offsets |

The polling role documented in the Baseline as "PollEngine" is `PollCoordinator`, a `@MainActor final class` in the App target; it logs under the `PollEngine` component. The §9 polling behavior (429 ladder, `poll_health_events`, proactive slowdown, staleness TTL) landed in STEP_25 — the pure cadence policy lives in `PollBackoffPolicy` (KvotarCore/Polling) so it is unit-testable; the coordinator owns the loops and I/O. `CodexRPCClient` remains a `final class` with an `NSLock` (see *Codex RPC client* below). The `Logger` wrapper uses an internal serial `DispatchQueue` for file writes — it is not an actor because callers must never await a log write.

---

## SwiftUI state management

One `@MainActor`-bound `AppViewModel: ObservableObject` bridges the actor world to SwiftUI. Actors push updates via `await MainActor.run { }`.

```swift
@MainActor
final class AppViewModel: ObservableObject {
    @Published var claudeState: ClaudeDisplayState
    @Published var codexState: CodexDisplayState
    @Published var activeTab: Tool
    // ...
}
```

Rules:
- Views hold no business logic. Read from `@EnvironmentObject var vm: AppViewModel` only.
- No per-view view models. One top-level model. *(One recorded exception since STEP_109:
  `HistoryViewModel`, the History window's own `@MainActor` bridge — a separate window with its own
  lifecycle, loader closure injected by the composition root, same views-hold-no-logic rule.
  It is a second window's model, not a per-view one.)*
- Number rules shared between the popover and the History window live in Core, not the UI
  package: `DisplayedTokens` (the §4 displayed count) and `CacheHit` (the §2.5/§2.6 ratio). A
  formatter that needs either calls it; it never re-derives the arithmetic (STEP_109).
- `@State` in views only for transient UI state (e.g. disclosure group expanded, hover state).
- A section that reads its own store query carries **availability**, not an optional (STEP_177):
  `DailyLocalReportState` is `loading` / `available` / `unavailable(retained:)`, the reader
  **throws** on a failed query, and the last good value is retained under the failure. `nil`
  or `[]` for a failed read is the pattern `AttributionEngine.attribution(for:)` still has and
  new readers must not copy — it renders a broken collector as "nothing observed".
- **A view never re-derives a number, a label or a pluralisation** (STEP_178). The section views
  added at the REV-92 cutover draw `OtherLimitsSection` and `LocalActivitySection` verbatim:
  the model groups are grouped by the formatter, the `N more projects ›` label is pluralised by
  the formatter, and the only arithmetic left in a popover view is multiplying a `0…1` progress
  fraction by a width.
- **A tagged explanation element writes its site, label and value into the diagnostics bundle**,
  so anything on the §17 never-store list must stay off a tagged row. The daily local section is
  tagged (E-23) but its walk records the fixed rows only, and its recency marker reports a
  constant site — never the project's name.
- **Silence needs a reason, or it means whatever the caller assumes** (STEP_202). The menu-bar
  reminder schedule read an empty reminder list as "recovered", so a stale poll, a freeze and a
  genuine recovery were one event and each replayed the warning from the top. The fix is a typed
  reading — `LongLimitReading` is `unknown` or `live([status])` — and it is the same shape as
  `DailyLocalReportState`'s `unavailable(retained:)` above: **a surface that can fail states that
  it failed**, rather than rendering the failure as an absence. The corollary is that a state that
  deliberately says nothing (a block, a five-hour warning outranking the long limit) stays in the
  reading and drops only its line, so nothing downstream reads its quiet as a change.
- **A lifetime is not a render** (STEP_202). What the bar *shows* and what the account is *going
  through* are different clocks: `ReminderEpisode` outlives every render of it, survives a
  relaunch through `settings`, and carries two timestamps that move on different events —
  `enteredAt` never inside an episode, `tierAt` on escalation only. A formatter that hands the
  view model strings alone forces it to re-derive the tier and the limit instance, which is why
  the reading carries them; a view model that keys state on the strings cannot tell a new week
  from a percentage ticking down.
- **A thing fitted to a measurement cannot be one of the things measured** (STEP_203). Variant D's
  menu-bar headline scales to fill the width the status item reserves, and the reservation is the
  widest render the item can draw — so if the headline were one of those renders, each would chase
  the other. `MenuBarItemView.Layout` makes the two questions different types (`.measuring` /
  `.drawing(width:)`), and the controller measures through its own offscreen hosting view. The
  second reason it must: a view that animates its own changes cannot also be the ruler, because
  walking five candidates through it fires five transitions before the real render arrives.
- **Two animations on one row are safe when they are two properties; they were not when they were
  one value** (STEP_203). §2.4a sequences the 350 ms crossfade before the pulse, and the last
  150 ms of the pulse still rides the exit fade — which is fine, because the fade animates the
  *layer's* opacity and the pulse the *row's* and SwiftUI multiplies them. The defect STEP_199 paid
  for was different in kind: one `@State` whose presentation value `repeatCount` restored and whose
  model value it did not. When adding motion, ask which value each animation owns, not how many
  animations there are.
- **A schedule is pure; a timer is not** (STEP_199). `MenuBarReminder` answers *which phase* and
  *when the next edge is* as arithmetic over one instant, `AppViewModel` holds the clock that asks
  it, and the view asks `MenuBarReminder.pulses` rather than deciding motion inline. Tests drive an
  injected clock through `advanceReminderPhase(now:)` — which is the right way to test a schedule
  and **the wrong way to test a timer**: the one defect this split could not catch was the system
  coalescing a 55-second `Task.sleep`, and only screenshots of the real menu bar found it. A long
  wait that must land on time carries an explicit tolerance, and anything that ticks on its own
  writes one DEBUG line per edge, because a clock that dies quietly is indistinguishable from
  nothing happening.
- **Two surfaces that must agree call one function; a test says so** (STEP_195). The §2.2 strip
  and the `OTHER LIMITS` row highlight are one decision — `otherLimitsSection` calls
  `longLimitStrip` itself rather than re-testing its five gates — and the hero's ink and the
  verdict's colour are another (`longLimitScopesPrimary`). Where a shared call is impossible
  because the two builders take different inputs, as with the menu-bar ⚠ slot and the strip, the
  rule is enforced by an **implication test** rather than by equality: a ⚠ slot implies a red
  strip, never the converse, because a five-hour warning legitimately outranks the long limit and
  takes the slot while the strip still stands. Same shape as `MenuBarExhaustionAgreementTests`.
- **A fixture states the state its own numbers produce** (STEP_195). `LongLimitFixtures` builds a
  `QuotaSnapshot` and runs it through the real formatter, and every frame asserts that the tier it
  claims is the tier Core derives from it. A hand-stubbed display state can pass every assertion
  while the shipped code says something else — and a fixture describing a state the engine cannot
  reach (a 95 %-used five-hour window under rank 5b, which every five-hour warning outranks) makes
  a correct rule look wrong.
- **A `PreferenceKey` does not cross a macOS `ScrollView`** (measured 2026-09-10, STEP_179): an
  `onPreferenceChange` above one fires once with the key's default and never again. A view that
  must know its own size inside a scroll view uses a background `GeometryReader` reporting through
  a closure into the caller's `@State` (`PopoverView.measuring`). A wrapping `GeometryReader` is
  not the alternative — measuring must not change what is measured.
- **An overlay over a scroll view goes inside it, not beside it** (STEP_179). Beside it, the
  overlay sits between the pointer and the list and swallows the scroll wheel — a hover card
  opened under the pointer stopped the popover scrolling, live. Inside, the wheel reaches the
  scroll view and the overlay travels with the content it is anchored to.
- **A colour pair is measured on the surface it is actually drawn on** (STEP_180). A palette is
  approved as a list of hexes, but a hex is not a contrast ratio: the reviewed REV-92 tertiary
  reads 4.81:1 on the popover base and 4.31:1 on the chrome band, and the burn pill's computed
  `dot.color.opacity(0.16)` was a fill nobody had measured because nobody had named it. Give every
  fill a token, pair it with the text that lands on it, and assert the pair —
  `ThemeContrastTests` resolves both through the real appearance provider. Body and source text
  target 4.5:1; a dot, a meter or a divider is a graphical object at 3:1, and holding one to the
  text figure is an over-assertion, not rigour.
- **Colour is never the only channel** (STEP_180). Where a status is carried by hue alone — a
  status dot, the hero percentage's ink, an age stamp turning amber — the element carries a spoken
  word beside it (`StatusDot.accessibilityStatusWord`). Where a control is a redraw of something
  already said, hide it from VoiceOver rather than repeating it: the header meter is the hero
  number and its caption drawn as geometry.
- **A window ordered front from inside `applicationDidFinishLaunching` is created and then lost**
  (STEP_204, and again in STEP_205). AppKit finishes an accessory app's launch sequence after the
  method returns, so the window never comes on screen while the process stays up looking fine — the
  glance row is written, the conflict process is alive, and there is nothing to see. One runloop turn
  later it works. It bit two different code paths in two consecutive steps, which is what makes it a
  rule rather than a note: **anything that shows a window at launch defers by one turn.**
- **Register the listener before you publish the thing that invites the message** (STEP_205). The
  §9.2 lock is what tells a second copy we exist, so the hand-off observer goes up *before* the lock
  is acquired — otherwise a request can land in the gap and the user has opened the app and got
  nothing. Ordering closes the race; a retry or a delay would only make it rarer. The corollary is
  that the listener still outruns the UI it needs, so the request is **held** (`HandoffInbox`) rather
  than answered or dropped — the same shape as `DailyLocalReportState.unavailable(retained:)` and
  `LongLimitReading.unknown` above: **state the thing you cannot yet act on, do not render it as an
  absence.**
- **A signal already in its terminal state fires no event** (STEP_206). The status item is
  occluded *before* macOS places it, so an item that stays occluded through placement never
  *changes* occlusion state and `didChangeOcclusionStateNotification` never fires again — the
  moment detection becomes eligible would pass unobserved, and the one state worth reporting is the
  one nothing announces. So the gates are re-evaluated on the triggers that change the **context**
  too (the window moving, the screens changing), and a debounce timer re-reads every gate when it
  fires rather than trusting the reading that armed it. Same family as *register the listener
  before you publish the thing that invites the message* above: both are about a fact that arrives
  in the gap where nobody is looking.
- **Observing with `object: nil` means filtering on identity, and it is not optional** (STEP_206).
  The status button's window does not exist at `MenuBarController.init` time in every launch shape,
  and `addObserver(forName:object:)` with a nil object observes **every** window's notification, not
  none — a monitor that forgets the identity check reads some other app's window and reports on it.
  Register broadly on purpose, then compare the object to the one you meant.
- `AppViewModel` is instantiated once in the app delegate and injected via `.environmentObject`.

---

## SQLite access (Baseline §17)

GRDB `DatabasePool` with WAL mode enabled from the start. `DatabasePool` (vs `DatabaseQueue`) is required because the CLI binary shares the same database file as the app — WAL mode allows concurrent multi-process access without corruption.

```swift
actor SQLiteStore {
    private let pool: DatabasePool

    init(path: String) throws {
        var config = Configuration()
        // CLI shares the file: wait out a concurrent-writer SQLITE_BUSY instead of erroring at once.
        config.busyMode = .timeout(5)
        // `DatabasePool` sets WAL implicitly; only per-connection FK enforcement needs setting here.
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        pool = try DatabasePool(path: path, configuration: config)
    }
}
```

Rules:
- No component imports GRDB directly except `SQLiteStore`. All other components call `SQLiteStore` methods.
  **One carve-out (STEP_74):** the CLI's bundle importer (`AnalysisStore`) imports GRDB directly, because it
  owns a *different* database — a corpus built from imported diagnostics bundles, which the app never opens, has no
  migrator, and whose schema mirrors whatever tables a stranger's bundle happens to contain. The rule stands
  unchanged for anything touching `kvotar.db`.
- Schema migrations via `DatabaseMigrator` — migration version 1 defined before build step 4.
- Reads use `pool.read { db in ... }`, writes use `pool.write { db in ... }`.
- Write failures are logged at ERROR level via `SQLiteStore` component. Never silently swallowed.
- **Unix timestamps must be written as `Int`**, not `Double`. All timestamp columns are declared `INTEGER`. `Date().timeIntervalSince1970` returns `Double` — always cast: `Int(Date().timeIntervalSince1970)`. SQLite accepts a Double silently but stores it as REAL, mismatching the declared type and breaking any reader that decodes the column as `Int`.

---

## Logger usage (Baseline §10.1)

Always call `Logger.*`. Never call `os_log` or file APIs directly from any component.

```swift
Logger.info("Poll complete", component: .claudeAccountAdapter,
            metadata: ["util": "38%", "reset": "1h52m", "ratelimit_remaining": "847/1000"])

Logger.warning("Poll 429 received", component: .pollEngine,
               metadata: ["endpoint": "oauth", "retry_after": "60s", "consecutive": "1"])
```

Components are the cases of `LogComponent` — they are also the `os_log` category names and the Console.app filter strings. Add a case there rather than inventing a name at a call site.

Metadata format: `key=value` pairs, greppable. The metadata half of each `os_log` line is marked `.private` in builds compiled without `DEBUG`.

Never log: prompt/code content, raw response bodies, email in plaintext. See [docs/spec/diagnostics.md](docs/spec/diagnostics.md) for the full privacy boundary of logs and diagnostics.

---

## JSONL parsing rules

### Claude (Baseline §7.2)

Filter: `type == "assistant"`. Ignore all other event types.

Token paths — all under `message.usage`:
- Input: `message.usage.input_tokens`
- Output: `message.usage.output_tokens`
- Cache creation: `message.usage.cache_creation_input_tokens` (the total; equals the sum of both tiers)
- Cache creation, 1-hour tier: `message.usage.cache_creation.ephemeral_1h_input_tokens`
- Cache read: `message.usage.cache_read_input_tokens`
- Model: `message.model`

**The two cache tiers are no longer summed away (STEP_94 → STEP_96, Baseline §7.2).** Anthropic
charges 1.25× input for a 5-minute cache write and **2× for a 1-hour** one, and most real writes are
1-hour — so pricing every write at the 5-minute rate understated the value badly, and `pricing.json`
alone could not fix it, because the parser flattened the split before storage. `TokenEvent.cacheCreation1hTokens` now
carries the 1-hour slice as a **subset** of the unchanged total (5-minute = total − 1h), clamped to
it. `nil` where the line carries no `cache_creation` object: split unknown ⇒ priced at 5-minute,
which is what every pre-`v17` row still does. Codex leaves it `nil` — OpenAI publishes no
cache-write charge, and that tool's cache-creation column holds cached *input*, not a write.

Subagent detection: `isSidechain == false` → main agent; `isSidechain == true` → subagent. Surface bucket: `Subagent · [attributionAgent]` or `Subagent · Unknown` if `attributionAgent` absent.

Deduplication key: `"<message.id>_<requestId>"` — **the session id is deliberately no part of it**
(STEP_94, Baseline §7.2). Resuming or forking a session makes Claude Code rewrite the copied lines
under the *new* session id, so a session-scoped key stored every copied message a second time.
Fall back to `"msg:<message.id>"` when `requestId` is absent (rare), or to the bare `requestId`
when `message.id` is (not yet observed). Rows written
before this change hold the bare `requestId`, so `TokenEvent.legacyDedupKey` carries the old form
and every duplicate guard matches either.

The key must keep collapsing **within-session** repeats: one API response is written as several
content-block lines sharing both ids, which is about half of raw Claude tokens (REV-62).
That is not a defect and the existing key already handles it —
`ClaudeJSONLParserTests.testWithinSessionContentBlockRepeatsShareOneKey` pins it.

**Model and surface are per-event (STEP_93, Baseline §17.1).** Every event row stores its own
`model` and `surface_bucket`; the session-level values are the fallback for pre-v15 rows only.
An event with zero usage across all four token columns asserts **no** model — neither on the
session upsert nor in its own column: `<synthetic>` is Claude Code's zero-token placeholder for
a turn that died before the API, and one such line landing last in a file used to rename the
whole session (genuine turns ended up filed under `<synthetic>`, REV-62).

### Codex (Baseline §8.4)

Filter: `payload.type == "token_count"`. Top-level `type` is `event_msg` or `response_item` — not useful for filtering.

Token paths — all under `payload.info.last_token_usage`:
- Input (per-turn): `payload.info.last_token_usage.input_tokens`
- Output (per-turn): `payload.info.last_token_usage.output_tokens`
- Cache (per-turn): `payload.info.last_token_usage.cached_input_tokens`
- Total (per-turn): `payload.info.last_token_usage.total_tokens`
- Cumulative totals: `payload.info.total_token_usage.*` (same subfields)

**Two of these are subsets, not siblings (STEP_91, Baseline §8.4).** `cached_input_tokens` is part of
`input_tokens` and `reasoning_output_tokens` is part of `output_tokens` — on every observed event,
and the provider's own `total_tokens` equals `input + output`. So: the parser stores
`output_tokens` **alone** (it used to add reasoning); any displayed Codex count is `input + output`;
the cache-hit ratio divides by `input` alone; and the est-value input term splits into cached and
uncached. Never reuse Claude's four-column sum here — Claude's columns really are disjoint.

**The cached slice is read from both cache columns.** `local_usage_events` stores Codex's cached
count in `cache_read_tokens` for rows written before 2026-07-13 and in `cache_creation_tokens` after
— no row has both — so every Codex read goes through
`SQLiteStore.ModelTokenTotals.codexCachedInputTokens`, which is a union over conventions. Fixtures
must not be drawn from pre-boundary data.

Originator: read **first line only** of each JSONL file (`type == "session_meta"`). Extract `payload.originator` and `payload.source`. Apply to all subsequent token events in that file — do not re-read originator from token_count events.

**Also extract `payload.thread_source`** (`"user"` | `"subagent"`) and, when `payload.source` is a
nested subagent object, its `agent_nickname` *(REV-63, 2026-08-12)*. **`source` is not always a
string** — a subagent-spawned session writes `{"subagent":{"thread_spawn":{…}}}` or
`{"subagent":{"other":"guardian"}}` there. Decode it leniently (a strict `String?` throws and loses
the otherwise-good `originator` with it), and use **`thread_source` as the discriminator**, not the
shape of `source`.

**And `payload.parent_thread_id` — the helper/top-level discriminator** *(REV-76 / D-95,
2026-08-22)*. `thread_source: "subagent"` does **not** mean "this is a helper": Codex writes it on
top-level threads too, and those are often the biggest spenders (most subagent-tagged
files carry no parent id, including long worktree runs and orchestrators of named helpers). **A helper is a thread with a parent id**; the nickname is not the test — it never appears
without one. Already decoded and already read as one of STEP_103's two fork-marker forms; D-95 adds
a second reader.

**Model: from `turn_context` lines (STEP_93 — the old "absent from JSONL" claim was wrong).**
A `turn_context` line is identified by its **top-level** `type == "turn_context"` — unlike
`token_count`, which lives at `payload.type` — and carries `payload.model` (e.g. `"gpt-5.5"`).
Each token event takes the most recent `turn_context` model above it; the adapter carries the
last-seen value per file across flushes. Decode to filter, never substring-scan: chat lines
*mention* "turn_context" in content. Fallback chain: carried model → `state_5.sqlite` →
`threads.model` (files predating `turn_context`; Baseline §8.5) → null.

Deduplication key: `(file basename, timestamp, payload.info.last_token_usage.total_tokens)`

**A re-emitted turn is dropped at parse (STEP_94, Baseline §8.4).** OpenAI writes the same turn into
the log again under a different timestamp, which the timestamp-bearing key above cannot catch , and the
duplicates inflated both input and output by several percent. The identity that works is the
provider's own accounting: skip any `token_count` event whose cumulative
`payload.info.total_token_usage.total_tokens` has **not advanced** past the previous event's, and
record the drop in `parse_anomalies` (written only inside an extended-diagnostics window — see [docs/spec/diagnostics.md](docs/spec/diagnostics.md)). The last-seen cumulative is carried
per file across debounced flushes (like the `turn_context` model), with a **separate** carry for
backfill reads — those start at byte 0, and judging them against a live carry already at
end-of-file would drop everything. Events carrying no cumulative field (older shapes) are exempt.
**A counter that goes backwards is a reset, not a re-emission (STEP_167, REV-87 / D-111, Baseline
§8.4).** Codex Desktop can rebuild a resumed thread's cumulative counter below its own high-water mark, and
the rule above then dropped every following turn — the Codex tab read all local surfaces idle while
every token was local. The discriminator is the event's own
`last_token_usage.total_tokens`: a re-record sits at most one turn below the carry; if the carry
minus the cumulative is **larger than this turn**, accept the event, rebase the carry on it, and
record "cumulative counter reset: carry rebased" in `parse_anomalies`. Backfill follows the same
rule, so a relaunch recovers the dropped turns through the watermark sweep.

**Never use `payload.rate_limits` for quota state** — non-authoritative local snapshot. RPC/wham only for quota. (Baseline §8.4, UI Spec D-12)

---

## Originator → surface bucket mapping (Baseline §8.4)

**Check `thread_source` first** *(REV-63 / UI Spec D-65, 2026-08-12)*. A subagent thread is named
before the originator table is consulted at all — but **only a thread carrying `parent_thread_id`
is a subagent** *(REV-76 / D-95, 2026-08-22 — supersedes the bare nickname fallback)*:

| `payload.thread_source` | `payload.parent_thread_id` | `agent_nickname` | Surface bucket |
|---|---|---|---|
| `subagent` | present | present | `Subagent · <nickname>` |
| `subagent` | present | absent | `Subagent · Unknown` |
| `subagent` | **absent** | — | **fall through to the table below** |
| `user`, or absent | — | — | fall through to the table below |

Row 3 is the whole of D-95: a nickname-less subagent tag is a **top-level thread**, not an
unidentified helper, and routing it to `Subagent · Unknown` put most of the user's own work
under a phantom. Row 2 is kept for a future shape that spawns a helper without naming it.

The `Subagent · …` vocabulary is **`ClaudeJSONLParser.surfaceBucket`'s, reused deliberately** — the
two tabs must read alike, so do not invent a Codex-specific form. Note the substrate difference the
reuse hides: **Claude's nickname is an agent *type*** (`Explore`, `general-purpose`, `Plan` — five
labels in practice), **Codex's is a per-spawn *instance*** (Fermat, Meitner, Ohm, …,
unbounded). Never render the Codex nicknames as a row set (UI Spec **D-96**).

**A helper bucket is not a surface — and that rule lives in Core, not the formatter** *(UI Spec
**D-99**, 2026-08-24)*. `Subagent · …` is a thread running *inside* whichever surface spawned it,
so it never counts toward "how many surfaces are active". The split is `KvotarCore.SurfaceWorkSplit`
(`surfaces` / `helpers`, share order preserved), and it has exactly **three** readers: the §2.6 work
rows and `Local source` copy in `DisplayFormatter`, `StateInputs.activeSurfaceBucketCount`, and
`NotificationSignal`. D-96 put it in `DisplayFormatter` alone, so only the *copy* obeyed it and §13
rule 8 read one Codex Desktop plus its own subagents as concurrent surfaces — a subagent user sat in
Multi-surface permanently. **If you need to know whether a bucket is a helper, call
`SurfaceWorkSplit`; never write a fourth `hasPrefix("Subagent · ")`.**

| `payload.originator` | `payload.source` | Surface bucket |
|---|---|---|
| `Codex Desktop` | any | `Desktop` |
| `codex_work_desktop` | any | `Desktop` |
| `codex_vscode` | any | `IDE extension` |
| `codex_cli_rs` | any | `CLI` |
| `codex_exec` | any | `CLI` |
| anything else | any | `Unknown` — bucket and monitor |

VS Code, Cursor, and Windsurf all produce `IDE extension`. No JSONL field distinguishes IDE hosts.

**`codex_work_desktop` is the same desktop app under a new name** *(hotfix 2026-08-13)*. A ChatGPT.app
release in August 2026 hard-codes this originator, replacing the `Codex Desktop` string every
earlier build wrote; until it was mapped, new desktop threads landed in `Unknown`. Older threads keep the old name, and a
subagent inherits its parent's, so both names will appear on disk for a while — **map both**.

The bundled binary holds a family beside it — `codex_work_web`, `codex_work_mobile`,
`codex_work_cca`, `chatgpt_cca`. **Only `codex_work_desktop` is mapped.** It is the only member
observed writing a real local session file; the rest are cloud surfaces that never write into
`~/.codex/sessions`, so mapping them would be a guess. They stay in the anything-else row — bucket
and monitor — and `testUnobservedWorkOriginatorFamilyStaysUnknown` pins that until a real capture
says otherwise.

**`Codex Desktop` maps to `Desktop` on any `source`, including `"vscode"`** *(changed REV-63 — it
used to split on `source` and told a desktop-only user they had used an editor extension; the app is
built on the VS Code shell and reports itself that way)*. The evidence for reading
`("Codex Desktop", *)` as the desktop app is that a genuine extension routes separately via
`codex_vscode` — **and that route is observed, not hypothetical**: genuine extension sessions carry
`codex_vscode` and bucket as `IDE extension` (STEP_100). The reading of `Codex Desktop` is still an inference
from that split rather than a provable fact, **so it is pinned by a test asserting
`codex_vscode → IDE extension`.**

---

## JSONL watching

Two-level `DispatchSource` watching — no third-party library. Both local adapters delegate the shared
plumbing to `JSONLDirectoryWatcher` (KvotarCore, STEP_24); each adapter injects only its parser,
delta rule, and (Codex) originator/SQLite-metadata hooks. The mechanics:

1. **Directory watcher** on the tool's roots — Claude `~/.claude/projects/`, Codex `~/.codex/sessions/` **and** `~/.codex/archived_sessions/`. Started at app launch. Fires when new files appear. **Watching must be recursive**: Claude JSONL sits one project-directory level down, and Codex JSONL sits under `sessions/YYYY/MM/DD/` — a single top-level source never sees those files. *(Clarified 2026-07-04; Decision 5 as originally written was under-specified for both tools.)* Directory sources are evicted on delete/rename of the directory itself. A root that exists but cannot be walked logs one `ERROR` naming it; a root that simply is not present logs one `INFO` and is re-checked each rescan (a machine that has never archived a Codex session has no `archived_sessions`).

   **The Codex root is two narrow trees, never `~/.codex` itself (STEP_117 / REV-71).** Every watched directory costs one file descriptor, and `~/.codex` is another tool's state folder that anything may write into. When an agent session scaffolded a large web project (with its `node_modules`) inside `~/.codex`, the watcher opened thousands of directory handles and exhausted the process's descriptors. **The ceiling is about 2,560, measured from that failure — not 256.** Everything that then could not open a file reported itself as *tool not set up*: both credential reads, the `which codex` lookup, and Claude's watcher. Narrowing to the two roots keeps the count small. `archived_sessions` is load-bearing — it holds real usage — and `JSONLBackfillReader` must sweep **both** roots or the archived tree's pre-launch bytes are never recovered.

   **Known limit (REV-12, open).** Directory sources remain unbounded: `sessions/` gains one directory per day and is never pruned, and `~/.claude/projects` grows per project. This buys years, not immunity. The durable fix is a choice between a single `FSEvents` subtree stream and a windowed directory bound; it needs an approved task.
2. **Per-file watcher** — created when a new JSONL file is detected by the directory watcher. Requires the file to exist before the source can be created (file descriptor needed). Per-file sources must be **cancelled and evicted** when their file is deleted or renamed (and re-created if the path reappears) — a source held forever per historical file leaks one fd each and exhausts the process fd limit (see STEP_24). **fd bound (STEP_24):** only files modified within `activeFileWindow` (30 min) hold a per-file source, most-recently-modified first, capped at `maxFileSources` (128); historical files are demoted (offset kept so a later re-promotion resumes cleanly). Byte offsets are tracked for every discovered file so a promotion never re-reads history.

**Partial-line carry (STEP_24):** appended bytes are split at the last `\n`; the un-terminated tail is retained in a per-path residual buffer and prepended to the next read, so a JSONL line split across two appends is never handed to the parser half-formed (reuses `CodexProcessTransportLive.ingest`'s approach). Dropped on truncation/rotation.

Debounce: cancel and reschedule a `DispatchWorkItem` with 5s delay on each FSEvents callback. Multiple changes within 5s produce one state evaluation.

**A flush with zero token events still reports liveness (STEP_170).** `flushNow()` already calls
`onFlush` on *any* appended completed lines, empty batch included (the STEP_26 quota-429 rationale),
so both adapters' `emit` runs on a token-less append and stamps a per-tool **last local write** on
`LocalAdapter.localWrites`. `AttributionEngine` folds it into the liveness timestamp beside the
token times, which is what the 8-minute idle test reads. Codex writes a turn's `token_count` 20–30
minutes late, so without this a working machine reads idle and the Elsewhere notification fires at
it (Baseline §8.4).

**A write is evidence of a live surface, never of an amount.** It must not reach `ingest`, the
token rate, a burn tier, the tripwire, or the STEP_77 turn-boundary hook — that last one would arm
alignment polls on ordinary appends, which `TurnBoundaryPolicy.maxActivityAge` exists to prevent.
It rides its own stream rather than a `LocalDeltaSignal` field so it cannot leak into Trigger 2.

**Launch backfill (STEP_95, REV-62 §4.2):** the EOF seed above means anything written while the
app was not running would be lost permanently, including events mid-stream in sessions the app
otherwise tracked. A one-shot
background sweep (`JSONLBackfillReader`, driven by `PollCoordinator` on a `.utility` task after
both watchers start) re-reads every file touched since the per-tool watermark
(`settings.jsonl_backfill_watermark_<tool>`; first run: 90-day horizon) from byte 0. Inserts go
through `SQLiteStore.backfillTokenEvents`, which dedups on `(tool, dedup_key)` under **any**
session id — the Codex session-id convention changed ~2026-07-13 while the dedup key stayed
stable, so the composite PK alone would re-insert pre-boundary events as duplicates. The sweep
deliberately skips quota-429 detection (a historic 429 would pair with today's utilization in
`quota_limit_events`) and the delta/emit path (historic bursts must not fire the tripwire, burn
tiers, or the STEP_77 alignment timer).

**One-shot surface repair (STEP_100, REV-63 §6):** a corrected bucket rule does not reach data
already stored. Since STEP_93 each event row carries its own `surface_bucket`, and the §2.5b bar
reads `COALESCE(local_usage_events.surface_bucket, local_sessions.surface_bucket)`, so every row the
old rule mislabelled would have kept telling a desktop-only user they had used an editor extension.
`PollCoordinator.runCodexSurfaceAttributionRepair` re-reads the Codex tree (cutoff `.distantPast`,
like the STEP_94 cleanup and unlike the 90-day enrichment — the mislabelled rows reach back to the
start of the stored history) and calls `SQLiteStore.repairSurfaceAttribution`. **This is the only path that
overwrites an already-attributed bucket** — `enrichTokenEventAttribution` coalesces and is a no-op
where a value exists. It rewrites one derived label and no token quantity (REV-43), is
completion-stamped like its siblings, and is idempotent, so losing the stamp costs a free re-run.
The per-session column is reconciled from the rows themselves (`reconcileSessionSurface`), never per
event: the Codex session-id convention changed while the dedup key stayed stable, so a re-parse
names a session differently from the row that stores it.

**Periodic rescan (STEP_32, REV-20):** a repeating `DispatchSourceTimer` on the watcher queue calls `flushNow()` every `rescanInterval` (45s default). Appends to a known-but-unwatched file (demoted, or outside `activeFileWindow` at launch) fire no FS event — dir vnode sources only see entry create/rename/delete — and re-promotion otherwise happened only inside event-driven flushes, so a *resumed* Claude Code session stayed invisible indefinitely. The rescan bounds that blind window to one interval; it also softens REV-12's new-day-dir case. Parsers stamp events with the line's own `timestamp` (fallback: parse time) so a catch-up backlog never lands as a fake "now" rate spike.

---

## Codex RPC client

`CodexRPCClient` is a `final class` (not an actor) wrapping `Foundation.Process` with `Pipe` for stdin/stdout.

Pending request tracking:
```swift
private var pendingRequests: [Int: CheckedContinuation<Data, Error>] = [:]
private let pendingLock = NSLock()
```

`NSLock` is required around `pendingRequests` — it is accessed from both the calling async context (writes on send) and the stdout reader `DispatchQueue` (writes on response arrival). This is the one place in the codebase where a lock is used instead of an actor — because `Process` stdout reading runs on a `DispatchQueue`, not in an async context.

Unsolicited notifications (no `id` field, has `method` field): log at DEBUG level via `CodexAccountAdapter` component and ignore in Pre-Alpha. Do not route to any continuation.

---

## Naming conventions (Baseline §4)

Use these terms everywhere — in code, comments, UI copy, and log messages:

| Concept | Correct term | Do not use |
|---|---|---|
| Claude menu-bar prefix | `CL` | `CC` |
| Codex menu-bar prefix | `CX` | — |
| External account burn not seen locally | `Not seen locally` in popover header (REV-92, refined REV-94 / D-116); `Elsewhere` remains on other surfaces (REV-81 / D-102) — `offMachine*` stays in identifiers | `Off-machine`, `Non-local`, `Multi-machine` |
| Primary short window | `5-hour` | `five hour`, `5h` |
| Secondary long window | `Weekly` | `7-day`, `weekly` (lowercase in code constants is fine) |
| The weekly + the monthly, together | `long limit` (`LongLimitAssessment`, `longLimit…`) | `secondary limit`, `big window` |
| API-equivalent value of tokens | `Est. token value` | `Cost` |
| Codex local IDE bucket | `IDE extension` | `vscode`, `IDE` |
| plan_type string | Raw `String` — never a Swift `enum` | Any enum representation |

---

## Testing strategy per layer (Baseline §19)

| Layer | Approach | Framework |
|---|---|---|
| Engines (StateEngine, ForecastEngine, NotificationEngine) and pure policies (`PollBackoffPolicy` and the like) | Write the test first; drive the clock and the inputs by injection | XCTest |
| Adapters (ClaudeAccountAdapter, CodexAccountAdapter, ClaudeLocalAdapter, CodexLocalAdapter) | Fixture-driven — static files in `TestFixtures/` loaded via `Bundle.module` | XCTest |
| SQLiteStore | Migrations apply cleanly; read/write round-trips for the tables a change touches | XCTest |
| Display (`DisplayFormatter`, `HistoryDisplay`) | Assert the strings and display models; previews are for looking, not proof | XCTest + Xcode Previews |
| App target (presenters, gates, pure decision types) | Tested without AppKit | XCTest, `KvotarTests` scheme |
| CLI | Argument parsing and output payloads | XCTest (`KvotarCLITests`) |

Dependency injection rule: engine code in `KvotarCore` never sees an adapter. Engines take plain
values (snapshots, token events); `PollCoordinator` holds the adapters as protocol existentials and
the composition root injects the concrete ones. Tests inject mock conformances. No swizzling, no
third-party mocking library.

```swift
// App/PollCoordinator.swift — depends on the protocol, never the concrete adapter
private let claude: any AccountAdapter
private let codex: any AccountAdapter
```

Fixtures live in `Packages/ClaudeAdapter/Tests/ClaudeAdapterTests/TestFixtures/` and
`Packages/CodexAdapter/Tests/CodexAdapterTests/TestFixtures/`, one file per provider or JSONL shape
the adapter decodes (healthy, at risk, over quota, null windows, a 429 with `Retry-After`, an expired
token, each surface and subagent form, and so on). A new shape gets a fixture before the parser
changes. **Every number and identifier in a fixture is synthetic** — never a real account's usage,
money or ids.

---

## Do / don't

| Do | Don't |
|---|---|
| Use `poll_health_events` for Kvotar's own poll 429s | Mix poll 429 and quota 429 handling or storage |
| Use `quota_limit_events` for user session 429s observed in JSONL | Use JSONL `payload.rate_limits` for quota state (D-12) |
| Compute est. token value from JSONL × pricing table internally | Use ccusage as a runtime dependency |
| Price a Claude cache write by tier — 1-hour at 2× input, 5-minute (the remainder) at 1.25× | Add `cache_creation_1h_tokens` to any token count or cache-hit ratio — it is a subset of `cache_creation_tokens`, not a fifth column |
| Count Codex tokens as `input + output`, and read its cached slice as the union of both cache columns | Reuse Claude's four-column sum on Codex, or read one cache column (both count the same tokens twice / miss most of the history) |
| Check the matched pricing row's `provider` before using it | Trust an exact model-string match across providers |
| Store normalized fields only by default; capture raw payloads through the `DiagnosticsSink` seam, gated on the §10.7a capture setting (REV-52) | Store raw payloads on any path that ignores that setting, or copy JSONL session files anywhere — they carry transcripts (§17 never-store list) |
| Depend on adapter protocols in engine code | Import concrete adapter types in KvotarCore |
| Log `email=<redacted>` in file output | Log email in plaintext |
| Read `originator` from first line (`session_meta`) only | Read originator from `token_count` events |
| Parse `plan_type` as a raw `String` | Parse `plan_type` as a Swift enum |
| Show real billed money (`used_credits`, `monthly_limit`, prepaid `amount`, the `spend` money objects) in the provider's own currency through `Fmt.money` — symbol first, never converted (REV-102 §2.5, STEP_219) — the §2.4a Cost-naming exemption | Route real credit dollars through the Est.-token-value grammar (D-05 applies to estimates only) |
| Assert credit state (on/off, armed/charging, auto-reload on/off) only from a validated source; degrade to `nil`/row-suppressed when a source (e.g. `/prepaid/credits`) fails | Assert a dollar amount or "about to charge" from an unvalidated/absent field (auto_reload warning is gated on P2-8 +a/+b — REV-29 §2.4a.5) |
| Derive the §1.6 glyph + §2.4a status from the shared forecast result | Fork a second forecast/hysteresis counter for money (reuse §13.4) |
| Add unrequested code only when a task explicitly requires it | Add abstractions or refactor adjacent code speculatively |
