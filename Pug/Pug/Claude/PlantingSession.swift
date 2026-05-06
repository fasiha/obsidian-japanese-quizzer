// PlantingSession.swift
// Orchestrates the "Learn" (planting) flow for one document.
//
// Pattern (from TODO-planting.md):
//   Introduce word → drill → introduce next word → drill all introduced → ...
//   Repeat drills until every (word, facet) pair has been reviewed reviewThreshold times.
//   Planted words immediately enter the normal SRS queue via Ebisu models.
//
// MC questions are generated app-side (no LLM), using distractors from other words
// in the same document.  Newly introduced words always get multiple-choice drill
// questions because their Ebisu halflife is far below the free-answer threshold.

import Foundation
import GRDB
#if os(iOS)
import UIKit
#endif

// MARK: - Supporting types

/// One word + facet pair queued for a planting drill.
struct PlantQuizItem: Equatable {
    let wordId: String
    let wordText: String    // primary display form (kanji or kana)
    let kanaText: String    // kana reading
    let facet: String       // e.g. "reading-to-meaning"
    let senseIndices: [Int] // document-scoped JMDict sense indices
}

/// An app-generated multiple-choice question used during planting drills.
struct PlantingMultipleChoice: Equatable {
    let stem: String
    let choices: [String]   // exactly 4 items
    let correctIndex: Int   // 0–3
    let item: PlantQuizItem
}

// MARK: - PlantingSession

@Observable @MainActor
final class PlantingSession {

    // MARK: - Constants (all tunable; exposed as named constants per spec)

    /// Number of words introduced per batch before drilling the whole batch.
    static let batchSize = 4
    /// Minimum review count per (word, facet) before a word is considered planted.
    static let reviewThreshold = 2
    /// Initial Ebisu halflife (hours) for a word that was just introduced.
    static let initialHalflife: Double = 1.5

    // MARK: - Phase

    enum Phase: Equatable {
        case idle
        case loading
        case introducing                              // show introduce card for currentIntroWord
        case awaitingTap(PlantingMultipleChoice)      // app-side MC drill
        case tapFeedback(correct: Bool, String)       // brief result before "Continue"
        case batchDone                                // one batch finished; more words remain
        case allDone                                  // every word in the document is planted
        case noNewWords                               // all words already above threshold
        case error(String)
    }

    // MARK: - Problem reporting
    // Planting drills use app-generated multiple-choice questions (no LLM), so there are no
    // auto-skip failure paths — only the manual button path from PostAnswerChatView.

    var pendingReport: ProblemReport? = nil

    func reportProblem() {
        let wordText = lastAnsweredMC?.item.wordText ?? currentIntroWord?.wordText ?? "unknown word"
        pendingReport = ProblemReport(
            message: "Problem reported at \(ProblemReport.timestamp()): planting drill for \(wordText). Please share with the quiz admin.",
            timestamp: Date()
        )
    }

    // MARK: - Observed state

    var phase: Phase = .idle

    /// Title of the document currently being planted.
    private(set) var documentTitle: String = ""

    /// All words for the document, sorted by first appearance (min line number).
    /// Never mutated after loading — used as the distractor pool for multiple-choice questions.
    private(set) var documentWords: [VocabItem] = []

    /// Ordered queue of words that still need to be planted in this session.
    /// Words are removed from the front as batches are completed, or individually when skipped.
    /// The current batch is always `remainingWords.prefix(batchSize)`.
    private(set) var remainingWords: [VocabItem] = []

    /// How many words in the current batch have been introduced ("Got it" tapped).
    private(set) var batchIntroducedCount: Int = 0

    /// Kanji-facet toggle per wordId; set when the user taps "Got it" on the introduce card.
    private(set) var kanjiEnabled: [String: Bool] = [:]

    /// Review counts keyed by "wordId\0facet", seeded from the DB at session start.
    /// Used at load time to filter out words whose facets are already past threshold.
    private(set) var reviewCounts: [String: Int] = [:]

