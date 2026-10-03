import Foundation

/// Production `CodexProcessTransport` — wraps `Foundation.Process` + `Pipe` for the persistent
/// `codex ... app-server` subprocess (Baseline §8.1, §8.7). NDJSON stdout is split on newlines
/// (no Content-Length framing) and yielded as complete lines.
///
/// `@unchecked Sendable`: mutable process/stream state is confined behind `lock`; the stdout
/// `readabilityHandler` runs on a private `DispatchQueue`, not in an async context — this is the
/// reason `CodexRPCClient` is a `final class` rather than an actor (PATTERNS.md §Codex RPC client).
public final class CodexProcessTransportLive: CodexProcessTransport, @unchecked Sendable {

    /// Launch arguments locked by Baseline §8.1: read-only sandbox, never ask for approval.
    ///
    /// **`-a` was `untrusted` until 2026-09-09 and that value no longer exists.** codex 0.153.4
    /// answers it with `error: invalid value 'untrusted' for '--ask-for-approval'
    /// [possible values: on-request, never]` and exits before reading a byte of stdin. `never` is
    /// accepted by both 0.153.4 and the older 0.145.0, so it is the compatible choice; paired with
    /// `-s read-only` it also cannot escalate. Approval policy is close to moot for us either way —
    /// we send only `account/*` reads and never ask the child to run anything.
    static let launchArguments = ["-s", "read-only", "-a", "never", "app-server"]

    /// Cap on the retained stderr tail. We want the first error line, not a transcript.
    private static let stderrTailLimit = 2048

    private let lock = NSLock()
    private var process: Process?
    private var stdin: FileHandle?
    private var continuation: AsyncStream<String>.Continuation?
    private var buffer = Data()
    private var stderrTail = Data()
    /// Retained so `finish()` can detach both readability handlers. Left attached, they keep the
    /// descriptors alive across every crash-recovery restart — the REV-71 leak class.
    private var readHandles: [FileHandle] = []

    public init() {}

    public var isRunning: Bool {
        lock.withLock { process?.isRunning ?? false }
    }

    public func start(binary: URL) throws -> AsyncStream<String> {
        let process = Process()
        process.executableURL = binary
        process.arguments = Self.launchArguments

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        // stderr was inherited until 2026-09-09, which is why an argument-parse failure produced a
        // bare initialize timeout and the message naming the bad flag went nowhere. It must be
        // *drained*, not merely piped: an undrained pipe stalls the child once its 64 KB buffer
        // fills, which would be strictly worse than inheriting.
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        lock.withLock {
            self.process = process
            self.stdin = stdinPipe.fileHandleForWriting
            self.continuation = continuation
            self.buffer = Data()
            // Cleared here, not in `finish()` — the failure path reads the tail *after* the stream
            // has finished, which is the whole point of keeping it.
            self.stderrTail = Data()
            self.readHandles = [
                stdoutPipe.fileHandleForReading, stderrPipe.fileHandleForReading,
            ]
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.ingest(chunk)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.appendStderr(chunk)
        }
        process.terminationHandler = { [weak self] _ in
            self?.finish()
        }

        try process.run()
        return stream
    }

    public func send(_ line: String) throws {
        let handle = lock.withLock { stdin }
        guard let handle else { throw CocoaError(.fileWriteUnknown) }
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    public func terminate() {
        let process = lock.withLock { self.process }
        process?.terminate()
        finish()
    }

    // MARK: - stdout framing

    /// Appends bytes and yields any complete newline-delimited lines. Runs on the pipe's
    /// `DispatchQueue`; buffer access is locked so partial frames survive across chunks.
    private func ingest(_ chunk: Data) {
        let lines: [String] = lock.withLock {
            buffer.append(chunk)
            var out: [String] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let text = String(data: lineData, encoding: .utf8) {
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { out.append(trimmed) }
                }
            }
            return out
        }
        let continuation = lock.withLock { self.continuation }
        for line in lines { continuation?.yield(line) }
    }

    /// Keeps the last `stderrTailLimit` bytes the child wrote. Runs on the stderr pipe's own queue,
    /// which is not stdout's — so the critical section is an append and a trim and nothing else. It
    /// must never touch `continuation`: stderr bytes are diagnostics, and yielding them would feed
    /// non-NDJSON garbage into the client's line handler.
    private func appendStderr(_ chunk: Data) {
        lock.withLock {
            stderrTail.append(chunk)
            if stderrTail.count > Self.stderrTailLimit {
                stderrTail.removeFirst(stderrTail.count - Self.stderrTailLimit)
            }
        }
    }

    /// First non-empty stderr line since the last `start`, capped. Read by `CodexRPCClient` on the
    /// start/initialize failure path so a future argument break names itself.
    public var recentStderr: String? {
        let data = lock.withLock { stderrTail }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let first = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let first, !first.isEmpty else { return nil }
        return String(first.prefix(300))
    }

    private func finish() {
        let (continuation, handles) = lock.withLock {
            () -> (AsyncStream<String>.Continuation?, [FileHandle]) in
            let existing = self.continuation
            self.continuation = nil
            let open = self.readHandles
            self.readHandles = []
            return (existing, open)
        }
        for handle in handles { handle.readabilityHandler = nil }
        continuation?.finish()
    }
}
