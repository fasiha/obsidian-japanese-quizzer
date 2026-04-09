// JMDictSenseListView.swift
// Shared view for rendering JMDict sense data (glosses, part-of-speech, metadata).
// Used by both WordDetailSheet and TransitivePairDetailSheet to keep dictionary
// display consistent across the app.
//
// Two-layer sense highlighting:
//   originSenseIndices    — senses attested in the document/line the student navigated from
//   committedSenseIndices — senses the student has enrolled for quizzing (nil = all senses)
//
// When onToggleSense is provided (word is committed), each sense row shows a checkbox
// and is tappable. When nil, the view is read-only and shows no checkboxes.

import SwiftUI

/// Renders a list of JMDict senses with glosses, part-of-speech, metadata tags,
/// cross-references, and two-layer sense enrollment indicators.
struct JMDictSenseListView: View {
    let senseExtras: [SenseExtra]
    /// Senses attested in the navigation origin (current document or specific line).
    /// These are shown at full brightness even when not yet committed.
    var originSenseIndices: [Int] = []
    /// Senses the student has explicitly enrolled for quizzing.
    /// nil = legacy "all senses" state — show all as enrolled.
    /// Non-nil = only the listed indices are enrolled.
    var committedSenseIndices: [Int]? = nil
    /// All written (kanji/mixed) forms for the word. Used to expand ["*"] in appliesToKanji
    /// to the full form list so the user can see which spellings each sense covers.
    var writtenTexts: [String] = []
    /// All kana readings for the word. Used to expand ["*"] in appliesToKana annotations.
    /// Only shown when there is more than one kana reading (single-kana words are unambiguous).
    var kanaTexts: [String] = []
    /// When non-nil, sense rows are tappable and this closure is called with the tapped index.
    var onToggleSense: ((Int) -> Void)? = nil

    var body: some View {
        // Part of speech is shared across senses (JMDict convention: repeated on each sense,
        // but effectively describes the word). Deduplicate and show once at the top.
        let allPos = Array(NSOrderedSet(array: senseExtras.flatMap(\.partOfSpeech))) as? [String] ?? []
        if !allPos.isEmpty {
            Text(allPos.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        let isInteractive = onToggleSense != nil

        let senseList = ForEach(Array(senseExtras.enumerated()), id: \.offset) { index, sense in
            if index > 0 { Divider() }

            let isCommitted: Bool = {
                if let committed = committedSenseIndices {
                    return committed.contains(index)
                }
                return true  // nil = all senses enrolled
            }()
            let isInOrigin = originSenseIndices.contains(index)

            // Opacity: bright if this sense appears in the navigation origin (the document
            // or line the student came from), dim otherwise. The checkbox independently
            // shows enrollment state, so opacity and enrollment are orthogonal signals.
            let opacity: Double = (originSenseIndices.isEmpty || isInOrigin) ? 1.0 : 0.4

            HStack(alignment: .top, spacing: 8) {
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
                            .foregroundStyle(.secondary)
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
                .opacity(opacity)

                if isInteractive {
                    Spacer()
                    // Checkbox icon: filled = committed, ring = not committed
                    Image(systemName: isCommitted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isCommitted ? Color.accentColor : Color.secondary)
                        .font(.body)
                        .padding(.top, 2)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if let toggle = onToggleSense {
                    toggle(index)
                }
            }
        }

        // Show section header only when there is meaningful highlighting to explain.
        let hasOrigin = !originSenseIndices.isEmpty
        let hasCommitted = committedSenseIndices != nil

        if hasOrigin || hasCommitted {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(isInteractive ? "Senses" : "Senses found in corpus")
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