    // MARK: - Drill queue
    //
    // One shuffled queue feeds the whole session. Each "Got it" appends a chunk:
    //   • all facets of the newly introduced word
    //   • one facet per older word in the batch (lowest sessionCounts wins)
    //   • on the LAST intro of the batch: extra entries so every (word, facet) in the
    //     batch reaches reviewThreshold reviews this session
    // The chunk is shuffled before append, with a light adjacency fix to avoid the
    // same word appearing back-to-back across the queue/chunk boundary.

    /// Drill questions waiting to be shown, consumed front-to-back.
    private var pendingQueue: [PlantQuizItem] = []

    /// Per-(word, facet) counter of reviews completed *this session*. Used to drive
    /// the topup at end-of-batch independently of long-term DB review counts.
    private var sessionCounts: [String: Int] = [:]

    /// The word being introduced in the current introduce-card phase (nil otherwise).
    private(set) var currentIntroWord: VocabItem? = nil

    /// The most recently answered drill question and the choice index the student tapped.
    /// Retained while in .tapFeedback so PlantView can show the full question context.
    private(set) var lastAnsweredMC: PlantingMultipleChoice? = nil
    private(set) var lastAnswerChoiceIndex: Int = 0

    /// The words from the batch that just completed. Set when entering .batchDone.
    private(set) var completedBatchWords: [VocabItem] = []

    /// Mirrors the kanji toggle on the current introduce card — bound via @Bindable in the view.
    var currentIntroKanjiEnabled: Bool = false

    /// Which individual kanji characters the user has opted into for the current introduce card.
    /// Populated (all kanji selected by default) when the kanji toggle is turned on.
    /// Persisted into `kanjiEnabled` as a Bool when the user taps "Got it".
    var currentIntroSelectedKanji: Set<String> = []

    /// Total unplanted words when the session was loaded (for progress display).
    private(set) var totalToPlant: Int = 0

    // MARK: - Dependencies

    let db: QuizDB
    let corpus: VocabCorpus

    // MARK: - Init

    init(db: QuizDB, corpus: VocabCorpus) {
        self.db = db
        self.corpus = corpus
    }

    // MARK: - Public: start

    /// Begin (or restart) a planting session for `documentTitle`.
    /// `allWords` is the full VocabCorpus items list; it is filtered internally to the document.
    func start(documentTitle: String, allWords: [VocabItem]) {
        self.documentTitle = documentTitle
        phase = .loading
        Task { await loadSession(allWords: allWords) }
    }

    // MARK: - Public: introduce-card actions

    /// Called when the student taps "Got it" on the introduce card.
    /// Creates Ebisu models for the word's facets and starts the first drill round.
    func tapGotIt() {
        guard case .introducing = phase, let word = currentIntroWord else { return }
        let selectedKanji = Array(currentIntroSelectedKanji)
        let includeKanji = !selectedKanji.isEmpty
        kanjiEnabled[word.id] = includeKanji
        phase = .loading
        Task {
            let senseIndices = docScopedSenseIndices(for: word)
            await corpus.setReadingState(.learning, wordId: word.id, db: db,
                                         senseIndicesToSeed: senseIndices,
                                         halflife: Self.initialHalflife)
            if includeKanji && !word.writtenTexts.isEmpty {
                await corpus.setKanjiState(.learning, wordId: word.id,
                                           kanjiChars: selectedKanji, db: db,
                                           halflife: Self.initialHalflife)
            }
            let isLast = batchIntroducedCount + 1 == currentBatch.count
            enqueueAfterIntroduction(word: word, isLastInBatch: isLast)
            batchIntroducedCount += 1
            drainOrAdvance()
        }
    }

    /// Called when the student taps "Skip" on the introduce card.
    /// Removes the word from this session's queue without creating any Ebisu models,
    /// so it will reappear at the start of the next planting session for this document.
    func tapSkip() {
        guard case .introducing = phase else { return }
        dismissCurrentIntroWord()
    }

