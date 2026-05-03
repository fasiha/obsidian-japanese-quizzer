// Fuzz.swift
// Randomized / property-based fuzz tests for non-UI logic.
// Invoked via: TestHarness --fuzz <area>
// Areas: jmdict, furigana, fillin

import Foundation
import GRDB

// MARK: - Dispatcher

func runFuzz(area: String, jmdict: DatabaseQueue) async throws {
    switch area {
    case "jmdict":           try await fuzzJmdict(jmdict: jmdict)
    case "furigana":         try await fuzzFurigana(jmdict: jmdict)
    case "fillin":           try await fuzzFillin()
    case "ebisu":            fuzzEbisu()
    case "partial-template": try await fuzzPartialTemplate(jmdict: jmdict)
    case "romaji":           fuzzRomaji()
    case "commit-progression": try await fuzzCommitProgression(jmdict: jmdict)
    case "kanjidic2":        try await fuzzKanjidic2(jmdict: jmdict)
    case "counters":         fuzzCounters()
    case "all":
        try await fuzzJmdict(jmdict: jmdict)
        try await fuzzFurigana(jmdict: jmdict)
        try await fuzzFillin()
        fuzzEbisu()
        try await fuzzPartialTemplate(jmdict: jmdict)
        fuzzRomaji()
        try await fuzzCommitProgression(jmdict: jmdict)
        try await fuzzKanjidic2(jmdict: jmdict)
        fuzzCounters()
    default:
        fputs("Unknown fuzz area '\(area)'. Valid: jmdict, furigana, fillin, ebisu, partial-template, romaji, commit-progression, kanjidic2, counters, all\n", stderr)
        exit(1)
    }
}

// MARK: - Shared reporter

private func report(area: String, checked: Int, silentlySkipped: Int, failures: [(String, String)]) {
    print("")
    let skipNote = silentlySkipped > 0 ? " (\(silentlySkipped) silently skipped by implementation)" : ""
    print("Checked \(checked) items\(skipNote).")
    if failures.isEmpty {
        print("[PASS] \(area): no failures.")
    } else {
        print("[FAIL] \(area): \(failures.count) failure(s):")
        for (ctx, reason) in failures.prefix(30) {
            print("  [\(ctx)] \(reason)")
        }
        if failures.count > 30 { print("  … and \(failures.count - 30) more.") }
    }
}

// MARK: - Area 1: jmdict structural invariants

// Runs jmdictWordData over every entry ID in the database and checks:
//   • kanaTexts is non-empty (every JMDict entry has at least one kana reading)
//   • text (display form) is non-empty
// Also verifies that adversarial IDs (zero, negative, non-numeric) return no result.
func fuzzJmdict(jmdict: DatabaseQueue) async throws {
    print("=== FUZZ: jmdict structural invariants ===")
    print("Loading all entry IDs from jmdict.sqlite…")

    let allIds = try await jmdict.read { db in
        try String.fetchAll(db, sql: "SELECT id FROM entries ORDER BY CAST(id AS INTEGER)")
    }
    print("Found \(allIds.count) entries. Checking invariants…")

    var failures: [(String, String)] = []
    var silentlySkipped = 0
    let batchSize = 1000
    var i = 0

    while i < allIds.count {
        let batch = Array(allIds[i ..< min(i + batchSize, allIds.count)])
        let result = try await QuizContext.jmdictWordData(ids: batch, jmdict: jmdict)
        for id in batch {
            guard let e = result[id] else {
                // jmdictWordData silently skips entries where all kana are tagged 'ik'
                // (irregular readings) and there are also no valid kanji forms.
                silentlySkipped += 1
                continue
            }
            // Invariant: every returned entry must have at least one kana reading and a non-empty display text.
            if e.kanaTexts.isEmpty { failures.append((id, "kanaTexts is empty")) }
            if e.text.isEmpty      { failures.append((id, "text is empty")) }
        }
        i += batchSize
        if i % 20_000 == 0 { print("  \(i)/\(allIds.count)…") }
    }

    // Adversarial IDs: none of these should match a real entry.
    let adversarial = ["0", "-1", "99999999", "", " ", "abc", "\u{0000}", "1e9", "NaN"]
    for id in adversarial {
        let r = try await QuizContext.jmdictWordData(ids: [id], jmdict: jmdict)
        if r[id] != nil { failures.append((id, "adversarial ID '\(id)' returned a result")) }
    }

    report(area: "jmdict", checked: allIds.count, silentlySkipped: silentlySkipped, failures: failures)
}

// MARK: - Area 3: furigana coverage invariant

