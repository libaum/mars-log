#!/bin/bash
set -e
# env.json (gitignored) provides GEMINI_API_KEY as a compile-time fallback.
# Runs fine without it — the key can also be entered in the app's Settings.
DEFINE=""
[ -f env.json ] && DEFINE="--dart-define-from-file=env.json"
flutter run --debug $DEFINE