    /// Called when the student taps "Known" on the introduce card.
    /// Moves the word's reading facets (and kanji facets if the toggle is on) into the
    /// learned table so the word is permanently skipped by future planting sessions.
    /// No drill questions are shown for the word — it is removed from the queue immediately.
    func tapKnown() {
        guard case .introducing = phase, let word = currentIntroWord else { return }
        let includeKanji = !currentIntroSelectedKanji.isEmpty
        phase = .loading
        Task {
            await corpus.setReadingState(.known, wordId: word.id, db: db)
            if includeKanji && !word.writtenTexts.isEmpty {
                await corpus.setKanjiState(.known, wordId: word.id, db: db)
            }
            dismissCurrentIntroWord()
        }
    }

    /// Removes the front word from the queue and shows the next introduce card (or ends the
    /// session). Called by both tapSkip and tapKnown — they differ only in what DB writes
    /// they perform before reaching this point.
    private func dismissCurrentIntroWord() {
        remainingWords.removeFirst()
        totalToPlant = max(0, totalToPlant - 1)
        introduceNextWord()
    }

    // MARK: - Public: drill actions

    /// Called when the student taps a multiple-choice answer during a drill.
    func tapChoice(_ choiceIndex: Int) {
        guard case .awaitingTap(let mc) = phase else { return }
        let correct = choiceIndex == mc.correctIndex
        let score   = correct ? 1.0 : 0.0
        let explanation: String
        if correct {
            explanation = "✓  \(mc.choices[choiceIndex])"
        } else {
            explanation = "✗  \(mc.choices[choiceIndex])   →   ✓  \(mc.choices[mc.correctIndex])"
        }
        lastAnsweredMC = mc
        lastAnswerChoiceIndex = choiceIndex
        phase = .tapFeedback(correct: correct, explanation)
        let key = "\(mc.item.wordId)\0\(mc.item.facet)"
        sessionCounts[key, default: 0] += 1
        Task { await recordPlantingReview(item: mc.item, score: score) }
    }

    // MARK: - Private: session loading

    private func loadSession(allWords: [VocabItem]) async {
        let docWords = allWords.filter { $0.sources.contains(documentTitle) }

        // Sort by the word's first occurrence (minimum line number) in this document.
        let sorted = docWords.sorted { a, b in
            let aMin = a.references[documentTitle]?.map(\.line).min() ?? Int.max
            let bMin = b.references[documentTitle]?.map(\.line).min() ?? Int.max
            return aMin < bMin
        }

        // Seed review counts and existing Ebisu model word IDs from the DB.
        let counts = (try? await db.reviewCounts()) ?? [:]
        reviewCounts = counts
        let enrolledRecords = (try? await db.enrolledEbisuRecords()) ?? []
        let enrolledWordIds = Set(enrolledRecords.map(\.wordId))
        let learnedWordIds = (try? await db.learnedWordIds()) ?? []

        // Recovered words inherit kanji-enabled state from whatever facets their
        // existing Ebisu records cover — we never re-prompt the kanji toggle for them.
        let kanjiFacets: Set<String> = ["kanji-to-reading", "meaning-reading-to-kanji"]
        var recoveredKanji: [String: Bool] = [:]
        for rec in enrolledRecords where kanjiFacets.contains(rec.quizType) {
            recoveredKanji[rec.wordId] = true
        }

        // Skip words whose reading facets are already above the review threshold,
        // or that the user has explicitly marked as known (present in the learned table).
        // (Kanji facets are checked after the user sets the toggle on the introduce card.)
        let readingFacets = ["reading-to-meaning", "meaning-to-reading"]
        let unplanted = sorted.filter { word in
            guard !learnedWordIds.contains(word.id) else { return false }
            return !readingFacets.allSatisfy { facet in
                (counts["\(word.id)\0\(facet)"] ?? 0) >= Self.reviewThreshold
            }
        }

        // Session recovery: words that were introduced in a previous session (have Ebisu
        // models already) but whose review counts are still below the threshold should be
        // drilled before new words are introduced. Split the unplanted list so that
        // already-introduced words come first, preserving document order within each group.
        let alreadyIntroduced = unplanted.filter { enrolledWordIds.contains($0.id) }
        let notYetIntroduced  = unplanted.filter { !enrolledWordIds.contains($0.id) }
        let recovered = alreadyIntroduced + notYetIntroduced

        documentWords      = recovered
        remainingWords     = recovered
        totalToPlant       = recovered.count
        kanjiEnabled       = recoveredKanji
        pendingQueue       = []
        sessionCounts      = [:]

        if recovered.isEmpty {
            phase = .noNewWords
            return
        }

        // If the first batch contains already-introduced words, mark them as introduced so
        // the session goes directly to drilling them instead of showing their intro cards again.
        let firstBatch = Array(recovered.prefix(Self.batchSize))
        batchIntroducedCount = firstBatch.filter { enrolledWordIds.contains($0.id) }.count

        // Edge case: every word in the first batch is recovered (no new word will be
        // introduced to trigger an enqueue). Build the topup chunk now so they get drilled.
        if batchIntroducedCount == firstBatch.count {
            enqueueRecoveredOnlyBatch()
        }

        introduceNextWord()
    }

