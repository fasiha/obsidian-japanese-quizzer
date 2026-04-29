// QuizContext.swift
// Ranks learning vocab words by Ebisu recall probability (lowest = most urgent).
// Mirrors the logic in get-quiz-context.mjs.
//
// Word text is sourced from the reviews table (word_text column).
// hasKanji is inferred from whether kanji facets exist in ebisu_models.
// All learning words are guaranteed to have a complete set of Ebisu facets
// (enforced by setReadingLearning/setKanjiLearning), so no newWord/newFacet cases needed.

import GRDB
import Foundation

// MARK: - Sense extras

/// One JMDict sense: its English glosses plus associated metadata.
/// Keeping glosses and metadata together preserves which notes/xrefs belong to which definition.
/// For example, "usu. 慌てて" applies only to the "to hurry; to rush" sense of 慌てる,
/// not to its "to panic" sense — flattening them would lose that association.
struct SenseExtra {
    let glosses: [String]        // English glosses for this sense (already filtered to lang=eng)
    let info: [String]           // free-text usage notes (e.g. "usually written using kana alone")
    let related: [[String]]      // see-also cross-references; each inner array is [word, reading?, index?]
    let antonym: [[String]]      // antonym cross-references; same format as related
    let partOfSpeech: [String]   // JMDict tag codes (e.g. "n", "v5r", "adj-na")
    let misc: [String]           // misc tag codes (e.g. "uk" = usually kana, "col" = colloquial)
    let field: [String]          // subject-field tag codes (e.g. "math", "law")
    let dialect: [String]        // dialect tag codes (e.g. "ksb" = Kansai)
    /// Which kanji forms this sense applies to. Empty array or ["*"] both mean "no restriction".
    let appliesToKanji: [String]
    /// Which kana readings this sense applies to. Empty array or ["*"] both mean "no restriction".
    let appliesToKana: [String]

    /// True when there is no metadata beyond the glosses themselves.
    var metadataIsEmpty: Bool {
        info.isEmpty && related.isEmpty && antonym.isEmpty &&
        partOfSpeech.isEmpty && misc.isEmpty && field.isEmpty && dialect.isEmpty
    }

    /// Format cross-reference arrays as "word,reading; word2" — mirrors printXrefs() in tabito.
    static func formatXrefs(_ xrefs: [[String]]) -> String {
        xrefs.map { $0.joined(separator: ",") }.joined(separator: "; ")
    }
}

// MARK: - Preferred written form

/// Returns the best written form for the given active senses, implementing the D3 algorithm
/// from TODO-appliesToKanji.md:
///
///   1. Collect the union of appliesToKanji across all active restricted senses
///      (skip empty arrays and ["*"] — both mean "no restriction").
///   2. Return the first WrittenForm whose text is in that union (all active restricted
///      senses agree, or at least the union covers it).
///   3. If step 2 yields nothing (mutually-exclusive senses), return the first WrittenForm
///      that satisfies any single active restricted sense.
///   4. If no active sense has any kanji restriction at all, return nil — the caller
///      should use its own default (typically kanjiTexts.first or kanaTexts.first).
func preferredWrittenForm(
    senseExtras: [SenseExtra],
    activeSenseIndices: [Int],
    writtenForms: [WrittenFormGroup]
) -> WrittenForm? {
    let allForms = writtenForms.flatMap(\.forms)
    guard !allForms.isEmpty else { return nil }

    // Collect per-sense restricted sets (ignoring empty and ["*"]).
    let restrictedSets: [Set<String>] = activeSenseIndices.compactMap { i -> Set<String>? in
        guard i < senseExtras.count else { return nil }
        let atk = senseExtras[i].appliesToKanji
        guard !atk.isEmpty, atk != ["*"] else { return nil }
        return Set(atk)
    }

    guard !restrictedSets.isEmpty else { return nil }  // no restriction at all → caller decides

    // Pass 1: first form in the union of all restricted sets.
    let union = restrictedSets.reduce(Set<String>()) { $0.union($1) }
    if let form = allForms.first(where: { union.contains($0.text) }) { return form }

    // Pass 2 (mutually exclusive case): first form satisfying any single restricted sense.
    return allForms.first { form in restrictedSets.contains { $0.contains(form.text) } }
}

/// Returns the best kana reading for the given active senses, parallel to `preferredWrittenForm`.
/// Inputs are plain strings (kanaTexts) rather than WrittenFormGroups.
/// Returns nil when no active sense restricts to a specific kana — caller uses its own default.
func preferredKanaForm(
    senseExtras: [SenseExtra],
    activeSenseIndices: [Int],
    kanaTexts: [String]
) -> String? {
    guard !kanaTexts.isEmpty else { return nil }

    let restrictedSets: [Set<String>] = activeSenseIndices.compactMap { i -> Set<String>? in
        guard i < senseExtras.count else { return nil }
        let atk = senseExtras[i].appliesToKana
        guard !atk.isEmpty, atk != ["*"] else { return nil }
        return Set(atk)
    }

    guard !restrictedSets.isEmpty else { return nil }

    let union = restrictedSets.reduce(Set<String>()) { $0.union($1) }
    if let form = kanaTexts.first(where: { union.contains($0) }) { return form }

    return kanaTexts.first { form in restrictedSets.contains { $0.contains(form) } }
}

