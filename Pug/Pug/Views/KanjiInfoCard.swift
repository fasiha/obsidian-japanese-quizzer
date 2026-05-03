// KanjiInfoCard.swift
// Per-kanji enrollment card shown in WordDetailSheet and PlantView.
// Displays the kanji, its reading in this word, active kanjidic2 meanings,
// general readings/meanings for context, and enrollment toggle.
// "Also learning in" rows are rendered below the card bubble and are tappable.

import GRDB
import SwiftUI

// MARK: - KanjiInfoCard

struct KanjiInfoCard: View {
    let kanji: String
    /// Reading used in this word (from the committed furigana segments).
    let wordReading: String?
    /// LLM-identified kanjidic2 meanings active in this word. Empty when not yet analyzed.
    let activeWordMeanings: [String]
    /// Open DatabaseReader on kanjidic2.sqlite. Nil when not available.
    let kanjidicDB: (any DatabaseReader)?
    /// Whether the word-context kanji facets (kanji-to-reading, meaning-reading-to-kanji) are enrolled.
    let isWordEnrolled: Bool
    /// Whether the global kanji quiz facets (kanji-to-on-reading, kanji-to-kun-reading, kanji-to-meaning) are enrolled.
    let isKanjiEnrolled: Bool
    /// Other words where this kanji is also enrolled, with a callback to navigate to them.
    let otherWords: [VocabItem]
    /// Toggles the word-context kanji facets for this word.
    let onToggleWord: () -> Void
    /// Toggles the global kanji quiz facets for this kanji character.
    let onToggleKanji: () -> Void
    /// Called when the user taps one of the "Also learning in" word rows.
    let onTapOtherWord: (VocabItem) -> Void