    /// When a batch consists entirely of recovered words, no "Got it" tap will fire to
    /// build a chunk. Seed the queue with the end-of-batch topup directly.
    private func enqueueRecoveredOnlyBatch() {
        let batch = currentBatch
        var chunk: [PlantQuizItem] = []
        for word in batch {
            for facet in activeFacets(for: word) {
                let key = "\(word.id)\0\(facet)"
                let alreadyDone = reviewCounts[key] ?? 0
                let needed = max(0, Self.reviewThreshold - alreadyDone)
                for _ in 0..<needed {
                    chunk.append(makePlantQuizItem(word: word, facet: facet))
                }
            }
        }
        chunk.shuffle()
        avoidAdjacentRepeats(&chunk, prevTailWordId: nil)
        pendingQueue.append(contentsOf: chunk)
    }

    // MARK: - Private: introduce flow

    private func introduceNextWord() {
        let batch = currentBatch
        guard batchIntroducedCount < batch.count else {
            // All words in the batch have been introduced — drain the queue or advance.
            drainOrAdvance()
            return
        }
        currentIntroWord             = batch[batchIntroducedCount]
        currentIntroKanjiEnabled     = false
        currentIntroSelectedKanji    = []
        phase = .introducing
    }

    // MARK: - Private: drill flow

    /// Show the next queued drill question, or — if the queue is empty — introduce the
    /// next word in the batch, or advance to the next batch when the batch is finished.
    private func drainOrAdvance() {
        if !pendingQueue.isEmpty {
            let next = pendingQueue.removeFirst()
            phase = .awaitingTap(buildMultipleChoice(item: next))
            return
        }
        if batchIntroducedCount < currentBatch.count {
            introduceNextWord()
            return
        }
        advanceBatch()
    }

    /// Called when the student taps "Continue" after drill feedback.
    func continueAfterFeedback() {
        guard case .tapFeedback = phase else { return }
        drainOrAdvance()
    }

    // MARK: - Private: batch management

    private func advanceBatch() {
        // Capture the completed batch for the summary screen before removing it.
        completedBatchWords = currentBatch

        let batchCount = currentBatch.count
        remainingWords.removeFirst(batchCount)
        batchIntroducedCount = 0
        kanjiEnabled         = [:]
        pendingQueue         = []
        sessionCounts        = [:]

        phase = remainingWords.isEmpty ? .allDone : .batchDone
    }

    // MARK: - Private: computed helpers

    /// The words forming the current batch: the first batchSize entries of remainingWords.
    private var currentBatch: [VocabItem] {
        Array(remainingWords.prefix(Self.batchSize))
    }

    /// Quiz facets active for this word.
    /// Reading facets are always included; kanji facets are added when the user opted in.
    private func activeFacets(for word: VocabItem) -> [String] {
        if kanjiEnabled[word.id] == true && !word.writtenTexts.isEmpty {
            return ["reading-to-meaning", "meaning-to-reading",
                    "kanji-to-reading", "meaning-reading-to-kanji"]
        }
        return ["reading-to-meaning", "meaning-to-reading"]
    }

