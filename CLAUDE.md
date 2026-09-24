# CLAUDE.md

This file provides guidance when working with code in this repository.

## Project Overview

Mars Log is a voice journal. Open → tap the circle → talk → done. On stop, the audio is saved locally, transcribed on the phone by Whisper, and the transcript analysed on the phone by Gemini Nano (AICore) into summary, mood (label + 0–10 score + six 0–100 dimensions) and tags as JSON. No forms, no titles, no save button. Part of the Mars product family.

**AI stays on the device:** no journal content goes to a cloud AI (the Gemini API was removed 2026-09-24). The only network use is the optional E2E-encrypted sync hub, the one-time Whisper model download, map tiles and Android's geocoder for place names. The device is assumed to support Gemini Nano (the owner's phone does); on one that doesn't, analysis fails with a clear message and the transcript still exists.

**Core principle:** the transcript is the permanent record; the interpretation (summary/mood/tags) is recomputable. Every entry records `analysisModel` + `analysisVersion`, and the detail screen offers "Neu analysieren". Audio is kept alongside the transcript but is *optional* — the "Audio nach Transkription löschen" setting discards it once `ready` (`audioDeleted` flag); re-analysis then runs from the transcript text (`AnalysisEngine.analyzeText`) instead of the audio. Each entry can also carry an optional recording location (`latitude`/`longitude` + editable `place` label).

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
| `SecureStorageService` | flutter_secure_storage: PIN hash (sha256); deletes the old Gemini API key on start |
| `OnDeviceAnalysisEngine` (`AnalysisEngine`) | Whisper `small` (`whisper_ggml`, model downloaded on first use) → transcript; Gemini Nano (`gemini_nano_android`) → summary/mood/dimensions/tags JSON, and the monthly recap (chunked, Nano's input window is small). `kAnalysisVersion` 2 |
| `ExportService` | Zip export (`entries.json` + audio) via share sheet; import + merge by id |
| `RecordingManager` | Microphone lifecycle; records WAV 16 kHz mono; timer |
| `LocationService` | Best-effort GPS + reverse-geocoded label for a new entry; silent/nullable, never throws |
| `NotificationManager` | Optional evening reminder; schedules a rolling window of one-shots, skipping days that already have a log |
| `AnalysisTaskService` | Holds an Android foreground service (`flutter_foreground_task`, `dataSync`) for the duration of an analysis, so a backgrounded app isn't frozen mid-request. Ref-counted, no task handler — the work stays in the main isolate |
| `JournalManager` | Core state: `entriesNotifier` + `trashNotifier`, `createFromAudio`, `reanalyze`, `delete` (soft, to trash), `restore`, `purge`, `emptyTrash`, `setDay`, `setPlace`, `resumePending` |
| `SettingsManager` | PIN/biometric toggles |
| `LockManager` | Optional PIN/biometric gate; re-locks on app resume |
| `ThemeManager` | Light/dark following system (Mars pattern) |

### Recording → analysis flow
Tap stop → `RecordingManager.stop()` returns a `RecordingResult` → `JournalManager.createFromAudio` writes a provisional `analyzing` entry (UI shows a spinner) → best-effort `LocationService` stamp → `AnalysisEngine.analyzeAudio` (Whisper, then Nano) → entry becomes `ready` (or `failed` with the audio kept for retry). On success, if the "delete audio after transcription" setting is on, the audio is discarded and `audioDeleted` set.

The whole analysis runs inside `AnalysisTaskService.run`, so Android keeps the process out of the cached/frozen bucket while Whisper runs. Gemini Nano itself only runs while the app is in the foreground (AICore rule), so an entry recorded right before switching away can fail. As a backstop, `JournalManager.resumePending()` runs on app start and on every resume and re-runs entries still stuck in `analyzing`, plus every `failed` one once per session.

### Persistence
`<appDocuments>/entries.json` (index) + `<appDocuments>/audio/<id>.wav`. Transcripts can be long, so entries live in a JSON file rather than SharedPreferences, which also makes export a simple directory zip. No backend/sync.

## Project Structure
```
lib/
├── data/        # local_storage, secure_storage, journal_repository, analysis_engine, on_device_analysis_service, export_service
├── domain/      # journal_entry (model + AnalysisResult + EntryStatus), mood (emoji/date helpers)
├── logic/       # recording_manager, journal_manager, settings_manager, lock_manager, location_service, notification_manager
├── pages/       # main / entry_detail / settings / lock / about screens + widgets/
├── services/    # service_locator.dart
├── theme/       # theme_constants (SCREAMING_CASE), theme_manager
└── main.dart    # MarsLog + AppRoot (lock gate + lifecycle re-lock)
```

## Key Interactions
- **Tap** the circle → start/stop recording (entry then analyzes itself)
- **Tap** a timeline row → entry detail (playback, location label, transcript, summary, mood, tags, re-analyze, delete). Tap the date to backdate, tap the location to set/adjust the label.
- **Swipe left/right** in the entry detail → next/previous day's entry (pager over all entries, oldest left)
- **Long-press** a timeline row → selection mode: tap rows to (de)select, bottom bar offers "Alle"/"Keine" and "Kopieren" (transcripts of the picked days, oldest first, each under its date, joined by `---`, to the clipboard). Back or ✕ leaves the mode; swipe-to-delete is off while selecting.
- **Swipe left** on a row → delete, moves to the trash (same gesture as mars_thoughts: arms with a haptic once pulled to the stop, red reveal, no confirm dialog)
- **Long-press** the header/record area → Settings
- **Double-tap** anywhere → toggle theme

## Setup notes
- Settings → "Analyse-Modelle vorbereiten" downloads Whisper ahead of the first recording and checks that Gemini Nano is available.
- Android: `RECORD_AUDIO` + `INTERNET` + `POST_NOTIFICATIONS` + `ACCESS_COARSE/FINE_LOCATION` permissions; `MainActivity` extends `FlutterFragmentActivity` (required by `local_auth`); `minSdk` 23. Location is requested at first recording and is optional — denial just leaves entries without a location.
- AGP 8.11.1 / Kotlin 2.2.20 / Gradle 8.14, pinned below the rest of the Mars ecosystem (2026-09): `share_plus` >=13.0.0 (required once `file_picker` is bumped past 8.x for AGP 9's compileSdk 36 floor) fails `compileDebugKotlin` under AGP 9's built-in Kotlin — unresolved references to its own `ShareSuccessManager`/`SharePlusPendingIntent` classes. Revisit once `share_plus` ships an AGP-9-compatible release.

## Build Variants
| Variant | Package | App Name |
|---|---|---|
| Debug | `com.catchingclouds.marslog.debug` | Mars Log Debug |
| Release | `com.catchingclouds.marslog` | Mars Log |

Release currently uses debug signing (slim setup — no Play upload keystore yet).

## Not in V1 (future)
Insights/statistics, calendar, tag filters, AI search, monthly/yearly reports, word stats, "on this day" memories, recording pause/waveform, larger Whisper model / laptop transcription, batch re-analysis on new `analysisVersion`, release infrastructure (keystore/fastlane/store assets).
