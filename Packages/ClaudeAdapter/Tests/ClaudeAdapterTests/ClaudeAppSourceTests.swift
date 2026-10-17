import XCTest
import CommonCrypto
import Security
import KvotarCore
@testable import ClaudeAdapter

private let appAccount = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private let appOrg = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
private let otherOrg = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
private let appNow = Date(timeIntervalSince1970: 1_800_000_000)
private let password = Data("synthetic-safe-storage-password".utf8)

private func cacheKey(account: UUID = appAccount, org: UUID = appOrg,
                      client: UUID = ClaudeAppCache.productionClient,
                      scopes: String = "user:profile user:inference") -> String {
    "acct:\(account.uuidString)|\(client.uuidString):\(org.uuidString):https://api.anthropic.com:\(scopes)"
}
private func entry(_ token: String = "synthetic-access", expiry: Double = appNow.timeIntervalSince1970 * 1000 + 60_000) -> [String: Any] {
    ["token": token, "expiresAt": expiry, "refreshToken": ["ignored": true]]
}
private func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
private func encrypt(_ data: Data) -> String {
    let key = try! ClaudeAppCrypto.derive(password: password)
    var output = Data(count: data.count + 16), count = 0
    let capacity = output.count
    let status = output.withUnsafeMutableBytes { out in
        key.withUnsafeBytes { secret in
            data.withUnsafeBytes { input in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        secret.baseAddress, key.count, [UInt8](repeating: 32, count: 16),
                        input.baseAddress, data.count, out.baseAddress, capacity, &count)
            }
        }
    }
    precondition(status == kCCSuccess)
    return (Data("v10".utf8) + output.prefix(count)).base64EncodedString()
}
private func config(_ entries: [String: Any], account: UUID = appAccount) -> Data {
    json(["lastKnownAccountUuid": account.uuidString, "oauth:tokenCacheV2": encrypt(json(entries))])
}

private final class AppFixture: ClaudeTokenProvider, HTTPFetcher, @unchecked Sendable {
    private let lock = NSLock()
    struct State {
        var cli: ClaudeCodeCredentialRead = .absent
        var cliThrows = false
        var presence: ClaudeAppPresence = {
            var value = ClaudeAppPresence(); value.app = .present; value.config = .present
            value.cacheMarker = .present; return value
        }()
        var config = ClaudeAppSourceTests.defaultConfig
        var configReadFails = false
        var unchanged = true
        var keyResult = ClaudeAppKeyRead.password(password)
        var keyReads: [Bool] = []
        var requests: [(String, String)] = []
        var binding = ClaudeAppBinding()
        var saves = 0
        var rebounds = 0
        var saveFails = false
        var changeDuringProfile = false
        var profileOrg = appOrg
        var cliOrg = appOrg
    }
    private var state = State()
    func change(_ body: (inout State) -> Void) { lock.withLock { body(&state) } }
    func value<T>(_ body: (State) -> T) -> T { lock.withLock { body(state) } }
    func credential() throws -> ClaudeCredential? {
        if case .available(let value) = try readOutcome() { return value }; return nil
    }
    func readOutcome() throws -> ClaudeCodeCredentialRead {
        try lock.withLock {
            if state.cliThrows { throw AccountAdapterError.credentialUnreadable("fixture") }
            return state.cli
        }
    }
    func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        let bytes: Data = lock.withLock {
            let token = headers["Authorization"] ?? ""
            state.requests.append((url.path, token))
            if url.path.hasSuffix("profile") {
                if state.changeDuringProfile { state.unchanged = false }
                let org = token.contains("synthetic-cli") ? state.cliOrg : state.profileOrg
                return json(["account": ["uuid": appAccount.uuidString, "email": "fixture@example.invalid", "has_claude_pro": false],
                             "organization": ["uuid": org.uuidString]])
            }
            return json(["five_hour": ["utilization": 12, "resets_at": "2027-01-15T12:00:00Z"],
                         "seven_day": ["utilization": 23, "resets_at": "2027-01-20T12:00:00Z"]])
        }
        return (bytes, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func resolver() -> ClaudeSourceResolver {
        .init(code: self, fetcher: self, detector: { self.value(\.presence) },
              readConfig: {
                  if self.value(\.configReadFails) { throw ClaudeAppCrypto.Failure.invalid }
                  return self.value { .init(bytes: $0.config, fingerprint: Data([1])) }
              },
              unchanged: { _ in self.value(\.unchanged) }, readKey: { allowed in
                  self.lock.withLock { self.state.keyReads.append(allowed); return self.state.keyResult }
              }, load: { self.value(\.binding) }, save: { binding, rebound in
                  try self.lock.withLock {
                      if self.state.saveFails { throw AccountAdapterError.credentialUnreadable("fixture persistence failure") }
                      self.state.binding = binding; self.state.saves += 1
                      if rebound { self.state.rebounds += 1 }
                  }
              }, now: { appNow })
    }
}

final class ClaudeAppSourceTests: XCTestCase {
    fileprivate static let defaultConfig = config([cacheKey(): entry()])

