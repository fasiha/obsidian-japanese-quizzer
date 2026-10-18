// DrillBatch.swift
// Pure logic for drill mode: which vocabulary words share a sentence or a document with the
// current word, and the order in which a drill batch joins the end of the quiz queue.
// No database or UI access, so the fuzz harness (TestHarness --fuzz drill) can exercise it.
// Design notes: docs/TODO-drill-mode.md.

import Foundation

// MARK: - Sibling index

/// Groups vocabulary words by the sentence they occur in (story title + context prose) and by
/// the document they occur in (story title). Built once per quiz session from the cached vocab
/// manifest, so drill taps and button counts never re-decode vocab.json.
struct DrillIndex {
    /// One sentence: the story it belongs to and its context prose.
    struct Sentence: Hashable {
        let source: String
        let context: String
    }

    private var sentencesByWord: [String: Set<Sentence>] = [:]
    private var wordsBySentence: [Sentence: Set<String>] = [:]
    private var sourcesByWord: [String: Set<String>] = [:]
    private var wordsBySource: [String: Set<String>] = [:]

    init(manifest: VocabManifest) {
        for word in manifest.words {
            for source in word.sources {
                sourcesByWord[word.id, default: []].insert(source)
                wordsBySource[source, default: []].insert(word.id)
            }
            // A reference without context has no sentence to share, so it joins no sentence group.
            for (source, references) in word.references ?? [:] {
                for reference in references {
                    guard let context = reference.context, !context.isEmpty else { continue }
                    let sentence = Sentence(source: source, context: context)
                    sentencesByWord[word.id, default: []].insert(sentence)
                    wordsBySentence[sentence, default: []].insert(word.id)
                }
            }
        }
    }

    /// Words that share at least one sentence with `wordId`. Never contains `wordId` itself.
    func sentenceSiblings(of wordId: String) -> Set<String> {
        var siblings = Set<String>()
        for sentence in sentencesByWord[wordId] ?? [] {
            siblings.formUnion(wordsBySentence[sentence] ?? [])
        }
        siblings.remove(wordId)
        return siblings
    }

    /// Words that appear in at least one document `wordId` appears in. Never contains `wordId` itself.
    func documentSiblings(of wordId: String) -> Set<String> {
        var siblings = Set<String>()
        for source in sourcesByWord[wordId] ?? [] {
            siblings.formUnion(wordsBySource[source] ?? [])
        }
        siblings.remove(wordId)
        return siblings
    }
}

// MARK: - Batch ordering

/// One enrolled sibling that a drill could add, with its current recall (lower = more urgent).
struct DrillCandidate: Equatable {
    let wordId: String
    let recall: Double
}

/// Orders a drill batch for appending to the quiz queue ("noisy sort").
///
/// 1. Drop candidates whose word ID is already seen this session or already queued. Keep only
///    the first candidate for each word ID.
/// 2. Sort weakest-first (ascending recall). The word ID breaks ties, so the order is deterministic.
/// 3. Walk left to right, swapping each adjacent pair with probability `swapProbability`.
///    A swap can cascade, so a word can slip a few places further back. This is intentional.
///
/// The result is a permutation of the filtered candidates: no word is dropped or duplicated.
nonisolated func drillBatch<Generator: RandomNumberGenerator>(
    siblings: [DrillCandidate],
    seen: Set<String>,
    queued: Set<String>,
    swapProbability: Double,
    using generator: inout Generator
) -> [String] {
    var admittedIds = Set<String>()
    var batch: [DrillCandidate] = []
    for candidate in siblings where !seen.contains(candidate.wordId) && !queued.contains(candidate.wordId) {
        if admittedIds.insert(candidate.wordId).inserted {
            batch.append(candidate)
        }
    }

    batch.sort { ($0.recall, $0.wordId) < ($1.recall, $1.wordId) }

    for index in batch.indices.dropLast() {
        if Double.random(in: 0..<1, using: &generator) < swapProbability {
            batch.swapAt(index, index + 1)
        }
    }
    return batch.map(\.wordId)
}
