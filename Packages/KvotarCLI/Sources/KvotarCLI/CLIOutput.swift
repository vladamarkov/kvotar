import Foundation

/// Rendering seam every `kvotar` command writes through. A command builds an `Encodable`
/// payload with stable field names and a `humanText` rendering; the seam prints one or the other
/// per the `--json` flag. Field names are the forward-compatible contract for a later
/// `--format prompt` embedding (STEP_54 task 4) — commands must not rename them casually.
protocol CLIOutputPayload: Encodable {
    /// Human-readable default rendering (no trailing newline).
    var humanText: String { get }
}

enum CLIOutput {
    /// Render `payload` to a string in the requested format. JSON uses sorted keys so the field
    /// order is deterministic across runs.
    static func render<P: CLIOutputPayload>(_ payload: P, json: Bool) -> String {
        guard json else { return payload.humanText }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    /// Render to stdout.
    static func print<P: CLIOutputPayload>(_ payload: P, json: Bool) {
        Swift.print(render(payload, json: json))
    }
}
