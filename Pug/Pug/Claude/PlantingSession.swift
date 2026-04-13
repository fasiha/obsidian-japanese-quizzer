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
        case allDone                                  // every word in the document is planted
        case noNewWords                               // all words already above threshold
        case error(String)
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

    /// Review counts keyed by "wordId\0facet".
    /// Seeded from the DB at session start; incremented locally after each drill answer.
    private(set) var reviewCounts: [String: Int] = [:]

    // MARK: - Interleaved drill state
    //
    // Drilling is organized into "rounds". A round is a pre-built, shuffled list containing
    // one drill question for each word introduced so far in the batch — specifically the first
    // facet of that word that is still below reviewThreshold.
    //
    // The session works through the round question by question. When the round is exhausted:
    //   • If there are more words to introduce in the batch → show the next introduce card.
    //   • Else if any (word, facet) is still below threshold → build another round and continue.
    //   • Else → advance to the next batch.
    //
    // This produces the interleaved Memrise-style pattern:
    //   Introduce word 1 → round [w1] → Introduce word 2 → round [w1, w2] →
    //   Introduce word 3 → round [w1, w2, w3] → ... → rounds until all at threshold.
    //
    // Words introduced earlier naturally accumulate more total drills, but every word
    // reaches the same minimum of reviewThreshold reviews per facet.

    /// The pre-built question sequence for the current round.
    /// Items are consumed from the front by advanceAfterDrill().
    private var currentRoundQueue: [PlantQuizItem] = []

    /// The wordId of the most recently answered drill question.
    /// Used to avoid presenting the same word back-to-back across round boundaries.
    private var lastDrilledWordId: String? = nil

    /// The word being introduced in the current introduce-card phase (nil otherwise).
    private(set) var currentIntroWord: VocabItem? = nil

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

    // MARK: - Init

    init(db: QuizDB) {
        self.db = db
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
        let includeKanji = currentIntroKanjiEnabled
        kanjiEnabled[word.id] = includeKanji
        phase = .loading
        Task {
            do {
                try await db.setReadingLearning(wordType: "jmdict", wordId: word.id,
                                                halflife: Self.initialHalflife)
                if includeKanji && !word.writtenTexts.isEmpty {
                    try await db.setKanjiLearning(wordType: "jmdict", wordId: word.id,
                                                  halflife: Self.initialHalflife)
                }
            } catch {
                // Word may already have Ebisu models (recovery from a prior session).
                print("[PlantingSession] setFacetLearning: \(error)")
            }
            batchIntroducedCount += 1
            startDrillRound()
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
        let includeKanji = currentIntroKanjiEnabled
        phase = .loading
        Task {
            do {
                try await db.setReadingKnown(wordType: "jmdict", wordId: word.id)
                if includeKanji && !word.writtenTexts.isEmpty {
                    try await db.setKanjiKnown(wordType: "jmdict", wordId: word.id)
                }
            } catch {
                print("[PlantingSession] tapKnown: \(error)")
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
        phase = .tapFeedback(correct: correct, explanation)
        lastDrilledWordId = mc.item.wordId
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
        kanjiEnabled       = [:]
        currentRoundQueue  = []
        lastDrilledWordId  = nil

        if recovered.isEmpty {
            phase = .noNewWords
            return
        }

        // If the first batch contains already-introduced words, mark them as introduced so
        // the session goes directly to drilling them instead of showing their intro cards again.
        let firstBatch = Array(recovered.prefix(Self.batchSize))
        batchIntroducedCount = firstBatch.filter { enrolledWordIds.contains($0.id) }.count

        introduceNextWord()
    }

    // MARK: - Private: introduce flow

    private func introduceNextWord() {
        let batch = currentBatch
        guard batchIntroducedCount < batch.count else {
            // All words in the batch have been introduced — go straight to drill.
            startDrillRound()
            return
        }
        currentIntroWord             = batch[batchIntroducedCount]
        currentIntroKanjiEnabled     = false
        currentIntroSelectedKanji    = []
        phase = .introducing
    }

    // MARK: - Private: drill flow

    /// Called after "Got it" (a new word was just introduced) and after each drill answer.
    /// Presents the next question from the current round, or decides what comes next when
    /// the round is exhausted.
    private func startDrillRound() {
        // If the current round still has questions, show the next one immediately.
        if let next = currentRoundQueue.first {
            currentRoundQueue.removeFirst()
            phase = .awaitingTap(buildMultipleChoice(item: next))
            return
        }

        // The round queue is empty. Build a new round for all introduced words.
        let newRound = buildOneRound()

        if newRound.isEmpty {
            // Every introduced (word, facet) pair has reached reviewThreshold.
            if batchIntroducedCount < currentBatch.count {
                // More words remain to introduce in this batch — show the next introduce card.
                introduceNextWord()
            } else {
                // The entire batch is planted and drilled to threshold.
                advanceBatch()
            }
            return
        }

        // More drilling needed. Load the new round and present its first question.
        // (We already decided to start a new round, so currentRoundQueue holds questions 2…N.)
        currentRoundQueue = Array(newRound.dropFirst())
        phase = .awaitingTap(buildMultipleChoice(item: newRound[0]))
    }

    /// Called when the student taps "Continue" after drill feedback.
    /// Records the just-answered word as the last drilled, then advances.
    func continueAfterFeedback() {
        guard case .tapFeedback = phase else { return }
        advanceAfterDrill()
    }

    private func advanceAfterDrill() {
        startDrillRound()
    }

    // MARK: - Private: batch management

    private func advanceBatch() {
        // Drop the completed batch from the front of the queue.
        let batchCount = currentBatch.count
        remainingWords.removeFirst(batchCount)
        batchIntroducedCount = 0
        kanjiEnabled         = [:]
        currentRoundQueue    = []
        lastDrilledWordId    = nil

        if remainingWords.isEmpty {
            phase = .allDone
            return
        }
        introduceNextWord()
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

    /// Build one round of drill questions: one question per introduced word that still has
    /// at least one facet below reviewThreshold. Returns an empty array when all introduced
    /// words are fully drilled (caller should then introduce the next word or advance the batch).
    ///
    /// The round is shuffled and then adjusted so the first question is not for the same word
    /// as the last question of the previous round (stored in lastDrilledWordId). This prevents
    /// the same word from appearing back-to-back across round boundaries.
    private func buildOneRound() -> [PlantQuizItem] {
        let introduced = Array(currentBatch.prefix(batchIntroducedCount))
        var round: [PlantQuizItem] = []
        for word in introduced {
            // Pick the first facet for this word that is still below threshold.
            for facet in activeFacets(for: word) {
                if (reviewCounts["\(word.id)\0\(facet)"] ?? 0) < Self.reviewThreshold {
                    round.append(makePlantQuizItem(word: word, facet: facet))
                    break
                }
            }
        }

        guard !round.isEmpty else { return [] }

        round.shuffle()

        // If the first item repeats the word that was just drilled, rotate the array by one
        // position so no word appears back-to-back across round boundaries.
        if round.count > 1, round[0].wordId == lastDrilledWordId {
            round.append(round.removeFirst())
        }

        return round
    }

    private func makePlantQuizItem(word: VocabItem, facet: String) -> PlantQuizItem {
        let kana = word.commitment?.committedReading ?? word.kanaTexts.first ?? word.wordText
        let docSenseIndices: [Int] = {
            let refs = word.references[documentTitle] ?? []
            let indices = Array(Set(refs.compactMap(\.llmSense).flatMap(\.senseIndices))).sorted()
            return indices.isEmpty ? [0] : indices
        }()
        return PlantQuizItem(wordId: word.id, wordText: word.wordText,
                             kanaText: kana, facet: facet, senseIndices: docSenseIndices)
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
            let kanji   = word.writtenTexts.first ?? word.wordText
            let correct = item.kanaText
            let distractors = kanaDistractors(excluding: word.id, correct: correct)
            let (choices, idx) = assembleChoices(correct: correct, distractors: distractors)
            return PlantingMultipleChoice(stem: "Reading of \(kanji)?",
                                         choices: choices, correctIndex: idx, item: item)

        case "meaning-reading-to-kanji":
            let gloss   = firstGloss(for: word, senseIndices: item.senseIndices)
            let kanji   = word.writtenTexts.first ?? word.wordText
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
            if let gloss = word.senseExtras.first?.glosses.first, gloss != correct {
                result.append(gloss)
                if result.count >= 6 { break }
            }
        }
        return result
    }

    private func kanaDistractors(excluding wordId: String, correct: String) -> [String] {
        var result: [String] = []
        for word in documentWords where word.id != wordId {
            let kana = word.commitment?.committedReading ?? word.kanaTexts.first ?? ""
            if !kana.isEmpty && kana != correct {
                result.append(kana)
                if result.count >= 6 { break }
            }
        }
        return result
    }

    private func kanjiDistractors(excluding wordId: String, correct: String) -> [String] {
        var result: [String] = []
        for word in documentWords where word.id != wordId {
            if let kanji = word.writtenTexts.first, kanji != correct {
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
