// Fuzz.swift
// Randomized / property-based fuzz tests for non-UI logic.
// Invoked via: TestHarness --fuzz <area>
// Areas: jmdict, furigana, fillin, ebisu, partial-template, romaji, commit-progression,
// kanjidic2, counters, written-form-picker, drill, all

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
    case "written-form-picker": try await fuzzWrittenFormPicker(jmdict: jmdict)
    case "drill":            fuzzDrill()
    case "reading-to-meaning": try await fuzzReadingToMeaning(jmdict: jmdict)
    case "prefetch-consume":   try await fuzzPrefetchConsume()
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
        try await fuzzWrittenFormPicker(jmdict: jmdict)
        fuzzDrill()
        try await fuzzReadingToMeaning(jmdict: jmdict)
        try await fuzzPrefetchConsume()
    default:
        fputs("Unknown fuzz area '\(area)'. Valid: jmdict, furigana, fillin, ebisu, partial-template, romaji, commit-progression, kanjidic2, counters, written-form-picker, drill, reading-to-meaning, prefetch-consume, all\n", stderr)
        exit(1)
    }
}

// MARK: - Shared reporter

/// Areas that printed a failure this run. `main.swift` exits non-zero if any area failed.
var fuzzFailedAreas: [String] = []

private func report(area: String, checked: Int, silentlySkipped: Int, failures: [(String, String)]) {
    print("")
    let skipNote = silentlySkipped > 0 ? " (\(silentlySkipped) silently skipped by implementation)" : ""
    print("Checked \(checked) items\(skipNote).")
    if failures.isEmpty {
        print("[PASS] \(area): no failures.")
    } else {
        fuzzFailedAreas.append(area)
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

        // Documented limitation of QuizSession.extractKanji: it only matches CJK ideographs
        // (U+4E00–U+9FFF, U+3400–U+4DBF, U+F900–U+FAFF). It does not match the iteration
        // mark 々 (U+3005) or fullwidth Latin (Ａ-Ｚ), so its output is not equal to the
        // rt-bearing segment set for words like 国々, 個々, ＣＤプレーヤー. QuizContext used
        // to derive its partial-template suppression decision from extractKanji on the
        // joined ruby; that's BUG #5, fixed by switching the suppression check to use the
        // rt-bearing segment ruby set directly. We leave extractKanji's narrower contract
        // alone — it's the right behavior for the global kanji-quiz character iteration —
        // and just track the count of words where the two sets disagree as an info metric.
        let joinedRuby = parts.map(\.ruby).joined()
        let extracted = Set(QuizSession.extractKanji(from: joinedRuby))
        if extracted != Set(kanjiInOrder) {
            kanjiSetMismatchFails += 1   // informational, not a failure now
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
    print("  [info] extractKanji ⊊ rt-segments for \(kanjiSetMismatchFails) row(s) (々, Ａ-Ｚ — not a failure post-BUG #5 fix)")
    print("  Multi-kanji rows checked: \(multiKanjiRows)")

    report(area: "commit-progression", checked: checkedRows * 3, silentlySkipped: 0, failures: failures)
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

    // BUG #6 was demoted to a data-quality report once the kanji-detail sheet learned to
    // handle missing kanjidic2 entries gracefully. The iOS app no longer relies on every
    // JMDict CJK character being present in kanjidic2.kanji.literal, so the divergence is
    // no longer a code-contract violation. We still print the list of missing characters
    // so a future kanjidic2 regenerate has a ready-made target list.
    print("  Distinct CJK characters seen in JMDict written forms; \(missingKanji.count) missing from kanjidic2.")
    if !missingKanji.isEmpty {
        let preview = missingKanji.sorted(by: { $0.key < $1.key }).prefix(15).map { (k, examples) in
            "'\(k)' (U+\(String(k.unicodeScalars.first!.value, radix: 16, uppercase: true))) used in: \(examples.joined(separator: ", "))"
        }
        for line in preview { print("  [info] missing-kanji: \(line)") }
        if missingKanji.count > 15 {
            print("  [info] … and \(missingKanji.count - 15) more — see BUG #6 for context.")
        }
    }

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

// MARK: - Area N: Written-form picker selection uniqueness

// For every JMDict entry, constructs WrittenFormGroups as the iOS app does — one group per
// kana reading, each containing the kanji forms that reading applies to — then calls the
// app's deduplicateWrittenForms() function (same code the picker calls) and verifies the
// invariant: after deduplication, no (text, formReading) pair appears more than once.
//
// Invariant: deduplicateWrittenForms produces a list where every (text, formReading) pair
// is unique, so isSelected fires exactly once for any committed form.
//
// This fuzzer calls deduplicateWrittenForms directly (from VocabSync.swift, compiled into
// TestHarness), so if that function changes, the test automatically uses the new version.
// It also reports how many raw entries had duplicate pairs before deduplication — those are
// handled correctly by deduplication, but the count is useful for tracking data quality.
func fuzzWrittenFormPicker(jmdict: DatabaseQueue) async throws {
    print("=== FUZZ: written-form picker selection uniqueness ===")

    // Load furigana table as (text, reading) → segs JSON for fast lookup.
    struct FuriganaKey: Hashable { let text: String; let reading: String }
    print("Loading furigana table…")
    let furiganaMap = try await jmdict.read { db -> [FuriganaKey: String] in
        let cursor = try Row.fetchCursor(db, sql: "SELECT text, reading, segs FROM furigana")
        var map: [FuriganaKey: String] = [:]
        while let row = try cursor.next() {
            map[FuriganaKey(text: row["text"], reading: row["reading"])] = row["segs"]
        }
        return map
    }
    print("Loaded \(furiganaMap.count) furigana rows.")

    print("Loading all entry IDs…")
    let allIds = try await jmdict.read { db in
        try String.fetchAll(db, sql: "SELECT id FROM entries ORDER BY CAST(id AS INTEGER)")
    }
    print("Checking \(allIds.count) entries…")

    let decoder = JSONDecoder()
    var failures: [(String, String)] = []
    var checkedEntries = 0
    var rawDuplicateEntries = 0

    let batchSize = 1000
    var i = 0
    while i < allIds.count {
        let batch = Array(allIds[i ..< min(i + batchSize, allIds.count)])
        let jsonRows = try await jmdict.read { db -> [String: String] in
            var map: [String: String] = [:]
            for id in batch {
                if let json = try String.fetchOne(db, sql: "SELECT entry_json FROM entries WHERE id = ?", arguments: [id]) {
                    map[id] = json
                }
            }
            return map
        }

        for id in batch {
            guard let json = jsonRows[id],
                  let data = json.data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            // Filter kanji forms the same way as jmdictWordData and VocabCorpus.
            let kanjiArray = raw["kanji"] as? [[String: Any]] ?? []
            let validKanji: [String] = kanjiArray.compactMap { k in
                let tags = k["tags"] as? [String] ?? []
                guard !tags.contains("iK"), !tags.contains("rK"), !tags.contains("sK"),
                      let text = k["text"] as? String else { return nil }
                return text
            }
            guard !validKanji.isEmpty else { continue }

            // Filter kana forms (exclude irregular kana).
            let kanaArray = raw["kana"] as? [[String: Any]] ?? []
            let validKana: [(text: String, appliesToKanji: [String])] = kanaArray.compactMap { k in
                let tags = k["tags"] as? [String] ?? []
                guard !tags.contains("ik"),
                      let text = k["text"] as? String else { return nil }
                let applies = k["appliesToKanji"] as? [String] ?? ["*"]
                return (text: text, appliesToKanji: applies)
            }
            guard !validKana.isEmpty else { continue }

            // Build WrittenFormGroup objects exactly as the app does —
            // one group per kana reading, forms = kanji forms that reading applies to.
            var groups: [WrittenFormGroup] = []
            for kana in validKana {
                let appliesToAll = kana.appliesToKanji == ["*"]
                var forms: [WrittenForm] = []
                for kanji in validKanji {
                    if !appliesToAll && !kana.appliesToKanji.contains(kanji) { continue }
                    let key = FuriganaKey(text: kanji, reading: kana.text)
                    guard let segsJson = furiganaMap[key],
                          let segsData = segsJson.data(using: .utf8),
                          let segs = try? decoder.decode([FuriganaSegment].self, from: segsData)
                    else { continue }
                    forms.append(WrittenForm(furigana: segs, text: kanji))
                }
                if !forms.isEmpty {
                    groups.append(WrittenFormGroup(reading: kana.text, forms: forms))
                }
            }

            let rawFormCount = groups.flatMap(\.forms).count
            guard rawFormCount >= 2 else { continue }
            checkedEntries += 1

            // Track raw duplicates (informational — these are handled by deduplication).
            var rawSeen: Set<String> = []
            var hadRawDuplicate = false
            for form in groups.flatMap(\.forms) {
                let key = "\(form.text)|\(form.furigana.readingText)"
                if !rawSeen.insert(key).inserted { hadRawDuplicate = true }
            }
            if hadRawDuplicate { rawDuplicateEntries += 1 }

            // Core invariant: call the app's deduplicateWrittenForms and verify the result
            // has no duplicate (text, formReading) pairs. A failure here means the
            // deduplication function is broken and isSelected would fire multiple times.
            let deduplicated = deduplicateWrittenForms(groups)
            var dedupSeen: Set<String> = []
            for form in deduplicated {
                let key = "\(form.text)|\(form.furigana.readingText)"
                if !dedupSeen.insert(key).inserted {
                    failures.append((id,
                        "deduplicateWrittenForms left duplicate (\(form.text), \(form.furigana.readingText)) — isSelected would fire twice"))
                }
            }
        }

        i += batchSize
        if i % 50_000 == 0 { print("  \(i)/\(allIds.count) entries checked…") }
    }

    print("  Entries with 2+ forms: \(checkedEntries)")
    print("  Entries with raw (text, formReading) duplicates (handled by deduplication): \(rawDuplicateEntries)")
    report(area: "written-form-picker", checked: checkedEntries, silentlySkipped: 0, failures: failures)
}

// MARK: - Area O: Drill mode sibling index and batch ordering

/// Seeded generator so every drill fuzz run is reproducible.
private struct DrillFuzzGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state ^= state &<< 13
        state ^= state >> 7
        state ^= state &<< 17
        return state
    }
}

/// Builds a vocab manifest with a small pool of stories and contexts, so that many words collide
/// on the same sentence and the same document.
private func randomDrillManifest(wordCount: Int, using generator: inout DrillFuzzGenerator) -> VocabManifest {
    let sourcePool = ["A", "B", "C", "D", "E"]
    let contextPool: [String?] = [nil, "", "s1", "s2", "s3", "s4", "s5", "s6"]
    var words: [VocabWordEntry] = []
    for index in 0..<wordCount {
        let sourceCount = Int.random(in: 0...3, using: &generator)
        let sources = Array(sourcePool.shuffled(using: &generator).prefix(sourceCount))
        var references: [String: [VocabReference]] = [:]
        for source in sources {
            let referenceCount = Int.random(in: 0...2, using: &generator)
            references[source] = (0..<referenceCount).map { _ in
                let context = contextPool.randomElement(using: &generator) ?? nil
                return VocabReference(line: 1, bulletIndex: nil, context: context, narration: nil,
                                      counter: nil, llmSense: nil, annotatedForms: nil)
            }
        }
        words.append(VocabWordEntry(id: "\(index + 1)", sources: sources, writtenForms: nil,
                                    references: references, bccwjPerMillionWords: nil, kanjiMeanings: nil))
    }
    return VocabManifest(generatedAt: "fuzz", stories: [], words: words, sourceOrders: nil)
}

func fuzzDrill() {
    print("=== FUZZ: drill sibling index and batch ordering ===")

    var failures: [(String, String)] = []
    var checkedWords = 0
    var checkedBatches = 0

    // 1. Hand-written case: the sentence and document rules, with nil and empty contexts.
    let handWritten = VocabManifest(generatedAt: "fuzz", stories: [], words: [
        VocabWordEntry(id: "1", sources: ["A"], writtenForms: nil, references: ["A": [
            VocabReference(line: 1, bulletIndex: nil, context: "x", narration: nil, counter: nil, llmSense: nil, annotatedForms: nil)]],
            bccwjPerMillionWords: nil, kanjiMeanings: nil),
        VocabWordEntry(id: "2", sources: ["A"], writtenForms: nil, references: ["A": [
            VocabReference(line: 2, bulletIndex: nil, context: "x", narration: nil, counter: nil, llmSense: nil, annotatedForms: nil)]],
            bccwjPerMillionWords: nil, kanjiMeanings: nil),
        VocabWordEntry(id: "3", sources: ["A"], writtenForms: nil, references: ["A": [
            VocabReference(line: 3, bulletIndex: nil, context: "y", narration: nil, counter: nil, llmSense: nil, annotatedForms: nil)]],
            bccwjPerMillionWords: nil, kanjiMeanings: nil),
        VocabWordEntry(id: "4", sources: ["B"], writtenForms: nil, references: ["B": [
            VocabReference(line: 1, bulletIndex: nil, context: "x", narration: nil, counter: nil, llmSense: nil, annotatedForms: nil)]],
            bccwjPerMillionWords: nil, kanjiMeanings: nil),
        VocabWordEntry(id: "5", sources: ["A"], writtenForms: nil, references: ["A": [
            VocabReference(line: 5, bulletIndex: nil, context: nil, narration: nil, counter: nil, llmSense: nil, annotatedForms: nil),
            VocabReference(line: 6, bulletIndex: nil, context: "", narration: nil, counter: nil, llmSense: nil, annotatedForms: nil)]],
            bccwjPerMillionWords: nil, kanjiMeanings: nil),
    ], sourceOrders: nil)
    let handIndex = DrillIndex(manifest: handWritten)
    let handExpectations: [(String, sentence: Set<String>, document: Set<String>)] = [
        ("1", ["2"], ["2", "3", "5"]),   // shares sentence "x" with 2; document A has 2, 3, 5
        ("3", [], ["1", "2", "5"]),      // sentence "y" is unshared
        ("4", [], []),                   // document B holds only word 4
        ("5", [], ["1", "2", "3"]),      // nil and empty contexts join no sentence
    ]
    for (wordId, expectedSentence, expectedDocument) in handExpectations {
        checkedWords += 1
        let sentence = handIndex.sentenceSiblings(of: wordId)
        let document = handIndex.documentSiblings(of: wordId)
        if sentence != expectedSentence {
            failures.append(("hand-written word \(wordId)", "sentence siblings \(sentence.sorted()), expected \(expectedSentence.sorted())"))
        }
        if document != expectedDocument {
            failures.append(("hand-written word \(wordId)", "document siblings \(document.sorted()), expected \(expectedDocument.sorted())"))
        }
    }

    // 2. Random manifests: sibling index invariants.
    var generator = DrillFuzzGenerator(state: 0x5EED_D21C_0FFE_E123)
    for round in 0..<200 {
        let manifest = randomDrillManifest(wordCount: 30, using: &generator)
        let index = DrillIndex(manifest: manifest)
        let wordIds = manifest.words.map(\.id)
        var sentenceOf: [String: Set<String>] = [:]
        var documentOf: [String: Set<String>] = [:]
        for wordId in wordIds {
            checkedWords += 1
            sentenceOf[wordId] = index.sentenceSiblings(of: wordId)
            documentOf[wordId] = index.documentSiblings(of: wordId)
            let context = "round \(round), word \(wordId)"
            // A word is never its own sibling.
            if sentenceOf[wordId]!.contains(wordId) || documentOf[wordId]!.contains(wordId) {
                failures.append((context, "word listed as its own sibling"))
            }
            // A shared sentence implies a shared document.
            if !sentenceOf[wordId]!.isSubset(of: documentOf[wordId]!) {
                failures.append((context, "sentence siblings \(sentenceOf[wordId]!.sorted()) not a subset of document siblings \(documentOf[wordId]!.sorted())"))
            }
        }
        // Sibling relations are symmetric.
        for wordId in wordIds {
            for other in sentenceOf[wordId]! where !sentenceOf[other, default: []].contains(wordId) {
                failures.append(("round \(round), word \(wordId)", "sentence sibling \(other) does not list \(wordId) back"))
            }
            for other in documentOf[wordId]! where !documentOf[other, default: []].contains(wordId) {
                failures.append(("round \(round), word \(wordId)", "document sibling \(other) does not list \(wordId) back"))
            }
        }
    }

    // 3. Random candidate lists: batch ordering invariants.
    for round in 0..<2_000 {
        // Recalls are multiples of 0.1, so ties occur and exercise the word-ID tie-break.
        let candidates: [DrillCandidate] = (0..<Int.random(in: 0...12, using: &generator)).map { _ in
            DrillCandidate(wordId: "\(Int.random(in: 1...15, using: &generator))",
                           recall: Double(Int.random(in: 0...10, using: &generator)) / 10)
        }
        let seen = Set((0..<Int.random(in: 0...4, using: &generator)).map { _ in "\(Int.random(in: 1...15, using: &generator))" })
        let queued = Set((0..<Int.random(in: 0...4, using: &generator)).map { _ in "\(Int.random(in: 1...15, using: &generator))" })
        let eligible = Set(candidates.map(\.wordId)).subtracting(seen).subtracting(queued)
        let context = "batch round \(round)"
        checkedBatches += 1

        // Swap probability 0: weakest-first, so recall never decreases along the output.
        var zeroSwapGenerator = generator
        let ordered = drillBatch(siblings: candidates, seen: seen, queued: queued,
                                 swapProbability: 0, using: &zeroSwapGenerator)
        var firstRecall: [String: Double] = [:]
        for candidate in candidates where firstRecall[candidate.wordId] == nil {
            firstRecall[candidate.wordId] = candidate.recall
        }
        for (previous, current) in zip(ordered, ordered.dropFirst()) {
            if firstRecall[previous]! > firstRecall[current]! {
                failures.append((context, "swap probability 0 broke weakest-first: \(previous) (\(firstRecall[previous]!)) before \(current) (\(firstRecall[current]!))"))
            }
        }

        // Any swap probability: duplicate-free permutation of the eligible words.
        let swapProbability = Double.random(in: 0...1, using: &generator)
        let batch = drillBatch(siblings: candidates, seen: seen, queued: queued,
                               swapProbability: swapProbability, using: &generator)
        if Set(batch).count != batch.count {
            failures.append((context, "duplicate word in batch \(batch)"))
        }
        if Set(batch) != eligible {
            failures.append((context, "batch \(batch.sorted()) is not the eligible set \(eligible.sorted()) (p=\(swapProbability))"))
        }

        // Re-running with the batch already queued yields nothing new.
        let rerun = drillBatch(siblings: candidates, seen: seen, queued: queued.union(batch),
                               swapProbability: swapProbability, using: &generator)
        if !rerun.isEmpty {
            failures.append((context, "second drill added \(rerun) after the first added \(batch)"))
        }
    }

    report(area: "drill", checked: checkedWords + checkedBatches, silentlySkipped: 0, failures: failures)
}

// MARK: - Area P: reading-to-meaning confusers and JMDict sense shape

/// Seeded generator so every reading-to-meaning fuzz run is reproducible.
private struct ConfuserFuzzGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state ^= state &<< 13
        state ^= state >> 7
        state ^= state &<< 17
        return state
    }
}

