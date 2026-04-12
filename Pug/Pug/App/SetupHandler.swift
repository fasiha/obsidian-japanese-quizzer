// SetupHandler.swift
// Handles the japanquiz://setup?key=sk-ant-...&vocabUrl=https://...&token=github_pat_... deep link.
// Saves the Anthropic API key and GitHub PAT to Keychain; saves the vocab URL to UserDefaults.

import Foundation
import Security

enum SetupHandler {
    private static let keychainService = "me.aldebrn.Pug"
    private static let keychainAccount = "anthropic-api-key"
    private static let keychainAccountPAT = "vocab-url-pat"

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
        if let token = params["token"], !token.isEmpty {
            saveToKeychain(token, account: keychainAccountPAT)
            print("[Setup] GitHub PAT saved to Keychain")
        }
        return true
    }

    /// Resolve the Anthropic API key: Keychain first, then ANTHROPIC_API_KEY env var.
    static func resolvedApiKey() -> String {
        if let key = loadApiKey(), !key.isEmpty { return key }
        return ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
    }

    /// Resolve the GitHub PAT for private repo access: Keychain first, then VOCAB_URL_PAT env var.
    /// Returns nil if no PAT is configured (public repo or local dev without auth).
    static func resolvedVocabPAT() -> String? {
        if let pat = loadFromKeychain(account: keychainAccountPAT), !pat.isEmpty { return pat }
        if let pat = ProcessInfo.processInfo.environment["VOCAB_URL_PAT"], !pat.isEmpty { return pat }
        return nil
    }

    // MARK: - Keychain

    private static func loadApiKey() -> String? { loadFromKeychain(account: keychainAccount) }
    private static func saveApiKey(_ key: String) { saveToKeychain(key, account: keychainAccount) }

    private static func loadFromKeychain(account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func saveToKeychain(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }
}
