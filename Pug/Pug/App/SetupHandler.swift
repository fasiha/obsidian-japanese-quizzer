// SetupHandler.swift
// Handles the japanquiz://setup?key=sk-ant-...&vocabUrl=https://... deep link.
// Saves the API key to Keychain and the vocab URL to UserDefaults.

import Foundation
import Security

enum SetupHandler {
    private static let keychainService = "me.aldebrn.Pug"
    private static let keychainAccount = "anthropic-api-key"

    /// Handle a `japanquiz://setup` deep link.
    /// Saves `key` to Keychain and `vocabUrl` to UserDefaults.
    /// Returns true if the URL was recognized as a setup link.
    @discardableResult
    static func handle(url: URL) -> Bool {
        guard url.scheme == "japanquiz",
              url.host == "setup",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return false }

        let params = components.queryItems?.reduce(into: [String: String]()) { dict, item in
            if let value = item.value { dict[item.name] = value }
        } ?? [:]

        if let key = params["key"], !key.isEmpty {
            saveApiKey(key)
            print("[Setup] API key saved to Keychain")
        }
        if let vocabUrl = params["vocabUrl"], !vocabUrl.isEmpty {
            UserDefaults.standard.set(vocabUrl, forKey: VocabSync.userDefaultsKey)
            print("[Setup] Vocab URL saved: \(vocabUrl)")
        }
        return true
    }

    /// Resolve the Anthropic API key: Keychain first, then ANTHROPIC_API_KEY env var.
    static func resolvedApiKey() -> String {
        if let key = loadApiKey(), !key.isEmpty { return key }
        return ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
    }

    // MARK: - Keychain

    private static func loadApiKey() -> String? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func saveApiKey(_ key: String) {
        let data = Data(key.utf8)
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }
}
