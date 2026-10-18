import Foundation
import CryptoKit
import Darwin
import KvotarCore

struct ClaudeAppIdentity: Sendable, Equatable {
    let account: UUID
    let organization: UUID
    var digest: String {
        SHA256.hash(data: Data("\(account.uuidString)|\(organization.uuidString)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

struct ClaudeAppCandidate: Sendable, Equatable {
    let identity: ClaudeAppIdentity
    let credential: ClaudeCredential
    let entryKey: String
}

enum ClaudeAppSelection: Sendable, Equatable {
    case candidate(ClaudeAppCandidate)
    case expired, ambiguous, noEntry, unreadable
}

/// Compatibility format observed in Claude.app; deliberately no generic decrypted JSON model.
enum ClaudeAppCache {
    static let productionClient = UUID(uuidString: "9d1c250a-e61b-44d9-88ed-5944d1962f5e")!
    struct Config: Decodable {
        let lastKnownAccountUuid: UUID?
        let legacy: String?
        let scoped: String?
        enum CodingKeys: String, CodingKey {
            case lastKnownAccountUuid
            case legacy = "oauth:tokenCache"
            case scoped = "oauth:tokenCacheV2"
        }
    }
    struct Entry: Decodable {
        let token: String?
        let expiresAt: Double?
        let subscriptionType: String?
    }
    struct Key: Hashable {
        let account: UUID
        let organization: UUID
        let client: UUID
        let scopes: Set<String>
        init?(_ raw: String) {
            guard raw.hasPrefix("acct:") else { return nil }
            let tagged = raw.dropFirst(5).split(separator: "|", omittingEmptySubsequences: false)
            guard tagged.count == 2, let account = UUID(uuidString: String(tagged[0])) else { return nil }
            let parts = tagged[1].split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            let host = "https://api.anthropic.com:"
            guard parts.count == 3, let client = UUID(uuidString: String(parts[0])),
                  let organization = UUID(uuidString: String(parts[1])), parts[2].hasPrefix(host) else { return nil }
            self.account = account; self.organization = organization; self.client = client
            self.scopes = Set(parts[2].dropFirst(host.count).split(separator: " ").map(String.init))
        }
        var canonical: String {
            "\(account.uuidString)|\(client.uuidString)|\(organization.uuidString)|\(scopes.sorted().joined(separator: " "))"
        }
    }
    enum Slot { case deleted, value(Entry) }

    private static func decode(_ bytes: Data?) throws -> [Key: Slot] {
        guard let bytes else { return [:] }
        let entries = try JSONDecoder().decode([String: Entry?].self, from: bytes)
        var result: [Key: Slot] = [:]
        for (raw, entry) in entries {
            guard let key = Key(raw) else { continue }
            guard result[key] == nil else { throw ClaudeAppCrypto.Failure.invalid }
            result[key] = entry.map(Slot.value) ?? .deleted
        }
        return result
    }

    static func select(legacy: Data?, scoped: Data?, account: UUID?, now: Date,
                       clients: Set<UUID> = [productionClient]) -> ClaudeAppSelection {
        guard let account else { return .noEntry }
        do {
            var slots = try decode(legacy)
            for (key, slot) in try decode(scoped) { slots[key] = slot }
            var eligible: [(Key, Entry)] = []
            var expired = false
            for (key, slot) in slots {
                guard key.account == account, clients.contains(key.client), key.scopes.contains("user:profile"),
                      case .value(let entry) = slot, let token = entry.token,
                      !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let expiry = entry.expiresAt, expiry.isFinite else { continue }
                guard expiry > now.timeIntervalSince1970 * 1000 else { expired = true; continue }
                eligible.append((key, entry))
            }
            guard Set(eligible.map { $0.0.organization }).count <= 1 else { return .ambiguous }
            func rank(_ row: (Key, Entry)) -> (Int, Int, Int, Double) {
                let full = row.0.scopes.contains("user:inference")
                return (row.0.client == productionClient && full ? 1 : 0, full ? 1 : 0,
                        row.0.scopes.count, row.1.expiresAt ?? 0)
            }
            eligible.sort { rank($0) > rank($1) }
            guard let (key, entry) = eligible.first else { return expired ? .expired : .noEntry }
            if eligible.count > 1, rank(eligible[0]) == rank(eligible[1]) { return .ambiguous }
            return .candidate(.init(identity: .init(account: key.account, organization: key.organization),
                credential: .init(accessToken: entry.token!, subscriptionType: entry.subscriptionType,
                                  expiresAt: entry.expiresAt), entryKey: key.canonical))
        } catch { return .unreadable }
    }
}

struct ClaudeAppConfigSnapshot: Sendable {
    let bytes: Data
    let fingerprint: Data
}

struct ClaudeAppConfigReader: Sendable {
    let detector: ClaudeAppDetector
    func snapshot() throws -> ClaudeAppConfigSnapshot {
        guard detector.detect().config == .present else { throw ClaudeAppCrypto.Failure.invalid }
        let url = detector.supportURL.appendingPathComponent("config.json")
        func stamp() throws -> String {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                throw ClaudeAppCrypto.Failure.invalid
            }
            return "\(info.st_ino)|\(info.st_size)|\(info.st_mtimespec.tv_sec)|\(info.st_mtimespec.tv_nsec)|\(info.st_ctimespec.tv_sec)|\(info.st_ctimespec.tv_nsec)"
        }
        let before = try stamp()
        let bytes = try ClaudeAppDetector.readBoundedFile(url, cap: ClaudeAppDetector.configByteCap)
        guard try stamp() == before else { throw ClaudeAppCrypto.Failure.invalid }
        return .init(bytes: bytes, fingerprint: Data(SHA256.hash(data: bytes + Data(before.utf8))))
    }
    func unchanged(_ fingerprint: Data) -> Bool {
        (try? snapshot().fingerprint) == fingerprint
    }
}
