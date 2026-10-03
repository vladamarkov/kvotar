import Foundation
import KvotarCore

/// Injectable transport over the Codex `app-server` subprocess (Baseline §8.1, §8.7;
/// PATTERNS.md §Codex RPC client). Mirrors the Claude `HTTPFetcher` seam so `CodexRPCClient`
/// can be unit-tested with a scripted fake — production wraps `Foundation.Process` + `Pipe`.
///
/// A fresh line stream is returned per `start(binary:)` so the client can restart the process
/// after a crash and consume a new stdout stream (§8.7 crash recovery).
public protocol CodexProcessTransport: Sendable {
    /// Spawns the process for `binary` and returns a stream of complete NDJSON stdout lines.
    /// The stream finishes when the process exits (the client's crash-recovery signal).
    func start(binary: URL) throws -> AsyncStream<String>

    /// Writes one NDJSON line to the process stdin (newline appended by the implementation).
    func send(_ line: String) throws

    /// Whether the underlying process is currently running.
    var isRunning: Bool { get }

    /// Terminates the process and finishes the stdout stream.
    func terminate()

    /// The tail of the child's stderr since the last `start`, for the failure log only — never a
    /// data source. Defaulted so scripted fakes need not implement it.
    var recentStderr: String? { get }
}

public extension CodexProcessTransport {
    var recentStderr: String? { nil }
}

/// One-poll RPC surface consumed by `CodexAccountAdapter` (task Step 9). Injected as a protocol
/// so the adapter can be unit-tested with a scripted fake instead of a live `app-server` process.
/// `CodexRPCClient` is the production conformance.
public protocol CodexRPCPolling: Sendable {
    /// Spawns + initializes the process if needed (idempotent).
    func start() async throws
    /// One poll: `account/read` then `account/rateLimits/read` (Baseline §8.7).
    func poll() async throws -> (account: CodexAccountRead, rateLimits: CodexRateLimits)
    /// Terminates the process and fails any in-flight calls.
    func shutdown()
}

/// Resolves the `codex` binary path (Baseline §8.6). Injected so tests avoid disk/PATH lookups.
public protocol CodexBinaryLocator: Sendable {
    /// The binary, plus every path that was examined to find it. `url` is nil when no candidate is
    /// executable and `codex` is not on PATH — the caller then marks the adapter unavailable and
    /// falls through to wham/usage.
    func locate() -> CodexBinaryCandidates.Resolution
}

/// Default discovery (Baseline §8.6): the candidate list in `CodexBinaryCandidates`, then
/// `which codex`.
///
/// **Stateless on purpose.** Caching the result belongs to `CodexRPCClient`, which already owns an
/// `NSLock` for exactly this kind of cross-call state (PATTERNS.md §Codex RPC client, Decision 6);
/// making this a stateful class would add a third lock-guarded type to the package and force every
/// test that builds one to reason about its lifetime.
public struct DefaultCodexBinaryLocator: CodexBinaryLocator {

    /// Resolves Codex Desktop's bundle identifier to its app URL. Supplied by the App target, which
    /// may import AppKit; nil inside the package, which may not. A bundle found this way wins over
    /// every literal path, which is what makes discovery survive the next time the app is renamed
    /// or moved out of `/Applications`.
    private let appBundleURL: @Sendable () -> URL?
    private let isExecutable: @Sendable (String) -> Bool
    private let home: URL

    public init(
        appBundleURL: @escaping @Sendable () -> URL? = { nil },
        isExecutable: @escaping @Sendable (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        },
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.appBundleURL = appBundleURL
        self.isExecutable = isExecutable
        self.home = home
    }

    public func locate() -> CodexBinaryCandidates.Resolution {
        let resolved = CodexBinaryCandidates.firstExecutable(
            appBundle: appBundleURL(), home: home, isExecutable: isExecutable)
        if resolved.url != nil { return resolved }

        // Last resort, and rarely useful in production: a GUI-launched app inherits the `/etc/paths`
        // default, which has none of the directories a standalone Codex install writes into.
        guard let onPath = Self.which("codex") else { return resolved }
        return CodexBinaryCandidates.Resolution(
            url: onPath, searched: resolved.searched + ["which codex"])
    }

    /// `which <name>` via `/usr/bin/env`; nil when not found. Covers exotic PATH installs.
    ///
    /// **A lookup that could not run is logged as such (STEP_117 / REV-71 §2.4, §3.2).** Launching
    /// this needs a `Process` and two `Pipe`s — four file descriptors — so when the process table
    /// was exhausted on 2026-08-17 the launch threw and the app reported "Codex binary not found"
    /// for a binary that the same lookup had located successfully twelve hours earlier. The return
    /// value is unchanged (`nil` either way, and the RPC path falls through to wham/usage
    /// regardless): this is logging honesty, so a future occurrence is diagnosable.
    static func which(_ name: String) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", name]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            Logger.warning("Codex binary lookup could not be attempted — `which` failed to launch",
                           component: .codexAccountAdapter,
                           metadata: ["name": name, "error": "\(error)"])
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}
