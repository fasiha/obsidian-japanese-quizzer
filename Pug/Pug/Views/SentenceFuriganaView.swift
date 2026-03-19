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
/// Each gloss's `rubySegments` (parsed from Haiku's `ruby_html`) is spliced in wherever
/// the word appears verbatim in the sentence. This correctly handles okurigana and
/// middle-kana (e.g. 食べ物) because the ruby HTML annotates only the kanji characters.
///
/// - Words with no `rubySegments`, or whose segments have no `rt` annotations, are skipped.
/// - Words not found verbatim in the sentence are silently skipped.
/// - Overlapping annotations are resolved: first found wins.
func sentenceFuriganaSegments(sentence: String, glosses: [VocabGloss]) -> [FuriganaSegment] {
    // Collect (range, segments) pairs for annotatable words.
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

    // Build FuriganaSegment array. Plain text between annotations is emitted
    // character by character so the flow layout can break between any two characters.
    var segments: [FuriganaSegment] = []
    var pos = sentence.startIndex
    for (range, segs) in annotations {
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

// MARK: - View

/// Renders a Japanese sentence with furigana above annotated words.
/// Annotations come from the vocab-assumed pass (`[VocabGloss]`).
/// Falls back gracefully to plain body text when no glosses are provided.
struct SentenceFuriganaView: View {
    let segments: [FuriganaSegment]

    init(sentence: String, glosses: [VocabGloss]) {
        self.segments = sentenceFuriganaSegments(sentence: sentence, glosses: glosses)
    }

    var body: some View {
        SentenceFuriganaFlow(segments: segments)
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
