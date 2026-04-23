// CounterCorpus.swift
// Observable state for the counter corpus.
// Loads counters.json (from cache or download) and tracks per-counter
// enrollment state from quiz.sqlite (ebisu_models + learned tables).
//
// Each counter has two facets:
//   "meaning-to-reading"        — word_type="counter", word_id="{id}"
//   "counter-number-to-reading" — word_type="counter", word_id="{id}"

import Foundation
import GRDB

// MARK: - CounterItem

/// One counter in the corpus, enriched with the user's enrollment state.
struct CounterItem: Identifiable {
    let counter: Counter
    /// Overall enrollment state derived from both facets.
    /// .learning if either facet is learning; .known if both facets are known; .unknown otherwise.
    var state: FacetState = .unknown

    var id: String { counter.id }

    /// Compute document sources by looking up the counter's jmdict ID in the vocab corpus.
    /// Falls back to category-based mapping if no jmdict reference.
    func sources(in corpus: any Sequence<VocabItem>) -> [String] {
        if let jmdictId = counter.jmdict?.id {
            let matches = Array(corpus).filter { $0.id == jmdictId }
            let sourcesSet = Set(matches.flatMap(\.sources))
            if !sourcesSet.isEmpty {
                return Array(sourcesSet).sorted()
            }
        }
        // Fallback to category-based mapping if no jmdict match
        switch counter.category {
        case "Absolutely Must Know", "Must Know":
            return ["Counters/Counters-Must-Know"]
        case "Common":
            return ["Counters/Counters-Common"]
        default:
            return ["Counters/Counters-Common"]
        }
    }

    func matches(filter: VocabFilter) -> Bool {
        switch filter {
        case .notYetLearning: return state == .unknown
        case .learning:       return state == .learning
        case .known:          return state == .known
        }
    }
}

// MARK: - CounterCorpus

@Observable
@MainActor
final class CounterCorpus {
    private(set) var items: [CounterItem] = []
    private(set) var isLoading = false
    private(set) var syncError: String? = nil

    /// Lookup by JMDict ID — used by WordDetailSheet to find counters for a vocab word.
    func items(forJMDictId jmdictId: String) -> [CounterItem] {
        items.filter { $0.counter.jmdict?.id == jmdictId }
    }

    // MARK: - Load

    func load(db: QuizDB, download: Bool = false) async {
        isLoading = true
        syncError = nil
        defer { isLoading = false }

        var counters: [Counter]?

        if download || CounterSync.cached() == nil {
            do {
                counters = try await CounterSync.sync()
            } catch {
                counters = CounterSync.cached()
                if counters == nil {
                    syncError = error.localizedDescription
                    return
                }
                print("[CounterCorpus] download failed, using cache: \(error.localizedDescription)")
            }
        } else {
            counters = CounterSync.cached()
        }

        guard let counters else {
            syncError = "No counter data available."
            return
        }

        let ebisuRecords = (try? await db.enrolledCounterRecords()) ?? []
        let learnedMap   = (try? await db.allLearnedFacets()) ?? [:]

        var learningIds: Set<String> = []
        for r in ebisuRecords { learningIds.insert(r.wordId) }

        items = counters.map { counter in
            let cid = counter.id
            let isLearning = learningIds.contains(cid)
            let meaningKnown = learnedMap["\(cid):meaning-to-reading"] != nil
            let numberKnown  = learnedMap["\(cid):counter-number-to-reading"] != nil
            let isKnown = meaningKnown && numberKnown
            let state: FacetState = isLearning ? .learning : (isKnown ? .known : .unknown)
            return CounterItem(counter: counter, state: state)
        }
        print("[CounterCorpus] loaded \(items.count) counter(s)")
    }

    // MARK: - Learning actions

    /// Enroll a counter for learning (creates two ebisu_models rows).
    func setCounterLearning(counterId: String, db: QuizDB) async {
        guard let idx = items.firstIndex(where: { $0.id == counterId }) else { return }
        do {
            try await db.setFacetLearning(wordType: "counter", wordId: counterId,
                                           quizType: "meaning-to-reading")
            try await db.setFacetLearning(wordType: "counter", wordId: counterId,
                                           quizType: "counter-number-to-reading")
            items[idx].state = .learning
        } catch {
            print("[CounterCorpus] setCounterLearning error for \(counterId): \(error)")
        }
    }

    /// Mark a counter as known (moves both facets to the learned table).
    func setCounterKnown(counterId: String, db: QuizDB) async {
        guard let idx = items.firstIndex(where: { $0.id == counterId }) else { return }
        do {
            try await db.setFacetKnown(wordType: "counter", wordId: counterId,
                                        quizType: "meaning-to-reading")
            try await db.setFacetKnown(wordType: "counter", wordId: counterId,
                                        quizType: "counter-number-to-reading")
            items[idx].state = .known
        } catch {
            print("[CounterCorpus] setCounterKnown error for \(counterId): \(error)")
        }
    }

    /// Clear a counter back to unknown (removes both facets).
    func clearCounter(counterId: String, db: QuizDB) async {
        guard let idx = items.firstIndex(where: { $0.id == counterId }) else { return }
        do {
            try await db.setFacetUnknown(wordType: "counter", wordId: counterId,
                                          quizType: "meaning-to-reading")
            try await db.setFacetUnknown(wordType: "counter", wordId: counterId,
                                          quizType: "counter-number-to-reading")
            items[idx].state = .unknown
        } catch {
            print("[CounterCorpus] clearCounter error for \(counterId): \(error)")
        }
    }

    // MARK: - Re-download

    func redownload(db: QuizDB) async {
        await load(db: db, download: true)
    }
}
