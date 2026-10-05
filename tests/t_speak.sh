#!/usr/bin/env bash
# speak.sh: posts text to the local Kokoro service and plays the result. curl and the player are stubs.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
S="$BIN/speak.sh"
CALLS="$WORK/calls"; PLAYED="$WORK/played"
CURL="$WORK/curl-stub.sh"; PLAYER="$WORK/player-stub.sh"
mkdir -p "$WORK/tmp"

# stub curl: one argument per line into $CALLS; writes fake audio to the -o target unless told to fail
cat >"$CURL" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$CALLS"
out=""
while [ \$# -gt 0 ]; do
  if [ "\$1" = -o ]; then out=\$2; fi
  shift
done
if [ -n "\${STUB_FAIL:-}" ]; then exit 7; fi
if [ -n "\${STUB_EMPTY:-}" ]; then : >"\$out"; exit 0; fi
printf 'ID3fake' >"\$out"
EOF
cat >"$PLAYER" <<EOF
#!/usr/bin/env bash
cp "\$1" "$PLAYED"
EOF
chmod +x "$CURL" "$PLAYER"
sp() { env TMPDIR="$WORK/tmp" SPEAK_CURL="$CURL" SPEAK_PLAYER="$PLAYER" "$@"; }
body_of() { awk 'prev == "-d" { print; exit } { prev = $0 }' "$CALLS"; }

assert_ok "speaks plain text" sp "$S" "Hello there"
assert_file "the audio reached the player" "$PLAYED"
assert_contains "request has the 30 s limit" "$(tr '\n' ' ' <"$CALLS")" "-m 30"
assert_contains "request goes to the local Kokoro endpoint" "$(tr '\n' ' ' <"$CALLS")" "http://127.0.0.1:8880/v1/audio/speech"
assert_eq "body input" "Hello there" "$(body_of | jq -r .input)"
assert_eq "body voice" "af_sky" "$(body_of | jq -r .voice)"
assert_eq "body model" "kokoro" "$(body_of | jq -r .model)"
assert_eq "no temp file is left behind" "0" "$(find "$WORK/tmp" -type f | wc -l | tr -d ' ')"

# Review Focus 3: quotes, a backslash and a newline survive as valid JSON
HOSTILE=$'He said "hi"\nit'"'"'s a \\ back'
assert_ok "speaks hostile text" sp "$S" "$HOSTILE"
assert_eq "hostile text round-trips through the JSON body" "$HOSTILE" "$(body_of | jq -r .input)"

rm -f "$PLAYED"
assert_fails "service down: fails" sp env STUB_FAIL=1 "$S" "x"
assert_no_file "service down: nothing is played" "$PLAYED"
assert_fails "empty audio: fails" sp env STUB_EMPTY=1 "$S" "x"
assert_no_file "empty audio: nothing is played" "$PLAYED"
assert_fails "no text: fails" sp "$S" ""
exit 0
