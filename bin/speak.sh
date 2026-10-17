#!/usr/bin/env bash
# speak.sh TEXT - say TEXT through the local Kokoro service (VoiceMode's TTS) and play it. Local only:
# nothing leaves the machine. Prints nothing; exits non-zero when the text is empty, Kokoro is down, or no
# audio came back. The synthesis request is limited to 30 s. It does not take the VoiceMode conch; the
# caller checks that first.
# Env: SPEAK_URL SPEAK_VOICE (af_sky) SPEAK_CURL (curl) SPEAK_PLAYER (afplay)
set -euo pipefail

TEXT=${1:-}
if [ -z "$TEXT" ]; then echo "usage: speak.sh TEXT" >&2; exit 64; fi
URL=${SPEAK_URL:-http://127.0.0.1:8880/v1/audio/speech}
VOICE=${SPEAK_VOICE:-af_sky}
CURL=${SPEAK_CURL:-curl}
PLAYER=${SPEAK_PLAYER:-afplay}

TMP=$(mktemp "${TMPDIR:-/tmp}/kaching-speak.XXXXXX")
trap 'rm -f "$TMP"' EXIT

BODY=$(jq -nc --arg t "$TEXT" --arg v "$VOICE" '{model:"kokoro", input:$t, voice:$v, response_format:"mp3"}')
"$CURL" -sf -m 30 -H 'Content-Type: application/json' -d "$BODY" -o "$TMP" "$URL"
[ -s "$TMP" ] || exit 1
"$PLAYER" "$TMP"
