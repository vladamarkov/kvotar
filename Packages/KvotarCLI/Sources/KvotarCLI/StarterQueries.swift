import Foundation

/// The handful of queries a corpus is worth having for (STEP_74 task 4, REV-52 §7).
///
/// Deliberately a **reference, not a framework**: text printed by `kvotar import
/// --print-queries`, ready to paste into `sqlite3` or pipe straight in. Every one of them answers a
/// question that needs *more than one bundle* — which is the whole reason the importer exists.
///
/// This file is the single source of truth for them; `docs/DIAGNOSTICS_ANALYSIS.md` points here
/// rather than restating the SQL, so the two can never drift apart.
enum StarterQueries {

    struct Query {
        let title: String
        /// Why an operator would run it — what the answer is *for*.
        let purpose: String
        let sql: String
    }

    static let all: [Query] = [
        Query(
            title: "What is in the corpus",
            purpose: "Which bundles landed, from whom, on what app version — and whether capture "
                   + "was on, without which an empty payload table is ambiguous.",
            sql: """
                SELECT tester_id,
                       app_version,
                       channel,
                       CASE capture_enabled WHEN 1 THEN 'on' WHEN 0 THEN 'off' ELSE '?' END
                           AS capture,
                       schema_migration,
                       datetime(generated_at, 'unixepoch') AS generated_utc,
                       import_count,
                       archive_name
                FROM bundles
                ORDER BY tester_id, generated_at;
                """),

        Query(
            title: "Utilization series per tester per tool",
            purpose: "The raw shape of what each machine saw. Run it when a tester says a number "
                   + "looked wrong and you want the hours around it.",
            sql: """
                SELECT tester_id,
                       tool,
                       datetime(polled_at, 'unixepoch') AS polled_utc,
                       primary_used_pct,
                       datetime(primary_resets_at, 'unixepoch') AS resets_utc
                FROM quota_series
                WHERE polled_at > strftime('%s', 'now', '-2 days')
                ORDER BY tester_id, tool, polled_at;
                """),

        Query(
            title: "Account-shape coverage — the goal the beta exists for",
            purpose: "Distinct provider response shapes across every bundle. A shape only one "
                   + "tester has ever produced is an account shape this app has met once; that is "
                   + "where the wrong-number bugs live (REV-52 §1.3).",
            sql: """
                SELECT tool,
                       endpoint,
                       shape_hash,
                       COUNT(DISTINCT tester_id) AS testers,
                       GROUP_CONCAT(DISTINCT tester_id) AS seen_on,
                       datetime(MIN(first_seen_at), 'unixepoch') AS first_seen_utc
                FROM payload_shapes
                GROUP BY tool, endpoint, shape_hash
                ORDER BY testers ASC, tool, endpoint;
                """),

        Query(
            title: "Parse anomalies by tester and tool",
            purpose: "Local JSONL lines the parsers rejected — field names only, never values. A "
                   + "cluster on one tester usually means a client version writing a shape we have "
                   + "never seen.",
            sql: """
                SELECT tester_id,
                       tool,
                       error,
                       COUNT(*) AS occurrences,
                       COUNT(DISTINCT source_file) AS files,
                       datetime(MIN(observed_at), 'unixepoch') AS first_utc,
                       datetime(MAX(observed_at), 'unixepoch') AS last_utc
                FROM parse_anomalies
                GROUP BY tester_id, tool, error
                ORDER BY occurrences DESC;
                """),

        Query(
            title: "Verdict correctness — predictions against what happened",
            purpose: "For every forecast that named a time it expected to hit 100%, did that "
                   + "machine's own series actually get there by then? A low rate is not "
                   + "automatically a bug: a window reset before the ETA is the ordinary reason a "
                   + "prediction does not land, so read it beside the reset column.",
            sql: """
                SELECT f.tester_id,
                       f.tool,
                       f.forecast_tier,
                       COUNT(*) AS predictions,
                       SUM(CASE WHEN (SELECT MAX(q.primary_used_pct)
                                      FROM quota_series q
                                      WHERE q.tester_id = f.tester_id
                                        AND q.tool = f.tool
                                        AND q.polled_at BETWEEN f.computed_at AND f.eta_to_100
                                     ) >= 100
                                THEN 1 ELSE 0 END) AS reached_100_by_eta,
                       SUM(CASE WHEN f.primary_resets_at < f.eta_to_100
                                THEN 1 ELSE 0 END) AS window_reset_first
                FROM forecast_log f
                WHERE f.eta_to_100 IS NOT NULL
                GROUP BY f.tester_id, f.tool, f.forecast_tier
                ORDER BY predictions DESC;
                """),

        Query(
            title: "Glances per day — product signal",
            purpose: "How often each tester actually opened the popover, and which tab they landed "
                   + "on. The observer-effect caveat stands: the first weeks read with a grain of "
                   + "salt.",
            sql: """
                SELECT tester_id,
                       date(opened_at, 'unixepoch') AS day_utc,
                       COUNT(*) AS opens,
                       SUM(CASE WHEN tab = 'claude' THEN 1 ELSE 0 END) AS claude_tab,
                       SUM(CASE WHEN tab = 'codex' THEN 1 ELSE 0 END) AS codex_tab
                FROM popover_opens
                GROUP BY tester_id, day_utc
                ORDER BY tester_id, day_utc;
                """)
    ]

    /// Printed by `--print-queries`. Comment-prefixed prose so the whole thing can be piped into
    /// `sqlite3` unedited.
    static var text: String {
        var lines: [String] = [
            "-- Kvotar — starter queries for a diagnostics corpus (kvotar import).",
            "-- Every table carries tester_id / bundle_id / src_rowid / row_hash provenance columns.",
            "-- Times are UTC; the app stores unix seconds throughout.",
            ""
        ]
        for (index, query) in all.enumerated() {
            lines.append("-- \(index + 1). \(query.title)")
            for line in wrap(query.purpose) { lines.append("--    \(line)") }
            lines.append(query.sql)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func wrap(_ text: String, width: Int = 86) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            if current.isEmpty {
                current = String(word)
            } else if current.count + word.count + 1 <= width {
                current += " \(word)"
            } else {
                lines.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}
