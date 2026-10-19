# Mars Log

A voice journal. Open it, talk, leave.

The recording is the permanent record. From it the app derives a transcript, a short summary, a mood and a few tags, so a spoken minute becomes something you can read back later. Audio and transcript are the source of truth, everything derived can be recomputed.

Status: in development, not on Google Play yet.

## What it does

- Record a thought and the entry writes itself: transcript, summary, mood, tags.
- Stats and a map of your entries.
- Audio and transcript stay on the device and can be exported as a zip.
- Locked behind a PIN or your fingerprint.
- Deleted entries go to a trash first.
- Dark and light mode (double tap). No accounts, no tracking, no ads.

## Setup

Transcription and analysis run through the Gemini API (paid tier). Put your API key in Settings. Recordings and transcripts are sent to Google for that. Nothing else leaves the phone, and the audio stays on the device as well.

## Build

You need the [Flutter SDK](https://docs.flutter.dev/get-started/install).

```bash
./install_debug.sh      # "Mars Log Debug"
```

## Under the hood

Flutter and Dart, GetIt for DI, `ValueNotifier` for state, SharedPreferences and `flutter_secure_storage` for storage. `record` for audio, `local_auth` for the unlock, `connectivity_plus` to retry when back online. See [CLAUDE.md](CLAUDE.md).

Part of [Mars](https://github.com/libaum/mars), a family of small, calm apps.

## License

MIT
