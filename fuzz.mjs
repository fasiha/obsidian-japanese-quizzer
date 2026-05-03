#!/usr/bin/env node
// fuzz.mjs — property-based and adversarial tests for shared.mjs parsing functions
// and grammar/grammar-equivalences.json structural invariants.
//
// Usage: node fuzz.mjs
//
// Targets:
//   1. parseFrontmatter — known edge cases (BOM, CRLF, colons in values, etc.)
//   2. extractDetailsBlocks — nested <details> blocks (known regex limitation)
//   3. grammar-equivalences.json — partition invariants (no duplicate topic IDs, etc.)
//   4. extractJapaneseTokens — property tests on random Unicode strings

import {
    parseFrontmatter,
    extractJapaneseTokens,
    extractDetailsBlocks,
    extractVocabBullets,
    extractVocabBulletsWithLines,
    isJapanese,
    intersectSets,
    migrateEquivalences,
    toHiragana,
    isFuriganaParent,
    buildFuriganaForWord,
    extractContextBefore,
    findMdFiles,
    openJmdictDb,
    projectRoot,
} from "./.claude/scripts/shared.mjs";
import { findExactIds } from "jmdict-simplified-node";
import { readFileSync, existsSync } from "fs";
import { fileURLToPath } from "url";
import path from "path";

const HERE = path.dirname(fileURLToPath(import.meta.url));

let passed = 0;
let failed = 0;
let total  = 0;

function ok(label, cond, detail = "") {
    total++;
    if (cond) {
        passed++;
        console.log(`[pass] ${label}`);
    } else {
        failed++;
        const d = detail ? `: ${detail}` : "";
        console.error(`[FAIL] ${label}${d}`);
    }
}

function info(label, val) {
    console.log(`[info] ${label}: ${JSON.stringify(val)}`);
}

// ── 1. parseFrontmatter ──────────────────────────────────────────────────────

console.log("\n=== parseFrontmatter ===");

// Basic scalar values
ok("basic string value",   parseFrontmatter("---\ntitle: Hello\n---\n")?.title === "Hello");
ok("boolean true",         parseFrontmatter("---\nllm-review: true\n---\n")?.["llm-review"] === true);
ok("boolean false",        parseFrontmatter("---\nfoo: false\n---\n")?.foo === false);
ok("number-ish stays string", typeof parseFrontmatter("---\norder: 3\n---\n")?.order === "string");

// Colon in value — indexOf(":") takes the FIRST colon; value should include the rest
{
    const fm = parseFrontmatter("---\nurl: https://example.com\n---\n");
    ok("colon in value: key is 'url'", fm?.url === "https://example.com", JSON.stringify(fm?.url));
}

// Missing frontmatter
ok("null when no frontmatter",   parseFrontmatter("No frontmatter here") === null);
ok("null when opening --- only", parseFrontmatter("---\ntitle: No close\n") === null);

// BOM + CRLF
ok("strips BOM",       parseFrontmatter("﻿---\ntitle: BOM\n---\n")?.title === "BOM");
ok("handles CRLF",     parseFrontmatter("---\r\ntitle: CRLF\r\n---\r\n")?.title === "CRLF");

// Empty frontmatter block — the regex requires \n before the closing ---, so adjacent
// "---\n---\n" returns null. A blank line between the delimiters works: "---\n\n---\n".
ok("adjacent --- --- returns null (no blank line between)",
    parseFrontmatter("---\n---\n") === null);
{
    const fm = parseFrontmatter("---\n\n---\n");
    ok("blank-line separated --- --- returns non-null object", fm !== null && typeof fm === "object");
    ok("blank-line separated --- --- has no keys",             Object.keys(fm ?? {}).length === 0);
}

// Line starting with colon — empty key should be ignored
{
    const fm = parseFrontmatter("---\n: orphan-value\n---\n");
    ok("line with empty key produces no entry", Object.keys(fm ?? {}).length === 0);
}

// Whitespace around key
ok("key whitespace trimmed",
    parseFrontmatter("---\n  title  : Hello\n---\n")?.title === "Hello");

// Leading blank lines before ---
ok("leading blank lines tolerated",
    parseFrontmatter("\n\n---\ntitle: Late\n---\n")?.title === "Late");

// No crash on adversarial inputs
for (const [label, input] of [
    ["empty string",          ""],
    ["null byte",             "\0"],
    ["only dashes",           "---"],
    ["only whitespace",       "   \n\n  "],
    ["10 000-char repetition", "x".repeat(10_000)],
    ["1000 key-value pairs",   "---\n" + "k: v\n".repeat(1000) + "---\n"],
]) {
    let threw = false;
    try { parseFrontmatter(input); } catch { threw = true; }
    ok(`no throw on: ${label}`, !threw);
}

// ── 2. extractDetailsBlocks — nested <details> blocks ────────────────────────

console.log("\n=== extractDetailsBlocks ===");

// Normal single block
{
    const content = `
<details>
<summary>Vocab</summary>
- 食べる eat
</details>`;
    const matches = [...extractDetailsBlocks(content, "Vocab")];
    ok("normal block: 1 match", matches.length === 1);
    ok("normal block: bullet present", matches[0]?.stripped.includes("食べる"));
}

// Two separate Vocab blocks
{
    const content = `
<details><summary>Vocab</summary>
- 猫 cat
</details>
<details><summary>Vocab</summary>
- 犬 dog
</details>`;
    const matches = [...extractDetailsBlocks(content, "Vocab")];
    ok("two separate blocks: 2 matches", matches.length === 2);
}

// Case-insensitive summary
{
    const content = `<details><summary>VOCAB</summary>- 魚 fish</details>`;
    const matches = [...extractDetailsBlocks(content, "Vocab")];
    ok("case-insensitive summary match", matches.length === 1);
}