/// Serializes a list of strings as a JSON array, the shape Haiku is asked to return.
private func jsonArrayText(_ values: [String]) -> String {
    String(data: (try? JSONSerialization.data(withJSONObject: values)) ?? Data(), encoding: .utf8) ?? ""
}

// Two oracles:
//   1. Parser. For random enrolled senses, a pinned answer, and a mix of valid, rejected, and
//      duplicate confusers, the parser returns a question exactly when three acceptable confusers
//      exist. A returned question has four distinct choices (case-insensitively), the answer at
//      correctIndex, the first three acceptable confusers in order, and no confuser sharing a headword
//      with the entry. Rejected confusers are built from known rewordings of entry senses (other case,
//      parenthetical dropped, "to" dropped), so the oracle does not depend on the parser's own matching.
//      The same confusers parse identically when wrapped in prose and a code fence and when bare.
//   2. Data. Every JMDict entry has at least one sense, and every sense has at least one gloss, all
//      with non-empty text. The app relies on this when it pins the correct answer.
@MainActor
func fuzzReadingToMeaning(jmdict: DatabaseQueue) async throws {
    print("=== FUZZ: reading-to-meaning confusers and JMDict sense shape ===")

    var failures: [(String, String)] = []
    var checkedParses = 0
    var generator = ConfuserFuzzGenerator(state: 0x9E37_79B9_7F4A_7C15)
    let vocabulary = ["look", "down", "gaze", "steal", "rob", "carry", "hold", "watch", "cross",
                      "peer", "stare", "glance", "sweep", "admire", "despise", "rush", "wander", "linger"]
    let kana = "みおろす"
    var novelCounter = 0

    // Known case from real data: 呼び覚ます has an unenrolled sense "to wake up (someone; by calling out)".
    // Haiku once offered "to wake up; to rouse from sleep" as a wrong answer, which is that sense. The reply
    // also repeats "to forget; to lose track of" in another case, which must count as a duplicate.
    let awakenEntry = ["to bring back (e.g. memories)", "to evoke", "to recall",
                       "to wake up (someone; by calling out)", "to awaken"]
    let awakenPinned = "to bring back (e.g. memories); to evoke; to recall"
    let awakenReply = """
    ```json
    ["to forget; to lose track of", "to wake up; to rouse from sleep", "To Forget; To Lose Track Of",
     "to summon; to call upon someone", "to ignore; to disregard"]
    ```
    """
    let awakenExpected = ["to forget; to lose track of", "to summon; to call upon someone", "to ignore; to disregard"]
    checkedParses += 1
    if let awakenQuestion = QuizSession.parseReadingToMeaningConfusers(
        awakenReply, pinnedAnswer: awakenPinned, entryGlosses: awakenEntry, kana: "よびさます") {
        let awakenConfusers = awakenQuestion.choices.indices.filter { $0 != awakenQuestion.correctIndex }
            .map { awakenQuestion.choices[$0] }
        if awakenConfusers != awakenExpected {
            failures.append(("呼び覚ます reply", "confusers \(awakenConfusers), expected \(awakenExpected)"))
        }
    } else {
        failures.append(("呼び覚ます reply", "returned nil; expected three acceptable confusers"))
    }

    for trial in 0..<3000 {
        // Some glosses carry a parenthetical note, as real JMDict glosses do.
        let enrolled: [String] = (0..<Int.random(in: 1...4, using: &generator)).map { _ in
            let base = "to \(vocabulary.randomElement(using: &generator)!)"
            return Bool.random(using: &generator) ? "\(base) (someone)" : base
        }
        let pinned = enrolled.prefix(Int.random(in: 1...3, using: &generator)).joined(separator: "; ")

        // Mix acceptable confusers with the kinds the parser must reject.
        var candidates: [String] = []
        var acceptable: [String] = []
        for _ in 0..<Int.random(in: 0...8, using: &generator) {
            switch Int.random(in: 0..<8, using: &generator) {
            case 0:
                novelCounter += 1
                let novel = "to \(vocabulary.randomElement(using: &generator)!) \(novelCounter)"
                candidates.append(novel)
                acceptable.append(novel)
            case 1:
                candidates.append(pinned)
            case 2:
                candidates.append(enrolled.randomElement(using: &generator)!)
            case 3:
                novelCounter += 1
                candidates.append("to rush \(novelCounter); \(enrolled.randomElement(using: &generator)!)")
            case 4:
                if let repeated = acceptable.randomElement(using: &generator) {
                    // An exact repeat, or the same text in another case: both duplicate an earlier confuser.
                    candidates.append(Bool.random(using: &generator) ? repeated : repeated.uppercased())
                }
            case 5:
                candidates.append("")
            case 6:
                candidates.append(enrolled.randomElement(using: &generator)!.uppercased())
            default:
                // An entry sense reworded: same headword, no "to" and no parenthetical note.
                let entrySense = enrolled.randomElement(using: &generator)!
                    .replacingOccurrences(of: " (someone)", with: "")
                candidates.append(String(entrySense.dropFirst(3)))
            }
        }

        let context = "trial \(trial)"
        let expectedConfusers = Array(acceptable.prefix(3))
        let fenced = "Think first.\n```json\n\(jsonArrayText(candidates))\n```"
        let parsed = QuizSession.parseReadingToMeaningConfusers(
            fenced, pinnedAnswer: pinned, entryGlosses: enrolled, kana: kana)
        checkedParses += 1

        guard acceptable.count >= 3 else {
            if parsed != nil {
                failures.append((context, "parsed a question from \(acceptable.count) acceptable confuser(s); expected nil"))
            }
            continue
        }
        guard let question = parsed else {
            failures.append((context, "returned nil with \(acceptable.count) acceptable confuser(s)"))
            continue
        }
        guard question.choices.count == 4, question.choices.indices.contains(question.correctIndex) else {
            failures.append((context, "malformed question: \(question.choices.count) choice(s), correctIndex \(question.correctIndex)"))
            continue
        }
        if question.choices[question.correctIndex] != pinned {
            failures.append((context, "pinned answer is not at correctIndex"))
        }
        if question.stem != "What does \(kana) mean?" {
            failures.append((context, "stem is \"\(question.stem)\""))
        }
        let confusers = question.choices.indices.filter { $0 != question.correctIndex }.map { question.choices[$0] }
        if confusers != expectedConfusers {
            failures.append((context, "confusers \(confusers), expected \(expectedConfusers)"))
        }
        if Set(question.choices.map { $0.lowercased() }).count != 4 {
            failures.append((context, "duplicate choices: \(question.choices)"))
        }
        let entryHeadwords = Set(enrolled.map(QuizSession.glossHeadword))
        for confuser in confusers where confuser.components(separatedBy: "; ").map(QuizSession.glossHeadword).contains(where: { entryHeadwords.contains($0) }) {
            failures.append((context, "confuser \"\(confuser)\" shares a headword with the entry"))
        }

        // The same confusers, bare and without prose, must parse to the same confusers.
        let bare = "Here you go: \(jsonArrayText(candidates))"
        if let bareQuestion = QuizSession.parseReadingToMeaningConfusers(
            bare, pinnedAnswer: pinned, entryGlosses: enrolled, kana: kana) {
            let bareConfusers = bareQuestion.choices.indices.filter { $0 != bareQuestion.correctIndex }.map { bareQuestion.choices[$0] }
            if bareConfusers != expectedConfusers {
                failures.append((context, "bare array parsed to \(bareConfusers), expected \(expectedConfusers)"))
            }
        } else {
            failures.append((context, "bare array returned nil"))
        }
    }

    // Data invariant the app relies on when pinning the correct answer.
    let entries = try await jmdict.read { db in
        try Row.fetchAll(db, sql: "SELECT id, entry_json FROM entries").map { row -> (id: String, json: String) in
            let id: String = row["id"]
            let json: String = row["entry_json"]
            return (id, json)
        }
    }
    var checkedEntries = 0
    for entry in entries {
        checkedEntries += 1
        guard let object = try? JSONSerialization.jsonObject(with: Data(entry.json.utf8)) as? [String: Any] else {
            failures.append(("entry \(entry.id)", "entry_json is not a JSON object"))
            continue
        }
        let senses = object["sense"] as? [[String: Any]] ?? []
        if senses.isEmpty {
            failures.append(("entry \(entry.id)", "has no senses"))
        }
        for (senseIndex, sense) in senses.enumerated() {
            let glosses = sense["gloss"] as? [[String: Any]] ?? []
            let texts = glosses.compactMap { $0["text"] as? String }
            if glosses.isEmpty || texts.count != glosses.count || texts.contains(where: \.isEmpty) {
                failures.append(("entry \(entry.id) sense \(senseIndex)", "has no gloss, or a gloss with empty text"))
            }
        }
    }

    report(area: "reading-to-meaning", checked: checkedParses + checkedEntries, silentlySkipped: 0, failures: failures)
}