    func testTypedDecodeEligibilityAndV2Shadowing() throws {
        func select(_ v2: [String: Any], legacy: [String: Any]? = nil) -> ClaudeAppSelection {
            ClaudeAppCache.select(legacy: legacy.map(json), scoped: json(v2), account: appAccount, now: appNow)
        }
        guard case .candidate(let candidate) = select([cacheKey(): entry()]) else { return XCTFail() }
        XCTAssertEqual(candidate.credential.accessToken, "synthetic-access")
        XCTAssertEqual(select([cacheKey(): NSNull()], legacy: [cacheKey(): entry()]), .noEntry)
        XCTAssertEqual(select([cacheKey(): entry(expiry: 0)], legacy: [cacheKey(): entry()]), .expired)
        XCTAssertEqual(select([cacheKey(): ["token": "synthetic"]]), .noEntry)
        XCTAssertEqual(select([cacheKey(): ["expiresAt": 9e12]]), .noEntry)
        XCTAssertEqual(select([cacheKey(): entry("")], legacy: [cacheKey(): entry()]), .noEntry)
        XCTAssertEqual(select([cacheKey(scopes: "user:inference"): entry()]), .noEntry)
        XCTAssertEqual(select([cacheKey(client: otherOrg): entry()]), .noEntry)
        XCTAssertEqual(select([cacheKey(account: otherOrg): entry()]), .noEntry)
        XCTAssertEqual(select([cacheKey().replacingOccurrences(of: "api.anthropic.com", with: "api.anthropic.com.evil.invalid"): entry()]), .noEntry)
        XCTAssertEqual(select([cacheKey(): entry(), cacheKey(org: otherOrg): entry()]), .ambiguous)
        XCTAssertEqual(select([cacheKey(): entry(), cacheKey(scopes: "user:inference user:profile"): entry()]), .unreadable)
        XCTAssertEqual(ClaudeAppCache.select(legacy: json([cacheKey(): entry()]), scoped: Data("broken".utf8), account: appAccount, now: appNow), .unreadable)
    }

    func testClientAndScopeSuitabilityRankBeforeExpiry() {
        let otherClient = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let entries = [cacheKey(): entry("full"), cacheKey(scopes: "user:profile"): entry("partial", expiry: 9e12),
                       cacheKey(client: otherClient): entry("other", expiry: 9e12)]
        let selection = ClaudeAppCache.select(legacy: nil, scoped: json(entries), account: appAccount,
                                             now: appNow, clients: [ClaudeAppCache.productionClient, otherClient])
        guard case .candidate(let candidate) = selection else { return XCTFail() }
        XCTAssertEqual(candidate.credential.accessToken, "full")
    }

    func testCryptoRoundTripAndInvalidCiphertext() throws {
        let key = try ClaudeAppCrypto.derive(password: password)
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(), "6bd0d3469c81f15d3ad682aa12144756")
        XCTAssertEqual(try ClaudeAppCrypto.decrypt(encrypt(Data("fixture".utf8)), key: key), Data("fixture".utf8))
        XCTAssertThrowsError(try ClaudeAppCrypto.decrypt(Data("v10broken".utf8).base64EncodedString(), key: key))
        XCTAssertNotEqual(try? ClaudeAppCrypto.decrypt(encrypt(Data("fixture".utf8)), key: Data(repeating: 0, count: 16)), Data("fixture".utf8))
    }

