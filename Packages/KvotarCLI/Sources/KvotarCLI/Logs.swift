import ArgumentParser
import Foundation
import KvotarCore

/// `kvotar logs` — read the running app's forensic log (`~/Library/Logs/Kvotar/kvotar.log`),
/// with composable filters and an optional live tail. Pure file access; the database is never
/// touched (§10.8). Reads the *app's* log, not the CLI's own `kvotar-cli.log`.
///
/// Filters compose (AND); `--follow` layers on top of any filter set. Default (no flags) is the last
/// 100 lines. **Limitation:** reads only the current `kvotar.log`, not rotated
/// `kvotar.<n>.log` siblings, so `--since`/tail can under-cover right after a rotation.
struct Logs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Read Kvotar's log file (filter, tail, or follow).")

    /// Non-follow tail size and follow's initial context dump.
    private static let tailCount = 100

    @OptionGroup var global: GlobalOptions

    @Flag(name: .long, help: "Stream new lines as they are appended (like tail -f). Runs until interrupted.")
    var follow = false

    @Option(name: .long, help: "Show only lines at this level or higher: debug|info|warning|error|critical.")
    var level: String?

    @Option(name: .long, help: "Show only lines from this component, e.g. PollEngine.")
    var component: String?

    @Option(name: .long, help: "Show only lines whose metadata includes tool=<value>: claude|codex.")
    var tool: String?

    @Option(name: .long, help: "Show only lines from the last N minutes, e.g. 30m.")
    var since: String?

    func run() async throws {
        CLIRuntime.bootstrap()
        let filter = try LogFilter(level: level, component: component, tool: tool, since: since)
        let fileURL = Logger.logFileURL()   // the app's kvotar.log

        guard let data = try? Data(contentsOf: fileURL) else {
            FileHandle.standardError.write(
                Data("No log file at \(fileURL.path) — has Kvotar run?\n".utf8))
            throw ExitCode.failure
        }

        // Tail: filter the whole file, then emit the last N matching lines.
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        for raw in lines.filter({ filter.matches(LogLine.parse($0)) }).suffix(Self.tailCount) {
            emit(raw)
        }

        guard follow else { return }
        // Continue from exactly the bytes we just consumed so no line is duplicated or skipped.
        try await followLoop(fileURL: fileURL, startOffset: UInt64(data.count), filter: filter)
    }

    /// Parse, filter, and print one raw line (human = verbatim; `--json` = one compact JSON object).
    private func emit(_ raw: String) {
        guard global.json else {
            Swift.print(raw)
            return
        }
        Swift.print(LogLine.parse(raw).jsonLine)
    }

    /// Tail-follow: poll the file for appended bytes, splitting on newlines with a residual carry so
    /// a line split across two appends is never emitted half-formed. A file that shrinks (truncation,
    /// or a move-and-recreate rotation) is detected and re-read from the start.
    private func followLoop(fileURL: URL, startOffset: UInt64, filter: LogFilter) async throws {
        guard var handle = try? FileHandle(forReadingFrom: fileURL) else { return }
        defer { try? handle.close() }
        var offset = startOffset
        var residual = ""

        while true {
            try await Task.sleep(nanoseconds: 500_000_000)

            let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            let size = (attrs?[.size] as? UInt64) ?? offset
            if size < offset {   // truncated or rotated out from under us — reopen and start over
                try? handle.close()
                guard let fresh = try? FileHandle(forReadingFrom: fileURL) else { continue }
                handle = fresh
                offset = 0
                residual = ""
            }
            guard size > offset else { continue }

            try? handle.seek(toOffset: offset)
            let chunk = handle.readDataToEndOfFile()
            offset += UInt64(chunk.count)
            residual += String(decoding: chunk, as: UTF8.self)

            while let nl = residual.firstIndex(of: "\n") {
                let line = String(residual[..<nl])
                residual = String(residual[residual.index(after: nl)...])
                if !line.isEmpty, filter.matches(LogLine.parse(line)) { emit(line) }
            }
        }
    }
}

