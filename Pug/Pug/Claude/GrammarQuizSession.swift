// GrammarQuizSession.swift
// Manages the two-turn Claude conversation for a single grammar quiz item.
// Phase 1A: tier-1 multiple choice only (both production and recognition facets).
// Phase 1B will add fill-in-the-blank (tier 2) and free-text (tier 3).
//
// Grammar quizzes always require at least one LLM call for question generation —
// unlike vocab where stems can be built locally. Claude generates the English context
// (production) or Japanese sentence (recognition) plus 4 choices.
//
// No tools are used by grammar quizzes (no JMDict, no Kanjidic lookup needed).

import Foundation
import GRDB

// MARK: - Multiple choice question

/// Token used to mark the grammar gap when displaying fill-in-the-blank questions to the student.
let grammarGapToken = "____"

/// A grammar multiple-choice question returned by Claude.
///
/// For **production** (English → Japanese) tiers 1 and 2, `sentence` is the full, complete
/// Japanese sentence. Each choice is an array of strings — one element per grammar slot.
/// For tier 1 there are 4 choices (multiple choice); for tier 2 there is 1 choice containing
/// the correct answer substring(s). For multi-slot grammar like 〜し、〜し the sub-array has
/// 2 elements; single-slot grammar has 1 element.
///
/// For **recognition** (Japanese → English) tier 1, Claude generates full English
/// translation choices and `sentence` is nil. Each choice is still a 1-element array
/// containing the English string.
struct GrammarMultipleChoiceQuestion: Equatable, Sendable {
    let stem: String        // English context (production) or Japanese sentence (recognition)
    let sentence: String?   // Full Japanese sentence (production only; nil for recognition)
    var choices: [[String]] // 4 options for multiple choice, 1 option for fill-in-the-blank; each sub-array has one element per grammar slot
    let correctIndex: Int   // 0–3 for multiple choice, always 0 for fill-in-the-blank
    /// The specific sub-use or construction targeted by this question (from the "sub_use" JSON field).
    /// Stored in reviews.notes after the student answers, so future generation can vary sub-uses.
    let subUse: String?
    /// Pre-resolved gapped sentence, populated after disambiguation when an answer substring
    /// appears more than once in the sentence. Nil until resolved.
    var resolvedGappedSentence: String? = nil

    /// Number of grammar slots this question exercises (derived from the first choice).
    var gapCount: Int { choices.first?.count ?? 1 }

    /// Flat display string for a choice (joins elements with ", " for multi-slot).
    func choiceDisplay(_ index: Int) -> String {
        choices[index].joined(separator: ", ")
    }

    /// Extracts the longest common prefix and suffix shared by all four choices,
    /// returning `(prefix, suffix, cores)` where each core is the unique middle of that choice.
    ///
    /// Falls back to `(prefix: "", suffix: "", cores: all choices as-is)` when the shared
    /// prefix and suffix together are shorter than `minimumSharedLength` characters — in
    /// that case the cloze template header would add noise without saving space.
    func choiceClozeTemplate(minimumSharedLength: Int = 4) -> (prefix: String, suffix: String, cores: [String]) {
        let flat = choices.map { $0.joined(separator: ", ") }
        guard flat.count >= 2 else {
            return ("", "", flat)
        }

        // Build common prefix character by character across all choices.
        var prefixEnd = flat[0].startIndex
        outer: while prefixEnd < flat[0].endIndex {
            let next = flat[0].index(after: prefixEnd)
            let slice = flat[0][flat[0].startIndex..<next]
            for other in flat.dropFirst() {
                guard other.hasPrefix(slice) else { break outer }
            }
            prefixEnd = next
        }
        let commonPrefix = String(flat[0][flat[0].startIndex..<prefixEnd])

        // Build common suffix on the reversed strings, then reverse it back.
        let reversedFlat = flat.map { String($0.reversed()) }
        var suffixEnd = reversedFlat[0].startIndex
        outerSuffix: while suffixEnd < reversedFlat[0].endIndex {
            let next = reversedFlat[0].index(after: suffixEnd)
            let slice = reversedFlat[0][reversedFlat[0].startIndex..<next]
            for other in reversedFlat.dropFirst() {
                guard other.hasPrefix(slice) else { break outerSuffix }
            }
            // Make sure suffix does not overlap with the already-consumed prefix.
            let consumed = commonPrefix.count + next.utf16Offset(in: reversedFlat[0])
            if consumed > flat[0].count { break outerSuffix }
            suffixEnd = next
        }
        let commonSuffix = String(String(reversedFlat[0][reversedFlat[0].startIndex..<suffixEnd]).reversed())

        // Require a meaningful shared frame before showing the cloze header.
        guard commonPrefix.count + commonSuffix.count >= minimumSharedLength else {
            return ("", "", flat)
        }

        let cores = flat.map { choice -> String in
            var s = choice
            if !commonSuffix.isEmpty, let r = s.range(of: commonSuffix, options: .backwards) {
                s = String(s[s.startIndex..<r.lowerBound])
            }
            if !commonPrefix.isEmpty, let r = s.range(of: commonPrefix) {
                s = String(s[r.upperBound...])
            }
            return s
        }
        return (commonPrefix, commonSuffix, cores)
    }

    /// Naive gapping: replaces the first occurrence of each answer substring with `___`.
    /// Use `displayGappedSentence` instead, which prefers the disambiguated result.
    var gappedSentence: String? {
        guard let s = sentence else { return nil }
        guard correctIndex < choices.count else { return s }
        var result = s
        for fill in choices[correctIndex] {
            if let range = result.range(of: fill) {
                result = result.replacingCharacters(in: range, with: grammarGapToken)
            }
        }
        return result
    }

    /// The gapped sentence to show the student. Prefers the Haiku-disambiguated result
    /// if available, otherwise falls back to naive first-occurrence gapping.
    var displayGappedSentence: String? {
        resolvedGappedSentence ?? gappedSentence
    }

    /// Returns the full sentence with the given choice substituted in — for tier 1 this is
    /// always just `sentence` (choices are whole sentences), and is unused. Returns nil if
    /// `sentence` is nil.
    func filledSentence(choiceIndex: Int) -> String? {
        return sentence
    }

    /// True if any answer substring appears in the sentence more times than it is needed
    /// as a grammar slot, meaning naive gapping could gap the wrong occurrence.
    ///
    /// Example: answers ["し", "し"] with a sentence containing exactly two "し" is NOT
    /// ambiguous — we gap both. But answers ["の"] with a sentence containing two "の" IS
    /// ambiguous — we don't know which one is the grammar slot.
    var needsDisambiguation: Bool { grammarNeedsDisambiguation(self) }
}

/// Free function so `nonisolated` contexts can check disambiguation without touching the
/// main-actor-isolated struct property directly (required by SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor).
nonisolated func grammarNeedsDisambiguation(_ question: GrammarMultipleChoiceQuestion) -> Bool {
    guard let s = question.sentence, question.correctIndex < question.choices.count else { return false }
    let answers = question.choices[question.correctIndex]
    var neededCounts: [String: Int] = [:]
    for fill in answers { neededCounts[fill, default: 0] += 1 }
    for (fill, needed) in neededCounts {
        var sentenceCount = 0
        var searchRange = s.startIndex..<s.endIndex
        while let range = s.range(of: fill, range: searchRange) {
            sentenceCount += 1
            if sentenceCount > needed { return true }
            searchRange = range.upperBound..<s.endIndex
        }
    }
    return false
}

// MARK: - Haiku disambiguation for ambiguous gapping

