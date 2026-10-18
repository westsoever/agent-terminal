id: rule-no-version-bump
kind: rule
status: open
created: 2026-10-14T05:31:02Z
component: corrections
fingerprint: 3b6f411c4b4f18999fc37000ecc1b8e90c9858e1
sessions: 3
days: 2
target: ~/.agents/CLAUDE.md

## proposal
Add a rule that sessions never bump the version number. The owner releases by hand, and corrected this in three sessions across two repos on two days.

## evidence
- a1000000 2026-10-12 /Users/fixture/code/shop "no, don't bump the version number, I do releases by hand"
- a2000000 2026-10-12 /Users/fixture/code/blog "stop bumping the version in package.json, releases are manual"
- a3000000 2026-10-13 /Users/fixture/code/shop "actually leave the version alone, I bump it myself when I release"

## patch
```diff
--- a/CLAUDE.md
+++ b/CLAUDE.md
@@ -3,2 +3,5 @@
 ## Dates
 Write dates as YYYY-MM-DD.
+
+## Versions
+Never bump the version number. The owner releases by hand.
```

## why this is not already covered
Checked ~/.agents/CLAUDE.md: its only rule is about dates. No skill or AGENTS.md rule mentions version numbers.
