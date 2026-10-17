#!/usr/bin/env bash
# ask-check.sh: does a finished turn need the owner (input) or not (done), and what does it ask for.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

kind() { printf '%s' "$1" | "$KIT/bin/ask-check.sh" | sed -n 1p; }
ask() { printf '%s' "$1" | "$KIT/bin/ask-check.sh" | sed -n 2p; }

# a question at the end
assert_eq "last line question" input "$(kind "I changed X. Which colour do you want?")"
assert_eq "the question is the ask" "Which colour do you want?" "$(ask "I changed X. Which colour do you want?")"
assert_eq "bold question" input "$(kind "Done.

**Want me to make those two changes?**")"
assert_eq "markup is removed from the ask" "Want me to make those two changes?" "$(ask "Done.

**Want me to make those two changes?**")"

# a question that is not the last line (a sentence after it, or a list after it)
M="That brings back the open question: should the first batch be your roasters, or all ~28 at once?
I'll start as soon as you say."
assert_eq "question then a closing sentence" input "$(kind "$M")"
assert_eq "the question, not the closing sentence" "That brings back the open question: should the first batch be your roasters, or all ~28 at once?" "$(ask "$M")"
M="Which one should I do first?
1. The queue
2. The menu bar"
assert_eq "question followed by options" input "$(kind "$M")"
assert_eq "the question before the options" "Which one should I do first?" "$(ask "$M")"

# no question mark, but the owner is asked to do or decide something
for m in "Let me know if you want X." \
         "If it doesn't snap, tell me and I'll check the logs." \
         "Not yet tested on your real screens, so I left the live check to you." \
         "You'll need to allow KachingBar under Accessibility." \
         "Please confirm the folder shows up in Raycast." \
         "Your call: merge now or wait for the voice work." \
         "I need your approval before pushing." \
         "Waiting for your go-ahead to delete the branch." \
         "Shall I go ahead and merge." \
         "Say the word and I'll merge it."; do
  assert_eq "asks the owner: $m" input "$(kind "$m")"
done
assert_eq "the ask sentence is picked" "If it doesn't snap, tell me and I'll check the logs." "$(ask "The 94 queue checks pass. If it doesn't snap, tell me and I'll check the logs.")"

# a report with nothing for the owner
M="I did the research PicoNew asked for and sent the report.
- **Shopify coverage:** 10 of the 14 roasters run Shopify.
- **Size:** about 300 current coffees."
assert_eq "plain report" done "$(kind "$M")"
assert_eq "plain report has no ask" "" "$(ask "$M")"
assert_eq "empty message" done "$(kind "")"
assert_eq "a question mark inside a link is no question" done "$(kind "Fixed: see https://x.test/a?b=1 for the run.")"
assert_eq "a question mark inside code is no question" done "$(kind 'Use `jq ".a?"` to read it.')"
assert_eq "inline code stays in the ask" 'Can the folder be set to ~/vault/Briefings?' "$(ask 'Can the folder be set to `~/vault/Briefings`?')"
assert_eq "a question in a code block is no question" done "$(kind 'Added the test:
```
read -p "Continue?"
```
All 12 pass.')"
assert_eq "a question heading is no ask" done "$(kind "## Why did it break?
The cache was stale. Fixed and tested.")"
assert_eq "an old question further up is not the ask" done "$(kind "You asked: should I merge?
Merged.
Pushed.
Tests pass.
Installed.
Restarted.
Nothing else to do.")"
assert_eq "nothing is waiting on you" done "$(kind "Merged and pushed. Nothing is waiting on you from my side.")"
assert_eq "nothing needs you" done "$(kind "Nothing here needs you.")"
# a bold question that leads a paragraph is a label, not the question
M="**Is anything left?** Everything I did is verified. These are still open, and all need you:
- The Littlebird change above.
- Pushing main."
assert_eq "bold lead-in label, then a request" input "$(kind "$M")"
assert_eq "the request is the ask, not the label" "These are still open, and all need you:" "$(ask "$M")"
assert_eq "bold lead-in label, then a plain answer" done "$(kind "**Is anything left?** No, everything is merged and installed.")"
assert_eq "no action needed from you" done "$(kind "Merged and installed. No action needed from you.")"
exit 0