/// Asks the LLM which occurrence of an ambiguous answer substring is the grammar slot.
/// Returns a new `GrammarMultipleChoiceQuestion` with `resolvedGappedSentence` populated.
/// If disambiguation fails or isn't needed, returns the question unchanged.
nonisolated func disambiguateGaps(
    question: GrammarMultipleChoiceQuestion,
    topicId: String,
    client: AnthropicClient
) async -> GrammarMultipleChoiceQuestion {
    guard grammarNeedsDisambiguation(question),
          let sentence = question.sentence,
          question.correctIndex < question.choices.count
    else { return question }

    let gap = "___"   // local copy — avoids reaching the @MainActor-isolated global from nonisolated context
    let answers = question.choices[question.correctIndex]
    var result = sentence

    // Count how many times each unique fill is needed as a grammar slot.
    var neededCounts: [String: Int] = [:]
    for fill in answers { neededCounts[fill, default: 0] += 1 }

    for (fill, needed) in neededCounts {
        // Find all occurrences in the original sentence.
        var ranges: [Range<String.Index>] = []
        var searchRange = sentence.startIndex..<sentence.endIndex
        while let range = sentence.range(of: fill, range: searchRange) {
            ranges.append(range)
            searchRange = range.upperBound..<sentence.endIndex
        }
        guard ranges.count > needed else {
            // Unambiguous — gap the first `needed` occurrences in order.
            var gapped = 0
            var sr = result.startIndex..<result.endIndex
            while gapped < needed, let r = result.range(of: fill, range: sr) {
                result = result.replacingCharacters(in: r, with: gap)
                gapped += 1
                sr = (result.index(r.lowerBound, offsetBy: gap.count))..<result.endIndex
            }
            continue
        }

        // Build a numbered list of occurrences with surrounding context for Haiku.
        var occurrenceDescriptions: [String] = []
        for (i, range) in ranges.enumerated() {
            let charPos = sentence.distance(from: sentence.startIndex, to: range.lowerBound)
            let contextStart = sentence.index(range.lowerBound, offsetBy: -5, limitedBy: sentence.startIndex) ?? sentence.startIndex
            let contextEnd = sentence.index(range.upperBound, offsetBy: 5, limitedBy: sentence.endIndex) ?? sentence.endIndex
            let before = String(sentence[contextStart..<range.lowerBound])
            let after  = String(sentence[range.upperBound..<contextEnd])
            occurrenceDescriptions.append("\(i + 1). \"...\(before)[\(fill)]\(after)...\" (position \(charPos))")
        }

        let slotWord = needed == 1 ? "slot" : "slots"
        let exampleReply = needed == 1 ? "\"2\"" : "\"1,3\""
        let prompt = """
        Japanese sentence: \(sentence)
        Grammar topic: \(topicId)
        The substring "\(fill)" appears \(ranges.count) times in this sentence, but only \(needed) occurrence\(needed == 1 ? "" : "s") \(needed == 1 ? "is" : "are") grammar \(slotWord) for \(topicId).
        \(occurrenceDescriptions.joined(separator: "\n"))
        Reply with ONLY the \(needed == 1 ? "occurrence number" : "\(needed) occurrence numbers as a comma-separated list") (e.g. \(exampleReply)). Nothing else.
        """

        // maxTokens: single-digit number or short comma-separated list fits in ~16 tokens.
        let maxTok = 8 + needed * 4

        do {
            let (response, _, _) = try await client.send(
                messages: [AnthropicMessage(role: "user", content: [.text(prompt)])],
                maxTokens: maxTok
            )
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            // Parse one or more 1-based indices from the response.
            let pickedIndices = trimmed
                .components(separatedBy: CharacterSet(charactersIn: ", "))
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                .filter { $0 >= 1 && $0 <= ranges.count }
            let uniquePicked = Array(Set(pickedIndices)).sorted()

            if uniquePicked.count == needed {
                // Gap the chosen occurrences. Work backwards through `result` by occurrence
                // number so that earlier replacements don't shift later positions.
                // We find the Nth occurrence of `fill` in `result` for each chosen index.
                for occIndex in uniquePicked.sorted(by: >) {
                    var count = 0
                    var sr = result.startIndex..<result.endIndex
                    while let r = result.range(of: fill, range: sr) {
                        count += 1
                        if count == occIndex {
                            result = result.replacingCharacters(in: r, with: gap)
                            break
                        }
                        sr = r.upperBound..<result.endIndex
                    }
                }
                print("[Disambiguation] Haiku picked occurrence\(needed == 1 ? "" : "s") \(uniquePicked) of \"\(fill)\" for topic \(topicId)")
            } else {
                print("[Disambiguation] Haiku returned unparseable response: \(trimmed), falling back to first \(needed) occurrence\(needed == 1 ? "" : "s")")
                var gapped = 0
                var sr = result.startIndex..<result.endIndex
                while gapped < needed, let r = result.range(of: fill, range: sr) {
                    result = result.replacingCharacters(in: r, with: gap)
                    gapped += 1
                    sr = (result.index(r.lowerBound, offsetBy: gap.count))..<result.endIndex
                }
            }
        } catch {
            print("[Disambiguation] Haiku call failed: \(error), falling back to first \(needed) occurrence\(needed == 1 ? "" : "s")")
            var gapped = 0
            var sr = result.startIndex..<result.endIndex
            while gapped < needed, let r = result.range(of: fill, range: sr) {
                result = result.replacingCharacters(in: r, with: gap)
                gapped += 1
                sr = (result.index(r.lowerBound, offsetBy: gap.count))..<result.endIndex
            }
        }
    }

    var resolved = question
    resolved.resolvedGappedSentence = result
    return resolved
}

// MARK: - Answer extraction refinement

/// For tier 2 production fill-in-the-blank questions, asks Haiku to re-extract the
/// shortest exact substrings the student must produce, given the full sentence and grammar
/// topic. This corrects cases where the generation call extracted too large a chunk (e.g.
/// an entire clause instead of just the particle) or an inconsistently sized fragment.
///
/// Returns a new question with the `choices` array replaced if Haiku returns valid substrings
/// that all appear verbatim in the sentence; otherwise returns the question unchanged.
nonisolated func refineAnswerExtraction(
    question: GrammarMultipleChoiceQuestion,
    topicId: String,
    topicDescription: String,
    client: AnthropicClient
) async -> GrammarMultipleChoiceQuestion {
    // Only applies to tier 2 production: exactly one choices entry, sentence is present.
    guard question.choices.count == 1,
          let sentence = question.sentence
    else { return question }

    let prompt = """
    Japanese sentence: \(sentence)
    Grammar topic: \(topicId) — \(topicDescription)

    You are a Japanese teacher writing a worksheet. Identify the exact substring(s) that \
    test the grammar — the part a student must produce to show they've learned this form. \
    Everything else (vocabulary, verb stems, sentence structure) stays visible. \
    The blank should contain the grammar form and nothing more — no surrounding vocabulary \
    that the student could supply without knowing this grammar point. \
    Each substring must appear verbatim in the sentence.
    - Conjugation grammar (potential, causative, たり, etc.): just the inflectional suffix, \
    not the verb stem — e.g. られます not 帰られます, させた not 掃除させた, したり not 買い物したり
    - Fixed expressions (から, し, はず, したがって, etc.): just the grammar word/phrase — \
    e.g. し, から, はずだ
    - Grammatical frames (てはいけない, に堪えない, ようにする, etc.): the full frame pattern \
    but not the content verb it attaches to — e.g. てはいけない not 撮ってはいけない
    For multi-slot grammar, include one entry per slot.
    Reply with ONLY a JSON array of strings — nothing else.
    """

    // Budget: a few short Japanese substrings fit comfortably in 64 tokens.
    let maxTok = 64

    do {
        let (response, _, _) = try await client.send(
            messages: [AnthropicMessage(role: "user", content: [.text(prompt)])],
            maxTokens: maxTok
        )
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)

        // Extract JSON array from response (may be wrapped in a code fence).
        let jsonString: String
        if let fenceStart = trimmed.range(of: "["),
           let fenceEnd   = trimmed.range(of: "]", range: fenceStart.lowerBound..<trimmed.endIndex) {
            jsonString = String(trimmed[fenceStart.lowerBound...fenceEnd.lowerBound])
        } else {
            jsonString = trimmed
        }

        guard let data = jsonString.data(using: .utf8),
              let extracted = try? JSONDecoder().decode([String].self, from: data),
              !extracted.isEmpty
        else {
            print("[ExtractionRefinement] Haiku returned unparseable response for \(topicId): \(trimmed)")
            return question
        }

        // Validate every extracted substring appears verbatim in the sentence.
        for substring in extracted {
            guard sentence.contains(substring) else {
                print("[ExtractionRefinement] Haiku returned substring not in sentence for \(topicId): \"\(substring)\"")
                return question
            }
        }

        print("[ExtractionRefinement] Extracted answers for \(topicId): \(extracted)")
        var refined = question
        refined.choices[0] = extracted
        return refined

    } catch {
        print("[ExtractionRefinement] Haiku call failed for \(topicId): \(error)")
        return question
    }
}

// MARK: - Session

/// Manages a single grammar quiz item's question generation and answer grading.
/// Shared between the iOS app (Phase 1B) and the CLI TestHarness (Phase 1A).
@MainActor
final class GrammarQuizSession {
    let client: AnthropicClient
    let db: QuizDB

    /// Grammar topics the student knows well — included in every system prompt for difficulty scaling.
    /// Populated by the caller from GrammarQuizContext before calling generate.
    var extraGrammarTopics: [GrammarExtraTopic] = []

