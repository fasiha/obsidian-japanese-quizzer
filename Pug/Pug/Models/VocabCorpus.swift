// VocabCorpus.swift
// Observable state for the published vocab corpus.
// Loads vocab.json (from cache or download), enriches each word with JMdict data,
// and tracks per-word commitment/facet state from quiz.sqlite.

import GRDB
import Foundation

// MARK: - Filter

/// Vocab browser filter. A word can match multiple filters (OR semantics on facets).
enum VocabFilter: String, CaseIterable, Sendable {
    case notYetLearning = "Not yet learning"
    case learning = "Learning"
    case known = "Learned"
}

// MARK: - VocabItem

/// One word in the corpus, enriched with JMdict data and the user's facet states.
struct VocabItem: Identifiable {
    let id: String              // JMDict entry ID
    let sources: [String]       // story titles this word appears in
    let wordText: String        // primary display form (first written form, or first kana if none)
    /// Written form and kana resolved from the first reference's annotatedForms (the annotator's
    /// vocab bullet). Nil when annotatedForms are absent or no compatible form can be found.
    /// Used for display, default form commitment, and swipe-to-learn enrollment.
    let annotatorResolved: ResolvedAnnotatorForms?
    let writtenTexts: [String]  // non-irregular orthographic (kanji/mixed) forms
    let kanaTexts: [String]     // non-irregular kana-only forms
    let senseExtras: [SenseExtra]        // per-sense data: glosses + metadata (usage notes, related/antonym xrefs, pos tags)
    let writtenForms: [WrittenFormGroup]  // furigana data from vocab.json
    let references: [String: [VocabReference]]  // corpus occurrences with context
    /// Zero-based indices of senses attested in the corpus, from vocab.json llm_sense.
    /// Empty means llm_sense was absent or had no computed indices — show all senses equally (undimmed).
    let corpusSenseIndices: [Int]
    /// Frequency in the BCCWJ corpus expressed as occurrences per million words. Nil when not matched.
    let bccwjPerMillionWords: Double?

    // Derived from DB state (ebisu_models + learned + word_commitment)
    var commitment: WordCommitment?
    var readingState: FacetState = .unknown  // derived from reading facets
    var kanjiState: FacetState = .unknown    // derived from kanji facets

    /// Sense indices the student has explicitly enrolled for quizzing.
    /// nil = legacy state (word committed before v10 migration) — treat as "all senses".
    /// Empty array = explicitly no senses selected — quiz falls back to sense 0.
    var committedSenseIndices: [Int]? {
        guard let json = commitment?.senseIndices,
              let data = json.data(using: .utf8),
              let indices = try? JSONDecoder().decode([Int].self, from: data)
        else { return nil }
        return indices
    }

    /// Sense indices to display as enrolled in the UI.
    /// Expands nil (legacy "all senses") to the full index range.
    func committedSensesForDisplay(totalSenseCount: Int) -> [Int] {
        committedSenseIndices ?? Array(0 ..< totalSenseCount)
    }

    /// Does this word match the given filter? (OR semantics)
    func matches(filter: VocabFilter) -> Bool {
        switch filter {
        case .notYetLearning:
            let kanjiUnknown = !hasKanjiOptions || kanjiState == .unknown
            return readingState == .unknown && kanjiUnknown
        case .learning:
            return readingState == .learning || kanjiState == .learning
        case .known:
            return readingState == .known || kanjiState == .known
        }
    }

    /// Whether this word has any kanji forms at all (determines if kanji row is shown).
    var hasKanjiOptions: Bool { !writtenTexts.isEmpty }

    /// True when every furigana segment across all written forms lacks an `rt` (superscript).
    /// These are orthographic kana variants (e.g. そっと / そうっと) — no form picker needed.
    var isKanaOnly: Bool {
        !writtenForms.isEmpty &&
        writtenForms.allSatisfy { group in
            group.forms.allSatisfy { form in
                form.furigana.allSatisfy { $0.rt == nil }
            }
        }
    }
}

// MARK: - VocabCorpus

