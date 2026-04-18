// GrammarStore.swift
// Observable wrapper around the optional GrammarManifest, injected via SwiftUI environment.
// Avoids threading GrammarManifest? as an explicit prop through every intermediate view.

import Foundation

@Observable final class GrammarStore {
    var manifest: GrammarManifest? = nil

    /// One canonical topic ID per equivalence group (lexicographically first among group members).
    /// Used to count enrolled grammar groups without double-counting equivalent topics.
    var canonicalTopicIds: Set<String> {
        guard let manifest else { return [] }
        var seen: Set<String> = []
        var canonical: Set<String> = []
        for (prefixedId, topic) in manifest.topics {
            let group = ([prefixedId] + (topic.equivalenceGroup ?? [])).sorted()
            let representative = group[0]
            if seen.insert(representative).inserted {
                canonical.insert(representative)
            }
        }
        return canonical
    }
}
