// TransitivePairCorpus.swift
// Observable state for the transitive-intransitive verb pair corpus.
// Loads transitive-pairs.json (from cache or download), and tracks per-pair
// enrollment state from quiz.sqlite (ebisu_models + learned tables).
//
// Each pair has a single facet: "pair-discrimination".
// word_type = "transitive-pair", word_id = "{intransitive_jmdict_id}-{transitive_jmdict_id}"

import Foundation
import GRDB

// MARK: - TransitivePairItem

/// One pair in the corpus, enriched with the user's enrollment state.
struct TransitivePairItem: Identifiable {
    let pair: TransitivePair
    var state: FacetState = .unknown

    /// Precomputed furigana segments for the intransitive verb (nil = kana-only or no match).
    var intransitiveFurigana: [FuriganaSegment]?
    /// Precomputed furigana segments for the transitive verb.
    var transitiveFurigana: [FuriganaSegment]?

    var id: String { pair.id }

    /// Does this pair match the given filter?
    func matches(filter: VocabFilter) -> Bool {
        switch filter {
        case .notYetLearning: return state == .unknown
        case .learning:       return state == .learning
        case .known:          return state == .known
        }
    }
}

// MARK: - TransitivePairCorpus

@Observable
@MainActor
final class TransitivePairCorpus {
    private(set) var items: [TransitivePairItem] = []
    private(set) var isLoading = false
    private(set) var syncError: String? = nil

    // MARK: - Load

    /// Load (or reload) the pair corpus.
    /// If `download` is true, always fetches from the remote URL first.
    func load(db: QuizDB, jmdict: any DatabaseReader, download: Bool = false) async {
        isLoading = true
        syncError = nil
        defer { isLoading = false }

        var pairs: [TransitivePair]?

        if download || TransitivePairSync.cached() == nil {
            do {
                pairs = try await TransitivePairSync.sync()
            } catch {
                pairs = TransitivePairSync.cached()
                if pairs == nil {
                    syncError = error.localizedDescription
                    return
                }
                print("[TransitivePairCorpus] download failed, using cache: \(error.localizedDescription)")
            }
        } else {
            pairs = TransitivePairSync.cached()
        }

        guard let pairs else {
            syncError = "No transitive-pair data available."
            return
        }

        // Query ebisu_models and learned tables for transitive-pair state.
        let ebisuRecords = (try? await db.enrolledTransitivePairRecords()) ?? []
        let learnedMap = (try? await db.allLearnedFacets()) ?? [:]

        var learningIds: Set<String> = []
        for r in ebisuRecords { learningIds.insert(r.wordId) }

        items = pairs.map { pair in
            let pairId = pair.id
            let isLearning = learningIds.contains(pairId)
            let isKnown = learnedMap["\(pairId):pair-discrimination"] != nil
            let state: FacetState = isLearning ? .learning : (isKnown ? .known : .unknown)

            // Precompute furigana for each member using first kanji form + kana reading
            let intrFuri: [FuriganaSegment]? = pair.intransitive.kanji.first.flatMap {
                lookupFurigana(text: $0, reading: pair.intransitive.kana, db: jmdict)
            }
            let trFuri: [FuriganaSegment]? = pair.transitive.kanji.first.flatMap {
                lookupFurigana(text: $0, reading: pair.transitive.kana, db: jmdict)
            }

            return TransitivePairItem(pair: pair, state: state,
                                       intransitiveFurigana: intrFuri,
                                       transitiveFurigana: trFuri)
        }
        print("[TransitivePairCorpus] loaded \(items.count) pair(s)")
    }

    // MARK: - Learning actions

    /// Enroll a pair for learning (creates one ebisu_models row with quiz_type "pair-discrimination").
    func setPairLearning(pairId: String, db: QuizDB) async {
        guard let idx = items.firstIndex(where: { $0.id == pairId }) else { return }
        do {
            try await db.setFacetLearning(wordType: "transitive-pair", wordId: pairId,
                                           quizType: "pair-discrimination")
            items[idx].state = .learning
        } catch {
            print("[TransitivePairCorpus] setPairLearning error for \(pairId): \(error)")
        }
    }

    /// Mark a pair as known (moves to learned table).
    func setPairKnown(pairId: String, db: QuizDB) async {
        guard let idx = items.firstIndex(where: { $0.id == pairId }) else { return }
        do {
            try await db.setFacetKnown(wordType: "transitive-pair", wordId: pairId,
                                        quizType: "pair-discrimination")
            items[idx].state = .known
        } catch {
            print("[TransitivePairCorpus] setPairKnown error for \(pairId): \(error)")
        }
    }

    /// Clear a pair back to unknown.
    func clearPair(pairId: String, db: QuizDB) async {
        guard let idx = items.firstIndex(where: { $0.id == pairId }) else { return }
        do {
            try await db.setFacetUnknown(wordType: "transitive-pair", wordId: pairId,
                                          quizType: "pair-discrimination")
            items[idx].state = .unknown
        } catch {
            print("[TransitivePairCorpus] clearPair error for \(pairId): \(error)")
        }
    }

    // MARK: - Re-download

    func redownload(db: QuizDB, jmdict: any DatabaseReader) async {
        await load(db: db, jmdict: jmdict, download: true)
    }
}