@Observable
@MainActor
final class VocabCorpus {
    private(set) var items: [VocabItem] = []
    // TODO: add func item(for id: String) -> VocabItem? backed by a [String: VocabItem] index,
    // to replace the O(n) .first { $0.id == ... } scans in TransitivePairDetailSheet.
    private(set) var isLoading = false
    private(set) var syncError: String? = nil
    private(set) var lastSyncedAt: String? = nil

    // MARK: - Load

    /// Load (or reload) the corpus.
    ///
    /// - If `download` is true, always fetches from the remote URL first.
    /// - If `download` is false and a cached vocab.json exists, uses the cache.
    /// - If no cache exists and no URL is configured, sets `syncError`.
    func load(db: QuizDB, jmdict: any DatabaseReader, download: Bool = false) async {
        isLoading = true
        syncError = nil
        defer { isLoading = false }

        var manifest: VocabManifest?

        if download || VocabSync.cached() == nil {
            do {
                manifest = try await VocabSync.sync()
            } catch {
                // Fall back to cache if a download fails.
                manifest = VocabSync.cached()
                if manifest == nil {
                    syncError = error.localizedDescription
                    return
                }
                print("[VocabCorpus] download failed, using cache: \(error.localizedDescription)")
            }
        } else {
            manifest = VocabSync.cached()
        }

        guard let manifest else {
            syncError = "No vocab data available."
            return
        }
        lastSyncedAt = manifest.generatedAt

        // Enrich with JMdict data.
        let allIds = manifest.words.map(\.id)
        let jmdictData = (try? await QuizContext.jmdictWordData(ids: allIds, jmdict: jmdict)) ?? [:]

        // Load commitment and facet state data.
        let commitmentMap = (try? await db.allCommitments()) ?? [:]
        let learnedMap = (try? await db.allLearnedFacets()) ?? [:]
        let ebisuRecords = (try? await db.enrolledEbisuRecords()) ?? []

        // Build a set of "wordId:quizType" keys for learning facets.
        var learningFacets: Set<String> = []
        for r in ebisuRecords { learningFacets.insert("\(r.wordId):\(r.quizType)") }

        // Build items (skip words not found in JMdict).
        items = manifest.words.compactMap { entry in
            guard let jd = jmdictData[entry.id] else { return nil }
            let commitment = commitmentMap[entry.id]

            // Derive reading state from reading facets
            let readingState = Self.deriveFacetState(
                wordId: entry.id,
                facets: ["reading-to-meaning", "meaning-to-reading"],
                learningFacets: learningFacets,
                learnedMap: learnedMap
            )
            // Derive kanji state from kanji facets
            let kanjiState = Self.deriveFacetState(
                wordId: entry.id,
                facets: ["kanji-to-reading", "meaning-reading-to-kanji"],
                learningFacets: learningFacets,
                learnedMap: learnedMap
            )

            let corpusSenseIndices = entry.corpusSenseIndices

            // Resolve the annotator's preferred form from the first reference's annotatedForms.
            // Sources are stored in sorted order; use the first source's first reference entry.
            let firstAnnotatedForms: [String] = entry.sources.lazy
                .compactMap { entry.references?[$0]?.first?.annotatedForms }
                .first ?? []
            let annotatorResolved = resolveAnnotatedForms(
                annotatedForms: firstAnnotatedForms,
                writtenForms: entry.writtenForms ?? [],
                kanaTexts: jd.kanaTexts
            )

            // If the user has committed to a specific written form, use that for display
            // rather than inferring from corpus senses — the commitment is the user's
            // explicit choice and should always win.
            let preferredText = commitment?.committedWrittenText
            ?? annotatorResolved?.writtenForm.text
            ?? preferredWrittenForm(
                senseExtras: jd.senseExtras,
                activeSenseIndices: corpusSenseIndices,
                writtenForms: entry.writtenForms ?? []
            )?.text
            ?? preferredKanaForm(
                senseExtras: jd.senseExtras,
                activeSenseIndices: corpusSenseIndices,
                kanaTexts: jd.kanaTexts
            )
            ?? jd.text

            return VocabItem(
                id: entry.id,
                sources: entry.sources,
                wordText: preferredText,
                annotatorResolved: annotatorResolved,
                writtenTexts: jd.writtenTexts,
                kanaTexts: jd.kanaTexts,
                senseExtras: jd.senseExtras,
                writtenForms: entry.writtenForms ?? [],
                references: entry.references ?? [:],
                corpusSenseIndices: corpusSenseIndices,
                bccwjPerMillionWords: entry.bccwjPerMillionWords,
                commitment: commitment,
                readingState: readingState,
                kanjiState: kanjiState
            )
        }
        print("[VocabCorpus] loaded \(items.count)/\(manifest.words.count) word(s) " +
              "(\(manifest.words.count - items.count) skipped — not in JMdict)")

        // Seed sense_indices for committed words that were learned before the v10 migration.
        // Those rows have sense_indices = NULL ("all senses" legacy marker). Rather than
        // showing every JMDict sense as enrolled, we seed from the corpus-union sense indices
        // that the publish pipeline computed — the senses actually seen in the student's texts.
        // This is a one-time upgrade: once written, sense_indices is non-null and this is skipped.
        for idx in items.indices {
            guard let c = items[idx].commitment, c.senseIndices == nil else { continue }
            let seeds = items[idx].corpusSenseIndices
            guard !seeds.isEmpty else { continue }
            let wordId = items[idx].id
            try? await db.setCommittedSenseIndices(wordType: "jmdict", wordId: wordId, senseIndices: seeds)
            if let json = String(data: (try? JSONEncoder().encode(seeds)) ?? Data(), encoding: .utf8) {
                var updated = c
                updated.senseIndices = json
                items[idx].commitment = updated
            }
        }

        // Resolve placeholder furigana ('[]') for committed words that now have writtenForms.
        // This handles the migration path where v5 wrote '[]' pending a vocab sync.
        for idx in items.indices {
            guard let c = items[idx].commitment, c.furigana == "[]",
                  let resolved = defaultFuriganaJSON(for: items[idx]) as String?,
                  resolved != "[]" else { continue }
            let wordId = items[idx].id
            // Also commit all kanji characters in the resolved form.
            let kanjiJSON: String? = {
                guard let data = resolved.data(using: .utf8),
                      let segs = try? JSONDecoder().decode([FuriganaSegment].self, from: data)
                else { return nil }
                var chars: [String] = []
                for seg in segs where seg.rt != nil {
                    for scalar in seg.ruby.unicodeScalars {
                        let v = scalar.value
                        if (v >= 0x4E00 && v <= 0x9FFF) || (v >= 0x3400 && v <= 0x4DBF) || (v >= 0xF900 && v <= 0xFAFF) {
                            let s = String(scalar)
                            if !chars.contains(s) { chars.append(s) }
                        }
                    }
                }
                guard !chars.isEmpty,
                      let encoded = try? JSONEncoder().encode(chars),
                      let json = String(data: encoded, encoding: .utf8) else { return nil }
                return json
            }()
            try? await db.setCommitment(wordType: "jmdict", wordId: wordId,
                                        furigana: resolved, kanjiChars: kanjiJSON)
            items[idx].commitment = WordCommitment(wordType: "jmdict", wordId: wordId,
                                                   furigana: resolved, kanjiChars: kanjiJSON,
                                                   senseIndices: items[idx].commitment?.senseIndices)
        }
    }

