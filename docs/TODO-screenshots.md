# Screenshot Tour for README.md

Goal: two hero images for README.md — one showing a full quiz conversation, one showing
the reader — that together convey what makes this app one-of-a-kind.

## Approach
Navigate the simulator step by step (screenshot → tap → screenshot), no video.
Collect raw frames, then decide what to crop/composite.

---

## Hero 1: Quiz conversation composite
A tall composite showing one complete exchange:
- Claude asks a kanji-to-reading or reading-to-meaning question
- User answers (correctly or not)
- Claude explains using kanji breakdown (WaniKani radicals + KANJIDIC2)
- User asks a tangent question
- Claude answers and circles back

Steps:
- [x] Screenshot current simulator state (Reader tab, JRap)
- [ ] Navigate to Vocab tab, find a word with kanji commitment
- [ ] Tap Quiz button to start a vocab quiz session
- [ ] Screenshot: multiple choice question
- [ ] Submit an answer
- [ ] Screenshot: Claude's post-answer coaching (with kanji breakdown if possible)
- [ ] Type a tangent question ("how does this kanji relate to X?")
- [ ] Screenshot: Claude's tangent response
- [ ] Screenshot: full scrolled conversation showing the arc

## Hero 2: Reader screenshot
A single screenshot showing the corpus-as-source-of-truth:
- [ ] Navigate to Reader tab → document list (hierarchy of texts)
- [ ] Screenshot: document list
- [ ] Open a document, expand one annotation row showing vocab + grammar chips
- [ ] Screenshot: open document with chips visible

## Supporting screenshots (for README sections, not heroes)
- [ ] Vocab browser showing enrolled words including a transitive/intransitive pair
- [ ] Word detail / enrollment sheet — furigana form picker + kanji commitment UI
- [ ] Grammar browser — equivalence group with Genki + Bunpro + DBJG siblings visible

---

## Notes
- `xcrun simctl io booted screenshot /tmp/sim-NAME.png`
- `xcrun simctl io booted tap X Y`
- Final images → `Pug/Screenshots/`, linked from README.md
- Device: whatever is currently booted (confirmed 2026-03-26)
