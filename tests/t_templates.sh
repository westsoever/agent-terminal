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
# the Stop cap is "in a row", reset by a green run (stop-check.sh removes the counter), not per session
assert_contains "autonomy: Stop cap is retries in a row" "$(cat "$A")" "3 retries in a row"
assert_contains "autonomy: Stop cap resets after a green run" "$(cat "$A")" "resets after a green run"
assert_not_contains "autonomy: Stop cap is not described as per session" "$(cat "$A")" "retries per session"
# shipping step 4 is pasted into other repos: kit paths say so, the diff base is the GOAL.md base_branch
assert_contains "autonomy: lenses are in the agent-terminal kit" "$(cat "$A")" "templates/review-lenses/\` in the agent-terminal kit"
assert_contains "autonomy: REVIEW.md is in the agent-terminal kit" "$(cat "$A")" "templates/REVIEW.md\` in the agent-terminal kit"
assert_contains "autonomy: review diff uses base_branch" "$(cat "$A")" "git diff origin/<base_branch>...HEAD"
assert_not_contains "autonomy: no hard-coded origin/main" "$(cat "$A")" "origin/main"
assert_contains "autonomy: fixing a blocking finding makes a new HEAD" "$(cat "$A")" "creates a new HEAD"
assert_contains "autonomy: evidence and review must be redone for the new HEAD" "$(cat "$A")" "redo steps 3 and 4"
# the defaults GOAL.md template ships the gate settings (PLAN 1.5.7) and says who may change them
G="$KIT/templates/GOAL.md"
assert_eq "GOAL.md template: review: required" "required" "$(goal_get "$G" review)"
assert_eq "GOAL.md template: release_mode: confirm" "confirm" "$(goal_get "$G" release_mode)"
assert_contains "GOAL.md template: only the user changes the gate settings (guard rule 11)" "$(cat "$G")" "guard rule 11"
assert_contains "GOAL.md template: review is documented with the other keys" "$(cat "$G")" "review               required"
for k in result blocker next_action files_changed examined not_examined; do
  assert_eq "STATE.md template: $k parses" "1" "$([ -n "$(checkpoint_get "$KIT/templates/STATE.md" "$k")" ] && echo 1 || echo 0)"
done
assert_contains "handoff writes the checkpoint" "$(cat "$KIT/commands/handoff.md")" "ching:checkpoint"
assert_contains "dispatcher uses the inbox" "$(cat "$KIT/dispatcher/AGENTS.md")" "dash.sh --inbox"
assert_contains "dispatcher uses next" "$(cat "$KIT/dispatcher/AGENTS.md")" "dash.sh --next"
exit 0