// MARK: - Line parsing

/// A parsed `Logger` file line. Structured lines carry timestamp/level/component/metadata; bare
/// marker lines (e.g. `[DEBUG MODE]`) parse as unstructured with `raw` only.
struct LogLine {
    let raw: String
    let timestamp: Date?
    let timestampText: String?
    let level: LogLevel?
    /// Writing process (STEP_135). Nil on lines written before the PID entered the prefix — the
    /// ring holds both grammars until ten generations have turned over, so both must parse.
    let pid: Int?
    let component: String?
    let message: String?
    let metadata: [String: String]

    /// A line the grammar recognized fully — has timestamp, level, and component.
    var isStructured: Bool { timestamp != nil && level != nil && component != nil }

    /// Grammar: `<ISO8601Z> [LEVEL␣padded][pid][Component] message[ · k=v k=v …]`, with `[pid]`
    /// optional so pre-STEP_135 generations still parse. Returns an unstructured value (raw only)
    /// for anything that doesn't match — never throws.
    static func parse(_ raw: String) -> LogLine {
        let unstructured = LogLine(raw: raw, timestamp: nil, timestampText: nil, level: nil,
                                   pid: nil, component: nil, message: nil, metadata: [:])

        // 1. timestamp = leading token up to the first space.
        guard let firstSpace = raw.firstIndex(of: " ") else { return unstructured }
        let tsText = String(raw[..<firstSpace])
        guard let ts = Self.parseTimestamp(tsText) else { return unstructured }
        var rest = raw[raw.index(after: firstSpace)...]

        // 2. [LEVEL] — first bracket group.
        guard let level = Self.takeBracket(&rest).flatMap(Self.parseLevel) else { return unstructured }
        // 3. [pid] — optional, all-digits. A component name never is, so the two can never be
        //    confused and a pre-STEP_135 line simply skips this step.
        guard var next = Self.takeBracket(&rest) else { return unstructured }
        var pid: Int?
        if let parsed = Int(next), next.allSatisfy(\.isNumber), !next.isEmpty {
            pid = parsed
            guard let component = Self.takeBracket(&rest) else { return unstructured }
            next = component
        }

        // 4. message + optional ` · k=v …` metadata.
        let tail = rest.hasPrefix(" ") ? String(rest.dropFirst()) : String(rest)
        let (message, metadata) = Self.splitMessageAndMetadata(tail)

        return LogLine(raw: raw, timestamp: ts, timestampText: tsText, level: level,
                       pid: pid, component: next, message: message, metadata: metadata)
    }

    /// Consumes the next `[...]` group from `slice` (skipping any leading spaces from level padding)
    /// and returns its contents, advancing `slice` past the closing `]`.
    private static func takeBracket(_ slice: inout Substring) -> String? {
        while slice.first == " " { slice = slice.dropFirst() }
        guard slice.first == "[", let close = slice.firstIndex(of: "]") else { return nil }
        let contents = String(slice[slice.index(after: slice.startIndex)..<close])
        slice = slice[slice.index(after: close)...]
        return contents
    }

    private static func splitMessageAndMetadata(_ tail: String) -> (String, [String: String]) {
        guard let range = tail.range(of: " · ") else { return (tail, [:]) }
        let message = String(tail[..<range.lowerBound])
        let blob = tail[range.upperBound...]
        var metadata: [String: String] = [:]
        for token in Self.metadataTokens(blob) {
            guard let eq = token.firstIndex(of: "=") else { continue }
            metadata[String(token[..<eq])] = Self.unquote(String(token[token.index(after: eq)...]))
        }
        return (message, metadata)
    }

