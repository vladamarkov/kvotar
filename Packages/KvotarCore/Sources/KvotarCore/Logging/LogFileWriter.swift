import Foundation

/// Serial-queue-confined file writer for `Logger`'s file destination.
/// Not an actor — callers (`Logger.*`) must never await a log write (PATTERNS.md §Logger usage).
///
/// **Rotation is on size only (STEP_135).** The writer used to rotate on the first write of every
/// launch, five deep, so five launches erased the ring regardless of how little had been written —
/// Baseline §20 P1-24, which already cost one investigation (P1-23 is recorded as possibly
/// unanswerable because the logs that would settle it had rotated away). A launch now writes
/// `Logger.launchBanner` instead, which is the thing rotation was really being used to mark.
final class LogFileWriter: @unchecked Sendable {
    static let shared = LogFileWriter()

    private static let maxFileSizeBytes: UInt64 = 5 * 1024 * 1024
    /// Ten generations at 5 MB ≈ 5 weeks of history with DEBUG on, measured at ~58 KB/h on the
    /// dogfood machine (~38 KB/h with DEBUG off). Raised from 5 in STEP_135, once launch rotation
    /// stopped being the thing that consumed them.
    private static let maxRotatedFiles = 10

    private let queue = DispatchQueue(label: "com.vladimirmarkovic.kvotar.logfilewriter")
    private let fileManager = FileManager.default
    private let logDirectory: URL
    private let logFileURL: URL
    private let basename: String
    private var fileHandle: FileHandle?
    /// Inode the open `fileHandle` was created against. A *concurrent* instance rotating the ring
    /// renames the file out from under us, and an open handle follows the rename — so without this
    /// the older process keeps appending into a file already shifted down the ring — observed as
    /// generation 4 holding entries three hours newer than generation 1 (REV-13, 2026-08-09).
    private var fileInode: UInt64?

    /// - Parameter basename: log file stem (`<basename>.log`, rotated to `<basename>.<n>.log`).
    ///   The app writes `kvotar`; the CLI writes `kvotar-cli` (STEP_54).
    ///   `directory` is a test seam (STEP_239); every caller in the app takes the default.
    init(basename: String = ProductIdentity.logBasename, directory: URL? = nil) {
        // Path derivation lives in `Logger` (single source of truth) so the `logs` command reads
        // exactly the file this writer writes.
        self.logDirectory = directory ?? Logger.logDirectoryURL
        self.logFileURL = directory?.appendingPathComponent("\(basename).log")
            ?? Logger.logFileURL(basename: basename)
        self.basename = basename
    }

    /// Writes one record. Newlines and whitespace runs inside `line` are collapsed, so a record can
    /// never span file lines — see `Logger.singleLine`.
    func writeLine(_ line: String) {
        let record = Logger.singleLine(line)
        queue.async { [self] in
            ensureRotatedForSize()
            append(record)
        }
    }

    func writeRaw(_ line: String) {
        writeLine(line)
    }

    /// Test seam: runs `completion` once every write queued before this call has landed on disk.
    /// The queue is the synchronisation point and it is private, so there is no other way to know
    /// a fire-and-forget write finished.
    func drainForTesting(_ completion: @escaping () -> Void) {
        queue.async { completion() }
    }

    private func ensureRotatedForSize() {
        if !fileManager.fileExists(atPath: logDirectory.path) {
            try? fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        }

        guard let attributes = try? fileManager.attributesOfItem(atPath: logFileURL.path) else {
            // The path is gone (deleted, or rotated away by another instance). Drop the stale
            // handle so `append` recreates the file rather than writing into an unlinked inode.
            closeHandle()
            return
        }
        // Free with the stat we already performed: if the path now names a different inode than the
        // handle we hold, someone else rotated underneath us and our handle is following the old
        // file down the ring.
        if let held = fileInode, let current = Self.inode(from: attributes), held != current {
            closeHandle()
        }
        guard let size = attributes[.size] as? UInt64, size > Self.maxFileSizeBytes else { return }
        rotate()
    }

    private static func inode(from attributes: [FileAttributeKey: Any]) -> UInt64? {
        (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    private func closeHandle() {
        fileHandle?.closeFile()
        fileHandle = nil
        fileInode = nil
    }

    private func rotate() {
        closeHandle()

        let rotatedURL = { (index: Int) in
            self.logDirectory.appendingPathComponent("\(self.basename).\(index).log")
        }

        let oldestURL = rotatedURL(Self.maxRotatedFiles)
        if fileManager.fileExists(atPath: oldestURL.path) {
            try? fileManager.removeItem(at: oldestURL)
        }

        var index = Self.maxRotatedFiles - 1
        while index >= 1 {
            let source = rotatedURL(index)
            let destination = rotatedURL(index + 1)
            if fileManager.fileExists(atPath: source.path) {
                try? fileManager.moveItem(at: source, to: destination)
            }
            index -= 1
        }

        if fileManager.fileExists(atPath: logFileURL.path) {
            try? fileManager.moveItem(at: logFileURL, to: rotatedURL(1))
        }
    }

    /// Opened `O_APPEND`, which is load-bearing rather than a detail: **two live instances share one
    /// file** — that is what the §9.2 process guard is about, and why every line carries its PID.
    ///
    /// `FileHandle(forWritingTo:)` does not set it. Each handle then carries its own offset, so a
    /// seek-to-end captured at open time goes stale the moment the *other* process appends, and the
    /// next write lands back inside the file, overwriting whatever is there. Observed 2026-08-24: a
    /// blocked second instance logged `CRITICAL Another compatible instance is already running` and
    /// the line never reached the file, because the primary kept polling and wrote over it — the
    /// guard's one forensic record lost in exactly the situation it documents.
    ///
    /// With `O_APPEND` the kernel positions every write at the current end, so concurrent writers
    /// interleave whole lines instead of clobbering each other. The offset is no longer ours to
    /// track, so there is nothing to seek.
    private func append(_ line: String) {
        if fileHandle == nil {
            let descriptor = Darwin.open(logFileURL.path,
                                         O_WRONLY | O_CREAT | O_APPEND,
                                         S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
            guard descriptor >= 0 else { return }
            fileHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            fileInode = (try? fileManager.attributesOfItem(atPath: logFileURL.path))
                .flatMap(Self.inode(from:))
        }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        fileHandle?.write(data)
    }
}
