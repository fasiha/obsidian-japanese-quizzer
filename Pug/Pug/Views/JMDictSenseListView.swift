// JMDictSenseListView.swift
// Shared view for rendering JMDict sense data (glosses, part-of-speech, metadata).
// Used by both WordDetailSheet and TransitivePairDetailSheet to keep dictionary
// display consistent across the app.

import SwiftUI

/// Renders a list of JMDict senses with glosses, part-of-speech, metadata tags,
/// cross-references, and optional dimming for non-enrolled senses.
struct JMDictSenseListView: View {
    let senseExtras: [SenseExtra]
    /// Corpus-attested sense indices (from llm_sense.sense_indices). When non-empty,
    /// non-corpus senses are dimmed to show which senses the student has encountered.
    var corpusSenseIndices: [Int] = []
    /// All written (kanji/mixed) forms for the word. Used to expand ["*"] in appliesToKanji
    /// to the full form list so the user can see which spellings each sense covers.
    var writtenTexts: [String] = []
    /// All kana readings for the word. Used to expand ["*"] in appliesToKana annotations.
    /// Only shown when there is more than one kana reading (single-kana words are unambiguous).
    var kanaTexts: [String] = []

    var body: some View {
        // Part of speech is shared across senses (JMDict convention: repeated on each sense,
        // but effectively describes the word). Deduplicate and show once at the top.
        let allPos = Array(NSOrderedSet(array: senseExtras.flatMap(\.partOfSpeech))) as? [String] ?? []
        if !allPos.isEmpty {
            Text(allPos.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        let useLabel = !corpusSenseIndices.isEmpty

        let senseList = ForEach(Array(senseExtras.enumerated()), id: \.offset) { index, sense in
            if index > 0 { Divider() }
            VStack(alignment: .leading, spacing: 2) {
                // Glosses for this sense
                ForEach(sense.glosses, id: \.self) { gloss in
                    Text("• \(gloss)")
                }

                // appliesToKanji annotation: show which written forms this sense covers.
                // Restricted (not ["*"]): list the specific forms.
                // Unrestricted (["*"]): enumerate all written forms so it's clear this sense
                // covers every spelling, not just the first one.
                if writtenTexts.count > 1 && !sense.appliesToKanji.isEmpty {
                    let forms: [String] = sense.appliesToKanji == ["*"] ? writtenTexts : sense.appliesToKanji
                    Text("Applies to: \(forms.joined(separator: ", "))")
                        .font(.caption)
                }
                if kanaTexts.count > 1 && !sense.appliesToKana.isEmpty && sense.appliesToKana != ["*"] {
                    Text("Read as: \(sense.appliesToKana.joined(separator: ", "))")
                        .font(.caption)
                }

                // Metadata that applies only to this sense
                if !sense.metadataIsEmpty {
                    let tags = (sense.misc + sense.field + sense.dialect).joined(separator: ", ")
                    Group {
                        if !tags.isEmpty {
                            Text(tags).italic()
                        }
                        ForEach(sense.info, id: \.self) { note in
                            Text(note).italic()
                        }
                        if !sense.related.isEmpty {
                            Text("Related: \(SenseExtra.formatXrefs(sense.related))")
                        }
                        if !sense.antonym.isEmpty {
                            Text("Antonym: \(SenseExtra.formatXrefs(sense.antonym))")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .opacity(useLabel && !corpusSenseIndices.contains(index) ? 0.4 : 1.0)
        }

        if useLabel {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Senses found in corpus")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                }
                senseList
            }
        } else {
            senseList
        }
    }
}
