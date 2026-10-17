import Foundation
import KvotarCore

public struct ClaudeAppCard: Sendable, Equatable {
    public let title: String
    public let detail: String
    public let action: String?
    public let permissionNote: String?
}

extension DisplayFormatter {
    public static func claudeAppCard(_ connection: ClaudeAppConnection?) -> ClaudeAppCard? {
        guard let connection, (connection.codeAbsent && connection.appPresent) || connection.usingApp else { return nil }
        let action: String? = connection.offersConnection ? {
            switch connection.state {
            case .permissionRequired: return "Retry"
            case .accountChanged: return "Connect again"
            default: return "Connect Claude app"
            }
        }() : nil
        let detail: String
        switch connection.state {
        case .connected: return nil
        case .codeIdentityDiffers:
            return .init(title: "Using the Claude app", detail: ExplanationRegistry.claudeCodeIdentityDiffers,
                         action: nil, permissionNote: nil)
        case .unavailable:
            detail = connection.usingApp ? "The Claude app or its sign-in file is unavailable. Earlier readings are historical."
                : "Kvotar cannot see the Claude app’s chat sign-in. Sign in to Claude Code, then re-check."
        case .ready: detail = "Connect the Claude app to read its account quota."
        case .permissionRequired: detail = "Access to the Claude app’s sign-in was not granted. Use the button to ask macOS again."
        case .expired: detail = "The Claude app’s sign-in expired. Wait for the Claude app to renew it."
        case .ambiguous: detail = "The Claude app has more than one eligible sign-in. Kvotar cannot choose one."
        case .accountChanged: detail = ExplanationRegistry.claudeAppAccountChanged
        case .noEntry: detail = "Kvotar cannot find an eligible sign-in in the Claude app."
        case .unreadable: detail = "The Claude app’s sign-in could not be read. Re-check after the app finishes updating it."
        }
        let note = action != nil && connection.state != .accountChanged
            ? "Always Allow avoids repeat prompts while the grant, item and Kvotar’s signing identity stay unchanged; macOS keeps the grant."
            : nil
        return .init(title: "Claude app not connected", detail: detail, action: action, permissionNote: note)
    }

    public static func claudeAppSource(_ connection: ClaudeAppConnection?) -> String? {
        guard let connection, connection.usingApp else { return nil }
        return connection.isHistorical ? "Source: Claude app · historical reading" : "Source: Claude app"
    }

    static func claudeExpiredLine(_ snapshot: QuotaSnapshot?) -> String {
        snapshot?.source == .claudeApp
            ? "Claude app sign-in expired — waiting for the Claude app to renew it."
            : "Claude sign-in expired — open Claude Code to reconnect."
    }
}
