// KanjiInfoCard.swift
// Per-kanji enrollment card shown in WordDetailSheet and PlantView.
// Displays the kanji, its reading in this word, active kanjidic2 meanings,
// general readings/meanings for context, and enrollment toggle.

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
    let isEnrolled: Bool
    /// True when this is the only enrolled kanji — disables unenrollment to prevent empty selection.
    let isLastEnrolled: Bool
    /// Other word display texts where the learner is also enrolled in this kanji.
    let otherWords: [String]
    let onToggle: () -> Void

    @State private var onReadings: [String] = []
    @State private var kunReadings: [String] = []
    @State private var allKanjidicMeanings: [String] = []

    var body: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: 10) {
                thisWordSection
                if showGeneralSection {
                    Divider()
                    generalSection
                }
                if !otherWords.isEmpty {
                    Divider()
                    Text("Also learning in: \(otherWords.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isEnrolled ? Color.green.opacity(0.1) : Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isEnrolled ? Color.green : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(isLastEnrolled)
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
                        .foregroundStyle(isEnrolled ? Color.green : .primary)
                }
                if !activeWordMeanings.isEmpty {
                    Text(activeWordMeanings.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                } else {
                    Text(allKanjidicMeanings.prefix(2).joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Image(systemName: isEnrolled ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(isEnrolled ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
        }
    }

    // MARK: - General kanjidic2 section

    /// True when there is on/kun reading info or additional meanings not shown in the this-word section.
    private var showGeneralSection: Bool {
        !generalOnReadings.isEmpty || !generalKunReadings.isEmpty || !additionalMeanings.isEmpty
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !generalOnReadings.isEmpty || !generalKunReadings.isEmpty {
                let readingParts = [
                    generalOnReadings.isEmpty ? nil : "音: \(generalOnReadings.prefix(1).joined())",
                    generalKunReadings.isEmpty ? nil : "訓: \(generalKunReadings.prefix(1).map(kunBase).joined())"
                ].compactMap { $0 }
                Text(readingParts.joined(separator: "  "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !additionalMeanings.isEmpty {
                Text(additionalMeanings.prefix(2).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// On-readings to show in the general section: those not matching the word reading.
    private var generalOnReadings: [String] {
        guard !onReadings.isEmpty else { return [] }
        // On-readings are katakana; compare to wordReading (hiragana) via conversion.
        if let wr = wordReading, onReadings.contains(where: { katakanaToHiragana($0) == wr }) {
            // Word reading is an on-reading — omit it from general section but show kun.
            return []
        }
        return onReadings
    }

    /// Kun-readings to show in the general section: those not matching the word reading.
    private var generalKunReadings: [String] {
        guard !kunReadings.isEmpty else { return [] }
        if let wr = wordReading, kunReadings.contains(where: { kunBase($0) == wr }) {
            // Word reading is a kun-reading — omit it from general section but show on.
            return []
        }
        return kunReadings
    }

    /// Kanjidic2 meanings not already shown in activeWordMeanings.
    private var additionalMeanings: [String] {
        let active = Set(activeWordMeanings)
        return allKanjidicMeanings.filter { !active.contains($0) }
    }

    // MARK: - Data loading

    private func loadKanjidicData() async {
        guard let db = kanjidicDB else { return }
        let result = try? await db.read { conn -> (on: [String], kun: [String], meanings: [String]) in
            let row = try Row.fetchOne(conn,
                sql: "SELECT on_readings, kun_readings, meanings FROM kanji WHERE literal = ?",
                arguments: [kanji])
            func decodeJSON(_ key: String) -> [String] {
                guard let json = row?[key] as? String,
                      let arr = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String]
                else { return [] }
                return arr
            }
            return (decodeJSON("on_readings"), decodeJSON("kun_readings"), decodeJSON("meanings"))
        }
        if let result {
            onReadings = result.on
            kunReadings = result.kun
            allKanjidicMeanings = result.meanings
        }
    }

    // MARK: - Helpers

    /// Returns the kun-reading base (part before the okurigana dot, if any).
    private func kunBase(_ kun: String) -> String {
        kun.components(separatedBy: ".").first ?? kun
    }

    /// Converts a katakana string to hiragana by shifting each scalar by -0x60.
    private func katakanaToHiragana(_ katakana: String) -> String {
        String(katakana.unicodeScalars.map { scalar in
            if scalar.value >= 0x30A1 && scalar.value <= 0x30F6,
               let h = Unicode.Scalar(scalar.value - 0x60) {
                return Character(h)
            }
            return Character(scalar)
        })
    }
}

// MARK: - Helper: reading for a kanji in furigana segments

/// Returns the reading annotation (rt) for the given kanji character in a furigana segment array.
/// Returns nil when the kanji is not found or has no annotation.
func readingForKanji(_ kanji: String, in segments: [FuriganaSegment]) -> String? {
    for seg in segments where seg.rt != nil {
        if seg.ruby == kanji { return seg.rt }
        // Multi-character ruby: if ruby consists of kanji characters and contains our target,
        // we cannot split the reading per-character, so skip.
    }
    return nil
}
