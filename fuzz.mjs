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
    isJapanese,
    migrateEquivalences,
    toHiragana,
    isFuriganaParent,
    buildFuriganaForWord,
    extractContextBefore,
} from "./.claude/scripts/shared.mjs";
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
    const bullets = matches.flatMap((m) =>
        m.stripped.split("\n").filter((l) => l.trim().startsWith("-")).map((l) => l.trim()),
    );
    info("nested block: matches found",  matches.length);
    info("nested block: bullets found",  bullets);

    const foundTaberu = bullets.some((b) => b.includes("食べる"));
    const foundNomu   = bullets.some((b) => b.includes("飲む"));

    ok("nested block: 食べる (before inner block) is found", foundTaberu);

    // 飲む appears after the inner </details>. With the lazy regex it is lost.
    if (!foundNomu) {
        console.error(
            "[BUG] nested block: '飲む' silently dropped — lazy regex matched inner" +
            " </details> instead of outer, so bullets after the inner block are lost.",
        );
        failed++; total++;
    } else {
        ok("nested block: 飲む (after inner block) is found", true);
    }

    // The Grammar bullet 'ている' should NOT appear as a Vocab bullet.
    // If it does, the inner block's content leaked into the Vocab extraction.
    const foundTeiru = bullets.some((b) => b.includes("ている"));
    if (foundTeiru) {
        console.error(
            "[BUG] nested block: Grammar bullet 'ている' leaked into Vocab extraction.",
        );
        failed++; total++;
    } else {
        ok("nested block: Grammar bullet ている did not leak into Vocab", true);
    }
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

// ── Summary ───────────────────────────────────────────────────────────────────

console.log(`\n=== SUMMARY ===`);
console.log(`Passed: ${passed}/${total}   Failed: ${failed}`);
if (failed === 0) {
    console.log("[PASS] All Node.js fuzz checks passed.");
} else {
    console.error(`[FAIL] ${failed} check(s) failed — see [FAIL] lines above.`);
    process.exit(1);
}
