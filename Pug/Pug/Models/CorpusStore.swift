// CorpusStore.swift
// Observable wrapper around the document corpus entries, injected via SwiftUI environment.
// Avoids threading [CorpusEntry] as an explicit prop through every intermediate view.

import Foundation

@Observable final class CorpusStore {
    var entries: [CorpusEntry] = []
}
