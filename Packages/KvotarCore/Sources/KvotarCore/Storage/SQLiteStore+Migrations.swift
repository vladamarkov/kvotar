import Foundation
import GRDB

// AgentPilot — SQLite v1 schema (§17.1).
// Ported verbatim from docs/history/agentpilot/AgentPilot_SQLite_v1_DDL.swift; cross-checked against
// ARCHITECTURE.md §SQLite table inventory. All migrations registered before any
// read or write occurs (see SQLiteStore.init).
//
// Foreign key enforcement (required for ON DELETE CASCADE on local_usage_events) and
// WAL mode are set per-connection in SQLiteStore.init's config.prepareDatabase.
extension SQLiteStore {

    static func registerMigrations(_ migrator: inout DatabaseMigrator) {

        migrator.registerMigration("v1") { db in

            // ── accounts ───────────────────────────────────────────────────
            // One row per tool. Current-only — upsert on every successful
            // adapter poll that returns account identity. Permanent retention.
            try db.create(table: "accounts") { t in
                t.column("tool", .text).notNull()           // "claude" | "codex"
                t.column("email", .text)                    // nullable; may be unavailable
                t.column("plan_type", .text)                // raw String; never a Swift enum
                t.column("updated_at", .integer).notNull()  // unix timestamp of last upsert
                t.primaryKey(["tool"])
            }

            // ── poll_snapshots ─────────────────────────────────────────────
            // One row per poll per tool. Powers 10-poll rolling average.
            // Rolling 2-hour window; most recent row per tool exempt from cleanup.
            try db.create(table: "poll_snapshots") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("tool", .text).notNull()
                t.column("polled_at", .integer).notNull()   // unix timestamp

                // Quota windows — shared columns, tool-tagged by `tool`. All nullable.
                t.column("primary_used_pct", .real)
                t.column("primary_resets_at", .integer)     // unix timestamp
                t.column("secondary_used_pct", .real)
                t.column("secondary_resets_at", .integer)   // unix timestamp

                // Shared block flag. null = insufficient data to determine state.
                t.column("rate_limit_reached", .integer)    // 0/1, nullable

                // Tool-specific flags.
                t.column("extra_usage_is_enabled", .integer) // 0/1; Claude only
                t.column("spend_control_reached", .integer)  // 0/1; Codex only

                // Rate-limit headers from §9.5. Nullable.
                t.column("ratelimit_limit", .integer)
                t.column("ratelimit_remaining", .integer)
                t.column("ratelimit_reset", .integer)       // unix timestamp

                // Must-store columns from §17. Seeds Alpha trend analysis (A20).
                t.column("primary_window_limit", .real)
                t.column("secondary_window_limit", .real)
                t.column("rate_limit_reset_credits_count", .integer)

                // Debug mode only (§10.7, P1-1). null in normal operation.
                t.column("raw_payload_redacted", .text)
            }

            try db.create(
                index: "poll_snapshots_tool_polled_at",
                on: "poll_snapshots",
                columns: ["tool", "polled_at"]
            )

            // ── notification_events ────────────────────────────────────────
            // Append-only fired notification log per tool per window.
            // Rolling 90 days on fired_at via the shared cleanup job (v5.17 — REV-42;
            // window-scoped deletion retired: enforcement scopes window_start = current).
            try db.create(table: "notification_events") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("tool", .text).notNull()
                t.column("event_type", .text).notNull()     // raw String e.g. "at_risk"
                t.column("fired_at", .integer).notNull()    // unix timestamp
                t.column("window_start", .integer).notNull()// unix timestamp; per-window
                                                            // enforcement scope key
                t.column("dismissed_at", .integer)          // null = not yet dismissed
                t.column("copy_variant", .text)             // null for single-variant notifications
            }

            try db.create(
                index: "notification_events_tool_window_start",
                on: "notification_events",
                columns: ["tool", "window_start"]
            )

            // ── local_sessions ─────────────────────────────────────────────
            // Per-session metadata for local attribution. Permanent since v5.18 (REV-43) —
            // the raw learning corpus; no cleanup job touches it.
            try db.create(table: "local_sessions") { t in
                t.column("session_id", .text).notNull()
                t.column("tool", .text).notNull()
                t.column("project", .text)
                t.column("model", .text)
                t.column("originator", .text)
                t.column("surface_bucket", .text)
                t.column("started_at", .integer)
                t.column("last_seen_at", .integer).notNull()// retention cutoff key
                t.primaryKey(["session_id", "tool"])
            }

            try db.create(
                index: "local_sessions_tool_last_seen_at",
                on: "local_sessions",
                columns: ["tool", "last_seen_at"]
            )

            // ── local_usage_events ─────────────────────────────────────────
            // Token deltas per request per session. Append-only. Dedup at PK level.
            // Permanent since v5.18 (REV-43). FK cascade from local_sessions retained —
            // nothing triggers it; correct if a manual purge is ever performed.
            try db.create(table: "local_usage_events") { t in
                t.column("session_id", .text).notNull()
                t.column("tool", .text).notNull()
                t.column("dedup_key", .text).notNull()
                t.column("recorded_at", .integer).notNull() // unix timestamp
                t.column("input_tokens", .integer).notNull().defaults(to: 0)
                t.column("output_tokens", .integer).notNull().defaults(to: 0)
                t.column("cache_creation_tokens", .integer).notNull().defaults(to: 0)
                t.column("cache_read_tokens", .integer).notNull().defaults(to: 0)
                t.primaryKey(["session_id", "tool", "dedup_key"])
                // Composite FK covers both columns of local_sessions' composite PK.
                t.foreignKey(["session_id", "tool"],
                             references: "local_sessions",
                             columns: ["session_id", "tool"],
                             onDelete: .cascade)
            }

            try db.create(
                index: "local_usage_events_session_tool_recorded_at",
                on: "local_usage_events",
                columns: ["session_id", "tool", "recorded_at"]
            )

            try db.create(
                index: "local_usage_events_tool_recorded_at",
                on: "local_usage_events",
                columns: ["tool", "recorded_at"]
            )

