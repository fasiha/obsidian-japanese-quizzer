# Persist LLM Chat Turns

## Problem

The iOS app makes many calls to Haiku — both mostly-canned (quiz multiple-choice generation, grammar hints) and highly-organic (user questions in WordDetailSheet, GrammarDetailSheet, TransitivePairDetailSheet). None of these turns are currently persisted. This means:

- Conversations in detail sheets are lost when the sheet is dismissed.
- There is no way to audit Haiku's answers for quality or prompt-tuning opportunities.
- HistoryView shows quiz results but not the discussion that followed.

## Decision: separate `chat.sqlite` file

Chat logs go in a new `chat.sqlite`, not in `quiz.sqlite`. Rationale:

- Chat data has a different value profile: losing it is inconvenient but not catastrophic, unlike the Ebisu models in `quiz.sqlite` which represent weeks of spaced-repetition history.
- Growth rates differ. Quiz rows accumulate slowly; chat turns can multiply quickly with conversational use.
- Keeping them separate means `chat.sqlite` can be deleted, rotated, or excluded from backups without touching quiz data.

## Schema

```sql
CREATE TABLE turns (
  id          INTEGER PRIMARY KEY,
  ts          INTEGER NOT NULL,       -- unix epoch milliseconds
  context     TEXT    NOT NULL,       -- e.g. 'word:1234567', 'quiz:1234567:reading-to-meaning'
  role        TEXT    NOT NULL,       -- 'user' | 'assistant'
  content     TEXT    NOT NULL,
  template_id TEXT                    -- NULL = organic; e.g. 'vocab-mc-reading-to-meaning'
);

CREATE INDEX turns_context ON turns(context);
```

### Column notes

- **context**: tag identifying the subject of the turn. Populated via the `ChatContext` Swift enum (see `ChatDB.swift`), which enforces a consistent format at every call site. Lets us pull all turns for a given word or grammar topic without a foreign key schema.
- **template_id**: non-NULL for turns whose prompt is code-generated (canned). NULL for organic user-initiated exchanges. A descriptive string without a version suffix — if a prompt changes significantly, git blame on the template string is the version history. Storing the full prompt text is intentional: the prompt in the repo may diverge from what was actually sent months ago.

### `ChatContext` enum

Every call to `AnthropicClient.send()` must supply a `ChatContext` value and an explicit `templateId: String?`. Both are required (no defaults) so the compiler rejects any new call site that forgets to identify itself.

The enum cases and their `context` column tags:

| Case | Tag format |
|---|---|
| `.wordExplore(wordId:)` | `word:<id>` |
| `.reviewDetail(wordId:quizType:)` | `review:<id>:<quizType>` |
| `.transitivePairDetail(pairId:)` | `pair:<id>` |
| `.grammarDetail(topicId:)` | `grammar:<id>` |
| `.vocabQuiz(wordId:facet:)` | `quiz:<id>:<facet>` |
| `.grammarQuiz(topicId:facet:)` | `quiz:<id>:<facet>` |
| `.grammarQuizGeneration(topicId:)` | `quiz-gen:<id>` |

`grammarQuizGeneration` covers internal question-generation helpers (gap disambiguation, answer refinement, vocabulary gloss) that run without a specific facet.

## Compression

GRDB has no built-in row compression. iOS APFS may apply transparent compression but it cannot be relied upon. LLM turns are typically 100–500 bytes of UTF-8; even at 1 000 turns per month that is under 500 KB uncompressed. Defer compression unless storage becomes a real concern.

## Work plan

1. ~~**Create `chat.sqlite`** with the schema above, opened alongside `quiz.sqlite` at app launch via a new `ChatDB` (GRDB `DatabaseQueue`). **Done** — `ChatDB.swift`, wired in `PugApp.swift`.~~
2. ~~**Write-only logging**: `ChatDB.append(context:role:content:templateId:)` wired into every Haiku call site via required parameters on `AnthropicClient.send()`. **Done.**~~
3. ~~**Detail sheet persistence**: in WordDetailSheet, GrammarDetailSheet, and TransitivePairDetailSheet, load prior turns for the relevant context on appear and surface them above the chat input. Filter to organic turns only (templateId is NULL) so canned prompt/response pairs don't clutter the view. **Done** — `ChatDB.organicTurns(context:)` added; all three detail sheets load past turns on `.task` and render them via the shared `ChatBubble` view.~~
4. ~~**HistoryView + ReviewDetailSheet integration**: each past quiz row gets a collapsible "Chat" disclosure group; tapping the row opens ReviewDetailSheet which shows the quiz summary, the original quiz-session chat, and a chat input to continue the conversation — all under the same `vocabQuiz` context. **Done** — session UUID (`QuizItem.id`) is now stored in both `chat.sqlite` turns and the `reviews` table (`session_id` column, migration v11), replacing the fragile time-window query. `reviewDetail` context removed entirely.~~

## Future directions

- **Audit tooling**: export turns where `template_id` is not NULL and pipe to Sonnet or Opus for prompt critique. A simple Node.js script that reads `chat.sqlite` and calls the Anthropic API would suffice.
- **Rotation/pruning**: add a setting to delete turns older than N days, or cap `chat.sqlite` at a size limit. Low priority given the small footprint.
- **Search**: full-text search over `content` using SQLite FTS5. Useful once the chat history is large enough to be hard to browse manually.
