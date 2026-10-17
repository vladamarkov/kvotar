import Foundation
import Security
import LocalAuthentication
import CommonCrypto

enum ClaudeAppKeyRead: Sendable, Equatable {
    case password(Data)
    case permissionDenied
    case unavailable
}

/// A read-only seam: no Keychain mutation or credential-renewal operation exists here.
struct ClaudeAppKeychainOperations: Sendable {
    var interaction: @Sendable () -> (OSStatus, Bool)
    var setInteraction: @Sendable (Bool) -> OSStatus
    var read: @Sendable (Bool) -> ClaudeAppKeyRead

    static let live = Self(
        interaction: {
            var allowed = DarwinBoolean(false)
            let status = SecKeychainGetUserInteractionAllowed(&allowed)
            return (status, allowed.boolValue)
        },
        setInteraction: { SecKeychainSetUserInteractionAllowed($0) },
        read: { allowed in
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "Claude Safe Storage",
                kSecAttrAccount as String: "Claude Key",
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            if !allowed {
                let context = LAContext()
                context.interactionNotAllowed = true
                query[kSecUseAuthenticationContext as String] = context
                query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
            }
            var value: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &value)
            switch status {
            case errSecSuccess:
                guard let bytes = value as? Data else { return .unavailable }
                return .password(bytes)
            case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
                return .permissionDenied
            default: return .unavailable
            }
        })
}

struct ClaudeAppSafeStorage: Sendable {
    private static let lock = NSLock()
    let operations: ClaudeAppKeychainOperations
    init(operations: ClaudeAppKeychainOperations = .live) { self.operations = operations }

    func read(allowInteraction: Bool) -> ClaudeAppKeyRead {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        if allowInteraction { return operations.read(true) }
        let (status, prior) = operations.interaction()
        guard status == errSecSuccess else { return .unavailable }
        // File-based login Keychain ACLs can ignore LAContext/UIFail (FB16959400).
        // Deliberately retain the deprecated process switch, as Chromium does:
        // https://github.com/chromium/chromium/blob/main/crypto/apple/scoped_keychain_user_interaction_allowed.cc
        guard operations.setInteraction(false) == errSecSuccess else { return .unavailable }
        var restored: OSStatus = errSecSuccess
        func perform() -> ClaudeAppKeyRead {
            defer { restored = operations.setInteraction(prior) }
            return operations.read(false)
        }
        let result = perform()
        return restored == errSecSuccess ? result : .unavailable
    }
}

enum ClaudeAppCrypto {
    enum Failure: Error { case invalid }
    static func derive(password: Data) throws -> Data {
        var key = Data(count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let status = key.withUnsafeMutableBytes { output in
            password.withUnsafeBytes { secret in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                    secret.bindMemory(to: Int8.self).baseAddress, password.count,
                    salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                    output.bindMemory(to: UInt8.self).baseAddress, kCCKeySizeAES128)
            }
        }
        guard status == kCCSuccess else { throw Failure.invalid }
        return key
    }

    static func decrypt(_ encoded: String, key: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128, let bytes = Data(base64Encoded: encoded),
              bytes.starts(with: Data("v10".utf8)), bytes.count > 3,
              (bytes.count - 3) % kCCBlockSizeAES128 == 0 else { throw Failure.invalid }
        let ciphertext = Data(bytes.dropFirst(3))
        var output = Data(count: ciphertext.count + kCCBlockSizeAES128)
        let capacity = output.count
        var written = 0
        let iv = [UInt8](repeating: 32, count: kCCBlockSizeAES128)
        let status = output.withUnsafeMutableBytes { destination in
            key.withUnsafeBytes { secret in
                ciphertext.withUnsafeBytes { input in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding), secret.baseAddress, key.count, iv,
                            input.baseAddress, ciphertext.count, destination.baseAddress, capacity, &written)
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.invalid }
        output.count = written
        return output
    }
}