    func testGateOnlyPositiveAbsenceAndClickRechecksIt() async throws {
        for mode in 0..<5 {
            let fixture = AppFixture()
            fixture.change {
                switch mode {
                case 0: $0.cli = .undecodable
                case 1: $0.cliThrows = true
                case 2: $0.presence.app = .absent
                case 3: $0.presence.cacheMarker = .absent
                default: $0.cli = .available(.init(accessToken: "synthetic-cli", expiresAt: 0))
                }
            }
            let resolver = fixture.resolver()
            _ = try? await resolver.resolve()
            await resolver.connect()
            let state = await resolver.connection
            XCTAssertFalse(state.offersConnection)
            XCTAssertEqual(fixture.value(\.keyReads), [])
        }
        let fixture = AppFixture() // card-to-click race
        let target = fixture.resolver()
        _ = try await target.resolve()
        fixture.change { $0.cli = .available(.init(accessToken: "synthetic-cli")) }
        await target.connect()
        XCTAssertTrue(fixture.value(\.keyReads).isEmpty)
    }

    func testConnectProfileBeforeUsageAndKeyCachedAcrossPolls() async throws {
        let fixture = AppFixture()
        let source = fixture.resolver()
        let adapter = ClaudeAccountAdapter(tokenProvider: fixture, fetcher: fixture, sourceResolver: source,
                                           localConfigURL: URL(fileURLWithPath: "/unused-fixture"), now: { appNow })
        await adapter.connectClaudeApp()
        let snapshot = try await adapter.fetchQuotaSnapshot()
        _ = try await adapter.fetchQuotaSnapshot()
        XCTAssertEqual(snapshot.source, .claudeApp)
        XCTAssertEqual(snapshot.email, "fixture@example.invalid")
        XCTAssertEqual(fixture.value(\.keyReads), [true])
        XCTAssertEqual(fixture.value { $0.requests.map(\.0) }, ["/api/oauth/profile", "/api/oauth/usage", "/api/oauth/usage"])
        XCTAssertNotNil(fixture.value { $0.binding.identityDigest })
    }

    func testDeniedPermissionRememberedAcrossRelaunchUntilClick() async throws {
        let fixture = AppFixture()
        fixture.change { $0.keyResult = .permissionDenied }
        let resolver = fixture.resolver()
        await resolver.connect()
        _ = try await resolver.resolve()
        let restarted = fixture.resolver()
        _ = try await restarted.resolve()
        XCTAssertEqual(fixture.value(\.keyReads), [true])
        let state = await restarted.connection
        XCTAssertEqual(state.state, .permissionRequired)
        fixture.change { $0.keyResult = .password(password) }
        await restarted.connect()
        XCTAssertEqual(fixture.value(\.keyReads), [true, true])
    }

    func testRelaunchUsesSuppressedReadAndRemembersRevokedGrant() async throws {
        let fixture = AppFixture()
        await fixture.resolver().connect()
        let restarted = fixture.resolver()
        _ = try await restarted.resolve()
        XCTAssertEqual(fixture.value(\.keyReads), [true, false])
        fixture.change { $0.keyResult = .permissionDenied }
        let revoked = fixture.resolver()
        _ = try? await revoked.resolve()
        _ = try? await revoked.resolve()
        XCTAssertEqual(fixture.value(\.keyReads), [true, false, false])
        XCTAssertTrue(fixture.value { $0.binding.permissionDenied })
    }

    func testCLIIdentityPrecedenceAndExpiredCLIContinuation() async throws {
        let fixture = AppFixture()
        let resolver = fixture.resolver()
        await resolver.connect()
        fixture.change { $0.cli = .available(.init(accessToken: "synthetic-cli", expiresAt: 0)) }
        let expired = try await resolver.resolve()
        XCTAssertEqual(expired?.source, .claudeApp)
        XCTAssertEqual(fixture.value { $0.requests.count }, 1)
        fixture.change { $0.cli = .available(.init(accessToken: "synthetic-cli", expiresAt: 9e12)); $0.cliOrg = otherOrg }
        let different = try await resolver.resolve()
        XCTAssertEqual(different?.source, .claudeApp)
        let mismatch = await resolver.connection
        XCTAssertEqual(mismatch.state, .codeIdentityDiffers)
        fixture.change { $0.cli = .available(.init(accessToken: "synthetic-cli-rotated", expiresAt: 9e12)); $0.cliOrg = appOrg }
        let same = try await resolver.resolve()
        XCTAssertEqual(same?.source, .oauth)
    }

