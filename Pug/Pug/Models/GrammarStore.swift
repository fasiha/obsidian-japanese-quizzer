// GrammarStore.swift
// Observable wrapper around the optional GrammarManifest, injected via SwiftUI environment.
// Avoids threading GrammarManifest? as an explicit prop through every intermediate view.

import Foundation

@Observable final class GrammarStore {
    var manifest: GrammarManifest? = nil
}
