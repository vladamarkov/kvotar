import XCTest
@testable import KvotarCore

/// The only test in the suite that opens **the file the app actually ships**
/// (`Resources/pricing.json`, copied into `Kvotar.app/Contents/Resources` by `project.yml`).
///
/// Before STEP_91 no test read it: every pricing test built its own `PricingTable` fixture, so the
/// shipped file could have been empty, truncated, or carrying a two-times-wrong rate and the whole
/// suite would still have passed — which is exactly how `gpt-5.5` sat at a rate belonging to no
/// OpenAI model for five weeks. This is also the only mechanism by which a change to the rate table
/// can satisfy the project's verified-failing-pre-fix rule (REV-62 §5.3).
///
/// Ungated, unlike `LiveDiagnostics`: it reads a checked-in file, not the live machine.
final class ShippedPricingTableTests: XCTestCase {

    /// The repo-root `Resources/` directory — `pricing.json` is bundled into the **app target**,
    /// not the `KvotarCore` package, so there is no `Bundle.module` to reach it through.
    private func shippedTable() throws -> PricingTable {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }  // …/KvotarCoreTests/Tests/KvotarCore/Packages/<repo root>
        let file = url.appendingPathComponent("Resources/pricing.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "Resources/pricing.json is missing at \(file.path)")
        return try JSONDecoder().decode(PricingTable.self, from: try Data(contentsOf: file))
    }

    func testShippedTableDecodes() throws {
        let table = try shippedTable()
        XCTAssertFalse(table.models.isEmpty, "the shipped table has no model rows")
        XCTAssertNotNil(table.fallback["claude"], "no Claude provider fallback")
        XCTAssertNotNil(table.fallback["codex"], "no Codex provider fallback")
    }

    func testEveryShippedRateIsNonNegative() throws {
        let table = try shippedTable()
        for (name, row) in table.models.merging(table.fallback, uniquingKeysWith: { a, _ in a }) {
            for (field, rate) in ["input": row.inputPerMtok, "output": row.outputPerMtok,
                                  "cache_creation": row.cacheCreationPerMtok,
                                  "cache_write_5m": row.cacheWrite5mPerMtok,
                                  "cache_write_1h": row.cacheWrite1hPerMtok,
                                  "cache_read": row.cacheReadPerMtok] {
                if let rate {
                    XCTAssertGreaterThanOrEqual(rate, 0, "\(name).\(field) is negative")
                }
            }
        }
    }

    /// An all-null row would read as "free" and, worse, would reclassify active local work as
    /// off-machine: `AttributionEngine.localValuePerMin` feeds `MonthlyAttributionEstimator` as a
    /// boolean `> 0` idle discriminator, so a model priced at nothing looks like an idle machine
    /// (REV-62 §4.6).
    func testNoShippedRowIsEntirelyNull() throws {
        let table = try shippedTable()
        for (name, row) in table.models.merging(table.fallback, uniquingKeysWith: { a, _ in a }) {
            let rates = [row.inputPerMtok, row.outputPerMtok,
                         row.cacheCreationPerMtok, row.cacheWrite5mPerMtok,
                         row.cacheWrite1hPerMtok, row.cacheReadPerMtok].compactMap { $0 }
            XCTAssertFalse(rates.allSatisfy { $0 == 0 } || rates.isEmpty,
                           "\(name) has no non-zero rate — it would price real work at $0")
        }
    }

    /// OpenAI publishes **one** cached-input rate and **no** cache-write charge at all. Kvotar's
    /// two cache columns hold that single quantity under two storage conventions (Baseline §8.4),
    /// so the two rates must be equal or half the stored corpus prices at the wrong one.
    func testCodexRowsCarryOneCachedRateInBothColumns() throws {
        let table = try shippedTable()
        let codexRows = table.models.filter { $0.value.provider == "codex" }
        XCTAssertFalse(codexRows.isEmpty, "no Codex rows in the shipped table")
        for (name, row) in codexRows {
            let write = try XCTUnwrap(row.cacheCreationPerMtok, "\(name) has no cache-creation rate")
            let read = try XCTUnwrap(row.cacheReadPerMtok, "\(name) has no cache-read rate")
            XCTAssertEqual(write, read, accuracy: 0.000_001,
                           "\(name): the two Codex cache rates differ; one convention would misprice")
        }
        let fallback = try XCTUnwrap(table.fallback["codex"])
        XCTAssertEqual(try XCTUnwrap(fallback.cacheCreationPerMtok),
                       try XCTUnwrap(fallback.cacheReadPerMtok), accuracy: 0.000_001)
    }