// Nested <details> inside a Vocab block — known regex limitation.
// The lazy [\s\S]*? in the regex matches up to the FIRST </details>, which closes
// the inner block. The outer Vocab block is therefore matched only up to the inner
// </details>, and any bullets that appear between the inner </details> and the outer
// </details> are silently dropped.
{
    const content = `
<details>
<summary>Vocab</summary>
- 食べる eat
<details>
<summary>Grammar</summary>
- ている
</details>
- 飲む drink
</details>`;
    const matches = [...extractDetailsBlocks(content, "Vocab")];
    // Use the public extractVocabBullets API: depth tracking ensures bullets
    // inside nested <details> are not leaked into the Vocab extraction.
    const bullets = extractVocabBullets(content);
    info("nested block: matches found",  matches.length);
    info("nested block: bullets found",  bullets);

    const foundTaberu = bullets.some((b) => b.includes("食べる"));
    const foundNomu   = bullets.some((b) => b.includes("飲む"));

    ok("nested block: 食べる (before inner block) is found", foundTaberu);
    ok("nested block: 飲む (after inner block) is found — BUG #1 fixed", foundNomu);

    // The Grammar bullet 'ている' should NOT appear as a Vocab bullet.
    const foundTeiru = bullets.some((b) => b.includes("ている"));
    ok("nested block: Grammar bullet ている did not leak into Vocab — BUG #1 fixed", !foundTeiru);
}

// ── 3. grammar-equivalences.json partition invariants ────────────────────────

console.log("\n=== grammar-equivalences.json ===");

const equivPath = path.join(HERE, "grammar", "grammar-equivalences.json");
if (!existsSync(equivPath)) {
    console.log("[skip] grammar/grammar-equivalences.json not found");
} else {
    const raw    = JSON.parse(readFileSync(equivPath, "utf8"));
    const groups = migrateEquivalences(raw);
    info("group count", groups.length);

    // No topic ID may appear in more than one group.
    const topicToGroup = new Map();
    let duplicates = 0;
    for (const [gi, group] of groups.entries()) {
        for (const id of group.topics ?? []) {
            if (topicToGroup.has(id)) {
                console.error(
                    `[FAIL] duplicate topic ID "${id}" in groups ` +
                    `${topicToGroup.get(id)} and ${gi}`,
                );
                duplicates++;
                failed++; total++;
            } else {
                topicToGroup.set(id, gi);
            }
        }
    }
    ok(`no duplicate topic IDs across ${groups.length} groups (${topicToGroup.size} IDs total)`,
       duplicates === 0);

    // No group may have an empty topics array.
    const emptyGroups = groups.filter((g) => !g.topics || g.topics.length === 0);
    ok("no groups with empty topics array",
       emptyGroups.length === 0, `${emptyGroups.length} empty group(s)`);

    // Every topic ID must have exactly one colon (format: "source:slug").
    const badIds = [...topicToGroup.keys()].filter((id) => {
        const parts = id.split(":");
        return parts.length !== 2 || parts[0].length === 0 || parts[1].length === 0;
    });
    ok(`all ${topicToGroup.size} topic IDs have format "source:slug"`,
       badIds.length === 0, `bad IDs: ${badIds.slice(0, 5).join(", ")}`);

    // No duplicate sub-use IDs within a single group.
    let dupSubUses = 0;
    for (const [gi, group] of groups.entries()) {
        const seen = new Set();
        for (const su of group.subUses ?? []) {
            const id = typeof su === "string" ? su : su?.id;
            if (!id) continue;
            if (seen.has(id)) {
                console.error(`[FAIL] group ${gi}: duplicate sub-use ID "${id}"`);
                dupSubUses++;
                failed++; total++;
            } else {
                seen.add(id);
            }
        }
    }
    ok("no duplicate sub-use IDs within any group", dupSubUses === 0);

    // Sub-use IDs must be non-empty slug-format strings (no spaces, no colons).
    let badSubUseIds = 0;
    for (const [gi, group] of groups.entries()) {
        for (const su of group.subUses ?? []) {
            const id = typeof su === "string" ? null : su?.id;
            if (id == null) continue;
            if (id.length === 0 || id.includes(" ") || id.includes(":")) {
                console.error(`[FAIL] group ${gi}: invalid sub-use ID "${id}"`);
                badSubUseIds++;
                failed++; total++;
            }
        }
    }
    ok("all sub-use IDs are non-empty slug-format strings", badSubUseIds === 0);
}

// ── 4. extractJapaneseTokens property tests ───────────────────────────────────

console.log("\n=== extractJapaneseTokens ===");

// All returned tokens must satisfy isJapanese() and be non-empty.
const tokenInputs = [
    ["食べる eat",         ["食べる"]],
    ["食べる",             ["食べる"]],
    ["食べる 飲む drink",  ["食べる", "飲む"]],
    ["eat 食べる",         []],
    ["",                  []],
    ["   ",               []],
];
for (const [input, expected] of tokenInputs) {
    const tokens = extractJapaneseTokens(input);
    ok(`tokens of "${input.slice(0, 30)}" are all isJapanese`,
       tokens.every((t) => isJapanese(t)),
       `tokens: ${JSON.stringify(tokens)}`);
    ok(`tokens of "${input.slice(0, 30)}" are all non-empty`,
       tokens.every((t) => t.length > 0));
    ok(`tokens of "${input.slice(0, 30)}" match expected`,
       JSON.stringify(tokens) === JSON.stringify(expected),
       `got ${JSON.stringify(tokens)}, expected ${JSON.stringify(expected)}`);
}

// Random property: every token returned by extractJapaneseTokens must satisfy isJapanese.
// Generate random strings mixing hiragana, ASCII, and a few kanji.
const hiraganaBase = 0x3041;
function randomHiragana(len) {
    return Array.from({ length: len }, (_, i) =>
        String.fromCodePoint(hiraganaBase + (Math.floor(Math.sin(i * 12345.6789) * 0x55) & 0x55)),
    ).join("");
}

