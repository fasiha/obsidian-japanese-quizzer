# Audio Lyrics Feature — Decisions and Work Plan

Play timed audio clips inline while reading lyrics in the Pug iOS app,
mirroring the Obsidian timed-audio plugin.

---

## Background

`Music/*.md` use `<audio data-src="my-audio.m4a#t=10.48,14.76" />` tags — one per
lyric line — produced by `Music/inject-timestamps.mjs`. The Obsidian timed-audio plugin
resolves the vault-relative path and plays the clip.

The `.m4a` files live inside the Obsidian vault. Obsidian on iOS exposes its vault
folder via the Files app, so Pug can gain persistent read access using a one-time folder
picker and a security-scoped bookmark — no network transfer or bundling needed.

Related: https://github.com/fasiha/obsidian-timed-audio

---

## Decisions

### D1 — Audio format: M4A/AAC

All audio files are `.m4a`. Convert existing `.webm` files with:

```sh
ffmpeg -i input.webm -c:a aac -b:a 128k output.m4a
```

M4A has frame-accurate seeking on iOS and works with the simpler `AVAudioPlayer` API.
The timed-audio Obsidian plugin works fine with `.m4a`.

### D2 — Audio playback: `AVAudioPlayer` singleton

Use a single shared `AVAudioPlayer` instance so only one clip plays at a time. Tapping
a new line replaces the player; tapping the same line again stops it.

- Set `currentTime = start`, call `play()`
- Stop via a `DispatchWorkItem` fired after `(end − start)` seconds

### D3 — Audio file delivery and lookup strategy

This is an **opt-in feature**. Users without audio files silently see no play buttons.

**File lookup order** (first hit wins):

1. **Pug's own Documents folder** — filename match only (e.g. `Shiki no Uta.m4a`),
   ignoring directory structure. Files land here via the Files app.
2. **Security-scoped bookmark to an external folder** (e.g. the Obsidian vault) —
   one-time folder picker in Settings, bookmark persisted in `UserDefaults`. Pug reads
   directly from the external folder without copying.

This means:
- Family members without Obsidian can drop files into Pug via the Files app — no setup.
- Users with Obsidian point Pug at the vault once and get all files automatically.
- If neither source has the file, the play button is hidden (not shown as disabled).

**Future work — Pug as share target for `.m4a`:** register Pug to appear in the iOS
share sheet for audio files. AirDropped or shared `.m4a` files are saved to Pug's
Documents folder automatically. `AudioFileFinder` step 1 already handles it — no other
changes needed at that point.

### D4 — Timestamp parsing: extend existing `data-src` stripping pass

`DocumentReaderView` already strips `<audio>` tags via `stripUnsupportedHtmlTags`
(commit `18c0ab0`). Extend that same pass to *capture* before stripping: extract
`(audioFile, start, end)` from `data-src="foo.m4a#t=START,END"`. Store in
`audioClipMap: [Int: AudioClip]` alongside `vocabMap`/`grammarMap`.

### D5 — Scope: DocumentReaderView only (for now)

Audio playback belongs in `DocumentReaderView`, not in quiz views.

### D6 — Music files are already in the corpus

`Music/Shiki no Uta.md` has `llm-review: true` and is already visible in
`DocumentReaderView`. No corpus changes needed.

---

## Work Plan

### Phase 1 — Parsing and data model

1. **`AudioClip` struct**
   ```swift
   struct AudioClip {
       let audioFile: String   // filename only, e.g. "Shiki no Uta.m4a"
       let start: Double       // seconds
       let end: Double         // seconds
   }
   ```

2. **Extend `DocumentReaderView` line-parsing** (in `.task`)
   - Before `stripUnsupportedHtmlTags` discards the tag, extract with regex:
     `data-src="([^"#]+?\.m4a)#t=([0-9.]+),([0-9.]+)"`
   - Populate `@State private var audioClipMap: [Int: AudioClip]`
   - Stripping already happens — no further change needed to rendering

### Phase 2 — Audio file lookup

3. **`AudioFileFinder`** (`Pug/Pug/Models/AudioFileFinder.swift`)
   - `static func findURL(for filename: String, externalFolderBookmark: Data?) -> URL?`
   - Step 1: check Pug's own Documents folder for a file matching `filename` (basename
     only). Return URL if found.
   - Step 2: if `externalFolderBookmark` is set, resolve it, call
     `startAccessingSecurityScopedResource()`, look for `filename` in the root of that
     folder. Return URL if found (caller must stop access when done).
   - Returns `nil` if neither source has the file.

4. **External folder bookmark in Settings** (`SettingsView.swift`)
   - New "Audio files" section in Settings
   - Shows current bookmarked folder path (or "Not configured")
   - "Choose folder" button — `.fileImporter` with `allowedContentTypes: [.folder]`
   - Saves `url.bookmarkData(options: .minimalBookmark)` to `UserDefaults`

### Phase 3 — Playback

5. **`ClipPlayer` observable class** (`Pug/Pug/Models/ClipPlayer.swift`)
   - `@Observable`, injected via environment
   - `func play(clip: AudioClip, externalFolderBookmark: Data?)`
     - Calls `AudioFileFinder.findURL`; does nothing if nil
     - Creates `AVAudioPlayer(contentsOf:)`, sets `currentTime = clip.start`, calls `play()`
     - Schedules `DispatchWorkItem` after `(clip.end − clip.start)` seconds to stop
   - `func stop()`
   - `var currentClip: AudioClip?` — for button state (▶ vs ⏹)

6. **Inject `ClipPlayer` into environment** in `PugApp.swift`

### Phase 4 — UI

7. **Inline play button in `DocumentReaderView`**
   - At parse time, check file availability via `AudioFileFinder` for each entry in
     `audioClipMap`; store results in `audioAvailableLines: Set<Int>`
   - Render a ▶ / ⏹ button only for lines in `audioAvailableLines`
   - No button, no nudge for unavailable files — feature is invisible to users without
     audio files

---

## Files to create / modify

| File | Change |
|---|---|
| `Pug/Pug/Models/AudioFileFinder.swift` | New — two-source file lookup (Documents then external bookmark) |
| `Pug/Pug/Models/ClipPlayer.swift` | New — AVAudioPlayer singleton, state, DispatchWorkItem stop |
| `Pug/Pug/Views/SettingsView.swift` | Add "Audio files" section with folder picker |
| `Pug/Pug/Views/DocumentReaderView.swift` | Parse audio clips from data-src, add conditional play buttons |
| `Pug/Pug/PugApp.swift` | Inject `ClipPlayer` into environment |
| `README.md` / `App.md` | Document audio feature and vault setup step |
