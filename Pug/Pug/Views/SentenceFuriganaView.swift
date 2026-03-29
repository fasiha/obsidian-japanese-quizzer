// SentenceFuriganaView.swift
// Renders a Japanese sentence with furigana (ruby text) above words identified
// by the vocab-assumed pass. Reuses FuriganaSegment from VocabSync.swift.
//
// Each annotated word (from VocabGloss.reading) becomes a non-breaking unit
// with the kana reading shown above it. Plain text between annotated words is
// tokenized by NLTagger so the flow layout only breaks between words, not mid-word.
// Kinsoku (行頭禁則) rules prevent sentence-ending punctuation like 。 from starting a line.

import AVFoundation
import NaturalLanguage
import SwiftUI

// MARK: - Plain-text word tokenization

/// Splits a plain (non-annotated) span into `FuriganaSegment` runs using `NLTagger`.
/// Each token (word or punctuation) becomes one segment, which the flow layout treats
/// as a non-breakable unit. This prevents the layout from splitting mid-word — e.g.
/// `ください` stays together instead of wrapping as `くださ / い`.
///
/// Any span not covered by a tagger token (rare) is emitted character-by-character
/// as a fallback so no text is lost.
private func plainSegments(for text: String) -> [FuriganaSegment] {
    guard !text.isEmpty else { return [] }
    var segments: [FuriganaSegment] = []
    let tagger = NLTagger(tagSchemes: [.tokenType])
    tagger.string = text
    var pos = text.startIndex
    tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .tokenType) { _, range in
        // Fill any gap before this token (e.g. whitespace NLTagger skips) char-by-char.
        if range.lowerBound > pos {
            for ch in text[pos..<range.lowerBound] {
                segments.append(FuriganaSegment(ruby: String(ch), rt: nil))
            }
        }
        segments.append(FuriganaSegment(ruby: String(text[range]), rt: nil))
        pos = range.upperBound
        return true
    }
    // Emit any trailing text not covered by the tagger.
    if pos < text.endIndex {
        for ch in text[pos...] {
            segments.append(FuriganaSegment(ruby: String(ch), rt: nil))
        }
    }
    return segments
}

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

    // Build FuriganaSegment array. Plain text between annotations is tokenized into
    // words by NLTagger so the flow layout only breaks between words, not mid-word.
    var segments: [FuriganaSegment] = []
    var pos = sentence.startIndex
    for (range, segs) in allAnnotations {
        segments.append(contentsOf: plainSegments(for: String(sentence[pos..<range.lowerBound])))
        segments.append(contentsOf: segs)
        pos = range.upperBound
    }
    segments.append(contentsOf: plainSegments(for: String(sentence[pos...])))

    return segments.isEmpty ? plainSegments(for: sentence) : segments
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

// MARK: - HTML ruby parser

