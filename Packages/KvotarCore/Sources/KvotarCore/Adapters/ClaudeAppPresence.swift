import Foundation
import Darwin

/// Metadata only. The same detector serves connection eligibility and diagnostics; cache values
/// never leave this read. Roots are injectable so tests never inspect a real Claude installation.
public struct ClaudeAppPresence: Sendable, Equatable {
    public enum Presence: String, Sendable { case present, absent, unknown }
    public struct Folder: Sendable, Equatable {
        public var presence: Presence
        public var files: Int?
        public var capped: Bool
        public init(_ presence: Presence, files: Int? = nil, capped: Bool = false) {
            self.presence = presence; self.files = files; self.capped = capped
        }
        public var description: String {
            guard let files else { return presence.rawValue }
            return "\(presence.rawValue), \(files)\(capped ? "+" : "") files"
        }
    }
    public var app: Presence = .unknown
    public var version: String?
    public var config: Presence = .unknown
    public var cacheMarker: Presence = .unknown
    public var codeSessions = Folder(.unknown)
    public var agentSessions = Folder(.unknown)
    public init() {}
    public var canConnect: Bool { app == .present && config == .present && cacheMarker == .present }
    public var diagnosticsLines: [String] {
        ["  Claude.app:           \(app.rawValue), version \(version ?? "unknown")",
         "  config.json:          \(config.rawValue)",
         "  OAuth cache marker:   \(cacheMarker.rawValue)",
         "  claude-code-sessions: \(codeSessions.description)",
         "  local-agent-mode-sessions: \(agentSessions.description)"]
    }
}

public struct ClaudeAppDetector: Sendable {
    public static let configByteCap = 8 * 1024 * 1024
    public let applicationURL: URL
    public let supportURL: URL
    public let fileCap: Int

    public init(applicationURL: URL = URL(fileURLWithPath: "/Applications/Claude.app"),
                supportURL: URL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/Claude"), fileCap: Int = 1_000) {
        self.applicationURL = applicationURL; self.supportURL = supportURL
        self.fileCap = max(1, fileCap)
    }

    public func detect() -> ClaudeAppPresence {
        var result = ClaudeAppPresence()
        result.app = presence(applicationURL, directory: true)
        if result.app == .present {
            let contents = applicationURL.appendingPathComponent("Contents")
            if presence(contents, directory: true) == .present,
               let bytes = try? Self.readBoundedFile(contents.appendingPathComponent("Info.plist"), cap: 64 * 1024),
               let plist = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
               let version = plist["CFBundleShortVersionString"] as? String,
               version.count <= 64, !version.isEmpty,
               version.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) {
                result.version = version
            }
        }
        let support = presence(supportURL, directory: true)
        guard support == .present else {
            result.config = support; result.cacheMarker = support
            result.codeSessions = .init(support); result.agentSessions = .init(support)
            return result
        }
        let configURL = supportURL.appendingPathComponent("config.json")
        result.config = presence(configURL, directory: false)
        if result.config == .present {
            if let data = try? Self.readBoundedFile(configURL, cap: Self.configByteCap) {
                result.cacheMarker = ["\"oauth:tokenCacheV2\"", "\"oauth:tokenCache\""]
                    .contains { data.range(of: Data($0.utf8)) != nil } ? .present : .absent
            }
        } else { result.cacheMarker = result.config }
        result.codeSessions = folder(supportURL.appendingPathComponent("claude-code-sessions"))
        result.agentSessions = folder(supportURL.appendingPathComponent("local-agent-mode-sessions"))
        return result
    }

    private func presence(_ url: URL, directory: Bool) -> ClaudeAppPresence.Presence {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return errno == ENOENT ? .absent : .unknown }
        let kind = info.st_mode & S_IFMT
        return kind == (directory ? S_IFDIR : S_IFREG) ? .present : .unknown
    }

    private func folder(_ root: URL) -> ClaudeAppPresence.Folder {
        let state = presence(root, directory: true)
        guard state == .present else { return .init(state) }
        var files = 0, visited = 0, capped = false
        func walk(_ fd: Int32) -> Bool {
            guard let directory = fdopendir(fd) else { close(fd); return false }
            defer { closedir(directory) }
            errno = 0
            while let entry = readdir(directory) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                visited += 1
                if visited > fileCap { capped = true; return true }
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
                switch info.st_mode & S_IFMT {
                case S_IFREG: files += 1
                case S_IFDIR:
                    let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                    guard child >= 0, walk(child) else { return false }
                    if capped { return true }
                case S_IFLNK: break
                default: return false
                }
                errno = 0
            }
            return errno == 0
        }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0, walk(fd) else { return .init(.unknown) }
        return .init(.present, files: files, capped: capped)
    }

    public enum ReadError: Error { case unavailable }

    /// Opens the final component without following a symlink and caps allocation before reading.
    /// The caller checks its fixed parent directory; no user-supplied paths are accepted in production.
    public static func readBoundedFile(_ url: URL, cap: Int) throws -> Data {
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw ReadError.unavailable }
        defer { close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ReadError.unavailable }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= cap else { throw ReadError.unavailable }
        var data = Data(count: Int(before.st_size))
        let count = data.count
        let readCount = data.withUnsafeMutableBytes { bytes in
            Darwin.read(fd, bytes.baseAddress, count)
        }
        var after = stat()
        guard readCount == count, fstat(fd, &after) == 0,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw ReadError.unavailable }
        return data
    }
}