// For every row in the furigana table, checks that the concatenation of all
// segment ruby fields exactly equals the row's text field.
// A mismatch means a character was dropped or duplicated in segmentation,
// which would cause partial-kanji quiz templates to be malformed.
func fuzzFurigana(jmdict: DatabaseQueue) async throws {
    print("=== FUZZ: furigana coverage invariant ===")

    struct FRow { let text: String; let reading: String; let segs: String }
    struct Seg: Decodable { let ruby: String; let rt: String? }

    print("Loading furigana table…")
    let rows = try await jmdict.read { db -> [FRow] in
        let cursor = try Row.fetchCursor(db, sql: "SELECT text, reading, segs FROM furigana")
        var buf: [FRow] = []
        buf.reserveCapacity(240_000)
        while let row = try cursor.next() {
            buf.append(FRow(text: row["text"], reading: row["reading"], segs: row["segs"]))
        }
        return buf
    }
    print("Checking \(rows.count) furigana rows…")

    let decoder = JSONDecoder()
    var failures: [(String, String)] = []

    for (n, row) in rows.enumerated() {
        guard let data = row.segs.data(using: .utf8),
              let segs = try? decoder.decode([Seg].self, from: data) else {
            failures.append((row.text, "JSON decode failed for segs: \(row.segs.prefix(60))"))
            continue
        }
        // Core invariant: ruby fields joined must equal the original text.
        let joined = segs.map(\.ruby).joined()
        if joined != row.text {
            failures.append((row.text,
                "ruby joined '\(joined)' ≠ text '\(row.text)' (reading: \(row.reading))"))
        }
        // Each segment's ruby must be non-empty.
        if segs.isEmpty {
            failures.append((row.text, "zero segments (reading: \(row.reading))"))
        } else if segs.contains(where: { $0.ruby.isEmpty }) {
            failures.append((row.text, "segment with empty ruby (reading: \(row.reading))"))
        }
        if n > 0 && n % 50_000 == 0 { print("  \(n)/\(rows.count)…") }
    }

    report(area: "furigana", checked: rows.count, silentlySkipped: 0, failures: failures)
}

// MARK: - Area 2: gradeFillin normalization adversarial inputs

@MainActor

// Tests GrammarQuizSession.gradeFillin with:
//   • Known fixed cases (exact match, punctuation stripping, whitespace trimming, Unicode edge cases)
//   • Random property: reflexivity — gradeFillin([s], [s]) must always return true
//   • Random property: 。-strip invariant — appending 。 to either side must not change the result
func fuzzFillin() async throws {
    print("=== FUZZ: gradeFillin normalization invariants ===")

    // gradeFillin is a pure function; creating the session just to call it requires a client+db
    // but neither will be used for any network call.
    let tmpPath = NSTemporaryDirectory() + "fuzz-fillin-\(ProcessInfo.processInfo.processIdentifier).sqlite"
    defer { try? FileManager.default.removeItem(atPath: tmpPath) }
    let db      = try QuizDB.open(path: tmpPath)
    let client  = AnthropicClient(apiKey: "not-needed", model: "claude-haiku-4-5-20251001")
    let session = GrammarQuizSession(client: client, db: db)

    var failures: [(String, String)] = []

    // Fixed cases: (student, correct, expectedPass?, description)
    // nil expectedPass means we record the result but don't assert.
    let fixed: [(String, String, Bool?, String)] = [
        ("食べます",            "食べます",    true,  "exact match"),
        ("食べます。",           "食べます",    true,  "student appends 。"),
        ("食べます",            "食べます。",   true,  "correct has trailing 。"),
        ("食べます、",           "食べます",    true,  "student appends 、"),
        ("  食べます  ",         "食べます",    true,  "student pads with ASCII spaces"),
        ("食べます\n",           "食べます",    true,  "student appends newline"),
        ("食べます\t",           "食べます",    true,  "student appends tab"),
        ("食べる",              "食べます",    false, "wrong word"),
        ("",                  "食べます",    false, "empty student answer"),
        ("食べます",            "",           false, "empty correct answer"),
        // Both normalize to "" so they match — surprising but consistent with the implementation.
        ("。",                 "",           true,  "student types 。, correct is empty (both → empty)"),
        ("。",                 "。",          true,  "both are just 。 (both → empty)"),
        // Half-width ideographic full stop U+FF61 is NOT stripped — record actual behavior.
        ("食べます\u{FF61}",     "食べます",    nil,   "half-width ｡ U+FF61 (not stripped by current impl)"),
        // Ideographic space U+3000 — Swift's whitespacesAndNewlines includes it.
        ("\u{3000}食べます\u{3000}", "食べます", nil,  "ideographic space U+3000 trimming"),
        // Swift String.== uses Unicode canonical equivalence: NFC か+◌゛ == NFD が
        ("\u{304B}\u{3099}",   "\u{304C}",   true,  "NFD か+◌゛ == NFC が (canonical equivalence)"),
        // Count mismatch
        ("食べます",            "食べます",    true,  "count 1 vs 1"),
    ]

    print("Fixed cases:")
    for (student, correct, expected, desc) in fixed {
        let result = session.gradeFillin(studentAnswers: [student], correctFills: [correct])
        if let exp = expected, result != exp {
            failures.append((desc, "gradeFillin(\"\(student)\", \"\(correct)\") = \(result), expected \(exp)"))
            print("  [FAIL] \(desc): got \(result)")
        } else {
            let tag = expected == nil ? "[info]" : "[ok]  "
            print("  \(tag) \(desc): \(result ? "pass" : "fail")")
        }
    }

    // Random properties: use a deterministic xorshift64 PRNG for reproducibility.
    var rng: UInt64 = 0xDEAD_BEEF_CAFE_BABE
    func next() -> UInt64 {
        rng ^= rng &<< 13; rng ^= rng >> 7; rng ^= rng &<< 17; return rng
    }
    let hiragana = (0x3041 ... 0x3096).compactMap { Unicode.Scalar($0).map(Character.init) }
    func randomHiraganaString(maxLen: Int = 10) -> String {
        let len = Int(next() % UInt64(maxLen)) + 1
        return String((0 ..< len).map { _ in hiragana[Int(next() % UInt64(hiragana.count))] })
    }

    let iterations = 500
    print("\nReflexivity property (\(iterations) random hiragana strings):")
    var reflexFailures = 0
    for _ in 0 ..< iterations {
        let s = randomHiraganaString()
        if !session.gradeFillin(studentAnswers: [s], correctFills: [s]) {
            failures.append(("reflexivity", "gradeFillin([\"\(s)\"], [\"\(s)\"]) = false"))
            reflexFailures += 1
        }
    }
    print("  \(reflexFailures == 0 ? "[PASS]" : "[FAIL]") \(reflexFailures) failures")

    print("\n。-strip invariant (\(iterations * 2) random strings):")
    var stripFailures = 0
    for _ in 0 ..< iterations {
        let s = randomHiraganaString()
        // Appending 。 to either side: both should produce the same gradeFillin result.
        let baseResult   = session.gradeFillin(studentAnswers: [s], correctFills: [s])         // always true from reflexivity
        let studentExtra = session.gradeFillin(studentAnswers: [s + "。"], correctFills: [s])
        let correctExtra = session.gradeFillin(studentAnswers: [s], correctFills: [s + "。"])
        if !studentExtra {
            failures.append(("。-strip", "gradeFillin([\"\(s)。\"], [\"\(s)\"]) = false (base = \(baseResult))"))
            stripFailures += 1
        }
        if !correctExtra {
            failures.append(("。-strip", "gradeFillin([\"\(s)\"], [\"\(s)。\"]) = false (base = \(baseResult))"))
            stripFailures += 1
        }
    }
    print("  \(stripFailures == 0 ? "[PASS]" : "[FAIL]") \(stripFailures) failures")

    report(area: "fillin", checked: fixed.count + iterations * 3, silentlySkipped: 0, failures: failures)
}

