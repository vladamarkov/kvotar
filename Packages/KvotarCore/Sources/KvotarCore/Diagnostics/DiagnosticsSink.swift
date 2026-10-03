import Foundation

/// Stable endpoint identifiers for `raw_payloads.endpoint` (§17.1). Names, never raw URLs — a URL
/// carries an org id and would make the column a moving target across accounts.
public enum DiagnosticsEndpoint {
    public static let claudeUsage = "claude_usage"
    public static let claudeProfile = "claude_profile"
    public static let claudePrepaid = "claude_prepaid"
    public static let claudeOther = "claude_other"
    public static let codexWhamUsage = "codex_wham_usage"
    // Codex RPC rows use the JSON-RPC method verbatim (`account/read`,
    // `account/rateLimits/read`) — it is already a stable name, so nothing needs mapping.

    /// Maps a Claude OAuth URL to its stable identifier. Path-suffix matched so a host or version
    /// change does not silently reclassify every row as `claude_other`.
    public static func claudeEndpoint(for url: URL) -> String {
        let path = url.path
        if path.hasSuffix("/oauth/usage") { return claudeUsage }
        if path.hasSuffix("/oauth/profile") { return claudeProfile }
        if path.contains("/prepaid/credits") { return claudePrepaid }
        return claudeOther
    }
}

/// One local JSONL line the parsers could not decode (§17.1 `parse_anomalies`).
///
/// **Field names only, never values.** This type is the reason a diagnostics bundle never needs to
/// carry a JSONL file — those files contain transcripts and code belonging to third parties who
/// never consented (§17 never-store list), and the parsed corpus already travels in the DB. The
/// only thing raw files would add over the database is *the lines we failed to parse*, which is
/// exactly this.
public struct ParseAnomaly: Sendable, Equatable {
    public let tool: Tool
    public let sourceFile: String
    public let lineNumber: Int?
    public let observedAt: Date
    public let error: String?
    /// Top-level key names present on the line. Nil when the line was not even a JSON object.
    public let fieldNames: [String]?

    public init(tool: Tool, sourceFile: String, lineNumber: Int?, observedAt: Date = Date(),
                error: String?, fieldNames: [String]?) {
        self.tool = tool
        self.sourceFile = sourceFile
        self.lineNumber = lineNumber
        self.observedAt = observedAt
        self.error = error
        self.fieldNames = fieldNames
    }

    /// Extracts top-level key names from a line that failed structured decoding. Returns nil when
    /// the bytes are not a JSON object at all (the common corruption case). Values are discarded
    /// here and never leave this function.
    public static func fieldNames(of line: Data) -> [String]? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return nil
        }
        return object.keys.sorted()
    }
}

/// Fire-and-forget destination for captured diagnostics.
///
/// Deliberately **not** a `SQLiteStore` reference: the capture decorators live in the adapter
/// packages and sit on the poll path, so they must neither import the store nor await an actor to
/// record something. Implementations hop to their own `Task`; a dropped row is acceptable, a slowed
/// poll is not.
public protocol DiagnosticsSink: Sendable {
    /// Record one provider response. Callers do **not** gate on `DiagnosticsCapture.isEnabled` —
    /// the sink does, so the check lives in exactly one place.
    func capture(tool: Tool, endpoint: String, body: Data, httpStatus: Int?)

    /// Record one undecodable local JSONL line.
    func recordAnomaly(_ anomaly: ParseAnomaly)
}