    /// The most recent multiple-choice result (set by Phase 1B QuizView after student taps).
    /// Included in the post-answer chat system prompt so Claude knows whether they got it right.
    var multipleChoiceResult: String? = nil

    /// JMDict database for vocab resolution. Set by the caller before generating a question.
    /// If nil, vocab glosses fall back entirely to Haiku's inline gloss (no local lookup).
    var jmdict: (any DatabaseReader)? = nil

    /// Fires after a successful multiple-choice generation. Awaiting it returns the resolved
    /// vocabulary list for the "Show vocabulary" button. Nil until the first question is generated.
    var vocabTask: Task<[VocabGloss], Never>? = nil

    init(client: AnthropicClient, db: QuizDB) {
        self.client = client
        self.db     = db
    }

    // MARK: - TestHarness entry points

    /// Generate a multiple-choice question for a grammar topic.
    /// Returns the formatted question string, the parsed multiple-choice struct, and the raw conversation.
    /// Intended for CLI test harness use; bypasses the phase state machine.
    func generateQuestionForTesting(item: GrammarQuizItem)
        async throws -> (question: String, multipleChoice: GrammarMultipleChoiceQuestion?, conversation: [AnthropicMessage])
    {
        let system   = systemPrompt(for: item, isGenerating: true)
        let initMsg  = AnthropicMessage(role: "user", content: [.text(questionRequest(for: item))])
        return try await runGenerationLoop(for: item, system: system, initMsg: initMsg, label: "test")
    }

    /// Grade a free-text answer for a grammar item. Returns Claude's full response.
    /// Used by TestHarness --grade mode and will be called by Phase 1B free-text quiz UI.
    func gradeAnswerForTesting(item: GrammarQuizItem, stem: String, answer: String) async throws -> String {
        let system  = systemPrompt(for: item, isGenerating: false)
        let opening = "Question you asked me: \(stem)\nMy answer: \(answer)\nPlease grade my answer."
        let messages = [AnthropicMessage(role: "user", content: [.text(opening)])]
        let (text, _, _) = try await client.send(
            messages: messages,
            system: system,
            tools: [],
            maxTokens: 512,
            toolHandler: nil
        )
        return text
    }

    // MARK: - System prompt

    /// Build the system prompt for a grammar quiz item.
    ///
    /// - `isGenerating`: true when asking Claude to generate a question; false when Claude is grading
    ///   a free-text answer or discussing a completed multiple-choice question.
    func systemPrompt(for item: GrammarQuizItem, isGenerating: Bool,
                      preRecall: Double? = nil, preHalflife: Double? = nil,
                      postHalflife: Double? = nil, mnemonicBlock: String = "") -> String {
        let ebisuLine: String
        if let r = preRecall, let h = preHalflife {
            if let ph = postHalflife {
                ebisuLine = "recall=\(String(format: "%.2f", r)) halflife=\(String(format: "%.0f", h))h→\(String(format: "%.0f", ph))h"
            } else {
                ebisuLine = "recall=\(String(format: "%.2f", r)) halflife=\(String(format: "%.0f", h))h"
            }
        } else {
            ebisuLine = "new topic"
        }

        let sourceName: String
        switch item.source {
        case "genki":   sourceName = "Genki I & II (textbook)"
        case "bunpro":  sourceName = "Bunpro (online)"
        case "dbjg":    sourceName = "Dictionary of Basic Japanese Grammar"
        default:        sourceName = item.source
        }

        var topicLine = "Target grammar: \(item.topicId) — \(item.titleEn)"
        if let jp = item.titleJp, !jp.isEmpty { topicLine += " (\(jp))" }

        var metaLine = "Level: \(item.level) | Source: \(sourceName)"
        if let href = item.href, !href.isEmpty { metaLine += " | Reference: \(href)" }

        // Build description block from equivalence-group data (may be absent for stub or unsynced topics).
        var descriptionBlock = ""
        if let summary = item.summary {
            var lines = "Description: \(summary)"
            if let subUses = item.subUses, !subUses.isEmpty {
                lines += "\nSub-uses:\n" + subUses.map { "- \($0)" }.joined(separator: "\n")
            }
            if let cautions = item.cautions, !cautions.isEmpty {
                lines += "\nCautions:\n" + cautions.map { "- \($0)" }.joined(separator: "\n")
            }
            descriptionBlock = "\n" + lines
        }

        // Recent sub-uses: injected only in generation calls to guide diversity.
        var recentNotesBlock = ""
        if isGenerating && !item.recentNotes.isEmpty {
            let list = item.recentNotes.map { "- \($0)" }.joined(separator: "\n")
            recentNotesBlock = "\nRecently exercised sub-uses (prefer a different sub-use; if all have been recently exercised, any is fine):\n\(list)"
        }

        // Verb-variety nudge is only relevant for generation calls, not grading.
        let quirkyNote = isGenerating ? "\nVary the verb and setting; 食べる, 飲む, and 泳ぐ are overused." : ""

        // Whether this generation call is for a free-text stem (no choices needed)
        // rather than a multiple-choice question.
        let isFreeTextStemGeneration = isGenerating && (
            (item.facet == "production"  && item.tier >= 3) ||
            (item.facet == "recognition" && item.tier >= 2)
        )

        let facetRule: String
        switch item.facet {
        case "production":
            if isGenerating && !isFreeTextStemGeneration {
                if item.tier == 1 {
                    facetRule = """
                    Facet: production (tier 1) — student sees an English context sentence and \
                    four complete Japanese sentences; they select the one that correctly expresses \
                    the English using the target grammar.
                    The English stem must NOT contain Japanese.
                    The four choices are complete, natural Japanese sentences. Only the correct \
                    choice uses the target grammar; the three distractors use clearly different \
                    grammar constructions (e.g. causative instead of potential, passive instead \
                    of conditional). Distractors must express a DIFFERENT meaning from the \
                    English stem — do NOT use a construction that is a valid alternative way to \
                    express the same meaning.
                    """
                } else {
                    // Tier 2: fill-in-the-blank — student types the grammar form(s) into gap(s).
                    facetRule = """
                    Facet: production (tier 2) — you provide an English context sentence and a \
                    complete, natural Japanese sentence that uses the target grammar. No multiple-choice distractors.
                    The English stem must NOT contain Japanese.
                    """
                }
            } else if isGenerating && isFreeTextStemGeneration {
                facetRule = """
                Facet: production (tier 3, free text) — you will generate a short English \
                sentence or situation for the student to translate into Japanese using the \
                target grammar. No choices or JSON needed — output only the English text.
                The English must NOT contain Japanese.
                """
            } else if item.tier == 3 {
                facetRule = """
                Facet tested: production (tier 3, free text) — student was shown English context \
                and wrote their own Japanese sentence using the target grammar.
                """
            } else {
                // Tier 1 multiple choice discussion or tier 2 fill-in-the-blank discussion.
                facetRule = """
                Facet tested: production (tier \(item.tier)) — student was shown English context \
                and selected/typed a Japanese sentence using the target grammar.
                """
            }
        case "recognition":
            if isGenerating && !isFreeTextStemGeneration {
                facetRule = """
                Facet: recognition (tier \(item.tier)) — student sees a Japanese sentence, \
                selects the correct natural English translation from four choices.
                The Japanese stem must naturally contain the target grammar. It must NOT contain \
                any English.
                All four choices must be natural, idiomatic English sentences — not grammar \
                labels or descriptions. Only the correct choice accurately reflects what the \
                target grammar contributes to the sentence's meaning; the other three are \
                plausible mistranslations a student would produce by confusing the target \
                grammar with a related grammar point.
                """
            } else if isGenerating && isFreeTextStemGeneration {
                facetRule = """
                Facet: recognition (tier 2, free text) — you will generate a single Japanese \
                sentence that naturally uses the target grammar. No choices or JSON needed — \
                output only the Japanese sentence.
                The sentence must NOT contain English.
                """
            } else if item.tier >= 2 {
                facetRule = """
                Facet tested: recognition (tier 2, free text) — student was shown a Japanese \
                sentence and wrote an English translation.
                """
            } else {
                facetRule = """
                Facet tested: recognition (tier 1) — student was shown a Japanese sentence and \
                chose the correct English translation.
                """
            }
        default:
            facetRule = isGenerating
                ? "Facet: \(item.facet) (tier \(item.tier)) — generate an appropriate multiple-choice question."
                : "Facet tested: \(item.facet) (tier \(item.tier))."
        }

        let header = """
        You are quizzing an English-speaking student who is learning Japanese grammar.
        \(topicLine)
        \(metaLine)\(descriptionBlock)
        Memory: \(ebisuLine)
        \(facetRule)\(quirkyNote)\(recentNotesBlock)
        """

        if isGenerating && isFreeTextStemGeneration {
            if item.facet == "production" {
                // For production, the stem is English — make sure it doesn't leak the grammar name.
                return header + "\nWrite a concrete, story-like scenario — something that happened or is happening to a specific person in a specific setting."
            } else {
                // For recognition, the stem is Japanese — no additional instruction needed here.
                return header
            }
        } else if isGenerating {
            return header
        } else if item.facet == "recognition" && item.isFreeAnswer {
            // Recognition tier 2: single-turn LLM grading of the student's English translation.
            return header + """

        Grade the student's English translation of the Japanese sentence.
        SCORE: X.X (0.0–1.0) — emit on the same turn you grade. Format exactly:
          SCORE: X.X — <one grading sentence>
        Never emit SCORE on a line by itself with no other prose.
        Scoring is Bayesian confidence, not percentage-correct:
        - 1.0: translation captures the meaning of the target grammar correctly
        - 0.8–0.9: right idea with a minor nuance missed
        - 0.5: ambiguous — can't tell if they understood the grammar (do NOT use as "half credit")
        - 0.1–0.3: translation misunderstands the target grammar
        - 0.0: completely wrong or off-topic
        On the same turn you emit SCORE, add one brief sentence explaining your reasoning.
        After grading, stop — do not ask follow-up questions. The student will ask if they want to discuss.
        """
        } else if item.facet == "production" && item.isFreeAnswer {
            // Production tier 3: use the dedicated coaching prompt method instead.
            // This branch should not be reached — callers should use
            // tier3ProductionGradingSystemPrompt() for production tier 3 grading.
            // Fallback: return the header with a note.
            return header + "\n(Production tier 3 grading uses the coaching prompt.)"
        } else {
            let resultLine = multipleChoiceResult.map { "Multiple choice result: \($0)\n" } ?? ""
            let mnemonicInstruction = mnemonicBlock.isEmpty ? "" :
                "\n\n\(mnemonicBlock)\nYou have get_mnemonic and set_mnemonic tools;" +
                " use word_type='grammar' and word_id='\(item.topicId)'." +
                " Always call get_mnemonic before set_mnemonic" +
                " so you can see what is already stored and merge new content rather than replacing it wholesale."
            return header + """

        \(resultLine)The student has already answered — scoring is handled by the app. Do NOT emit SCORE.
        The student may ask follow-up questions or move on without chatting. If they ask, engage naturally.\(mnemonicInstruction)
        """
        }
    }

