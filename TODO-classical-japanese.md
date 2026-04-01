# Classical Japanese grammar topics — work plan

## Goal

Add a `classicalJapanese?: boolean` field to equivalence groups so that topics like
classical ず, ぬ/つ completion, 係り結び, む, and き can live in
`grammar-equivalences.json` as annotation references without being enrollable or
quizzable in the iOS app.

---

## Step 1 — Tag entries in grammar-equivalences.json

Add `"classicalJapanese": true` to the following equivalence groups:

- `imabi:「完了」を示す「ぬ」・「つ」` (ぬ/つ completion auxiliaries)
- `imabi:bound-particles` (係り結び)
- `imabi:the-auxiliary-verb-～ず-i` (classical ず)
- `kanshudo:〜む` (classical む volitional/conjecture)
- `kanshudo:き` (archaic attributive adjective き)

Also add `"classicalJapanese": true` to the existing ぬ cluster
(`bunpro:ぬ`, `kanshudo:ぬ_negative`) since it covers the same classical ぬ
attributive form.

---

## Step 2 — Publish pipeline (.claude/scripts/prepare-publish.mjs)

Find the block that copies `stub` from an equivalence group into the topic output
(around the lines that do `if (group.summary) topic.summary = group.summary` etc.)
and add an equivalent line:

```js
if (group.classicalJapanese) topic.classicalJapanese = group.classicalJapanese;
```

This ensures `classicalJapanese` reaches the `grammar.json` artifact that the iOS
app fetches.

---

## Step 3 — GrammarSync.swift: decode and propagate

File: `Pug/Pug/Models/GrammarSync.swift`

3a. Add to `GrammarEquivalenceGroup` (the Codable struct that mirrors the JSON):
```swift
let classicalJapanese: Bool?
```

3b. Add to `GrammarTopic` (the mutable struct that holds per-topic state):
```swift
var classicalJapanese: Bool?
```

3c. In `mergeDescriptions()`, after the line that sets `isStub`, add:
```swift
manifest.topics[key]?.classicalJapanese = group.classicalJapanese
```

---

## Step 4 — GrammarQuizContext.swift: carry field + filter out of quiz pool

File: `Pug/Pug/Models/GrammarQuizContext.swift`

4a. Add to `GrammarQuizItem`:
```swift
let classicalJapanese: Bool?
```

4b. Pass it when constructing items (in `build()`):
```swift
classicalJapanese: topic.classicalJapanese,
```

4c. Filter classical topics out of the quiz candidate pool.  Classical topics
should never appear as quiz items regardless of enrollment state.  Add this
filter just before the sort at the end of `build()`:
```swift
let items = rawItems.filter { $0.classicalJapanese != true }
```

---

## Step 5 — GrammarDetailSheet.swift: badge + disable enrollment

File: `Pug/Pug/Views/GrammarDetailSheet.swift`

5a. Add a "classical" badge alongside the existing "stub" badge (in the topic
title/header area around line 126):
```swift
if topic.classicalJapanese == true && t.prefixedId == topic.prefixedId {
    Text("classical")
        .font(.caption)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.purple.opacity(0.15), in: Capsule())
        .foregroundStyle(.purple)
}
```

5b. In the enrollment section, disable the "Start learning" button for classical
topics (allowing unenroll in case someone enrolled before the flag was added):
```swift
.disabled(topic.classicalJapanese == true)
```
Add a brief explanatory note below the button when disabled, e.g.:
```swift
if topic.classicalJapanese == true {
    Text("Classical Japanese topics are reference-only and cannot be enrolled.")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

---

## Step 6 — GrammarQuizSession.swift and TestHarness (minor)

Search for places that warn about `isStub` (TestHarness `main.swift` around
line 229 and `GrammarDumpPrompts.swift` around line 101) and add parallel
handling for `classicalJapanese` so the test harness warns when a classical
topic is included in a dump run.  Low priority — classical topics should never
reach the harness after Step 4 filters them out.

---

## Non-goals

- Classical quizzing via a fixed sentence pool (possible future work, not now).
- Changes to the annotation pipeline — `/annotate-grammar` should still tag
  classical forms and the detail sheet "Ask Claude" chat remains available.
