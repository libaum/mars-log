# CLAUDE.md

This file provides guidance when working with code in this repository.

## Project Overview

Mars Log is a voice journal. Open → tap the circle → talk → done. On stop, the audio (AAC `.m4a`, 16 kHz mono, 64 kbps) is saved locally and sent to the **Gemini API** (paid tier) in three separate calls: transcription (audio → transcript), analysis (transcript → title, summary, mood label + 0–10 score + six 0–100 dimensions, tags) and people (transcript + the known people → who is mentioned). No forms, no titles, no save button. Part of the Mars product family.

**Cloud AI, deliberately:** on-device Whisper took 30–60 min per entry and the transcript went to Gemini anyway, so since 2026-10-02 Gemini does everything (Whisper, Gemma, Mistral and the hub's Ollama analysis were removed — they are in git history). Models are settings (`gemini_transcription_model` / `gemini_analysis_model`, default `gemini-3.8-flash`), the key is in secure storage. The audio stays on the phone (and in the export zip); the sync hub has no audio storage — that's a separate, later task.

**Core principle:** the transcript is the permanent record; the interpretation is recomputable. Every entry records `transcriptionModel`, `analysisModel` + `analysisVersion` (prompt version) and `peopleModel` + `peopleVersion`; the detail screen offers "Neu analysieren" / "Neu transkribieren". Audio is kept alongside the transcript but is *optional* — the "Audio nach Transkription löschen" setting discards it once `ready` (`audioDeleted`). Each entry can carry a recording location (`latitude`/`longitude` + editable `place`).

**Pending, not lost:** a passing error (offline, timeout, 429, 5xx — `AnalysisException.transient`) parks the entry as `EntryStatus.pending`; `JournalManager` retries with backoff (30 s doubling to 30 min), at once when connectivity returns (`connectivity_plus`, in `main.dart`) and on every resume. Each step is skipped when its result is there, so a retry continues where it stopped. Recordings not yet transcribed are listed in `untranscribed` (device-local like the files; a sync purge turns them into entries of their own instead of deleting them). Pending entries don't sync until done. A rejected key / bad request → `failed`; saving a key retries failed entries.

**People:** `people` holds the names *as the text says them* ("Bruder"); `PeopleAliases` (`lib/domain/people_aliases.dart`, `people.json`, sync item `people:aliases`, last-write-wins as a whole) maps spellings to one person and is applied on read, so merge/split are lossless. The extraction gets the known people + aliases in its prompt; when it matches a new spelling to a known person, the aliases learn it (`learn`) — never for a spelling split off by hand (a split is stored as a self-mapping). Corrections by hand are overrides in the **entry item** (not the analysis item), so every re-extraction keeps them: `peopleAdded`, `peopleRemoved` (tombstones: extracted spellings + shown name). Everything shown goes through `effectivePeople(entry, aliases)`. Settings → "Personen neu erkennen" backfills all entries below `kPeopleVersion` (idempotent; "Alle …" redoes every entry).

**Self-rating:** `selfValence` / `selfArousal` (1–10, null = skipped, never defaulted), `selfRatedAt`, `selfRatingTiming` (`before`/`after` — Settings → Selbsteinschätzung, default after). Ground truth for calibrating the model's mood: it must never reach a prompt — the engine's calls take only text/audio, never the entry (tested in `journal_manager_race_test.dart` and the hub's `claude_insight_test.dart`).

**Stats:** everything in `lib/domain/stats.dart` / `place_stats.dart` is plain computation, recomputed on every journal change — no AI. The one written evaluation over everything ("Auswertung", sync item `insight:all`, model `Insight` in `lib/domain/insight.dart`, stored in `insights.json` next to `entries.json`) is made on the laptop by the hub with Claude Code and only synced here. Places: grid cells within 400 m fold into the densest one, then clusters geocoded to the same "Stadt, Stadtteil" merge.

## Common Commands

```bash
flutter run              # run on connected device
flutter analyze          # static analysis (SCREAMING_CASE consts are intentional Mars style)
./install_debug.sh       # flutter run --debug (app: "Mars Log Debug", pkg: com.catchingclouds.marslog.debug)
flutter build apk --debug
```

## Architecture

### Dependency Injection
Singletons registered via `GetIt` in `lib/services/service_locator.dart`, initialized in `main()` before `runApp`. Registration order matters: async `LocalStorageService` and `JournalRepository` are constructed first (others read them in their constructors).

### State Management
Managers expose state via `ValueNotifier`; UI subscribes with `ValueListenableBuilder`. No Bloc/Provider/Riverpod.

### Key Classes
| Class | Responsibility |
|---|---|
| `JournalRepository` | Owns `entries.json` + `audio/` in app documents dir; in-memory list, persisted on every mutation. Delete is a soft-delete (`deletedAt`); trashed entries are purged on load after `trashRetention` (30 days) |
| `LocalStorageService` | SharedPreferences: theme + lock flags + analysis version + reminder + "delete audio after transcription" flag (non-sensitive) |
| `SecureStorageService` | flutter_secure_storage: Gemini API key, PIN hash (sha256); deletes the old Mistral key on start |
| `GeminiEngine` (`AnalysisEngine`) | `transcribe` (audio inline as base64 up to ~14 MB, above that the Files API with resumable upload, deleted afterwards; one call per recording; a cut-off answer — `finishReason` ≠ STOP — is an error), `analyzeText`, `extractPeople`, `summarizeMonth`. Plain `dart:io` `HttpClient`, key in the `x-goog-api-key` header, `thinkingLevel: low`. `kAnalysisVersion` 4, `kPeopleVersion` 1 |
| `ExportService` | Zip export (`entries.json`, `location_history.json`, `audio/`) built on disk and copied into a SAF folder (manual "Export" and the daily backup); streamed import merges entries by id and restores missing audio |
| `RecordingManager` | Microphone lifecycle; records AAC `.m4a` 16 kHz mono 64 kbps (~0.5 MB/min); timer |
| `LocationService` | Best-effort GPS + reverse-geocoded label for a new entry; silent/nullable, never throws |
| `NotificationManager` | Optional evening reminder; schedules a rolling window of one-shots, skipping days that already have a log |
| `AnalysisTaskService` | Holds an Android foreground service (`flutter_foreground_task`, `dataSync`) for the duration of an analysis, so a backgrounded app isn't frozen mid-request. Ref-counted, no task handler — the work stays in the main isolate |
| `JournalManager` | Core state: `entriesNotifier` + `trashNotifier`, `createFromAudio`, `appendRecording`, `reanalyze`, `resumePending` (+ backoff, `retryAt`), `backfillPeople`, `addPerson` / `removePerson` / `restorePeople`, `setSelfRating`, `delete` (soft, to trash), `restore`, `purge`, `emptyTrash`, `setDay`, `setPlace` |
| `SettingsManager` | PIN/biometric toggles |
| `LockManager` | Optional PIN/biometric gate; re-locks on app resume |
| `ThemeManager` | Light/dark following system (Mars pattern) |

### Recording → analysis flow
Tap stop ("Senden") → `RecordingManager.stop()` returns a `RecordingResult` → `JournalManager.createFromAudio` writes a provisional `analyzing` entry (the recording in `untranscribed`) → the self-rating sheet opens (setting "after") → best-effort `LocationService` stamp → `_process`: transcribe (stored at once) → analyse → people → `ready`. A passing error → `pending` (retried), anything else → `failed`. On success, if "delete audio after transcription" is on, the audio is discarded.

The whole run sits inside `AnalysisTaskService.run` (foreground service), so Android doesn't freeze the process mid-request. `resumePending()` runs on start, on every resume, on connectivity and from the backoff timer: `analyzing` leftovers, due `pending` ones, and each `failed` one once per session.

### Persistence
`<appDocuments>/entries.json` (index) + `<appDocuments>/audio/<id>.m4a` (older entries: `.wav`). Transcripts can be long, so entries live in a JSON file rather than SharedPreferences, which also makes export a simple directory zip. No backend/sync.

## Project Structure
```
lib/
├── data/        # local_storage, secure_storage, journal_repository, analysis_engine, gemini_engine, export_service
├── domain/      # journal_entry (model + AnalysisResult + EntryStatus), people_aliases (aliases, effectivePeople, KnownPerson), stats, mood
├── logic/       # recording_manager, journal_manager, settings_manager, lock_manager, location_service, notification_manager
├── pages/       # main / entry_detail / settings / lock / about screens + widgets/
├── services/    # service_locator.dart
├── theme/       # theme_constants (SCREAMING_CASE), theme_manager
└── main.dart    # MarsLog + AppRoot (lock gate + lifecycle re-lock)
```

## Key Interactions
- **Tap** the circle → start/stop recording (entry then analyzes itself)
- **Tap** a timeline row → entry detail (playback, location label, transcript, summary, mood, self-rating, tags, people, re-analyze, delete). Tap the date to backdate, the location to set/adjust the label, SELBST to (re)rate. People are pills: tap one → removed, with a „Rückgängig“ snackbar; „+ Person“ → sheet with suggestions (recent ×3 + total, `suggestedPeople`), search over names and aliases, „Neue Person …“; it stays open for several.
- **Swipe left/right** in the entry detail → next/previous day's entry (`EntryPager`, oldest left). A drag that starts vertical locks the pager, so scrolling never wobbles sideways; the snap after a swipe is driven by `EntryPager` itself (PageView's ballistic snap makes the pages pointer-blind), and a touch during it lands the page and scrolls/swipes on at once; **pull down** at the top closes the entry. At the bottom, the day's route from the location history (tap → fullscreen)
- **Long-press** a timeline row → selection mode: tap rows to (de)select, bottom bar offers "Alle"/"Keine" and "Kopieren" (transcripts of the picked days, oldest first, each under its date, joined by `---`, to the clipboard). Back or ✕ leaves the mode; swipe-to-delete is off while selecting.
- **Swipe left** on a row → delete, moves to the trash (same gesture as mars_thoughts: arms with a haptic once pulled to the stop, red reveal, no confirm dialog)
- **Long-press** the header/record area → Settings
- **Double-tap** anywhere → toggle theme

## Setup notes
- Settings → "Gemini API-Key" (Google AI Studio, with billing = paid tier, no training on the content). Without it every entry fails with a clear message and is retried once the key is saved.
- Stats → MENSCHEN × STIMMUNG → "Alle Namen": long-press (or „Auswählen“) to pick several names → „Zusammenführen“ → main name (most mentioned preselected). Tap a person → aliases with entry counts, „Trennen“, „Umbenennen“.
- Android: `RECORD_AUDIO` + `INTERNET` + `POST_NOTIFICATIONS` + `ACCESS_COARSE/FINE_LOCATION` permissions; `MainActivity` extends `FlutterFragmentActivity` (required by `local_auth`); `minSdk` 23. Location is requested at first recording and is optional — denial just leaves entries without a location.
- AGP 8.11.1 / Kotlin 2.2.20 / Gradle 8.14, pinned below the rest of the Mars ecosystem (2026-09): originally because `share_plus` >=13 broke under AGP 9. `share_plus` is gone since 2026-09-25 (export no longer shares), so this can be revisited.

## Build Variants
| Variant | Package | App Name |
|---|---|---|
| Debug | `com.catchingclouds.marslog.debug` | Mars Log Debug |
| Release | `com.catchingclouds.marslog` | Mars Log |

Release currently uses debug signing (slim setup — no Play upload keystore yet).

## Not in V1 (future)
Calendar, tag filters, AI search, yearly reports, word stats, "on this day" memories, waveform, audio on the sync hub, splitting very long recordings, batch re-analysis on new `analysisVersion`, release infrastructure (keystore/fastlane/store assets).