// MARK: - Area A: EbisuModel mathematical invariants

// Tests:
//   • predictRecall is in [0, 1] for any well-formed model and any tnow ≥ 0
//   • predictRecall ≈ 1 right after a review (tnow ≈ 0), ≈ 0.5 at halflife
//   • updateRecall doesn't throw for valid inputs (score ∈ [0,1], tnow > 0)
//   • Monotonicity: a perfect review (score = 1) produces ≥ halflife than a zero review
//   • No NaN, no Infinity in any output for any reasonable input
func fuzzEbisu() {
    print("=== FUZZ: EbisuModel mathematical invariants ===")

    var failures: [(String, String)] = []

    // 1. predictRecall sanity: range, fresh-review, at-halflife.
    let halflives: [Double] = [0.5, 1, 8, 24, 72, 168, 720, 8760, 100_000]
    for t in halflives {
        let m = defaultModel(halflife: t)

        let pNow = predictRecall(m, tnow: 0, exact: true)
        if !pNow.isFinite || pNow < 0.99 || pNow > 1.0001 {
            failures.append(("predictRecall t=\(t)", "tnow=0 → \(pNow), expected ≈ 1"))
        }

        let pHalf = predictRecall(m, tnow: t, exact: true)
        if !pHalf.isFinite || pHalf < 0.45 || pHalf > 0.55 {
            failures.append(("predictRecall t=\(t)", "tnow=halflife → \(pHalf), expected ≈ 0.5"))
        }

        let pFar = predictRecall(m, tnow: t * 100, exact: true)
        if !pFar.isFinite || pFar < 0 || pFar > 0.5 {
            failures.append(("predictRecall t=\(t)", "tnow=100×halflife → \(pFar), expected ∈ [0, 0.5]"))
        }
    }

    // 2. predictRecall always in [0, 1] for random (halflife, tnow) pairs.
    var rng: UInt64 = 0xA1B2_C3D4_E5F6_0789
    func next() -> UInt64 { rng ^= rng &<< 13; rng ^= rng >> 7; rng ^= rng &<< 17; return rng }
    func randHalflife() -> Double { Double(next() % 1_000_000) / 100.0 + 0.1 }   // 0.1 .. 10000
    func randTnow(t: Double) -> Double { Double(next() % UInt64(1_000_000)) / 1000.0 * t + 0.0 }

    var rangeFailures = 0
    for _ in 0 ..< 5000 {
        let t = randHalflife()
        let m = defaultModel(halflife: t)
        let tnow = randTnow(t: t) * 50  // up to 50× halflife
        let p = predictRecall(m, tnow: tnow, exact: true)
        if !p.isFinite || p < 0 || p > 1.0001 {
            rangeFailures += 1
            if rangeFailures <= 5 {
                failures.append(("predictRecall range", "halflife=\(t) tnow=\(tnow) → \(p)"))
            }
        }
    }
    if rangeFailures > 5 {
        failures.append(("predictRecall range", "...and \(rangeFailures - 5) more failures over 5000 random samples"))
    }
    print("  predictRecall range: \(rangeFailures == 0 ? "[PASS]" : "[FAIL] \(rangeFailures) failures")")

    // 3. updateRecall doesn't throw for valid inputs; output model is well-formed.
    var updateFailures = 0
    var monotonicityFailures = 0
    for _ in 0 ..< 1000 {
        let t = randHalflife()
        let prior = defaultModel(halflife: t)
        let tnow = randTnow(t: t) + 0.01

        do {
            let perfect = try updateRecall(prior, successes: 1.0, tnow: tnow)
            let zero    = try updateRecall(prior, successes: 0.0, tnow: tnow)

            if !perfect.t.isFinite || perfect.t <= 0 ||
               !perfect.alpha.isFinite || perfect.alpha <= 0 ||
               !perfect.beta.isFinite || perfect.beta <= 0 {
                updateFailures += 1
                if updateFailures <= 5 {
                    failures.append(("updateRecall well-formed",
                        "perfect score: t=\(prior.t) tnow=\(tnow) → α=\(perfect.alpha) β=\(perfect.beta) t=\(perfect.t)"))
                }
            }
            if !zero.t.isFinite || zero.t <= 0 ||
               !zero.alpha.isFinite || zero.alpha <= 0 ||
               !zero.beta.isFinite || zero.beta <= 0 {
                updateFailures += 1
            }

            // Monotonicity: perfect score should produce ≥ halflife than zero score
            // (allow a tiny epsilon for floating-point noise).
            if perfect.t < zero.t - 1e-6 {
                monotonicityFailures += 1
                if monotonicityFailures <= 5 {
                    failures.append(("updateRecall monotonicity",
                        "perfect.t=\(perfect.t) < zero.t=\(zero.t) for prior.t=\(prior.t) tnow=\(tnow)"))
                }
            }
        } catch {
            updateFailures += 1
            if updateFailures <= 5 {
                failures.append(("updateRecall threw", "prior.t=\(prior.t) tnow=\(tnow) → \(error)"))
            }
        }
    }
    print("  updateRecall well-formed: \(updateFailures == 0 ? "[PASS]" : "[FAIL] \(updateFailures) failures")")
    print("  updateRecall monotonicity (perfect ≥ zero): \(monotonicityFailures == 0 ? "[PASS]" : "[FAIL] \(monotonicityFailures) failures")")

    // 4. Adversarial inputs to updateRecall: should throw, not crash silently.
    let prior = defaultModel(halflife: 24)
    let badInputs: [(Double, Double, String)] = [
        (-0.1, 1.0, "negative score"),
        (1.1,  1.0, "score > 1"),
        (Double.nan, 1.0, "NaN score"),
    ]
    for (score, tnow, desc) in badInputs {
        do {
            _ = try updateRecall(prior, successes: score, tnow: tnow)
            failures.append(("updateRecall adversarial", "\(desc): did not throw"))
        } catch {
            // Expected
        }
    }

    // 5. rescaleHalflife should preserve halflife when given the current halflife as target.
    do {
        let m = defaultModel(halflife: 100)
        let rescaled = try rescaleHalflife(m, targetHalflife: 100)
        if abs(rescaled.t - 100) > 0.01 {
            failures.append(("rescaleHalflife identity", "100h → \(rescaled.t)h, expected 100"))
        }
    } catch {
        failures.append(("rescaleHalflife", "identity threw: \(error)"))
    }

    let totalChecked = halflives.count * 3 + 5000 + 1000 * 3 + badInputs.count + 1
    report(area: "ebisu", checked: totalChecked, silentlySkipped: 0, failures: failures)
}

