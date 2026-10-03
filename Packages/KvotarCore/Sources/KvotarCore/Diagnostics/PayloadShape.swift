import CryptoKit
import Foundation

/// Structural fingerprint of a JSON response body (§17.1 `payload_shapes`, REV-52 / STEP_72).
///
/// **Keys on structure, never on values.** This is the one place STEP_72 can silently invert its
/// own spec: if values entered the hash, every poll would read as a shape change, every row would
/// create a durable field-name-only shape record, while captured bodies remain time-limited and
/// unbounded growth *while appearing to work*.
///
/// Arrays contribute the paths of their elements under a `[]` marker, so a list that grows from two
/// entries to five is the **same** shape — element count is a value, not a structure.
public struct PayloadShape: Sendable, Equatable {
    /// Sorted, de-duplicated dotted field paths, e.g. `["five_hour.resets_at", "spend.limit"]`.
    public let fieldPaths: [String]
    /// SHA-256 of the joined paths, hex. Stable across processes and launches.
    public let hash: String

    public init(fieldPaths: [String]) {
        let sorted = Array(Set(fieldPaths)).sorted()
        self.fieldPaths = sorted
        let joined = sorted.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(joined.utf8))
        self.hash = digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Derives the shape of a JSON body. A body that is not decodable JSON yields the reserved
    /// `unparseable` shape rather than nil — an endpoint that starts returning HTML or an error
    /// page **is** a shape change, and one worth keeping permanently.
    public static func of(_ body: Data) -> PayloadShape {
        guard let root = try? JSONSerialization.jsonObject(
            with: body, options: [.fragmentsAllowed]) else {
            return PayloadShape(fieldPaths: ["<unparseable>"])
        }
        var paths: Set<String> = []
        collect(root, prefix: "", into: &paths)
        // An empty object/array still has a shape distinct from an unparseable body.
        return PayloadShape(fieldPaths: paths.isEmpty ? ["<empty>"] : Array(paths))
    }

    /// Walks the decoded structure accumulating dotted paths. Leaf *types* are deliberately not
    /// recorded: a field that flips `null` → number is the same field, and Claude/Codex payloads
    /// null out windows routinely (§8.3) — treating that as drift would fire on every idle night.
    private static func collect(_ node: Any, prefix: String, into paths: inout Set<String>) {
        switch node {
        case let dict as [String: Any]:
            if dict.isEmpty, !prefix.isEmpty { paths.insert(prefix) }
            for (key, value) in dict {
                let path = prefix.isEmpty ? key : "\(prefix).\(key)"
                paths.insert(path)
                collect(value, prefix: path, into: &paths)
            }
        case let array as [Any]:
            let path = prefix.isEmpty ? "[]" : "\(prefix)[]"
            paths.insert(path)
            // Union across elements: heterogeneous arrays contribute every element shape once,
            // and a longer array of identical elements adds nothing.
            for element in array {
                collect(element, prefix: path, into: &paths)
            }
        default:
            break   // scalar leaf — its path was inserted by the parent
        }
    }
}