    /// Anthropic charges 1.25× input for a 5-minute cache write and 2× for a 1-hour one, and both
    /// tiers must be present on every Claude row: a missing 1-hour rate silently reverts that model
    /// to the flat pricing this step replaced, which understated 84.3% of writes (REV-62 §4.4).
    /// The multiples are asserted against each row's **own** input rate, so a future rate change
    /// cannot leave the write rates behind.
    func testClaudeRowsCarryBothCacheWriteTiersAtTheirPublishedMultiples() throws {
        let table = try shippedTable()
        let claudeRows = table.models.filter { $0.value.provider == "claude" }
        XCTAssertFalse(claudeRows.isEmpty, "no Claude rows in the shipped table")
        for (name, row) in claudeRows {
            let input = try XCTUnwrap(row.inputPerMtok, "\(name) has no input rate")
            let write5m = try XCTUnwrap(row.cacheWrite5mPerMtok, "\(name) has no 5-minute write rate")
            let write1h = try XCTUnwrap(row.cacheWrite1hPerMtok, "\(name) has no 1-hour write rate")
            XCTAssertEqual(write5m, input * 1.25, accuracy: 0.000_001,
                           "\(name): 5-minute cache write is not 1.25× input")
            XCTAssertEqual(write1h, input * 2.00, accuracy: 0.000_001,
                           "\(name): 1-hour cache write is not 2× input")
            XCTAssertNil(row.cacheCreationPerMtok,
                         "\(name): the untiered field must be gone — two fields holding the same "
                         + "rate drift apart, and its name does not say which tier it prices")
        }
        let fallback = try XCTUnwrap(table.fallback["claude"])
        let fallbackInput = try XCTUnwrap(fallback.inputPerMtok)
        XCTAssertEqual(try XCTUnwrap(fallback.cacheWrite5mPerMtok), fallbackInput * 1.25,
                       accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(fallback.cacheWrite1hPerMtok), fallbackInput * 2.00,
                       accuracy: 0.000_001)
    }

    /// OpenAI publishes no cache-write charge at all, so a Codex row carrying a write tier would be
    /// an invented price. Its `cache_creation_per_mtok` is the cached-input rate, not a write.
    func testCodexRowsCarryNoCacheWriteTier() throws {
        let table = try shippedTable()
        for (name, row) in table.models.filter({ $0.value.provider == "codex" }) {
            XCTAssertNil(row.cacheWrite5mPerMtok, "\(name) invents a 5-minute cache-write price")
            XCTAssertNil(row.cacheWrite1hPerMtok, "\(name) invents a 1-hour cache-write price")
        }
        let fallback = try XCTUnwrap(table.fallback["codex"])
        XCTAssertNil(fallback.cacheWrite5mPerMtok)
        XCTAssertNil(fallback.cacheWrite1hPerMtok)
    }

    /// Cached input must be strictly cheaper than uncached input on every Codex row — the whole
    /// point of splitting the input term (Baseline §12).
    func testCodexCachedRateIsBelowInputRate() throws {
        let table = try shippedTable()
        for (name, row) in table.models.filter({ $0.value.provider == "codex" }) {
            let input = try XCTUnwrap(row.inputPerMtok, "\(name) has no input rate")
            let cached = try XCTUnwrap(row.cacheCreationPerMtok, "\(name) has no cached rate")
            XCTAssertLessThan(cached, input, "\(name): cached input is not cheaper than uncached")
        }
    }

