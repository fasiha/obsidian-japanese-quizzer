// AudioFileFinder.swift
// Resolves an audio filename to a URL using two sources:
//   1. Pug's own Documents folder (filename match only, ignoring subdirectories)
//   2. A security-scoped bookmark to an external folder (e.g. the Obsidian vault)
//
// This is an opt-in feature. Callers that get nil can silently hide any audio UI.

import Foundation

/// A timed audio clip extracted from a Markdown `<audio data-src="…#t=START,END" />` tag.
struct AudioClip: Equatable {
    let audioFile: String   // filename only, e.g. "Shiki no Uta.m4a"
    let start: Double       // clip start time in seconds
    let end: Double         // clip end time in seconds
}

enum AudioFileFinder {
    /// Returns `true` if `filename` is accessible in either source.
    /// Starts and stops external folder security-scoped access internally — safe to call
    /// from a background task without leaking the security scope.
    static func fileExists(for filename: String, externalFolderBookmark: Data?) -> Bool {
        // Step 1: Pug's own Documents folder (no security scope needed).
        if let docs = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) {
            let candidate = docs.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: candidate.path) {
                print("[AudioFileFinder] Found \(filename) in Documents: \(candidate.path)")
                return true
            } else {
                print("[AudioFileFinder] Not in Documents: \(candidate.path)")
            }
        } else {
            print("[AudioFileFinder] Could not resolve Documents folder")
        }

        // Step 2: Security-scoped external folder bookmark.
        guard let bookmarkData = externalFolderBookmark else {
            print("[AudioFileFinder] No external folder bookmark configured")
            return false
        }
        var isStale = false
        guard let folderURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withoutUI,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), !isStale else {
            print("[AudioFileFinder] Bookmark resolution failed (stale or error)")
            return false
        }
        guard folderURL.startAccessingSecurityScopedResource() else {
            print("[AudioFileFinder] Failed to start security-scoped access")
            return false
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }
        let found = FileManager.default.fileExists(atPath: folderURL.appendingPathComponent(filename).path)
        print("[AudioFileFinder] External folder check: \(found ? "found" : "not found") \(filename)")
        return found
    }

    /// Returns the file URL for `filename` if found in either source, or `nil` if not found.
    ///
    /// When the file is found in the external folder, `folderURL` is non-nil and security-scoped
    /// resource access has already been started on it. **The caller must call
    /// `folderURL.stopAccessingSecurityScopedResource()` when finished reading the file.**
    ///
    /// When the file is found in Documents, `folderURL` is `nil` and no cleanup is needed.
    static func findURL(for filename: String, externalFolderBookmark: Data?) -> (fileURL: URL, folderURL: URL?)? {
        // Step 1: Pug's own Documents folder.
        if let docs = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) {
            let candidate = docs.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: candidate.path) {
                print("[AudioFileFinder] Resolving \(filename) → \(candidate.path)")
                return (candidate, nil)
            }
        }

        // Step 2: Security-scoped external folder.
        guard let bookmarkData = externalFolderBookmark else {
            print("[AudioFileFinder] Could not resolve \(filename): no external folder")
            return nil
        }
        var isStale = false
        guard let folderURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withoutUI,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), !isStale else {
            print("[AudioFileFinder] Could not resolve external folder bookmark")
            return nil
        }
        guard folderURL.startAccessingSecurityScopedResource() else {
            print("[AudioFileFinder] Could not start security-scoped access")
            return nil
        }
        let candidate = folderURL.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: candidate.path) {
            print("[AudioFileFinder] Resolving \(filename) → \(candidate.path) (external)")
            return (candidate, folderURL)  // caller must stop access on folderURL
        }
        folderURL.stopAccessingSecurityScopedResource()
        print("[AudioFileFinder] Could not resolve \(filename) in external folder")
        return nil
    }
}