    /// Build the chunk of drill questions triggered by introducing `word` and append it
    /// to `pendingQueue`. The chunk contains:
    ///   • all facets of the newly introduced word
    ///   • one facet per older word in the batch (the facet with the lowest sessionCounts)
    ///   • on the last intro of the batch, extra entries so every (word, facet) reaches
    ///     `reviewThreshold` reviews this session
    private func enqueueAfterIntroduction(word: VocabItem, isLastInBatch: Bool) {
        let batch = currentBatch
        let olderWords = Array(batch.prefix(batchIntroducedCount))
        var chunk: [PlantQuizItem] = []

        // All facets of the newly introduced word.
        for facet in activeFacets(for: word) {
            chunk.append(makePlantQuizItem(word: word, facet: facet))
        }

        // One facet per older word — pick the facet with the lowest session count so
        // facets round-robin across rounds rather than always re-drilling the same one.
        for older in olderWords {
            let facets = activeFacets(for: older)
            guard let chosen = facets.min(by: {
                facetSessionCount(older.id, $0) < facetSessionCount(older.id, $1)
            }) else { continue }
            chunk.append(makePlantQuizItem(word: older, facet: chosen))
        }

        // Last intro of the batch: top up so every (word, facet) reaches reviewThreshold.
        // Counts already in pendingQueue and chunk count toward the target.
        if isLastInBatch {
            var scheduled: [String: Int] = [:]
            for item in pendingQueue {
                scheduled["\(item.wordId)\0\(item.facet)", default: 0] += 1
            }
            for item in chunk {
                scheduled["\(item.wordId)\0\(item.facet)", default: 0] += 1
            }
            for w in batch {
                for facet in activeFacets(for: w) {
                    let key = "\(w.id)\0\(facet)"
                    let have = (reviewCounts[key] ?? 0) + (sessionCounts[key] ?? 0) + (scheduled[key] ?? 0)
                    let need = max(0, Self.reviewThreshold - have)
                    for _ in 0..<need {
                        chunk.append(makePlantQuizItem(word: w, facet: facet))
                    }
                }
            }
        }

        chunk.shuffle()
        avoidAdjacentRepeats(&chunk, prevTailWordId: pendingQueue.last?.wordId)
        pendingQueue.append(contentsOf: chunk)
    }

    private func facetSessionCount(_ wordId: String, _ facet: String) -> Int {
        sessionCounts["\(wordId)\0\(facet)"] ?? 0
    }

    /// Best-effort fix for back-to-back repeats of the same wordId, both at the chunk's
    /// boundary with the existing queue tail and within the chunk itself. Not exhaustive —
    /// if the chunk is dominated by one word, some adjacency is unavoidable.
    private func avoidAdjacentRepeats(_ chunk: inout [PlantQuizItem],
                                       prevTailWordId: String?) {
        guard chunk.count > 1 else { return }
        if let prev = prevTailWordId, chunk[0].wordId == prev {
            for i in 1..<chunk.count where chunk[i].wordId != prev {
                chunk.swapAt(0, i); break
            }
        }
        var i = 1
        while i < chunk.count {
            if chunk[i].wordId == chunk[i - 1].wordId {
                var swapped = false
                for j in (i + 1)..<chunk.count where chunk[j].wordId != chunk[i - 1].wordId {
                    chunk.swapAt(i, j); swapped = true; break
                }
                if !swapped { break }
            }
            i += 1
        }
    }

    private func makePlantQuizItem(word: VocabItem, facet: String) -> PlantQuizItem {
        let kana = preferredKana(for: word)
        let docSenseIndices: [Int] = docScopedSenseIndices(for: word)
        return PlantQuizItem(wordId: word.id, wordText: word.wordText,
                             kanaText: kana, facet: facet, senseIndices: docSenseIndices)
    }