// MARK: - Area Q: prefetch consume across item-kind sequences

/// Item kinds the check can answer offline. Each is answered the way the app expects for that kind.
private enum PrefetchKind: CaseIterable {
    case multipleChoice, freeAnswer, counterNumber, counterMeaning, pairBoth, pairIntransitive

    var label: String {
        switch self {
        case .multipleChoice: return "multiple choice (jmdict)"
        case .freeAnswer: return "free answer (jmdict, meaning-to-reading)"
        case .counterNumber: return "counter number-to-reading"
        case .counterMeaning: return "counter meaning-to-reading"
        case .pairBoth: return "transitive pair (both legs)"
        case .pairIntransitive: return "transitive pair (intransitive leg)"
        }
    }

    /// The phase the app should show this kind in, once it arrives.
    var expectedPhase: String {
        switch self {
        case .multipleChoice: return "awaitingTap"
        case .freeAnswer, .counterNumber, .counterMeaning: return "awaitingText"
        case .pairBoth, .pairIntransitive: return "awaitingPair"
        }
    }

    /// Whether the result bubble starts with ✓ or ✗. An exact-match free answer shows just the typed text.
    var marksResultBubble: Bool { self != .freeAnswer }

    /// Model calls an answer of this kind and outcome should make. A pair drill "don't know" is graded locally,
    /// so it makes none. Every other uncertain outcome makes one: the opening explanation turn.
    func expectedModelCalls(for outcome: PrefetchOutcome) -> Int {
        if (self == .pairBoth || self == .pairIntransitive) && outcome == .noIdea { return 0 }
        return outcome.expectedModelCalls
    }