let randomFailed = 0;
for (let i = 0; i < 1000; i++) {
    // Build a string with a random mix of hiragana tokens and ASCII words
    const parts = [];
    for (let j = 0; j < 4; j++) {
        if ((i + j) % 3 === 0) parts.push(randomHiragana(1 + (i % 5)));
        else                   parts.push(["eat", "the", "cat", "go"][j % 4]);
    }
    const input  = parts.join(" ");
    const tokens = extractJapaneseTokens(input);
    if (!tokens.every((t) => isJapanese(t) && t.length > 0)) {
        console.error(`[FAIL] random property: invalid token in "${input}": ${JSON.stringify(tokens)}`);
        randomFailed++;
        failed++; total++;
    }
}
ok(`random property: all tokens satisfy isJapanese (1000 random strings)`, randomFailed === 0);


// ── 5. isFuriganaParent adversarial inputs (Area F) ──────────────────────────

console.log("\n=== isFuriganaParent (prepare-publish.mjs) ===");

// Empty-furigana edge case noted during code review.
// Two distinct objects with empty furigana arrays should NOT be parent-child,
// but the current implementation returns true (the while-loop never executes).
{
    const a = { furigana: [] };
    const b = { furigana: [] };
    const result = isFuriganaParent(a, b);
    if (result === true) {
        console.error(
            "[BUG] isFuriganaParent returns true for two distinct objects with empty " +
            "furigana arrays. The while-loop never executes, so the function returns " +
            "the default `true`. Currently doesn't fire because callers filter empty- " +
            "furigana words upstream — but a future caller change would expose it.",
        );
        failed++; total++;
    } else {
        ok("empty-furigana arrays: distinct objects are not parent-child", true);
    }
}

// Self-reference is filtered by the early `===` check.
{
    const a = { furigana: [{ ruby: "食", rt: "た" }] };
    ok("self-reference returns false (early identity check)",
       isFuriganaParent(a, a) === false);
}

// Real parent relationship: "た" (kana-only) vs "食" with rt:"た" (more kanji)
{
    const child  = { furigana: [{ ruby: "た" }] };  // o.rt absent → string
    const parent = { furigana: [{ ruby: "食", rt: "た" }] };
    ok("real parent: 'た' has parent '食[た]'",
       isFuriganaParent(child, parent) === true);
    ok("not symmetric: '食[た]' is NOT child of 'た'",
       isFuriganaParent(parent, child) === false);
}

// Asymmetry property on synthesized inputs.
{
    let asymmetryFails = 0;
    const samples = [
        { furigana: [{ ruby: "食", rt: "た" }, { ruby: "べ" }, { ruby: "る" }] },
        { furigana: [{ ruby: "た" }, { ruby: "べ" }, { ruby: "る" }] },
        { furigana: [{ ruby: "食", rt: "た" }, { ruby: "べ" }, { ruby: "物", rt: "もの" }] },
        { furigana: [{ ruby: "た" }, { ruby: "べ" }, { ruby: "もの" }] },
        { furigana: [{ ruby: "焚", rt: "た" }, { ruby: "き" }, { ruby: "木", rt: "ぎ" }] },
        { furigana: [{ ruby: "たき木", rt: "たきぎ" }] },
    ];
    for (let i = 0; i < samples.length; i++) {
        for (let j = 0; j < samples.length; j++) {
            if (i === j) continue;
            const a = samples[i], b = samples[j];
            if (isFuriganaParent(a, b) && isFuriganaParent(b, a)) {
                console.error(`[FAIL] asymmetry: both isFuriganaParent(samples[${i}], samples[${j}]) and reverse are true`);
                asymmetryFails++;
                failed++; total++;
            }
        }
    }
    ok(`asymmetry across ${samples.length} samples`, asymmetryFails === 0);
}

// Random structured fuzz: should never throw.
{
    let throws = 0;
    for (let i = 0; i < 1000; i++) {
        // Build random furigana arrays with mixed string/object segments
        const makeArr = () => {
            const len = (i + 1) % 5 + 1;
            const arr = [];
            for (let k = 0; k < len; k++) {
                const r = (i * 7 + k * 3) % 3;
                if (r === 0) arr.push({ ruby: "X", rt: "x" });
                else if (r === 1) arr.push({ ruby: "y" });  // kana segment (no rt)
                else arr.push({ ruby: "abc", rt: "ab" });
            }
            return { furigana: arr };
        };
        try {
            isFuriganaParent(makeArr(), makeArr());
        } catch {
            throws++;
        }
    }
    ok(`random fuzz: no throws over 1000 iters`, throws === 0);
}

// ── 6. buildFuriganaForWord structural invariants (Area G) ───────────────────

console.log("\n=== buildFuriganaForWord (prepare-publish.mjs) ===");

// Kana-only word
{
    const word = {
        kanji: [],
        kana: [{ text: "ねこ" }],
    };
    const result = buildFuriganaForWord(word, new Map());
    ok("kana-only word returns 1 entry", result.length === 1);
    ok("kana-only word: forms is empty", result[0]?.forms.length === 0);
    ok("kana-only word: reading equals kana text", result[0]?.reading === "ねこ");
}

// kana-only word with `ik` (irregular) and `sk` (search-only) tags filtered out
{
    const word = {
        kanji: [],
        kana: [
            { text: "ねこ" },
            { text: "ネコ", tags: ["sk"] },     // search-only — filter
            { text: "ねこの", tags: ["ik"] },   // irregular — filter
        ],
    };
    const result = buildFuriganaForWord(word, new Map());
    ok("kana-only: ik/sk filtered", result.length === 1 && result[0].reading === "ねこ");
}