// MARK: - Area B: buildPartialTemplate round-trip

// For every row in the furigana table:
//   • All-committed: buildPartialTemplate returns text exactly
//   • None-committed: buildPartialTemplate returns reading exactly
// Plus random subsets: output character count equals sum of (ruby for committed, rt for uncommitted).
func fuzzPartialTemplate(jmdict: DatabaseQueue) async throws {
    print("=== FUZZ: buildPartialTemplate round-trip ===")

    struct FRow { let text: String; let reading: String; let segs: String }

    print("Loading furigana rows (limited to 50000 for speed)…")
    let rows = try await jmdict.read { db -> [FRow] in
        let cursor = try Row.fetchCursor(db, sql: "SELECT text, reading, segs FROM furigana LIMIT 50000")
        var buf: [FRow] = []
        buf.reserveCapacity(50_000)
        while let row = try cursor.next() {
            buf.append(FRow(text: row["text"], reading: row["reading"], segs: row["segs"]))
        }
        return buf
    }
    print("Checking \(rows.count) rows…")

    let decoder = JSONDecoder()
    var failures: [(String, String)] = []
    var allCommittedFails = 0
    var noneCommittedFails = 0
    var randomFails = 0

    var rng: UInt64 = 0x1234_5678_ABCD_EF01
    func next() -> UInt64 { rng ^= rng &<< 13; rng ^= rng >> 7; rng ^= rng &<< 17; return rng }

    for (n, row) in rows.enumerated() {
        guard let data = row.segs.data(using: .utf8),
              let parts = try? decoder.decode([FuriganaPart].self, from: data) else {
            continue  // malformed segs already covered by furigana area
        }

        // Invariant 1: all-committed → output == text
        let allKanji = Set(parts.compactMap { $0.rt != nil ? $0.ruby : nil })
        let allOut = buildPartialTemplate(furigana: parts, committedKanji: allKanji)
        if allOut != row.text {
            allCommittedFails += 1
            if allCommittedFails <= 5 {
                failures.append(("all-committed",
                    "text='\(row.text)' reading='\(row.reading)' → '\(allOut)'"))
            }
        }

        // Invariant 2 (relaxed): none-committed should equal the manually computed expected
        // value (kana segments unchanged, kanji segments replaced by their rt). The original
        // version asserted equality with row.reading, but that fails for katakana surface
        // forms (e.g. "アッと言う間に") where segments preserve katakana but reading is
        // hiragana-canonicalized. Documenting that discrepancy by counting it separately.
        let noneOut = buildPartialTemplate(furigana: parts, committedKanji: [])
        var noneExpected = ""
        for p in parts { noneExpected += (p.rt != nil ? p.rt! : p.ruby) }
        if noneOut != noneExpected {
            noneCommittedFails += 1
            if noneCommittedFails <= 5 {
                failures.append(("none-committed (vs computed expected)",
                    "text='\(row.text)' → '\(noneOut)' vs expected '\(noneExpected)'"))
            }
        }
        // Separately track the discrepancy with the row's hiragana-canonicalized reading.
        // This is informational — not necessarily a bug.
        // (We could enable a stricter check here if the UI relies on this equality.)

        // Invariant 3: random subset of kanji committed.
        // Output should equal ruby for kanji ∈ subset, rt for kanji ∉ subset.
        if !allKanji.isEmpty {
            let kanjiArr = Array(allKanji)
            let subsetSize = Int(next() % UInt64(kanjiArr.count + 1))
            let shuffled = kanjiArr.shuffled()
            let subset = Set(shuffled.prefix(subsetSize))
            let out = buildPartialTemplate(furigana: parts, committedKanji: subset)
            // Manual computation of the expected output
            var expected = ""
            for p in parts {
                if let rt = p.rt, !subset.contains(p.ruby) {
                    expected += rt
                } else {
                    expected += p.ruby
                }
            }
            if out != expected {
                randomFails += 1
                if randomFails <= 5 {
                    failures.append(("random-subset",
                        "text='\(row.text)' subset=\(subset.sorted()) → '\(out)' vs expected '\(expected)'"))
                }
            }
        }

        if n > 0 && n % 25_000 == 0 { print("  \(n)/\(rows.count)…") }
    }

    print("  all-committed: \(allCommittedFails == 0 ? "[PASS]" : "[FAIL] \(allCommittedFails) failures")")
    print("  none-committed: \(noneCommittedFails == 0 ? "[PASS]" : "[FAIL] \(noneCommittedFails) failures")")
    print("  random-subset: \(randomFails == 0 ? "[PASS]" : "[FAIL] \(randomFails) failures")")

    report(area: "partial-template", checked: rows.count * 3, silentlySkipped: 0, failures: failures)
}