    // MARK: - Sub-use instruction (shared across generation prompts)

    /// Instruction for the `"sub_use"` JSON field in multiple-choice / fill-in-the-blank generation.
    private let subUseJsonInstruction = """
        - "sub_use": 5 words or fewer naming the specific sub-use this question targets \
        (e.g. "godan potential affirmative" or "negative inability"). Prefer a sub-use not \
        already listed under "Recently exercised sub-uses" in the system prompt; if all have \
        been recently exercised, any sub-use is fine.
        """

    /// Instruction for the `SUB_USE:` line in free-text stem generation.
    private let subUseFreeTextInstruction = """
        On the final line, write: SUB_USE: <phrase>
        where <phrase> is 5 words or fewer naming the specific sub-use targeted \
        (e.g. "godan potential affirmative" or "negative inability"). Prefer a sub-use not \
        already listed under "Recently exercised sub-uses" in the system prompt; if all have \
        been recently exercised, any sub-use is fine.
        """

    // MARK: - Question request (user turn for generation)

    /// Build the user message that asks Claude to generate a multiple-choice question.
    func questionRequest(for item: GrammarQuizItem) -> String {
        switch item.facet {
        case "production":
            if item.tier == 1 {
                return """
                Generate ONE multiple-choice question for the production facet (tier 1).
                Work through these steps explicitly — write out each step before the JSON:

                Step 1 — English stem: One or two English sentences that tell a concrete, story-like scenario — something that happened or is happening to a specific person in a specific setting. No Japanese. Vary the verb and setting; 食べる, 飲む, and 泳ぐ are overused.
                Step 2 — Correct sentence: Write one complete, natural Japanese sentence that correctly expresses the English stem using the target grammar.
                Step 3 — Distractors: Write three distractor Japanese sentences. Each must:
                  (a) use the SAME core vocabulary and situation as the correct sentence — keep the subject, object, and setting identical,
                  (b) swap ONLY the grammar construction — use a clearly different grammar form (e.g. causative instead of potential, passive instead of conditional, te-form instead of volitional),
                  (c) NOT use any construction that is a valid alternative way to express the target grammar's meaning (e.g. if target is potential verbs, do NOT use ことができる as a distractor — that is also correct; use causative, passive, plain form, etc.),
                  (d) result in a grammatically valid Japanese sentence that expresses a DIFFERENT meaning from the English stem because it uses the wrong grammar form.
                  Name the grammar form each distractor uses.
                Step 4 — Self-check: (a) Are the four sentences clearly distinguishable by grammar form, not just by particles (が vs を)? (b) Could a student who knows the target grammar but not the distractors' forms reliably pick the correct answer? If not, revise.

                Finally, end with a ```json code block:
                {"stem":"<Step 1>","sentence":"","choices":[["<correct sentence>"],["<distractor 1>"],["<distractor 2>"],["<distractor 3>"]],"correct":<0-3>,"sub_use":"<phrase>"}
                - "sentence" is always empty string for tier 1.
                - Place the correct sentence at a randomly chosen index (0–3) and record it in "correct".
                - Each choice is a 1-element array containing the full Japanese sentence.
                \(subUseJsonInstruction)
                """
            } else {
                return """
                Generate ONE production question for tier 2.
                Work through these steps explicitly — write out each step before the JSON:

                Step 1 — English stem: One or two English sentences that tell a concrete, story-like scenario — something that happened or is happening to a specific person in a specific setting. No Japanese. Vary the verb and setting; 食べる, 飲む, and 泳ぐ are overused.
                Step 2 — Full sentence: Write one complete, natural Japanese sentence using the target grammar.

                Finally, end with a ```json code block:
                {"stem":"<Step 1>","sentence":"<Step 2 full sentence>","choices":[[""]],"correct":0,"sub_use":"<phrase>"}
                - "sentence" is the FULL Japanese sentence from Step 2.
                - "choices" is always [[""]] — answer extraction happens separately.
                - "correct" is always 0.
                \(subUseJsonInstruction)
                """
            }
        case "recognition":
            return """
            Generate ONE multiple-choice question for the recognition facet.
            Work through these steps explicitly — write out each step before the JSON:

            Step 1 — Japanese stem: Write one complete, natural Japanese sentence using the target grammar. No English.
            Step 2 — Correct translation: Write a natural, idiomatic English translation that accurately reflects what the target grammar contributes to the meaning.
            Step 3 — Distractors: Write three alternative English translations. Each must:
              (a) be a natural English sentence a fluent speaker would actually say — NOT a grammar label or description,
              (b) be a plausible mistranslation a student would produce by confusing the target grammar with a specific related grammar point — name the confusion for each (e.g. "confuses causative with passive"),
              (c) NOT be a valid alternative way to translate the stem — if a native speaker could reasonably accept it, revise it.
            Step 4 — Self-check: (a) Does any distractor express a meaning close enough to the correct answer that a student could reasonably argue for it? If yes, revise. (b) Are all four choices clearly different in meaning, not just in nuance?

            Finally, end with a ```json code block:
            {"stem":"<Step 1>","choices":[["<correct translation>"],["<distractor 1>"],["<distractor 2>"],["<distractor 3>"]],"correct":<0-3>,"sub_use":"<phrase>"}
            - "stem": the Japanese sentence from Step 1 — no English.
            - Place the correct translation at a randomly chosen index (0–3) and record it in "correct".
            - Each choice is a 1-element array containing the English translation.
            \(subUseJsonInstruction)
            """
        default:
            return """
            Generate ONE multiple-choice question for the \(item.facet) facet.
            Think first if helpful, then end with a ```json code block containing:
            {"stem":"<question text>","choices":[["<A>"],["<B>"],["<C>"],["<D>"]],"correct":<0-3>}
            Provide four answer choices (each a 1-element array). Only one is correct.
            """
        }
    }