/// True when the string contains at least one CJK kanji character.
private func containsKanji(_ text: String) -> Bool {
    text.unicodeScalars.contains {
        ($0.value >= 0x4E00 && $0.value <= 0x9FFF) ||
        ($0.value >= 0x3400 && $0.value <= 0x4DBF) ||
        ($0.value >= 0xF900 && $0.value <= 0xFAFF)
    }
}

/// Result of resolving annotator-chosen forms against a JMDict entry's written forms and readings.
struct ResolvedAnnotatorForms {
    /// The best-matching written form (kanji + furigana) for this occurrence.
    let writtenForm: WrittenForm
    /// The kana reading that matches the written form for this occurrence.
    let kana: String
}

/// Resolves the annotator's vocab-bullet tokens into a concrete written form and kana reading.
///
/// Resolution rules:
/// - Tokens are classified as kana-only (pure hiragana/katakana) or kanji-containing.
/// - The first kana token is the preferred reading; the first kanji token is the preferred written text.
/// - If only one type is present, the other is derived from the matching WrittenFormGroup.
/// - If both are present and compatible (a WrittenFormGroup exists with that reading containing
///   that kanji form), both are used directly.
/// - If both are present but incompatible, the token that appears first in annotatedForms wins:
///   kanji-first → keep the kanji, derive a compatible kana from its group's reading;
///   kana-first  → keep the kana, derive a compatible kanji form from its group.
///   This ensures the returned (writtenForm, kana) pair always corresponds to a valid furigana
///   entry in writtenForms — we never mix a form and a reading from different groups.
/// Returns nil when no compatible form can be found.
func resolveAnnotatedForms(
    annotatedForms: [String],
    writtenForms: [WrittenFormGroup],
    kanaTexts: [String]
) -> ResolvedAnnotatorForms? {
    guard !annotatedForms.isEmpty else { return nil }

    let kanjiCandidate = annotatedForms.first(where: { containsKanji($0) })
    let kanaCandidate  = annotatedForms.first(where: { !containsKanji($0) })

    if let kana = kanaCandidate, let kanji = kanjiCandidate {
        // Both present — try compatible match first.
        for group in writtenForms where group.reading == kana {
            if let form = group.forms.first(where: { $0.text == kanji }) {
                return ResolvedAnnotatorForms(writtenForm: form, kana: kana)
            }
        }
        // Incompatible: honour whichever token appears first in the annotatedForms list.
        let kanjiIndex = annotatedForms.firstIndex(where: { containsKanji($0) }) ?? .max
        let kanaIndex  = annotatedForms.firstIndex(where: { !containsKanji($0) }) ?? .max
        if kanjiIndex < kanaIndex {
            // Kanji wins: find the kanji form, derive its group's reading as kana.
            for group in writtenForms {
                if let form = group.forms.first(where: { $0.text == kanji }) {
                    return ResolvedAnnotatorForms(writtenForm: form, kana: group.reading)
                }
            }
        } else {
            // Kana wins: find the kana group, take its first form as kanji.
            if let group = writtenForms.first(where: { $0.reading == kana }),
               let form = group.forms.first {
                return ResolvedAnnotatorForms(writtenForm: form, kana: kana)
            }
        }

    } else if let kana = kanaCandidate {
        // Kana only: find the WrittenFormGroup whose reading matches.
        // For pure-kana entries (no kanji forms), synthesize a plain WrittenForm from the kana itself.
        if let group = writtenForms.first(where: { $0.reading == kana }) {
            let form = group.forms.first ?? WrittenForm(
                furigana: [FuriganaSegment(ruby: kana, rt: nil)],
                text: kana
            )
            return ResolvedAnnotatorForms(writtenForm: form, kana: kana)
        }

    } else if let kanji = kanjiCandidate {
        // Kanji only: find the form, derive kana from its group's reading.
        for group in writtenForms {
            if let form = group.forms.first(where: { $0.text == kanji }) {
                return ResolvedAnnotatorForms(writtenForm: form, kana: group.reading)
            }
        }
    }

    return nil
}

// MARK: - Shared kana helpers

/// Convert a katakana string to hiragana by shifting Unicode scalar values.
/// Katakana small/normal characters U+30A1–U+30F6 map to hiragana U+3041–U+3096.
func katakanaToHiragana(_ s: String) -> String {
    var scalars = String.UnicodeScalarView()
    for sc in s.unicodeScalars {
        if sc.value >= 0x30A1 && sc.value <= 0x30F6,
           let h = Unicode.Scalar(sc.value - 0x60) {
            scalars.append(h)
        } else {
            scalars.append(sc)
        }
    }
    return String(scalars)
}

// MARK: - Kanji quiz data

/// Per-kanji data carried by QuizItems whose word_type is "kanji".
/// The word_id is just the kanji character (e.g. "図") — independent of any parent word.
struct KanjiQuizData {
    /// The single kanji character being tested (e.g. "図").
    let kanjiChar: String
    /// Top-2 on-readings from kanjidic2, converted to hiragana (e.g. ["ず", "と"]).
    /// Empty when the kanji has no on-readings.
    let top2OnReadings: [String]
    /// Top-2 kun-readings from kanjidic2, stripped at the okurigana "." marker (e.g. ["え", "はか"]).
    /// Empty when the kanji has no kun-readings.
    let top2KunReadings: [String]
    /// Full kun-reading forms including okurigana (e.g. ["え", "はかる"]).
    /// Used for okurigana-leniency grading in free-answer mode: a student who types "はかる"
    /// when the answer is "はか" is also accepted as correct.
    let top2KunFullForms: [String]
    /// Top-2 meanings from kanjidic2 (e.g. ["map", "drawing"]).
    let top2Meanings: [String]
}

