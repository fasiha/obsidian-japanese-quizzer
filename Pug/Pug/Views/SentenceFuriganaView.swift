// SentenceFuriganaView.swift
// Renders a Japanese sentence with furigana (ruby text) above words identified
// by the vocab-assumed pass. Reuses FuriganaSegment from VocabSync.swift.
//
// Each annotated word (from VocabGloss.reading) becomes a non-breaking unit
// with the kana reading shown above it. Plain text between annotated words is
// split into individual characters so the flow layout can break anywhere.

import SwiftUI

// MARK: - Segmentation

/// Splits `sentence` into `FuriganaSegment` runs using `glosses` for annotations.
///
/// **Step 1 — exact word match**: Each gloss's `rubySegments` is spliced in wherever
/// the full dictionary-form word appears verbatim in the sentence. This handles words
/// that were not conjugated (or whose conjugated form happens to match the dictionary form).
///
/// **Step 2 — single-kanji fallback**: After Step 1, any kanji character that is still
/// unannotated and appears exactly once in the sentence can be annotated safely. We build
/// a map from each individual kanji to its reading(s) extracted from the glosses' ruby
/// segments. A kanji is only annotated when there is exactly one occurrence in the sentence
/// AND all glosses that contain it agree on a single reading.
///
/// - Words with no `rubySegments`, or whose segments have no `rt` annotations, are skipped.
/// - Words not found verbatim in the sentence are silently skipped (Step 1).
/// - Overlapping annotations are resolved: first found wins.
func sentenceFuriganaSegments(sentence: String, glosses: [VocabGloss]) -> [FuriganaSegment] {
    // Step 1: Collect (range, segments) pairs for annotatable words via exact match.
    var annotations: [(range: Range<String.Index>, segs: [FuriganaSegment])] = []
    for gloss in glosses {
        guard let segs = gloss.rubySegments,
              segs.contains(where: { $0.rt != nil }) else { continue }
        var searchRange = sentence.startIndex..<sentence.endIndex
        while let found = sentence.range(of: gloss.word, range: searchRange) {
            let overlaps = annotations.contains { $0.range.overlaps(found) }
            if !overlaps { annotations.append((found, segs)) }
            searchRange = found.upperBound..<sentence.endIndex
        }
    }
    annotations.sort { $0.range.lowerBound < $1.range.lowerBound }

    // Step 2: For kanji still unannotated after Step 1, build a map from each individual
    // kanji character to its reading, then annotate characters that appear exactly once
    // in the sentence and have an unambiguous reading from the glosses.
    let annotatedRanges = annotations.map(\.range)
    let singleKanjiAnnotations = singleKanjiFurigana(sentence: sentence, glosses: glosses,
                                                      alreadyAnnotated: annotatedRanges)
    let allAnnotations = (annotations + singleKanjiAnnotations)
        .sorted { $0.range.lowerBound < $1.range.lowerBound }

    // Build FuriganaSegment array. Plain text between annotations is emitted
    // character by character so the flow layout can break between any two characters.
    var segments: [FuriganaSegment] = []
    var pos = sentence.startIndex
    for (range, segs) in allAnnotations {
        for ch in sentence[pos..<range.lowerBound] {
            segments.append(FuriganaSegment(ruby: String(ch), rt: nil))
        }
        segments.append(contentsOf: segs)
        pos = range.upperBound
    }
    for ch in sentence[pos...] {
        segments.append(FuriganaSegment(ruby: String(ch), rt: nil))
    }

    return segments.isEmpty ? sentence.map { FuriganaSegment(ruby: String($0), rt: nil) } : segments
}

/// Returns whether a Unicode scalar is a CJK kanji character.
private func isKanji(_ scalar: Unicode.Scalar) -> Bool {
    // CJK Unified Ideographs (the vast majority of kanji used in Japanese)
    (0x4E00...0x9FFF).contains(scalar.value) ||
    // CJK Extension A
    (0x3400...0x4DBF).contains(scalar.value) ||
    // CJK Compatibility Ideographs
    (0xF900...0xFAFF).contains(scalar.value)
}