    func testChangedIdentityStopsUntilExplicitRebind() async throws {
        let fixture = AppFixture()
        let resolver = fixture.resolver()
        await resolver.connect()
        fixture.change { $0.config = config([cacheKey(org: otherOrg): entry("synthetic-new")]); $0.profileOrg = otherOrg }
        _ = try? await resolver.resolve()
        let changed = await resolver.connection
        XCTAssertEqual(changed.state, .accountChanged)
        XCTAssertEqual(fixture.value { $0.requests.count }, 1)
        _ = try? await fixture.resolver().resolve()
        XCTAssertEqual(fixture.value { $0.requests.count }, 1)
        await resolver.connect()
        let rebound = try await resolver.resolve()
        XCTAssertEqual(rebound?.source, .claudeApp)
        XCTAssertEqual(fixture.value(\.rebounds), 1)
    }

    func testProfileMismatchConfigChangeAndPersistenceFailureNeverUseCandidate() async {
        for mode in 0..<3 {
            let fixture = AppFixture()
            fixture.change {
                if mode == 0 { $0.profileOrg = otherOrg }
                if mode == 1 { $0.unchanged = false }
                if mode == 2 { $0.saveFails = true }
            }
            let resolver = fixture.resolver()
            await resolver.connect()
            XCTAssertNil(fixture.value { $0.binding.identityDigest })
            XCTAssertFalse(fixture.value { $0.requests.contains { $0.0.hasSuffix("usage") } })
        }
    }

    func testAwaitedProfileCannotCommitAChangedConfig() async {
        let fixture = AppFixture()
        fixture.change { $0.changeDuringProfile = true }
        await fixture.resolver().connect()
        XCTAssertNil(fixture.value { $0.binding.identityDigest })
        XCTAssertEqual(fixture.value { $0.requests.count }, 1)
    }

    func testCommonBackgroundPollEntryAndCooldownReadNeverAllowInteraction() async throws {
        // Launch, timer, wake, Re-check and notification-triggered quota checks all use
        // AccountAdapter.fetchQuotaSnapshot. A fresh resolver forces an actual key read here.
        let fixture = AppFixture()
        fixture.change {
            $0.binding = .init(identityDigest: ClaudeAppIdentity(account: appAccount, organization: appOrg).digest,
                              connectionRequested: true)
        }
        let resolver = fixture.resolver()
        let adapter = ClaudeAccountAdapter(tokenProvider: fixture, fetcher: fixture, sourceResolver: resolver,
            localConfigURL: URL(fileURLWithPath: "/unused-fixture"), now: { appNow })
        _ = try await adapter.fetchQuotaSnapshot()
        _ = await adapter.credentialChanged()
        _ = try await adapter.fetchQuotaSnapshot()
        XCTAssertEqual(fixture.value(\.keyReads), [false])
        XCTAssertEqual(fixture.value { $0.requests.filter { $0.0.hasSuffix("profile") }.count }, 1)
    }

    func testPermissionLossRanksBeforeExpiryAndInvalidConfig() async {
        let fixture = AppFixture()
        await fixture.resolver().connect()
        fixture.change { $0.config = config([cacheKey(): entry(expiry: 0)]); $0.keyResult = .permissionDenied }
        let restarted = fixture.resolver()
        _ = try? await restarted.resolve()
        let status = await restarted.connection
        XCTAssertEqual(status.state, .permissionRequired)
        XCTAssertTrue(status.offersConnection)
    }

    func testConfigReadFailureStopsConnectedSourceAndMarksReadingHistorical() async {
        let fixture = AppFixture()
        let resolver = fixture.resolver()
        await resolver.connect()
        fixture.change { $0.configReadFails = true }
        do { _ = try await resolver.resolve(); XCTFail("unreadable config used") }
        catch { }
        let status = await resolver.connection
        XCTAssertEqual(status.state, .unreadable)
        XCTAssertTrue(status.isHistorical)
        XCTAssertEqual(fixture.value { $0.requests.count }, 1)
    }

