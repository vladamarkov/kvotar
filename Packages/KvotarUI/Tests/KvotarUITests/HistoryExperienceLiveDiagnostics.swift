import XCTest
import KvotarCore
@testable import KvotarUI

/// Read-only live diagnostic for the experience model (STEP_159; four modes STEP_182): builds
/// every mode/provider payload from a real database — `HistoryReportReader` →
/// `HistoryDisplay.experience` — and prints it, so the recap's weeks, the quota sections, the day
/// details and the hard-block pages can be checked against known live figures before STEP_183
/// draws the new two. Gated like `HistoryLiveDiagnostics`; point it at a **copy** of the live
/// database:
///
///     KVOTAR_LIVE=1 KVOTAR_LIVE_DB=/path/copy.db swift test --filter HistoryExperienceLiveDiagnostics
final class HistoryExperienceLiveDiagnostics: XCTestCase {

    func testLiveExperiencePayloads() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["KVOTAR_LIVE"] == "1", "set KVOTAR_LIVE=1 to run live diagnostics")
        let path = try env["KVOTAR_LIVE_DB"] ?? SQLiteStore.defaultPath()
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let bundle = try XCTUnwrap(Bundle(url: url.appendingPathComponent("Resources",
                                                                          isDirectory: true)))
        let now = env["KVOTAR_LIVE_NOW"].flatMap { Double($0) }
            .map { Date(timeIntervalSince1970: $0) } ?? Date()

        let store = try SQLiteStore(path: path)
        let engine = EstimatedValueEngine(store: store, bundle: bundle)
        await engine.loadPricingTable()
        let report = await HistoryReportReader(store: store, valueEngine: engine).report(now: now)
        let experience = HistoryDisplay.experience(report, now: now)

        print("\n════════ HistoryExperience (\(path), now=\(now)) ════════")
        print("header: \(experience.header.title) · \(experience.header.subtitle)")
        print("footer: \(experience.footer)")
        print("pricingNote: \(experience.pricingNote)")
        print("emptyMessage: \(experience.emptyMessage ?? "—")")

        // STEP_227: the weekly-limit outcomes STEP_228's recap lines will read, as folded.
        print("\n──────── Weekly limits (report, STEP_227) ────────")
        let cest = DateFormatter()
        cest.dateFormat = "yyyy-MM-dd HH:mm"
        for tool in report.tools {
            for w in tool.weeklyLimits {
                let name: String
                switch w.limit {
                case .overall: name = "overall"
                case .model(let key, let label): name = label ?? key
                }
                print("  \(tool.tool.tabLabel) \(name) · reset \(cest.string(from: w.outcome.resetsAt))"
                      + " · \(Int(w.outcome.highWaterPct))% · \(w.outcome.completion.rawValue)"
                      + " · gap \(String(format: "%.1f", w.outcome.lastReadingGap / 3600)) h"
                      + (w.outcome.hitLimitAt != nil ? " · hit limit" : "")
                      + (w.outcome.ending != .reachedReset ? " · \(w.outcome.ending.rawValue)" : ""))
            }
        }

        // STEP_228: main windows the provider ended before their schedule, as the fold attributes them.
        print("\n──────── Early endings (main window, STEP_228) ────────")
        for tool in report.tools {
            for w in tool.quotaWindows where w.ending != .reachedReset {
                print("  \(tool.tool.tabLabel) · due \(cest.string(from: w.resetsAt))"
                      + " · ended \(cest.string(from: w.endedAt)) · \(Int(w.highWaterPct))%"
                      + " · \(w.ending.rawValue) · gap \(Int(w.lastReadingGap)) s")
            }
        }

        print("\n──────── Weekly recap (cross-provider) ────────")
        print("empty: \(experience.recap.emptyMessage ?? "—")")
        for week in experience.recap.weeks {
            print("\n  [\(week.title)] \(week.span)\(week.isLatest ? "  ← latest" : "")")
            print("    lead(\(week.lead.kind.rawValue)) \(week.lead.eyebrow): \(week.lead.sentence)")
            if let g = week.lead.grounding { print("      grounding: \(g)") }
            if let c = week.coverageNote { print("      coverage: \(c)") }
            if let table = week.table {
                print("    \(table.title): \(table.columns.map(\.tabLabel).joined(separator: " | "))")
                for row in table.rows {
                    let cells = row.cells.map { $0.text + ($0.comparison.map { " (\($0))" } ?? "") }
                    print("      \(row.label): \(cells.joined(separator: " | "))")
                }
                print("      \(table.valueNote)")
                if let f = table.fallbackNote { print("      \(f)") }
            }
            if let limits = week.weeklyLimits {
                print("    \(limits.title)")
                for line in limits.lines { print("      \(line.label)   \(line.value)") }
                for note in limits.footnotes { print("      \(note)") }
            }
            for insight in week.observations {
                print("    · \(insight.provider.map { "[\($0.tabLabel)] " } ?? "")\(insight.sentence)")
                if let note = insight.coverageNote { print("        coverage: \(note)") }
                if let link = insight.link {
                    print("        → \(link.label) [\(link.destination.mode.label)"
                          + " · \(link.destination.banner ?? "—")]")
                }
            }
            if let action = week.action {
                print("    \(action.title): \(action.sentence)")
                if let e = action.evidence { print("      evidence: \(e)") }
            } else {
                print("    (no action — the week recorded no hard block)")
            }
        }

        for pages in experience.pages {
            print("\n──────── provider: \(pages.provider.label) ────────")

            let q = pages.quota
            print("[Explore quota] empty=\(q.emptyMessage ?? "—")")
            print("  eyebrow: \(q.eyebrow)")
            print("  scope: \(q.scopeNote)")
            for section in q.sections {
                print("  ── \(section.title)")
                print("     \(section.summary)")
                if let note = section.sparseNote { print("     \(note)") }
                let counts = Dictionary(grouping: section.points, by: \.kind)
                    .map { "\($0.key.rawValue)=\($0.value.count)" }.sorted()
                print("     points: \(section.points.count) [\(counts.joined(separator: " "))]"
                      + "  hitLimit=\(section.points.filter(\.hitLimit).count)")
                for segment in section.segments {
                    print("     segment \(segment.widthLabel ?? "unknown width")"
                          + " · \(segment.pointIDs.count) points"
                          + " · \(segment.connects ? "joined" : "separate points")"
                          + (segment.boundaryNote.map { " · after: \($0)" } ?? ""))
                }
                if let last = section.points.last {
                    print("     newest: \(last.detail.title) — \(last.label)")
                    for row in last.detail.rows { print("        \(row.label) → \(row.value)") }
                    if let link = last.detail.blockLink { print("        → \(link.label)") }
                }
            }

            let e = pages.explore
            print("[Explore usage] empty=\(e.emptyMessage ?? "—")")
            print("  days=\(e.days.count) initial=\(e.initialSelection?.description ?? "—")")
            if let initial = e.initialSelection,
               let entry = e.days.first(where: { $0.id == initial }) {
                let d = entry.detail
                print("  selected \(d.title) \(d.status ?? "")")
                for sec in d.sections {
                    print("    \(sec.provider): \(sec.tokens) · \(sec.value) · \(sec.activity)"
)
                    for m in sec.models { print("      \(m.label) → \(m.value)") }
                }
                if let combined = d.combinedValue { print("    combined: \(combined)") }
                for r in d.blocks { print("    block: \(r.row.label) → \(r.row.value)") }
                for r in d.observations { print("    observed: \(r.row.label) → \(r.row.value)") }
                for r in d.changes { print("    change: \(r.row.label) → \(r.row.value)") }
                print("    note: \(d.evidenceNote)")
            }
            for total in e.totals {
                print("  \(total.title): \(total.tokens) · \(total.activity) · \(total.value)")
            }
            if let combined = e.combinedValue { print("  combined 30-day value: \(combined)") }
            for weekly in e.weekly {
                print("  weeks · \(weekly.provider.tabLabel):")
                for row in weekly.rows {
                    print("    \(row.label)\(row.note.map { " (\($0))" } ?? "")  "
                          + "\(row.tokens) · \(row.value)  "
                          + String(format: "%.2f", row.fraction))
                }
            }
            print("  \(e.breakdown.title):")
            for row in e.breakdown.projects {
                print("    project \(row.tag.map { "[\($0)] " } ?? "")\(row.row.label) → \(row.row.value)")
            }
            for group in e.breakdown.models {
                print("    models · \(group.provider.tabLabel):")
                for row in group.rows { print("      \(row.row.label) → \(row.row.value)") }
            }
            for row in e.breakdown.largestWork {
                print("    work \(row.tag.map { "[\($0)] " } ?? "")\(row.row.label) → \(row.row.value)")
            }

            let b = pages.hardBlocks
            print("[Hard blocks] empty=\(b.emptyMessage ?? "—")")
            print("  conclusion: \(b.conclusion)")
            for row in b.rows {
                print("  \(row.tag.map { "[\($0)] " } ?? "")\(row.row.label) → \(row.row.value)")
            }
            print("  chart: \(b.chart.map { "yes — \($0.caption)" } ?? "withheld")")
            print("  pattern: \(b.patternNote ?? "—")")
            print("  coverage: \(b.coverageNote)")
        }

        // The reconciliation the model must keep: selected-day/model rows against period totals.
        print("\n──────── reconciliation ────────")
        for t in report.tools {
            let dayTokens = t.days.reduce(0) { $0 + $1.tokens }
            let dayValue = t.days.reduce(0.0) { $0 + $1.value }
            let modelValue = t.modelValues.reduce(0.0) { $0 + $1.value }
            print("[\(t.tool.tabLabel)] Σday tokens=\(dayTokens) total=\(t.totalTokens) · "
                  + "Σday value=\(String(format: "%.2f", dayValue)) "
                  + "Σmodel value=\(String(format: "%.2f", modelValue)) "
                  + "value=\(String(format: "%.2f", t.value)) · "
                  + "critical=\(t.criticalObservations.count)")
            XCTAssertEqual(dayTokens, t.totalTokens)
            XCTAssertEqual(dayValue, t.value, accuracy: 0.01)
            XCTAssertEqual(modelValue, t.value, accuracy: 0.01)
        }
        print("══════════════════════════════════════════════════════════\n")
    }
}
