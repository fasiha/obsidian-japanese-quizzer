# iOS SwiftUI architecture rules (Pug app)

## Environment vs explicit props

**Observable shared data → SwiftUI environment.**
`VocabCorpus`, `TransitivePairCorpus`, `GrammarStore` (wrapping `GrammarManifest?`), and `CorpusStore`
(wrapping `[CorpusEntry]`) are injected at `AppRootView` via `.environment()` and
read with `@Environment` at the leaf views that need them. Do not thread these as
explicit `let` props through intermediate views.

**Service objects with side effects → explicit props.**
`db: QuizDB`, `client: AnthropicClient`, `toolHandler: ToolHandler?`, and
`jmdict: any DatabaseReader` stay as explicit parameters. They are infrastructure,
not shared data, and keeping them explicit makes it obvious which views perform
I/O or API calls.

**Before adding a new parameter to any view, ask:**
- Will this need to reach leaf views several layers down? If yes, prefer environment.
- Does it have side effects (database writes, network calls)? If yes, keep it explicit.