    /// `updated` is the table's age, and the age is the only defence against a rate that changed
    /// silently — no provider publishes an effective date (REV-62 §5.3). STEP_92 turns this into a
    /// staleness assertion; here it only has to be a real date.
    func testUpdatedParsesAsADate() throws {
        let table = try shippedTable()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        XCTAssertNotNil(formatter.date(from: table.updated),
                        "pricing.json `updated` (\(table.updated)) is not a yyyy-MM-dd date")
        XCTAssertFalse(table.version.isEmpty)
    }

    /// The staleness assertion itself (REV-62 §5.3 mechanism 3 / STEP_92): the suite fails when
    /// the shipped table is more than 90 days old. This is deliberate breakage on a schedule —
    /// neither provider publishes an effective date, so a silently changed rate is undetectable
    /// from its own source, and the only honest mitigation is to force a human re-check. The
    /// Sonnet 5 rate sat five weeks stale with a 2× error rendering daily because nothing did this.
    /// When this fails: re-verify every rate against the providers' published pages, then bump
    /// `updated` (and `version` if a rate moved) in `Resources/pricing.json`.
    func testShippedTableIsNotStale() throws {
        let table = try shippedTable()
        let age = try XCTUnwrap(table.ageInDays(),
                                "pricing.json `updated` (\(table.updated)) did not parse")
        XCTAssertGreaterThanOrEqual(age, 0, "pricing.json `updated` is in the future")
        XCTAssertLessThanOrEqual(
            age, PricingTable.stalenessLimitDays,
            """
            Resources/pricing.json is \(age) days old (limit \(PricingTable.stalenessLimitDays)). \
            Re-verify every rate against the providers' published pricing pages and bump `updated`.
            """)
    }

    /// The 89/91-day boundary, pinned with fixtures on a fixed clock (STEP_92 DoD).
    func testStalenessBoundary() {
        let table = PricingTable(version: "t", updated: "2026-01-01", models: [:], fallback: [:])
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let stamp = utc.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let at89 = utc.date(byAdding: .day, value: 89, to: stamp)!
        let at91 = utc.date(byAdding: .day, value: 91, to: stamp)!
        XCTAssertLessThanOrEqual(table.ageInDays(asOf: at89)!, PricingTable.stalenessLimitDays,
                                 "89 days must pass the staleness limit")
        XCTAssertGreaterThan(table.ageInDays(asOf: at91)!, PricingTable.stalenessLimitDays,
                             "91 days must fail the staleness limit")
    }

    /// A malformed `updated` must read as unparseable, never as age zero — age zero would make a
    /// corrupt stamp immortally fresh.
    func testUnparseableUpdatedReturnsNil() {
        for bad in ["yesterday", "2026-13-40", "2026/01/01", ""] {
            let table = PricingTable(version: "t", updated: bad, models: [:], fallback: [:])
            XCTAssertNil(table.ageInDays(), "'\(bad)' should not parse")
        }
    }

    /// The models this machine actually runs must resolve **exactly**, not through the fallback.
    /// Every one of these was a live miss before STEP_91 (Opus 5: 188 warnings in one hour;
    /// Haiku: 48) or a wrong rate (`gpt-5.5` at gpt-5.4's numbers).
    func testModelsObservedOnThisMachineHaveExactRows() throws {
        let table = try shippedTable()
        for model in ["claude-opus-5", "claude-opus-4-8", "claude-fable-5", "claude-fable-5-1",
                      "claude-sonnet-5", "claude-sonnet-4-6", "claude-haiku-4-5-20251001",
                      "claude-haiku-4-5", "claude-opus-5-5",
                      "gpt-5.5", "gpt-5.4", "gpt-5.3-codex",
                      "gpt-5.6-sol", "gpt-5.6-terra", "gpt-6-astra"] {
            XCTAssertNotNil(table.models[model], "\(model) has no exact pricing row")
        }
    }