    /// Splits the `k=v` blob on spaces **outside double quotes**. `Logger.metadataValue` quotes any
    /// value containing a space, because a plain space split silently mis-read them: the live log's
    /// `error=unable to open database file table=thread_goals` parsed as `error=unable` and dropped
    /// the rest. Pre-STEP_135 lines carry the unquoted form and still parse the old way — badly, but
    /// no worse than before, and the ring holds them for weeks.
    private static func metadataTokens(_ blob: Substring) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for character in blob {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\", inQuotes {
                current.append(character)
                escaped = true
            } else if character == "\"" {
                inQuotes.toggle()
                current.append(character)
            } else if character == " ", !inQuotes {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func parseLevel(_ label: String) -> LogLevel? {
        switch label.lowercased() {
        case "debug": return .debug
        case "info": return .info
        case "warning": return .warning
        case "error": return .error
        case "critical": return .critical
        default: return nil
        }
    }

    /// ISO8601 with fractional seconds, matching `Logger.timestamp()`. `ISO8601DateFormatter` is not
    /// `Sendable`, so it's built per call (same constraint the adapters observe).
    static func parseTimestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    /// Compact single-line JSON for `--json` (JSONL — one object per line, stream-friendly).
    var jsonLine: String {
        struct Entry: Encodable {
            let timestamp: String?
            let level: String?
            let pid: Int?
            let component: String?
            let message: String?
            let metadata: [String: String]?
        }
        let entry = Entry(
            timestamp: timestampText,
            level: level.map(String.init(describing:)),
            pid: pid,
            component: component,
            message: isStructured ? message : raw,
            metadata: metadata.isEmpty ? nil : metadata)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(entry),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}

// MARK: - Filtering

/// The `logs` filter set. Validates flag values at construction (bad level/tool/since ⇒
/// `ValidationError`). An empty filter matches every line, including bare marker lines.
struct LogFilter {
    let minLevel: LogLevel?
    let component: String?
    let tool: String?
    let since: Date?

    var isEmpty: Bool { minLevel == nil && component == nil && tool == nil && since == nil }

    init(level: String?, component: String?, tool: String?, since: String?) throws {
        if let level {
            guard let parsed = LogFilter.parseLevel(level) else {
                throw ValidationError("Unknown --level '\(level)'. Use debug|info|warning|error|critical.")
            }
            minLevel = parsed
        } else {
            minLevel = nil
        }

        if let tool {
            let lowered = tool.lowercased()
            guard lowered == "claude" || lowered == "codex" else {
                throw ValidationError("Unknown --tool '\(tool)'. Use claude|codex.")
            }
            self.tool = lowered
        } else {
            self.tool = nil
        }

        if let since {
            guard let minutes = LogFilter.parseMinutes(since) else {
                throw ValidationError("Bad --since '\(since)'. Use a minute count like 30m.")
            }
            self.since = Date().addingTimeInterval(-Double(minutes) * 60)
        } else {
            self.since = nil
        }

        self.component = component
    }

    func matches(_ line: LogLine) -> Bool {
        if isEmpty { return true }             // no filter → everything, incl. bare marker lines
        // A filter is active, so only fully-parsed lines can qualify (timestamp/level/component
        // all non-nil under `isStructured`).
        guard line.isStructured else { return false }
        if let minLevel, let level = line.level, level < minLevel { return false }
        if let component,
           line.component?.caseInsensitiveCompare(component) != .orderedSame { return false }
        if let tool, line.metadata["tool"]?.lowercased() != tool { return false }
        if let since, let ts = line.timestamp, ts < since { return false }
        return true
    }

    private static func parseLevel(_ s: String) -> LogLevel? {
        switch s.lowercased() {
        case "debug": return .debug
        case "info": return .info
        case "warning", "warn": return .warning
        case "error": return .error
        case "critical", "crit": return .critical
        default: return nil
        }
    }

    /// Accepts `30m` or a bare `30` (minutes). Returns nil for anything else.
    private static func parseMinutes(_ s: String) -> Int? {
        let trimmed = s.hasSuffix("m") ? String(s.dropLast()) : s
        guard let n = Int(trimmed), n >= 0 else { return nil }
        return n
    }
}