/// Step 2 helper: builds single-character kanji annotations for positions not already covered.
///
/// For each kanji in each gloss's `rubySegments`, records what reading that gloss assigns to it.
/// A kanji is safe to annotate when:
/// 1. All glosses that contain it agree on the same reading.
/// 2. It appears exactly once in the sentence (so we know which occurrence to annotate).
/// 3. That occurrence is not already covered by a Step 1 annotation.
private func singleKanjiFurigana(
    sentence: String,
    glosses: [VocabGloss],
    alreadyAnnotated: [Range<String.Index>]
) -> [(range: Range<String.Index>, segs: [FuriganaSegment])] {
    // Build map: kanji character → set of readings (from all glosses that contain it).
    // A reading is the `rt` value on the segment whose `ruby` is exactly that kanji.
    var kanjiReadings: [Character: Set<String>] = [:]
    for gloss in glosses {
        guard let segs = gloss.rubySegments else { continue }
        for seg in segs {
            guard let rt = seg.rt, seg.ruby.unicodeScalars.count == 1,
                  let scalar = seg.ruby.unicodeScalars.first, isKanji(scalar) else { continue }
            let ch = seg.ruby.first!
            kanjiReadings[ch, default: []].insert(rt)
        }
    }

    var result: [(range: Range<String.Index>, segs: [FuriganaSegment])] = []
    for (kanji, readings) in kanjiReadings {
        // Ambiguous reading across glosses — skip.
        guard readings.count == 1, let reading = readings.first else { continue }
        let kanjiStr = String(kanji)

        // Find all occurrences of this kanji in the sentence.
        var occurrences: [Range<String.Index>] = []
        var search = sentence.startIndex..<sentence.endIndex
        while let found = sentence.range(of: kanjiStr, range: search) {
            occurrences.append(found)
            search = found.upperBound..<sentence.endIndex
        }

        // Only annotate if there is exactly one occurrence and it is not already covered.
        guard occurrences.count == 1, let occurrence = occurrences.first else { continue }
        let alreadyCovered = alreadyAnnotated.contains { $0.overlaps(occurrence) }
            || result.contains { $0.range.overlaps(occurrence) }
        guard !alreadyCovered else { continue }

        result.append((range: occurrence, segs: [FuriganaSegment(ruby: kanjiStr, rt: reading)]))
    }
    return result
}

// MARK: - View

/// Renders a Japanese sentence with furigana above annotated words.
/// Annotations come from the vocab-assumed pass (`[VocabGloss]`).
/// Falls back gracefully to plain body text when no glosses are provided.
struct SentenceFuriganaView: View {
    let sentence: String
    let segments: [FuriganaSegment]

    init(sentence: String, glosses: [VocabGloss]) {
        self.sentence = sentence
        self.segments = sentenceFuriganaSegments(sentence: sentence, glosses: glosses)
    }

    var body: some View {
        SentenceFuriganaFlow(segments: segments)
            .contextMenu {
                Button {
                    UIPasteboard.general.string = sentence
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
    }
}

// MARK: - Flow layout

/// A flow (wrapping) layout for furigana segments. Annotated words (with `rt`) are
/// taller than plain characters; all items in a row are bottom-aligned so baselines match.
private struct SentenceFuriganaFlow: View {
    let segments: [FuriganaSegment]

    var body: some View {
        SentenceFuriganaLayout {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                if let rt = seg.rt {
                    VStack(spacing: 0) {
                        Text(rt)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(seg.ruby)
                            .font(.body)
                    }
                    .fixedSize()
                } else {
                    Text(seg.ruby)
                        .font(.body)
                        .fixedSize()
                }
            }
        }
    }
}

private struct SentenceFuriganaLayout: Layout {
    let spacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(
            width: proposal.width ?? rows.map(\.width).max() ?? 0,
            height: rows.map(\.height).reduce(0, +)
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for subview in row.subviews {
                let size = subview.sizeThatFits(.unspecified)
                // Bottom-align within the row so baselines match across annotated and plain items.
                subview.place(
                    at: CGPoint(x: x, y: y + row.height - size.height),
                    proposal: .unspecified
                )
                x += size.width + spacing
            }
            y += row.height
        }
    }

    private struct Row {
        var subviews: [LayoutSubview] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if current.subviews.isEmpty {
                current.subviews.append(subview)
                current.width = size.width
                current.height = size.height
            } else if current.width + spacing + size.width <= maxWidth {
                current.subviews.append(subview)
                current.width += spacing + size.width
                current.height = max(current.height, size.height)
            } else {
                rows.append(current)
                current = Row(subviews: [subview], width: size.width, height: size.height)
            }
        }
        if !current.subviews.isEmpty { rows.append(current) }
        return rows
    }
}
