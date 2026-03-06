// VocabCorpus.swift
// Observable state for the published vocab corpus.
// Loads vocab.json (from cache or download), enriches each word with JMdict data,
// and tracks per-word enrollment status from quiz.sqlite.

import GRDB
import Foundation

// MARK: - VocabItem

/// One word in the corpus, enriched with JMdict data and the user's enrollment status.
struct VocabItem: Identifiable {
    let id: String              // JMDict entry ID
    let sources: [String]       // story titles this word appears in
    let wordText: String        // primary display form (first written form, or first kana if none)
    let writtenTexts: [String]  // non-irregular orthographic (kanji/mixed) forms
    let kanaTexts: [String]     // non-irregular kana-only forms
    let meanings: [String]      // English glosses from all senses
    var status: EnrollmentStatus
    var kanjiOk: Bool           // true → user committed to kanji facets (only meaningful when .learning)
}

// MARK: - VocabCorpus

@Observable
@MainActor
final class VocabCorpus {
    private(set) var items: [VocabItem] = []
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

        // Load enrollment records. reconcileEnrollment() runs at startup so every
        // word backed by ebisu_models already has a vocab_enrollment row.
        let enrollmentMap = (try? await db.allEnrollments()) ?? [:]

        // Build items (skip words not found in JMdict).
        items = manifest.words.compactMap { entry in
            guard let jd = jmdictData[entry.id] else { return nil }
            let enrollment = enrollmentMap[entry.id]
            return VocabItem(
                id: entry.id,
                sources: entry.sources,
                wordText: jd.text,
                writtenTexts: jd.writtenTexts,
                kanaTexts: jd.kanaTexts,
                meanings: jd.meanings,
                status: enrollment?.status ?? .notYetLearned,
                kanjiOk: enrollment?.kanjiOk ?? false
            )
        }
        print("[VocabCorpus] loaded \(items.count)/\(manifest.words.count) word(s) " +
              "(\(manifest.words.count - items.count) skipped — not in JMdict)")
    }

    // MARK: - Learning actions

    /// Start learning a word. Creates Ebisu models and sets status = .learning.
    func startLearning(wordId: String, kanjiOk: Bool, db: QuizDB) async {
        guard let idx = items.firstIndex(where: { $0.id == wordId }) else { return }
        do {
            try await db.setLearning(
                wordType: "jmdict",
                wordId: wordId,
                wordText: items[idx].wordText,
                kanjiOk: kanjiOk
            )
            items[idx].status = .learning
            items[idx].kanjiOk = kanjiOk
        } catch {
            print("[VocabCorpus] startLearning error for \(wordId): \(error)")
        }
    }

    /// Stop learning a word — archives Ebisu models and removes from vocab_enrollment.
    func stopLearning(wordId: String, db: QuizDB) async {
        guard let idx = items.firstIndex(where: { $0.id == wordId }) else { return }
        do {
            try await db.archiveAndRemove(wordType: "jmdict", wordId: wordId, reason: "unlearned")
            items[idx].status = .notYetLearned
            items[idx].kanjiOk = false
        } catch {
            print("[VocabCorpus] stopLearning error for \(wordId): \(error)")
        }
    }

    /// Mark a word as known — archives Ebisu models and sets status = .known.
    func markKnown(wordId: String, db: QuizDB) async {
        guard let idx = items.firstIndex(where: { $0.id == wordId }) else { return }
        do {
            try await db.archiveAndRemove(wordType: "jmdict", wordId: wordId, reason: "known")
            items[idx].status = .known
            items[idx].kanjiOk = false
        } catch {
            print("[VocabCorpus] markKnown error for \(wordId): \(error)")
        }
    }

    /// Toggle kanji commitment for a learning word.
    func toggleKanji(wordId: String, db: QuizDB) async {
        guard let idx = items.firstIndex(where: { $0.id == wordId }),
              items[idx].status == .learning else { return }
        do {
            try await db.toggleKanji(wordType: "jmdict", wordId: wordId,
                                     wordText: items[idx].wordText)
            items[idx].kanjiOk.toggle()
        } catch {
            print("[VocabCorpus] toggleKanji error for \(wordId): \(error)")
        }
    }

    /// Move a known word back to "not yet learned" — deletes the vocab_enrollment row.
    func undoKnown(wordId: String, db: QuizDB) async {
        guard let idx = items.firstIndex(where: { $0.id == wordId }) else { return }
        do {
            try await db.removeEnrollment(wordType: "jmdict", wordId: wordId)
            items[idx].status = .notYetLearned
            items[idx].kanjiOk = false
        } catch {
            print("[VocabCorpus] undoKnown error for \(wordId): \(error)")
        }
    }

    // MARK: - Re-download

    /// Force a fresh download from the remote URL, then reload.
    func redownload(db: QuizDB, jmdict: any DatabaseReader) async {
        await load(db: db, jmdict: jmdict, download: true)
    }
}