// Single-kanji word with furigana.
// Note: real JMDict words from jmdict-simplified-node always populate appliesToKanji
// (typically ["*"] meaning "all kanji forms"). Without this field, the function
// returns an empty forms array — this is "garbage in, defined-garbage out" behavior
// and a defensive default-to-["*"] could be considered for robustness.
{
    const word = {
        kanji: [{ text: "猫" }],
        kana: [{ text: "ねこ", appliesToKanji: ["*"] }],
    };
    const furiganaMap = new Map([
        ["猫", [{ reading: "ねこ", furigana: [{ ruby: "猫", rt: "ねこ" }] }]],
    ]);
    const result = buildFuriganaForWord(word, furiganaMap);
    ok("single kanji: 1 reading", result.length === 1);
    ok("single kanji: reading is hiragana-keyed", result[0]?.reading === "ねこ");
    ok("single kanji: 1 form", result[0]?.forms.length === 1);
    ok("single kanji: form text is in kanji array", result[0]?.forms[0]?.text === "猫");
}

// Katakana reading is normalized to hiragana key
{
    const word = {
        kanji: [{ text: "電話" }],
        kana: [{ text: "デンワ", appliesToKanji: ["*"] }],
    };
    const furiganaMap = new Map([
        ["電話", [{ reading: "デンワ", furigana: [{ ruby: "電話", rt: "デンワ" }] }]],
    ]);
    const result = buildFuriganaForWord(word, furiganaMap);
    info("katakana reading normalization", { reading: result[0]?.reading });
    ok("reading key is hiragana-normalized (デンワ → でんわ)",
       result[0]?.reading === "でんわ",
       `got "${result[0]?.reading}"`);
}

// Property: every form.text is in word.kanji (filtered for iK)
{
    const word = {
        kanji: [
            { text: "焚き木" },
            { text: "薪" },
            { text: "ねつぎ", tags: ["iK"] },  // irregular kanji — filter
        ],
        kana: [{ text: "たきぎ", appliesToKanji: ["*"] }],
    };
    const furiganaMap = new Map([
        ["焚き木", [{ reading: "たきぎ", furigana: [{ ruby: "焚", rt: "た" }, { ruby: "き" }, { ruby: "木", rt: "ぎ" }] }]],
        ["薪",     [{ reading: "たきぎ", furigana: [{ ruby: "薪", rt: "たきぎ" }] }]],
    ]);
    const result = buildFuriganaForWord(word, furiganaMap);
    const validKanji = new Set(["焚き木", "薪"]);
    const allFormsValid = result.every((r) => r.forms.every((f) => validKanji.has(f.text)));
    ok("all returned form.text values are in word.kanji (filtered)", allFormsValid,
       `result: ${JSON.stringify(result.map((r) => r.forms.map((f) => f.text)))}`);
}

// ── 7. extractContextBefore — including the predicted nested-block bug (Area H) ──

console.log("\n=== extractContextBefore (prepare-publish.mjs) ===");

// Simple case: prose paragraph followed by a single Vocab block
{
    const content = `Some prose here.
<details><summary>Vocab</summary>
- 食べる
</details>
`;
    const endIdx = content.indexOf("<details>");
    const result = extractContextBefore(content, endIdx);
    ok("simple: text is the prose", result.text === "Some prose here.");
    ok("simple: line is 1 (1-based)", result.line === 1);
}

// Empty content
{
    const result = extractContextBefore("", 0);
    ok("empty content: text and line are null", result.text === null && result.line === null);
}

// No prose before block
{
    const content = `<details><summary>Vocab</summary>
- 食べる
</details>
`;
    const result = extractContextBefore(content, content.length);
    info("no-prose case", result);
    ok("no prose before block: text is null", result.text === null);
}

// Multi-line block backward-walking
{
    const content = `Prose here.
<details>
<summary>Vocab</summary>
- 食べる
</details>
<details><summary>Grammar</summary>- ている</details>
`;
    // endIdx is past both blocks
    const endIdx = content.length;
    const result = extractContextBefore(content, endIdx);
    info("multi-line + single-line backward walk", result);
    ok("multi-line + single-line: text is the prose", result.text === "Prose here.");
}

// PREDICTED BUG: nested <details> blocks confuse the backward walker.
// The inner "scan backward to <details" loop matches the inner <details>, not the outer
// one. So content from the OUTER block's first half ends up treated as prose context.
{
    const content = `Prose paragraph.
<details>
<summary>Vocab</summary>
- 食べる eat
<details>
<summary>Grammar</summary>
- ている
</details>
- 飲む drink
</details>
`;
    const endIdx = content.length;
    const result = extractContextBefore(content, endIdx);
    info("nested-blocks case", result);

    // Correct behavior: text should be "Prose paragraph." (the outer block fully skipped).
    if (result.text === "Prose paragraph.") {
        ok("nested-blocks: outer block skipped correctly", true);
    } else if (result.text && result.text.includes("食べる")) {
        console.error(
            "[BUG] extractContextBefore: nested <details> confuses the backward walker. " +
            "Bullets from inside the outer Vocab block leaked into the 'prose' context: " +
            JSON.stringify(result.text),
        );
        failed++; total++;
    } else {
        // Different but unexpected behavior — flag it as well
        console.error(
            "[FAIL] extractContextBefore nested-blocks: unexpected result " +
            JSON.stringify(result) + " (expected 'Prose paragraph.')",
        );
        failed++; total++;
    }
}

// Random adversarial: never throw on weird inputs
{
    const adversarial = [
        "<details><details><details>",
        "</details></details></details>",
        "abc\n<details>\nxyz",
        "<details>\n<summary>X</summary>\n", // no closing
        "x\n".repeat(10000),
    ];
    let throws = 0;
    for (const input of adversarial) {
        try {
            extractContextBefore(input, input.length);
        } catch {
            throws++;
        }
    }
    ok("no throws on adversarial inputs", throws === 0);
}

// ── 8. migrateEquivalences idempotency (Area I) ───────────────────────────────

console.log("\n=== migrateEquivalences idempotency ===");

