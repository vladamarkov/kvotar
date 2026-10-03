import Foundation
import KvotarCore

/// Production `ClaudeTokenProvider`: reads the Claude Code OAuth token from the macOS Keychain by
/// delegating to `/usr/bin/security` (Baseline §8.0.1, Spike Findings §S3).
///
/// **Why delegation, not `SecItemCopyMatching`.** The `Claude Code-credentials` item's ACL is
/// "Confirm before allowing access", and the single trusted application is `/usr/bin/security` —
/// Claude Code created the item via that tool. A direct `SecItemCopyMatching` from our own process
/// is therefore *not* the trusted accessor: it hits the ACL confirmation, and with
/// `kSecUseAuthenticationUIFail` that returns `errSecUserCanceled` (-128) — no token, regardless of
/// how Kvotar is signed. Invoking `/usr/bin/security` instead makes the trusted Apple tool the
/// accessor, so macOS grants the read **silently** — no dialog, no one-time authorization. This is
/// the same mechanism CodexBar uses (verified on-machine, 2026-07-03).
///
/// - Command: `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`
///   (`-w` prints only the password — the credential JSON — to stdout).
/// - Extraction path: JSON `claudeAiOauth.accessToken` (not a top-level key).
///
/// **Read-only posture.** Never writes, deletes, refreshes, or shows a dialog.
///
/// **Absent is not the same as unreachable (STEP_117 / REV-71 §3.2).** `nil` means *the Keychain
/// item is not there* — the caller turns that into `setupRequired`, which the app reads as "never
/// set up". A failure to *attempt* the read throws `AccountAdapterError.credentialUnreadable`
/// instead, so it can never be mistaken for a machine that has not signed in. The split:
///
/// | Outcome | Meaning | Result |
/// |---|---|---|
/// | `process.run()` throws | could not start `/usr/bin/security` at all — this is what descriptor exhaustion looks like, since a `Process` plus two `Pipe`s needs four free handles | `throw .credentialUnreadable` |
/// | exit 44 (`errSecItemNotFound`) | the item genuinely is not there | `nil` |
/// | any other non-zero exit | the item exists but the read was denied/inaccessible | `throw .credentialUnreadable` |
/// | output does not decode | present but unusable — unchanged, still `nil` | `nil` |
///
/// **Brittleness.** This relies on `/usr/bin/security` being the trusted app on the item, which
/// holds because Claude Code stores it that way. If a future Claude Code release stores the token
/// under its own app identity, the delegated read would no longer be silent — revalidate across
/// Claude Code releases (the OAuth path was flagged brittle across releases in the follow-up spike).
public struct KeychainTokenProvider: ClaudeTokenProvider {

    /// Keychain generic-password service name (confirmed on-machine, §S3).
    public static let service = "Claude Code-credentials"

    private let service: String
    /// Path to the trusted accessor. Injectable so a fake `security` can be scripted in tests;
    /// internal so a test can pin the default (STEP_239).
    let securityToolPath: String

    public init(
        service: String = KeychainTokenProvider.service,
        securityToolPath: String = "/usr/bin/security"
    ) {
        self.service = service
        self.securityToolPath = securityToolPath
    }

    public func credential() throws -> ClaudeCredential? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: securityToolPath)
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()  // discard "not found" noise; never surfaced to the user

        do {
            try process.run()
        } catch {
            // Could not even attempt the read — not evidence about whether a credential exists.
            Logger.warning("Claude Keychain read could not be attempted — security tool failed to launch",
                           component: .claudeAccountAdapter,
                           metadata: ["tool": securityToolPath, "error": "\(error)"])
            throw AccountAdapterError.credentialUnreadable("security tool would not launch")
        }

        // Read to EOF before waiting so a full credential blob never deadlocks the pipe buffer.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            // 44 = errSecItemNotFound — the item genuinely is not there, which is the only exit
            // that may mean "not set up". Anything else is denied/inaccessible: the item may well
            // exist and we simply could not read it, so it must not read as first-run (REV-71
            // §3.2). Never log the credential itself.
            guard process.terminationStatus == 44 else {
                Logger.warning("Claude Keychain read could not be completed",
                               component: .claudeAccountAdapter,
                               metadata: ["exit": "\(process.terminationStatus)"])
                throw AccountAdapterError.credentialUnreadable(
                    "security exit \(process.terminationStatus)")
            }
            Logger.info("Claude Keychain credential unavailable",
                        component: .claudeAccountAdapter,
                        metadata: ["exit": "\(process.terminationStatus)"])
            return nil
        }

        struct Credentials: Decodable {
            let claudeAiOauth: OAuth
            struct OAuth: Decodable {
                let accessToken: String
                let subscriptionType: String?
                // Epoch milliseconds (§8.0.1). Optional so an absent/unparseable field decodes to
                // nil (gate no-op) rather than failing the whole credential read.
                let expiresAt: Double?
            }
        }

        do {
            let oauth = try JSONDecoder().decode(Credentials.self, from: data).claudeAiOauth
            return ClaudeCredential(
                accessToken: oauth.accessToken,
                subscriptionType: oauth.subscriptionType,
                expiresAt: oauth.expiresAt
            )
        } catch {
            Logger.warning("Claude Keychain credential decode failed",
                           component: .claudeAccountAdapter, metadata: ["error": "\(error)"])
            return nil
        }
    }
}