/// Parses a string containing HTML `<ruby>…<rt>…</rt></ruby>` tags into `FuriganaSegment` runs.
///
/// - `<ruby>BASE<rt>READING</rt></ruby>` → one segment per character in BASE, with `rt` on
///   the first character and `nil` on the rest (so the flow layout groups them naturally).
///   Actually, the entire base is emitted as a single segment with the full `rt`, matching
///   how `WrittenFormGroup` furigana is stored.
/// - Text outside any `<ruby>` block is split character-by-character (so the flow layout
///   can break between any two characters).
/// - Unknown or malformed tags are treated as plain text.
func furiganaSegmentsFromHTMLRuby(_ html: String) -> [FuriganaSegment] {
    var segments: [FuriganaSegment] = []
    var remaining = html[...]

    while !remaining.isEmpty {
        if let rubyStart = remaining.range(of: "<ruby>", options: .caseInsensitive) {
            // Emit plain text before this <ruby> tag as NLTagger word tokens.
            segments.append(contentsOf: plainSegments(for: String(remaining[..<rubyStart.lowerBound])))
            remaining = remaining[rubyStart.upperBound...]

            // Find the matching </ruby>.
            guard let rubyEnd = remaining.range(of: "</ruby>", options: .caseInsensitive) else {
                // Malformed — treat the rest as plain text.
                segments.append(contentsOf: plainSegments(for: String(remaining)))
                return segments
            }
            let rubyContent = remaining[..<rubyEnd.lowerBound]
            remaining = remaining[rubyEnd.upperBound...]

            // Split on <rt>…</rt> inside the ruby block.
            if let rtStart = rubyContent.range(of: "<rt>", options: .caseInsensitive),
               let rtEnd   = rubyContent.range(of: "</rt>", options: .caseInsensitive),
               rtStart.upperBound <= rtEnd.lowerBound {
                let base    = String(rubyContent[..<rtStart.lowerBound])
                let reading = String(rubyContent[rtStart.upperBound..<rtEnd.lowerBound])
                if !base.isEmpty {
                    segments.append(FuriganaSegment(ruby: base, rt: reading.isEmpty ? nil : reading))
                }
            } else {
                // No <rt> found inside — emit the whole block as plain text.
                segments.append(contentsOf: plainSegments(for: String(rubyContent)))
            }
        } else {
            // No more <ruby> tags — emit the rest as NLTagger word tokens.
            segments.append(contentsOf: plainSegments(for: String(remaining)))
            break
        }
    }

    return segments
}

// MARK: - View

/// Renders a Japanese sentence with furigana above annotated words.
/// Annotations come from the vocab-assumed pass (`[VocabGloss]`), or from inline
/// HTML `<ruby>…<rt>…</rt></ruby>` tags in corpus context strings.
/// Falls back gracefully to plain body text when no glosses are provided.
struct SentenceFuriganaView: View {
    let sentence: String
    let segments: [FuriganaSegment]
    var trailingAlignment: Bool = false

    let textStyle: Font.TextStyle

    /// Initialise from a plain sentence and a list of vocab glosses (grammar quiz / assumed-vocab path).
    init(sentence: String, glosses: [VocabGloss], textStyle: Font.TextStyle = .body) {
        self.sentence = sentence
        self.segments = sentenceFuriganaSegments(sentence: sentence, glosses: glosses)
        self.textStyle = textStyle
    }

    /// Initialise from a corpus context string that may contain HTML `<ruby>` tags.
    /// The plain-text sentence (tags stripped) is derived automatically.
    init(htmlRuby: String, trailingAlignment: Bool = false, textStyle: Font.TextStyle = .body) {
        self.segments = furiganaSegmentsFromHTMLRuby(htmlRuby)
        self.sentence = segments.map(\.ruby).joined()
        self.trailingAlignment = trailingAlignment
        self.textStyle = textStyle
    }

    /// Initialise directly from pre-computed furigana segments (e.g. from writtenForms or
    /// from the jmdict.sqlite furigana table). The plain-text sentence is derived automatically.
    init(segments: [FuriganaSegment], textStyle: Font.TextStyle = .body) {
        self.segments = segments
        self.sentence = segments.map(\.ruby).joined()
        self.trailingAlignment = false
        self.textStyle = textStyle
    }

    // Must be held as a persistent property; a synthesizer created inside a closure
    // is deallocated before it finishes speaking.
    @State private var synthesizer = AVSpeechSynthesizer()

