import Foundation
import KvotarCore

/// Chooses an already-owned credential. Only connect() can authorize an interactive key read.
/// All mutable connection state is serialized across suspension points, including profile checks.
public actor ClaudeSourceResolver {
    struct Resolved: Sendable {
        let credential: ClaudeCredential
        let source: QuotaSource
        let profile: ClaudeProfileResponse?
    }
    private let code: any ClaudeTokenProvider
    private let fetcher: any HTTPFetcher
    private let detector: @Sendable () -> ClaudeAppPresence
    private let readConfig: @Sendable () throws -> ClaudeAppConfigSnapshot
    private let unchanged: @Sendable (Data) -> Bool
    private let readKey: @Sendable (Bool) -> ClaudeAppKeyRead
    private let load: @Sendable () async throws -> ClaudeAppBinding
    private let save: @Sendable (ClaudeAppBinding, Bool) async throws -> Void
    private let now: @Sendable () -> Date
    private var binding = ClaudeAppBinding()
    private var loaded = false
    private var key: Data?
    private var proof: (ClaudeAppCandidate, ClaudeProfileResponse)?
    private var codeProof: (ClaudeCredential, ClaudeProfileResponse)?
    private var status = ClaudeAppConnection()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(code: any ClaudeTokenProvider, fetcher: any HTTPFetcher,
                detector: ClaudeAppDetector,
                load: @escaping @Sendable () async throws -> ClaudeAppBinding,
                save: @escaping @Sendable (ClaudeAppBinding, Bool) async throws -> Void,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.code = code; self.fetcher = fetcher
        self.detector = { detector.detect() }
        let reader = ClaudeAppConfigReader(detector: detector)
        self.readConfig = { try reader.snapshot() }; self.unchanged = { reader.unchanged($0) }
        self.readKey = { ClaudeAppSafeStorage().read(allowInteraction: $0) }
        self.load = load; self.save = save; self.now = now
    }

    init(code: any ClaudeTokenProvider, fetcher: any HTTPFetcher,
         detector: @escaping @Sendable () -> ClaudeAppPresence,
         readConfig: @escaping @Sendable () throws -> ClaudeAppConfigSnapshot,
         unchanged: @escaping @Sendable (Data) -> Bool,
         readKey: @escaping @Sendable (Bool) -> ClaudeAppKeyRead,
         load: @escaping @Sendable () async throws -> ClaudeAppBinding = { .init() },
         save: @escaping @Sendable (ClaudeAppBinding, Bool) async throws -> Void = { _, _ in },
         now: @escaping @Sendable () -> Date) {
        self.code = code; self.fetcher = fetcher; self.detector = detector
        self.readConfig = readConfig; self.unchanged = unchanged; self.readKey = readKey
        self.load = load; self.save = save; self.now = now
    }

    public var connection: ClaudeAppConnection { status }

    func credentialChanged(baseline: String?) async -> Bool {
        await enter(); defer { leave() }
        guard let baseline else { return false }
        do {
            try await restore()
            if binding.identityDigest == nil {
                guard case .available(let value) = try code.readOutcome() else { return false }
                return value.accessToken != baseline && !ClaudeAccountAdapter.isCredentialExpired(value, now: now())
            }
            guard !binding.permissionDenied, !binding.requiresReconnect,
                  detector().canConnect, let selected = try await candidate(allowInteraction: false),
                  selected.identity.digest == binding.identityDigest else { return false }
            return selected.credential.accessToken != baseline
        } catch { return false }
    }

    private func enter() async {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        else { busy = true }
    }
    private func leave() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
    private func restore() async throws {
        if !loaded { binding = try await load(); loaded = true }
    }
    private func persist(_ next: ClaudeAppBinding, rebound: Bool = false) async throws {
        guard next != binding else { return }
        try await save(next, rebound)
        binding = next
    }

    public func connect() async {
        await enter(); defer { leave() }
        do {
            try await restore()
            let presence = detector()
            let cli = try code.readOutcome()
            status.gate = cli == .absent && presence.canConnect
            status.codeAbsent = cli == .absent
            guard status.gate else { return }
            status = .init(state: .ready, gate: true, appPresent: true, codeAbsent: true,
                           usingApp: binding.identityDigest != nil)
            // Clear permission memory only on a deliberate click. Persistence failure stops here.
            var next = binding; next.permissionDenied = false; next.connectionRequested = true
            try await persist(next)
            guard let selected = try await candidate(allowInteraction: true) else { return }
            guard let profile = await verifiedProfile(selected.credential),
                  identity(profile) == selected.identity else {
                status.state = .unreadable; return
            }
            guard unchanged(selectedSnapshot), !ClaudeAccountAdapter.isCredentialExpired(selected.credential, now: now()) else {
                status.state = .unreadable; return
            }
            let digest = selected.identity.digest
            let rebound = binding.identityDigest.map { $0 != digest } ?? false
            try await persist(.init(identityDigest: digest, connectionRequested: true), rebound: rebound)
            proof = (selected, profile); codeProof = nil
            status = .init(state: .connected, gate: true, appPresent: true, codeAbsent: true, usingApp: true)
        } catch { status.state = .unreadable }
    }

    func resolve() async throws -> Resolved? {
        await enter(); defer { leave() }
        try await restore()
        let presence = detector()
        let cli: ClaudeCodeCredentialRead
        do { cli = try code.readOutcome() }
        catch {
            status.gate = false; status.codeAbsent = false
            if binding.identityDigest == nil { throw error }
            // A connected app source does not depend on the CLI remaining absent/readable.
            return try await resolveApp(presence: presence, codeCredential: nil)
        }
        status.gate = cli == .absent && presence.canConnect
        status.codeAbsent = cli == .absent
        status.appPresent = presence.app == .present
        guard binding.identityDigest != nil else {
            status.usingApp = false
            if case .available(let credential) = cli {
                status.state = .unavailable
                return .init(credential: credential, source: .oauth, profile: nil)
            }
            status.state = !presence.canConnect ? .unavailable
                : (binding.permissionDenied ? .permissionRequired : .ready)
            if presence.canConnect, binding.connectionRequested, !binding.permissionDenied {
                if try await candidate(allowInteraction: false) != nil { status.state = .ready }
            }
            // Preserve the existing CLI decode-failure result, but never open the connect gate.
            return nil
        }
        let credential: ClaudeCredential?
        if case .available(let value) = cli,
           !ClaudeAccountAdapter.isCredentialExpired(value, now: now()) { credential = value }
        else { credential = nil }
        return try await resolveApp(presence: presence, codeCredential: credential)
    }

    private func resolveApp(presence: ClaudeAppPresence, codeCredential: ClaudeCredential?) async throws -> Resolved? {
        status.appPresent = presence.app == .present
        status.usingApp = true
        if let cli = codeCredential {
            let checked: ClaudeProfileResponse?
            if let cached = codeProof, cached.0 == cli { checked = cached.1 }
            else { checked = await verifiedProfile(cli); if let checked { codeProof = (cli, checked) } }
            if let checked, identity(checked)?.digest == binding.identityDigest,
               !ClaudeAccountAdapter.isCredentialExpired(cli, now: now()) {
                status.usingApp = false; status.state = .connected
                return .init(credential: cli, source: .oauth, profile: checked)
            }
            status.state = .codeIdentityDiffers
        }
        guard presence.app == .present, presence.config == .present else {
            status.state = .unavailable; throw unavailable()
        }
        guard !binding.permissionDenied else { status.state = .permissionRequired; throw unavailable() }
        guard !binding.requiresReconnect else { status.state = .accountChanged; throw unavailable() }
        guard let selected = try await candidate(allowInteraction: false) else { throw unavailable() }
        guard selected.identity.digest == binding.identityDigest else {
            try await changedIdentity(); throw unavailable()
        }
        let profile: ClaudeProfileResponse
        if let cached = proof, cached.0 == selected { profile = cached.1 }
        else {
            guard let verified = await verifiedProfile(selected.credential) else {
                status.state = .unreadable; throw unavailable()
            }
            guard identity(verified) == selected.identity,
                  identity(verified)?.digest == binding.identityDigest else {
                try await changedIdentity(); throw unavailable()
            }
            profile = verified
        }
        guard unchanged(selectedSnapshot), !ClaudeAccountAdapter.isCredentialExpired(selected.credential, now: now()) else {
            status.state = .unreadable; throw unavailable()
        }
        proof = (selected, profile)
        status.state = codeCredential == nil ? .connected : .codeIdentityDiffers
        return .init(credential: selected.credential, source: .claudeApp, profile: profile)
    }

    private func changedIdentity() async throws {
        var next = binding; next.requiresReconnect = true
        // Stop in memory even if saving fails; next selection will independently reject identity.
        status.state = .accountChanged; proof = nil
        try await persist(next)
    }

    private var selectedSnapshot = Data()
    private func candidate(allowInteraction: Bool) async throws -> ClaudeAppCandidate? {
        let snapshot: ClaudeAppConfigSnapshot
        do { snapshot = try readConfig() }
        catch { status.state = .unreadable; throw error }
        let config: ClaudeAppCache.Config
        do { config = try JSONDecoder().decode(ClaudeAppCache.Config.self, from: snapshot.bytes) }
        catch { status.state = .unreadable; return nil }
        guard config.legacy != nil || config.scoped != nil else { status.state = .noEntry; return nil }
        if key == nil, !(try await obtainKey(allowInteraction: allowInteraction)) { return nil }
        func select(_ key: Data) throws -> ClaudeAppSelection {
            ClaudeAppCache.select(
                legacy: try config.legacy.map { try ClaudeAppCrypto.decrypt($0, key: key) },
                scoped: try config.scoped.map { try ClaudeAppCrypto.decrypt($0, key: key) },
                account: config.lastKnownAccountUuid, now: now())
        }
        let selection: ClaudeAppSelection
        do { selection = try select(key!) }
        catch {
            // A rotated Safe Storage key invalidates the memory cache. The recovery read is
            // silent even during Connect: a click authorizes at most one dialog.
            key = nil
            guard try await obtainKey(allowInteraction: false) else { return nil }
            do { selection = try select(key!) }
            catch { status.state = .unreadable; return nil }
        }
        guard unchanged(snapshot.fingerprint) else { status.state = .unreadable; return nil }
        selectedSnapshot = snapshot.fingerprint
        switch selection {
        case .candidate(let candidate): return candidate
        case .expired: status.state = .expired
        case .ambiguous: status.state = .ambiguous
        case .noEntry: status.state = .noEntry
        case .unreadable: status.state = .unreadable
        }
        return nil
    }

    private func obtainKey(allowInteraction: Bool) async throws -> Bool {
        guard allowInteraction || !binding.permissionDenied else { status.state = .permissionRequired; return false }
        switch readKey(allowInteraction) {
        case .password(let password):
            key = try ClaudeAppCrypto.derive(password: password); return true
        case .permissionDenied:
            status.state = .permissionRequired
            var next = binding; next.permissionDenied = true
            do { try await persist(next) }
            catch { binding.permissionDenied = true; throw error }
            return false
        case .unavailable: status.state = .unreadable; return false
        }
    }

    private func verifiedProfile(_ credential: ClaudeCredential) async -> ClaudeProfileResponse? {
        guard !ClaudeAccountAdapter.isCredentialExpired(credential, now: now()) else { return nil }
        do {
            let (bytes, response) = try await fetcher.get(ClaudeAccountAdapter.profileURL,
                headers: ["Authorization": "Bearer \(credential.accessToken)",
                          "anthropic-beta": ClaudeAccountAdapter.profileBetaHeader])
            guard (200...299).contains(response.statusCode) else { return nil }
            let profile = try JSONDecoder().decode(ClaudeProfileResponse.self, from: bytes)
            guard identity(profile) != nil else { return nil }
            return profile
        } catch { return nil }
    }
    private func identity(_ profile: ClaudeProfileResponse) -> ClaudeAppIdentity? {
        guard let a = profile.account.uuid.flatMap(UUID.init(uuidString:)),
              let o = profile.organization?.uuid.flatMap(UUID.init(uuidString:)) else { return nil }
        return .init(account: a, organization: o)
    }
    private func unavailable() -> AccountAdapterError {
        if status.state == .expired { return .credentialExpired(details: nil) }
        return .credentialUnreadable("Claude app source unavailable")
    }
}
