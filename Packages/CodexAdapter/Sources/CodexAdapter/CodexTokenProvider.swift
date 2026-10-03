import Foundation
import KvotarCore

/// The Codex OAuth credential read from `~/.codex/auth.json` (Baseline §8.2, §5.2).
public struct CodexCredential: Sendable, Equatable {
    public let accessToken: String
    /// `tokens.account_id` — sent as `ChatGPT-Account-Id` when present (Baseline §8.2).
    public let accountId: String?

    public init(accessToken: String, accountId: String? = nil) {
        self.accessToken = accessToken
        self.accountId = accountId
    }
}

/// Supplies the current Codex OAuth credential. Injected so tests can feed a fixed value (or nil)
/// without touching the filesystem (PATTERNS.md §Testing — inject mock conformances).
///
/// Read-only posture: an implementation must never write `auth.json` or attempt to refresh (§5.2,
/// CLAUDE.md absolute rules).
public protocol CodexTokenProvider: Sendable {
    /// Returns the current credential, or `nil` when the credential is genuinely **not there**.
    /// A failure to *attempt* the read must throw `AccountAdapterError.credentialUnreadable`
    /// instead of returning `nil` (STEP_117 / REV-71 §3.2) — `nil` is what the caller turns into
    /// `setupRequired`, which the app reads as "this tool was never set up".
    /// Must fail silently — never present a dialog.
    func credential() throws -> CodexCredential?
}

/// Production `CodexTokenProvider`: a passive read of `~/.codex/auth.json` (Baseline §8.2).
///
/// Reads only `tokens.access_token` and `tokens.account_id`. `tokens.refresh_token` is
/// deliberately not modeled in the decoded shape — this type never refreshes and never writes the
/// file (CLAUDE.md absolute rules).
///
/// **Absent is not the same as unreadable (STEP_117 / REV-71 §3.2).** `Data(contentsOf:)` used to
/// swallow every failure into `nil`, so on 2026-08-17 — when the process had no free file
/// descriptors left — "I could not open this file" was reported as "Codex is not signed in" on a
/// machine where it was. Only `NSFileNoSuchFileError` now means absent; every other read failure
/// (permissions, `EMFILE`, I/O) throws `credentialUnreadable` and lands on the idle path.
public struct CodexAuthFileReader: CodexTokenProvider {

    /// Default path (Baseline §5.3). Overridable for tests.
    public static func defaultPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json", isDirectory: false)
    }

    private let path: URL

    public init(path: URL? = nil) {
        self.path = path ?? Self.defaultPath()
    }

    public func credential() throws -> CodexCredential? {
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch let error as CocoaError
            where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            Logger.info("Codex auth.json not present", component: .codexAccountAdapter)
            return nil
        } catch {
            Logger.warning("Codex auth.json could not be read",
                           component: .codexAccountAdapter, metadata: ["error": "\(error)"])
            throw AccountAdapterError.credentialUnreadable("auth.json unreadable")
        }

        struct AuthFile: Decodable {
            let tokens: Tokens
            struct Tokens: Decodable {
                let accessToken: String
                let accountId: String?

                enum CodingKeys: String, CodingKey {
                    case accessToken = "access_token"
                    case accountId = "account_id"
                }
            }
        }

        do {
            let auth = try JSONDecoder().decode(AuthFile.self, from: data)
            return CodexCredential(accessToken: auth.tokens.accessToken, accountId: auth.tokens.accountId)
        } catch {
            Logger.warning("Codex auth.json decode failed",
                           component: .codexAccountAdapter, metadata: ["error": "\(error)"])
            return nil
        }
    }
}
