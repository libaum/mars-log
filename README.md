# Mars Log

Voice journal. Talk, and it writes itself.

Open Mars Log, speak, and leave. The recording is your permanent record; from it
a transcript, a short summary, a mood, and a few tags are derived — so a spoken
minute becomes something you can read back later. Audio and transcript are the
source of truth; everything derived can be recomputed with a better prompt.

Locked behind a PIN or your fingerprint. Nothing leaves the device except the
audio sent for transcription.

> Early development — the domain and storage layers exist; the UI is being built.

## Features

- **Talk, don't type** — record a thought, the entry writes itself
- **Derived, not manual** — transcript · summary · mood · tags
- **Yours to keep** — audio + transcript stored locally, exportable as a zip
- **Locked** — PIN and biometric unlock
- **Light & dark mode** — double-tap to toggle; follows system by default
- **Private** — no accounts, no tracking, no ads

## Setup

Transcription and analysis run on the phone: Whisper (downloaded on first
use) and an open model, Gemma 4 E2B (~2.6 GB, downloaded on first use).
No journal content goes to a cloud AI.

## Install

```bash
./install_debug.sh     # Debug (installs as "Mars Log Debug")
```

## Tech Stack

- Flutter / Dart
- GetIt (dependency injection)
- ValueNotifier + ValueListenableBuilder (state)
- SharedPreferences + flutter_secure_storage (local & encrypted persistence)
- `record` (audio) · Whisper via `whisper_ggml` (transcript) · Gemma 4 E2B via `flutter_gemma` (analysis) · `local_auth` (unlock)

## Design

Part of the Mars product family. Pure black & white, Outfit font, light weights,
no visual clutter.

## License

MIT
