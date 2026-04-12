// SyncHelpers.swift
// Shared URL-resolution and cache-path helpers used by all sync types.

import Foundation

/// Derive a sibling file URL from the configured vocab URL by substituting `filename`
/// for "vocab.json".  Checks UserDefaults "vocabUrl" first, then the VOCAB_URL
/// environment variable.  Falls back to `fallbackEnvVar` if provided.
/// Returns nil if no base URL is configured or if the substitution produces no change.
func derivedURL(replacing filename: String, fallbackEnvVar: String? = nil) -> URL? {
    func substitute(_ base: String) -> URL? {
        let derived = base.replacingOccurrences(of: "vocab.json", with: filename)
        guard derived != base, let url = URL(string: derived) else { return nil }
        return url
    }
    if let s = UserDefaults.standard.string(forKey: VocabSync.userDefaultsKey), !s.isEmpty,
       let url = substitute(s) { return url }
    if let s = ProcessInfo.processInfo.environment["VOCAB_URL"], !s.isEmpty,
       let url = substitute(s) { return url }
    if let envVar = fallbackEnvVar,
       let s = ProcessInfo.processInfo.environment[envVar], !s.isEmpty,
       let url = URL(string: s) { return url }
    return nil
}

/// Build a URLRequest for the given URL, adding the GitHub PAT Authorization header
/// if one is configured. Used by all Sync types to support private GitHub repos.
///
/// - `cachePolicy`: defaults to `.reloadIgnoringLocalCacheData` for JSON data files that
///   change on each publish. Pass `.returnCacheDataElseLoad` for static assets like images.
func authenticatedRequest(
    for url: URL,
    cachePolicy: URLRequest.CachePolicy = .reloadIgnoringLocalCacheData
) -> URLRequest {
    var request = URLRequest(url: url, cachePolicy: cachePolicy)
    if let pat = SetupHandler.resolvedVocabPAT() {
        request.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
    }
    return request
}

/// Return the URL for a file in the user's Documents directory, creating the
/// directory if needed.
func documentsURL(filename: String) throws -> URL {
    let docs = try FileManager.default.url(
        for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    return docs.appendingPathComponent(filename)
}
