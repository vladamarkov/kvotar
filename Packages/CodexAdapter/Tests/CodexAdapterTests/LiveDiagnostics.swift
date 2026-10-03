import XCTest
import KvotarCore
@testable import CodexAdapter

/// Read-only live diagnostics for Codex usage tracking — run manually against the real machine
/// to validate Steps 8/9/10/11 on real data before the engines/CLI wire them together. Mirrors
/// `ClaudeAdapter/Tests/ClaudeAdapterTests/LiveDiagnostics.swift`.
///
/// Not part of the normal suite: every case is gated on `KVOTAR_LIVE=1` so CI and ordinary
/// `swift test` skip it. Nothing here writes, refreshes, or mutates anything — it spawns the real
/// Codex app-server (read-only sandbox flags, same as production), calls the real RPC/wham
/// endpoints, reads the real `~/.codex/auth.json` (passively), and parses the real `~/.codex/`
/// JSONL. Invoke with:
///
///     KVOTAR_LIVE=1 swift test --filter LiveDiagnostics
final class LiveDiagnostics: XCTestCase {

    private func requireLive() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KVOTAR_LIVE"] == "1",
                          "set KVOTAR_LIVE=1 to run live diagnostics")
    }

    // MARK: - Account: real RPC (app-server subprocess) -> wham fallback -> QuotaSnapshot

    func testLiveAccountSnapshot() async throws {
        try requireLive()

        let adapter = CodexAccountAdapter(
            rpc: CodexRPCClient(),
            wham: CodexWhamHTTPClient()
        )

        print("\n──────── Codex account snapshot (live RPC → wham) ────────")
        do {
            let s = try await adapter.fetchQuotaSnapshot()
            print("plan             : \(s.planType ?? "unknown")")
            print("email            : \(s.email == nil ? "none" : "<present, redacted>")")
            print("primary used     : \(fmtPct(s.primaryUsedPct))   resets: \(fmtDate(s.primaryResetsAt))")
            print("secondary used   : \(fmtPct(s.secondaryUsedPct))   resets: \(fmtDate(s.secondaryResetsAt))")
            print("null-window      : \(s.isNullWindow)")
            print("rateLimitReached : \(s.rateLimitReached.map(String.init(describing:)) ?? "nil")")
            print("spendControl     : \(s.spendControlReached.map(String.init(describing:)) ?? "nil")")
            if let m = s.monthlyLimit {
                print("monthlyLimit     : limit=\(m.limitAmount) used=\(m.usedAmount) "
                    + "remaining%=\(m.remainingPercent) resets=\(fmtDate(m.resetsAt)) "
                    + "source=\(m.source ?? "nil")")
                print("monthly derived  : used%exact=\(m.usedPercentExact.map { String(format: "%.2f", $0) } ?? "nil") "
                    + "pace/day=\(m.pacePerDay(now: Date()).map { String(format: "%.1f", $0) } ?? "nil")")
            } else {
                print("monthlyLimit     : nil (no monthly limit configured)")
            }
            print("bankedResets     : \(s.rateLimitResetCreditsCount.map(String.init) ?? "nil")")
            print("rate-limit hdrs  : limit=\(s.rateLimitLimit.map(String.init) ?? "n/a") "
                + "remaining=\(s.rateLimitRemaining.map(String.init) ?? "n/a")")
            let health = await adapter.health
            print("health           : \(health)")
        } catch AccountAdapterError.setupRequired {
            print("SETUP-REQUIRED: neither RPC nor wham could produce a credential/connection "
                + "(Codex binary missing, or `~/.codex/auth.json` unavailable).")
        } catch AccountAdapterError.reauthRequired {
            print("REAUTH-REQUIRED: token present but rejected (401/403).")
        } catch {
            print("ERROR: \(error)")
            throw error
        }
        print("─────────────────────────────────────────────────────────\n")
    }

    // MARK: - Account (wham only): direct live wham/usage call, bypassing RPC precedence

    /// `testLiveAccountSnapshot` above goes through `CodexAccountAdapter`'s RPC-first precedence —
    /// when RPC succeeds (the common case), `CodexWhamHTTPClient` is never exercised. This case
    /// calls it directly so the Step 10 live HTTP path (auth-header build from real
    /// `~/.codex/auth.json`, real network call, response decode) gets its own real-data proof.
    func testLiveWhamDirect() async throws {
        try requireLive()

        let client = CodexWhamHTTPClient()
        print("\n──────── Codex wham/usage snapshot (direct, bypasses RPC) ────────")
        do {
            let result = try await client.fetchUsage()
            print("plan             : \(result.usage.planType ?? "unknown")")
            print("email            : \(result.usage.email == nil ? "none" : "<present, redacted>")")
            print("rate_limit       : \(result.usage.rateLimit == nil ? "null (healthy idle)" : "present")")
            print("spendControl     : \(result.usage.spendControl?.reached.map(String.init) ?? "nil")")
            if let il = result.usage.spendControl?.individualLimit {
                // F4 proof: this object failing to decode used to kill the entire wham response.
                print("individual_limit : limit=\(il.limit ?? "nil") used=\(il.used ?? "nil") "
                    + "remaining%=\(il.remainingPercent.map(String.init) ?? "nil") "
                    + "reset_at=\(il.resetAt.map(String.init) ?? "nil") source=\(il.source ?? "nil")")
            } else {
                print("individual_limit : nil (no monthly limit configured)")
            }
            print("bankedResets     : \(result.usage.rateLimitResetCredits?.availableCount.map(String.init) ?? "nil")")
            print("rate-limit hdrs  : limit=\(result.headers.limit.map(String.init) ?? "n/a") "
                + "remaining=\(result.headers.remaining.map(String.init) ?? "n/a")")
        } catch AccountAdapterError.setupRequired {
            print("SETUP-REQUIRED: `~/.codex/auth.json` unavailable.")
        } catch AccountAdapterError.reauthRequired {
            print("REAUTH-REQUIRED: token present but rejected (401/403).")
        } catch {
            print("ERROR: \(error)")
            throw error
        }
        print("─────────────────────────────────────────────────────────────────\n")
    }

    // MARK: - Local: real ~/.codex JSONL -> parsed attribution

    func testLiveLocalAttribution() throws {
        try requireLive()

        let roots = CodexLocalAdapter.defaultRoots()
        let files = roots.flatMap { jsonlFiles(under: $0) }
        print("\n──────── Codex local attribution (live JSONL) ────────")
        print("roots : \(roots.map(\.path).joined(separator: ", "))")
        print("files : \(files.count)")

        let parser = CodexJSONLParser()
        let metadataReader = CodexSQLiteMetadataReader()

        var seen = Set<String>()
        var events: [TokenEvent] = []
        var sessionMetaFailures: [String] = []
        var emptyFiles = 0
        var sessionsWithModel = Set<String>()
        var sessionsWithoutModel = Set<String>()

        for file in files {
            guard let data = try? Data(contentsOf: file), !data.isEmpty else { emptyFiles += 1; continue }
            guard let newlineIndex = data.firstIndex(of: 0x0A) else {
                // Single-line file (or no trailing newline) — try treating the whole thing as
                // session_meta; if that fails it's just not a session file (e.g. session_index.jsonl).
                if parser.parseSessionMeta(data) == nil {
                    sessionMetaFailures.append(file.lastPathComponent)
                }
                continue
            }
            let firstLine = data[data.startIndex..<newlineIndex]
            let rest = data[data.index(after: newlineIndex)...]
            let resolved = parser.parseSessionMeta(Data(firstLine))
            if resolved == nil {
                sessionMetaFailures.append(file.lastPathComponent)
            }
            let sessionId = CodexLocalAdapter.sessionId(forFilePath: file.path)
            let metadata = metadataReader.threadMetadata(rolloutPath: file.path)
            if metadata?.model != nil { sessionsWithModel.insert(sessionId) }
            else { sessionsWithoutModel.insert(sessionId) }
            let batch = parser.parseTokenEvents(
                Data(rest), sessionId: sessionId,
                surfaceBucket: resolved?.surfaceBucket ?? CodexJSONLParser.surfaceUnknown,
                originator: resolved?.originator,
                sessionModel: metadata?.model, project: metadata?.cwd
            ).events
            for e in batch where seen.insert("\(e.sessionId)|\(e.dedupKey)").inserted {
                events.append(e)
            }
        }

        print("\nSQLite model attribution (Step 12): \(sessionsWithModel.count) sessions with model, "
            + "\(sessionsWithoutModel.count) without (state_5.sqlite row absent or unavailable)")
        print("goals_1.sqlite usage_limited     : \(metadataReader.hasUsageLimitedGoal())")

        var totals = Totals()
        var bySurface: [String: Totals] = [:]
        var byOriginator: [String: Int] = [:]
        var sessions = Set<String>()
        for e in events {
            totals.add(e)
            bySurface[e.surfaceBucket, default: Totals()].add(e)
            byOriginator[e.originator ?? "nil", default: 0] += 1
            sessions.insert(e.sessionId)
        }

        print("events (deduped): \(totals.count)   sessions: \(sessions.count)")
        print("empty files: \(emptyFiles)   session_meta unresolved: \(sessionMetaFailures.count)"
            + (sessionMetaFailures.isEmpty ? "" : " \(sessionMetaFailures.prefix(5))"))
        print("tokens  input=\(grp(totals.input)) output=\(grp(totals.output)) "
            + "cacheCreate=\(grp(totals.cacheCreate)) cacheRead=\(grp(totals.cacheRead))")
        print("\nby surface bucket:")
        for (k, t) in bySurface.sorted(by: { $0.value.total > $1.value.total }) {
            print("  \(k.padding(toLength: 20, withPad: " ", startingAt: 0)) "
                + "events=\(t.count)  total_tokens=\(grp(t.total))")
        }
        print("\nby originator:")
        for (k, c) in byOriginator.sorted(by: { $0.value > $1.value }) {
            print("  \(k.padding(toLength: 20, withPad: " ", startingAt: 0)) events=\(c)")
        }
        print("────────────────────────────────────────────────────\n")
    }

    // MARK: - Helpers

    private struct Totals {
        var count = 0, input = 0, output = 0, cacheCreate = 0, cacheRead = 0
        var total: Int { input + output + cacheCreate + cacheRead }
        mutating func add(_ e: TokenEvent) {
            count += 1
            input += e.inputTokens; output += e.outputTokens
            cacheCreate += e.cacheCreationTokens; cacheRead += e.cacheReadTokens
        }
    }

    private func jsonlFiles(under root: URL) -> [URL] {
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return en.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
    }

    private func fmtPct(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0) } ?? "—" }
    private func fmtDate(_ d: Date?) -> String { d.map { ISO8601DateFormatter().string(from: $0) } ?? "—" }
    private func grp(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