    // MARK: - Facet state derivation

    /// Derive the aggregate state for a group of facets (reading or kanji).
    /// If ANY facet is learning → .learning. Else if ANY is known → .known. Else .unknown.
    private static func deriveFacetState(
        wordId: String,
        facets: [String],
        learningFacets: Set<String>,
        learnedMap: [String: LearnedFacet]
    ) -> FacetState {
        var hasLearning = false
        var hasKnown = false
        for facet in facets {
            let key = "\(wordId):\(facet)"
            if learningFacets.contains(key) { hasLearning = true }
            if learnedMap[key] != nil { hasKnown = true }
        }
        if hasLearning { return .learning }
        if hasKnown { return .known }
        return .unknown
    }

    // MARK: - Learning actions

    /// Set the reading state for a word. Also ensures word_commitment exists.
    /// When transitioning to .learning for the first time, pass senseIndicesToSeed to record
    /// which senses the student is committing to from their current navigation origin.
    func setReadingState(_ state: FacetState, wordId: String, db: QuizDB,
                         senseIndicesToSeed: [Int]? = nil,
                         preferredForm: WrittenForm? = nil) async {
        guard let idx = items.firstIndex(where: { $0.id == wordId }) else { return }
        do {
            // Ensure commitment exists
            if items[idx].commitment == nil {
                let furigana = defaultFuriganaJSON(for: items[idx], preferredForm: preferredForm)
                try await db.setCommitment(wordType: "jmdict", wordId: wordId, furigana: furigana)
                items[idx].commitment = WordCommitment(wordType: "jmdict", wordId: wordId,
                                                        furigana: furigana, kanjiChars: nil,
                                                        senseIndices: nil)
            }
            switch state {
            case .learning:
                try await db.setReadingLearning(wordType: "jmdict", wordId: wordId)
                // Seed enrolled senses from origin on first commit (when no senses are set yet).
                if items[idx].commitment?.senseIndices == nil, let seeds = senseIndicesToSeed {
                    try await db.setCommittedSenseIndices(wordType: "jmdict", wordId: wordId, senseIndices: seeds)
                    if var c = items[idx].commitment,
                       let json = String(data: (try? JSONEncoder().encode(seeds)) ?? Data(), encoding: .utf8) {
                        c.senseIndices = json
                        items[idx].commitment = c
                    }
                }
            case .known:
                try await db.setReadingKnown(wordType: "jmdict", wordId: wordId)
            case .unknown:
                try await db.setReadingUnknown(wordType: "jmdict", wordId: wordId)
                // If kanji is also unknown and we're going to unknown, clear commitment
                if items[idx].kanjiState == .unknown {
                    try await db.clearCommitment(wordType: "jmdict", wordId: wordId)
                    items[idx].commitment = nil
                }
            }
            items[idx].readingState = state
            // Enforce kanji <= reading constraint
            if state == .unknown && items[idx].kanjiState != .unknown {
                try await db.setKanjiUnknown(wordType: "jmdict", wordId: wordId)
                items[idx].kanjiState = .unknown
            }
        } catch {
            print("[VocabCorpus] setReadingState error for \(wordId): \(error)")
        }
    }