// MARK: - Quiz item

/// The urgency of one word+facet pair for a quiz session.
enum QuizStatus: Equatable {
    /// recall ∈ [0,1]; isFree = qualifies for free answer.
    case reviewed(recall: Double, isFree: Bool, halflife: Double)
}

struct QuizItem: Identifiable {
    let id = UUID()
    let wordType: String        // "jmdict", "transitive-pair", "counter", or "kanji"
    let wordId: String
    let wordText: String        // single primary form (first written, or first kana if no written)
    let writtenTexts: [String]  // non-irregular orthographic (kanji/mixed) forms
    let kanaTexts: [String]     // non-irregular kana-only forms
    let hasKanji: Bool          // true → {kanji-ok}: all 4 facets available
    let facet: String           // the most-urgent facet to quiz
    let status: QuizStatus
    let senseExtras: [SenseExtra]   // per-sense data: glosses + metadata (info, xrefs, pos, etc.)
    /// Kanji chars the user has committed to learning, decoded from word_commitment.kanji_chars.
    /// nil = no partial commitment (learn all or none). Empty array = committed but no kanji chosen.
    let committedKanji: [String]?
    /// Pre-computed template for partial-commitment kanji quizzes.
    /// Uncommitted kanji are replaced by kana readings; committed kanji stay as-is.
    /// e.g. "ふりかえ休日" for 振替休日 when only [休, 日] are committed. nil when N/A.
    let partialKanjiTemplate: String?
    /// Full kana reading derived from the committed furigana segments (concat rt ?? ruby for each segment).
    /// nil when there is no word commitment. Used for local exact-match grading on reading facets.
    let committedReading: String?
    /// The exact written form the user committed to (ruby fields of furigana segments joined).
    /// nil when there is no word commitment. Used as the explicit correct answer in meaning-reading-to-kanji
    /// prompts so the LLM picks the enrolled form rather than any valid JMDict written form.
    /// Built from furigana ruby fields joined (not from JMDict wordWritten), so alternate orthographies
    /// like 閉じ籠もる are correctly preserved even if JMDict lists a different canonical form.
    let committedWrittenText: String?
    /// Raw furigana segments from the committed word_commitment entry.
    /// Each segment is {"ruby": surface, "rt": reading} where "rt" is present only on kanji segments.
    /// nil when there is no word commitment. Used by kanji-to-reading generation to build mora-level
    /// distractor slots: kanji segments contribute substitutable morae; kana segments are fixed.
    let committedFurigana: [[String: String]]?
    /// All kana readings of every enrolled word that shares the same written form as this item.
    /// Used by kanji-to-reading distractor generation to prevent a sibling entry's reading from
    /// appearing as a "wrong" answer (e.g. if both 怒る/おこる and 怒る/いかる are enrolled,
    /// いかる must be excluded when testing 怒る = おこる).
    let siblingKanaReadings: [String]

    /// Zero-based indices into senseExtras for senses attested in the corpus (from llm_sense.sense_indices).
    /// Defaults to [0] (first sense) when absent or empty, so quiz prompts always have at least one meaning.
    /// Empty for non-jmdict word types (transitive pairs, etc.).
    let corpusSenseIndices: [Int]

    /// Present only when wordType == "kanji". Carries the kanji character, its reading in this word,
    /// the parent word text, and LLM-identified meanings. Nil for all other word types.
    let kanjiQuizData: KanjiQuizData?

    /// The subset of senseExtras attested in the corpus (used as the quiz meaning pool).
    var corpusSenses: [SenseExtra] {
        corpusSenseIndices.compactMap { $0 < senseExtras.count ? senseExtras[$0] : nil }
    }

    var recall: Double {
        switch status { case .reviewed(let r, _, _): return r }
    }

    /// True when this item should be presented as a free-answer question.
    /// meaning-reading-to-kanji is always multiple choice (kanji form must never appear in the stem).
    /// All three kanji quiz facets graduate to free-answer using the standard thresholds,
    /// the same as vocabulary facets.
    var isFreeAnswer: Bool {
        if case .reviewed(_, let free, _) = status {
            return free && facet != "meaning-reading-to-kanji"
        }
        return false
    }
}

// MARK: - Context builder

struct QuizContext {
    static let kanjiOkFacets  = ["kanji-to-reading", "reading-to-meaning", "meaning-to-reading", "meaning-reading-to-kanji"]
    static let noKanjiFacets  = ["reading-to-meaning", "meaning-to-reading"]
    static let kanjiFacetSet  = Set(["kanji-to-reading", "meaning-reading-to-kanji"])

    static let freeAnswerMinReviews  = 3
    static let freeAnswerMinHalflife = 48.0   // hours

    /// Minimum pair-discrimination halflife (hours) before single-leg facets enter the queue.
    static let singleLegUnlockHalflife = 72.0   // hours (~3 days of successful pair reviews)
    /// Minimum pair-discrimination review count before single-leg facets enter the queue.
    static let singleLegUnlockMinReviews = 4