            // ── poll_health_events ─────────────────────────────────────────
            // AgentPilot-caused poll 429s only. Rolling 90 days (v5.17 — REV-42, was 7).
            try db.create(table: "poll_health_events") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("tool", .text).notNull()
                t.column("endpoint", .text).notNull()       // "oauth_usage" | "rpc" | "wham_usage"
                t.column("timestamp", .integer).notNull()   // unix timestamp
                t.column("retry_after_seconds", .integer).notNull()
                t.column("consecutive_count", .integer).notNull()
                t.column("base_interval_at_time", .integer).notNull()
            }

            try db.create(
                index: "poll_health_events_tool_timestamp",
                on: "poll_health_events",
                columns: ["tool", "timestamp"]
            )

            // ── quota_limit_events ─────────────────────────────────────────
            // User session quota 429s from JSONL — self-learning ceiling only.
            // Permanent retention; plan-change reset via plan_type filter.
            try db.create(table: "quota_limit_events") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("tool", .text).notNull()
                t.column("timestamp", .integer).notNull()
                t.column("utilization_pct", .real).notNull()
                t.column("window_type", .text).notNull()    // "five_hour" | "weekly"
                t.column("source_file", .text).notNull()
                t.column("plan_type", .text).notNull()
                t.uniqueKey(["tool", "source_file", "timestamp"])
            }

            try db.create(
                index: "quota_limit_events_tool_window_plan",
                on: "quota_limit_events",
                columns: ["tool", "window_type", "plan_type"]
            )

            // ── state_transitions ──────────────────────────────────────────
            // StateEngine transition log for debugging/dogfood. Rolling 90 days
            // (v5.17 — REV-42, was 7).
            try db.create(table: "state_transitions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("tool", .text).notNull()
                t.column("timestamp", .integer).notNull()   // unix timestamp
                t.column("from_state", .text).notNull()     // raw state name strings
                t.column("to_state", .text).notNull()
                t.column("triggered_by", .text).notNull()   // "poll" | "jsonl_delta" | "poll_failure"
                t.column("utilization_pct", .real)          // nullable
            }

            try db.create(
                index: "state_transitions_tool_timestamp",
                on: "state_transitions",
                columns: ["tool", "timestamp"]
            )

            // ── settings ───────────────────────────────────────────────────
            // Key-value store. Permanent retention. INSERT OR REPLACE on key PK.
            // Pre-Alpha keys: "debug_mode_enabled", "schema_version".
            try db.create(table: "settings") { t in
                t.column("key", .text).notNull()
                t.column("value", .text)                    // all values stored as TEXT
                t.column("updated_at", .integer).notNull()  // unix timestamp of last write
                t.primaryKey(["key"])
            }

            // ── Schema version ─────────────────────────────────────────────
            // updated_at cast to Int to avoid storing a Double in an INTEGER column.
            try db.execute(
                sql: "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, ?)",
                arguments: ["schema_version", "1", Int(Date().timeIntervalSince1970)]
            )
        }

        // v4 (§9.5 — R31-4): 429 forensic capture. Eight nullable, additive columns on
        // poll_health_events populated on the 429 branch only, so the event is self-contained
        // (poll_snapshots retains only 2h; joining the account context at read time is impossible).
        //
        // Identifier is `v4_*`, not `v2_*`: the migration lineage in live databases already reached
        // v3 via concurrent work not yet on this branch (`v2_local_usage_reasoning_tokens`,
        // `v3_codex_desktop_surface_bucket`). GRDB keys on the identifier string, so a fresh
        // main-built DB runs v1 → v4 (schema_version jumps 1 → 4, harmless), and a live DB that
        // already applied v2/v3 runs this one cleanly with no collision on merge.
        migrator.registerMigration("v4_poll_health_forensics") { db in
            try db.alter(table: "poll_health_events") { t in
                t.add(column: "response_headers_json", .text)   // full response headers, verbatim
                t.add(column: "response_body", .text)           // redacted (§10.6); token never stored
                t.add(column: "category", .text)                // transient | rate_pressure | unknown
                t.add(column: "last_primary_used_pct", .real)   // last-good 5-hour utilization
                t.add(column: "last_secondary_used_pct", .real) // last-good weekly utilization
                t.add(column: "last_primary_resets_at", .integer)   // last-good primary reset (unix)
                t.add(column: "last_extra_usage_enabled", .integer) // 0/1 credits toggle
                t.add(column: "null_window_source", .text)      // "provider" | "normalized" (D1)
            }
            try db.execute(
                sql: "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, ?)",
                arguments: ["schema_version", "4", Int(Date().timeIntervalSince1970)]
            )
        }

        // v5 (§17 — REV-38, STEP_43): Codex per-user monthly credit limit (`individual_limit` /
        // RPC `individualLimit`). Four nullable, additive columns on poll_snapshots — string→numeric
        // at ingest, NULL when no monthly limit is configured (consumer always; Enterprise without
        // an admin limit) and on every Claude row. Feeds monthly pace deltas + launch restore of
        // the monthly header (stale rendering per UI Spec D-35). `source` is control metadata and
        // is deliberately not persisted.
        migrator.registerMigration("v5_codex_monthly_limit") { db in
            try db.alter(table: "poll_snapshots") { t in
                t.add(column: "monthly_limit", .real)           // credit ceiling (e.g. 4000)
                t.add(column: "monthly_used", .real)            // credits consumed this cycle
                t.add(column: "monthly_remaining_pct", .integer) // OpenAI's own integer remaining %
                t.add(column: "monthly_resets_at", .integer)    // unix ts — next calendar month UTC
            }
            try db.execute(
                sql: "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, ?)",
                arguments: ["schema_version", "5", Int(Date().timeIntervalSince1970)]
            )
        }

        // v6 (§17 — REV-40, STEP_46): the monthly limit's denomination (`QuotaUnit`). Two
        // nullable, additive columns; both NULL ⇒ `.credits`, so every existing Codex and
        // pre-migration row is correct with no backfill. Written as a pair only for `.money`
        // rows (Claude Enterprise spend), whose `monthly_limit`/`monthly_used` REALs hold raw
        // **minor units** exactly. Rejected: normalizing to dollars + inferring unit from
        // `tool` — loses currency, guesses USD, couples storage to tool identity where the
        // model is deliberately unit-parameterized.
        migrator.registerMigration("v6_claude_monthly_spend_unit") { db in
            try db.alter(table: "poll_snapshots") { t in
                t.add(column: "monthly_currency", .text)     // ISO code, e.g. "USD"; NULL ⇒ credits
                t.add(column: "monthly_exponent", .integer)  // minor-unit exponent, e.g. 2
            }
            try db.execute(
                sql: "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, ?)",
                arguments: ["schema_version", "6", Int(Date().timeIntervalSince1970)]
            )
        }

        // v7 (§17.1/§17.2 — REV-42 + REV-43, STEP_50): the learning substrate. Six permanent
        // tables in one migration — three aggregate/receipt layers written by the cleanup job
        // and the settings write path (STEP_50), and three whose writers land later
        // (forecast_log → STEP_51; discontinuity_events + popover_opens → STEP_52; created here
        // so the schema ships once). Substrate principle (§17): raw observations, claims-made,
        // and what-was-shown facts only — never derived states, whose meaning rots when
        // thresholds change.
        migrator.registerMigration("v7_learning_substrate") { db in

            // ── history_rollups ────────────────────────────────────────────
            // Permanent hourly aggregate of poll_snapshots, written by runRetentionCleanup()
            // immediately before the snapshot DELETE, from exactly the rows being deleted
            // (aggregate-before-purge). Merge-upsert: one hour bucket is purged across up to
            // three cleanup runs at 2h retention / 30-min cadence (§17.1 merge semantics).
            try db.create(table: "history_rollups") { t in
                t.column("tool", .text).notNull()
                t.column("hour_start", .integer).notNull()   // polled_at floored to UTC hour
                t.column("snapshot_count", .integer).notNull()
                t.column("primary_used_pct_min", .real)
                t.column("primary_used_pct_max", .real)
                t.column("primary_used_pct_last", .real)
                t.column("secondary_used_pct_min", .real)
                t.column("secondary_used_pct_max", .real)
                t.column("secondary_used_pct_last", .real)
                t.column("primary_resets_at_last", .integer)
                t.column("secondary_resets_at_last", .integer)
                t.column("primary_window_limit_last", .real)   // durable A20 limit-trend series
                t.column("secondary_window_limit_last", .real)
                t.column("rate_limit_reached_max", .integer)   // 0/1 — any hit in the hour
                t.column("extra_usage_is_enabled_last", .integer)
                t.column("spend_control_reached_last", .integer)
                t.column("rate_limit_reset_credits_count_last", .integer)
                t.column("monthly_limit_last", .real)          // minor units for .money rows
                t.column("monthly_used_last", .real)
                t.column("monthly_resets_at_last", .integer)
                t.column("monthly_currency_last", .text)       // NULL + NULL exponent ⇒ .credits
                t.column("monthly_exponent_last", .integer)
                t.column("plan_type", .text)                   // from accounts at rollup write
                t.column("last_polled_at", .integer).notNull() // merge tie-breaker for _last
                t.primaryKey(["tool", "hour_start"])
            }

            // ── forecast_log ───────────────────────────────────────────────
            // Permanent prediction log — each row is a claim about the future, graded later
            // (forecast calibration). Writer ships in STEP_51: ≤1 row / 5 min / tool plus one
            // per state transition. Deliberately absent: the state string and verdict template
            // (derived conclusions; substrate principle §17).
            try db.create(table: "forecast_log") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("tool", .text).notNull()
                t.column("computed_at", .integer).notNull()
                t.column("primary_used_pct", .real)
                t.column("secondary_used_pct", .real)
                t.column("burn_rate_pct_per_min", .real)     // quantized §11.2a value
                t.column("eta_to_100", .integer)             // null ⇒ "nothing burning" claim
                t.column("primary_resets_at", .integer)      // the deadline the prediction races
                t.column("forecast_tier", .text).notNull()   // "cold_start" | "partial" | "full"
                t.column("trigger", .text).notNull()         // "sample" | "state_change"
                t.column("app_version", .text)               // engine math changes between builds
            }

            try db.create(
                index: "forecast_log_tool_computed_at",
                on: "forecast_log",
                columns: ["tool", "computed_at"]
            )

            // ── session_summaries ──────────────────────────────────────────
            // One permanent receipt per work session — convenience aggregate over the (permanent)
            // raw corpus. Upserted by runRetentionCleanup() for sessions idle >24h; a resumed
            // session is simply re-summarized on the next pass. Raw sums, never percentages.
            try db.create(table: "session_summaries") { t in
                t.column("session_id", .text).notNull()
                t.column("tool", .text).notNull()
                t.column("project", .text)
                t.column("model", .text)                     // session-level; per-request not stored
                t.column("originator", .text)
                t.column("surface_bucket", .text)
                t.column("started_at", .integer)
                t.column("last_seen_at", .integer).notNull() // session-end proxy
                t.column("event_count", .integer).notNull()
                t.column("input_tokens", .integer).notNull().defaults(to: 0)
                t.column("output_tokens", .integer).notNull().defaults(to: 0)
                t.column("cache_creation_tokens", .integer).notNull().defaults(to: 0)
                t.column("cache_read_tokens", .integer).notNull().defaults(to: 0)
                t.column("summarized_at", .integer).notNull()
                t.primaryKey(["session_id", "tool"])
            }

            // ── discontinuity_events ───────────────────────────────────────
            // Permanent append-only log of instants with before/after pairs — rollups blur,
            // moments point. Writer ships in STEP_52 (consecutive-poll comparison + the §13.2
            // windowReset event; R33-7 once-per-anchor is the dedup). For window_reset rows,
            // utilization_pct is utilization-at-crossing — the quota-waste histogram input.
            try db.create(table: "discontinuity_events") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("tool", .text).notNull()
                t.column("event_type", .text).notNull()      // "limit_changed" | "plan_changed" |
                                                             // "credits_toggled" | "window_reset" |
                                                             // "monthly_rollover"; raw String
                t.column("observed_at", .integer).notNull()
                t.column("window_type", .text)               // "five_hour" | "weekly"; null for
                                                             // account-scoped types
                t.column("old_value", .text)                 // raw string, typed at read
                t.column("new_value", .text)
                t.column("utilization_pct", .real)
            }

            try db.create(
                index: "discontinuity_events_tool_observed_at",
                on: "discontinuity_events",
                columns: ["tool", "observed_at"]
            )

            // ── popover_opens ──────────────────────────────────────────────
            // Permanent glance log — one row per popover open, what the app was showing at that
            // moment. State strings here are what-was-shown facts about the interaction (the §17
            // exception), never a quota-truth series. Writer ships in STEP_52 (UI hook).
            try db.create(table: "popover_opens") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("opened_at", .integer).notNull()
                t.column("tab", .text)                       // §15.1 default-tab outcome
                t.column("claude_state", .text)              // as shown; null if unknown/loading
                t.column("claude_primary_used_pct", .real)
                t.column("codex_state", .text)
                t.column("codex_primary_used_pct", .real)
            }

            // ── settings_changes ───────────────────────────────────────────
            // Permanent append-only audit of settings writes (old → new) — INSERT OR REPLACE
            // previously erased the trail. Written by the settings write path (STEP_50).
            try db.create(table: "settings_changes") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("changed_at", .integer).notNull()
                t.column("key", .text).notNull()
                t.column("old_value", .text)                 // null ⇒ key was absent
                t.column("new_value", .text)
            }

            try db.execute(
                sql: "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, ?)",
                arguments: ["schema_version", "7", Int(Date().timeIntervalSince1970)]
            )
        }

        // v8 (§9.1/§9.5 — REV-41, STEP_48): the credential-expired forensic row. A poll preempted
        // by the §8.0.1 expiry gate sends **no request**, so it has no `Retry-After` to record —
        // the row's `retry_after_seconds` must be NULL (category `credential_expired`, response
        // fields null). v1 declared the column NOT NULL; SQLite cannot DROP NOT NULL in place, so
        // the table is recreated with it nullable and every existing row copied forward. No table
        // references poll_health_events and it references none, so the recreate needs no FK dance.
        migrator.registerMigration("v8_credential_expired_nullable") { db in
            // Mirror the live schema (v1 base + v4 forensics) exactly, retry_after_seconds nullable.
            try db.create(table: "poll_health_events_new") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("tool", .text).notNull()
                t.column("endpoint", .text).notNull()
                t.column("timestamp", .integer).notNull()
                t.column("retry_after_seconds", .integer)        // nullable since v8 (gate rows: NULL)
                t.column("consecutive_count", .integer).notNull()
                t.column("base_interval_at_time", .integer).notNull()
                t.column("response_headers_json", .text)
                t.column("response_body", .text)
                t.column("category", .text)
                t.column("last_primary_used_pct", .real)
                t.column("last_secondary_used_pct", .real)
                t.column("last_primary_resets_at", .integer)
                t.column("last_extra_usage_enabled", .integer)
                t.column("null_window_source", .text)
            }
            try db.execute(sql: """
                INSERT INTO poll_health_events_new (
                    id, tool, endpoint, timestamp,
                    retry_after_seconds, consecutive_count, base_interval_at_time,
                    response_headers_json, response_body, category,
                    last_primary_used_pct, last_secondary_used_pct, last_primary_resets_at,
                    last_extra_usage_enabled, null_window_source
                )
                SELECT
                    id, tool, endpoint, timestamp,
                    retry_after_seconds, consecutive_count, base_interval_at_time,
                    response_headers_json, response_body, category,
                    last_primary_used_pct, last_secondary_used_pct, last_primary_resets_at,
                    last_extra_usage_enabled, null_window_source
                FROM poll_health_events
                """)
            try db.execute(sql: "DROP TABLE poll_health_events")
            try db.execute(sql: "ALTER TABLE poll_health_events_new RENAME TO poll_health_events")
            try db.create(
                index: "poll_health_events_tool_timestamp",
                on: "poll_health_events",
                columns: ["tool", "timestamp"]
            )
            try db.execute(
                sql: "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, ?)",
                arguments: ["schema_version", "8", Int(Date().timeIntervalSince1970)]
            )
        }

        // v9 (§10.7a/§17.1 — REV-52, STEP_72): diagnostics capture. Four tables. The first three
        // exist because *nothing* stored what the provider actually returned — the adapters parsed
        // and dropped it, so on an unfamiliar account shape `poll_snapshots` recorded our
        // conclusion and the input that produced it was gone. `poll_snapshots.raw_payload_redacted`
        // (v1, §10.7's original effect (b)) is **retired unwritten**: it is per-snapshot, so it has
        // nowhere to put the profile/prepaid/wham/RPC responses, and `poll_snapshots` is purged at
        // 2h — a payload captured there dies before anyone notices anything is wrong. Left in place
        // rather than dropped (a recreate for no behavioural gain).
        migrator.registerMigration("v9_diagnostics_capture") { db in

            // ── raw_payloads ───────────────────────────────────────────────
            // Response bodies, verbatim and **unredacted** (P1-1 re-resolved, §17): these endpoints
            // carry quota + account identity only — no prompt/code/transcript/tool-output, and no
            // bearer material (the token rides a request header, which is never captured).
            // Two retention classes in one table (§17.2): `window` rows are pruned at 48h;
            // `shape_change` rows are permanent.
            try db.create(table: "raw_payloads") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("tool", .text).notNull()
                t.column("endpoint", .text).notNull()   // stable identifier, never a raw URL
                t.column("captured_at", .integer).notNull()
                t.column("http_status", .integer)       // NULL on the RPC path — it has no status
                t.column("body", .text).notNull()
                t.column("shape_hash", .text).notNull()
                t.column("keep_reason", .text).notNull()  // "window" | "shape_change"
            }

            try db.create(
                index: "raw_payloads_tool_endpoint_captured_at",
                on: "raw_payloads",
                columns: ["tool", "endpoint", "captured_at"]
            )

            // ── payload_shapes ─────────────────────────────────────────────
            // One row per distinct structural shape per endpoint — the provider-drift tripwire.
            // `field_paths` is a sorted JSON array of dotted paths: **names only, no values**.
            // Permanent: the row *is* the drift record, and it is what makes "the provider changed
            // something on the 14th" answerable a month later.
            try db.create(table: "payload_shapes") { t in
                t.column("tool", .text).notNull()
                t.column("endpoint", .text).notNull()
                t.column("shape_hash", .text).notNull()
                t.column("first_seen_at", .integer).notNull()
                t.column("last_seen_at", .integer).notNull()
                t.column("field_paths", .text).notNull()
                t.primaryKey(["tool", "endpoint", "shape_hash"])
            }

            // ── parse_anomalies ────────────────────────────────────────────
            // Local JSONL lines the parsers could not decode. **Values are never stored — only
            // names.** This table is the entire reason a diagnostics bundle needs no JSONL file
            // (§17: those files carry transcripts belonging to third parties who never consented),
            // so widening it to values would reopen the never-store rule by the back door.
            try db.create(table: "parse_anomalies") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("tool", .text).notNull()
                t.column("source_file", .text).notNull()
                t.column("line_number", .integer)
                t.column("observed_at", .integer).notNull()
                t.column("error", .text)
                t.column("field_names", .text)          // JSON array of top-level key names
            }

            // ── app_lifecycle_events ───────────────────────────────────────
            // Launch/quit/sleep/wake. Written **regardless** of the capture setting — this is
            // app-lifecycle fact, not provider data. Without it a gap in any other series is
            // unreadable: laptop shut, or engine stalled? The logs carry these events today but
            // rotate on every launch, which is exactly the problem.
            try db.create(table: "app_lifecycle_events") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("event", .text).notNull()      // "launch" | "quit" | "sleep" | "wake"
                t.column("occurred_at", .integer).notNull()
                t.column("app_version", .text)          // version + channel at the time
            }

            try db.execute(
                sql: "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, ?)",
                arguments: ["schema_version", "9", Int(Date().timeIntervalSince1970)]
            )
        }

        migrator.registerMigration("v10_quota_series") { db in

            // ── quota_series ───────────────────────────────────────────────
            // One slim row per successful poll that carried an active 5-hour window — the
            // account-side interval boundaries the off-machine recompute walks (REV-53 §3) and
            // the permanent calibration substrate for the STEP_78 pricing fit (REV-53 §6).
            // Written inside `writePoll`'s transaction; rows whose poll had a null window are
            // never written (a windowless pct can't be attributed to a window). Permanent
            // (§17.2): unlike `poll_snapshots` (2h, fat forensic rows), these four columns are
            // the minimum that makes any past window re-walkable, and history is the point.
            try db.create(table: "quota_series") { t in
                t.column("tool", .text).notNull()
                t.column("polled_at", .integer).notNull()
                t.column("primary_used_pct", .real).notNull()
                t.column("primary_resets_at", .integer).notNull()
                t.primaryKey(["tool", "polled_at"])
            }

            // Serves the window-row read: rows are selected by `primary_resets_at` proximity
            // (±60s jitter tolerance), never by a `polled_at` range — the rollover-robust
            // predicate (REV-53 / STEP_76).
            try db.create(
                index: "quota_series_tool_resets_at",
                on: "quota_series",
                columns: ["tool", "primary_resets_at"]
            )

            try db.execute(
                sql: "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, ?)",
                arguments: ["schema_version", "10", Int(Date().timeIntervalSince1970)]
            )
        }

        migrator.registerMigration("v11_quota_ceiling_floor") { db in

            // ── quota_limit_events: one-time sub-floor cleanup ─────────────
            // THE SANCTIONED EXCEPTION to §17.2's permanent-table rule. `quota_limit_events` is on
            // the never-pruned list (`SQLiteStore+Retention.swift`) and stays there — the retention
            // rule is NOT being abandoned; this migration is a single historical correction of rows
            // the §9.4 detector should never have written (REV-54 §6 / STEP_80).
            //
            // Why: the detector is a working assumption (it marks any rate-limit-shaped error line)
            // and `resolveCeiling` takes the *minimum*, so one implausible reading pins the learned
            // ceiling forever. Live: `100, 100, 5, 7, 97, 97, 99, 100` ⇒ a learned five-hour ceiling
            // of 5.0%. The write path now refuses sub-floor observations; this clears the ones that
            // predate the floor.
            //
            // 50.0 is written as a LITERAL, deliberately — it is the floor *as of v11*, and this
            // migration is a fixed historical act. Reading
            // `LimitsDatabaseAdapter.quotaCeilingObservationFloorPct` would let a later P1-21 tuning
            // silently change what v11 deletes on any machine that has not migrated yet.
            try db.execute(sql: "DELETE FROM quota_limit_events WHERE utilization_pct < 50.0")
            Logger.info("Sub-floor quota ceiling observations deleted",
                        component: .sqliteStore,
                        metadata: ["deleted": "\(db.changesCount)", "floor": "50.0",
                                   "migration": "v11_quota_ceiling_floor"])

            try db.execute(
                sql: "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, ?)",
                arguments: ["schema_version", "11", Int(Date().timeIntervalSince1970)]
            )
        }

        migrator.registerMigration("v12_unanchored_window_cleanup") { db in

            // ── discontinuity_events / notification_events: one-time unanchored-reset cleanup ──
            // THE SANCTIONED EXCEPTION to §17.2's permanent-table rule, and the second of its kind
            // (v11 above is the first — same shape, same reasoning). `discontinuity_events` stays on
            // the never-pruned list; this migration is a single historical correction of rows that
            // record an event which did not happen (REV-57 §7 / STEP_85).
            //
            // Why: at `used_percent == 0` the Codex provider recomputes `reset_at = now + window`
            // on every request, so the anchor advanced by exactly one poll gap per poll and every
            // guard keyed on it read a rollover. Live 2026-08-08/09: 103 `window_reset` rows and 101
            // `window_reset_post` notifications, one per poll, for a 30-day window that never reset —
            // and the discontinuity rows are stamped `window_type = 'five_hour'` besides. §17.1's
            // corpus exists to answer "was the app right?"; it cannot while it holds these.
            //
            // Scoped to Codex deliberately. Claude cannot produce the shape (it reports no window
            // width, so the adapter rule that now prevents this never engages there), and its own
            // reset history is real.
            try db.execute(sql: """
                DELETE FROM discontinuity_events WHERE tool = 'codex' AND event_type = 'window_reset'
                """)
            Logger.info("Unanchored-window reset discontinuities deleted",
                        component: .sqliteStore,
                        metadata: ["deleted": "\(db.changesCount)",
                                   "migration": "v12_unanchored_window_cleanup"])

            try db.execute(sql: """
                DELETE FROM notification_events
                WHERE tool = 'codex' AND event_type = 'window_reset_post'
                """)
            Logger.info("Unanchored-window reset notifications deleted",
                        component: .sqliteStore,
                        metadata: ["deleted": "\(db.changesCount)",
                                   "migration": "v12_unanchored_window_cleanup"])

            try db.execute(
                sql: "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, ?)",
                arguments: ["schema_version", "12", Int(Date().timeIntervalSince1970)]
            )
        }

        migrator.registerMigration("v13_drop_persisted_poll_base") { db in

            // ── settings: retire the persisted poll base (REV-39 / STEP_45) ──────────────
            // Not a data correction like v11/v12 — this deletes a *setting the app no longer
            // has code to read or write*. `PollBackoffPolicy`'s base is fixed at 60s and the
            // 429 ladder is transient and in-memory (§9.2/§9.3), so a left-behind
            // `poll_base_interval.<tool>` row would be a stale claim about how the app behaves,
            // readable by the CLI and the diagnostics bundle and true of neither.
            //
            // Why it existed: R31-1 persisted the learned cadence so a restart could not throw
            // it away and re-provoke the limiter. Real bug, real fix — but it persisted the
            // *value* without the *cause*, and on this machine it pinned the base at the 300s
            // ceiling indefinitely (decay needed 100 clean polls and any 429 reset the count).
            //
            // The `settings_changes` audit rows are deliberately NOT deleted. They are the
            // evidence trail REV-39 §5.1 was written from — the base sawtoothing 60 → 120 → 240
            // and back with nobody touching it — and §17.1's corpus keeps raw observations even
            // when the mechanism that produced them is gone.
            try db.execute(sql: "DELETE FROM settings WHERE key LIKE 'poll_base_interval.%'")
            Logger.info("Persisted poll base intervals deleted",
                        component: .sqliteStore,
                        metadata: ["deleted": "\(db.changesCount)",
                                   "migration": "v13_drop_persisted_poll_base"])

            try db.execute(
                sql: "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, ?)",
                arguments: ["schema_version", "13", Int(Date().timeIntervalSince1970)]
            )
        }

        migrator.registerMigration("v14_unpriced_models") { db in

            // ── unpriced_models ────────────────────────────────────────────
            // One permanent row per `(provider, model)` that `resolvePricing` had to price at the
            // provider fallback (REV-62 §5.3 / STEP_92). `claude-opus-5` ran for weeks on the
            // fallback and the only notice was a WARNING in a log file that rotates on every
            // launch; this table is that observation made durable. Follows the `payload_shapes`
            // merge-upsert pattern (STEP_72): the row is the record, so it is never cleaned up.
            //
            // `provider` is the *requesting* provider (the fallback actually used), which on a
            // provider-mismatch row differs from the matched row's own provider — the pair still
            // has no usable row, which is the fact being recorded.
            //
            // Additive only, and deliberately blind to `local_usage_events`: the live database
            // carries that table's `reasoning_output_tokens` from the unregistered
            // `v2_local_usage_reasoning_tokens` while a fresh install does not (REV-62 §6), so a
            // migration touching it would fork behaviour by machine.
            try db.create(table: "unpriced_models") { t in
                t.column("provider", .text).notNull()
                t.column("model", .text).notNull()
                t.column("first_seen_at", .integer).notNull()
                t.column("last_seen_at", .integer).notNull()
                t.column("observation_count", .integer).notNull()
                t.primaryKey(["provider", "model"])
            }

            try db.execute(
                sql: "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, ?)",
                arguments: ["schema_version", "14", Int(Date().timeIntervalSince1970)]
            )
        }

        migrator.registerMigration("v15_event_attribution") { db in

            // ── local_usage_events.model / .surface_bucket ─────────────────
            // Per-event attribution (REV-62 §4.3 / STEP_93). Model and surface were session-scoped
            // — `local_sessions.model` under a last-non-null-wins upsert — so every token a session
            // produced was priced at whichever model spoke last, and subagent work inherited the
            // same bug through `surface_bucket` (31 of 145 Claude sessions are multi-model; 5.3%
            // of tokens mispriced; subagent share understated 24×).
            //
            // Both columns are nullable with no default: existing rows stay NULL and every reader
            // falls back to the session value via COALESCE. A one-shot enrichment sweep (STEP_93,
            // user ruling 2026-08-12) fills them from the JSONL corpus where it is still on disk —
            // an UPDATE of these two columns only, never of recorded token quantities (REV-43).
            //
            // ALTER TABLE, not table rebuild: the live database carries `reasoning_output_tokens`
            // from the unregistered `v2_local_usage_reasoning_tokens` while a fresh install does
            // not (REV-62 §6) — a rebuild would fork behaviour by machine.
            try db.execute(sql: "ALTER TABLE local_usage_events ADD COLUMN model TEXT")
            try db.execute(sql: "ALTER TABLE local_usage_events ADD COLUMN surface_bucket TEXT")

            try db.execute(
                sql: "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, ?)",
                arguments: ["schema_version", "15", Int(Date().timeIntervalSince1970)]
            )
        }

        migrator.registerMigration("v16_duplicate_event_cleanup") { db in

            // ── local_usage_events: one-time cross-session duplicate reconciliation ──
            // The third sanctioned exception to §17.2's permanent-table rule (v11, v12 precede
            // it — same shape, same reasoning). REV-43's principle protects *provider
            // observations*; every row deleted here is one observation the app recorded twice
            // under two of its own naming schemes, and the raw JSONL on disk — itself permanent —
            // still holds each turn exactly once. Deletion converges the database toward that
            // ground truth (REV-62 §4.1 / STEP_94).
            //
            // Codex (mechanism b): the session-id convention changed ~2026-07-13 (bare UUID →
            // rollout-file basename) while the dedup key, which embeds the rollout basename,
            // stayed stable — so the 2026-07-05→07-10 stretch was ingested under BOTH
            // conventions: 154 keys on two rows each (+14.9M input, +12.7M cached, ≈$30.59).
            // The **bare-UUID twin is kept**, not the rollout one: input and the cached union
            // match on all 154 pairs, but 138 rollout twins were written by the era's
            // reasoning-folding parser and overstate output by 47,355 tokens the bare twins
            // record raw (the §8.4 post-STEP_91 rule). Keeping the bare side also leaves the
            // corpus with a single convention boundary at 2026-07-13 instead of an island.
            let codexEmptied = try String.fetchAll(db, sql: """
                SELECT DISTINCT session_id FROM local_usage_events
                WHERE tool = 'codex' AND session_id LIKE 'rollout-%' AND dedup_key IN (
                    SELECT dedup_key FROM local_usage_events
                    WHERE tool = 'codex' AND session_id NOT LIKE 'rollout-%')
                """)
            try db.execute(sql: """
                DELETE FROM local_usage_events WHERE rowid IN (
                    SELECT e.rowid FROM local_usage_events e
                    WHERE e.tool = 'codex' AND e.session_id LIKE 'rollout-%'
                      AND EXISTS (
                        SELECT 1 FROM local_usage_events k
                        WHERE k.tool = 'codex' AND k.dedup_key = e.dedup_key
                          AND k.session_id NOT LIKE 'rollout-%'))
                """)
            Logger.info("Cross-convention Codex duplicates deleted", component: .sqliteStore,
                        metadata: ["deleted": "\(db.changesCount)",
                                   "migration": "v16_duplicate_event_cleanup"])

            // Claude (mechanism c): session resume/fork rewrote copied lines under the new
            // session id and the pre-STEP_94 key was session-scoped, so each of 67 billed
            // messages is stored in two sessions (+7.2M tokens, ≈$5.93). The earliest-recorded
            // row is kept (all 67 pairs share `recorded_at` — the line's own timestamp was
            // copied — so the rowid tiebreak keeps the first-ingested, i.e. the original
            // session's row).
            let claudeAffected = try String.fetchAll(db, sql: """
                SELECT DISTINCT e.session_id FROM local_usage_events e
                JOIN local_usage_events k
                  ON k.tool = 'claude' AND k.dedup_key = e.dedup_key
                 AND k.session_id <> e.session_id
                 AND (k.recorded_at < e.recorded_at
                      OR (k.recorded_at = e.recorded_at AND k.rowid < e.rowid))
                WHERE e.tool = 'claude'
                """)
            try db.execute(sql: """
                DELETE FROM local_usage_events WHERE rowid IN (
                    SELECT e.rowid FROM local_usage_events e
                    JOIN local_usage_events k
                      ON k.tool = 'claude' AND k.dedup_key = e.dedup_key
                     AND k.session_id <> e.session_id
                     AND (k.recorded_at < e.recorded_at
                          OR (k.recorded_at = e.recorded_at AND k.rowid < e.rowid))
                    WHERE e.tool = 'claude')
                """)
            Logger.info("Cross-session Claude duplicates deleted", component: .sqliteStore,
                        metadata: ["deleted": "\(db.changesCount)",
                                   "migration": "v16_duplicate_event_cleanup"])

            // Session rows left with zero events by the deletions above are the duplicate
            // *session* recording of the same naming-scheme accident — the cleanup the STEP_95
            // backfill deferred to this step. Only sessions that just lost rows are candidates;
            // a session that was legitimately empty before this migration is untouched.
            for (tool, sessions) in [("codex", codexEmptied), ("claude", claudeAffected)] {
                var dropped = 0
                for sessionId in sessions {
                    try db.execute(sql: """
                        DELETE FROM local_sessions
                        WHERE tool = ? AND session_id = ? AND NOT EXISTS (
                            SELECT 1 FROM local_usage_events e
                            WHERE e.tool = local_sessions.tool
                              AND e.session_id = local_sessions.session_id)
                        """, arguments: [tool, sessionId])
                    dropped += db.changesCount
                }
                if dropped > 0 {
                    Logger.info("Emptied duplicate session rows deleted", component: .sqliteStore,
                                metadata: ["tool": tool, "deleted": "\(dropped)",
                                           "migration": "v16_duplicate_event_cleanup"])
                }
            }

            // The STEP_94 duplicate guard queries `(tool, dedup_key)` under any session id on
            // every live insert, backfill insert, and enrichment update; the composite PK leads
            // with `session_id` and cannot serve it. Non-unique deliberately: nothing above
            // guarantees global uniqueness for rows predating the cleanup horizon.
            try db.execute(sql: """
                CREATE INDEX idx_local_usage_events_tool_dedup
                ON local_usage_events(tool, dedup_key)
                """)

            try db.execute(
                sql: "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, ?)",
                arguments: ["schema_version", "16", Int(Date().timeIntervalSince1970)]
            )
        }

        migrator.registerMigration("v17_cache_write_tiers") { db in

            // ── local_usage_events.cache_creation_1h_tokens ────────────────
            // Anthropic charges 1.25x input for a 5-minute cache write and 2x for a 1-hour one.
            // The parser decoded both tiers and summed them away, so the distinction died at
            // ingest and could not be fixed in `pricing.json` alone (REV-62 §4.4 / STEP_96).
            // 84.3% of lifetime writes are the 1-hour kind — roughly $332 of understated
            // est. token value, larger than the missing `claude-opus-5` row STEP_91 fixed.
            //
            // The column holds the **1-hour slice**, a SUBSET of `cache_creation_tokens`, which
            // keeps its meaning as the total. Storing the subset (rather than replacing the
            // total, or storing the 5-minute side) is what makes every displayed count, the
            // cache-hit ratio and the menu bar structurally incapable of moving, and makes NULL
            // mean exactly today's behaviour: nothing known to be 1-hour, so the whole write
            // prices at 1.25x.
            //
            // Nullable with no default, and deliberately NOT backfilled (user ruling
            // 2026-08-12, declining the STEP_93 enrichment precedent): every row written before
            // this migration keeps pricing at the 5-minute rate, and that boundary is recorded
            // in Baseline §17.1 rather than left to be rediscovered.
            //
            // ALTER TABLE, not table rebuild: the live database carries `reasoning_output_tokens`
            // from the unregistered `v2_local_usage_reasoning_tokens` while a fresh install does
            // not (REV-62 §6) — a rebuild would fork behaviour by machine.
            try db.execute(
                sql: "ALTER TABLE local_usage_events ADD COLUMN cache_creation_1h_tokens INTEGER")

            try db.execute(
                sql: "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, ?)",
                arguments: ["schema_version", "17", Int(Date().timeIntervalSince1970)]
            )
        }

        migrator.registerMigration("v18_poll_window_seconds") { db in

            // ── poll_snapshots.primary_window_seconds ──────────────────────
            // The provider-reported width of the primary window, which every REV-59/REV-60 rule
            // is keyed on and which nothing persisted until now — **P1-28**, folded into
            // STEP_101 because the rule that reads it is what this step rewrites.
            //
            // Without it a launch-restored snapshot has no width at all, so until the first
            // successful poll lands `primaryWindowLength` falls back to five hours (§11 REV-60):
            // `primaryWindowStart` anchors attribution against a window 144x too short on a
            // 30-day plan, `DisplayFormatter.windowGrain` renders the bare `Used` instead of
            // `Weekly used`, `NotificationEngine.windowStart` buckets on the wrong width, and
            // the §11.3 shape backstop cannot fire because its first clause reads nil.
            //
            // Nullable, and NOT backfilled: `poll_snapshots` keeps two hours (§17), so existing
            // rows age out by themselves and read NULL until the next poll writes. Claude writes
            // NULL permanently — its usage endpoint reports no width (§8.0.2).
            try db.alter(table: "poll_snapshots") { t in
                t.add(column: "primary_window_seconds", .integer)
            }

            try db.execute(
                sql: "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, ?)",
                arguments: ["schema_version", "18", Int(Date().timeIntervalSince1970)]
            )
        }

        migrator.registerMigration("v19_fixture_session_cleanup") { db in

            // ── local corpus: delete seven fabricated Codex sessions ───────
            // REV-71 §3.4 / STEP_117. The fourth sanctioned exception to §17.2's permanent-table
            // rule (v11, v12, v16 precede it — same shape, same reasoning).
            //
            // Until STEP_117 the Codex watcher walked the whole of `~/.codex`. That reached a
            // Codex **worktree checkout of this repository** (`~/.codex/worktrees/4dda/`,
            // created 2026-07-03 14:16 CEST) and parsed AgentPilot's own Codex test fixtures as
            // though they were real sessions. Seven landed in the live database: 7 events,
            // ~335 input tokens, all stamped 2026-07-03. The identifiers below are verbatim from
            // `Tests/CodexAdapterTests/TestFixtures/CodexJSONL/*.jsonl` as that checkout had them.
            //
            // **Why deleting these does not violate REV-43.** That rule protects a *recorded
            // observation* from being rewritten. These are not observations of anything — they
            // are fixtures authored to exercise the parser, and no user work produced them.
            // Removing them converges the corpus toward ground truth, which is exactly the
            // argument that justified the v11, v12 and v16 deletions. The volume is trivial, so
            // nothing the user has read was materially wrong; what matters is that invented rows
            // do not sit in the corpus the whole pricing and attribution story rests on.
            //
            // Narrowing the watched root (`CodexLocalAdapter.defaultRoots`) prevents recurrence;
            // this removes what is already there. Bounded by the **exact seven ids** plus
            // `tool = 'codex'` — never a `LIKE` pattern, which could match a real session.
            let fabricatedSessionIds = [
                "codex-desktop-session",
                "codex-cli-session",
                "codex-ide-session",
                "codex-guardian-session",
                "codex-duplicate-session",
                "codex-top-level-session",
                "codex-sqlite-session",
            ]
            let placeholders = databaseQuestionMarks(count: fabricatedSessionIds.count)
            let arguments = StatementArguments(fabricatedSessionIds)

            // Events first, then the session rows. The FK cascades from `local_sessions`, so the
            // session delete alone would carry the events with it — doing both explicitly keeps
            // each logged count meaningful and does not depend on the migrator's FK settings.
            try db.execute(
                sql: """
                    DELETE FROM local_usage_events
                    WHERE tool = 'codex' AND session_id IN (\(placeholders))
                    """,
                arguments: arguments)
            Logger.info("Deleted fabricated fixture usage events", component: .sqliteStore,
                        metadata: ["deleted": "\(db.changesCount)",
                                   "migration": "v19_fixture_session_cleanup"])

            try db.execute(
                sql: """
                    DELETE FROM local_sessions
                    WHERE tool = 'codex' AND session_id IN (\(placeholders))
                    """,
                arguments: arguments)
            Logger.info("Deleted fabricated fixture sessions", component: .sqliteStore,
                        metadata: ["deleted": "\(db.changesCount)",
                                   "migration": "v19_fixture_session_cleanup"])

            // `session_summaries` is not named in REV-71 §3.4 and is deleted here deliberately.
            // The §17.2 retention pass upserts that receipt table *from* `local_sessions`, so once
            // the session rows above are gone these seven summaries can never be refreshed or
            // removed by any later pass — they would be orphaned invented data in a permanent
            // table, which is precisely what this migration exists to remove.
            try db.execute(
                sql: """
                    DELETE FROM session_summaries
                    WHERE tool = 'codex' AND session_id IN (\(placeholders))
                    """,
                arguments: arguments)
            Logger.info("Deleted fabricated fixture session summaries", component: .sqliteStore,
                        metadata: ["deleted": "\(db.changesCount)",
                                   "migration": "v19_fixture_session_cleanup"])

            // `history_rollups` is deliberately untouched: it aggregates `poll_snapshots`
            // (account quota percentages), not local token events, so none of the fabricated
            // tokens ever reached it.

            try db.execute(
                sql: "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, ?)",
                arguments: ["schema_version", "19", Int(Date().timeIntervalSince1970)]
            )
        }

        migrator.registerMigration("v20_time_limited_diagnostics") { db in
            // Earlier builds retained verbatim provider bodies for 48 hours and kept one body per
            // new shape permanently. Kvotar never carries those legacy bodies forward: shapes are
            // sufficient for drift history, and every future body requires visible 24-hour consent
            // plus the pre-storage safety filter.
            try db.execute(sql: "DELETE FROM raw_payloads")
            try db.execute(sql: """
                UPDATE poll_health_events
                SET response_headers_json = NULL, response_body = NULL
                """)
            let now = Int(Date().timeIntervalSince1970)
            try db.execute(
                sql: "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, ?)",
                arguments: [DiagnosticsCapture.settingsKey, "0", now])
            try db.execute(
                sql: "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, ?)",
                arguments: [DiagnosticsCapture.expiresAtSettingsKey, nil, now])
            try db.execute(
                sql: "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, ?)",
                arguments: ["schema_version", "20", now])
        }

        // REV-78 / UI Spec D-98 — three menu-bar display modes, not six. `adaptive`,
        // `compact_glyph` and `hidden` are retired.
        //
        // The runtime already copes without this: `MenuBarDisplayMode.init(rawValue:)` returns nil
        // for a retired string and `AppDelegate` falls through to the `.bothStacked` default. But
        // that fixes the screen, not the record — the row would keep saying `adaptive` forever, and
        // `settings_changes` would never see it. Four alpha builds shipped with all six modes named
        // in the tester guide, so retired values are in the field.
        migrator.registerMigration("v21_retire_menu_bar_modes") { db in
            let now = Int(Date().timeIntervalSince1970)
            // Raw SQL bypasses `writeSetting`, which is what normally appends the audit row — so
            // record the change explicitly. `settings_changes` is append-only and is where anyone
            // reading a diagnostics bundle looks to explain why the mode moved.
            try db.execute(sql: """
                INSERT INTO settings_changes (changed_at, key, old_value, new_value)
                SELECT \(now), key, value, 'both_stacked' FROM settings
                 WHERE key = 'menu_bar_display_mode'
                   AND value IN ('adaptive', 'compact_glyph', 'hidden')
                """)
            try db.execute(sql: """
                UPDATE settings SET value = 'both_stacked', updated_at = \(now)
                 WHERE key = 'menu_bar_display_mode'
                   AND value IN ('adaptive', 'compact_glyph', 'hidden')
                """)
            try db.execute(
                sql: "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, ?)",
                arguments: ["schema_version", "21", now])
        }

        // STEP_173 — the §12.2 Elsewhere split reads the same clock the `Local source` row reads.
        //
        // The retrospective split classified an interval by whether a `local_usage_events` row
        // landed inside it, and Codex writes a turn's `token_count` twenty to thirty minutes after
        // the work starts (§8.4, STEP_170). So a stretch the user worked straight through was
        // booked Elsewhere, under a row that correctly named the surface as active — on the alpha
        // tester's 2026-09-03 window, 61 of 95 points.
        //
        // One nullable column on the series the estimator already walks, rather than a new
        // write-mark table: it is interval-shaped, which is the shape the walk needs, and REV-43's
        // substrate principle asks for an argument before inventing a table. Each row carries the
        // §12 liveness timestamp as of that poll — the newest of {last local write, in-memory token
        // event, persisted event} — which is the exact value the burn card rendered its
        // `Local source` row from, so the row and the number cannot disagree.
        //
        // No backfill: file-write times were never recorded, so historic rows stay NULL and the
        // walk reads them as "no evidence", reproducing the pre-STEP_173 classification exactly.
        migrator.registerMigration("v22_quota_series_local_activity") { db in
            try db.alter(table: "quota_series") { t in
                t.add(column: "last_local_activity_at", .integer)
            }
            try db.execute(
                sql: "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, ?)",
                arguments: ["schema_version", "22", Int(Date().timeIntervalSince1970)])
        }

        // `quota_series.primary_window_seconds` — the provider-reported width of the window each
        // row belongs to (REV-93 §4 / D-115, STEP_181).
        //
        // The table records utilization and the reset anchor, which was enough for the narrow
        // last-window retrospective it was built for. It is not enough for Explore quota, which
        // charts thirty days of finished windows and must name each one's shape: Claude's five
        // hours and Codex's seven days are the same four columns on disk. The width is already
        // computed on every poll and already written to `poll_snapshots` (`v18`), but that table
        // is a two-hour forensic buffer — the number exists and then is purged, so no past window
        // can be labelled from it.
        //
        // No backfill, and the reader may never borrow a neighbour's width or the latest
        // snapshot's: pre-`v23` rows stay NULL and their windows read as unknown-width evidence.
        // Inheriting today's shape is exactly the fabrication REV-93 §4 forbids, and the
        // `HistoryReportReader` work-per-percent path is the precedent it was written against.
        migrator.registerMigration("v23_quota_series_window_seconds") { db in
            try db.alter(table: "quota_series") { t in
                t.add(column: "primary_window_seconds", .integer)
            }
            try db.execute(
                sql: "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, ?)",
                arguments: ["schema_version", "23", Int(Date().timeIntervalSince1970)])
        }

        // The forecast shadow substrate (REV-95 §3.1/§3.2, STEP_188) — ten nullable columns that
        // record what a later grading pass cannot reconstruct.
        //
        // `quota_series` keeps the weekly window beside the primary one. The series has always
        // stored the primary alone, so Spike D had to rebuild Claude's weekly history from two
        // tables (nine instances) and found five Codex long windows in seven weeks. Long windows
        // are the easier forecasting horizon and the unrecorded one.
        //
        // `forecast_log` keeps five slots for the §11.5 shadow outputs — written by STEP_190, NULL
        // until then — and the two exposure facts written from this build on. `displayed_state` is
        // what the app was showing when the prediction was written, and it is not a derived
        // conclusion the §17 substrate principle excludes: no later threshold can recompute what a
        // user already saw, and `state_transitions` cannot supply it past its 90-day retention.
        // Spike D F13 is why it matters — the owner slows down when warned, so a prediction made
        // under a visible warning has to be graded on its own scoreboard.
        //
        // Additive and nullable throughout: no backfill, no value inherited from a neighbouring
        // window, no index change — the STEP_181 rule. Every pre-`v24` row says what it always
        // said, which is nothing about any of this.
        migrator.registerMigration("v24_forecast_shadow_substrate") { db in
            try db.alter(table: "quota_series") { t in
                t.add(column: "secondary_used_pct", .double)
                t.add(column: "secondary_resets_at", .integer)
                t.add(column: "secondary_window_seconds", .integer)
            }
            try db.alter(table: "forecast_log") { t in
                t.add(column: "shadow_version", .text)
                t.add(column: "blend_rate_pct_per_min", .double)
                t.add(column: "rise_probability", .double)
                t.add(column: "rise_p10_pct", .double)
                t.add(column: "rise_p90_pct", .double)
                t.add(column: "displayed_state", .text)
                t.add(column: "warning_first_shown_at", .integer)
            }
            try db.execute(
                sql: "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, ?)",
                arguments: ["schema_version", "24", Int(Date().timeIntervalSince1970)])
        }

        // `model_limit_series` — the model allowances, kept (STEP_209).
        //
        // Since STEP_134 every poll has carried the model-scoped limits — Claude's `Fable` weekly,
        // Codex's `GPT-5.3-Codex-Spark` five-hour and weekly — and nothing stored them: the
        // snapshot drew the popover and the log line was the only record. On 2026-09-16 the Fable
        // weekly fell from 77 % used to 53 % between two polls two minutes apart, with no reset and
        // the all-models weekly unmoved, and that fact survived only in a log ring that rotates at
        // 5 MB. A provider-side change to an allowance is exactly what cannot be reconstructed later.
        //
        // A table rather than columns on `quota_series`: an account carries any number of model
        // allowances, each with one or two windows, and that series is selected by the *main*
        // primary window — a poll with no five-hour anchor writes nothing there, while a model
        // allowance is reported regardless. One row per poll per allowance per reported window.
        //
        // `limit_key` is the provider's id where one exists (Codex `codex_bengalfox`) and the
        // display name otherwise — Claude's `scope.model.id` is null on every capture, so its name
        // is the only handle. `window_slot` is `primary` / `secondary` (`window` is an SQL keyword).
        // Additive: nothing existing is touched, nothing is backfilled, the table is permanent.
        migrator.registerMigration("v25_model_limit_series") { db in
            try db.create(table: "model_limit_series") { t in
                t.column("tool", .text).notNull()
                t.column("polled_at", .integer).notNull()
                t.column("limit_key", .text).notNull()
                t.column("limit_id", .text)
                t.column("limit_name", .text)
                t.column("window_slot", .text).notNull()
                t.column("used_pct", .double)
                t.column("resets_at", .integer)
                t.column("window_seconds", .integer)
                t.primaryKey(["tool", "polled_at", "limit_key", "window_slot"])
            }
            try db.execute(
                sql: "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, ?)",
                arguments: ["schema_version", "25", Int(Date().timeIntervalSince1970)])
        }
    }

    /// `?, ?, ?` for an `IN` list of `count` bound values.
    private static func databaseQuestionMarks(count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }
}