    /// Set the kanji state for a word.
    func setKanjiState(_ state: FacetState, wordId: String, kanjiChars: [String]? = nil, db: QuizDB) async {
        guard let idx = items.firstIndex(where: { $0.id == wordId }) else { return }
        do {
            switch state {
            case .learning:
                try await db.setKanjiLearning(wordType: "jmdict", wordId: wordId)
                // Update kanji_chars in commitment
                if let chars = kanjiChars {
                    let json = try String(data: JSONEncoder().encode(chars), encoding: .utf8) ?? "[]"
                    let furigana = items[idx].commitment?.furigana ?? "[]"
                    try await db.setCommitment(wordType: "jmdict", wordId: wordId,
                                               furigana: furigana, kanjiChars: json)
                    items[idx].commitment = WordCommitment(wordType: "jmdict", wordId: wordId,
                                                            furigana: furigana, kanjiChars: json,
                                                            senseIndices: items[idx].commitment?.senseIndices)
                }
            case .known:
                try await db.setKanjiKnown(wordType: "jmdict", wordId: wordId)
            case .unknown:
                try await db.setKanjiUnknown(wordType: "jmdict", wordId: wordId)
            }
            items[idx].kanjiState = state
        } catch {
            print("[VocabCorpus] setKanjiState error for \(wordId): \(error)")
        }
    }