    /// Number of top-urgency candidates to sample from when building a session.
    static let selectionPoolSize = 10

    /// Build a ranked list of QuizItems from the DB.
    ///
    /// Only words with active ebisu_models are included (= "learning" facets).
    /// hasKanji is inferred from whether kanji facets exist in ebisu_models.
    /// - Parameter jmdict: Optional jmdict DB reader used to fill in word texts and forms.
    /// - Parameter pairCorpus: Optional transitive-pair corpus; enrolled pairs are appended as pair-discrimination items.
    /// - Parameter counterCorpus: Optional counter corpus; enrolled counters are appended as counter quiz items.
    static func build(db: QuizDB, jmdict: (any DatabaseReader)? = nil, kanjidic: (any DatabaseReader)? = nil, pairCorpus: TransitivePairCorpus? = nil, counterCorpus: CounterCorpus? = nil) async throws -> [QuizItem] {
        let records        = try await db.enrolledEbisuRecords()
        var wordTexts      = try await db.wordTexts()
        let reviewCounts   = try await db.reviewCounts()
        let commitments    = try await db.allCommitments()

        // Build enrolled-senses map. Priority order:
        //   1. word_commitment.sense_indices (non-null) — student's explicit enrollment
        //   2. vocab.json corpus union — automatic fallback from publish-time sense analysis
        //   3. [0] — default when no sense data is available at all
        //
        // NULL sense_indices means "all senses" (legacy state before v10 migration).
        // Empty array means "explicitly nothing selected" — falls back to [0].
        var corpusSensesMap: [String: [Int]] = [:]
        var wordWrittenForms: [String: [WrittenFormGroup]] = [:]
        if let manifest = VocabSync.cached() {
            for entry in manifest.words {
                let deduped = entry.corpusSenseIndices
                corpusSensesMap[entry.id] = deduped.isEmpty ? [0] : deduped
                wordWrittenForms[entry.id] = entry.writtenForms ?? []
            }
        }
        // Override with committed senses where the student has made an explicit selection.
        for (wordId, commitment) in commitments {
            if let json = commitment.senseIndices,
               let data = json.data(using: .utf8),
               let committed = try? JSONDecoder().decode([Int].self, from: data) {
                // Non-null committed array: use it (empty → [0] fallback, else explicit list).
                corpusSensesMap[wordId] = committed.isEmpty ? [0] : committed
            } else {
                // NULL sense_indices: "all senses" — let the corpus union or [0] default stand,
                // but if jmdict data is available we will expand to the full sense count below
                // (handled after wordSenseExtras is populated).
            }
        }

        // Fetch word text, structured forms, and meanings from jmdict.
        var wordWritten:     [String: [String]] = [:]
        var wordKana:        [String: [String]] = [:]
        var wordSenseExtras: [String: [SenseExtra]] = [:]
        if let jmdict {
            let allIds = Array(Set(records.map(\.wordId)))
            let fromJmdict = try await jmdictWordData(ids: allIds, jmdict: jmdict)
            for (id, entry) in fromJmdict {
                if wordTexts[id] == nil { wordTexts[id] = entry.text }
                wordWritten[id]     = entry.writtenTexts
                wordKana[id]        = entry.kanaTexts
                wordSenseExtras[id] = entry.senseExtras
            }
            print("[QuizContext] fetched jmdict data for \(fromJmdict.count)/\(allIds.count) word(s)")

            // Expand NULL sense_indices ("all senses") to the full JMDict sense range now that
            // sense counts are known. Words with NULL skip the corpusSensesMap override above,
            // so their entry is the corpus-union default — which is already correct for "all
            // senses encountered". No change needed for those words.
            // (This comment block is intentionally left as documentation; no code action needed.)
        }

        // Build reverse map: written form → all enrolled kana readings across all enrolled words.
        // Used by kanji-to-reading to block sibling-entry readings (e.g. both 怒る entries enrolled:
        // student shouldn't see いかる as a distractor when tested on 怒る = おこる).
        var writtenFormToAllKana: [String: Set<String>] = [:]
        for (id, forms) in wordWritten {
            guard let kanas = wordKana[id] else { continue }
            for form in forms {
                for kana in kanas {
                    writtenFormToAllKana[form, default: []].insert(kana)
                }
            }
        }

        // Group by (wordType, wordId).
        var modelsByWord: [String: [EbisuRecord]] = [:]
        for r in records {
            modelsByWord["\(r.wordType)\0\(r.wordId)", default: []].append(r)
        }

        let now = Date()
        var items: [QuizItem] = []

        for (key, wordModels) in modelsByWord {
            let parts = key.split(separator: "\0", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let wordType = String(parts[0])
            let wordId   = String(parts[1])

            // hasKanji inferred from whether any kanji facets exist in this word's models.
            let hasKanji = wordModels.contains { kanjiFacetSet.contains($0.quizType) }
            let facets = hasKanji ? kanjiOkFacets : noKanjiFacets

            let wordText: String = {
                let senses = wordSenseExtras[wordId] ?? []
                let active = corpusSensesMap[wordId] ?? [0]
                let forms  = wordWrittenForms[wordId] ?? []
                let kanas  = wordKana[wordId] ?? []
                return preferredWrittenForm(senseExtras: senses, activeSenseIndices: active, writtenForms: forms)?.text
                    ?? preferredKanaForm(senseExtras: senses, activeSenseIndices: active, kanaTexts: kanas)
                    ?? wordTexts[wordId]
                    ?? wordId
            }()

            // Compute recall for each facet.
            var recallMap: [String: (recall: Double, halflife: Double)] = [:]
            for record in wordModels {
                let elapsed = max(now.timeIntervalSince(iso8601Date(record.lastReview)), 1e-6) / 3600.0
                recallMap[record.quizType] = (predictRecall(record.model, tnow: elapsed, exact: true), record.t)
            }

            // Pick the most-urgent (lowest-recall) facet among the required set.
            var lowestRecall = Double.infinity
            var lowestFacet: String? = nil
            for facet in facets {
                if let (recall, _) = recallMap[facet], recall < lowestRecall {
                    lowestRecall = recall
                    lowestFacet = facet
                }
            }
            guard let facet = lowestFacet else {
                // Should not happen after v3 migration guarantees complete facets.
                assertionFailure("[QuizContext] \(wordId) has no modeled facets despite being learning")
                continue
            }

            let (recall, halflife) = recallMap[facet]!
            let reviewCount = reviewCounts["\(wordId)\0\(facet)"] ?? 0
            let isFree = reviewCount >= freeAnswerMinReviews && halflife >= freeAnswerMinHalflife
            let status = QuizStatus.reviewed(recall: recall, isFree: isFree, halflife: halflife)

            // Decode committed kanji and build partial-kanji template from furigana.
            let committedKanji: [String]?
            var partialKanjiTemplate: String? = nil
            let committedReading: String? = commitments[wordId]?.committedReading

            if let commitment = commitments[wordId], let kc = commitment.kanjiChars,
               let data = kc.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String].self, from: data),
               let segments = commitment.furiganaSegmentsForTemplate {
                committedKanji = decoded
                // Build partial-kanji template from furigana: committed kanji stay,
                // uncommitted kanji are replaced by their kana reading.
                let committedSet = Set(decoded)
                var template = ""
                for seg in segments {
                    let ruby = seg["ruby"] ?? ""
                    let rt = seg["rt"]
                    if let rt, !ruby.isEmpty, !committedSet.contains(ruby) {
                        // Uncommitted kanji → replace with kana reading
                        template += rt
                    } else {
                        // Committed kanji, kana-only segment, or no rt → keep as-is
                        template += ruby
                    }
                }
                // Only set if there were actual uncommitted kanji replaced.
                // Scan the committed form's furigana ruby fields (not the first JMDict written
                // form) so that alternate-orthography words like 閉じ籠もる are handled correctly.
                // The first JMDict written form may use a different kanji (e.g. 閉じ込もる) or
                // hiragana (閉じこもる), causing the check to miss kanji that are present in the
                // committed form and therefore incorrectly suppress the partial template.
                let allKanjiInCommittedForm = Set(
                    QuizSession.extractKanji(from: segments.map { $0["ruby"] ?? "" }.joined())
                )
                if !allKanjiInCommittedForm.subtracting(committedSet).isEmpty {
                    partialKanjiTemplate = template
                }
            } else {
                committedKanji = nil
            }

            let committedWrittenText = commitments[wordId]?.committedWrittenText
            let lookupForm = committedWrittenText ?? wordTexts[wordId] ?? ""
            let siblingKana = Array(writtenFormToAllKana[lookupForm] ?? [])
            items.append(QuizItem(
                wordType: wordType, wordId: wordId, wordText: wordText,
                writtenTexts: wordWritten[wordId] ?? [],
                kanaTexts: wordKana[wordId] ?? [],
                hasKanji: hasKanji, facet: facet, status: status,
                senseExtras: wordSenseExtras[wordId] ?? [],
                committedKanji: committedKanji,
                partialKanjiTemplate: partialKanjiTemplate,
                committedReading: committedReading,
                committedWrittenText: committedWrittenText,
                committedFurigana: commitments[wordId]?.furiganaSegmentsForTemplate,
                siblingKanaReadings: siblingKana,
                corpusSenseIndices: corpusSensesMap[wordId] ?? [0],
                kanjiQuizData: nil))
        }

