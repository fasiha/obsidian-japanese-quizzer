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

        // Load enrollment status.
        // Words with explicit vocab_enrollment rows use those.
        // Words with ebisu_models rows but no enrollment row are treated as enrolled —
        // this covers words introduced via the Node.js quiz before the iOS app existed.
        let enrollmentMap   = (try? await db.allEnrollments()) ?? [:]
        let ebisuWordIds    = (try? await db.wordIdsWithEbisuModels()) ?? []

        // Build items (skip words not found in JMdict).
        items = manifest.words.compactMap { entry in
            guard let jd = jmdictData[entry.id] else { return nil }
            let status: EnrollmentStatus
            if let explicit = enrollmentMap[entry.id] {
                status = explicit
            } else if ebisuWordIds.contains(entry.id) {
                status = .enrolled
            } else {
                status = .pending
            }
            return VocabItem(
                id: entry.id,
                sources: entry.sources,
                wordText: jd.text,
                writtenTexts: jd.writtenTexts,
                kanaTexts: jd.kanaTexts,
                meanings: jd.meanings,
                status: status
            )
        }
        print("[VocabCorpus] loaded \(items.count)/\(manifest.words.count) word(s) " +
              "(\(manifest.words.count - items.count) skipped — not in JMdict)")
    }

    // MARK: - Enrollment

    /// Update one word's enrollment status, creating Ebisu models if enrolling.
    func setStatus(_ status: EnrollmentStatus, for wordId: String, db: QuizDB) async {
        guard let idx = items.firstIndex(where: { $0.id == wordId }) else { return }
        do {
            try await db.setEnrollment(wordType: "jmdict", wordId: wordId, status: status)
            if status == .enrolled {
                // Start with reading/meaning facets only (hasKanji = false).
                // QuizContext infers hasKanji from which facets exist in ebisu_models,
                // so {kanji-ok} facets can be added later via a settings option.
                try await db.introduceWord(
                    wordType: "jmdict",
                    wordId: wordId,
                    wordText: items[idx].wordText,
                    hasKanji: false,
                    halflife: 24
                )
            }
            items[idx].status = status
        } catch {
            print("[VocabCorpus] setStatus error for \(wordId): \(error)")
        }
    }

    // MARK: - Re-download

    /// Force a fresh download from the remote URL, then reload.
    func redownload(db: QuizDB, jmdict: any DatabaseReader) async {
        await load(db: db, jmdict: jmdict, download: true)
    }
}
