// WordCommitment+CommittedForms.swift
// Helpers for extracting the committed written form and kana reading from the
// furigana JSON stored in word_commitment.furigana.
//
// The furigana field is a JSON array of segment objects, each with:
//   "ruby": the surface character(s) — kanji, kana, or mixed
//   "rt":   the reading (kana), present only on kanji segments
//
// Example — 焚き木 (たきぎ):
//   [{"ruby":"焚","rt":"た"}, {"ruby":"き"}, {"ruby":"木","rt":"ぎ"}]
//   committedWrittenText → "焚き木"
//   committedReading     → "たきぎ"

import Foundation

extension WordCommitment {
    /// Decodes the furigana segments, returning nil if the JSON is malformed or empty.
    /// Internal use only — callers should prefer committedWrittenText / committedReading.
    /// Exposed as `internal` (not private) so QuizContext can reuse it for the partial-kanji
    /// template loop, which needs access to both "ruby" and "rt" on each segment.
    var furiganaSegmentsForTemplate: [[String: String]]? {
        guard let data = furigana.data(using: .utf8),
              let segments = try? JSONDecoder().decode([[String: String]].self, from: data),
              !segments.isEmpty
        else { return nil }
        return segments
    }

    /// The written surface form of the committed word (ruby fields joined).
    /// Returns nil if the furigana cannot be decoded.
    /// Example: 焚き木
    var committedWrittenText: String? {
        guard let segments = furiganaSegmentsForTemplate else { return nil }
        let text = segments.map { $0["ruby"] ?? "" }.joined()
        return text.isEmpty ? nil : text
    }

    /// The full kana reading of the committed word (rt ?? ruby for every segment, joined).
    /// Returns nil if the furigana cannot be decoded.
    /// Example: たきぎ
    var committedReading: String? {
        guard let segments = furiganaSegmentsForTemplate else { return nil }
        let reading = segments.map { ($0["rt"] ?? $0["ruby"]) ?? "" }.joined()
        return reading.isEmpty ? nil : reading
    }
}