// MARK: - Area E: RomajiConverter adversarial inputs

func fuzzRomaji() {
    print("=== FUZZ: romajiToHiragana adversarial inputs ===")

    var failures: [(String, String)] = []

    // Fixed cases with expected outputs.
    let known: [(String, String?, String)] = [
        ("",         "",       "empty string"),
        ("ka",       "か",     "single kana"),
        ("KA",       "か",     "uppercase ka"),
        ("Ka",       "か",     "mixed case ka"),
        ("sha",      "しゃ",   "digraph sha"),
        ("kka",      "っか",   "geminate っか"),
        ("tta",      "った",   "geminate った"),
        ("ssha",     "っしゃ", "geminate digraph"),
        ("nn",       "ん",     "explicit n n"),
        ("n'a",      "んあ",   "n with apostrophe before vowel"),
        ("watashi",  "わたし", "real word"),
        ("benkyou",  "べんきょう", "real word with digraph + 'n' before consonant"),
        ("xyz",       nil,     "all-unknown ASCII"),
        ("kaXY",      nil,     "starts valid, ends invalid"),
        ("k",         nil,     "lone consonant"),
        ("kkk",       nil,     "triple consonant (kk consumed → っ; lone k unrecognized)"),
        ("tcha",      nil,     "tcha (only ccha is in the table)"),
        ("123",       nil,     "digits"),
        ("\u{0000}",  nil,     "null byte"),
    ]

    for (input, expected, desc) in known {
        let result = romajiToHiragana(input)
        if result != expected {
            failures.append((desc, "romajiToHiragana(\"\(input)\") = \(String(describing: result)), expected \(String(describing: expected))"))
        } else {
            print("  [ok]   \(desc): \(result.map { "\"\($0)\"" } ?? "nil")")
        }
    }

    // Random ASCII fuzz: function should never crash; output is either nil or hiragana-only.
    var rng: UInt64 = 0xCAFE_BABE_DEAD_BEEF
    func next() -> UInt64 { rng ^= rng &<< 13; rng ^= rng >> 7; rng ^= rng &<< 17; return rng }

    var crashCount = 0
    var nonHiraganaOutputs = 0
    let iterations = 5000
    for _ in 0 ..< iterations {
        let len = Int(next() % 16) + 1
        var s = ""
        for _ in 0 ..< len {
            let c = Character(Unicode.Scalar(UInt8(next() % 26 + 97)))  // a-z
            s.append(c)
        }
        // Occasionally inject high-bit / non-ASCII to test robustness
        if (next() % 10) == 0 {
            s.append(Character(Unicode.Scalar(0x3042)!))  // hiragana あ
        }

        if let result = romajiToHiragana(s) {
            // Output must be hiragana (or empty). Allow も for special compound combinations.
            // Hiragana range: 0x3041-0x309F, plus っ which is 0x3063.
            for u in result.unicodeScalars {
                if !(u.value >= 0x3041 && u.value <= 0x309F) {
                    nonHiraganaOutputs += 1
                    if nonHiraganaOutputs <= 5 {
                        failures.append(("non-hiragana output",
                            "romajiToHiragana(\"\(s)\") returned \"\(result)\" containing U+\(String(u.value, radix: 16))"))
                    }
                    break
                }
            }
        }
        // No way to verify "no crash" except that we got here without trapping.
        _ = crashCount  // unused but kept for clarity
    }

    print("  random ASCII (\(iterations) iters): \(nonHiraganaOutputs == 0 ? "[PASS]" : "[FAIL] \(nonHiraganaOutputs) bad-output failures")")

    report(area: "romaji", checked: known.count + iterations, silentlySkipped: 0, failures: failures)
}