        // Include enrolled transitive-pair items.
        // Single-leg facets ("transitive", "intransitive") are suppressed until the
        // pair-discrimination model meets both unlock criteria:
        //   halflife ≥ singleLegUnlockHalflife AND review count ≥ singleLegUnlockMinReviews
        if let pairCorpus {
            let pairReviewCounts = try await db.pairReviewCounts()
            let pairRecords = try await db.enrolledTransitivePairRecords()
            // Group all facet records by wordId so we can consider all three facets together.
            var pairRecallByFacet: [String: [String: (recall: Double, halflife: Double)]] = [:]
            for record in pairRecords {
                let elapsed = max(now.timeIntervalSince(iso8601Date(record.lastReview)), 1e-6) / 3600.0
                pairRecallByFacet[record.wordId, default: [:]][record.quizType] =
                    (predictRecall(record.model, tnow: elapsed, exact: true), record.t)
            }
            let pairItems = await MainActor.run { pairCorpus.items }
            for pairItem in pairItems where pairItem.state == .learning {
                guard let facetRecalls = pairRecallByFacet[pairItem.id],
                      let pairData = facetRecalls["pair-discrimination"] else { continue }

                // Which facets are eligible depends on whether the pair has matured enough.
                let pairReviewCount = pairReviewCounts["\(pairItem.id)\0pair-discrimination"] ?? 0
                let unlocked = pairData.halflife >= singleLegUnlockHalflife
                            && pairReviewCount >= singleLegUnlockMinReviews
                let eligibleFacets: [String] = unlocked
                    ? ["pair-discrimination", "transitive", "intransitive"]
                    : ["pair-discrimination"]

                // Pick the most-urgent (lowest recall) eligible facet.
                var lowestRecall = Double.infinity
                var chosenFacet = "pair-discrimination"
                var chosenHalflife = pairData.halflife
                for facet in eligibleFacets {
                    if let (recall, halflife) = facetRecalls[facet], recall < lowestRecall {
                        lowestRecall = recall
                        chosenFacet = facet
                        chosenHalflife = halflife
                    }
                }

                let status = QuizStatus.reviewed(recall: lowestRecall, isFree: false, halflife: chosenHalflife)
                let kanjiIntr = pairItem.pair.intransitive.kanji.first ?? pairItem.pair.intransitive.kana
                let kanjiTran = pairItem.pair.transitive.kanji.first ?? pairItem.pair.transitive.kana
                let wordText = "\(kanjiIntr) ↔ \(kanjiTran)"
                items.append(QuizItem(
                    wordType: "transitive-pair", wordId: pairItem.id, wordText: wordText,
                    writtenTexts: [], kanaTexts: [], hasKanji: false,
                    facet: chosenFacet, status: status,
                    senseExtras: [], committedKanji: nil, partialKanjiTemplate: nil, committedReading: nil,
                    committedWrittenText: nil, committedFurigana: nil,
                    siblingKanaReadings: [], corpusSenseIndices: [], kanjiQuizData: nil
                ))
            }
        }