    /// Build the user request message for generating a tier-3 production stem.
    /// Tier 3 production: the LLM provides an English context only (no choices).
    /// The student then writes a full Japanese sentence.
    func tier3ProductionStemRequest(for item: GrammarQuizItem) -> String {
        let grammarTopicsInstruction: String
        if !item.extraGrammarTopics.isEmpty {
            grammarTopicsInstruction = """
            \nAfter the English text, on a new line write GRAMMAR_TOPICS: followed by a \
            JSON array of topic IDs (from the extra grammar topics list in the system prompt) \
            that a correct Japanese translation would syntactically exercise — only include a topic \
            if the Japanese sentence would genuinely use that grammar construction. \
            Use an empty array if none apply: GRAMMAR_TOPICS: []
            """
        } else {
            grammarTopicsInstruction = ""
        }
        return """
        Generate ONE English-language situation or sentence for the student to translate \
        into Japanese using the target grammar.
        The English must NOT contain Japanese.
        Keep it to one or two sentences. Write a concrete, story-like scenario — something that \
        happened or is happening to a specific person in a specific setting.
        Think step by step if helpful, then write --- on its own line, followed by the \
        English text (no labels, no JSON).\(grammarTopicsInstruction)
        \(subUseFreeTextInstruction)
        """
    }

    /// Build the user request message for generating a tier-2 recognition stem.
    /// Tier 2 recognition: the LLM provides a Japanese sentence only (no choices).
    /// The student then writes a free-text English translation.
    func tier2RecognitionStemRequest(for item: GrammarQuizItem) -> String {
        let grammarTopicsInstruction: String
        if !item.extraGrammarTopics.isEmpty {
            grammarTopicsInstruction = """
            \nAfter the Japanese sentence, on a new line write GRAMMAR_TOPICS: followed by a \
            JSON array of topic IDs (from the extra grammar topics list in the system prompt) \
            that the sentence syntactically exercises — only include a topic if the sentence \
            genuinely uses that grammar construction. \
            Use an empty array if none apply: GRAMMAR_TOPICS: []
            """
        } else {
            grammarTopicsInstruction = ""
        }
        return """
        Generate ONE Japanese sentence that naturally uses the target grammar.
        The sentence must NOT contain English.
        Think step by step if helpful, then write --- on its own line, followed by the \
        Japanese sentence (no labels, no furigana annotations).\(grammarTopicsInstruction)
        \(subUseFreeTextInstruction)
        """
    }