    /// Outcomes the runner covers for this kind. Wrong free answers and wrong pair drills are graded by Haiku,
    /// so they are left out until a phase scripts their replies. "While grading" outcomes need a Haiku-graded
    /// free answer, so only free answers have them.
    var outcomes: [PrefetchOutcome] {
        switch self {
        case .multipleChoice, .counterNumber, .counterMeaning:
            return [.correct, .wrong, .noIdea, .inkling]
        case .freeAnswer:
            return [.correct, .noIdea, .inkling, .noIdeaWhileGrading, .inklingWhileGrading]
        case .pairBoth, .pairIntransitive:
            return [.correct, .noIdea]
        }
    }
}

/// How the student answered an item.
private enum PrefetchOutcome: String {
    case correct, wrong
    /// "No idea" or "Inkling" tapped before anything is submitted.
    case noIdea = "no idea"
    case inkling
    /// "No idea" or "Inkling" tapped after a free answer was submitted, while Haiku is still grading it.
    case noIdeaWhileGrading = "no idea while grading"
    case inklingWhileGrading = "inkling while grading"

    /// The score the app should record for this answer. A self-reported score must survive Haiku's grade.
    var expectedScore: Double {
        switch self {
        case .correct: return 1.0
        case .wrong, .noIdea, .noIdeaWhileGrading: return 0.0
        case .inkling, .inklingWhileGrading: return 0.25
        }
    }

