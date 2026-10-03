import XCTest
import KvotarCore
@testable import ClaudeAdapter

/// Read-only live diagnostics for Claude usage tracking — run manually against the real machine
/// to validate Steps 6/7 on real data before the engines/CLI wire them together.
///
/// Not part of the normal suite: every case is gated on `KVOTAR_LIVE=1` so CI and ordinary
/// `swift test` skip it. Nothing here writes, refreshes, or mutates anything — it reads the live
/// Keychain token (silently, never prompting), calls the real OAuth usage/profile endpoints, and
/// parses the real `~/.claude/projects` JSONL. Invoke with:
///
///     KVOTAR_LIVE=1 swift test --filter LiveDiagnostics
final class LiveDiagnostics: XCTestCase {

    private func requireLive() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KVOTAR_LIVE"] == "1",
                          "set KVOTAR_LIVE=1 to run live diagnostics")
    }

    // MARK: - Account: real Keychain token → real OAuth usage/profile

    func testLiveAccountSnapshot() async throws {
        try requireLive()

        let adapter = ClaudeAccountAdapter(
            tokenProvider: KeychainTokenProvider(),
            fetcher: URLSessionFetcher()
        )

        print("\n──────── Claude account snapshot (live OAuth) ────────")
        do {
            let s = try await adapter.fetchQuotaSnapshot()
            print("plan             : \(s.planType ?? "unknown")")
            print("email            : \(s.email == nil ? "none" : "<present, redacted>")")
            print("5-hour used      : \(fmtPct(s.primaryUsedPct))   resets: \(fmtDate(s.primaryResetsAt))")
            print("Weekly used      : \(fmtPct(s.secondaryUsedPct))   resets: \(fmtDate(s.secondaryResetsAt))")
            print("rateLimitReached : \(s.rateLimitReached.map(String.init(describing:)) ?? "nil")")
            if let extra = s.extraUsage {
                let used = extra.usedCredits.map { "\($0)" } ?? "nil"
                let util = fmtPct(extra.utilization)
                let cur = extra.currency ?? "nil"
                print("extra_usage      : enabled=\(extra.isEnabled) used=\(used) util=\(util) cur=\(cur)")
            } else {
                print("extra_usage      : absent (no pay-as-you-go)")
            }
            if let prepaid = s.prepaid {
                let amt = prepaid.amountCents.map { "\($0)¢" } ?? "nil"
                let ar = prepaid.autoReloadOn.map { $0 ? "on" : "off" } ?? "nil"
                print("prepaid          : amount=\(amt) auto_reload=\(ar)")
            }
            print("rate-limit hdrs  : limit=\(s.rateLimitLimit.map(String.init) ?? "n/a") "
                + "remaining=\(s.rateLimitRemaining.map(String.init) ?? "n/a")")
            let health = await adapter.health
            print("health           : \(health)")
        } catch AccountAdapterError.setupRequired {
            print("SETUP-REQUIRED: `/usr/bin/security` could not read `Claude Code-credentials` "
                + "(item absent, or `security` is no longer the trusted app on its ACL). "
                + "Adapter fell back to JSONL-only mode.")
        } catch AccountAdapterError.reauthRequired {
            print("REAUTH-REQUIRED: token present but rejected (401/403).")
        } catch {
            print("ERROR: \(error)")
            throw error
        }
        print("──────────────────────────────────────────────────────\n")
    }

    // MARK: - Local: real ~/.claude/projects JSONL → parsed attribution

    func testLiveLocalAttribution() async throws {
        try requireLive()

        let root = ClaudeLocalAdapter.defaultRoot()
        let files = jsonlFiles(under: root)
        print("\n──────── Claude local attribution (live JSONL) ────────")
        print("root  : \(root.path)")
        print("files : \(files.count)")

        let parser = ClaudeJSONLParser()

        // Dedup by (sessionId, dedupKey) to mirror what the DB composite PK would actually store.
        var seen = Set<String>()
        var events: [TokenEvent] = []
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            for e in parser.parse(data) where seen.insert("\(e.sessionId)|\(e.dedupKey)").inserted {
                events.append(e)
            }
        }

        var totals = Totals()
        var bySurface: [String: Totals] = [:]
        var byModel: [String: Totals] = [:]
        var sessions = Set<String>()
        var projects = Set<String>()
        for e in events {
            totals.add(e)
            bySurface[e.surfaceBucket, default: Totals()].add(e)
            byModel[e.model ?? "unknown", default: Totals()].add(e)
            sessions.insert(e.sessionId)
            if let p = e.project { projects.insert(p) }
        }

        print("events (deduped): \(totals.count)   sessions: \(sessions.count)   projects: \(projects.count)")
        print("tokens  input=\(grp(totals.input)) output=\(grp(totals.output)) "
            + "cacheCreate=\(grp(totals.cacheCreate)) cacheRead=\(grp(totals.cacheRead))")
        print("\nby surface bucket:")
        for (k, t) in bySurface.sorted(by: { $0.value.total > $1.value.total }) {
            print("  \(k.padding(toLength: 26, withPad: " ", startingAt: 0)) "
                + "events=\(t.count)  total_tokens=\(grp(t.total))")
        }
        print("\nby model:")
        for (k, t) in byModel.sorted(by: { $0.value.total > $1.value.total }) {
            print("  \(k.padding(toLength: 26, withPad: " ", startingAt: 0)) "
                + "events=\(t.count)  total_tokens=\(grp(t.total))")
        }
        print("──────────────────────────────────────────────────────\n")

        XCTAssertFalse(events.isEmpty, "expected at least one parsed assistant event in real JSONL")
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