{
    const inputs = [
        // Legacy: array of arrays
        [["bunpro:causative", "bunpro:passive"]],
        // Mixed: array of arrays and array of objects
        [["a:b", "c:d"], { topics: ["e:f"], summary: "x" }],
        // Modern: array of objects
        [{ topics: ["a:b"] }, { topics: ["c:d"], subUses: [] }],
        // Empty
        [],
        // Single-element array
        [["only:one"]],
    ];
    let idempotencyFails = 0;
    for (const inp of inputs) {
        const once  = migrateEquivalences(inp);
        const twice = migrateEquivalences(once);
        const match = JSON.stringify(once) === JSON.stringify(twice);
        if (!match) {
            console.error("[FAIL] migrateEquivalences not idempotent for input " + JSON.stringify(inp));
            console.error("  once:  " + JSON.stringify(once));
            console.error("  twice: " + JSON.stringify(twice));
            idempotencyFails++;
            failed++; total++;
        }
    }
    ok(`migrateEquivalences idempotent on ${inputs.length} inputs`, idempotencyFails === 0);
}

// ── 9. check-vocab.mjs bullet resolution invariants (Area J) ─────────────────

console.log("\n=== check-vocab.mjs resolution invariants ===");

{
    const db = await openJmdictDb({ checkJournalMode: false });
    const idExistsStmt = db.prepare("SELECT 1 FROM entries WHERE id = ?");
    const idExists = (id) => !!idExistsStmt.get(String(id));

    // Scan ALL Markdown files (not just llm-review: true) for structural checks.
    // Resolution checks are restricted to llm-review files since that's what the
    // production check-vocab.mjs validates.
    const allMdFiles = findMdFiles(projectRoot);

    let totalBullets = 0;
    let totalLlmReviewBullets = 0;
    let lineNumberMismatches = 0;
    let directIdInvalids = 0;
    let resolvedIdInvalids = 0;
    let nestedDetailsHits = [];
    let resolveCrashes = 0;

    for (const filePath of allMdFiles) {
        let content;
        try { content = readFileSync(filePath, "utf8"); }
        catch { continue; }

        const fm = parseFrontmatter(content);
        const isLlmReview = fm?.["llm-review"] === true;
        const fileLines = content.split("\n");
        const relPath = path.relative(projectRoot, filePath);

        // Detect two related extractDetailsBlocks failure modes:
        //   (a) real nested <details> inside a Vocab block (BUG #1)
        //   (b) regex started matching from a stray <details> in prose / code span /
        //       code fence, capturing a huge chunk of unrelated text. The match
        //       does not actually start with "<details ... <summary>Vocab"
        //       — the <summary>Vocab</summary> is somewhere in the middle of the captured chunk.
        for (const { fileOffset, stripped } of extractDetailsBlocks(content, "Vocab")) {
            const matchStart = content.slice(fileOffset, fileOffset + 200);
            const looksLikeRealVocabOpener =
                /^<details\b[^>]*>\s*<summary>\s*Vocab\s*<\/summary>/i.test(matchStart);
            if (!looksLikeRealVocabOpener) {
                nestedDetailsHits.push(`${relPath} [stray-opener]`);
            } else if (stripped.includes("<details")) {
                nestedDetailsHits.push(`${relPath} [real-nested]`);
            }
        }

        let bullets;
        try { bullets = extractVocabBulletsWithLines(content); }
        catch (e) {
            console.error(`[FAIL] extractVocabBulletsWithLines threw on ${relPath}: ${e.message}`);
            failed++; total++;
            continue;
        }

        // Skip files with no bullets (no Vocab block).
        if (bullets.length === 0) continue;

        // Check 1: every returned (bullet, line) points to a line that actually contains
        // the bullet text. This accommodates both standalone bullet lines (`- 経験`) and
        // single-line Vocab blocks (`<details><summary>Vocab</summary>- 経験</details>`).
        for (const { bullet, line } of bullets) {
            totalBullets++;
            if (line < 1 || line > fileLines.length) {
                lineNumberMismatches++;
                console.error(`[FAIL] line out of range: ${relPath}:${line} (file has ${fileLines.length} lines)`);
                continue;
            }
            const actualLine = fileLines[line - 1];
            // Verify by token: every leading Japanese token from the bullet must appear
            // somewhere on the line. This handles space-separated tokens
            // ("- はなれる 離れる") and single-line Vocab blocks alike.
            const tokens = extractJapaneseTokens(bullet);
            const missingTokens = tokens.filter((t) => !actualLine.includes(t));
            if (missingTokens.length > 0) {
                lineNumberMismatches++;
                console.error(
                    `[FAIL] line ${relPath}:${line} missing token(s) ${JSON.stringify(missingTokens)} — actual line: "${actualLine.slice(0, 80)}"`,
                );
            }
        }

        // Resolution-only checks: only run on llm-review files (matches production scope).
        if (!isLlmReview) continue;

        for (const { bullet, line } of bullets) {
            totalLlmReviewBullets++;

            // Direct-ID branch: bullet starts with digits.
            const directIdMatch = bullet.match(/^(\d+)/);
            if (directIdMatch) {
                const id = directIdMatch[1];
                if (!idExists(id)) {
                    directIdInvalids++;
                    console.error(`[FAIL] direct-ID bullet ${relPath}:${line} references non-existent JMDict ID ${id}: "${bullet}"`);
                }
                continue;
            }

            // Token-resolution branch.
            let tokens;
            try { tokens = extractJapaneseTokens(bullet); }
            catch (e) {
                resolveCrashes++;
                console.error(`[FAIL] extractJapaneseTokens threw on "${bullet}": ${e.message}`);
                continue;
            }
            if (tokens.length === 0) continue;

            let matchIds;
            try {
                const idSets = tokens.map((t) => new Set(findExactIds(db, t)));
                matchIds = [...intersectSets(idSets)];
            } catch (e) {
                resolveCrashes++;
                console.error(`[FAIL] resolution threw on "${bullet}": ${e.message}`);
                continue;
            }

            // Every resolved ID must exist in JMDict (sanity check on findExactIds output).
            for (const id of matchIds) {
                if (!idExists(id)) {
                    resolvedIdInvalids++;
                    console.error(`[FAIL] resolved ID ${id} from "${bullet}" (${relPath}:${line}) does not exist in jmdict.sqlite`);
                }
            }
        }
    }

    info("scope", {
        files: allMdFiles.length,
        total_bullets: totalBullets,
        llm_review_bullets: totalLlmReviewBullets,
    });
    ok(`line numbers correct (${totalBullets} bullets across ${allMdFiles.length} files)`,
       lineNumberMismatches === 0,
       `${lineNumberMismatches} mismatches`);
    ok(`direct-ID bullets reference real JMDict IDs`, directIdInvalids === 0);
    ok(`resolved IDs all exist in JMDict`, resolvedIdInvalids === 0);
    ok(`no resolution crashes`, resolveCrashes === 0);
    const realNested = nestedDetailsHits.filter((h) => h.endsWith("[real-nested]"));
    const strayOpener = nestedDetailsHits.filter((h) => h.endsWith("[stray-opener]"));
    if (realNested.length > 0) {
        console.error(
            `[BUG #1] ${realNested.length} file(s) have a real nested <details> in a Vocab block — ` +
            `bullets between inner and outer </details> would be silently dropped. ` +
            `Files: ${realNested.slice(0, 5).join(", ")}`,
        );
        failed++; total++;
    } else {
        ok(`no real nested <details> in Vocab blocks (BUG #1 dormant)`, true);
    }
    if (strayOpener.length > 0) {
        console.error(
            `[BUG #4 — new variant] ${strayOpener.length} file(s) trigger extractDetailsBlocks ` +
            `to start matching from a <details> in prose / inline code span / code fence, ` +
            `capturing unrelated text as a Vocab block. Same root cause as BUG #1 (regex doesn't ` +
            `understand Markdown context). Files: ${strayOpener.slice(0, 5).join(", ")}`,
        );
        failed++; total++;
    } else {
        ok(`no stray-opener confusions (BUG #4 dormant)`, true);
    }

    // Adversarial: synthesized bullets shouldn't crash the resolution pipeline.
    {
        const adversarial = [
            "",                     // empty (filtered before resolution)
            " ",                    // whitespace
            "\0",                   // null byte
            "🍣 sushi",              // emoji + English
            "1234567890",           // pure digits (direct-ID branch, will probably miss)
            "999999999999",         // direct-ID with implausible ID
            "12 食べる",             // direct-ID prefix + Japanese
            "食べる、 飲む。",        // multi-token with punctuation
            "...",                  // only punctuation
            "食",                    // single char (lots of homonyms)
            "○○○",                  // ideographic placeholders
            "食べる" + "x".repeat(1000),  // very long input
            "\n\n\n",               // newlines (shouldn't appear but test anyway)
            "食\nべる",              // newline mid-bullet (extracted upstream so unlikely, but still)
        ];
        let throws = 0;
        for (const b of adversarial) {
            try {
                const directId = b.match(/^(\d+)/);
                if (directId) { idExists(directId[1]); continue; }
                const tokens = extractJapaneseTokens(b);
                if (tokens.length > 0) {
                    const idSets = tokens.map((t) => new Set(findExactIds(db, t)));
                    [...intersectSets(idSets)];
                }
            } catch (e) {
                throws++;
                console.error(`[FAIL] adversarial input "${b.slice(0, 30)}" threw: ${e.message}`);
            }
        }
        ok(`adversarial bullets: no crashes (${adversarial.length} inputs)`, throws === 0);
    }

    db.close();
}