        // Include enrolled counter items.
        if let counterCorpus {
            let counterRecords = try await db.enrolledCounterRecords()
            // Group counter records by wordId, then build recall map for each facet.
            var counterRecallByFacet: [String: [String: (recall: Double, halflife: Double)]] = [:]
            for record in counterRecords {
                let elapsed = max(now.timeIntervalSince(iso8601Date(record.lastReview)), 1e-6) / 3600.0
                let facetRecall = (predictRecall(record.model, tnow: elapsed, exact: true), record.t)
                counterRecallByFacet[record.wordId, default: [:]][record.quizType] = facetRecall
            }
            let counterItems = await MainActor.run { counterCorpus.items }
            for counterItem in counterItems where counterItem.state == .learning {
                guard let facetRecalls = counterRecallByFacet[counterItem.id] else { continue }
                // Pick the most-urgent (lowest-recall) facet.
                let meaningData = facetRecalls["meaning-to-reading"]
                let numberData = facetRecalls["counter-number-to-reading"]
                let (facet, recall, halflife): (String, Double, Double)
                if let meaning = meaningData, let number = numberData {
                    if meaning.recall < number.recall {
                        facet = "meaning-to-reading"
                        recall = meaning.recall
                        halflife = meaning.halflife
                    } else {
                        facet = "counter-number-to-reading"
                        recall = number.recall
                        halflife = number.halflife
                    }
                } else if let meaning = meaningData {
                    facet = "meaning-to-reading"
                    recall = meaning.recall
                    halflife = meaning.halflife
                } else if let number = numberData {
                    facet = "counter-number-to-reading"
                    recall = number.recall
                    halflife = number.halflife
                } else {
                    continue
                }

                let status = QuizStatus.reviewed(recall: recall, isFree: true, halflife: halflife)
                let wordText = "\(counterItem.counter.kanji)(\(counterItem.counter.reading))"
                items.append(QuizItem(
                    wordType: "counter", wordId: counterItem.id, wordText: wordText,
                    writtenTexts: [counterItem.counter.kanji], kanaTexts: [counterItem.counter.reading],
                    hasKanji: false, facet: facet, status: status,
                    senseExtras: [], committedKanji: nil, partialKanjiTemplate: nil, committedReading: nil,
                    committedWrittenText: nil, committedFurigana: nil,
                    siblingKanaReadings: [], corpusSenseIndices: [], kanjiQuizData: nil
                ))
            }
        }

        // Include enrolled kanji quiz items (word_type="kanji", word_id=single kanji character).
        // Three facets: kanji-to-on-reading, kanji-to-kun-reading, kanji-to-meaning.
        // Top-2 on/kun/meanings are loaded from kanjidic2 here and stored in KanjiQuizData
        // so QuizSession can build questions and coaching prompts without additional DB calls.
        let kanjiQuizRecords = try await db.enrolledKanjiQuizRecords()
        let kanjiReviewCounts = try await db.kanjiQuizReviewCounts()
        var kanjiQuizRecallByFacet: [String: [String: (recall: Double, halflife: Double)]] = [:]
        for record in kanjiQuizRecords {
            let elapsed = max(now.timeIntervalSince(iso8601Date(record.lastReview)), 1e-6) / 3600.0
            kanjiQuizRecallByFacet[record.wordId, default: [:]][record.quizType] =
                (predictRecall(record.model, tnow: elapsed, exact: true), record.t)
        }