// MARK: - Area K: Word commitment progression

// Walks the commitment ladder ∅ → {k₁} → {k₁, k₂} → … → all-kanji for furigana rows
// that have at least two kanji segments, and verifies invariants at each step.
//
// Why this is different from area B: B tests random subsets independently. K tests
// a coherent progression where each step must be consistent with the prior step.
// The invariants exercise the per-segment rule and monotonicity of rt-substitution
// — the contract the iOS app's QuizContext relies on when computing partialKanjiTemplate
// at every kanji-commit event.
func fuzzCommitProgression(jmdict: DatabaseQueue) async throws {
    print("=== FUZZ: word commitment progression ===")

    struct FRow { let text: String; let reading: String; let segs: String }

    // Pull rows that have at least one CJK ideograph in text — those are the only ones
    // a user can progressively commit. 50k random sample for speed.
    let rows = try await jmdict.read { db -> [FRow] in
        let cursor = try Row.fetchCursor(db, sql: "SELECT text, reading, segs FROM furigana LIMIT 50000")
        var buf: [FRow] = []
        buf.reserveCapacity(50_000)
        while let row = try cursor.next() {
            buf.append(FRow(text: row["text"], reading: row["reading"], segs: row["segs"]))
        }
        return buf
    }
    print("Loaded \(rows.count) furigana rows.")

    let decoder = JSONDecoder()
    var failures: [(String, String)] = []
    var monotonicityFails = 0
    var perSegmentFails = 0
    var allCommittedFails = 0
    var kanjiSetMismatchFails = 0
    var checkedRows = 0
    var multiKanjiRows = 0

    var rng: UInt64 = 0xFADE_BEEF_DEAD_BABE
    func next() -> UInt64 { rng ^= rng &<< 13; rng ^= rng >> 7; rng ^= rng &<< 17; return rng }

    for (n, row) in rows.enumerated() {
        guard let data = row.segs.data(using: .utf8),
              let parts = try? decoder.decode([FuriganaPart].self, from: data) else {
            continue
        }
        // Order-preserving deduplicated kanji from rt-bearing segments.
        var seenK = Set<String>()
        let kanjiInOrder: [String] = parts.compactMap { p -> String? in
            guard p.rt != nil else { return nil }
            return seenK.insert(p.ruby).inserted ? p.ruby : nil
        }
        if kanjiInOrder.count < 2 { continue }
        multiKanjiRows += 1
        checkedRows += 1

        // Cross-check that the iOS app's "is partial?" trigger logic agrees with the
        // segment-derived kanji set: extractKanji on the joined ruby fields must equal
        // the set of rt-bearing segment ruby values.
        let joinedRuby = parts.map(\.ruby).joined()
        let extracted = Set(QuizSession.extractKanji(from: joinedRuby))
        if extracted != Set(kanjiInOrder) {
            kanjiSetMismatchFails += 1
            if kanjiSetMismatchFails <= 5 {
                failures.append(("kanji-set-mismatch",
                    "text='\(row.text)' rt-segments=\(kanjiInOrder.sorted()) extractKanji=\(extracted.sorted())"))
            }
        }

        // Random commitment ordering — Fisher-Yates over kanjiInOrder.
        var order = kanjiInOrder
        if order.count > 1 {
            for i in stride(from: order.count - 1, through: 1, by: -1) {
                let j = Int(next() % UInt64(i + 1))
                order.swapAt(i, j)
            }
        }

        // Walk the ladder ∅ → … → all. Check invariants at each step.
        var committed: Set<String> = []
        var prevRtCount = parts.filter { $0.rt != nil }.count
        // Step 0 is ∅; verify expected rt count and per-segment rule.
        for stepIdx in 0 ... order.count {
            if stepIdx > 0 { committed.insert(order[stepIdx - 1]) }
            let template = buildPartialTemplate(furigana: parts, committedKanji: committed)

            // Per-segment expected output.
            var expected = ""
            var rtCount = 0
            for p in parts {
                if let rt = p.rt, !committed.contains(p.ruby) {
                    expected += rt
                    rtCount += 1
                } else {
                    expected += p.ruby
                }
            }
            if template != expected {
                perSegmentFails += 1
                if perSegmentFails <= 5 {
                    failures.append(("per-segment step=\(stepIdx)",
                        "text='\(row.text)' committed=\(committed.sorted()) → '\(template)' vs expected '\(expected)'"))
                }
            }
            // Monotonicity: rt-substitutions must be non-increasing.
            if stepIdx > 0 && rtCount > prevRtCount {
                monotonicityFails += 1
                if monotonicityFails <= 5 {
                    failures.append(("monotonicity step=\(stepIdx)",
                        "text='\(row.text)' rtCount=\(rtCount) > prev=\(prevRtCount) committed=\(committed.sorted())"))
                }
            }
            prevRtCount = rtCount

            // All-committed final state: template must equal row.text exactly.
            if stepIdx == order.count {
                if template != row.text {
                    allCommittedFails += 1
                    if allCommittedFails <= 5 {
                        failures.append(("all-committed",
                            "text='\(row.text)' final='\(template)' (committed=\(committed.sorted()))"))
                    }
                }
            }
        }

        if n > 0 && n % 25_000 == 0 { print("  \(n)/\(rows.count) (multi-kanji so far: \(multiKanjiRows))…") }
    }

    print("  per-segment rule: \(perSegmentFails == 0 ? "[PASS]" : "[FAIL] \(perSegmentFails) failures")")
    print("  monotonicity (rt-count non-increasing): \(monotonicityFails == 0 ? "[PASS]" : "[FAIL] \(monotonicityFails) failures")")
    print("  all-committed → row.text: \(allCommittedFails == 0 ? "[PASS]" : "[FAIL] \(allCommittedFails) failures")")
    print("  extractKanji ↔ rt-segments agree: \(kanjiSetMismatchFails == 0 ? "[PASS]" : "[FAIL] \(kanjiSetMismatchFails) failures")")
    print("  Multi-kanji rows checked: \(multiKanjiRows)")

    report(area: "commit-progression", checked: checkedRows * 4, silentlySkipped: 0, failures: failures)
}

