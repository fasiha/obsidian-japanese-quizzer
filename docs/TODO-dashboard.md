# Motivational Analytics Dashboard

## Status: COMPLETE 2026-04-14

## Problem

The app had no at-a-glance sense of momentum. You had to open the quiz or browse the lists to know whether you were keeping up with vocab and grammar. Grammar in particular tends to be neglected, and with the vocab browser as the cold-start tab there was no nudge to check grammar health.

## Decisions

**What to show.** Six stats arranged in a 3-row × 2-column grid (Vocab left, Grammar right):

| Row | Vocab | Grammar |
|-----|-------|---------|
| Recall | Lowest predicted recall % across all enrolled facets | Same for grammar |
| Quizzes | Active quiz answers this week ↑↓(last week) | Same |
| New this week | Distinct words newly enrolled this week ↑↓(last week) | Topics newly enrolled this week ↑↓(last week) |

**Where to put it.** As a scrollable card at the top of all three browser tabs (Vocab, Grammar, Reader), inside the `List` as the first `Section` so it scrolls away naturally. Same widget on all three tabs so grammar stats are visible from the vocab cold-start screen.

Hidden during search (Vocab and Grammar tabs) since you are in a focused lookup context.

**Active reviews only.** The `reviews` table is already passive-free — passive facet updates (triggered by `applyPassiveUpdates` / `applyMeaningBonus` in QuizSession) only write to `ebisu_models` and `model_events`, never to `reviews`. No filtering needed.

**Vocab includes transitive pairs.** The dashboard counts vocab reviews as `word_type IN ('jmdict', 'transitive-pair')`, reflecting the UI where both appear in the Vocab tab quiz.

**Calendar weeks, not rolling windows.** "This week" = Monday 00:00 (device local time) to now; "last week" = the full prior Mon–Sun. Computed in Swift via `Calendar(identifier: .iso8601)` and passed as ISO 8601 bind parameters to SQLite. This gives a clean Monday reset: you open the app Monday morning and see `0 ↑(47)`, which motivates catching up to last week's pace.

**Recall coloring.** Ebisu is known to be pessimistic, so thresholds are loose: red below 5%, orange below 50%, primary otherwise.

**Refresh trigger.** Loads on first appear (covers cold start and tab switching). Silently refreshes — no spinner after the first load — when `showQuiz` or `showPlanting` flips back to false in Vocab/Grammar browser views. Document browser passes a fixed `refreshID: 0` since no quiz launches from there.

**Vocab "new this week"** = distinct `word_id` values in `model_events WHERE event LIKE 'learned,%' AND word_type = 'jmdict'`. Each facet fires its own event, so `COUNT(DISTINCT word_id)` collapses them to one count per word.

**Grammar "new this week"** = rows in `grammar_enrollment` by `enrolled_at` date. There is no separate "marked known" timestamp for grammar, so enrollment date is the right proxy.

## Visual redesign: instrument-panel gauges (completed)

Two racecar-style speedometer gauges (Vocab left, Grammar right) side-by-side, implemented in SwiftUI `Canvas`. Each gauge has two rotating needles sharing a central hub: an upper 300° arc for weekly quiz count and a lower 60° arc for new items learned. Surrounding each arc are tick marks with dynamically scaled labels (0 to all-time max week).

**Active metrics (solid needles):** This week's progress (thick colorful needles with neon glow in dark mode, muted in light mode).

**Pace comparison (dashed needle):** Expected weekly pace calculated from last week's activity and hours elapsed in the current week: `(lastWeek / 168) × hoursElapsed`. Shows at a glance whether current week is on track, ahead, or behind.

**Overflow indicator (red wedge):** If this week exceeds all-time weekly max, a red wedge fills the space between old-max and current position, with a glow effect. Visual urgency without numbers.

**Recall bar (sides):** Vertical 60px bar on each side (Vocab left in cyan, Grammar right in orange). Red/orange/green coloring (< 5% / < 25% / ≥ 25%).

**Tap-to-toggle:** Tap the gauges to switch to a compact 3-row table view (Weakest Recall, Quizzes This Week, Learned This Week) with Vocab/Grammar columns. Tap again to return to gauges.

**Dark/light support:** Neon glow (3px blur) in dark mode, subtler (1.5px blur) in light mode. Card background auto-adjusts; recall bar opacity matches scheme.

All-time weekly maximums tracked in `AnalyticsSnapshot` via new SQL aggregations: `SELECT MAX(weekly_count) FROM (SELECT strftime('%Y-W%W', reviewed_at) as week, COUNT(*) as weekly_count FROM reviews ...)` separately for vocab and grammar, and likewise for new items from `model_events`.

## Files changed

- `Pug/Pug/Models/QuizDB.swift` — `AnalyticsSnapshot` struct + `analyticsSnapshot()` (new MARK section at end of `QuizDB`)
- `Pug/Pug/Views/MotivationDashboardView.swift` — new file
- `Pug/Pug/Views/VocabBrowserView.swift` — `dashboardRefreshID` state, `.onChange` for quiz/planting dismiss, dashboard section in `groupedWordList`
- `Pug/Pug/Views/GrammarBrowserView.swift` — same pattern; dashboard shown when `searchText.isEmpty`
- `Pug/Pug/Views/DocumentBrowserView.swift` — dashboard section in `documentList` (fixed `refreshID: 0`)
