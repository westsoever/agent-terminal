commit: <full 40-char sha of HEAD>
reviewer: subagent
lenses: error-resilience, identity, simulation
blocking: 0

<!--
Review file for release-gate.sh. Save as .agent/review/<full HEAD sha>.md. Written by a FRESH, read-only
reviewer subagent (not the session that wrote the code) that got `git diff origin/<base>...HEAD` and the
three lens prompts in templates/review-lenses/.

The gate parses this file mechanically. It rejects the release if:
  - `commit:` is not the exact HEAD sha, or the file is older than the HEAD commit
  - `blocking:` is not a number
  - any `- [blocking]` finding is not followed by a `resolved:` line (what was done, or why it stays)
  - `## not examined` has fewer than 10 characters
-->

## findings

- [blocking] path/to/file.ts:42 What is wrong and what it breaks for a user.
  resolved: fixed in <sha7> / kept because <reason>
- [note] path/to/other.ts:7 Worth knowing, does not block.

## not examined

- What this review did not check (and why).