        // Load kanjidic2 data for all enrolled kanji characters in one read.
        var kanjidicData: [String: (onReadings: [String], kunReadings: [String], meanings: [String])] = [:]
        let enrolledKanjiChars = Array(Set(kanjiQuizRecords.map(\.wordId)))
        if let kanjidic, !enrolledKanjiChars.isEmpty {
            kanjidicData = (try? await kanjidic.read { db in
                var result: [String: (onReadings: [String], kunReadings: [String], meanings: [String])] = [:]
                for ch in enrolledKanjiChars {
                    guard let row = try Row.fetchOne(db,
                        sql: "SELECT on_readings, kun_readings, meanings FROM kanji WHERE literal = ?",
                        arguments: [ch]) else { continue }
                    func decode(_ key: String) -> [String] {
                        guard let json = row[key] as? String,
                              let arr = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String]
                        else { return [] }
                        return arr
                    }
                    result[ch] = (decode("on_readings"), decode("kun_readings"), decode("meanings"))
                }
                return result
            }) ?? [:]
        }

        for wordId in Set(kanjiQuizRecords.map(\.wordId)) {
            guard let facetRecalls = kanjiQuizRecallByFacet[wordId] else { continue }
            let kanjiChar = wordId

            let onData  = facetRecalls["kanji-to-on-reading"]
            let kunData = facetRecalls["kanji-to-kun-reading"]
            let meanData = facetRecalls["kanji-to-meaning"]
            let candidates: [(String, Double, Double)] = [
                onData.map  { ("kanji-to-on-reading",  $0.recall, $0.halflife) },
                kunData.map { ("kanji-to-kun-reading", $0.recall, $0.halflife) },
                meanData.map { ("kanji-to-meaning",    $0.recall, $0.halflife) },
            ].compactMap { $0 }
            guard let (facet, recall, halflife) = candidates.min(by: { $0.1 < $1.1 }) else { continue }

            let reviewCount = kanjiReviewCounts["\(wordId)\0\(facet)"] ?? 0
            let isFree = reviewCount >= freeAnswerMinReviews && halflife >= freeAnswerMinHalflife
            let status = QuizStatus.reviewed(recall: recall, isFree: isFree, halflife: halflife)

            // Build top-2 on/kun/meanings from the kanjidic2 data loaded above.
            let kdicEntry = kanjidicData[kanjiChar]
            let rawOn = Array((kdicEntry?.onReadings ?? []).prefix(2))
            let top2On = rawOn.map { katakanaToHiragana($0) }
            let rawKun = Array((kdicEntry?.kunReadings ?? []).prefix(2))
            // Stripped stems (before ".") for answer matching and display.
            let top2Kun = rawKun.map { r -> String in
                let stripped = r.hasPrefix("-") ? String(r.dropFirst()) : r
                return String(stripped.split(separator: ".", maxSplits: 1).first ?? Substring(stripped))
            }
            // Full forms with okurigana appended for leniency grading (e.g. "はかる").
            let top2KunFull = rawKun.map { r -> String in
                let stripped = r.hasPrefix("-") ? String(r.dropFirst()) : r
                let parts = stripped.split(separator: ".", maxSplits: 1)
                if parts.count == 2 { return String(parts[0]) + String(parts[1]) }
                return String(parts[0])
            }
            let top2Meanings = Array((kdicEntry?.meanings ?? []).prefix(2))

            let kanjiData = KanjiQuizData(
                kanjiChar: kanjiChar,
                top2OnReadings: top2On,
                top2KunReadings: top2Kun,
                top2KunFullForms: top2KunFull,
                top2Meanings: top2Meanings
            )
            items.append(QuizItem(
                wordType: "kanji", wordId: wordId, wordText: kanjiChar,
                writtenTexts: [], kanaTexts: [], hasKanji: false,
                facet: facet, status: status,
                senseExtras: [], committedKanji: nil, partialKanjiTemplate: nil,
                committedReading: nil, committedWrittenText: nil,
                corpusSenseIndices: [], kanjiQuizData: kanjiData
            ))
        }
        print("[QuizContext] built \(Set(kanjiQuizRecords.map(\.wordId)).count) kanji quiz item(s)")

        items.sort { $0.recall < $1.recall }
        return items   // caller (QuizSession.selectItems) decides how many to use
    }

    struct JmdictEntry {
        let text: String
        let writtenTexts: [String]
        let kanaTexts: [String]
        let senseExtras: [SenseExtra]
    }

    /// Cached JMDict tag abbreviation → full description map. Loaded once from the
    /// metadata table on first use, then reused for the lifetime of the process.
    private nonisolated(unsafe) static var cachedTags: [String: String]?

    /// Load (or return cached) tag expansions from a jmdict DatabaseReader.
    private nonisolated static func loadTags(db: Database) -> [String: String] {
        if let cached = cachedTags { return cached }
        let tags: [String: String] = {
            guard let json = try? String.fetchOne(db, sql: "SELECT value_json FROM metadata WHERE key = 'tags'"),
                  let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            else { return [:] }
            return obj
        }()
        cachedTags = tags
        return tags
    }

    /// Look up canonical word text and English meanings from jmdict entries.
    /// Tag abbreviations (e.g. "uk") are expanded to full descriptions using the
    /// metadata table in the same jmdict database (cached after first load).
    static func jmdictWordData(ids: [String], jmdict: any DatabaseReader) async throws -> [String: JmdictEntry] {
        try await jmdict.read { db in
            let tags = loadTags(db: db)
            let expand: ([String]) -> [String] = { codes in codes.map { tags[$0] ?? $0 } }
            var result: [String: JmdictEntry] = [:]
            for id in ids {
                guard let json = try String.fetchOne(db,
                          sql: "SELECT entry_json FROM entries WHERE id = ?", arguments: [id]),
                      let data = json.data(using: .utf8),
                      let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                // Filter out irregular kanji (iK), rare kanji (rK), and irregular kana (ik),
                // matching summarizeWord() in shared.mjs. Rare kanji like 馬穴 (バケツ) have no
                // furigana data in writtenForms, so including them creates mismatches between
                // the vocab browser (which uses writtenTexts) and the detail sheet (which uses writtenForms).
                let kanjiTexts = (raw["kanji"] as? [[String: Any]] ?? [])
                    .filter {
                        let tags = $0["tags"] as? [String] ?? []
                        return !tags.contains("iK") && !tags.contains("rK")
                    }
                    .compactMap { $0["text"] as? String }
                let kanaTexts  = (raw["kana"]  as? [[String: Any]] ?? [])
                    .filter { !(($0["tags"] as? [String] ?? []).contains("ik")) }
                    .compactMap { $0["text"] as? String }
                guard let text = kanjiTexts.first ?? kanaTexts.first else { continue }
                let senses = raw["sense"] as? [[String: Any]] ?? []
                // Build one SenseExtra per sense, pairing glosses with their metadata so the
                // association is never lost (e.g. "usu. 慌てて" stays with "to hurry/rush").
                let senseExtras: [SenseExtra] = senses.map { sense in
                    let glosses = (sense["gloss"] as? [[String: Any]] ?? [])
                        .filter { ($0["lang"] as? String) == "eng" }
                        .compactMap { $0["text"] as? String }
                    return SenseExtra(
                        glosses:        glosses,
                        info:           sense["info"] as? [String] ?? [],
                        related:        parseXrefs(sense["related"]),
                        antonym:        parseXrefs(sense["antonym"]),
                        partOfSpeech:   expand(sense["partOfSpeech"] as? [String] ?? []),
                        misc:           expand(sense["misc"] as? [String] ?? []),
                        field:          expand(sense["field"] as? [String] ?? []),
                        dialect:        expand(sense["dialect"] as? [String] ?? []),
                        appliesToKanji: sense["appliesToKanji"] as? [String] ?? [],
                        appliesToKana:  sense["appliesToKana"]  as? [String] ?? []
                    )
                }
                result[id] = JmdictEntry(text: text, writtenTexts: kanjiTexts, kanaTexts: kanaTexts,
                                         senseExtras: senseExtras)
            }
            return result
        }
    }

    /// Parse a JMDict Xref JSON array (each element is [String | Number]) into [[String]].
    private nonisolated static func parseXrefs(_ value: Any?) -> [[String]] {
        guard let arr = value as? [Any] else { return [] }
        return arr.compactMap { elem -> [String]? in
            guard let xref = elem as? [Any] else { return nil }
            let parts = xref.compactMap { part -> String? in
                if let s = part as? String { return s }
                if let n = part as? NSNumber { return n.stringValue }
                return nil
            }
            return parts.isEmpty ? nil : parts
        }
    }

    private static func iso8601Date(_ s: String) -> Date {
        parseISO8601(s) ?? Date(timeIntervalSinceNow: -60)
    }
}