// ── 9. vocab.json structural invariants (target O) ───────────────────────────

console.log("\n=== vocab.json structural invariants ===");
{
    const vocabPath = path.join(HERE, "vocab.json");
    if (!existsSync(vocabPath)) {
        console.log("[skip] vocab.json not found — run prepare-publish.mjs to generate it.");
    } else {
        const v = JSON.parse(readFileSync(vocabPath, "utf-8"));

        // Top-level shape
        ok("vocab.json has generatedAt", typeof v.generatedAt === "string" && /\d{4}-\d{2}-\d{2}T/.test(v.generatedAt));
        ok("vocab.json has stories array", Array.isArray(v.stories));
        ok("vocab.json has words array", Array.isArray(v.words));
        ok("vocab.json has sourceOrders object", v.sourceOrders && typeof v.sourceOrders === "object" && !Array.isArray(v.sourceOrders));

        // stories: each has a non-empty title string
        const storyTitles = new Set();
        let storyShapeFails = 0;
        for (const s of v.stories) {
            if (!s || typeof s.title !== "string" || s.title.length === 0) storyShapeFails++;
            else storyTitles.add(s.title);
        }
        ok(`stories[*].title non-empty strings (${v.stories.length} stories)`, storyShapeFails === 0,
           `${storyShapeFails} malformed`);

        // sourceOrders: keys strings, values integers
        let soFails = 0;
        for (const [k, val] of Object.entries(v.sourceOrders)) {
            if (typeof k !== "string" || k.length === 0) soFails++;
            if (typeof val !== "number" || !Number.isInteger(val)) soFails++;
        }
        ok(`sourceOrders shape (${Object.keys(v.sourceOrders).length} keys)`, soFails === 0,
           `${soFails} bad pairs`);

        // Words: id is digits, unique, sources non-empty, references keys ⊆ sources
        const seenIds = new Set();
        let dupIds = 0;
        let badIdShape = 0;
        let emptySources = 0;
        let refsKeysMismatchSources = 0;
        let refsLineNotPositive = 0;
        let badLlmSense = 0;
        let badAnnotatedForms = 0;
        let badBccwj = 0;
        let badKanjiMeanings = 0;
        let sourceNotInStories = 0;
        let badContextOrNarration = 0;
        let badRefCounter = 0;
        let computedFromNotSortedDedup = 0;
        let writtenFormsRoundTripFails = 0;
        const sourcesSeen = new Set();
        const sampleFails = { dupIds: [], badIdShape: [], emptySources: [], refsKeysMismatchSources: [],
                              refsLineNotPositive: [], badLlmSense: [], badAnnotatedForms: [], badBccwj: [],
                              badKanjiMeanings: [], sourceNotInStories: [],
                              badContextOrNarration: [], badRefCounter: [],
                              computedFromNotSortedDedup: [], writtenFormsRoundTripFails: [] };
        function record(bucket, msg) {
            if (sampleFails[bucket].length < 3) sampleFails[bucket].push(msg);
        }

        for (const w of v.words) {
            if (typeof w.id !== "string" || !/^\d+$/.test(w.id)) {
                badIdShape++; record("badIdShape", `id=${JSON.stringify(w.id)}`);
            }
            if (seenIds.has(w.id)) { dupIds++; record("dupIds", w.id); }
            seenIds.add(w.id);

            if (!Array.isArray(w.sources) || w.sources.length === 0) {
                emptySources++; record("emptySources", w.id);
            } else {
                for (const src of w.sources) sourcesSeen.add(src);
                for (const src of w.sources) {
                    if (!storyTitles.has(src)) {
                        sourceNotInStories++;
                        record("sourceNotInStories", `${w.id} → '${src}'`);
                    }
                }
            }

            if (w.references != null) {
                const refKeys = new Set(Object.keys(w.references));
                const sourceSet = new Set(w.sources || []);
                // Symmetric difference
                const onlyRefs = [...refKeys].filter(k => !sourceSet.has(k));
                const onlySources = [...sourceSet].filter(k => !refKeys.has(k));
                if (onlyRefs.length || onlySources.length) {
                    refsKeysMismatchSources++;
                    record("refsKeysMismatchSources",
                        `${w.id}: refs-only=${onlyRefs} sources-only=${onlySources}`);
                }
                for (const [src, list] of Object.entries(w.references)) {
                    if (!Array.isArray(list)) {
                        refsKeysMismatchSources++;
                        record("refsKeysMismatchSources", `${w.id}/${src} is not an array`);
                        continue;
                    }
                    for (const ref of list) {
                        if (typeof ref.line !== "number" || !Number.isInteger(ref.line) || ref.line < 1) {
                            refsLineNotPositive++;
                            record("refsLineNotPositive", `${w.id}/${src} line=${ref.line}`);
                        }
                        // context/narration: per spec, may be null or a string.
                        if (ref.context !== undefined && ref.context !== null
                            && typeof ref.context !== "string") {
                            badContextOrNarration++;
                            record("badContextOrNarration",
                                `${w.id}/${src}:L${ref.line} context=${typeof ref.context}`);
                        }
                        if (ref.narration !== undefined && ref.narration !== null
                            && typeof ref.narration !== "string") {
                            badContextOrNarration++;
                            record("badContextOrNarration",
                                `${w.id}/${src}:L${ref.line} narration=${typeof ref.narration}`);
                        }
                        // ref.counter: when present, non-empty array of strings.
                        if (ref.counter !== undefined) {
                            if (!Array.isArray(ref.counter) || ref.counter.length === 0
                                || ref.counter.some(c => typeof c !== "string" || c.length === 0)) {
                                badRefCounter++;
                                record("badRefCounter",
                                    `${w.id}/${src}:L${ref.line} counter=${JSON.stringify(ref.counter)}`);
                            }
                        }
                        if (ref.annotated_forms !== undefined) {
                            if (!Array.isArray(ref.annotated_forms) || ref.annotated_forms.length === 0
                                || ref.annotated_forms.some(t => typeof t !== "string" || t.length === 0)) {
                                badAnnotatedForms++;
                                record("badAnnotatedForms",
                                    `${w.id}/${src}:L${ref.line} annotated_forms=${JSON.stringify(ref.annotated_forms)}`);
                            }
                        }
                        if (ref.llm_sense !== undefined && ref.llm_sense !== null) {
                            const s = ref.llm_sense;
                            if (!Array.isArray(s.sense_indices)
                                || s.sense_indices.some(i => !Number.isInteger(i) || i < 0)) {
                                badLlmSense++;
                                record("badLlmSense",
                                    `${w.id}/${src}:L${ref.line} sense_indices=${JSON.stringify(s.sense_indices)}`);
                            }
                            if (s.computed_from !== undefined) {
                                if (!Array.isArray(s.computed_from)) {
                                    badLlmSense++;
                                    record("badLlmSense",
                                        `${w.id}/${src}:L${ref.line} computed_from is not an array`);
                                } else {
                                    // Per spec: sorted + deduplicated.
                                    const cf = s.computed_from;
                                    const dedup = [...new Set(cf)];
                                    const sorted = [...dedup].sort();
                                    const isSortedDedup = cf.length === sorted.length
                                        && cf.every((x, i) => x === sorted[i]);
                                    if (!isSortedDedup) {
                                        computedFromNotSortedDedup++;
                                        record("computedFromNotSortedDedup",
                                            `${w.id}/${src}:L${ref.line}`);
                                    }
                                }
                            }
                            // llm_sense.counter: array of strings, empty array, or null. Never an array
                            // of non-strings.
                            if (s.counter !== undefined && s.counter !== null) {
                                if (!Array.isArray(s.counter)
                                    || s.counter.some(c => typeof c !== "string")) {
                                    badLlmSense++;
                                    record("badLlmSense",
                                        `${w.id}/${src}:L${ref.line} llm_sense.counter=${JSON.stringify(s.counter)}`);
                                }
                            }
                        }
                    }
                }
            }

            if (w.bccwjPerMillionWords !== null && w.bccwjPerMillionWords !== undefined) {
                if (typeof w.bccwjPerMillionWords !== "number"
                    || !Number.isFinite(w.bccwjPerMillionWords)
                    || w.bccwjPerMillionWords < 0) {
                    badBccwj++;
                    record("badBccwj", `${w.id} bccwj=${w.bccwjPerMillionWords}`);
                }
            }

            // writtenForms: each form's joined ruby fields must equal the form's text.
            if (w.writtenForms !== undefined && w.writtenForms !== null) {
                if (!Array.isArray(w.writtenForms)) {
                    writtenFormsRoundTripFails++;
                    record("writtenFormsRoundTripFails", `${w.id} writtenForms not an array`);
                } else {
                    for (const group of w.writtenForms) {
                        if (typeof group?.reading !== "string" || group.reading.length === 0
                            || !Array.isArray(group?.forms)) {
                            writtenFormsRoundTripFails++;
                            record("writtenFormsRoundTripFails",
                                `${w.id} group reading=${JSON.stringify(group?.reading)}`);
                            continue;
                        }
                        for (const form of group.forms) {
                            if (typeof form?.text !== "string" || form.text.length === 0
                                || !Array.isArray(form?.furigana)) {
                                writtenFormsRoundTripFails++;
                                record("writtenFormsRoundTripFails",
                                    `${w.id} form text=${JSON.stringify(form?.text)}`);
                                continue;
                            }
                            const joined = form.furigana.map(seg => seg?.ruby ?? "").join("");
                            if (joined !== form.text) {
                                writtenFormsRoundTripFails++;
                                record("writtenFormsRoundTripFails",
                                    `${w.id} '${form.text}' joined ruby='${joined}'`);
                            }
                        }
                    }
                }
            }

            if (w.kanjiMeanings !== undefined && w.kanjiMeanings !== null) {
                if (typeof w.kanjiMeanings !== "object" || Array.isArray(w.kanjiMeanings)) {
                    badKanjiMeanings++;
                    record("badKanjiMeanings", `${w.id}: kanjiMeanings not an object`);
                } else {
                    for (const [kch, meanings] of Object.entries(w.kanjiMeanings)) {
                        // Each key should be a single CJK character.
                        if ([...kch].length !== 1) {
                            badKanjiMeanings++;
                            record("badKanjiMeanings", `${w.id}: kanjiMeanings key '${kch}' not 1 char`);
                        }
                        if (!Array.isArray(meanings)
                            || meanings.some(m => typeof m !== "string" || m.length === 0)) {
                            badKanjiMeanings++;
                            record("badKanjiMeanings",
                                `${w.id}/${kch}: meanings=${JSON.stringify(meanings)}`);
                        }
                    }
                }
            }
        }

        info("vocab scope", { words: v.words.length, stories: v.stories.length,
                              uniqueSources: sourcesSeen.size,
                              sourceOrderKeys: Object.keys(v.sourceOrders).length });

        ok("word ids well-formed (digits)", badIdShape === 0,
           sampleFails.badIdShape.join(" / "));
        ok("word ids unique", dupIds === 0,
           sampleFails.dupIds.join(" / "));
        ok("sources arrays non-empty", emptySources === 0,
           sampleFails.emptySources.join(" / "));
        ok("references keys exactly match sources", refsKeysMismatchSources === 0,
           sampleFails.refsKeysMismatchSources.join(" / "));
        ok("every source appears as a story title", sourceNotInStories === 0,
           sampleFails.sourceNotInStories.join(" / "));
        ok("reference line numbers are positive integers", refsLineNotPositive === 0,
           sampleFails.refsLineNotPositive.join(" / "));
        ok("annotated_forms arrays well-formed when present", badAnnotatedForms === 0,
           sampleFails.badAnnotatedForms.join(" / "));
        ok("llm_sense.sense_indices well-formed when present", badLlmSense === 0,
           sampleFails.badLlmSense.join(" / "));
        ok("bccwjPerMillionWords is finite ≥ 0 when present", badBccwj === 0,
           sampleFails.badBccwj.join(" / "));
        ok("kanjiMeanings well-formed when present", badKanjiMeanings === 0,
           sampleFails.badKanjiMeanings.join(" / "));
        ok("ref.context / ref.narration null-or-string", badContextOrNarration === 0,
           sampleFails.badContextOrNarration.join(" / "));
        ok("ref.counter is non-empty string array when present", badRefCounter === 0,
           sampleFails.badRefCounter.join(" / "));
        ok("llm_sense.computed_from is sorted and deduplicated", computedFromNotSortedDedup === 0,
           sampleFails.computedFromNotSortedDedup.join(" / "));
        ok("writtenForms: every form's joined ruby == form.text", writtenFormsRoundTripFails === 0,
           sampleFails.writtenFormsRoundTripFails.join(" / "));

        // sourceOrders keys should typically correspond to source paths or directory paths.
        // Don't assert this strictly (directory keys are valid), but flag if a key is neither
        // a known source nor a prefix of any source.
        let dangling = 0;
        const sampleDangling = [];
        for (const k of Object.keys(v.sourceOrders)) {
            const isSource = sourcesSeen.has(k);
            const isDirPrefix = [...sourcesSeen].some(s => s.startsWith(k + "/"));
            if (!isSource && !isDirPrefix) {
                dangling++;
                if (sampleDangling.length < 5) sampleDangling.push(k);
            }
        }
        // This is a soft check — record as info, not a failure assertion.
        info("sourceOrders keys not seen in any source path",
             { count: dangling, sample: sampleDangling });
    }
}

// ── Summary ───────────────────────────────────────────────────────────────────

console.log(`\n=== SUMMARY ===`);
console.log(`Passed: ${passed}/${total}   Failed: ${failed}`);
if (failed === 0) {
    console.log("[PASS] All Node.js fuzz checks passed.");
} else {
    console.error(`[FAIL] ${failed} check(s) failed — see [FAIL] lines above.`);
    process.exit(1);
}
