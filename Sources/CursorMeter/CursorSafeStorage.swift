import CommonCrypto
import Darwin
import Foundation
import LocalAuthentication
import Security

/// Serializes access to Cursor's encryption key; only the derived key lives in memory.
final class CursorSafeStorage: @unchecked Sendable {
    enum SecretResult: Equatable, Sendable {
        case found(Data), missing, authorizationRequired, unavailable
    }
    enum DecryptionResult: Equatable, Sendable {
        case plaintext(String), authorizationRequired, unavailable
    }

    private let lock = NSLock()
    private var cachedKey: Data?
    private let readSecret: @Sendable (String, Bool) -> SecretResult

    init(readSecret: @escaping @Sendable (String, Bool) -> SecretResult = CursorSafeStorage.readSecret) {
        self.readSecret = readSecret
    }

    func decrypt(_ ciphertext: Data, allowInteraction: Bool) -> DecryptionResult {
        lock.lock(); defer { lock.unlock() }
        if let cachedKey, let plaintext = Self.decrypt(ciphertext, key: cachedKey) {
            return .plaintext(plaintext)
        }
        cachedKey = nil
        for account in ["Cursor Key", "Cursor"] {
            var result = readSecret(account, false)
            if result == .missing { continue }
            if result == .authorizationRequired, allowInteraction {
                result = readSecret(account, true)
            }
            switch result {
            case .found(let password):
                guard let key = Self.deriveKey(password),
                      let plaintext = Self.decrypt(ciphertext, key: key) else { return .unavailable }
                cachedKey = key
                return .plaintext(plaintext)
            case .authorizationRequired: return .authorizationRequired
            case .missing, .unavailable: return .unavailable
            }
        }
        return .unavailable
    }

    private static let legacyUIFailPolicy: String? = {
        guard let library = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW) else { return nil }
        defer { dlclose(library) }
        guard let symbol = dlsym(library, "kSecUseAuthenticationUIFail"),
              let value = symbol.assumingMemoryBound(to: CFString?.self).pointee else { return nil }
        return value as String
    }()

    static func query(account: String, allowInteraction: Bool,
                      uiFailPolicy: String? = CursorSafeStorage.legacyUIFailPolicy) -> [String: Any]? {
        guard allowInteraction || uiFailPolicy != nil else { return nil }
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "Cursor Safe Storage",
         kSecAttrAccount as String: account,
         kSecMatchLimit as String: kSecMatchLimitOne,
         kSecReturnData as String: true,
         kSecUseAuthenticationContext as String: context]
        // Legacy Keychain ACL prompts also need the explicit UI-fail policy.
        // Resolve its real Security value; if unavailable, never issue a background query.
        if !allowInteraction { query[kSecUseAuthenticationUI as String] = uiFailPolicy }
        return query
    }

    private static func readSecret(account: String, allowInteraction: Bool) -> SecretResult {
        guard let query = query(account: account, allowInteraction: allowInteraction) else { return .unavailable }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let password = item as? Data, !password.isEmpty else { return .unavailable }
            return .found(password)
        case errSecItemNotFound: return .missing
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled: return .authorizationRequired
        default: return .unavailable
        }
    }

    private static func deriveKey(_ password: Data) -> Data? {
        guard !password.isEmpty else { return nil }
        let salt = Array("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let status = key.withUnsafeMutableBytes { output in
            password.withUnsafeBytes { input in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                    input.bindMemory(to: Int8.self).baseAddress, password.count,
                    salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                    output.bindMemory(to: UInt8.self).baseAddress, kCCKeySizeAES128)
            }
        }
        return status == kCCSuccess ? key : nil
    }

    private static func decrypt(_ ciphertext: Data, key: Data) -> String? {
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        let capacity = ciphertext.count + kCCBlockSizeAES128
        var output = Data(count: capacity)
        var written = 0
        let status = output.withUnsafeMutableBytes { destination in
            key.withUnsafeBytes { keyBytes in
                ciphertext.withUnsafeBytes { source in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, key.count, iv, source.baseAddress, ciphertext.count,
                        destination.baseAddress, capacity, &written)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return String(data: output.prefix(written), encoding: .utf8)
    }
}