    func testConnectedAppExpiryGatesNetworkAndSetsAdapterHealth() async {
        let fixture = AppFixture()
        let resolver = fixture.resolver()
        let adapter = ClaudeAccountAdapter(tokenProvider: fixture, fetcher: fixture,
            sourceResolver: resolver, now: { appNow })
        await adapter.connectClaudeApp()
        fixture.change { $0.config = config([cacheKey(): entry(expiry: 0)]) }
        do { _ = try await adapter.fetchQuotaSnapshot(); XCTFail("expired token used") }
        catch { XCTAssertEqual(error as? AccountAdapterError, .credentialExpired(details: nil)) }
        let health = await adapter.health
        XCTAssertEqual(health, .credentialExpired)
        XCTAssertEqual(fixture.value { $0.requests.count }, 1) // only the connection profile
    }

    func testExpiredAmbiguousAndMissingAppOfferNoPermissionRemedy() async {
        for mode in 0..<3 {
            let fixture = AppFixture()
            fixture.change {
                if mode == 0 { $0.config = config([cacheKey(): entry(expiry: 0)]) }
                if mode == 1 { $0.config = config([cacheKey(): entry(), cacheKey(org: otherOrg): entry()]) }
                if mode == 2 { $0.presence.app = .absent }
            }
            let resolver = fixture.resolver()
            await resolver.connect()
            _ = try? await resolver.resolve()
            let state = await resolver.connection
            XCTAssertFalse(state.offersConnection)
        }
    }
}

final class ClaudeAppSuppressionTests: XCTestCase {
    private final class Spy: @unchecked Sendable {
        let lock = NSLock()
        var calls: [String] = []
        var getFails = false, setFails = false, restoreFails = false
        var prior = true
        func add(_ call: String) { lock.withLock { calls.append(call) } }
        var operations: ClaudeAppKeychainOperations {
            .init(interaction: { self.add("get"); return (self.getFails ? -1 : 0, self.prior) },
                  setInteraction: { value in
                      self.add("set:\(value)")
                      return (!value && self.setFails) || (value && self.restoreFails) ? -1 : 0
                  }, read: { allowed in self.add("read:\(allowed)"); return .password(password) })
        }
    }
    func testSuppressionSequenceRestoresPriorStateAndClickIsOnlyAllowedRead() {
        for prior in [true, false] {
            let spy = Spy(); spy.prior = prior
            let reader = ClaudeAppSafeStorage(operations: spy.operations)
            XCTAssertEqual(reader.read(allowInteraction: false), .password(password))
            XCTAssertEqual(spy.calls, ["get", "set:false", "read:false", "set:\(prior)"])
        }
        let spy = Spy()
        _ = ClaudeAppSafeStorage(operations: spy.operations).read(allowInteraction: true)
        XCTAssertEqual(spy.calls, ["read:true"])
    }
    func testInteractiveAndBackgroundReadersShareOneLock() {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let firstDone = DispatchSemaphore(value: 0), secondDone = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)
        let spy = Spy()
        var operations = spy.operations
        operations.read = { allowed in
            spy.add("read:\(allowed)")
            if !allowed { entered.signal(); _ = release.wait(timeout: .now() + 3) }
            return .password(password)
        }
        let background = ClaudeAppSafeStorage(operations: operations)
        let interactive = ClaudeAppSafeStorage(operations: operations)
        DispatchQueue.global().async {
            _ = background.read(allowInteraction: false); firstDone.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            secondStarted.signal()
            _ = interactive.read(allowInteraction: true); secondDone.signal()
        }
        XCTAssertEqual(secondStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(secondDone.wait(timeout: .now() + 0.1), .timedOut)
        release.signal()
        XCTAssertEqual(firstDone.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(secondDone.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(spy.calls, ["get", "set:false", "read:false", "set:true", "read:true"])
    }

    func testGetDisableAndRestoreFailuresFailClosed() {
        for mode in 0..<3 {
            let spy = Spy(); spy.getFails = mode == 0; spy.setFails = mode == 1; spy.restoreFails = mode == 2
            XCTAssertEqual(ClaudeAppSafeStorage(operations: spy.operations).read(allowInteraction: false), .unavailable)
            if mode != 2 { XCTAssertFalse(spy.calls.contains("read:false")) }
        }
    }
}