    /// Resolves annotated forms from this document's first reference for the word,
    /// falling back to the item-level annotatorResolved (computed from the first source overall).
    func documentResolvedForms(for word: VocabItem) -> ResolvedAnnotatorForms? {
        let forms = word.references[documentTitle]?.first?.annotatedForms ?? []
        return resolveAnnotatedForms(annotatedForms: forms,
                                     writtenForms: word.writtenForms,
                                     kanaTexts: word.kanaTexts)
            ?? word.annotatorResolved
    }

    /// Kana reading respecting the annotator's choice and any user commitment.
    private func preferredKana(for word: VocabItem) -> String {
        word.commitment?.committedReading
            ?? documentResolvedForms(for: word)?.kana
            ?? word.kanaTexts.first
            ?? word.wordText
    }

    /// Written form respecting the annotator's choice and any user commitment.
    private func preferredWrittenForm(for word: VocabItem) -> String {
        word.commitment?.committedWrittenText
            ?? documentResolvedForms(for: word)?.writtenForm.text
            ?? word.writtenTexts.first
            ?? word.wordText
    }

    /// Sense indices attested in this document, falling back to [0].
    private func docScopedSenseIndices(for word: VocabItem) -> [Int] {
        let refs = word.references[documentTitle] ?? []
        let indices = Array(Set(refs.compactMap(\.llmSense).flatMap(\.senseIndices))).sorted()
        return indices.isEmpty ? [0] : indices
    }

    /// First gloss for the sense(s) attested in this document.
    private func firstGlossForDocument(word: VocabItem) -> String {
        firstGloss(for: word, senseIndices: docScopedSenseIndices(for: word))
    }

    // MARK: - Private: app-side multiple-choice generation

    /// Build an app-side MC question for a planting drill item.
    /// No LLM call; distractors come from other words in the same document.
    private func buildMultipleChoice(item: PlantQuizItem) -> PlantingMultipleChoice {
        guard let word = documentWords.first(where: { $0.id == item.wordId }) else {
            return PlantingMultipleChoice(stem: item.wordText,
                                         choices: ["—", "—", "—", "—"],
                                         correctIndex: 0, item: item)
        }
        switch item.facet {

        case "reading-to-meaning":
            let correct = firstGloss(for: word, senseIndices: item.senseIndices)
            let distractors = glossDistractors(excluding: word.id, correct: correct)
            let (choices, idx) = assembleChoices(correct: correct, distractors: distractors)
            return PlantingMultipleChoice(stem: "What does \(item.kanaText) mean?",
                                         choices: choices, correctIndex: idx, item: item)

        case "meaning-to-reading":
            let gloss   = firstGloss(for: word, senseIndices: item.senseIndices)
            let correct = item.kanaText
            let distractors = kanaDistractors(excluding: word.id, correct: correct)
            let (choices, idx) = assembleChoices(correct: correct, distractors: distractors)
            return PlantingMultipleChoice(stem: gloss,
                                         choices: choices, correctIndex: idx, item: item)

        case "kanji-to-reading":
            let kanji   = preferredWrittenForm(for: word)
            let correct = item.kanaText
            let distractors = kanaDistractors(excluding: word.id, correct: correct)
            let (choices, idx) = assembleChoices(correct: correct, distractors: distractors)
            return PlantingMultipleChoice(stem: "Reading of \(kanji)?",
                                         choices: choices, correctIndex: idx, item: item)

        case "meaning-reading-to-kanji":
            let gloss   = firstGloss(for: word, senseIndices: item.senseIndices)
            let kanji   = preferredWrittenForm(for: word)
            let correct = kanji
            let distractors = kanjiDistractors(excluding: word.id, correct: correct)
            let (choices, idx) = assembleChoices(correct: correct, distractors: distractors)
            return PlantingMultipleChoice(stem: "\(gloss) (\(item.kanaText))",
                                         choices: choices, correctIndex: idx, item: item)

        default:
            return PlantingMultipleChoice(stem: "What does \(item.wordText) mean?",
                                         choices: ["—", "—", "—", "—"],
                                         correctIndex: 0, item: item)
        }
    }