    @State private var onReadings: [String] = []
    @State private var kunReadings: [String] = []
    @State private var allKanjidicMeanings: [String] = []
    /// True after `loadKanjidicData` returns with no row in `kanjidic2.kanji` for this
    /// character. ~98 CJK characters in JMDict (rare/archaic variants) are absent from
    /// kanjidic2; without this flag the card silently omits its readings/meanings section
    /// with no explanation.
    @State private var kanjidicLookupMissing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardBubble
            if !otherWords.isEmpty {
                alsoLearningInRows
            }
        }
    }

    // MARK: - Card bubble

    private var cardBubble: some View {
        let hasGeneralSection = !onReadings.isEmpty || !kunReadings.isEmpty || !allKanjidicMeanings.isEmpty
        let eitherEnrolled = isWordEnrolled || isKanjiEnrolled
        return VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggleWord) {
                thisWordSection
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(isWordEnrolled ? Color.green.opacity(0.1) : Color.clear)
            }
            .buttonStyle(.plain)
            if hasGeneralSection {
                Divider()
                Button(action: onToggleKanji) {
                    generalSection
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(isKanjiEnrolled ? Color.green.opacity(0.1) : Color.clear)
                }
                .buttonStyle(.plain)
            } else if kanjidicLookupMissing {
                Divider()
                Text("No detailed information available for this character.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(eitherEnrolled ? Color.green : Color.clear, lineWidth: 1.5)
        )
        .task(id: kanji) { await loadKanjidicData() }
    }

    // MARK: - This word section

    private var thisWordSection: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(kanji)
                .font(.system(size: 48, weight: .regular))

            VStack(alignment: .leading, spacing: 4) {
                if let reading = wordReading {
                    Text(reading)
                        .font(.title3)
                        .foregroundStyle(isWordEnrolled ? Color.green : .primary)
                }
                if !activeWordMeanings.isEmpty {
                    Text(activeWordMeanings.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                } else if !allKanjidicMeanings.isEmpty {
                    Text(allKanjidicMeanings.prefix(2).joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Image(systemName: isWordEnrolled ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(isWordEnrolled ? Color.green : Color.secondary)
        }
    }

    // MARK: - General kanjidic2 readings + meanings section

    /// Three left-aligned rows (on-readings, kun-readings, meanings) with a shared enrollment
    /// checkbox on the right. Each row only appears when data is available.
    private var generalSection: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if !onReadings.isEmpty {
                    onReadingsRow
                }
                if !displayKunReadings.isEmpty {
                    kunReadingsRow
                }
                if !allKanjidicMeanings.isEmpty {
                    meaningsRow
                }
            }
            Spacer()
            Image(systemName: isKanjiEnrolled ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(isKanjiEnrolled ? Color.green : Color.secondary)
        }
    }

    /// On-readings row: label + top 2 katakana readings, word-match highlighted.
    private var onReadingsRow: some View {
        HStack(spacing: 6) {
            Text("音:")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(onReadings.prefix(2), id: \.self) { on in
                Text(on)
                    .font(.subheadline)
                    .foregroundStyle(isWordReading(on) ? Color.primary : Color.secondary)
            }
        }
    }

    /// Kun-readings row: label + top 2 hiragana readings (deduplicated), word-match highlighted.
    private var kunReadingsRow: some View {
        HStack(spacing: 6) {
            Text("訓:")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(displayKunReadings, id: \.self) { kun in
                Text(kun)
                    .font(.subheadline)
                    .foregroundStyle(isWordReading(kun) ? Color.primary : Color.secondary)
            }
        }
    }

    /// Top 2 kanjidic2 meanings. Meanings that are active in this word are shown at
    /// primary brightness; others at secondary.
    private var meaningsRow: some View {
        let active = Set(activeWordMeanings)
        let top2 = Array(allKanjidicMeanings.prefix(2))
        return HStack(spacing: 0) {
            ForEach(Array(top2.enumerated()), id: \.offset) { idx, meaning in
                if idx > 0 {
                    Text(", ")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(meaning)
                    .font(.subheadline)
                    .foregroundStyle(active.contains(meaning) ? Color.primary : Color.secondary)
            }
        }
    }

    // MARK: - Also learning in rows

    private var alsoLearningInRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(otherWords) { word in
                Button {
                    onTapOtherWord(word)
                } label: {
                    HStack {
                        Text("Learning via: \(word.wordText)")
                            .font(.caption)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Kun reading normalization

    /// Kun-readings with leading dashes stripped, deduplicated by base (before dot), top 2.
    private var displayKunReadings: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for kun in kunReadings {
            let stripped = kun.hasPrefix("-") ? String(kun.dropFirst()) : kun
            let base = stripped.components(separatedBy: ".").first ?? stripped
            if seen.insert(base).inserted {
                result.append(base)
            }
        }
        return Array(result.prefix(2))
    }

    // MARK: - Reading match helpers

    /// True when the given kanjidic2 reading (on or kun) matches the word's committed reading.
    /// Handles katakana→hiragana conversion for on-readings and rendaku for kun-readings.
    private func isWordReading(_ reading: String) -> Bool {
        guard let wr = wordReading else { return false }
        // On-readings are katakana — convert to hiragana for comparison.
        if katakanaToHiragana(reading) == wr { return true }
        // Kun-readings: strip leading dash, compare base before dot, also check rendaku.
        let stripped = reading.hasPrefix("-") ? String(reading.dropFirst()) : reading
        let base = stripped.components(separatedBy: ".").first ?? stripped
        if base == wr { return true }
        if let r = rendakuForm(base), r == wr { return true }
        return false
    }

    /// Returns the rendaku (voiced) form of a hiragana string by voicing its first mora,
    /// or nil if the first character is not voiceable.
    private func rendakuForm(_ hiragana: String) -> String? {
        guard let first = hiragana.unicodeScalars.first else { return nil }
        let v = first.value
        let voiced: UInt32
        switch v {
        case 0x304B, 0x304D, 0x304F, 0x3051, 0x3053: voiced = v + 1  // か き く け こ
        case 0x3055, 0x3057, 0x3059, 0x305B, 0x305D: voiced = v + 1  // さ し す せ そ
        case 0x305F, 0x3061, 0x3064, 0x3066, 0x3068: voiced = v + 1  // た ち つ て と
        case 0x306F, 0x3072, 0x3075, 0x3078, 0x307B: voiced = v + 1  // は ひ ふ へ ほ
        default: return nil
        }
        guard let scalar = Unicode.Scalar(voiced) else { return nil }
        return String(scalar) + String(hiragana.dropFirst())
    }

    private func kunBase(_ kun: String) -> String {
        kun.components(separatedBy: ".").first ?? kun
    }

    private func katakanaToHiragana(_ katakana: String) -> String {
        String(katakana.unicodeScalars.map { scalar in
            if scalar.value >= 0x30A1 && scalar.value <= 0x30F6,
               let h = Unicode.Scalar(scalar.value - 0x60) {
                return Character(h)
            }
            return Character(scalar)
        })
    }

    // MARK: - Data loading

    private func loadKanjidicData() async {
        guard let db = kanjidicDB else { return }
        let result = try? await db.read { conn -> (rowFound: Bool, on: [String], kun: [String], meanings: [String]) in
            let row = try Row.fetchOne(conn,
                sql: "SELECT on_readings, kun_readings, meanings FROM kanji WHERE literal = ?",
                arguments: [kanji])
            func decodeJSON(_ key: String) -> [String] {
                guard let json = row?[key] as? String,
                      let arr = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String]
                else { return [] }
                return arr
            }
            return (row != nil,
                    decodeJSON("on_readings"), decodeJSON("kun_readings"), decodeJSON("meanings"))
        }
        if let result {
            onReadings = result.on
            kunReadings = result.kun
            allKanjidicMeanings = result.meanings
            kanjidicLookupMissing = !result.rowFound
        }
    }
}

// MARK: - Helper: reading for a kanji in furigana segments

/// Returns the reading annotation (rt) for the given kanji character in a furigana segment array.
/// Returns nil when the kanji is not found or has no annotation.
func readingForKanji(_ kanji: String, in segments: [FuriganaSegment]) -> String? {
    for seg in segments where seg.rt != nil {
        if seg.ruby == kanji { return seg.rt }
        // Multi-character ruby: cannot split the reading per-character, so skip.
    }
    return nil
}
