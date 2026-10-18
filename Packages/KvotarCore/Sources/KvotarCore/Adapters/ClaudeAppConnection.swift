import Foundation

/// Credential-source state, independent of quota verdicts and polling health.
public struct ClaudeAppConnection: Sendable, Equatable {
    public enum State: String, Sendable, Codable {
        case unavailable, signInRequired, ready, permissionRequired, expired, ambiguous, accountChanged
        case noEntry, unreadable, connected, codeIdentityDiffers
    }
    public var state: State
    public var gate: Bool
    public var codeAbsent: Bool
    public var appPresent: Bool
    public var usingApp: Bool
    public init(state: State = .unavailable, gate: Bool = false,
                appPresent: Bool = false, codeAbsent: Bool = false, usingApp: Bool = false) {
        self.codeAbsent = codeAbsent
        self.state = state; self.gate = gate; self.appPresent = appPresent; self.usingApp = usingApp
    }
    public var offersConnection: Bool {
        gate && [.ready, .permissionRequired, .noEntry, .accountChanged].contains(state)
    }
    public var isHistorical: Bool {
        usingApp && state != .connected && state != .codeIdentityDiffers
    }
}

/// Only nonsecret connection metadata is durable. The macOS grant itself belongs to macOS.
public struct ClaudeAppBinding: Sendable, Codable, Equatable {
    public var identityDigest: String?
    public var permissionDenied: Bool
    public var connectionRequested: Bool
    public var requiresReconnect: Bool
    public init(identityDigest: String? = nil, permissionDenied: Bool = false,
                requiresReconnect: Bool = false, connectionRequested: Bool = false) {
        self.identityDigest = identityDigest; self.permissionDenied = permissionDenied
        self.requiresReconnect = requiresReconnect
        self.connectionRequested = connectionRequested
    }
}