    private func firstGloss(for word: VocabItem, senseIndices: [Int]) -> String {
        for i in senseIndices {
            if i < word.senseExtras.count,
               let gloss = word.senseExtras[i].glosses.first {
                return gloss
            }
        }
        return word.senseExtras.first?.glosses.first ?? word.wordText
    }

    private func glossDistractors(excluding wordId: String, correct: String) -> [String] {
        var result: [String] = []
        for word in documentWords where word.id != wordId {
            let gloss = firstGlossForDocument(word: word)
            if !gloss.isEmpty && gloss != correct {
                result.append(gloss)
                if result.count >= 6 { break }
            }
        }
        return result
    }

    private func kanaDistractors(excluding wordId: String, correct: String) -> [String] {
        var result: [String] = []
        for word in documentWords where word.id != wordId {
            let kana = preferredKana(for: word)
            if kana != correct {
                result.append(kana)
                if result.count >= 6 { break }
            }
        }
        return result
    }

    private func kanjiDistractors(excluding wordId: String, correct: String) -> [String] {
        var result: [String] = []
        for word in documentWords where word.id != wordId {
            let kanji = preferredWrittenForm(for: word)
            if kanji != correct {
                result.append(kanji)
                if result.count >= 6 { break }
            }
        }
        return result
    }

    /// Mix the correct answer with up to three distractors, shuffle, and return
    /// (choices, correctIndex).  The result is always exactly 4 items.
    private func assembleChoices(correct: String, distractors: [String]) -> ([String], Int) {
        var candidates = Array(distractors.shuffled().prefix(3))
        candidates.append(correct)
        candidates.shuffle()
        // Pad to exactly 4 in case there were fewer than 3 distractors.
        while candidates.count < 4 { candidates.append("—") }
        let choices = Array(candidates.prefix(4))
        let idx = choices.firstIndex(of: correct) ?? 0
        return (choices, idx)
    }

    // MARK: - Private: review recording

    /// Record a review to the DB and update the local review count.
    private func recordPlantingReview(item: PlantQuizItem, score: Double) async {
        let now = ISO8601DateFormatter().string(from: Date())
        let review = Review(
            reviewer: deviceName(),
            timestamp: now,
            wordType: "jmdict",
            wordId: item.wordId,
            wordText: item.wordText,
            score: score,
            quizType: item.facet,
            notes: "planting"
        )
        try? await db.insert(review: review)

        // Update the Ebisu model (same logic as QuizSession.recordReview).
        do {
            let existing = try await db.ebisuRecord(wordType: "jmdict",
                                                    wordId: item.wordId,
                                                    quizType: item.facet)
            let oldModel: EbisuModel
            let lastReview: String
            if let rec = existing {
                oldModel   = rec.model
                lastReview = rec.lastReview
            } else {
                oldModel   = defaultModel(halflife: Self.initialHalflife)
                lastReview = now
            }
            let referenceDate = parseISO8601(lastReview) ?? .distantPast
            let elapsed       = max(Date().timeIntervalSince(referenceDate) / 3600.0, 1e-6)
            let newModel      = try updateRecall(oldModel, successes: score, total: 1, tnow: elapsed)
            let record = EbisuRecord(wordType: "jmdict", wordId: item.wordId, quizType: item.facet,
                                     alpha: newModel.alpha, beta: newModel.beta, t: newModel.t,
                                     lastReview: now)
            try await db.upsert(record: record)
            let event = ModelEvent(timestamp: now, wordType: "jmdict",
                                   wordId: item.wordId, quizType: item.facet,
                                   event: "reviewed,\(String(format: "%.2f", score))")
            try await db.log(event: event)
        } catch {
            print("[PlantingSession] Ebisu update error: \(error)")
        }

        // Update local count so threshold checks are immediate.
        let key = "\(item.wordId)\0\(item.facet)"
        reviewCounts[key] = (reviewCounts[key] ?? 0) + 1
    }

    private func deviceName() -> String {
#if os(iOS)
        return UIDevice.current.name
#else
        return ProcessInfo.processInfo.hostName
#endif
    }
}