    var body: some View {
        SentenceFuriganaFlow(segments: segments, trailingAlignment: trailingAlignment, textStyle: textStyle)
            .contextMenu {
                Button {
                    UIPasteboard.general.string = sentence
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                Button {
                    let utterance = AVSpeechUtterance(string: sentence)
                    utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
                    synthesizer.speak(utterance)
                } label: {
                    Label("Speak", systemImage: "speaker.wave.2")
                }
            }
    }
}

// MARK: - Flow layout

/// Characters that must not appear at the start of a line (Japanese 行頭禁則).
/// When the flow layout would wrap here, the character is pulled onto the previous row instead.
private let lineStartForbidden: Set<Character> = [
    "。", "、", "！", "？", "…", "・",       // sentence-ending and ellipsis
    "）", "」", "』", "】", "〉", "》", "〕", // closing brackets
    "ー",                                   // prolonged-sound mark
    "っ", "ッ",                             // small tsu (can't sensibly open a line)
    "ぁ", "ぃ", "ぅ", "ぇ", "ぉ",           // small hiragana vowels
    "ァ", "ィ", "ゥ", "ェ", "ォ",           // small katakana vowels
    "ゃ", "ゅ", "ょ", "ャ", "ュ", "ョ",     // small ya/yu/yo
    "ゎ", "ヮ",                             // small wa
]

/// Returns true if a segment's first (and only) character is forbidden at the start of a line.
private func isForbiddenAtLineStart(_ seg: FuriganaSegment) -> Bool {
    seg.rt == nil && seg.ruby.count == 1 && seg.ruby.first.map { lineStartForbidden.contains($0) } == true
}

/// A flow (wrapping) layout for furigana segments. Annotated words (with `rt`) are
/// taller than plain characters; all items in a row are bottom-aligned so baselines match.
private struct SentenceFuriganaFlow: View {
    let segments: [FuriganaSegment]
    var trailingAlignment: Bool = false
    var textStyle: Font.TextStyle = .body

    // Furigana reading is shown at roughly 60% of the base text size.
    // ScaledMetric ties the furigana size to the same Dynamic Type axis as the base font.
    @ScaledMetric private var furiganaSize: CGFloat = 10

    private var scaledFuriganaSize: CGFloat {
        // body baseline is 10pt furigana; scale proportionally for other text styles.
        switch textStyle {
        case .title:  return furiganaSize * 1.8
        case .title2: return furiganaSize * 1.5
        case .title3: return furiganaSize * 1.2
        default:      return furiganaSize
        }
    }

    // Parallel array: true means the flow layout may break before this segment.
    // Kinsoku characters (。、） etc.) are marked false so they stay on the previous line.
    private var canBreakBefore: [Bool] {
        segments.map { !isForbiddenAtLineStart($0) }
    }

    var body: some View {
        SentenceFuriganaLayout(trailingAlignment: trailingAlignment, canBreakBefore: canBreakBefore) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                if let rt = seg.rt {
                    VStack(spacing: 0) {
                        Text(rt)
                            .font(.system(size: scaledFuriganaSize))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(seg.ruby)
                            .font(.system(textStyle))
                    }
                    .fixedSize()
                } else {
                    Text(seg.ruby)
                        .font(.system(textStyle))
                        .fixedSize()
                }
            }
        }
    }
}

private struct SentenceFuriganaLayout: Layout {
    let spacing: CGFloat = 0
    var trailingAlignment: Bool = false
    /// Parallel to subviews: false means this subview may not start a new line (kinsoku).
    var canBreakBefore: [Bool] = []

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
            // For trailing alignment, start each row flush with the right edge.
            let startX = trailingAlignment ? bounds.maxX - row.width : bounds.minX
            var x = startX
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
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let breakAllowed = index < canBreakBefore.count ? canBreakBefore[index] : true
            if current.subviews.isEmpty {
                current.subviews.append(subview)
                current.width = size.width
                current.height = size.height
            } else if current.width + spacing + size.width <= maxWidth {
                current.subviews.append(subview)
                current.width += spacing + size.width
                current.height = max(current.height, size.height)
            } else {
                // Before starting a new row, check the kinsoku flag (行頭禁則).
                // If this character must not start a line, pull it onto the current row
                // even if it overflows slightly — an orphaned 。 looks far worse.
                if !breakAllowed {
                    current.subviews.append(subview)
                    current.width += spacing + size.width
                    current.height = max(current.height, size.height)
                } else {
                    rows.append(current)
                    current = Row(subviews: [subview], width: size.width, height: size.height)
                }
            }
        }
        if !current.subviews.isEmpty { rows.append(current) }
        return rows
    }
}
