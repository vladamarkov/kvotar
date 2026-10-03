import XCTest
import KvotarCore
@testable import CodexAdapter

/// Step 11 fixture tests for `CodexJSONLParser` (Baseline §8.4; task Step 11).
final class CodexJSONLParserTests: XCTestCase {

    private let parser = CodexJSONLParser()

    private func jsonlData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "jsonl"),
            "missing fixture: \(name).jsonl"
        )
        return try Data(contentsOf: url)
    }

    /// Mirrors the adapter's real flow: parse line 1 as `session_meta`, then parse every
    /// remaining line as `token_count` events using the resolved origination — including the
    /// fork-marker anchor (STEP_103), exactly as `CodexLocalAdapter` threads it.
    private func parseFile(_ name: String,
                           with parser: CodexJSONLParser? = nil) throws -> [TokenEvent] {
        let parser = parser ?? self.parser
        let data = try jsonlData(name)
        guard let newlineIndex = data.firstIndex(of: 0x0A) else { return [] }
        let firstLine = data[data.startIndex..<newlineIndex]
        let rest = data[data.index(after: newlineIndex)...]
        let resolved = parser.parseSessionMeta(Data(firstLine))
        return parser.parseTokenEvents(
            Data(rest), sessionId: name,
            surfaceBucket: resolved?.surfaceBucket ?? CodexJSONLParser.surfaceUnknown,
            originator: resolved?.originator,
            forkMarkerAt: resolved?.forkMarkerAt,
            sourceFile: "\(name).jsonl"
        ).events
    }

    // MARK: A turn that writes its token accounting late (STEP_170 / STEP_173)

    /// The shape the alpha tester's 2026-09-03 morning was made of, and the shape no committed
    /// fixture carried until now: ten real 2026-09 rollout line types — `task_started`,
    /// `turn_context`, `message`, `item_completed`, `reasoning`, `custom_tool_call`,
    /// `custom_tool_call_output`, `task_complete`, `token_usage_record` — and the turn's
    /// `token_count` arriving **thirty minutes** after the work began. Every other fixture in this
    /// directory is `session_meta` followed by `token_count` only, so nothing pinned what the
    /// parser does with an ordinary working file.
    ///
    /// Content fields are blanked: the absolute rule is that no prompt, code, transcript or tool
    /// output is ever stored, fixtures included. Only the structure is real.
    func testLateTokenCountYieldsOneEventFromTenTokenlessLines() throws {
        let events = try parseFile("codex_local_late_token_count")
        XCTAssertEqual(events.count, 1,
                       "ten token-less lines carry no usage; only the late token_count counts")
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.surfaceBucket, "IDE extension")
        XCTAssertEqual(event.inputTokens, 23220)
        XCTAssertEqual(event.outputTokens, 161)
        XCTAssertEqual(event.model, "gpt-5.6-sol", "the turn_context line above it supplies the model")
    }

    /// `token_usage_record` is a newer top-level line that repeats the same turn's usage one line
    /// before the `event_msg` / `token_count` (live rollout, 2026-09-10). The filter is
    /// `payload.type == "token_count"`, so it is ignored — which is the only reason the turn above
    /// counts once rather than twice. Pinned because the line is new and looks countable.
    func testTokenUsageRecordLineIsNotCountedTwice() throws {
        let events = try parseFile("codex_local_late_token_count")
        let total = events.reduce(0) {
            $0 + $1.inputTokens + $1.outputTokens
        }
        XCTAssertEqual(total, 23381,
                       "the turn is counted once, from token_count — not again from token_usage_record")
    }

    // MARK: Desktop session — Codex Desktop + source: desktop → Desktop bucket

    func testDesktopSessionBucketAndTokenPaths() throws {
        let event = try XCTUnwrap(parseFile("codex_local_desktop").first)
        XCTAssertEqual(event.tool, .codex)
        XCTAssertEqual(event.surfaceBucket, "Desktop")
        XCTAssertEqual(event.originator, "Codex Desktop")
        XCTAssertEqual(event.inputTokens, 100)
        // `reasoning_output_tokens` (5) is a **subset of** `output_tokens` (50), not a sibling —
        // so output is 50, not 55 (STEP_91, inverting what this line asserted before). Adding them
        // charged and displayed the same generated tokens twice; OpenAI bills reasoning as output
        // exactly once.
        XCTAssertEqual(event.outputTokens, 50)
        XCTAssertEqual(event.cacheCreationTokens, 20)
        XCTAssertEqual(event.cacheReadTokens, 0)
        XCTAssertNil(event.project, "project unavailable from Codex JSONL — SQLite join is Step 12")
        XCTAssertNil(event.model, "model unavailable from Codex JSONL — SQLite join is Step 12")
    }

    /// The subset invariant, stated as a test rather than a comment (Baseline §8.4): whatever the
    /// reasoning count is, it never adds to the stored output column.
    func testReasoningTokensAreNotAddedToOutput() throws {
        let event = try XCTUnwrap(parseFile("codex_local_desktop").first)
        // The fixture line carries output 50 / reasoning 5. `output + reasoning` would be 55.
        XCTAssertEqual(event.outputTokens, 50)
        XCTAssertNotEqual(event.outputTokens, 55,
                          "reasoning must not be folded into output — it is already inside it")
    }

    // MARK: Timestamp honesty (REV-20, STEP_32)

    /// Events must be stamped at the line's own `timestamp` when it parses as ISO8601 — a
    /// catch-up read of backlogged lines must not register as a fake "now" spike.
    func testRecordedAtUsesLineTimestamp() throws {
        let event = try XCTUnwrap(parseFile("codex_local_desktop").first)
        XCTAssertEqual(event.recordedAt,
                       ISO8601DateFormatter().date(from: "2026-07-01T10:00:00Z"))
        XCTAssertEqual(event.startedAt, event.recordedAt)
    }

    /// A non-ISO timestamp string keeps the dedup key intact but falls back to parse time —
    /// the timestamp path is spike-unconfirmed and must never cost an event.
    func testUnparseableTimestampFallsBackToParseTime() throws {
        let line = Data("""
        {"type":"event_msg","timestamp":"07/06/2026 10:00","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}}}
        """.utf8)
        let parseTime = Date(timeIntervalSince1970: 1_750_000_000)
        let event = try XCTUnwrap(parser.parseTokenEvents(
            line, sessionId: "s", surfaceBucket: "CLI", originator: "codex_cli_rs",
            recordedAt: parseTime).events.first)
        XCTAssertEqual(event.recordedAt, parseTime)
        XCTAssertEqual(event.dedupKey, "s_07/06/2026 10:00_2",
                       "the opaque timestamp still widens the dedup key")
    }

    // MARK: CLI session — codex_cli_rs → CLI bucket

    func testCLISessionBucket() throws {
        let event = try XCTUnwrap(parseFile("codex_local_cli").first)
        XCTAssertEqual(event.surfaceBucket, "CLI")
        XCTAssertEqual(event.originator, "codex_cli_rs")
    }

    /// STEP_192: the CLI's current originator. First seen 2026-09-13 19:31 CEST on the one live
    /// session of the evening; it had been landing in `Unknown` and reached the popover as
    /// "Desktop and Unknown are both active". Every other unseen name still stays `Unknown` — §8.4
    /// maps only what has been observed writing a real local session file.
    func testCodexTUIOriginatorIsCLI() {
        for originator in ["codex-tui", "codex_cli_rs", "codex_exec"] {
            XCTAssertEqual(
                CodexJSONLParser.surfaceBucket(originator: originator, source: "cli",
                                               threadSource: nil, agentNickname: nil,
                                               parentThreadId: nil),
                "CLI", originator)
        }
        XCTAssertEqual(
            CodexJSONLParser.surfaceBucket(originator: "codex_work_web", source: nil,
                                           threadSource: nil, agentNickname: nil,
                                           parentThreadId: nil),
            "Unknown", "an unobserved originator is not pre-mapped on a guess")
    }

    /// STEP_197 moved the originator table into `KvotarCore.CodexSurface` so the daily local
    /// report can resolve a helper session's originator at read time. The parser must keep
    /// answering exactly as before — one table, two readers, no drift (the drift is what
    /// STEP_192 cost).
    func testOriginatorTableMoveKeepsParserAnswers() {
        let originators = ["Codex Desktop", "codex_work_desktop", "codex_vscode", "codex_cli_rs",
                           "codex_exec", "codex-tui", "codex_work_web", ""]
        for originator in originators {
            for source in [nil, "cli", "vscode", "desktop"] as [String?] {
                XCTAssertEqual(
                    CodexJSONLParser.surfaceBucket(originator: originator, source: source,
                                                   threadSource: nil, agentNickname: nil,
                                                   parentThreadId: nil),
                    CodexSurface.bucket(originator: originator, source: source),
                    "\(originator) / \(source ?? "nil")")
            }
        }
        // The helper rule stays in the parser — Core never sees thread fields.
        XCTAssertEqual(
            CodexJSONLParser.surfaceBucket(originator: "Codex Desktop", source: nil,
                                           threadSource: "subagent", agentNickname: "Bacon",
                                           parentThreadId: "p1"),
            "Subagent · Bacon")
    }

    // MARK: Codex Desktop + source: vscode → Desktop (REV-63/D-65 — was `IDE extension`)

    /// The desktop app is built on the VS Code shell and reports `source: "vscode"` about itself,
    /// so the old `("Codex Desktop","vscode") → IDE extension` row told a user who had only ever
    /// opened the desktop app that they had used an editor extension. This is the dominant real
    /// shape on the dogfood machine (105 of 153 session files carry it).
    func testCodexDesktopWithVSCodeSourceIsDesktop() throws {
        let event = try XCTUnwrap(parseFile("codex_local_ide").first)
        XCTAssertEqual(event.surfaceBucket, "Desktop")
    }

    // MARK: IDE extension — the pin under the `("Codex Desktop", *) → Desktop` inference

    /// **The pin STEP_100 exists to hold** (REV-63 §6.2, UI Spec D-65). Reading
    /// `("Codex Desktop", *)` as the desktop app rests on a genuine editor extension routing
    /// separately, via `originator: "codex_vscode"`. The fixture is drawn from a real capture on
    /// this machine — 2026-06-08, cli 0.137.0-alpha.4 — so the other path is
    /// provably still handled and cannot be collapsed by a later edit without failing here.
    func testCodexVSCodeOriginatorStaysIDEExtension() throws {
        let event = try XCTUnwrap(parseFile("codex_local_vscode_extension").first)
        XCTAssertEqual(event.surfaceBucket, "IDE extension")
        XCTAssertEqual(event.originator, "codex_vscode")
    }

    // MARK: `codex_work_desktop` — the desktop app's new originator name (hotfix 2026-08-13)

    /// The desktop app renamed itself. ChatGPT.app 26.803.61601 (installed 2026-08-11, bundling
    /// codex 0.147.0-alpha.6.5) writes `originator: "codex_work_desktop"` where every earlier
    /// build wrote `"Codex Desktop"`, so the first new thread after the update fell straight
    /// through to `Unknown` and the popover told a desktop-only user their week was part-Unknown.
    /// The fixture is the real capture that exposed it — 2026-08-13 20:12 local.
    ///
    /// `source` is still `"vscode"`, so this also re-exercises the REV-63 rule above: the bucket
    /// must come from the originator, never from the VS Code shell the app is built on.
    func testCodexWorkDesktopOriginatorIsDesktop() throws {
        let event = try XCTUnwrap(parseFile("codex_local_work_desktop").first)
        XCTAssertEqual(event.surfaceBucket, "Desktop")
        XCTAssertEqual(event.originator, "codex_work_desktop",
                       "the raw name is stored as-is; only the bucket is normalized")
    }

    /// The siblings found beside `codex_work_desktop` in the bundled Rust binary are deliberately
    /// **not** mapped: they are cloud surfaces that never write a file into `~/.codex/sessions`,
    /// so mapping them would be guessing. This pins that choice — if a later edit pre-maps them
    /// on a hunch, it fails here and has to justify itself with a real capture first.
    func testUnobservedWorkOriginatorFamilyStaysUnknown() {
        for originator in ["codex_work_web", "codex_work_mobile", "codex_work_cca", "chatgpt_cca"] {
            XCTAssertEqual(
                CodexJSONLParser.surfaceBucket(originator: originator, source: "vscode",
                                               threadSource: "user", agentNickname: nil,
                                               parentThreadId: nil),
                CodexJSONLParser.surfaceUnknown,
                "\(originator) has never been observed locally — bucket and monitor, do not guess"
            )
        }
    }

    // MARK: Subagent threads — `thread_source` wins over the originator table (REV-63, P2-4)

    /// A desktop-spawned subagent carrying `agent_nickname` reads exactly as Claude's does:
    /// `Subagent · <name>`. Fixture shape copied from a real thread (2026-08-12).
    func testNamedSubagentThreadUsesNickname() throws {
        let event = try XCTUnwrap(parseFile("codex_local_subagent_named").first)
        XCTAssertEqual(event.surfaceBucket, "Subagent · Fermat")
        XCTAssertEqual(event.originator, "Codex Desktop",
                       "the nested `source` decode must still not cost the originator")
    }

    /// `thread_source: "subagent"` with a plain-string `source` and **no `parent_thread_id`** —
    /// 30 real files on this machine carry the 2026-07-03 shape below. This used to read
    /// `Subagent · Unknown`, and that was the D-95 defect: Codex writes the tag on **top-level
    /// threads too**, so the catch-all became where main threads went (502.6M tokens of the
    /// user's own work, REV-76 §2.3). A census of all 181 corpus files splits with zero overlap
    /// across two Codex versions — a nickname never appears without a parent id — so the parent
    /// id is the discriminator and this thread falls through to the originator table.
    func testSubagentTagWithoutParentIsATopLevelThread() throws {
        let event = try XCTUnwrap(parseFile("codex_local_subagent_unnamed").first)
        XCTAssertEqual(event.surfaceBucket, "Desktop",
                       "a subagent tag with no parent id is the user's own desktop thread")
    }

    /// The headline case, drawn from a real 2026-08-20 orchestrator (fixture id `…000000000009`) —
    /// the thread that is the literal `parent_thread_id` of all six nicknamed helpers that ran that
    /// morning, and which the old rule filed as a sibling of its own children under a label
    /// meaning "we could not identify this". Newer Codex (`codex_work_desktop`, 0.147.0-alpha)
    /// than the fixture above, same verdict.
    func testOrchestratorThreadBucketsAsItsOwnSurface() throws {
        let event = try XCTUnwrap(parseFile("codex_local_subagent_no_parent").first)
        XCTAssertEqual(event.surfaceBucket, "Desktop")
        XCTAssertEqual(event.originator, "codex_work_desktop")
    }

    /// Row 2 of the D-95 table, kept deliberately: a future Codex shape could spawn a helper
    /// without naming it, and `Subagent · Unknown` is the honest label *behind a present parent
    /// id*. No file on disk has this shape, so it is pinned by a direct call rather than a
    /// fixture — inventing a capture for it would be the guess this table exists to avoid.
    func testParentedThreadWithoutNicknameStaysSubagentUnknown() {
        XCTAssertEqual(
            CodexJSONLParser.surfaceBucket(originator: "Codex Desktop", source: "vscode",
                                           threadSource: "subagent", agentNickname: nil,
                                           parentThreadId: "01900000-0000-7000-8000-000000000005"),
            CodexJSONLParser.surfaceSubagentUnknown
        )
    }

    /// The vocabulary is Claude's, restated rather than imported (adapters depend on Core only,
    /// never on each other — ARCHITECTURE.md). Nothing enforces that at compile time, so the two
    /// literals are pinned here: if either adapter's wording drifts, the two tabs stop reading
    /// alike and this fails.
    func testSubagentVocabularyMatchesTheClaudeTab() {
        XCTAssertEqual(CodexJSONLParser.surfaceSubagentUnknown, "Subagent · Unknown")
        XCTAssertEqual(CodexJSONLParser.surfaceBucket(
            originator: "Codex Desktop", source: nil, threadSource: "subagent",
            agentNickname: "Fermat", parentThreadId: "01900000-0000-7000-8000-000000000005"),
                       "Subagent · Fermat")
    }

    // MARK: Unrecognized originator — the remaining `Unknown` case (bucket and monitor)

    /// P2-4 was never this shape (it was a subagent thread, resolved above), but the
    /// anything-else row still has to hold: an originator the table does not name buckets as
    /// `Unknown` rather than being guessed at.
    func testUnknownOriginatorFallsBackToUnknownBucket() throws {
        let event = try XCTUnwrap(parseFile("codex_local_unknown_originator").first)
        XCTAssertEqual(event.surfaceBucket, "Unknown")
        XCTAssertEqual(event.originator, "guardian")
    }

    // MARK: Null-info token event — no usable token data, dropped gracefully

    func testNullInfoTokenEventDropped() throws {
        let events = try parseFile("codex_local_null_info")
        XCTAssertTrue(events.isEmpty, "token_count events with no info/total_tokens must be skipped, not crash")
    }

    // MARK: Duplicate token event — parser doesn't dedupe (SQLite PK layer does)

    func testDuplicateTokenEventsProduceSameDedupKey() throws {
        let events = try parseFile("codex_local_dedup")
        XCTAssertEqual(events.count, 2, "parser reports every line — dedup happens at the DB PK layer")
        XCTAssertEqual(events[0].dedupKey, events[1].dedupKey)
    }

    // MARK: Nested (non-string) `source` — confirmed on real data (2026-07-03), must not lose
    // originator (regression test for the live-diagnostic finding, §8.4)

    func testNestedSourceObjectDoesNotLoseOriginator() throws {
        let event = try XCTUnwrap(parseFile("codex_local_nested_source").first)
        XCTAssertEqual(event.originator, "Codex Desktop")
        // The `{"subagent":{"other":"guardian"}}` variant predates `thread_source` and carries no
        // nickname, so nothing names it a subagent and it falls through to the originator table —
        // where `("Codex Desktop", *)` now catches it. It used to land on `Unknown`; this is the
        // 2026-07-03 case resolving without a special case (REV-63 §6).
        XCTAssertEqual(event.surfaceBucket, "Desktop")
    }

    // MARK: payload.type filtering — top-level type is not used for filtering (§8.4)

    func testNonTokenCountPayloadTypeIgnored() {
        let data = Data("""
        {"type":"event_msg","timestamp":"t","payload":{"type":"something_else"}}
        """.utf8)
        XCTAssertTrue(parser.parseTokenEvents(
            data, sessionId: "s", surfaceBucket: "CLI", originator: "codex_cli_rs"
        ).events.isEmpty)
    }

    // MARK: model/project pass-through — populated by CodexSQLiteMetadataReader (task Step 12,
    // §8.5), not JSONL itself. Covers the "session discovery with model populated" fixture case.

    func testModelAndProjectPassThroughWhenProvided() throws {
        let data = try jsonlData("codex_local_desktop")
        guard let newlineIndex = data.firstIndex(of: 0x0A) else { return XCTFail("fixture missing newline") }
        let rest = data[data.index(after: newlineIndex)...]
        let events = parser.parseTokenEvents(
            Data(rest), sessionId: "codex_local_desktop", surfaceBucket: "Desktop",
            originator: "Codex Desktop", sessionModel: "gpt-5.5", project: "/Users/dev/project"
        ).events
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.model, "gpt-5.5")
        XCTAssertEqual(event.project, "/Users/dev/project")
    }

    // MARK: session_meta parsing — malformed first line yields nil (adapter falls back to Unknown)

    func testMalformedSessionMetaReturnsNil() {
        XCTAssertNil(parser.parseSessionMeta(Data("not json".utf8)))
        XCTAssertNil(parser.parseSessionMeta(Data(#"{"type":"session_meta","payload":{}}"#.utf8)))
    }

    // MARK: turn_context — the per-turn model source (STEP_93, REV-62 §4.3)

    /// Line shapes mirror the real corpus (verified 2026-08-12): `turn_context` is a **top-level**
    /// `type`, unlike `token_count` which lives at `payload.type`, and carries `payload.model`.
    private func tokenLine(_ total: Int, at: String = "2026-08-01T10:00:00.000Z") -> String {
        #"{"type":"event_msg","timestamp":"\#(at)","payload":{"type":"token_count","info":{"# +
        #""last_token_usage":{"input_tokens":\#(total),"output_tokens":10,"# +
        #""cached_input_tokens":0,"reasoning_output_tokens":0,"total_tokens":\#(total + 10)}}}}"#
    }

    private func turnContextLine(model: String) -> String {
        #"{"type":"turn_context","timestamp":"2026-08-01T10:00:00.000Z","# +
        #""payload":{"turn_id":"t","model":"\#(model)","effort":"high"}}"#
    }

    func testTurnContextModelAppliesToFollowingEventsAndSwitchesMidFile() throws {
        let blob = [
            turnContextLine(model: "gpt-5.5"),
            tokenLine(100),
            turnContextLine(model: "gpt-5.4"),
            tokenLine(200),
        ].joined(separator: "\n")
        let batch = parser.parseTokenEvents(
            Data(blob.utf8), sessionId: "s", surfaceBucket: "CLI", originator: "codex_cli_rs",
            sessionModel: "gpt-5.3-from-sqlite"
        )
        XCTAssertEqual(batch.events.count, 2)
        XCTAssertEqual(batch.events[0].model, "gpt-5.5")
        XCTAssertEqual(batch.events[1].model, "gpt-5.4",
                       "a mid-session model switch reattributes from the switch, not the file")
        XCTAssertEqual(batch.lastTurnContextModel, "gpt-5.4")
    }

    func testEventsBeforeFirstTurnContextUseCarryThenSessionModel() throws {
        let blob = [tokenLine(100), turnContextLine(model: "gpt-5.5"), tokenLine(200)]
            .joined(separator: "\n")
        // With a carried model (an earlier read of this file saw a turn_context), it wins.
        let carried = parser.parseTokenEvents(
            Data(blob.utf8), sessionId: "s", surfaceBucket: "CLI", originator: "codex_cli_rs",
            sessionModel: "gpt-5.3-from-sqlite", carriedModel: "gpt-5.4"
        )
        XCTAssertEqual(carried.events[0].model, "gpt-5.4")
        XCTAssertEqual(carried.events[1].model, "gpt-5.5")
        // Without one — a file predating turn_context — the sqlite session model is the fallback.
        let fallback = parser.parseTokenEvents(
            Data(tokenLine(100).utf8), sessionId: "s", surfaceBucket: "CLI",
            originator: "codex_cli_rs", sessionModel: "gpt-5.3-from-sqlite"
        )
        XCTAssertEqual(fallback.events[0].model, "gpt-5.3-from-sqlite")
        XCTAssertNil(fallback.lastTurnContextModel)
    }

    /// The trap found while verifying the corpus: chat lines *mention* "turn_context" in their
    /// content. Only a decoded top-level `type == "turn_context"` may change the model — a
    /// `response_item` message whose payload text contains the string must not.
    func testChatLineMentioningTurnContextDoesNotChangeModel() throws {
        let chatLine = #"{"type":"response_item","timestamp":"t","payload":{"type":"message","# +
            #""role":"assistant","content":"the type turn_context and model gpt-9 are discussed"}}"#
        let blob = [turnContextLine(model: "gpt-5.5"), chatLine, tokenLine(100)]
            .joined(separator: "\n")
        let batch = parser.parseTokenEvents(
            Data(blob.utf8), sessionId: "s", surfaceBucket: "CLI", originator: "codex_cli_rs"
        )
        XCTAssertEqual(batch.events.count, 1)
        XCTAssertEqual(batch.events[0].model, "gpt-5.5")
        XCTAssertEqual(batch.lastTurnContextModel, "gpt-5.5")
    }

    // MARK: Re-emitted turns (STEP_94 (a), REV-62 §4.1)

    /// A token line carrying the provider's cumulative account alongside the per-turn delta.
    private func cumulativeTokenLine(last: Int, cumulative: Int,
                                     at: String = "2026-08-01T10:00:00.000Z") -> String {
        #"{"type":"event_msg","timestamp":"\#(at)","payload":{"type":"token_count","info":{"# +
        #""last_token_usage":{"input_tokens":\#(last),"output_tokens":0,"# +
        #""cached_input_tokens":0,"reasoning_output_tokens":0,"total_tokens":\#(last)},"# +
        #""total_token_usage":{"input_tokens":\#(cumulative),"output_tokens":0,"# +
        #""cached_input_tokens":0,"reasoning_output_tokens":0,"total_tokens":\#(cumulative)}}}}"#
    }

    /// OpenAI re-emits the same turn with a different timestamp, which defeats the
    /// timestamp-bearing dedup key (0 of 192 corpus re-emissions collapsed). The provider's own
    /// cumulative account is the identity: a turn whose cumulative total has not advanced is a
    /// re-record of work already counted — dropped, with a `parse_anomalies` record so the rate
    /// stays visible.
    func testReEmittedTurnWithUnchangedCumulativeTotalIsDropped() {
        var seen: [ParseAnomaly] = []
        let parser = CodexJSONLParser(onAnomaly: { seen.append($0) })
        let blob = [
            cumulativeTokenLine(last: 15, cumulative: 15, at: "2026-08-01T10:00:00.000Z"),
            cumulativeTokenLine(last: 15, cumulative: 15, at: "2026-08-01T10:00:07.000Z"),
            cumulativeTokenLine(last: 5, cumulative: 20, at: "2026-08-01T10:01:00.000Z"),
        ].joined(separator: "\n")
        let batch = parser.parseTokenEvents(
            Data(blob.utf8), sessionId: "s", surfaceBucket: "CLI", originator: "codex_cli_rs",
            sourceFile: "rollout.jsonl"
        )
        XCTAssertEqual(batch.events.count, 2,
                       "the re-emission is dropped; the genuinely advancing turn is kept")
        XCTAssertEqual(batch.events.map(\.inputTokens), [15, 5])
        XCTAssertEqual(batch.lastCumulativeTotal, 20)
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen[0].tool, .codex)
        XCTAssertTrue(seen[0].error?.contains("not advanced") ?? false)
    }

    /// The carry across debounced reads of the same file: a re-emission split across two flushes
    /// must be caught exactly like one inside a single blob.
    func testCarriedCumulativeTotalDropsReEmissionAcrossReads() {
        let first = parser.parseTokenEvents(
            Data(cumulativeTokenLine(last: 15, cumulative: 15).utf8),
            sessionId: "s", surfaceBucket: "CLI", originator: "codex_cli_rs"
        )
        XCTAssertEqual(first.events.count, 1)
        XCTAssertEqual(first.lastCumulativeTotal, 15)

        let blob = [
            cumulativeTokenLine(last: 15, cumulative: 15, at: "2026-08-01T10:00:07.000Z"),
            cumulativeTokenLine(last: 5, cumulative: 20, at: "2026-08-01T10:01:00.000Z"),
        ].joined(separator: "\n")
        let second = parser.parseTokenEvents(
            Data(blob.utf8), sessionId: "s", surfaceBucket: "CLI", originator: "codex_cli_rs",
            carriedCumulativeTotal: first.lastCumulativeTotal
        )
        XCTAssertEqual(second.events.count, 1)
        XCTAssertEqual(second.events[0].inputTokens, 5)
        XCTAssertEqual(second.lastCumulativeTotal, 20)
    }

    /// Older file shapes carry no `total_token_usage` — the rule must never drop those events,
    /// even when their per-turn numbers repeat exactly.
    func testEventWithoutCumulativeTotalIsExemptFromDropRule() {
        var seen: [ParseAnomaly] = []
        let parser = CodexJSONLParser(onAnomaly: { seen.append($0) })
        let blob = [tokenLine(100), tokenLine(100)].joined(separator: "\n")
        let batch = parser.parseTokenEvents(
            Data(blob.utf8), sessionId: "s", surfaceBucket: "CLI", originator: "codex_cli_rs",
            sourceFile: "rollout.jsonl",
        )
        XCTAssertEqual(batch.events.count, 2)
        XCTAssertNil(batch.lastCumulativeTotal)
        XCTAssertTrue(seen.isEmpty)
    }

    // MARK: Cumulative counter reset (STEP_167, REV-87 / D-111)

    /// A counter that falls by more than the event's own turn was rebuilt by Codex, not
    /// re-emitted: the event is kept, the carry rebases on it, and the turns that follow are
    /// judged against the new ladder — including a genuine re-emission after the reset.
    func testCumulativeCounterResetRebasesCarryInsteadOfDropping() {
        var seen: [ParseAnomaly] = []
        let parser = CodexJSONLParser(onAnomaly: { seen.append($0) })
        let blob = [
            cumulativeTokenLine(last: 15, cumulative: 15, at: "2026-08-01T10:00:00.000Z"),
            cumulativeTokenLine(last: 5, cumulative: 20, at: "2026-08-01T10:01:00.000Z"),
            // Reset: 20 − 7 = 13 > this turn's 7 → accepted, carry becomes 7.
            cumulativeTokenLine(last: 7, cumulative: 7, at: "2026-08-01T10:02:00.000Z"),
            cumulativeTokenLine(last: 3, cumulative: 10, at: "2026-08-01T10:03:00.000Z"),
            // Re-emission after the reset: 10 − 10 = 0 ≤ 3 → dropped.
            cumulativeTokenLine(last: 3, cumulative: 10, at: "2026-08-01T10:03:07.000Z"),
        ].joined(separator: "\n")
        let batch = parser.parseTokenEvents(
            Data(blob.utf8), sessionId: "s", surfaceBucket: "Desktop", originator: "Codex Desktop",
            sourceFile: "rollout.jsonl"
        )
        XCTAssertEqual(batch.events.map(\.inputTokens), [15, 5, 7, 3])
        XCTAssertEqual(batch.lastCumulativeTotal, 10)
        XCTAssertEqual(seen.count, 2)
        XCTAssertTrue(seen[0].error?.contains("counter reset") ?? false)
        XCTAssertTrue(seen[1].error?.contains("not advanced") ?? false)
    }

    /// The boundary: a regression no larger than the event's own turn is still a re-record.
    func testRegressionWithinOneTurnIsStillDropped() {
        var seen: [ParseAnomaly] = []
        let parser = CodexJSONLParser(onAnomaly: { seen.append($0) })
        let batch = parser.parseTokenEvents(
            Data(cumulativeTokenLine(last: 30, cumulative: 15).utf8),
            sessionId: "s", surfaceBucket: "CLI", originator: "codex_cli_rs",
            carriedCumulativeTotal: 20, sourceFile: "rollout.jsonl"
        )
        XCTAssertTrue(batch.events.isEmpty)
        XCTAssertEqual(batch.lastCumulativeTotal, 20)
        XCTAssertEqual(seen.count, 1)
        XCTAssertTrue(seen[0].error?.contains("not advanced") ?? false)
    }

    /// The real 2026-09-07 shape across two reads: the file ended the night at 26,977,258 and
    /// the resumed thread's first turn arrived at 19,776,834 with a 101,274-token turn. Under
    /// the STEP_94 rule alone every turn that morning was dropped.
    func testCounterResetAcrossReadsViaCarry() {
        let evening = parser.parseTokenEvents(
            Data(cumulativeTokenLine(last: 98_918, cumulative: 26_977_258,
                                     at: "2026-09-06T21:21:54.812Z").utf8),
            sessionId: "s", surfaceBucket: "Desktop", originator: "Codex Desktop"
        )
        XCTAssertEqual(evening.lastCumulativeTotal, 26_977_258)

        let morning = parser.parseTokenEvents(
            Data(cumulativeTokenLine(last: 101_274, cumulative: 19_776_834,
                                     at: "2026-09-07T07:45:13.076Z").utf8),
            sessionId: "s", surfaceBucket: "Desktop", originator: "Codex Desktop",
            carriedCumulativeTotal: evening.lastCumulativeTotal
        )
        XCTAssertEqual(morning.events.count, 1)
        XCTAssertEqual(morning.events[0].inputTokens, 101_274)
        XCTAssertEqual(morning.lastCumulativeTotal, 19_776_834)
    }

    // MARK: Inherited forked-thread history (STEP_103)

    /// The headline case, drawn from the real 2026-08-12 "Fermat" fork: a fork-marked file
    /// replays the parent's history within milliseconds of `session_meta`, then genuine turns
    /// resume 10 s later. The inherited block is dropped — one anomaly per drop — and the
    /// genuine turns survive, which also pins the window edge: 10 s is outside `2 s`.
    func testForkedFileInheritedBlockDroppedAndGenuineTurnsKept() throws {
        var seen: [ParseAnomaly] = []
        let parser = CodexJSONLParser(onAnomaly: { seen.append($0) })
        let events = try parseFile("codex_local_forked_inherited", with: parser)
        // Fixture: 3 inherited lines at +1 ms, 2 genuine turns at +10.2 s and +17.5 s.
        XCTAssertEqual(events.count, 2, "only the post-window genuine turns survive")
        XCTAssertEqual(events.map(\.surfaceBucket), ["Subagent · Fermat", "Subagent · Fermat"])
        XCTAssertEqual(seen.count, 3, "each inherited drop writes one anomaly record")
        XCTAssertTrue(seen.allSatisfy { $0.error?.contains("forked-thread history") ?? false })
        XCTAssertTrue(seen.allSatisfy { $0.tool == .codex })
    }

    /// The Raman shape, drawn from the real 2026-07-16 capture: `parent_thread_id` alone marks
    /// a subagent-*spawned* thread, not a duplicating fork — its first turn lands 16 s out with
    /// its own cumulative ladder. A rule keyed on the marker alone would delete 11 real turns;
    /// the window is what spares them. Nothing is dropped and no anomaly is written.
    func testParentThreadIdWithoutInheritedBlockLosesNothing() throws {
        var seen: [ParseAnomaly] = []
        let parser = CodexJSONLParser(onAnomaly: { seen.append($0) })
        let events = try parseFile("codex_local_forked_parent_only", with: parser)
        XCTAssertEqual(events.count, 2, "a genuine subagent thread keeps every turn")
        XCTAssertTrue(seen.isEmpty)
    }

    /// An ordinary file — no fork marker — resolves `forkMarkerAt` nil, and the window rule
    /// never engages regardless of how fast the first turn follows `session_meta`.
    func testOrdinaryFileResolvesNoForkMarkerAndIsUntouched() throws {
        let data = try jsonlData("codex_local_desktop")
        let newlineIndex = try XCTUnwrap(data.firstIndex(of: 0x0A))
        let resolved = try XCTUnwrap(
            parser.parseSessionMeta(Data(data[data.startIndex..<newlineIndex])))
        XCTAssertNil(resolved.forkMarkerAt)
        XCTAssertFalse(try parseFile("codex_local_desktop").isEmpty)
    }

    /// A marker whose `session_meta` timestamp does not parse yields no anchor — and no anchor
    /// means no drops, never "drop everything" (the lenient posture: an unexpected shape must
    /// not cost the file its events, REV-63's `source` lesson applied to the window).
    func testForkMarkerWithoutParseableTimestampDropsNothing() {
        let meta = #"{"type":"session_meta","timestamp":"not-a-date","payload":"# +
            #"{"originator":"codex_cli_rs","forked_from_id":"01900000"}}"#
        let resolved = parser.parseSessionMeta(Data(meta.utf8))
        XCTAssertNotNil(resolved)
        XCTAssertNil(resolved?.forkMarkerAt)
    }

    /// The fork drop runs before the cumulative carry on purpose: the inherited block carries
    /// the parent's ladder, and a first genuine turn *continuing* that ladder must be judged
    /// against the carry the genuine stream builds, not the replayed history's high-water mark.
    /// Here the genuine turn's cumulative (20) is far below the inherited block's (1000) — if
    /// the inherited events advanced the carry, the genuine turn would be eaten as a
    /// "re-emission".
    func testInheritedBlockDoesNotPoisonCumulativeCarry() {
        let blob = [
            cumulativeTokenLine(last: 1000, cumulative: 1000, at: "2026-08-01T10:00:00.003Z"),
            cumulativeTokenLine(last: 20, cumulative: 20, at: "2026-08-01T10:00:15.000Z"),
        ].joined(separator: "\n")
        let batch = parser.parseTokenEvents(
            Data(blob.utf8), sessionId: "s", surfaceBucket: "CLI", originator: "codex_cli_rs",
            forkMarkerAt: ISO8601DateFormatter().date(from: "2026-08-01T10:00:00Z")
        )
        XCTAssertEqual(batch.events.count, 1)
        XCTAssertEqual(batch.events[0].inputTokens, 20)
        XCTAssertEqual(batch.lastCumulativeTotal, 20,
                       "the dropped inherited block must not become the carry")
    }
}
