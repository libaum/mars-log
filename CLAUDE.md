# CLAUDE.md

This file provides guidance when working with code in this repository.

## Project Overview

Mars Log is a voice journal. Open → tap the circle → talk → done. On stop, the audio is saved locally and sent to Gemini in a single multimodal call that returns transcript, summary, mood (label + 0–10 score + six 0–100 dimensions) and tags as structured JSON. No forms, no titles, no save button. Part of the Mars product family.

**Deliberate philosophy exception:** unlike the rest of Mars, this app is *not* offline/backendless — audio + transcript go to the Gemini cloud. It is primarily a personal-use app. Everything except the AI analysis stays on device.

**Core principle:** the journal (audio + transcript) is permanent; the interpretation (summary/mood/tags) is recomputable. Every entry records `analysisModel` + `analysisVersion`, and the detail screen offers "Neu analysieren".

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
| `LocalStorageService` | SharedPreferences: theme + lock flags + analysis version (non-sensitive) |
| `SecureStorageService` | flutter_secure_storage: Gemini API key + PIN hash (sha256) |
| `GeminiService` | One multimodal `generateContent` call (audio in, structured JSON out) |
| `ExportService` | Zip export (`entries.json` + audio) via share sheet; import + merge by id |
| `RecordingManager` | Microphone lifecycle; records WAV 16 kHz mono; timer |
| `JournalManager` | Core state: `entriesNotifier` + `trashNotifier`, `createFromAudio`, `reanalyze`, `delete` (soft, to trash), `restore`, `purge`, `emptyTrash` |
| `SettingsManager` | API key + PIN/biometric toggles |
| `LockManager` | Optional PIN/biometric gate; re-locks on app resume |
| `ThemeManager` | Light/dark following system (Mars pattern) |

### Recording → analysis flow
Tap stop → `RecordingManager.stop()` returns a `RecordingResult` → `JournalManager.createFromAudio` writes a provisional `analyzing` entry (UI shows a spinner) → `GeminiService.analyze` → entry becomes `ready` (or `failed` with the audio kept for retry).

### Persistence
`<appDocuments>/entries.json` (index) + `<appDocuments>/audio/<id>.wav`. Transcripts can be long, so entries live in a JSON file rather than SharedPreferences, which also makes export a simple directory zip. No backend/sync.

## Project Structure
```
lib/
├── data/        # local_storage, secure_storage, journal_repository, gemini_service, export_service
├── domain/      # journal_entry (model + AnalysisResult + EntryStatus), mood (emoji/date helpers)
├── logic/       # recording_manager, journal_manager, settings_manager, lock_manager
├── pages/       # main / entry_detail / settings / lock / about screens + widgets/
├── services/    # service_locator.dart
├── theme/       # theme_constants (SCREAMING_CASE), theme_manager
└── main.dart    # MarsLog + AppRoot (lock gate + lifecycle re-lock)
```

## Key Interactions
- **Tap** the circle → start/stop recording (entry then analyzes itself)
- **Tap** a timeline row → entry detail (playback, transcript, summary, mood, tags, re-analyze, delete)
- **Swipe left** on a row → delete (asks first, then moves to the trash)
- **Long-press** the header/record area → Settings
- **Double-tap** anywhere → toggle theme

## Setup notes
- Gemini API key is entered in Settings (Google AI Studio, free tier). Without it, entries fail with a clear message and can be re-analysed once a key is set.
- Android: `RECORD_AUDIO` + `INTERNET` permissions; `MainActivity` extends `FlutterFragmentActivity` (required by `local_auth`); `minSdk` 23.
- AGP 8.11.1 / Kotlin 2.2.20 / Gradle 8.14 (matches mars_fx; the Flutter 3.44 template's preview AGP 9 breaks `flutter_secure_storage` dexing).

## Build Variants
| Variant | Package | App Name |
|---|---|---|
| Debug | `com.catchingclouds.marslog.debug` | Mars Log Debug |
| Release | `com.catchingclouds.marslog` | Mars Log |

Release currently uses debug signing (slim setup — no Play upload keystore yet).

## Not in V1 (future)
Insights/statistics, calendar, tag filters, AI search, monthly/yearly reports, word stats, "on this day" memories, recording pause/waveform, m4a/opus + Gemini Files API for long recordings, batch re-analysis on new `analysisVersion`, release infrastructure (keystore/fastlane/store assets).