// MARK: - ISO 8601 parsing

/// Parse an ISO 8601 date, supporting both with and without fractional seconds.
/// Node.js `new Date().toISOString()` includes milliseconds (e.g. "2026-03-04T12:34:56.789Z"),
/// which iOS's default ISO8601DateFormatter cannot parse. Trying with .withFractionalSeconds
/// handles those. Returns nil (not now!) on failure so callers can treat stale records as urgent.
func parseISO8601(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    if let d = f.date(from: s) { return d }
    f.formatOptions.insert(.withFractionalSeconds)
    return f.date(from: s)
}

// MARK: - QuizDB extensions for quiz context

extension QuizDB {
    /// The most recent word_text per word_id across all jmdict reviews.
    func wordTexts() async throws -> [String: String] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT word_id, word_text
                FROM reviews
                WHERE word_type = 'jmdict'
                  AND id IN (
                      SELECT MAX(id) FROM reviews
                      WHERE word_type = 'jmdict'
                      GROUP BY word_id
                  )
                """)
            return Dictionary(rows.compactMap { row -> (String, String)? in
                guard let id = row["word_id"] as? String,
                      let text = row["word_text"] as? String else { return nil }
                return (id, text)
            }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// Review counts per "wordId\0quizType" for jmdict words.
    func reviewCounts() async throws -> [String: Int] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT word_id, quiz_type, COUNT(*) as count
                FROM reviews
                WHERE word_type = 'jmdict'
                GROUP BY word_id, quiz_type
                """)
            var result: [String: Int] = [:]
            for row in rows {
                guard let id = row["word_id"] as? String,
                      let qt = row["quiz_type"] as? String,
                      let count = (row["count"] as? Int64).map(Int.init) else { continue }
                result["\(id)\0\(qt)"] = count
            }
            return result
        }
    }

}
