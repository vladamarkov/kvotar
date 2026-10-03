import XCTest
import KvotarCore
@testable import KvotarUI

/// The explanation registry (UI Spec Part 3 §5.2 — REV-67/D-72, STEP_111; v2 copy and the seven
/// Enterprise monthly elements, REV-75/D-87 + D-89, STEP_128). The copy must be the spec's **byte
/// for byte**: the §5.2 table travels with the tests as `Fixtures/explanation_registry.md`
/// (STEP_237), every cell is compared to the registry, and where the private UI Spec exists
/// `testFixtureMatchesTheUISpec` holds the fixture to it.
final class ExplanationRegistryTests: XCTestCase {

    // MARK: Spec table as fixture

    private static let fixtureURL = Bundle.module.url(
        forResource: "explanation_registry", withExtension: "md", subdirectory: "Fixtures")

    /// The fixture's `| **E-` lines, in order — nil when the file is missing or unreadable.
    private static let fixtureLines: [Substring]? = {
        guard let url = fixtureURL,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").filter { $0.hasPrefix("| **E-") }
    }()

    /// The §5.2 registry rows, keyed by `E-nn` → (claude cell, codex cell), parsed from the fixture.
    private static let specRows: [String: (claude: String, codex: String)]? = {
        guard let lines = fixtureLines else { return nil }
        var rows: [String: (String, String)] = [:]
        for line in lines {
            // `| **E-01** | element | claude | codex |` — cells separated by ` | `; the element
            // cell may itself contain `·` and backticks but never ` | `.
            let cells = line.dropFirst(2).dropLast(2).components(separatedBy: " | ")
            guard cells.count == 4 else { continue }
            let id = cells[0].replacingOccurrences(of: "*", with: "")
            rows[id] = (cells[2], cells[3])
        }
        return rows.isEmpty ? nil : rows
    }()

    private struct FixtureMissing: Error {}

    /// A missing or empty fixture **fails** — it never skips, because the public repository has
    /// no other copy of this contract.
    private func spec() throws -> [String: (claude: String, codex: String)] {
        guard let rows = Self.specRows else {
            XCTFail("copy-contract fixture missing or empty: "
                    + "Packages/KvotarUI/Tests/KvotarUITests/Fixtures/explanation_registry.md")
            throw FixtureMissing()
        }
        return rows
    }

    // MARK: Drift guard (private repository only)