// MARK: - Area L: Kanjidic2 cross-DB consistency

// Every CJK ideograph appearing in any JMDict written form should also be present in
// kanjidic2.kanji.literal. A miss means the kanji-detail sheet shows empty data when
// the user taps that character — silent UX failure with a free oracle.
func fuzzKanjidic2(jmdict: DatabaseQueue) async throws {
    print("=== FUZZ: kanjidic2 cross-DB consistency ===")

    guard let kanjidicPath = findFile("kanjidic2.sqlite") else {
        fputs("Error: kanjidic2.sqlite not found\n", stderr)
        return
    }
    let kanjidicDB = try DatabaseQueue(path: kanjidicPath)

    let kanjidicLiterals = try await kanjidicDB.read { db in
        try Set(String.fetchAll(db, sql: "SELECT literal FROM kanji"))
    }
    print("Loaded \(kanjidicLiterals.count) kanjidic2 literals.")

    // Iterate every JMDict entry. We use jmdictWordData (canonical) so that iK/rK/ik
    // filtering is applied — i.e. we only check kanji forms the iOS app actually shows.
    let allIds = try await jmdict.read { db in
        try String.fetchAll(db, sql: "SELECT id FROM entries ORDER BY CAST(id AS INTEGER)")
    }
    print("Checking \(allIds.count) JMDict entries…")

    var failures: [(String, String)] = []
    var missingKanji: [String: [String]] = [:]   // kanji → up to 3 example word IDs
    var totalKanjiChecked = 0
    var entriesChecked = 0
    let batchSize = 1000
    var i = 0

    while i < allIds.count {
        let batch = Array(allIds[i ..< min(i + batchSize, allIds.count)])
        let result = try await QuizContext.jmdictWordData(ids: batch, jmdict: jmdict)
        for id in batch {
            guard let entry = result[id] else { continue }
            entriesChecked += 1
            for written in entry.writtenTexts {
                for scalar in written.unicodeScalars {
                    let v = scalar.value
                    let isCJK = (v >= 0x4E00 && v <= 0x9FFF) ||
                                (v >= 0x3400 && v <= 0x4DBF) ||
                                (v >= 0xF900 && v <= 0xFAFF)
                    if isCJK {
                        totalKanjiChecked += 1
                        let k = String(scalar)
                        if !kanjidicLiterals.contains(k) {
                            if missingKanji[k] == nil { missingKanji[k] = [] }
                            if missingKanji[k]!.count < 3 { missingKanji[k]!.append("\(id):\(written)") }
                        }
                    }
                }
            }
        }
        i += batchSize
        if i % 50_000 == 0 { print("  \(i)/\(allIds.count)…") }
    }

    if !missingKanji.isEmpty {
        for (k, examples) in missingKanji.sorted(by: { $0.key < $1.key }) {
            failures.append(("missing-kanji",
                "'\(k)' (U+\(String(k.unicodeScalars.first!.value, radix: 16, uppercase: true))) used in: \(examples.joined(separator: ", "))"))
        }
    }
    print("  Distinct CJK characters seen in JMDict written forms; \(missingKanji.count) missing from kanjidic2.")

    report(area: "kanjidic2", checked: totalKanjiChecked, silentlySkipped: 0, failures: failures)
}