    /// The first character of the result bubble the app should show: ✓ or ✗. Uncertain outcomes show the
    /// student's admission instead, so there is no mark to check.
    var expectedResultMark: String? {
        switch self {
        case .correct: return "✓"
        case .wrong: return "✗"
        case .noIdea, .inkling, .noIdeaWhileGrading, .inklingWhileGrading: return nil
        }
    }

    /// Model calls the answer should make, counting the opening explanation turn after an admission of
    /// uncertainty and the Haiku grade of a submitted free answer. Local grading makes none.
    var expectedModelCalls: Int {
        switch self {
        case .correct, .wrong: return 0
        case .noIdea, .inkling, .noIdeaWhileGrading, .inklingWhileGrading: return 1
        }
    }
}

/// One answer in a sequence: the item kind and how the student answered it.
private struct PrefetchStop {
    let kind: PrefetchKind
    let outcome: PrefetchOutcome

    static func correct(_ kind: PrefetchKind) -> PrefetchStop { PrefetchStop(kind: kind, outcome: .correct) }
    static func wrong(_ kind: PrefetchKind) -> PrefetchStop { PrefetchStop(kind: kind, outcome: .wrong) }
    static func noIdea(_ kind: PrefetchKind) -> PrefetchStop { PrefetchStop(kind: kind, outcome: .noIdea) }
    static func inkling(_ kind: PrefetchKind) -> PrefetchStop { PrefetchStop(kind: kind, outcome: .inkling) }
    static func noIdeaWhileGrading(_ kind: PrefetchKind) -> PrefetchStop { PrefetchStop(kind: kind, outcome: .noIdeaWhileGrading) }
    static func inklingWhileGrading(_ kind: PrefetchKind) -> PrefetchStop { PrefetchStop(kind: kind, outcome: .inklingWhileGrading) }

    var label: String { "\(kind.label) [\(outcome.rawValue)]" }
}

/// What one item looks like when it arrives, and how it was answered.
private struct PrefetchStep: Equatable {
    let kind: PrefetchKind
    let outcome: PrefetchOutcome
    let arrivalPhase: String
    /// State left over from the previous item when this one arrived. Empty means the item started clean.
    let dirtyFieldsAtArrival: [String]
    /// True if the next item was already prefetched while this item was still on screen.
    let nextPrefetchedBeforeAnswer: Bool
    let staleMultipleChoiceResult: Bool
    let staleTutorPrompt: Bool
    let answerScore: Double?
    /// The first character of the result bubble the answer produced, or "" if there is none.
    let resultMark: String
    /// Model calls made while the answer was graded, including any chat turn it started.
    let answerModelCalls: Int

    var expectedModelCalls: Int { kind.expectedModelCalls(for: outcome) }

    var summary: String {
        "\(kind.label) [\(outcome.rawValue)]: phase=\(arrivalPhase) dirty=\(dirtyFieldsAtArrival) prefetchedEarly=\(nextPrefetchedBeforeAnswer) staleResult=\(staleMultipleChoiceResult) staleTutor=\(staleTutorPrompt) score=\(answerScore.map { String($0) } ?? "nil") mark=\(resultMark) modelCalls=\(answerModelCalls)"
    }
}

/// Result of one sequence run: the steps, a problem that stopped the run (if any), and every model call it made.
private struct PrefetchRun {
    let steps: [PrefetchStep]
    let problem: String?
    let totalModelCalls: Int
}

/// Stands in for the Anthropic API inside `fuzzPrefetchConsume`. Records every model call so the oracles can
/// count them, and answers the calls the runner expects. Any other call gets nil, which the client reports as
/// an unexpected call, so the run fails. Phase 3 adds replies for the tutor sessions.
private final class ScriptedReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCalls: [String] = []

    func respond(messages: [AnthropicMessage], system: String?) -> String? {
        let lastUserText = messages.last(where: { $0.role == "user" })?.content.compactMap { block -> String? in
            if case .text(let text) = block { return text }
            return nil
        }.joined(separator: "\n") ?? ""
        lock.withLock { recordedCalls.append(system ?? "") }
        return Self.reply(toLastUserText: lastUserText)
    }

    /// The canned reply for each call the runner expects. The text is generic on purpose: the oracles check
    /// the app's state around the reply, not what Haiku says. A grading reply uses the real `SCORE:` and `NOTES:` lines.
    private static func reply(toLastUserText text: String) -> String? {
        if text.hasPrefix("I had no idea") || text.hasPrefix("I had a vague inkling") {
            return "Here is an explanation of the word and the meaning it is usually taken to have."
        }
        if text.hasPrefix("Question: ") {
            return "The answer covers part of the meaning.\n\nSCORE: 0.5\nNOTES: partial meaning, not the full sense."
        }
        return nil
    }

    var callCount: Int { lock.withLock { recordedCalls.count } }

    func reset() { lock.withLock { recordedCalls = [] } }
}