    /// **Cache reads are 0.1× input on every Claude model except three.** Anthropic prices hits and
    /// refreshes on Claude Fable 5.1 and Claude Mythos 5.1 at **0.025×** — a quarter of what the
    /// same tier costs on Claude Fable 5, which stays at $1.00. Nothing else in the suite looks at
    /// a Claude cache-read rate, so before this test a maintainer re-deriving the row from the
    /// usual multiple would have written $1.00 and nothing would have objected: on the dogfood
    /// corpus `claude-fable-5-1` carries 115.7M cache-read tokens in 30 days, so that slip prices
    /// $28.93 of reads at $115.73. The exception is asserted by name, and the rule is asserted for
    /// everyone else, so a future model inherits whichever branch it actually belongs in.
    /// Claude Opus 5.5 is the third exception, at **0.05×** ($0.20 on a $4.00 input).
    func testClaudeCacheReadsAreATenthOfInputExceptOnFable51Mythos51AndOpus55() throws {
        let table = try shippedTable()
        let quarterPercentModels: Set<String> = ["claude-fable-5-1", "claude-mythos-5-1"]
        let halfTenthModels: Set<String> = ["claude-opus-5-5"]

        for name in quarterPercentModels {
            let row = try XCTUnwrap(table.models[name], "\(name) has no pricing row")
            let input = try XCTUnwrap(row.inputPerMtok)
            XCTAssertEqual(try XCTUnwrap(row.cacheReadPerMtok), input * 0.025, accuracy: 0.000_001,
                           "\(name): cache reads are 0.025× input, not the usual 0.1×")
        }

        for name in halfTenthModels {
            let row = try XCTUnwrap(table.models[name], "\(name) has no pricing row")
            let input = try XCTUnwrap(row.inputPerMtok)
            XCTAssertEqual(try XCTUnwrap(row.cacheReadPerMtok), input * 0.05, accuracy: 0.000_001,
                           "\(name): cache reads are 0.05× input, not the usual 0.1×")
        }

        for (name, row) in table.models where row.provider == "claude"
            && !quarterPercentModels.contains(name) && !halfTenthModels.contains(name) {
            let input = try XCTUnwrap(row.inputPerMtok, "\(name) has no input rate")
            XCTAssertEqual(try XCTUnwrap(row.cacheReadPerMtok), input * 0.1, accuracy: 0.000_001,
                           "\(name): cache reads are 0.1× input on every model but Fable/Mythos 5.1 "
                           + "and Opus 5.5")
        }

        let fallback = try XCTUnwrap(table.fallback["claude"])
        XCTAssertEqual(try XCTUnwrap(fallback.cacheReadPerMtok),
                       try XCTUnwrap(fallback.inputPerMtok) * 0.1, accuracy: 0.000_001)
    }

    /// **`gpt-5.6-sol` is priced at a promotion that expires.** $4.00 / $0.40 / $20.00 has been
    /// OpenAI's published rate since 2026-08-21 and is guaranteed only through **2026-11-21**;
    /// what follows is unannounced, and secondary sources put the list price at $5 / $30. Sol is
    /// the heaviest model in this corpus (409M input tokens in 30 days), so a lapse quietly
    /// underprices the biggest row on the Codex tab. The table's own staleness assertion is no
    /// help here: a 2026-09-08 stamp does not go stale until 2026-12-07, sixteen days after the
    /// guarantee ends. This fails on the day the guarantee does.
    ///
    /// When this fails: re-check gpt-5.6-sol on OpenAI's pricing page, correct the row if it
    /// moved, and move `solPromotionalRateGuaranteedThrough` to the next guaranteed date (or
    /// delete this test if the rate has become permanent).
    func testSolPromotionalRateIsStillWithinItsGuaranteedWindow() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let guaranteedThrough = utc.date(from: DateComponents(year: 2026, month: 11, day: 21))!

        XCTAssertLessThanOrEqual(
            Date(), guaranteedThrough,
            """
            gpt-5.6-sol's promotional rate ($4.00 in / $0.40 cached / $20.00 out) was guaranteed \
            only through 2026-11-21. Re-verify it on OpenAI's pricing page, correct \
            Resources/pricing.json if it moved, and re-stamp `updated`.
            """)

        // The row this is guarding, so a rate edit without a date edit cannot pass unnoticed.
        let row = try XCTUnwrap(try shippedTable().models["gpt-5.6-sol"])
        XCTAssertEqual(try XCTUnwrap(row.inputPerMtok), 4.00, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(row.cacheCreationPerMtok), 0.40, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(row.outputPerMtok), 20.00, accuracy: 0.000_001)
    }
}
