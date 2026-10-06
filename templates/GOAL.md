# Goal

<!-- One paragraph: the outcome this repo/worktree is working toward right now. -->

## Settings (machine-read: keep the `key: value` form, one per line)

<!-- Only the user changes review, release_mode and test_command (guard rule 11); a session proposes a change in STATE.md. -->
test_command: <the repo's own check, e.g. bun run lint && bun run typecheck && bun test>
release_mode: confirm
review: required
base_branch: main
migrations_dir: db/migrations
migrate_pending_cmd:
migrate_test_command:

<!--
test_command         Run by stop-check.sh (before a session may stop) and by release-gate.sh.
                     Leave as the <placeholder> to disable the Stop check for this repo.
release_mode         confirm = gate passes, notify "ready to push", wait for the human to run
                                 `release-gate.sh --approve`.
                     auto    = gate passes and mints the push token itself.
                     Recommended: confirm for the first release in each repo, then auto.
review               required = release-gate.sh needs a review file for HEAD (default).
                                Format: templates/REVIEW.md.
                     off      = no review. Exactly `review: off`, written by the user; guard rule 11
                                denies a session that adds or changes it.
base_branch          Branch that pushes are gated on (default main).
migrations_dir       Where numbered migration files live.
migrate_pending_cmd  Optional. A dry-run command that prints the pending migration file names,
                     one per line. When set, migrate-gate.sh requires that list to equal the files
                     this session created.
migrate_test_command Optional. Must pass before migrate-gate.sh mints a token.
-->

## Scope boundaries

- In scope:
- Out of scope:

## Definition of done

- [ ]