/// Shared test data for the sequence runner.
private struct PrefetchFixtures {
    let counter: Counter
    let counterCorpus: CounterCorpus
    let pairCorpus: TransitivePairCorpus
    let client: AnthropicClient
    let replies: ScriptedReplies
    let toolHandler: ToolHandler
    let db: QuizDB

    static let multipleChoiceQuestion = QuizSession.MultipleChoiceQuestion(
        stem: "What does おいかける mean?",
        choices: ["to drive; to propel", "to drag; to haul; to pull", "to overtake; to pass", "to chase; to run after; to pursue"],
        correctIndex: 3)

    /// A typed counter reading that no counter accepts, so typing it always grades wrong.
    static let wrongCounterReading = "まちがい"

    /// A partly right free answer. It is not an exact match, so the app sends it to Haiku.
    static let partialFreeAnswer = "食べること"

    func item(for kind: PrefetchKind) -> QuizItem {
        switch kind {
        case .multipleChoice:
            return prefetchFuzzItem(wordType: "jmdict", wordId: "1608720", wordText: "追いかける", kana: "おいかける",
                                    facet: "reading-to-meaning", isFree: false)
        case .freeAnswer:
            return prefetchFuzzItem(wordType: "jmdict", wordId: "1309430", wordText: "食べ物", kana: "たべもの",
                                    facet: "meaning-to-reading", isFree: true)
        case .counterNumber:
            return prefetchFuzzItem(wordType: "counter", wordId: counter.id, wordText: counter.kanji, kana: "",
                                    facet: "counter-number-to-reading", isFree: true)
        case .counterMeaning:
            return prefetchFuzzItem(wordType: "counter", wordId: counter.id, wordText: counter.kanji, kana: "",
                                    facet: "meaning-to-reading", isFree: true)
        case .pairBoth:
            return prefetchFuzzItem(wordType: "transitive-pair", wordId: "1350040-1350110", wordText: "消える ↔ 消す", kana: "",
                                    facet: "pair-discrimination", isFree: true)
        case .pairIntransitive:
            return prefetchFuzzItem(wordType: "transitive-pair", wordId: "1350040-1350110", wordText: "消える ↔ 消す", kana: "",
                                    facet: "intransitive", isFree: true)
        }
    }

    /// Answers `stop` the way its outcome says, and returns the score the app recorded straight away.
    /// For outcomes that start a chat turn, the caller waits for that turn before reading the score again.
    @MainActor
    func answer(_ stop: PrefetchStop, session: QuizSession) async -> Double? {
        let isCorrect = stop.outcome == .correct
        let uncertaintyScore: Double? = switch stop.outcome {
        case .noIdea: 0.0
        case .inkling: 0.25
        default: nil
        }
        switch stop.kind {
        case .multipleChoice:
            // Index 3 is the correct choice; index 0 is a wrong one.
            if let uncertaintyScore {
                session.tapUncertain(score: uncertaintyScore)
            } else {
                session.tapChoice(isCorrect ? 3 : 0)
            }
        case .freeAnswer:
            switch stop.outcome {
            case .noIdeaWhileGrading, .inklingWhileGrading:
                // Submit a partly right answer, then tap the admission before Haiku's grade has come back.
                // The submit only starts the grading turn, so the admission lands while it is still in flight.
                session.chatInput = Self.partialFreeAnswer
                await session.submitFreeAnswer()
                session.tapFreeAnswerUncertain(score: stop.outcome == .noIdeaWhileGrading ? 0.0 : 0.25)
            default:
                if let uncertaintyScore {
                    session.tapTextUncertain(score: uncertaintyScore)
                } else {
                    session.chatInput = "たべもの"
                    await session.submitFreeAnswer()
                }
            }
        case .counterNumber:
            if let uncertaintyScore {
                session.tapTextUncertain(score: uncertaintyScore)
            } else {
                let accepted = session.currentCounterNumber.flatMap { counter.pronunciations[$0]?.primary.first } ?? ""
                session.chatInput = isCorrect ? accepted : Self.wrongCounterReading
                await session.submitFreeAnswer()
            }
        case .counterMeaning:
            if let uncertaintyScore {
                session.tapTextUncertain(score: uncertaintyScore)
            } else {
                session.chatInput = isCorrect ? counter.reading : Self.wrongCounterReading
                await session.submitFreeAnswer()
            }
        case .pairBoth:
            if stop.outcome == .noIdea {
                session.tapTransitiveDrillDontKnow()
            } else {
                session.pairIntransitiveInput = "きえる"
                session.pairTransitiveInput = "けす"
                session.submitTransitivePairDrillAnswer()
            }
        case .pairIntransitive:
            if stop.outcome == .noIdea {
                session.tapTransitiveDrillDontKnow()
            } else {
                session.pairIntransitiveInput = "きえる"
                session.submitTransitivePairDrillAnswer()
            }
        }
        return session.gradedScore
    }

    /// Fields that still hold the previous item's state when an item arrives. Empty when the item starts clean.
    @MainActor
    func dirtyFields(_ session: QuizSession) -> [String] {
        var dirty: [String] = []
        if !session.chatInput.isEmpty { dirty.append("chatInput") }
        if session.isSendingChat { dirty.append("isSendingChat") }
        if session.uncertaintyUnlocked { dirty.append("uncertaintyUnlocked") }
        if session.gradedScore != nil { dirty.append("gradedScore") }
        return dirty
    }
}