    /// The fixture is the spec's §5.2 rows, same lines, same order, same bytes. Runs only where
    /// the private-repository marker `.kvotar-private` sits at the repository root; there a
    /// missing UI Spec fails rather than skips.
    func testFixtureMatchesTheUISpec() throws {
        // …/Packages/KvotarUI/Tests/KvotarUITests/<file> → repo root is five levels up.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".kvotar-private").path)
        else {
            throw XCTSkip("private UI Spec absent — the fixture is the public copy contract")
        }
        let docs = root.appendingPathComponent("docs")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: docs.path)) ?? []
        // `Kvotar_UI_Spec_v5_10.md` → [5, 10]; the newest version wins, compared numerically.
        let version: (String) -> [Int] = { name in
            name.dropFirst("Kvotar_UI_Spec_v".count).dropLast(".md".count)
                .split(separator: "_").compactMap { Int($0) }
        }
        let specs = names.filter { $0.hasPrefix("Kvotar_UI_Spec_v") && $0.hasSuffix(".md") }
        guard let newest = specs.max(by: { version($0).lexicographicallyPrecedes(version($1)) }),
              let text = try? String(contentsOf: docs.appendingPathComponent(newest), encoding: .utf8)
        else {
            XCTFail(".kvotar-private is present but no docs/Kvotar_UI_Spec_v*.md was found")
            return
        }
        let specLines = text.split(separator: "\n").filter { $0.hasPrefix("| **E-") }
        let fixture = try XCTUnwrap(Self.fixtureLines, "copy-contract fixture missing")
        XCTAssertEqual(fixture, specLines,
                       "Fixtures/explanation_registry.md drifted from \(newest) §5.2 — "
                       + "re-extract the fixture from the spec")
    }

    /// The registry's rendering of a spec cell: the concept card, or for the state-aware E-09
    /// the full glossary, or for the Codex E-01 the template with its `[Width]` intact.
    private func registryCell(_ element: ExplanationElement, tool: Tool) -> String {
        switch (element, tool) {
        case (.sourceTag, _): return ExplanationRegistry.sourceTagGlossary(tool: tool)
        // The three Codex cells carrying a grain placeholder compare as templates (the spec cell
        // *is* the template — `[Width]` on E-01, `[grain]` on E-02 and E-14).
        case (.primaryWindow, .codex): return ExplanationRegistry.codexPrimaryWindowTemplate
        case (.secondaryWindow, .codex): return ExplanationRegistry.codexSecondaryWindowTemplate
        case (.weeklyReset, .codex): return ExplanationRegistry.codexWeeklyResetTemplate
        default: return ExplanationRegistry.card(element, tool: tool) ?? "—"
        }
    }

    /// The *fixed* rows only — an ID with a `·` is a live/family template (STEP_130, now landed),
    /// counted by `liveRows` below and deliberately outside this count. There are 22 elements and **21** fixed rows:
    /// E-08's card changes with the verdict family, so it has no generic cell (REV-75/D-90).
    private func fixedRows(_ rows: [String: (claude: String, codex: String)])
        -> [String: (claude: String, codex: String)] {
        rows.filter { !$0.key.contains("·") }
    }

    func testSpecTableHasTwentyThreeFixedRowsAndTheIDsMatch() throws {
        let rows = fixedRows(try spec())
        XCTAssertEqual(rows.count, 23)
        XCTAssertEqual(Set(rows.keys),
                       Set(ExplanationElement.allCases.map(\.specID)).subtracting(["E-08"]))
    }

    /// E-08 is the one element with no fixed cell — its per-family cards land in STEP_130, and
    /// until then the verdict's detail line is inert rather than carrying the retired v1 card.
    func testVerdictDetailHasNoFixedRowAndNoCard() throws {
        let rows = try spec()
        XCTAssertNil(fixedRows(rows)["E-08"])
        XCTAssertNil(ExplanationRegistry.card(.verdictDetail, tool: .claude))
        XCTAssertNil(ExplanationRegistry.card(.verdictDetail, tool: .codex))
    }

    func testEveryClaudeCellIsByteForByte() throws {
        let rows = try spec()
        for element in ExplanationElement.allCases where element != .verdictDetail {
            XCTAssertEqual(registryCell(element, tool: .claude), rows[element.specID]?.claude,
                           "\(element.specID) Claude cell drifted from the spec")
        }
    }

    func testEveryCodexCellIsByteForByte() throws {
        let rows = try spec()
        for element in ExplanationElement.allCases where element != .verdictDetail {
            XCTAssertEqual(registryCell(element, tool: .codex), rows[element.specID]?.codex,
                           "\(element.specID) Codex cell drifted from the spec")
        }
    }

    // MARK: Rules

    /// §5.2 rule 5: ≤ 45 words body — every cell, both columns (the bold lead counts; the E-09
    /// glossary is the full cell, the rendered card is always a subset).
    func testEveryBodyIsAtMost45Words() {
        for element in ExplanationElement.allCases {
            for tool in [Tool.claude, .codex] {
                let body = registryCell(element, tool: tool)
                guard body != "—" else { continue }
                let words = body.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
                XCTAssertLessThanOrEqual(words, 45, "\(element.specID) \(tool): \(words) words")
            }
        }
    }

    /// Baseline §10 / §5.1: no polling mechanics anywhere in the layer.
    func testNoCardExposesPollingMechanics() {
        for element in ExplanationElement.allCases {
            for tool in [Tool.claude, .codex] {
                let word = UserCopyRules.pollingWord(in: registryCell(element, tool: tool))
                XCTAssertNil(word, "\(element.specID) \(tool) says '\(word ?? "")'")
            }
        }
    }

    func testHeaderFactCardsCarryTheActualPeriodAndApprovedLimitations() {
        let burn = ExplanationRegistry.burnFactCard(tool: .codex, period: "5-hour",
                                                    monthly: false)
        XCTAssertTrue(burn.contains("5-hour quota"))
        XCTAssertTrue(burn.contains("derived from changes in the account meter"))
        XCTAssertTrue(burn.contains("bounded rather than shown as zero"))

        let gap = ExplanationRegistry.notSeenLocallyFactCard(period: "5-hour")
        XCTAssertTrue(gap.contains("during this 5-hour period"))
        XCTAssertTrue(gap.contains("other apps on this Mac, other devices"))
        XCTAssertTrue(gap.contains("missing or delayed data"))
        XCTAssertTrue(gap.contains("does not necessarily mean another device was used"))
    }

    /// §5.2 rule 7 (D-87): the app has no first person. "we" would spread from one card.
    func testNoCardSpeaksAsWe() {
        for element in ExplanationElement.allCases {
            for tool in [Tool.claude, .codex] {
                let body = registryCell(element, tool: tool).lowercased()
                XCTAssertFalse(body.contains("we "), "\(element.specID) \(tool) says 'we'")
            }
        }
    }

    func testUsageCreditsIsInertOnCodex() {
        XCTAssertNil(ExplanationRegistry.card(.usageCredits, tool: .codex))
        XCTAssertNotNil(ExplanationRegistry.card(.usageCredits, tool: .claude))
    }

    /// E-22 has a card on both tools since STEP_176 (REV-92): Codex's model windows render in
    /// `OTHER LIMITS` and can be the hero, so the row must explain itself there too. The two
    /// cells differ on purpose — Claude's scoped limit is weekly by construction, Codex's has
    /// windows of its own.
    func testScopedLimitHasACardOnBothTools() {
        XCTAssertNotNil(ExplanationRegistry.card(.scopedLimit, tool: .codex))
        XCTAssertNotNil(ExplanationRegistry.card(.scopedLimit, tool: .claude))
        XCTAssertNotEqual(ExplanationRegistry.card(.scopedLimit, tool: .codex),
                          ExplanationRegistry.card(.scopedLimit, tool: .claude))
    }

    func testCodexPrimaryWindowFillsTheWidthPlaceholder() {
        XCTAssertTrue(ExplanationRegistry.card(.primaryWindow, tool: .codex, grain: "Weekly")!
            .hasPrefix("**Weekly window.**"))
        XCTAssertTrue(ExplanationRegistry.card(.primaryWindow, tool: .codex, grain: "Monthly")!
            .hasPrefix("**Monthly window.**"))
        // No reported width → the five-hour default, never a literal placeholder.
        let fallback = ExplanationRegistry.card(.primaryWindow, tool: .codex)!
        XCTAssertTrue(fallback.hasPrefix("**5-hour window.**"))
        XCTAssertFalse(fallback.contains("[Width]"))
        // Claude's is fixed copy; the grain is ignored.
        XCTAssertTrue(ExplanationRegistry.card(.primaryWindow, tool: .claude, grain: "Weekly")!
            .hasPrefix("**5-hour window.**"))
    }

    /// The other two Codex grain cells fill from the same word and never leak a placeholder.
    func testCodexSecondaryAndWeeklyResetFillTheGrainPlaceholder() {
        let weekly = ExplanationRegistry.card(.secondaryWindow, tool: .codex, grain: "Weekly")!
        XCTAssertTrue(weekly.contains("on top of the Weekly one"))
        XCTAssertFalse(weekly.contains("[grain]"))
        let reset = ExplanationRegistry.card(.weeklyReset, tool: .codex, grain: "Monthly")!
        XCTAssertTrue(reset.contains("The Monthly window has its own"))
        XCTAssertFalse(reset.contains("[grain]"))
        // No reported width → the five-hour default, matching E-01.
        XCTAssertTrue(ExplanationRegistry.card(.secondaryWindow, tool: .codex)!
            .contains("on top of the 5-hour one"))
        XCTAssertTrue(ExplanationRegistry.card(.weeklyReset, tool: .codex)!
            .contains("The 5-hour window has its own"))
        // Claude's are fixed copy; the grain is ignored.
        XCTAssertTrue(ExplanationRegistry.card(.secondaryWindow, tool: .claude, grain: "Monthly")!
            .contains("on top of the 5-hour one"))
    }

    // MARK: E-09 — the state-aware source-tag card (rule 4)

    func testSourceTagCardExactOnly() {
        let tag = SourceTag(base: "Source: Claude account · exact", age: "12s ago")
        XCTAssertEqual(ExplanationRegistry.sourceTagCard(tool: .claude, tag: tag, freeze: nil),
                       "**exact:** straight from your account.")
    }

    func testSourceTagCardBurnTotalNamesBothTerms() {
        let tag = SourceTag(base: "Total: OAuth delta (exact) · est. from JSONL", age: "40s ago")
        XCTAssertEqual(ExplanationRegistry.sourceTagCard(tool: .claude, tag: tag, freeze: nil),
                       "**exact:** straight from your account. "
                       + "**est.:** estimated from Claude Code's session logs on this Mac.")
        // The `est.` sentence names the tool whose logs it means (STEP_128) — one segment, two columns.
        let codexTag = SourceTag(base: "Total: app-server RPC delta (exact) · est. from JSONL")
        XCTAssertEqual(ExplanationRegistry.sourceTagCard(tool: .codex, tag: codexTag, freeze: nil),
                       "**exact:** straight from your account. "
                       + "**est.:** estimated from Codex's session logs on this Mac.")
    }

    func testSourceTagCardAsOfFillsTheTime() {
        let tag = SourceTag(base: "Source: Claude account · as of 11:32 pm")
        XCTAssertEqual(ExplanationRegistry.sourceTagCard(tool: .claude, tag: tag, freeze: nil),
                       "**as of 11:32 pm:** the last good reading — nothing fresher was available.")
        // A dated stamp carries through whole.
        let dated = SourceTag(base: "Source: ChatGPT account · as of Jul 5, 11:32 pm")
        XCTAssertTrue(ExplanationRegistry.sourceTagCard(tool: .codex, tag: dated, freeze: nil)!
            .hasPrefix("**as of Jul 5, 11:32 pm:**"))
    }

    func testSourceTagCardFreezeReasonsInTheVerdictsWords() {
        let tag = SourceTag(base: "Source: Claude account · as of 11:32 pm")
        XCTAssertEqual(ExplanationRegistry.sourceTagCard(tool: .claude, tag: tag, freeze: .reconnecting),
                       "**as of 11:32 pm:** the last good reading — nothing fresher was available. "
                       + "*Reconnecting…* — the account isn't answering right now.")
        XCTAssertEqual(ExplanationRegistry.sourceTagCard(tool: .claude, tag: tag, freeze: .signInExpired),
                       "**as of 11:32 pm:** the last good reading — nothing fresher was available. "
                       + "*sign-in expired* — open Claude Code to sign in again.")
        let codexTag = SourceTag(base: "Source: app-server RPC · as of 11:32 pm")
        XCTAssertEqual(ExplanationRegistry.sourceTagCard(tool: .codex, tag: codexTag, freeze: .reconnecting),
                       "**as of 11:32 pm:** the last good reading — nothing fresher was available. "
                       + "*Reconnecting…* — the account isn't answering right now.")
        // The Codex cell names one reason only — a credential freeze says nothing there.
        XCTAssertEqual(ExplanationRegistry.sourceTagCard(tool: .codex, tag: codexTag, freeze: .signInExpired),
                       "**as of 11:32 pm:** the last good reading — nothing fresher was available.")
    }

    func testSourceTagCardIsInertWithoutItsTerms() {
        XCTAssertNil(ExplanationRegistry.sourceTagCard(
            tool: .claude, tag: SourceTag(base: "Source: Claude Code JSONL", age: "3m ago"), freeze: nil))
        XCTAssertNil(ExplanationRegistry.sourceTagCard(
            tool: .codex, tag: SourceTag(base: HistoryDisplay.pricingNote), freeze: nil))
        // A freeze is about the account; a tag that makes no account claim stays inert under it.
        XCTAssertNil(ExplanationRegistry.sourceTagCard(
            tool: .claude, tag: SourceTag(base: "Source: Claude Code JSONL"), freeze: .reconnecting))
    }

    // MARK: Live rows (rule 4 as amended — REV-75/D-88 + D-90, STEP_130)

    /// The *live* rows only — an ID carrying a `·`, split into its element and its variant. A row
    /// naming an unknown element or an unknown variant fails here rather than being skipped: an
    /// unparsed row would silently exempt itself from every check below.
    private func liveRows(_ rows: [String: (claude: String, codex: String)])
        -> [(element: ExplanationElement, variant: LiveVariant, id: String,
             claude: String, codex: String)] {
        var out: [(ExplanationElement, LiveVariant, String, String, String)] = []
        for (id, cells) in rows.sorted(by: { $0.key < $1.key }) where id.contains("·") {
            let parts = id.components(separatedBy: "·")
            guard parts.count == 2,
                  let element = ExplanationElement.allCases.first(where: { $0.specID == parts[0] }),
                  let variant = LiveVariant(rawValue: parts[1]) else {
                XCTFail("§5.2 row \(id) names no known element/variant pair")
                continue
            }
            out.append((element, variant, id, cells.claude, cells.codex))
        }
        return out
    }

    /// Direction 1: every live row in the spec is a template in the registry, byte for byte.
    func testLiveRowsMatchTheRegistry() throws {
        let rows = liveRows(try spec())
        XCTAssertEqual(rows.count, 24,
                       "REV-94 removed the model-hero verdict row; STEP_194 adds four tier lines; "
                       + "STEP_220 adds E-12·orgManaged")
        for row in rows {
            for (tool, cell) in [(Tool.claude, row.claude), (Tool.codex, row.codex)] {
                let template = ExplanationRegistry.liveTemplate(row.element, variant: row.variant,
                                                                tool: tool)
                XCTAssertEqual(template ?? "—", cell, "\(row.id) \(tool) drifted from the spec")
            }
        }
    }

    /// Direction 2: **no orphan template.** Every (element, variant, tool) the registry answers
    /// for has a spec row — walked over the whole product, so a template added in code without a
    /// spec row fails here.
    func testNoRegistryTemplateIsMissingFromTheSpec() throws {
        let rows = liveRows(try spec())
        let specified = Set(rows.map { "\($0.element.specID)·\($0.variant.rawValue)" })
        for element in ExplanationElement.allCases {
            for variant in LiveVariant.allCases {
                let has = [Tool.claude, .codex].contains {
                    ExplanationRegistry.liveTemplate(element, variant: variant, tool: $0) != nil
                }
                let id = "\(element.specID)·\(variant.rawValue)"
                XCTAssertEqual(has, specified.contains(id), "\(id): registry and spec disagree")
            }
        }
    }

    /// E-08's rows are whole cards (D-90), reachable through the name D-90 uses. The generic cell
    /// stays nil — `verdictDetailCard` is a slice of the one table, never a second copy.
    func testVerdictDetailCardIsTheSameTableUnderD90sName() {
        for variant in LiveVariant.allCases {
            for tool in [Tool.claude, .codex] {
                XCTAssertEqual(ExplanationRegistry.verdictDetailCard(family: variant, tool: tool),
                               ExplanationRegistry.liveTemplate(.verdictDetail, variant: variant,
                                                                tool: tool))
            }
        }
        XCTAssertTrue(ExplanationRegistry.verdictDetailCard(family: .resetsFirst, tool: .claude)!
            .hasPrefix("**Runway.**"))
        // Claude's alone: past 100% Codex simply stops, so there is no credits concept to explain.
        XCTAssertNotNil(ExplanationRegistry.verdictDetailCard(family: .onCredits, tool: .claude))
        XCTAssertNil(ExplanationRegistry.verdictDetailCard(family: .onCredits, tool: .codex))
        XCTAssertNil(ExplanationRegistry.card(.verdictDetail, tool: .claude))
    }

    /// §5.2 rule 5, the amended form: 45 words **concept + live line together**, per (element,
    /// variant, tool). E-08's rows are whole cards and count on their own.
    func testConceptPlusLiveLineIsAtMost45Words() throws {
        for row in liveRows(try spec()) {
            for (tool, cell) in [(Tool.claude, row.claude), (Tool.codex, row.codex)] {
                guard cell != "—" else { continue }
                let concept = row.element == .verdictDetail
                    ? "" : (ExplanationRegistry.card(row.element, tool: tool, grain: "Weekly") ?? "")
                let body = (concept + " " + cell).trimmingCharacters(in: .whitespaces)
                let words = body.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
                XCTAssertLessThanOrEqual(words, 45, "\(row.id) \(tool): \(words) words")
            }
        }
    }

    /// The §10 copy ban and rule 7's "never we", over the live templates too.
    func testNoLiveLineExposesPollingMechanicsOrSpeaksAsWe() throws {
        for row in liveRows(try spec()) {
            for cell in [row.claude, row.codex] where cell != "—" {
                let word = UserCopyRules.pollingWord(in: cell)
                XCTAssertNil(word, "\(row.id) says '\(word ?? "")'")
                XCTAssertFalse(cell.lowercased().contains("we "), "\(row.id) says 'we '")
            }
        }
    }

    /// The placeholder vocabulary (D-88), pinned so a typo cannot reach a card. `[Width]` belongs
    /// to the fixed Codex E-01 cell and to no live template; the union is what is checked.
    func testPlaceholderVocabularyIsClosed() throws {
        // `[left]` / `[wkLeft]` replaced `[used]` / `[wk]` / `[remaining]` in the percentage cells
        // (REV-77 / D-97); `[used]` survives in E-07·live and in the rule 8 bridge line.
        let allowed: Set<String> = ["start", "reset", "wkReset", "left", "wkLeft", "used", "grain",
                                    "runway", "countdown", "stops", "elapsed", "period", "pace",
                                    "total", "local", "off", "balance", "limit", "days", "Width",
                                    "diff", "line",   // the STEP_194 long-limit tier lines
                                    "t"]   // `[t]` is E-09's own, from STEP_111
        var seen: Set<String> = []
        var bodies = liveRows(try spec()).flatMap { [$0.claude, $0.codex] }
        bodies += [ExplanationRegistry.codexPrimaryWindowTemplate,
                   ExplanationRegistry.codexSecondaryWindowTemplate,
                   ExplanationRegistry.codexWeeklyResetTemplate,
                   ExplanationRegistry.sourceTagGlossary(tool: .claude),
                   ExplanationRegistry.bridgeTemplate]
        for body in bodies {
            let ns = body as NSString
            let re = try NSRegularExpression(pattern: "\\[([A-Za-z]+)\\]")
            for match in re.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
                seen.insert(ns.substring(with: match.range(at: 1)))
            }
        }
        XCTAssertTrue(seen.subtracting(allowed).isEmpty,
                      "unknown placeholders: \(seen.subtracting(allowed).sorted())")
        // And the vocabulary is not carrying names nothing uses any more.
        XCTAssertTrue(allowed.subtracting(seen).isEmpty,
                      "unused placeholder names: \(allowed.subtracting(seen).sorted())")
    }

    // MARK: The fill rule

    func testLiveLineFillsEveryPlaceholder() {
        let line = ExplanationRegistry.liveLine(
            .primaryWindow, variant: .live, tool: .claude,
            values: ["start": "4:00 pm", "reset": "9:00 pm"], missing: .noReset)
        XCTAssertEqual(line.text, "*This one started at 4:00 pm and resets at 9:00 pm.*")
        XCTAssertFalse(line.text!.contains("["))
    }

    /// One missing value drops the **whole** line — never a half-filled sentence (rule 4).
    func testLiveLineDropsOnAnyMissingValue() {
        let line = ExplanationRegistry.liveLine(
            .primaryWindow, variant: .live, tool: .claude,
            values: ["start": "4:00 pm", "reset": nil], missing: .noReset)
        XCTAssertEqual(line, .dropped(.noReset))
        XCTAssertNil(line.text)
    }

    /// A "—" cell is not a line that failed — it is an element with no line on that tab.
    func testLiveLineDropsAsNoTemplateOnADashCell() {
        // E-01·notStarted carries both cells since REV-80 / D-101 — it is no longer the example.
        XCTAssertNotNil(ExplanationRegistry.liveLine(.primaryWindow, variant: .notStarted,
                                                     tool: .claude, missing: .noWindow).text)
        XCTAssertNotNil(ExplanationRegistry.liveLine(.primaryWindow, variant: .notStarted,
                                                     tool: .codex, missing: .noWindow).text)
        XCTAssertEqual(ExplanationRegistry.liveLine(.usageCredits, variant: .off, tool: .codex,
                                                    missing: .noBalance),
                       .dropped(.noTemplate))
    }

    // MARK: The bridge line (rule 8 — REV-77/D-97, STEP_139)

    /// The bridge line is the spec's prose rule, byte for byte, and the only place a used figure
    /// is shown: `[left]` floors at 0, `[used]` is uncapped.
    func testBridgeLineReadsLeftThenUsed() {
        XCTAssertEqual(ExplanationRegistry.bridgeTemplate, "*[left]% left · [used]% used*")
        XCTAssertEqual(ExplanationRegistry.bridgeLine(utilization: 58).text, "*42% left · 58% used*")
        XCTAssertEqual(ExplanationRegistry.bridgeLine(utilization: 0).text, "*100% left · 0% used*")
        XCTAssertEqual(ExplanationRegistry.bridgeLine(utilization: 106).text, "*0% left · 106% used*",
                       "over quota keeps the overshoot on the used side only")
        XCTAssertFalse(ExplanationRegistry.bridgeLine(utilization: 40).text!.contains("%%"))
    }

    /// No window, no line — the card shows its concept text alone (rule 4's drop rule).
    func testBridgeLineDropsWithoutAUtilization() {
        XCTAssertEqual(ExplanationRegistry.bridgeLine(utilization: nil), .dropped(.noWindow))
        XCTAssertNil(ExplanationRegistry.bridgeLine(utilization: nil).text)
    }

    func testSpecIDsAreStable() {
        XCTAssertEqual(ExplanationElement.primaryWindow.specID, "E-01")
        XCTAssertEqual(ExplanationElement.sourceTag.specID, "E-09")
        XCTAssertEqual(ExplanationElement.usageCredits.specID, "E-12")
        XCTAssertEqual(ExplanationElement.rollingHorizons.specID, "E-13")
        XCTAssertEqual(ExplanationElement.weeklyReset.specID, "E-14")
        // Appended by STEP_128 — the enum order *is* the E-number, so this pins the append.
        XCTAssertEqual(ExplanationElement.monthlyUsed.specID, "E-15")
        XCTAssertEqual(ExplanationElement.monthlyPace.specID, "E-16")
        XCTAssertEqual(ExplanationElement.monthlyReset.specID, "E-17")
        XCTAssertEqual(ExplanationElement.thisMachine.specID, "E-18")
        XCTAssertEqual(ExplanationElement.monthlyOffMachine.specID, "E-19")
        XCTAssertEqual(ExplanationElement.unattributed.specID, "E-20")
        XCTAssertEqual(ExplanationElement.spendRate.specID, "E-21")
        // The E-number STEP_134 deferred for its model-scoped weekly row.
        XCTAssertEqual(ExplanationElement.scopedLimit.specID, "E-22")
        // Appended by STEP_178 for the daily local section and its recency marker.
        XCTAssertEqual(ExplanationElement.localActivity.specID, "E-23")
        XCTAssertEqual(ExplanationElement.projectRecency.specID, "E-24")
        XCTAssertEqual(ExplanationElement.allCases.count, 24)
    }
}