    /// Generate a free-text stem for tier-3 production or tier-2 recognition.
    /// Returns the LLM-generated stem string, any grammar topics the LLM identified
    /// in the sentence, and the raw conversation for caching.
    func generateFreeTextStemForTesting(item: GrammarQuizItem)
        async throws -> (stem: String, grammarTopics: [String], subUse: String?, conversation: [AnthropicMessage])
    {
        let system = systemPrompt(for: item, isGenerating: true)
        let request: String
        switch item.facet {
        case "production":  request = tier3ProductionStemRequest(for: item)
        case "recognition": request = tier2RecognitionStemRequest(for: item)
        default:            request = "Generate a question stem for the \(item.facet) facet."
        }
        let initMsg = AnthropicMessage(role: "user", content: [.text(request)])
        let (raw, msgs, meta) = try await client.send(
            messages: [initMsg],
            system: system,
            tools: [],
            maxTokens: 512,
            toolHandler: nil
        )
        try? await db.log(apiEvent: ApiEvent(
            timestamp:            ISO8601DateFormatter().string(from: Date()),
            eventType:            "stem_gen",
            wordId:               item.topicId,
            quizType:             item.facet,
            inputTokens:          meta.totalInputTokens,
            outputTokens:         meta.totalOutputTokens,
            model:                client.model,
            generationAttempt:    1,
            apiTurns:             meta.totalTurns,
            firstTurnInputTokens: meta.firstTurnInputTokens,
            questionChars:        raw.count,
            questionFormat:       "free_text_stem",
            prefetch:             0
        ))
        // Parse: strip reasoning before ---, extract GRAMMAR_TOPICS line if present.
        var content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let dividerRange = content.range(of: "\n---\n") {
            content = String(content[dividerRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if content.hasPrefix("---\n") {
            content = String(content.dropFirst(4))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var grammarTopics: [String] = []
        var subUse: String? = nil
        let lines = content.components(separatedBy: .newlines)
        var stemLines: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("GRAMMAR_TOPICS:") {
                let topicsPart = trimmed.dropFirst("GRAMMAR_TOPICS:".count)
                    .trimmingCharacters(in: .whitespaces)
                // Parse JSON array: ["id1","id2"] or fallback comma-separated
                if topicsPart.hasPrefix("["),
                   let data = topicsPart.data(using: .utf8),
                   let parsed = try? JSONDecoder().decode([String].self, from: data) {
                    grammarTopics = parsed.filter { !$0.isEmpty }
                } else {
                    grammarTopics = topicsPart.components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                }
            } else if trimmed.hasPrefix("SUB_USE:") {
                subUse = trimmed.dropFirst("SUB_USE:".count)
                    .trimmingCharacters(in: .whitespaces)
                    .nonEmptyOrNil
            } else {
                stemLines.append(line)
            }
        }
        let stem = stemLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (stem, grammarTopics, subUse, msgs)
    }

    /// Grade a fill-in-the-blank (tier-2 production) answer by string matching.
    /// `studentAnswers` is one string per gap (the student types each fill separately).
    /// `correctFills` is the correct choice sub-array from the question.
    /// Returns true if every segment matches after normalization. No LLM call — pure Swift logic.
    func gradeFillin(studentAnswers: [String], correctFills: [String]) -> Bool {
        guard studentAnswers.count == correctFills.count else { return false }
        let normalize: (String) -> String = { s in
            s.trimmingCharacters(in: .whitespacesAndNewlines)
             .replacingOccurrences(of: "。", with: "")
             .replacingOccurrences(of: "、", with: "")
        }
        return zip(studentAnswers, correctFills).allSatisfy { normalize($0) == normalize($1) }
    }

    // MARK: - Tier-2 fallback coaching (LLM grading when string match fails)

    /// Build the system prompt for the tier-2 production coaching conversation.
    ///
    /// This is used when the student's fill-in-the-blank answer fails string match.
    /// Haiku acts as a coaching tutor: it scores immediately when it has clear signal
    /// (correct grammar form → high score; clearly wrong/off-topic → low score), and
    /// asks a focused Socratic question when the answer is close but not quite right,
    /// waiting for the student to try again before committing a SCORE.
    ///
    /// - Parameters:
    ///   - item: the quiz item (provides topic, facet, scaffolding)
    ///   - stem: the English context shown to the student
    ///   - referenceAnswer: the correct choice from the generation call (one valid form)
    func tier2FallbackSystemPrompt(for item: GrammarQuizItem, stem: String, referenceAnswer: String) -> String {
        let sourceName: String
        switch item.source {
        case "genki":   sourceName = "Genki I & II (textbook)"
        case "bunpro":  sourceName = "Bunpro (online)"
        case "dbjg":    sourceName = "Dictionary of Basic Japanese Grammar"
        default:        sourceName = item.source
        }

        var topicLine = "Target grammar: \(item.topicId) — \(item.titleEn)"
        if let jp = item.titleJp, !jp.isEmpty { topicLine += " (\(jp))" }
        var metaLine = "Level: \(item.level) | Source: \(sourceName)"
        if let href = item.href, !href.isEmpty { metaLine += " | Reference: \(href)" }

        let extraTopicsLine: String
        if item.extraGrammarTopics.isEmpty {
            extraTopicsLine = ""
        } else {
            let list = item.extraGrammarTopics.prefix(8)
                .map { "- \($0.topicId) — \($0.titleEn)" }
                .joined(separator: "\n")
            extraTopicsLine = "\nExtra grammar topics the student knows well (context only — these were used to build the exercise sentence):\n\(list)"
        }

        return """
        You are coaching an English-speaking student on a fill-in-the-blank Japanese grammar exercise.
        \(topicLine)
        \(metaLine)\(extraTopicsLine)

        The student was shown this English context plus a Japanese sentence with \(grammarGapToken) gap(s).
        English context:
          \(stem)

        Correct fill(s) for the gap(s) (there may be other valid conjugations):
          \(referenceAnswer)

        The student typed fill(s) that did not exactly match. The student MUST use the target \
        grammar form — not a semantically equivalent alternative construction. Evaluate as follows:

        - If their answer correctly uses the target grammar form (even with minor surface \
        differences like spacing or politeness level): emit SCORE immediately.
        - If their answer is grammatically correct Japanese but uses a DIFFERENT construction \
        (e.g. a different construction that expresses the same meaning): do NOT emit SCORE yet. \
        Acknowledge that their answer is valid Japanese, but explain that this exercise is testing \
        the target grammar form specifically. Ask them to rephrase using that form. Wait for their \
        next attempt before scoring.
        - If their answer is close but has a fixable conjugation or particle error: do NOT emit \
        SCORE yet. Ask ONE focused coaching question to guide them toward the correct form. \
        Wait for their next attempt before scoring.
        - If their answer is clearly wrong, off-topic, or shows no understanding: emit SCORE: 0.0 \
        immediately with a brief explanation.
        - If the student cannot produce the target grammar form after coaching: emit SCORE: 0.0–0.2.

        SCORE format (emit on the turn you decide to grade):
          SCORE: X.X — <one grading sentence>
        Scoring scale (Bayesian confidence):
        - 1.0: correct grammar form, clear understanding
        - 0.8–0.9: right idea, very minor slip
        - 0.5: ambiguous — do NOT use as "half credit"; use coaching instead
        - 0.1–0.3: shows partial understanding but wrong for target grammar
        - 0.0: completely wrong or off-topic
        Never emit SCORE on a line by itself. After emitting SCORE, stop — do not ask follow-up \
        questions. The student will ask if they want to discuss further.
        """
    }

    /// Run the tier-2 production fallback coaching conversation.
    ///
    /// Called when the student's fill-in-the-blank answer fails string match. Haiku may
    /// ask coaching questions across multiple turns before emitting SCORE. The conversation
    /// ends as soon as SCORE appears or the turn limit is reached.
    ///
    /// - Returns: the final Haiku response text (always contains SCORE if successful) and
    ///   the full conversation for display.
    func gradeTier2FallbackForTesting(item: GrammarQuizItem, stem: String,
                                       referenceAnswer: String, studentAnswer: String,
                                       maxCoachingTurns: Int = 4)
        async throws -> (response: String, conversation: [AnthropicMessage])
    {
        let system   = tier2FallbackSystemPrompt(for: item, stem: stem, referenceAnswer: referenceAnswer)
        var messages = [AnthropicMessage(role: "user", content: [.text(studentAnswer)])]
        var lastResponse = ""

        for turn in 1...maxCoachingTurns {
            let (raw, msgs, _) = try await client.send(
                messages: messages,
                system: system,
                tools: [],
                maxTokens: 512,
                toolHandler: nil
            )
            messages    = msgs
            lastResponse = raw

            if raw.contains("SCORE:") {
                print("[GrammarQuizSession] tier-2 fallback scored on turn \(turn)")
                break
            }
            if turn == maxCoachingTurns {
                print("[GrammarQuizSession] tier-2 fallback reached max turns without SCORE")
            }
        }

        return (lastResponse, messages)
    }

    // MARK: - Tier-3 production coaching (LLM grading, multi-turn)

    /// Build the system prompt for tier-3 production grading.
    ///
    /// Similar to tier-2 fallback coaching: the student must use the target grammar form.
    /// If they write correct Japanese that uses a different construction, Haiku coaches them
    /// toward the target form. Haiku also points out other errors (particles, conjugation, etc.)
    /// even if they are not the quiz target.
    ///
    /// - Parameters:
    ///   - item: the quiz item (provides topic, facet, scaffolding)
    ///   - stem: the English context the student was asked to translate
    ///   - grammarTopics: topic IDs from the stem generation step (for PASSIVE grading)
    func tier3ProductionGradingSystemPrompt(for item: GrammarQuizItem, stem: String,
                                             grammarTopics: [String]) -> String {
        let sourceName: String
        switch item.source {
        case "genki":   sourceName = "Genki I & II (textbook)"
        case "bunpro":  sourceName = "Bunpro (online)"
        case "dbjg":    sourceName = "Dictionary of Basic Japanese Grammar"
        default:        sourceName = item.source
        }

        var topicLine = "Target grammar: \(item.topicId) — \(item.titleEn)"
        if let jp = item.titleJp, !jp.isEmpty { topicLine += " (\(jp))" }
        var metaLine = "Level: \(item.level) | Source: \(sourceName)"
        if let href = item.href, !href.isEmpty { metaLine += " | Reference: \(href)" }

        let grammarTopicsLine: String
        let passiveGradingBlock: String
        if grammarTopics.isEmpty {
            grammarTopicsLine = ""
            passiveGradingBlock = ""
        } else {
            grammarTopicsLine = "\nExtra grammar topics present in the exercise sentence (passively grade these too):\n"
                + grammarTopics.map { "- \($0)" }.joined(separator: "\n")
            passiveGradingBlock = """

            Opportunistic passive grading: on the same turn you emit SCORE, if the student's response \
            also demonstrates knowledge of grammar topics from the list above, emit one PASSIVE line \
            per topic:
              PASSIVE: <prefixed-topic-id> <score>
            Only emit PASSIVE for topics where the student demonstrates correct usage. \
            If a non-target grammar topic is used incorrectly, do NOT emit a PASSIVE line for it — \
            the student's attention is on the main quiz topic, so errors in other grammar may reflect \
            inattention rather than lack of knowledge. Mention the error in your coaching notes, but \
            skip the PASSIVE update.
            """
        }

        return """
        You are coaching an English-speaking student on a free-text Japanese production exercise.
        \(topicLine)
        \(metaLine)\(grammarTopicsLine)

        The student was shown this English context:
          \(stem)

        The student MUST use the target grammar form — not a semantically equivalent alternative \
        construction. Evaluate as follows:

        - If their answer correctly uses the target grammar form: emit SCORE immediately. \
        Also point out any other errors in their sentence (wrong particles, conjugation mistakes, \
        unnatural phrasing) as brief coaching notes — but these do not lower the SCORE for the \
        target grammar.
        - If their answer is grammatically correct Japanese but uses a DIFFERENT construction \
        (e.g. a different construction that expresses the same meaning): do NOT emit SCORE yet. \
        Acknowledge that their answer is valid Japanese, but explain that this exercise is testing \
        the target grammar form specifically. Ask them to rephrase using that form. Also note any \
        other errors you see. Wait for their next attempt before scoring.
        - If their answer has a fixable conjugation or particle error in the target grammar: \
        do NOT emit SCORE yet. Ask ONE focused coaching question. Wait for the next attempt.
        - If their answer is clearly wrong, off-topic, or shows no understanding: emit SCORE: 0.0 \
        immediately with a brief explanation.
        - If the student cannot produce the target grammar form after coaching: emit SCORE: 0.0–0.2.

        SCORE format (emit on the turn you decide to grade):
          SCORE: X.X — <one grading sentence>
        Scoring scale (Bayesian confidence, for the target grammar only):
        - 1.0: correct target grammar form, clear understanding
        - 0.8–0.9: target grammar form used, very minor slip
        - 0.5: ambiguous — do NOT use as "half credit"; use coaching instead
        - 0.1–0.3: shows partial understanding but could not produce the target grammar form
        - 0.0: completely wrong, off-topic, or gave up

        \(passiveGradingBlock)
        Never emit SCORE on a line by itself. After emitting SCORE, stop — do not ask follow-up \
        questions. The student will ask if they want to discuss further.
        """
    }

    /// Run the tier-3 production grading coaching conversation.
    ///
    /// Called when the student submits a free-text Japanese translation. Haiku may
    /// ask coaching questions across multiple turns before emitting SCORE. The conversation
    /// ends as soon as SCORE appears or the turn limit is reached.
    ///
    /// - Returns: the final Haiku response text (always contains SCORE if successful) and
    ///   the full conversation for display.
    func gradeTier3ProductionForTesting(item: GrammarQuizItem, stem: String,
                                         grammarTopics: [String], studentAnswer: String,
                                         maxCoachingTurns: Int = 4)
        async throws -> (response: String, conversation: [AnthropicMessage])
    {
        let system   = tier3ProductionGradingSystemPrompt(for: item, stem: stem,
                                                           grammarTopics: grammarTopics)
        let opening  = "Question you asked me: \(stem)\nMy answer: \(studentAnswer)\nPlease grade my answer."
        var messages = [AnthropicMessage(role: "user", content: [.text(opening)])]
        var lastResponse = ""

        for turn in 1...maxCoachingTurns {
            let (raw, msgs, _) = try await client.send(
                messages: messages,
                system: system,
                tools: [],
                maxTokens: 512,
                toolHandler: nil
            )
            messages     = msgs
            lastResponse = raw

            if raw.contains("SCORE:") {
                print("[GrammarQuizSession] tier-3 production scored on turn \(turn)")
                break
            }
            if turn == maxCoachingTurns {
                print("[GrammarQuizSession] tier-3 production reached max turns without SCORE")
            }
        }

        return (lastResponse, messages)
    }

    // MARK: - Generation loop (mirrors QuizSession.runGenerationLoop)

    func runGenerationLoop(for item: GrammarQuizItem, system: String,
                           initMsg: AnthropicMessage, label: String)
        async throws -> (question: String, multipleChoice: GrammarMultipleChoiceQuestion?, conversation: [AnthropicMessage])
    {
        var finalQuestion       = ""
        var finalMultipleChoice: GrammarMultipleChoiceQuestion? = nil
        var finalMsgs:           [AnthropicMessage] = []

        for attempt in 1...2 {
            let (raw, msgs, meta) = try await client.send(
                messages: [initMsg],
                system: system,
                tools: [],
                maxTokens: 1500,
                toolHandler: nil
            )
            finalMsgs = msgs

            if var multipleChoice = parseMultipleChoiceJSON(raw) {
                // For tier 2 production (single choices entry), do a focused second pass
                // to correct over-extraction (entire clause) or under-extraction (bare particle)
                // from the generation call.
                if multipleChoice.choices.count == 1 && multipleChoice.sentence != nil {
                    multipleChoice = await refineAnswerExtraction(
                        question: multipleChoice,
                        topicId: item.topicId,
                        topicDescription: item.titleEn,
                        client: client)
                }
                // Disambiguate gapping if an answer substring appears multiple times
                if multipleChoice.needsDisambiguation {
                    multipleChoice = await disambiguateGaps(
                        question: multipleChoice, topicId: item.topicId, client: client)
                }
                finalMultipleChoice = multipleChoice
                let letters     = ["A", "B", "C", "D"]
                let choicesText = multipleChoice.choices.indices
                    .map { "\(letters[$0])) \(multipleChoice.choiceDisplay($0))" }
                    .joined(separator: "\n")
                if let gapped = multipleChoice.displayGappedSentence {
                    // Production fill-in-the-blank: show English stem, then gapped Japanese sentence, then choices.
                    finalQuestion = "\(multipleChoice.stem)\n\n\(gapped)\n\n\(choicesText)"
                } else {
                    // Recognition: show Japanese stem, then English choices.
                    finalQuestion = "\(multipleChoice.stem)\n\n\(choicesText)"
                }
            } else {
                print("[GrammarQuizSession] \(label) attempt \(attempt): multiple choice JSON parse failed")
                finalQuestion = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            }

            try? await db.log(apiEvent: ApiEvent(
                timestamp:          ISO8601DateFormatter().string(from: Date()),
                eventType:          "question_gen",
                wordId:             item.topicId,
                quizType:           item.facet,
                inputTokens:        meta.totalInputTokens,
                outputTokens:       meta.totalOutputTokens,
                model:              client.model,
                generationAttempt:  attempt,
                apiTurns:           meta.totalTurns,
                firstTurnInputTokens: meta.firstTurnInputTokens,
                questionChars:      finalQuestion.count,
                questionFormat:     "multiple_choice",
                prefetch:           label == "prefetch" ? 1 : 0
            ))

            if finalMultipleChoice != nil || attempt >= 2 { break }
            print("[GrammarQuizSession] \(label) attempt \(attempt): parse failed, retrying")
        }

        // Fire vocab-assumed lookup async once we have a successfully parsed question.
        // Production tier 1: gloss the correct sentence (choices[correctIndex][0]).
        // Recognition tier 1: gloss the Japanese stem.
        if let mc = finalMultipleChoice {
            let sentenceToGloss: String?
            switch item.facet {
            case "production":
                sentenceToGloss = mc.choices[mc.correctIndex].first
            case "recognition":
                sentenceToGloss = mc.stem
            default:
                sentenceToGloss = nil
            }
            if let s = sentenceToGloss, !s.isEmpty {
                let capturedClient  = client
                let capturedJmdict  = jmdict
                let capturedTopicId = item.topicId
                vocabTask = Task {
                    await fetchAndResolveVocab(
                        sentence: s, topicId: capturedTopicId,
                        client: capturedClient, jmdict: capturedJmdict)
                }
            }
        }

        return (finalQuestion, finalMultipleChoice, finalMsgs)
    }

    // MARK: - JSON parsing helpers (mirrors QuizSession private helpers)

    func parseMultipleChoiceJSON(_ raw: String) -> GrammarMultipleChoiceQuestion? {
        // Collect all fenced-code-block candidates, then return the last valid one.
        // The model sometimes self-corrects mid-response by emitting a second JSON block;
        // the last block is always the intended final answer.
        var candidates: [GrammarMultipleChoiceQuestion] = []
        var search = raw[...]
        while let fenceStart = search.range(of: "```") {
            let afterFence = search[fenceStart.upperBound...]
            let body = afterFence.drop(while: { $0 != "\n" }).dropFirst()
            if let closeRange = body.range(of: "```") {
                let candidate = String(body[..<closeRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let q = decodeMultipleChoice(from: candidate) { candidates.append(q) }
                search = body[closeRange.upperBound...]
            } else {
                break
            }
        }
        if let last = candidates.last { return last }
        if let open = raw.firstIndex(of: "{"), let close = raw.lastIndex(of: "}") {
            return decodeMultipleChoice(from: String(raw[open...close]))
        }
        return nil
    }

    private func decodeMultipleChoice(from text: String) -> GrammarMultipleChoiceQuestion? {
        guard let data = text.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stem = obj["stem"] as? String,
              let rawChoices = obj["choices"] as? [Any],
              rawChoices.count == 4 || rawChoices.count == 1,
              let correctIndex = obj["correct"] as? Int,
              (0..<rawChoices.count).contains(correctIndex)
        else { return nil }

        // Accept both [[String]] (multi-gap) and [String] (legacy/recognition fallback).
        let choices: [[String]]
        if let nested = rawChoices as? [[String]] {
            // Validate: all sub-arrays must have the same length.
            let lengths = Set(nested.map(\.count))
            guard lengths.count == 1, let len = lengths.first, len >= 1 else { return nil }
            choices = nested
        } else if let flat = rawChoices as? [String] {
            // Legacy flat format — wrap each string in a 1-element array.
            choices = flat.map { [$0] }
        } else {
            return nil
        }

        // Reject questions where the model produced duplicate choices (e.g. after self-correcting
        // mid-response but the wrong block was picked, or the model made an error).
        // Compare choices as joined strings so multi-gap arrays are compared element-wise.
        let choiceKeys = choices.map { $0.joined(separator: "\u{001F}") }
        guard Set(choiceKeys).count == choices.count else { return nil }

        // "sentence" is present for production fill-in-the-blank, absent for recognition.
        let sentence = obj["sentence"] as? String
        // "sub_use" names the specific construction targeted (e.g. "godan potential form").
        let subUse = (obj["sub_use"] as? String)?.trimmingCharacters(in: .whitespaces).nonEmptyOrNil
        return GrammarMultipleChoiceQuestion(stem: stem, sentence: sentence,
                                             choices: choices, correctIndex: correctIndex,
                                             subUse: subUse)
    }
}

// MARK: - Vocab assumed

/// A single vocabulary item with its best available English gloss.
struct VocabGloss: Sendable, Equatable {
    let word: String                      // dictionary form (as returned by Haiku)
    let rubySegments: [FuriganaSegment]?  // parsed ruby HTML for furigana display; nil when unavailable
    let gloss: String                     // English gloss: JMDict senses if resolved, otherwise Haiku's gloss
    let jmdictWordIds: [String]?          // JMDict entry IDs when the word matched at least one entry; nil if no match
}

/// Returns the する-stripped lookup key for a word if it ends in する and has content before it,
/// otherwise returns nil. E.g. "練習する" → "練習", "する" → nil.
nonisolated private func suruPrefix(_ word: String) -> String? {
    guard word.hasSuffix("する") else { return nil }
    let prefix = String(word.dropLast(2))
    return prefix.isEmpty ? nil : prefix
}

/// Looks up pre-computed furigana segments for a (text, reading) pair from the `furigana`
/// table in jmdict.sqlite. Returns nil when no entry exists (caller should display the word
/// without furigana or attempt an NLTagger-based fallback).
nonisolated func lookupFurigana(
    text: String,
    reading: String,
    db: any DatabaseReader
) -> [FuriganaSegment]? {
    (try? db.read { dbConn -> [FuriganaSegment]? in
        guard let segsJSON = try String.fetchOne(
            dbConn,
            sql: "SELECT segs FROM furigana WHERE text = ? AND reading = ?",
            arguments: [text, reading]
        ) else { return nil }
        guard let data = segsJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([FuriganaSegment].self, from: data)
    }) ?? nil
}

/// Returns true when the given lookup text matches a kanji or kana form in the entry that is
/// marked `common: true`. Used to sort common entries before uncommon ones when combining
/// senses for ambiguous words.
nonisolated private func isCommonMatch(_ raw: [String: Any], lookupText: String) -> Bool {
    let kanjiForms = raw["kanji"] as? [[String: Any]] ?? []
    if let match = kanjiForms.first(where: { ($0["text"] as? String) == lookupText }) {
        return (match["common"] as? Bool) == true
    }
    let kanaForms = raw["kana"] as? [[String: Any]] ?? []
    if let match = kanaForms.first(where: { ($0["text"] as? String) == lookupText }) {
        return (match["common"] as? Bool) == true
    }
    return false
}

/// Extracts all English senses from a parsed JMDict entry_json object.
/// Sub-glosses within one sense are joined with ", "; senses are joined with "; ".
nonisolated private func glossFromEntry(_ raw: [String: Any]) -> String? {
    let senses = raw["sense"] as? [[String: Any]] ?? []
    let parts = senses.compactMap { sense -> String? in
        let texts = (sense["gloss"] as? [[String: Any]] ?? [])
            .filter { ($0["lang"] as? String) == "eng" }
            .compactMap { $0["text"] as? String }
        return texts.isEmpty ? nil : texts.joined(separator: ", ")
    }
    return parts.isEmpty ? nil : parts.joined(separator: "; ")
}

/// Asks Haiku to identify key vocabulary in `sentence` that an N4 learner might not know,
/// then resolves each word against jmdict.sqlite using exact match on kanji or kana form.
///
/// - Returns an array of `VocabGloss` (may be empty if Haiku returns nothing or the call fails).
/// - する-compound verbs (e.g. 練習する) are retried without する when the full form has no match.
/// - When multiple entries match, senses from all entries are combined (joined with " / ").
/// - Haiku's gloss is used only when JMDict has no match at all.
nonisolated func fetchAndResolveVocab(
    sentence: String,
    topicId: String,
    client: AnthropicClient,
    jmdict: (any DatabaseReader)?
) async -> [VocabGloss] {
    // Step 1: Ask Haiku for key vocabulary with brief glosses.
    let prompt = """
    Japanese text: \(sentence)
    Grammar topic: \(topicId)

    List the nouns, verbs, adjectives, and adverbs in this text that a Japanese learner \
    just at JLPT level N5 (and likely not N4 or N3) might not know. Use dictionary form for each word.
    Exclude: particles, copulas (だ/です/ある/いる/する), and the target grammar structure itself.
    When in doubt, include the word — it is better to over-include than to omit a word the \
    learner does not know.
    Aim for 2–6 words. If there are no such words, return [].

    Reply with ONLY a JSON array, nothing else:
    [{"word":"...","gloss":"brief English meaning"},...]
    """

    let haikuWords: [(word: String, gloss: String)]
    do {
        let (response, _, _) = try await client.send(
            messages: [AnthropicMessage(role: "user", content: [.text(prompt)])],
            maxTokens: 128,
            toolHandler: nil
        )
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        // Extract JSON array from response (may be wrapped in a code fence or have leading prose).
        guard let open = trimmed.firstIndex(of: "["),
              let close = trimmed.lastIndex(of: "]")
        else { return [] }
        let jsonStr = String(trimmed[open...close])
        guard let data = jsonStr.data(using: .utf8),
              let arr = try? JSONDecoder().decode([[String: String]].self, from: data)
        else { return [] }
        haikuWords = arr.compactMap { dict in
            guard let w = dict["word"], let g = dict["gloss"],
                  !w.isEmpty, !g.isEmpty else { return nil }
            return (w, g)
        }
    } catch {
        return []
    }

    guard !haikuWords.isEmpty else { return [] }

    // Step 2: Batch JMDict lookup. Build the set of lookup keys (original words + する-stripped
    // alternates) so we can resolve them all in one query.
    guard let db = jmdict else {
        print("[furigana] jmdict reader is nil — no furigana possible")
        return haikuWords.map { VocabGloss(word: $0.word, rubySegments: nil, gloss: $0.gloss, jmdictWordIds: nil) }
    }

    // Map each original word to its alternate lookup key (する-stripped), if applicable.
    let suruAlternates: [String: String] = Dictionary(
        uniqueKeysWithValues: haikuWords.compactMap { (word, _) -> (String, String)? in
            guard let prefix = suruPrefix(word) else { return nil }
            return (word, prefix)
        }
    )
    let allLookupKeys: [String] = Array(Set(
        haikuWords.map { $0.word } + suruAlternates.values
    ))
    let placeholders = allLookupKeys.map { _ in "?" }.joined(separator: ",")
    // No GROUP BY — return one row per (text, entry) pair so we get all matched entries.
    let sql = """
        SELECT r.text, e.id AS entry_id, e.entry_json
        FROM raws r JOIN entries e ON e.id = r.entry_id
        WHERE r.text IN (\(placeholders))
    """

    struct EntryRow { let text: String; let entryId: String; let entryJson: String }

    let entryRows: [EntryRow]
    do {
        entryRows = try await db.read { dbConn in
            try Row.fetchAll(dbConn, sql: sql, arguments: StatementArguments(allLookupKeys))
                .compactMap { row -> EntryRow? in
                    guard let text = row["text"] as? String,
                          let json = row["entry_json"] as? String else { return nil }
                    let entryId: String
                    if let s = row["entry_id"] as? String     { entryId = s }
                    else if let n = row["entry_id"] as? Int64 { entryId = String(n) }
                    else { return nil }
                    return EntryRow(text: text, entryId: entryId, entryJson: json)
                }
        }
    } catch {
        return haikuWords.map { VocabGloss(word: $0.word, rubySegments: nil, gloss: $0.gloss, jmdictWordIds: nil) }
    }

    // Group entry rows by lookup text.
    var entriesByText: [String: [EntryRow]] = [:]
    for row in entryRows {
        entriesByText[row.text, default: []].append(row)
    }

    return haikuWords.map { (word, haikuGloss) in
        // Prefer entries for the original word; fall back to the する-stripped form if no match.
        let matchedRows: [EntryRow]
        if let rows = entriesByText[word], !rows.isEmpty {
            matchedRows = rows
        } else if let alt = suruAlternates[word],
                  let rows = entriesByText[alt], !rows.isEmpty {
            matchedRows = rows
        } else {
            print("[furigana] no JMDict match for word=\(word)")
            return VocabGloss(word: word, rubySegments: nil, gloss: haikuGloss, jmdictWordIds: nil)
        }

        // Sort common entries before uncommon ones so the most-used meaning leads.
        let lookupText = suruAlternates[word] ?? word
        let sortedRows = matchedRows.sorted { a, b in
            let aRaw = (a.entryJson.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let bRaw = (b.entryJson.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let aCommon = aRaw.map { isCommonMatch($0, lookupText: lookupText) } ?? false
            let bCommon = bRaw.map { isCommonMatch($0, lookupText: lookupText) } ?? false
            return aCommon && !bCommon
        }
        let ids = sortedRows.map { $0.entryId }

        // Build combined gloss: one entry per segment, separated by " / ".
        let combinedGloss = sortedRows.compactMap { row -> String? in
            guard let data = row.entryJson.data(using: .utf8),
                  let raw  = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return glossFromEntry(raw)
        }.joined(separator: " / ")

        // Extract the first kana reading from the best-matched entry to key into the
        // furigana table. JmdictFurigana is keyed on (written form, kana reading).
        let furiganaSegments: [FuriganaSegment]?
        if let firstEntryData = sortedRows.first?.entryJson.data(using: .utf8),
           let firstRaw = try? JSONSerialization.jsonObject(with: firstEntryData) as? [String: Any],
           let kanaForms = firstRaw["kana"] as? [[String: Any]],
           let firstKana = kanaForms.first?["text"] as? String {
            let segs = lookupFurigana(text: lookupText, reading: firstKana, db: db)
            if segs == nil {
                print("[furigana] miss: text=\(lookupText) reading=\(firstKana)")
            } else {
                print("[furigana] hit:  text=\(lookupText) reading=\(firstKana) segs=\(segs!.count)")
            }
            furiganaSegments = segs
        } else {
            print("[furigana] no kana reading found in JMDict entry for word=\(word) lookupText=\(lookupText)")
            furiganaSegments = nil
        }

        return VocabGloss(word: word, rubySegments: furiganaSegments,
                          gloss: combinedGloss.isEmpty ? haikuGloss : combinedGloss,
                          jmdictWordIds: ids)
    }
}

// MARK: - String helper

private extension String {
    /// Returns nil when the string is empty (or whitespace-only), otherwise the trimmed string.
    var nonEmptyOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