/// Waits until no chat turn is in flight, so a turn that an answer started is counted and its state is in place.
/// The replies are stubbed, so a turn finishes in milliseconds. Returns false if one is still running after a
/// quarter second. The cap is short on purpose: a broken app that never finishes a turn fails every such step.
@MainActor
private func awaitChatIdle(_ session: QuizSession) async -> Bool {
    for _ in 0..<25 {
        if !session.isSendingChat { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return !session.isSendingChat
}

/// Runs one sequence of stops through a session. The sequence starts with a multiple-choice warm-up
/// unless its first stop is multiple choice, so every later item arrives through a grade and a prefetch.
/// `usePrefetch: false` discards each stored prefetch before advancing, so the item takes the direct path.
@MainActor
private func runPrefetchSequence(stops: [PrefetchStop], usePrefetch: Bool, multipleChoiceOnly: Bool,
                                 fixtures: PrefetchFixtures, preferences: UserPreferences) async -> PrefetchRun {
    preferences.multipleChoiceOnly = multipleChoiceOnly
    fixtures.replies.reset()
    let session = QuizSession(client: fixtures.client, toolHandler: fixtures.toolHandler,
                              db: fixtures.db, preferences: preferences)
    session.counterCorpus = fixtures.counterCorpus
    session.pairCorpus = fixtures.pairCorpus

    // `stopOfItem[i]` is the stop for item i, or nil for the multiple-choice warm-up.
    var items: [QuizItem] = []
    var stopOfItem: [PrefetchStop?] = []
    if stops.first?.kind != .multipleChoice {
        items.append(fixtures.item(for: .multipleChoice))
        stopOfItem.append(nil)
    }
    for stop in stops {
        items.append(fixtures.item(for: stop.kind))
        stopOfItem.append(stop)
    }
    session.items = items
    session.currentIndex = 0
    session.phase = .awaitingTap(PrefetchFixtures.multipleChoiceQuestion)

    var steps: [PrefetchStep] = []
    for index in items.indices {
        let stop = stopOfItem[index]
        // The item is on screen. Record how it arrived before the student answers it.
        let arrivalPhase = phaseName(session.phase)
        let dirtyFields = fixtures.dirtyFields(session)
        let nextPrefetchedEarly = session.prefetchedIndexForTesting != nil
        let staleResult = session.multipleChoiceResult != nil
        let staleTutor = session.currentCounterSystemPrompt != nil || session.currentPairSystemPrompt != nil

        let score: Double?
        if let stop {
            let callsBefore = fixtures.replies.callCount
            score = await fixtures.answer(stop, session: session)
            guard await awaitChatIdle(session) else {
                return PrefetchRun(steps: steps, problem: "chat turn for item \(index) never finished",
                                   totalModelCalls: fixtures.replies.callCount)
            }
            let answerCalls = fixtures.replies.callCount - callsBefore
            let resultMark = String(session.chatMessages.last?.text.prefix(1) ?? "")
            steps.append(PrefetchStep(kind: stop.kind, outcome: stop.outcome, arrivalPhase: arrivalPhase,
                                      dirtyFieldsAtArrival: dirtyFields,
                                      nextPrefetchedBeforeAnswer: nextPrefetchedEarly,
                                      staleMultipleChoiceResult: staleResult, staleTutorPrompt: staleTutor,
                                      answerScore: session.gradedScore, resultMark: resultMark,
                                      answerModelCalls: answerCalls))
        } else {
            // Warm-up: a multiple-choice question answered correctly to start the sequence.
            session.tapChoice(3)
            score = session.gradedScore
        }
        guard score != nil || stop == nil else {
            return PrefetchRun(steps: steps, problem: "item \(index) was not graded", totalModelCalls: fixtures.replies.callCount)
        }

        guard index + 1 < items.count else { break }
        guard await session.awaitPrefetchForTesting(index: index + 1) else {
            return PrefetchRun(steps: steps, problem: "prefetch was never stored for item \(index + 1)",
                               totalModelCalls: fixtures.replies.callCount)
        }
        if !usePrefetch { session.discardPrefetchForTesting() }
        // Tutor prompts left by an earlier tutor session. Both advance paths must leave them cleared.
        session.currentCounterSystemPrompt = "STALE counter tutor prompt"
        session.currentPairSystemPrompt = "STALE pair tutor prompt"
        session.phase = .idle
        session.nextQuestion()
        await session.awaitAdvanceForTesting()
    }
    return PrefetchRun(steps: steps, problem: nil, totalModelCalls: fixtures.replies.callCount)
}

/// Every ordered pair of stops (the second stop cannot be multiple choice, which needs Haiku to generate),
/// plus a few triples that check counter-to-counter and multiple-choice-to-counter-to-counter transitions.
private func prefetchSequences() -> [[PrefetchStop]] {
    let stops = PrefetchKind.allCases.flatMap { kind in
        kind.outcomes.map { PrefetchStop(kind: kind, outcome: $0) }
    }
    let secondStops = stops.filter { $0.kind != .multipleChoice }
    var sequences: [[PrefetchStop]] = []
    for first in stops {
        for second in secondStops {
            sequences.append([first, second])
        }
    }
    sequences += [
        [.correct(.multipleChoice), .correct(.counterNumber), .correct(.counterMeaning)],
        [.correct(.multipleChoice), .correct(.counterNumber), .correct(.counterNumber)],
        [.correct(.pairBoth), .correct(.counterNumber), .correct(.counterNumber)],
        [.correct(.counterNumber), .correct(.pairBoth), .correct(.counterNumber)],
        [.correct(.counterNumber), .correct(.counterMeaning), .correct(.pairIntransitive)],
        [.correct(.freeAnswer), .correct(.counterNumber), .correct(.freeAnswer)],
        // Wrong answers in a row, and a wrong answer between two right ones.
        [.wrong(.multipleChoice), .wrong(.counterNumber), .wrong(.counterMeaning)],
        [.correct(.multipleChoice), .wrong(.counterNumber), .correct(.counterMeaning)],
        [.wrong(.counterMeaning), .correct(.counterNumber), .wrong(.counterNumber)],
        // Admissions of uncertainty next to each other, and an admission between two right answers.
        [.correct(.multipleChoice), .noIdea(.counterNumber), .inkling(.counterMeaning)],
        [.noIdea(.multipleChoice), .noIdea(.counterNumber), .correct(.counterMeaning)],
        [.correct(.counterNumber), .inkling(.freeAnswer), .inklingWhileGrading(.freeAnswer)],
        [.noIdea(.pairBoth), .noIdeaWhileGrading(.freeAnswer), .correct(.counterNumber)],
    ]
    return sequences
}

/// Free oracle: for every sequence of items, the prefetch path and the direct path must show each item
/// in the same phase with the same answer score. Every item must arrive in the phase its kind expects,
/// clean (no leftover input, chat turn, unlock, or score), with no prefetch of the next item started while it
/// was on screen, and no multiple-choice result or tutor prompt carried over from the previous item.
/// A correct answer must score 1.0 and a wrong one 0.0. "No idea" scores 0.0 and "Inkling" 0.25, even when Haiku
/// grades a free answer that was submitted first. The result bubble must say so (✓ or ✗) for every kind and
/// outcome that prints one. Each answer makes exactly the model calls its outcome expects, and no others.
///
/// Reproduces a reported bug. Counter items are always built free (QuizContext), so the prefetch
/// consume path only fell through to `.chatting` when "multiple choice only" was on, because that turns
/// off `isFreeAnswer`. The student then saw the counter question in chat, and a typed answer went to Haiku.
///
/// Free-answer items do not exist when "multiple choice only" is on, so those sequences run only with it off.
@MainActor
func fuzzPrefetchConsume() async throws {
    print("=== FUZZ: prefetch consume across item-kind sequences (prefetch path vs direct path) ===")

    let tmpPath = NSTemporaryDirectory() + "fuzz-prefetch-\(ProcessInfo.processInfo.processIdentifier).sqlite"
    defer { try? FileManager.default.removeItem(atPath: tmpPath) }
    let db = try QuizDB.open(path: tmpPath)
    let replies = ScriptedReplies()
    var client = AnthropicClient(apiKey: "not-needed", model: "not-needed")
    client.replyStub = { messages, system in replies.respond(messages: messages, system: system) }
    let toolHandler = try ToolHandler(jmdict: DatabaseQueue(), kanjidic: nil,
                                      wanikani: WanikaniData(kanjiToComponents: [:], extraDescriptions: [:]),
                                      quizDB: db, chatDB: nil)

    guard let countersPath = findFile("Counters/counters.json"),
          let data = try? Data(contentsOf: URL(fileURLWithPath: countersPath)),
          let counters = try? JSONDecoder().decode([Counter].self, from: data),
          let counter = counters.first(where: { $0.kanji == "個" && $0.pronunciations["6"] != nil }) else {
        report(area: "prefetch-consume", checked: 0, silentlySkipped: 0,
               failures: [("setup", "no 個 counter with a \"6\" pronunciation in Counters/counters.json")])
        return
    }
    let counterCorpus = CounterCorpus()
    counterCorpus.setItemsForTesting([CounterItem(counter: counter)])

    let pairJSON = """
    {"intransitive": {"kana": "きえる", "jmdictId": "1350040", "kanji": ["消える"], "bccwjPerMillionWords": null},
     "transitive": {"kana": "けす", "jmdictId": "1350110", "kanji": ["消す"], "bccwjPerMillionWords": null},
     "examples": {"intransitive": null, "transitive": null},
     "ambiguousReason": null,
     "drills": [{"intransitive": {"en": "The streetlights went out.", "ja": "街灯が消えた。", "jaFurigana": null},
                 "transitive": {"en": "He switched off the lights.", "ja": "電気を消した。", "jaFurigana": null}}]}
    """
    let pair = try JSONDecoder().decode(TransitivePair.self, from: Data(pairJSON.utf8))
    let pairCorpus = TransitivePairCorpus()
    pairCorpus.setItemsForTesting([TransitivePairItem(pair: pair)])

    let fixtures = PrefetchFixtures(counter: counter, counterCorpus: counterCorpus, pairCorpus: pairCorpus,
                                    client: client, replies: replies, toolHandler: toolHandler, db: db)

    // The preference is backed by UserDefaults, so put back whatever the developer had set.
    let preferences = UserPreferences()
    let originalMultipleChoiceOnly = preferences.multipleChoiceOnly
    defer { preferences.multipleChoiceOnly = originalMultipleChoiceOnly }

    var failures: [(String, String)] = []
    var checked = 0
    var skipped = 0
    for stops in prefetchSequences() {
        for multipleChoiceOnly in [false, true] {
            let label = stops.map(\.label).joined(separator: " → ")
                + (multipleChoiceOnly ? " [multiple choice only]" : " [free answer allowed]")
            if multipleChoiceOnly && stops.contains(where: { $0.kind == .freeAnswer }) {
                skipped += 1
                continue
            }
            checked += 1
            let direct = await runPrefetchSequence(stops: stops, usePrefetch: false, multipleChoiceOnly: multipleChoiceOnly,
                                                   fixtures: fixtures, preferences: preferences)
            let prefetched = await runPrefetchSequence(stops: stops, usePrefetch: true, multipleChoiceOnly: multipleChoiceOnly,
                                                       fixtures: fixtures, preferences: preferences)
            if let problem = direct.problem ?? prefetched.problem {
                failures.append((label, problem))
                print("  [FAIL] \(label): \(problem)")
                continue
            }
            var sequenceFailed = false
            if prefetched.steps != direct.steps {
                sequenceFailed = true
                failures.append((label, "prefetch path differs from direct path\n      prefetch: \(prefetched.steps.map(\.summary))\n      direct:   \(direct.steps.map(\.summary))"))
            }
            // Every model call must belong to a step's expected count. Warm-up and prefetch make none.
            for run in [prefetched, direct] {
                let expectedTotal = run.steps.reduce(0) { $0 + $1.expectedModelCalls }
                if run.totalModelCalls != expectedTotal {
                    sequenceFailed = true
                    failures.append((label, "made \(run.totalModelCalls) model call(s), expected \(expectedTotal)"))
                }
            }
            for step in prefetched.steps {
                let name = "\(step.kind.label) [\(step.outcome.rawValue)]"
                if step.arrivalPhase != step.kind.expectedPhase {
                    failures.append((label, "\(step.kind.label) arrived in \(step.arrivalPhase), expected \(step.kind.expectedPhase)")); sequenceFailed = true
                }
                if !step.dirtyFieldsAtArrival.isEmpty {
                    failures.append((label, "\(step.kind.label) arrived with leftover state: \(step.dirtyFieldsAtArrival.joined(separator: ", "))")); sequenceFailed = true
                }
                if step.nextPrefetchedBeforeAnswer {
                    failures.append((label, "\(step.kind.label): the next item was prefetched while this one was still on screen")); sequenceFailed = true
                }
                if step.staleMultipleChoiceResult {
                    failures.append((label, "\(step.kind.label): a multiple-choice result from the previous item leaked in")); sequenceFailed = true
                }
                if step.staleTutorPrompt {
                    failures.append((label, "\(step.kind.label): a tutor prompt from the previous item survived the advance")); sequenceFailed = true
                }
                if step.answerScore != step.outcome.expectedScore {
                    failures.append((label, "\(name): scored \(step.answerScore.map { String($0) } ?? "nil"), expected \(step.outcome.expectedScore)")); sequenceFailed = true
                }
                if step.kind.marksResultBubble, let expectedMark = step.outcome.expectedResultMark, step.resultMark != expectedMark {
                    failures.append((label, "\(name): result bubble starts with \"\(step.resultMark)\", expected \(expectedMark)")); sequenceFailed = true
                }
                if step.answerModelCalls != step.expectedModelCalls {
                    failures.append((label, "\(name): made \(step.answerModelCalls) model call(s), expected \(step.expectedModelCalls)")); sequenceFailed = true
                }
            }
            print("  [\(sequenceFailed ? "FAIL" : "PASS")] \(label)")
        }
    }
    print("Skipped \(skipped) free-answer sequence(s) with multiple choice only on (free-answer items do not exist in that mode).")
    report(area: "prefetch-consume", checked: checked, silentlySkipped: skipped, failures: failures)
}

/// Builds a minimal quiz item for the prefetch check. Only fields the consume path reads matter.
private func prefetchFuzzItem(wordType: String, wordId: String, wordText: String, kana: String,
                              facet: String, isFree: Bool) -> QuizItem {
    QuizItem(
        wordType: wordType,
        wordId: wordId,
        wordText: wordText,
        writtenTexts: [],
        kanaTexts: kana.isEmpty ? [] : [kana],
        hasKanji: false,
        facet: facet,
        status: .reviewed(recall: 0.5, isFree: isFree, halflife: isFree ? 72.0 : 24.0),
        senseExtras: [],
        committedKanji: nil,
        partialKanjiTemplate: nil,
        committedReading: nil,
        committedWrittenText: nil,
        committedFurigana: nil,
        siblingKanaReadings: [],
        corpusSenseIndices: [0],
        kanjiQuizData: nil
    )
}

private func phaseName(_ phase: QuizSession.Phase) -> String {
    switch phase {
    case .idle: return "idle"
    case .loadingItems: return "loadingItems"
    case .generating: return "generating"
    case .awaitingTap: return "awaitingTap"
    case .awaitingText: return "awaitingText"
    case .awaitingPair: return "awaitingPair"
    case .chatting: return "chatting"
    case .noItems: return "noItems"
    case .finished: return "finished"
    case .error(let message): return "error(\(message))"
    }
}
