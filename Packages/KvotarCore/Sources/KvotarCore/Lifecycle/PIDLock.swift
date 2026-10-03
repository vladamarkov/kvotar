import Foundation
import Darwin

/// Cross-process single-instance guard backed by an advisory lock plus the legacy PID text format.
///
/// Kvotar instances coordinate through an advisory file lock, which closes the old read-then-write
/// race. The PID
/// remains in the file because released AgentPilot builds only understand that format; when Kvotar
/// holds the legacy compatibility path, an old app sees Kvotar's live PID and refuses to poll.
public final class PIDLock {
    public enum Acquisition: Equatable {
        case acquired
        case alreadyRunning(pid: Int32)
    }

    public let path: String
    private var descriptor: Int32 = -1

    public init(path: String) { self.path = path }

    deinit { release() }

    public static func defaultPath(fileManager: FileManager = .default) throws -> String {
        try ProductIdentity.applicationSupportDirectory(fileManager: fileManager, create: true)
            .appendingPathComponent(ProductIdentity.pidFilename).path
    }

    /// Returns the compatibility path only when AgentPilot has created its support folder. A clean
    /// Kvotar install never creates legacy storage merely to guard an app that was not there.
    public static func legacyCompatibilityPath(fileManager: FileManager = .default) -> String? {
        let directory = ProductIdentity.legacyApplicationSupportDirectory(fileManager: fileManager)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return directory.appendingPathComponent(ProductIdentity.Legacy.pidFilename).path
    }

    public func acquire() -> Acquisition {
        if descriptor >= 0 { return .acquired }
        let fd = Darwin.open(path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            Logger.error("Failed to open PID lock", component: .appLifecycle,
                         metadata: ["error": "\(errno)"])
            return .alreadyRunning(pid: -1)
        }

        guard Darwin.lockf(fd, F_TLOCK, 0) == 0 else {
            let existing = readPID() ?? -1
            Darwin.close(fd)
            logAlreadyRunning(existing)
            return .alreadyRunning(pid: existing)
        }

        let me = ProcessInfo.processInfo.processIdentifier
        if let existing = readPID(), existing != me, Self.isProcessAlive(existing) {
            _ = Darwin.lockf(fd, F_ULOCK, 0)
            Darwin.close(fd)
            logAlreadyRunning(existing)
            return .alreadyRunning(pid: existing)
        }

        guard write(pid: me, to: fd) else {
            _ = Darwin.lockf(fd, F_ULOCK, 0)
            Darwin.close(fd)
            return .alreadyRunning(pid: -1)
        }
        descriptor = fd
        return .acquired
    }

    public func release() {
        guard descriptor >= 0 else { return }
        let fd = descriptor
        descriptor = -1
        if readPID() == ProcessInfo.processInfo.processIdentifier {
            try? FileManager.default.removeItem(atPath: path)
        }
        _ = Darwin.lockf(fd, F_ULOCK, 0)
        Darwin.close(fd)
    }

    private func readPID() -> Int32? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func write(pid: Int32, to fd: Int32) -> Bool {
        guard Darwin.ftruncate(fd, 0) == 0, Darwin.lseek(fd, 0, SEEK_SET) >= 0 else {
            Logger.error("Failed to prepare PID lock", component: .appLifecycle,
                         metadata: ["error": "\(errno)"])
            return false
        }
        let data = Data("\(pid)".utf8)
        let written = data.withUnsafeBytes { bytes in
            Darwin.write(fd, bytes.baseAddress, bytes.count)
        }
        guard written == data.count else {
            Logger.error("Failed to write PID lock", component: .appLifecycle,
                         metadata: ["error": "\(errno)"])
            return false
        }
        _ = Darwin.fsync(fd)
        return true
    }

    private func logAlreadyRunning(_ pid: Int32) {
        Logger.critical("Another compatible instance is already running",
                        component: .appLifecycle, metadata: ["pid": "\(pid)"])
    }

    static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