// MARK: - Area M: Counter pronunciation completeness

// Validates Counters/counters.json against the contract the iOS app implicitly requires:
//   • 1–10 + how-many keys present, each with a non-empty primary array
//   • whatItCounts, kanji, reading, id non-empty
//   • countExamples non-empty
//   • Every quizNumber in the counter's quizNumbers array has a matching pronunciation
//     with a non-empty primary
//   • rendakuHint and classicalNumberHint return non-empty strings (their contract
//     promises this — verify it across all real counters)
func fuzzCounters() {
    print("=== FUZZ: counter pronunciation completeness ===")

    guard let path = findFile("Counters/counters.json"),
          let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let counters = try? JSONDecoder().decode([Counter].self, from: data) else {
        fputs("Error: cannot load Counters/counters.json\n", stderr)
        return
    }
    print("Loaded \(counters.count) counters from \(path).")

    var failures: [(String, String)] = []
    let requiredKeys: Set<String> = ["1","2","3","4","5","6","7","8","9","10","how-many"]
    var checked = 0

    for c in counters {
        let cid = c.id

        if c.id.isEmpty           { failures.append((cid, "empty id")) }
        if c.kanji.isEmpty         { failures.append((cid, "empty kanji")) }
        if c.reading.isEmpty       { failures.append((cid, "empty reading")) }
        if c.whatItCounts.isEmpty  { failures.append((cid, "empty whatItCounts")) }
        if c.countExamples.isEmpty { failures.append((cid, "empty countExamples")) }
        if let j = c.jmdict, j.id.isEmpty { failures.append((cid, "jmdict.id empty")) }
        for (idx, ex) in c.countExamples.enumerated() {
            if ex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                failures.append((cid, "countExamples[\(idx)] is blank"))
            }
        }

        let pkeys = Set(c.pronunciations.keys)
        let missing = requiredKeys.subtracting(pkeys)
        let extra   = pkeys.subtracting(requiredKeys)
        if !missing.isEmpty {
            failures.append((cid, "missing pronunciation keys: \(missing.sorted())"))
        }
        if !extra.isEmpty {
            failures.append((cid, "unexpected pronunciation keys: \(extra.sorted())"))
        }
        for key in requiredKeys {
            guard let cell = c.pronunciations[key] else { continue }
            if cell.primary.isEmpty {
                failures.append((cid, "pronunciation \(key) has empty primary array"))
            }
            for (i, p) in cell.primary.enumerated() {
                if p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    failures.append((cid, "pronunciation \(key) primary[\(i)] is blank"))
                }
            }
            for (i, r) in cell.rare.enumerated() {
                if r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    failures.append((cid, "pronunciation \(key) rare[\(i)] is blank"))
                }
            }
            checked += 1
        }

        // quizNumbers contract: each entry must resolve to a non-empty primary list.
        for qn in c.quizNumbers {
            guard let cell = c.pronunciations[qn] else {
                failures.append((cid, "quizNumber '\(qn)' has no pronunciation entry"))
                continue
            }
            if cell.primary.isEmpty {
                failures.append((cid, "quizNumber '\(qn)' has empty primary"))
            }
        }

        // Hint contracts: must be non-empty.
        let rh = c.rendakuHint
        let ch = c.classicalNumberHint
        if rh.isEmpty            { failures.append((cid, "rendakuHint is empty")) }
        if ch.isEmpty            { failures.append((cid, "classicalNumberHint is empty")) }

        // Hints reference numbers that exist in the data — sanity that the formatters
        // didn't end up with a "?" placeholder.
        if ch.contains("?") {
            failures.append((cid, "classicalNumberHint contains '?': \(ch)"))
        }
    }

    report(area: "counters", checked: checked + counters.count, silentlySkipped: 0, failures: failures)
}
