# CLAUDE.md

Mars Log is a voice journal: open → tap the circle → talk → done. On stop the
audio (AAC `.m4a`, 16 kHz mono, 64 kbps) is saved locally and sent to the
**Gemini API** (paid tier) in three calls: transcription, analysis (title,
summary, notes, mood label + 0–10 score + six 0–100 dimensions, tags) and
people. No forms, no titles, no save button. Personal app, no store flavor,
E2E-synced to the owner's relay and read on the laptop by `../mars_hub`.

Shared conventions: `../DESIGN.md`. Sync: `../SYNC.md`,
`../mars_sync_relay/SECURITY.md`.

## Commands

```bash
flutter run
flutter test
flutter analyze          # SCREAMING_CASE consts are intentional
./install_debug.sh       # "Mars Log Debug", com.catchingclouds.marslog.debug
```

Release signs with a persistent keystore via `android/key.properties`
(gitignored) and falls back to debug signing without it.

## Deviations from the Mars standard (owner's decision)

- The "default answer is no" feature rule does **not** apply here — stats
  features are welcome.
- Real colour scales are allowed where colour encodes data (mood); reuse the
  existing mood ramps instead of inventing new ones.
- Cloud AI on purpose: on-device Whisper took 30–60 min per entry and the
  transcript went to Gemini anyway, so since 2026-10-02 Gemini does everything.
  Whisper/Gemma/Mistral/Ollama code is gone (git history).

## Hard rules

- **The transcript is the permanent record; the interpretation is
  recomputable.** Every entry stores which model and prompt version produced
  each part (`transcriptionModel`, `analysisModel` + `analysisVersion`,
  `peopleModel` + `peopleVersion`). Bump `kAnalysisVersion` / `kPeopleVersion`
  when a prompt changes.
- **Self-rating never reaches a prompt.** `selfValence` / `selfArousal` are the
  ground truth for calibrating the model's mood; engine calls take only
  text/audio, never the entry (tested in `journal_manager_race_test.dart` and
  Mars Hub's `claude_insight_test.dart`). Null = skipped, never defaulted.
- **Desktop boundary.** `lib/domain`, `lib/sync` and the repositories listed in
  `test/desktop_boundary_test.dart` are imported by Mars Hub; the test is an
  allowlist of imports — new dependencies there are added on purpose.
- `notes` is never edited by hand. It's the dense bullet version of an entry
  (rule: `kNotesPromptRule`) that Mars Hub's Claude evaluation reads instead of
  the too-smoothed summary.
- Hand corrections of people are overrides on the **entry** item
  (`peopleAdded`, `peopleRemoved`), not on the analysis, so re-extraction keeps
  them. Everything shown goes through `effectivePeople(entry, aliases)`.
- Audio stays on the phone (and in the export zip); the relay stores no audio.
  The Gemini key lives in secure storage.

## How the pieces behave

- **Pending, not lost:** a passing error (offline, timeout, 429, 5xx) parks the
  entry as `pending`; retries back off 30 s → 30 min and also fire on
  connectivity and every resume. Each step is skipped if its result exists, so
  a retry continues where it stopped. Rejected key / bad request → `failed`;
  saving a key retries those. Pending entries don't sync until done.
- The whole analysis runs inside an Android foreground service so a
  backgrounded app isn't frozen mid-request. Large audio (> ~14 MB) goes via the
  Files API; a cut-off answer (`finishReason` ≠ STOP) counts as an error.
- **People:** `people` holds names as the text says them ("Bruder");
  `PeopleAliases` maps spellings to one person on read, so merge/split are
  lossless. Extraction learns new spellings for known people — never for one
  the user split off by hand (stored as a self-mapping).
- **Stats** are plain computation, recomputed on every change, no AI. The
  written evaluation (`insight:all`) is made on the laptop by Mars Hub with
  Claude and only synced here.
- **Phone usage** (opt-in): raw Android usage events, copied every 6 h and on
  start/resume because Android keeps them only ~a week; one file per day under
  `usage/`. Read via the local plugin `packages/usage_access/` (a plugin, not a
  `MainActivity` channel, so the WorkManager engine has it too). Nothing is
  evaluated or shown yet.
- Sync items: entry, analysis, `people:aliases`, `insight:all`, `usage:<day>`,
  `usage:apps` (usage merged as sets; a day over ~170 KB stays home so it can't
  sink a push). Not-yet-transcribed recordings are device-local; a remote purge
  turns them into entries of their own instead of deleting them.
- Delete is soft (trash, purged after 30 days).

## Gotchas

- `MainActivity` extends `FlutterFragmentActivity` (needed by `local_auth`).
- In the entry pager, the snap after a swipe is driven by `EntryPager` itself —
  PageView's ballistic snap makes pages pointer-blind.
- AGP 8.11.1 / Kotlin 2.2.20 / Gradle 8.14 are pinned below the rest of the
  ecosystem because of `share_plus`, which is gone since 2026-09-25 — the pin can
  be revisited.

## Not yet

Calendar, tag filters, AI search, yearly reports, "on this day", waveform,
audio on the relay, splitting very long recordings, batch re-analysis on a new
`analysisVersion`, store release infrastructure.
