// CorpusStore.swift
// Observable wrapper around the document corpus entries, injected via SwiftUI environment.
// Avoids threading [CorpusEntry] as an explicit prop through every intermediate view.

import Foundation

@Observable final class CorpusStore {
    var entries: [CorpusEntry] = []
    var images: [CorpusImageEntry] = []

    /// Base URL for resolving image paths from corpus documents.
    /// Derived from the vocab URL by dropping "vocab.json", e.g.:
    ///   https://raw.githubusercontent.com/USER/REPO/main/
    /// An image at repoPath "doc-name/1-usagi.jpg" resolves to:
    ///   baseURL?.appendingPathComponent("doc-name/1-usagi.jpg")
    var baseURL: URL?
}