    /// Mark all facets as known (reading + kanji if applicable).
    func markAllKnown(wordId: String, db: QuizDB) async {
        guard let idx = items.firstIndex(where: { $0.id == wordId }) else { return }
        do {
            // Ensure commitment
            if items[idx].commitment == nil {
                let furigana = defaultFuriganaJSON(for: items[idx])
                try await db.setCommitment(wordType: "jmdict", wordId: wordId, furigana: furigana)
                items[idx].commitment = WordCommitment(wordType: "jmdict", wordId: wordId,
                                                        furigana: furigana, kanjiChars: nil,
                                                        senseIndices: nil)
            }
            try await db.setReadingKnown(wordType: "jmdict", wordId: wordId)
            items[idx].readingState = .known
            if items[idx].hasKanjiOptions {
                try await db.setKanjiKnown(wordType: "jmdict", wordId: wordId)
                items[idx].kanjiState = .known
            }
        } catch {
            print("[VocabCorpus] markAllKnown error for \(wordId): \(error)")
        }
    }

    /// Clear all commitment and facets (back to fully unknown).
    func clearAll(wordId: String, db: QuizDB) async {
        guard let idx = items.firstIndex(where: { $0.id == wordId }) else { return }
        do {
            try await db.clearCommitment(wordType: "jmdict", wordId: wordId)
            items[idx].commitment = nil
            items[idx].readingState = .unknown
            items[idx].kanjiState = .unknown
        } catch {
            print("[VocabCorpus] clearAll error for \(wordId): \(error)")
        }
    }

    /// Update the committed furigana form for a word.
    func setCommittedFurigana(wordId: String, furiganaJSON: String, db: QuizDB) async {
        guard let idx = items.firstIndex(where: { $0.id == wordId }) else { return }
        do {
            let kanjiChars = items[idx].commitment?.kanjiChars
            let senseIndices = items[idx].commitment?.senseIndices
            try await db.setCommitment(wordType: "jmdict", wordId: wordId,
                                       furigana: furiganaJSON, kanjiChars: kanjiChars)
            items[idx].commitment = WordCommitment(wordType: "jmdict", wordId: wordId,
                                                    furigana: furiganaJSON, kanjiChars: kanjiChars,
                                                    senseIndices: senseIndices)
        } catch {
            print("[VocabCorpus] setCommittedFurigana error for \(wordId): \(error)")
        }
    }

    /// Update the enrolled sense indices for a committed word.
    /// Pass an explicit array — never pass nil here; nil is the legacy "all senses" marker.
    func setCommittedSenseIndices(wordId: String, senseIndices: [Int], db: QuizDB) async {
        guard let idx = items.firstIndex(where: { $0.id == wordId }) else { return }
        do {
            try await db.setCommittedSenseIndices(wordType: "jmdict", wordId: wordId, senseIndices: senseIndices)
            if var c = items[idx].commitment,
               let json = String(data: (try? JSONEncoder().encode(senseIndices)) ?? Data(), encoding: .utf8) {
                c.senseIndices = json
                items[idx].commitment = c
            }
        } catch {
            print("[VocabCorpus] setCommittedSenseIndices error for \(wordId): \(error)")
        }
    }

    // MARK: - Helpers

    /// Default furigana JSON for a word (first form of first reading group, or "[]").
    /// Returns the furigana JSON for the default committed form, preferring an explicit
    /// annotator-resolved form over sense-inferred defaults. Pass `preferredForm` to override
    /// with a document-specific resolution (e.g. from a swipe in a leaf document section).
    private func defaultFuriganaJSON(for item: VocabItem, preferredForm: WrittenForm? = nil) -> String {
        let form = preferredForm
            ?? item.annotatorResolved?.writtenForm
            ?? preferredWrittenForm(
                senseExtras: item.senseExtras,
                activeSenseIndices: item.corpusSenseIndices,
                writtenForms: item.writtenForms
            )
            ?? item.writtenForms.first?.forms.first
        guard let form,
              let data = try? JSONEncoder().encode(form.furigana),
              let json = String(data: data, encoding: .utf8)
        else { return "[]" }
        return json
    }

    // MARK: - Re-download

    /// Force a fresh download from the remote URL, then reload.
    func redownload(db: QuizDB, jmdict: any DatabaseReader) async {
        await load(db: db, jmdict: jmdict, download: true)
    }
}
