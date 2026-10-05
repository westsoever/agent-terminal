#!/usr/bin/env bash
# The policy text and templates agree with what the scripts parse.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../bin/lib.sh
. "$BIN/lib.sh"
A="$KIT/templates/AGENTS-autonomy-block.md"
assert_contains "autonomy: checkpoint every turn" "$(cat "$A")" "ching:checkpoint"
assert_contains "autonomy: name the exact missing piece" "$(cat "$A")" "exact missing piece"
assert_contains "autonomy: review step" "$(cat "$A")" ".agent/review/"
assert_contains "autonomy: review lenses" "$(cat "$A")" "review-lenses"
assert_contains "autonomy: drafts only" "$(cat "$A")" "drafts"
assert_contains "autonomy: gate settings belong to the user" "$(cat "$A")" "review:"
for k in result blocker next_action files_changed examined not_examined; do
  assert_eq "STATE.md template: $k parses" "1" "$([ -n "$(checkpoint_get "$KIT/templates/STATE.md" "$k")" ] && echo 1 || echo 0)"
done
assert_contains "handoff writes the checkpoint" "$(cat "$KIT/commands/handoff.md")" "ching:checkpoint"
assert_contains "dispatcher uses the inbox" "$(cat "$KIT/dispatcher/AGENTS.md")" "dash.sh --inbox"
assert_contains "dispatcher uses next" "$(cat "$KIT/dispatcher/AGENTS.md")" "dash.sh --next"
exit 0
