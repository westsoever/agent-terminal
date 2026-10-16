# Learner contracts (Phase 6, stage 6a, step 0)

This page lists the interfaces the learner components build on. The four implementers (A extractor and report, B corrections, C skills miner, D plumbing) need only this page and `tests/fixtures/learn/`. The design is in `docs/superpowers/specs/2026-10-16-phase6-learning-loop-design.md` (sections 4, 5 and 7). Where this page is more exact than the spec, this page wins. Everything here is tested in `tests/t_proposals.sh`.

If you change an interface, change this page, the fixtures and `t_proposals.sh` in the same commit, and say so in your report.

## 1. Where things live

```
$AGENT_HOME/proposals/            mode 0700, made by proposals_root
  <kind>-<slug>.md                open proposals, written ONLY by proposal_write (mode 0600)
  report-YYYY-Www.md              weekly report (A), written through proposal_safe_path
  archive/                        decided proposals, moved here by ching-proposals (D)
  rejected.txt                    one fingerprint per line, optionally followed by a space and a note
  .work/                          learner scratch, safe to delete; every path goes through proposal_safe_path
    prompts.jsonl  toolseq.jsonl  extractor output (A); format in section 6
    offsets                       extractor byte offsets (A; format is A's choice)
    tokens-YYYY-MM-DD             model tokens spent that local day (learn_model_call)
    learn.log                     one line per model call, plus claude's stderr
```

- `AGENT_HOME` defaults to `~/.agent`; `CLAUDE_DIR` defaults to `~/.claude`. Transcripts are `$CLAUDE_DIR/projects/*/*.jsonl` (one level deep only, so subagent files below a session directory are never read).
- Kinds: `rule skill blindspot prune lesson` (`$PROPOSAL_KINDS`). Components: `corrections skills report blindspot lessons` (`$PROPOSAL_COMPONENTS`).
- Files under `.work/` are written with `umask 077`.

## 2. Settings and environment

`learn_setting NAME` gives the value. The environment wins, then a `NAME=value` line in `$AGENT_HOME/config`, then the default.

| Name | Default | Used by |
|---|---|---|
| `LEARN_MODEL_CLASSIFY` | `haiku` | B, stage 2 labels (D26) |
| `LEARN_MODEL_DRAFT` | `sonnet` | B stage 3, C (D26) |
| `LEARN_TOKEN_CAP` | `200000` | `learn_model_call`, per local day (D26) |
| `LEARN_SKILL_MAX` | `3` | C, proposals per run (D26) |
| `LEARN_MAX_SNIPPETS` | `200` | B and C input cap; hitting it logs `learn_run{outcome: truncated}` |
| `LEARN_CALL_TIMEOUT` | `300` | `learn_model_call`, seconds per call |
| `LEARN_DISABLE` | empty | D: component names to skip, separated by commas or spaces |

Other environment:

- `CHING_CLAUDE_BIN` (default `claude`): the binary `learn_model_call` runs. Tests point it at `tests/fixtures/learn/claude-stub`.
- `CHING_LEARNER=1` and `CLAUDE_MEM_INTERNAL=1`: `learn_model_call` sets both on every call. D's launchd job sets them too. With `CHING_LEARNER=1`, guard learner mode applies (D builds that).

## 3. Functions in `bin/lib.sh`

Source `lib.sh` the way every script does (`. "$SELF_DIR/lib.sh"`). All of these work under `set -euo pipefail`.

| Signature | What it does | Exit |
|---|---|---|
| `learn_setting NAME` | prints a `LEARN_*` setting (section 2) | 1 if NAME is not `LEARN_*` |
| `learn_work_dir` | prints `$AGENT_HOME/proposals/.work` (does not create it) | 0 |
| `learn_filter MODE FILE...` | prints the lines that count, compact JSON, one per line, in file order. MODE `prompts`: counted human prompts. `lines`: user and assistant lines of countable sessions (use this for tool calls). `events`: countable `events.jsonl` lines. Skipped project directories are never opened. Malformed lines and missing files are skipped. | 0; 2 for an unknown MODE |
| `learn_skip_project DIR` | true when a `~/.claude/projects/<dir>` is skipped whole (only the last path part is judged) | 0 skip, 1 keep |
| `learn_redact [--jsonl]` | stdin to stdout with credentials replaced by `[REDACTED]` (section 5.3). `--jsonl`: one JSON value per line, every string inside is redacted; an unchanged line comes out byte for byte, a changed one is re-encoded with sorted keys (key order is never part of a contract), and a non-JSON line is redacted as text | 0 |
| `learn_model_call MODEL < PROMPT` | the only way to call a model (section 7). Prints the model's JSON answer, compact, one line | 0 ok; 1 call failed, timed out or not a success envelope; 2 the answer is not exactly one JSON document; 3 `.work` unusable; 5 daily token cap reached, no call made; 64 no MODEL |
| `proposal_fingerprint TEXT` | sha1 (40 lower-case hex) of TEXT lower-cased, with whitespace runs squeezed to one space and trimmed | 0 |
| `proposal_slug TEXT` | lower case, every run of other characters becomes `-`, at most 50 characters, no dash at either end | 0 |
| `proposals_root` | makes `$AGENT_HOME/proposals` (0700; an existing one is tightened) and prints its canonical path | 3 if it is a symlink or cannot be made |
| `proposal_safe_path PATH` | prints the absolute path PATH names inside the root, making missing parent directories (0700) | 3 refused |
| `proposal_write PATH < JSON` | the only writer of proposal files (section 5) | see 5.2 |
| `proposal_get FILE KEY` | value of a header line (lines before the first blank line) | 0 |
| `proposal_section FILE NAME` | body of `## NAME`, without surrounding blank lines | 0 |
| `proposal_patch FILE` | the raw unified diff of a rule (the `## patch` body without its fence) | 0 |
| `proposal_status_of_fp ROOT FP` | `open <file>`, `approved <file>`, `rejected <file>`, `snoozed <file>` or nothing (rules in 5.2) | 0 |

`proposal_safe_path` refuses: an empty path, any `.` or `..` component, an absolute path outside the root, the root itself, a symlink anywhere below the root (directory or final file), and an existing directory at PATH. An absolute path may be spelled through `$AGENT_HOME` or canonically (on macOS `/tmp` is really `/private/tmp`).

## 4. The exclusion filter `bin/learn-filter.jq`

It is a jq module, the only definition of what counts. Call it from jq, so perl or bash extractors are not needed for filtering:

```
jq -R -c -L "$LIB_DIR" --arg work "$(learn_work_dir)" \
  'include "learn-filter"; fromjson? // empty | select(learn_human_prompt($work))' FILE
```

`$LIB_DIR` is set by `lib.sh` (the `bin/` directory). `fromjson? // empty` is how malformed lines are skipped.

| def | input | true when |
|---|---|---|
| `learn_cwd_excluded($work)` | a cwd string or null | the path is `/tmp`, `/private/tmp`, `/var/folders/...`, `/private/var/folders/...`, or has a `task*-repo` path part, or is under `.claude-mem/observer-sessions`, or is at or under `$work` |
| `learn_project_excluded($work)` | a project directory name | the same rules on the encoded name (every non-alphanumeric character becomes `-`), plus the observer directory `*-claude-mem-observer-sessions`. Because the encoding drops `/`, the `task*-repo` test can over-exclude a name like `tasks-my-repo` |
| `learn_session_ok($work)` | any transcript line | a user or assistant line, not `isSidechain`, `entrypoint` is not `sdk-cli`, and the cwd is not excluded |
| `learn_prompt_text` | a user line | its text, outer whitespace trimmed. An array message joins its text blocks with a newline. A message holding a `tool_result` gives `""` |
| `learn_human_prompt($work)` | any transcript line | `learn_session_ok`, a user line, not `isMeta`, no `toolUseResult`, and the text is not empty and does not start with `<`, `Caveat:` or `[Request interrupted` |
| `learn_interrupt` | any transcript line | a user line whose text starts with `[Request interrupted` |
| `learn_event_ok($work)` | an `events.jsonl` line | kind `learn_run` or `proposal` (always kept), or the cwd is not excluded |
| `learn_encode` | a path | Claude Code's project directory name for it |

Notes:

- The `sdk-cli` test is per line. Every transcript line carries `entrypoint`.
- "Registry-only sessions" are excluded because nothing reads `$AGENT_HOME/sessions`.
- Events carry no `entrypoint`. A headless run's events stay countable unless its cwd is excluded. If A needs them out, it can drop event sids whose transcript is `sdk-cli`.
- Over the fixture tree, `learn_filter prompts` keeps exactly 17 prompts in 6 sessions.

## 5. Proposal files

### 5.1 Format (spec 4.2, exact)

`templates/PROPOSAL.md` is a filled example. The header is exactly these 9 lines in this order, then a blank line:

```
id: <kind>-<slug>
kind: rule|skill|blindspot|prune|lesson
status: open                      (ching-proposals sets approved | rejected | snoozed:YYYY-MM-DD)
created: YYYY-MM-DDTHH:MM:SSZ     (UTC)
component: corrections|skills|report|blindspot|lessons
fingerprint: <40 hex>
sessions: <n>
days: <n>
target: <file to change, or the proposed skill name>
```

The sections follow in this order:

1. `## proposal`
2. `## evidence`, one line per item: `- <sid first 8> <YYYY-MM-DD> <cwd> "<quote>"`
3. `## patch` (rule only), a unified diff inside a `` ```diff `` fence. `proposal_patch` gives the raw diff back. Apply it with `patch -p1` from the target's directory, since paths are `a/<file>` and `b/<file>`.
4. `## why this is not already covered`

The header holds no comments. A note such as "the target repo is public" goes in the first sentence of `## proposal`.

### 5.2 `proposal_write PATH < JSON`

PATH is `<kind>-<slug>.md` at the top of the root. It may be relative or absolute inside the root. The kind is taken from the file name. The slug is lower-case letters, digits and single dashes, and the whole id is at most 80 characters.

The JSON on stdin looks like this:

```json
{
  "component": "corrections",
  "fingerprint": "<proposal_fingerprint of the normalised pattern>",
  "sessions": 3, "days": 2,
  "target": "~/.agents/CLAUDE.md",
  "proposal": "two to five plain sentences",
  "evidence": [{"sid": "<full session id>", "day": "YYYY-MM-DD", "cwd": "/path", "quote": "the prompt"}],
  "patch": "unified diff (rule: required)",
  "why_not_covered": "text (rule and skill: required)",
  "kind": "optional; must match the file name"
}
```

- Every string is redacted first. Each quote then has newlines and tabs turned into spaces and is cut to 300 characters. A cwd that is empty becomes `-`.
- A line in the free text that starts with `## ` is demoted to `### ` so that it cannot end a section early. A patch line may not be a bare `` ``` ``.
- `evidence` may be empty, in which case the file says `- (none)`. Choosing which and how many quotes to send is the caller's job.
- For kinds other than rule and skill, a missing `why_not_covered` is written as `not applicable`.
- `fingerprint` is what deduplication keys on. For rules, it is the normalised one-line pattern. For skills, it is the token sequence joined with `" > "`. Always use `proposal_fingerprint`.

It prints one line and exits 0 in these cases:

| Output | When |
|---|---|
| `written <abs path>` | a new open proposal |
| `refreshed <abs path>` | an open proposal (top of the root, any slug) already has this fingerprint. Its `sessions`, `days` and `## evidence` are replaced. Its id, created, target, proposal, patch and why are kept. PATH is ignored |
| `skipped rejected <fp>` | the fingerprint is the first field of a line in `rejected.txt`, or an archived file with it has `status: rejected` |
| `skipped approved <fp>` | an archived file with this fingerprint has `status: approved` |
| `skipped snoozed <fp>` | a file with this fingerprint has `status: snoozed:<date>`, and the date is after today (local time) |

A snooze whose date has passed no longer blocks, so the next run proposes the pattern again. That is how a snoozed item comes back.

It fails without writing anything:

| Exit | Cause |
|---|---|
| 2 | bad input: not JSON, a missing or invalid field, an unknown kind or component, a bad slug, no `.md`, a rule without a patch, a rule or skill without a why, `sessions`/`days` not whole numbers, an evidence `day` that is not `YYYY-MM-DD` |
| 3 | unsafe path (section 3), or a path that is not at the top of the root |
| 4 | PATH already holds a proposal with a different fingerprint. Pick another slug, for example by adding `-2` |
| 1 | the write itself failed |

The write is atomic: a temporary file in the root, then `mv`. Files are mode 0600.

### 5.3 What redaction covers

The rules live in `bin/learn-redact.pl`.

- `NAME=value`, `NAME: value` and `"NAME": "value"`, case-insensitive, where NAME contains one of the guard's credential words (`guard.sh` `var_is_secret`: TOKEN SECRET PASSWORD API_KEY PRIVATE_KEY) or APIKEY or PASSWD. The test fails if the guard gains a word that this list lacks.
- Value shapes:
  - PEM private key blocks
  - `sk-...`
  - GitHub `gh?_` and `github_pat_`
  - AWS `AKIA`/`ASIA`
  - Slack `xox?-`
  - Stripe `sk_|rk_` live/test and `whsec_`
  - Supabase `sbp_` and `sb_secret_`
  - Google `AIza`
  - JWTs
  - `Bearer <token>`
  - the password in `scheme://user:pw@host`
- Fixtures and tests never hold a real-looking token literally. Build one at run time (`"gh""p_..."`), because GitHub push protection scans the repo.

## 6. The `.work` formats the extractor writes (spec 5.1)

The golden files `tests/fixtures/learn/work/prompts.jsonl` and `toolseq.jsonl` are the expected extractor output over `tests/fixtures/learn/claude/projects` with `AGENT_HOME=/Users/fixture/.agent`. A's test should match them, comparing as sets of lines with key order ignored. If A finds a justified difference, A updates the golden files and this section.

### 6.1 `prompts.jsonl`: one counted human prompt per line

```json
{"sid":"a1000000-...","ts":"2026-10-12T12:03:40.000Z","cwd":"/Users/fixture/code/shop",
 "text":"no, don't bump the version number, I do releases by hand",
 "prev_assistant_tail":"Done. I also bumped the version to 1.4.0 in package.json.","after_interrupt":false}
```

- `sid` is the line's `sessionId`, and `ts` is its `timestamp` exactly as written (UTC). `(sid, ts)` is unique in the file.
- `text` is `learn_prompt_text`, redacted, then cut to 600 characters.
- `prev_assistant_tail` is the last 300 characters of the text blocks of the nearest earlier non-sidechain assistant line in the same file that has text, redacted. It is `""` when there is none.
- `after_interrupt` (an addition to the spec) is true when a `learn_interrupt` line came after the previous counted prompt of the same file. Stage 1 in B uses it for "prompts that follow an interrupt".
- The file is cumulative. Byte offsets mean each transcript byte is read once. A shrunk transcript is re-read from 0, and that session's old lines are dropped first. Deleting `.work` rebuilds everything. To know which prompts are new, B keeps its own labelled cache keyed by `sid@ts`.

### 6.2 `toolseq.jsonl`: one line per session with at least one token

```json
{"sid":"a1000000-...","day":"2026-10-12","cwd":"/Users/fixture/code/shop",
 "tokens":["Read","Edit","git fetch","git rebase","bun test","git push"],
 "prompts":[{"i":0,"ts":"2026-10-12T12:00:30.000Z"},{"i":6,"ts":"2026-10-12T12:03:40.000Z"}]}
```

- Tokens come from the `tool_use` blocks of the assistant lines that `learn_filter lines` keeps, so sidechain lines are already gone. They are made this way:
  - Most tools give their name, such as `Read` or `mcp__x__y`.
  - Bash removes leading `cd <dir> &&` or `cd <dir>;` parts (repeated, and a quoted dir may hold spaces), splits on whitespace, drops words that start with `-` and `NAME=value` words, and keeps the first two words joined by a space (`git fetch`, `bun test`). For `git`, the argument of `-C` and `-c` is dropped too, so `git -C dir status` gives `git status`. Only the first 16 words are looked at (a heredoc can hold thousands). A command with no word left gives `Bash`. No golden line changed with these rules.
  - Skill gives `Skill:<skill name>`. The prefix is an addition to the spec, to tell skills apart from tool names.
- Plumbing calls are dropped before anything else:
  - `ToolSearch` and `TodoWrite`
  - the task tools: `TaskCreate`, `TaskUpdate`, `TaskList`, `TaskGet`, `TaskStop`, `TaskOutput`
  - `mcp__claude-in-chrome__tabs_context_mcp`
- Consecutive equal tokens are then collapsed.
- `day` is the local date of the session's first kept tool call, and `cwd` is the session's first cwd.
- `prompts` (an addition to the spec) marks where each counted prompt fell: `tokens[i:]` came after the prompt with that `ts`. It joins to `prompts.jsonl` on `(sid, ts)`, which C needs for "the human prompt that preceded the sequence". `i` may equal `tokens` length.
- There is always one line per sid, holding the whole session so far. The extractor rewrites the line when the session grows.
- In the counted fixture sessions, every timestamp is between 11:00 and 13:04 UTC. The local date is therefore the same in every timezone from UTC−11 to UTC+10. Tests that check dates should still pin `TZ` (for example `TZ=UTC`).

### 6.3 The extractor's other files (A's own; others need not read them)

- `text` and `prev_assistant_tail` are redacted whole, then cut, so a cut cannot split a secret and hide it from redaction.
- `events.jsonl`: the `learn_filter events` lines of `$AGENT_HOME/events.jsonl` and its rotated `events-<UTC stamp>.jsonl` files, cumulative, oldest file first. Events files are tracked by inode, so a rotated file carries on from its offset and the new live file starts at 0. The weekly report reads this file.
- `offsets`: a first line `# gen <n>`, then one TSV line per source file: `path|inode`, key, `dev:ino`, byte offset, head length, sha1 of the first head-length bytes, path. A file is read again from 0 when it shrank, its head changed or (transcripts) its inode changed.
- `extract-state.json`: `{gen, files: {path: {tail, intr, sids}}, sessions: {sid: {seen, ok, cwd, day, tokens, prompts}}}`, what the next run continues from. `seen` without `ok` marks a session none of whose lines count (for example `sdk-cli`); the report drops those sessions' events. When the `gen` of `offsets` and of this file differ (a run died between writes), everything is rebuilt from 0.

## 7. The model call

`learn_model_call MODEL < PROMPT` does these steps:

1. Runs `"$CHING_CLAUDE_BIN" -p --model MODEL --tools "" --output-format json --strict-mcp-config --disable-slash-commands`, with the prompt on stdin. `--tools ""` alone removes only the built-in tools: a live check on 2026-10-17 showed every MCP server still loaded (Gmail send, Drive share, ...) and 211k prompt tokens per call. With the two extra flags the run has no tools and no MCP servers, at about 6k tokens.
2. Runs it with cwd `$(learn_work_dir)`, `CHING_LEARNER=1` and `CLAUDE_MEM_INTERNAL=1`, in its own process group, and kills it after `LEARN_CALL_TIMEOUT` seconds.
3. Reads the envelope: `{type:"result", subtype, is_error, result:"<text>", usage:{input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens}, ...}`.
4. Adds all four usage numbers to `.work/tokens-<local day>`.
5. Takes `.result`, removes a `` ```json `` fence, requires exactly one JSON document, and prints it compact.

There is no model call when `tokens-<day>` is already at or above `LEARN_TOKEN_CAP` (exit 5). The caller then logs `learn_run{outcome: capped}`.

The prompt's first line is `ching-learn-task: <name>`. This lets the stub pick its canned answer, and it makes logs readable. Task names: `corrections-classify`, `corrections-draft`, `skills`. The prompt templates go in `templates/learn-prompts/` (B and C).

The canned answers in `tests/fixtures/learn/stub/` set the answer schemas. B owns `corrections-*.json` and C owns `skills.json`. Whoever changes a schema updates the canned file and this list.

- `corrections-classify`: `{"labels":[{"id":"<sid>@<ts>","label":"correction"|"not","pattern":"<one-line normalised pattern, corrections only>"}]}`. The id is the prompt's `sid@ts` from `prompts.jsonl`. The stub returns every fixture label whatever was sent, so the caller ignores ids it did not send. The fixture holds three patterns over three sessions each. The version pattern is in 3 sessions on 2 days and becomes a proposal. The pnpm pattern is in 3 sessions on 1 day and does not. The YYYY-MM-DD pattern is in 3 sessions on 3 days, but `agents-CLAUDE.md` already covers it.
- `corrections-draft`: `{"rules":[{"pattern","covered":false,"slug","target","proposal","patch","why_not_covered"} | {"pattern","covered":true,"covered_by"}]}`. The canned patch applies to `tests/fixtures/learn/agents-CLAUDE.md`, the fixture for `~/.agents/CLAUDE.md`.
- `skills`: `{"skills":[{"sequence":[tokens],"keep":true,"slug","name","proposal","why_not_covered"} | {"sequence","keep":false,"reason"}]}`.

The stub's own knobs are listed at the top of `tests/fixtures/learn/claude-stub`:

- `CLAUDE_STUB_RESPONSE`
- `CLAUDE_STUB_DIR`
- `CLAUDE_STUB_EXIT`
- `CLAUDE_STUB_TOKENS`
- `CLAUDE_STUB_LOG` (records args, PWD, the learner env and the prompt)
- `CLAUDE_STUB_SLEEP`

## 8. Events (spec 4.3)

All events are emitted with `ev KIND DATA_JSON` from `lib.sh`, so strings are capped at 300 characters.

- `learn_run`: `{"component":"corrections|skills|report|lessons","scanned":n,"candidates":n,"proposals":n,"outcome":"ok|nothing-new|truncated|capped|error|disabled","covered":n}`. `covered` appears only for corrections.
- `proposal`: `{"id":"<proposal id>","action":"approved|rejected|snoozed"}`, emitted by `ching-proposals` (D).
- `learn_event_ok` always keeps these two kinds, even though they carry the `.work` cwd or none.
- `checkpoint` (extended, `stop-check.sh`, from the STATE.md checkpoint block when the gate accepts it): `{"status":"<status line>","blocker":"...","next_action":"...","not_examined":"...","task_type":"build|fix|research|merge/sync|ops/config|writing|data"}`.
  - `not_examined` is always present (the gate requires the key). `learn-report.sh` reads it as the blind-spot ledger's input.
  - `task_type` is present only when the block has a `task_type:` line naming one of D26's seven types. Case and blanks are ignored, `merge` or `sync` becomes `merge/sync`, and `ops` or `config` becomes `ops/config`. The template's `(none)`, a missing line and any other word give no field, and the learner classifies the session instead (D26: the session's own type wins when present). `learn-report.sh` maps each session id to the `task_type` of its checkpoint events.
  - ev drops all the data of a line over 1 KB, so the free text is budgeted to fit: `blocker` and `next_action` are cut to 120 characters, `not_examined` to 300. A longer `not_examined` is cut after its last whole item (items end at `; ` or `, `, the ledger's own separators) when that keeps at least 150 characters, else at 300.
- `tests` (new, `stop-check.sh`): `{"outcome":"pass|fail","secs":n}`, one per run of the GOAL.md `test_command` (through test-escalate.sh, so the verdict includes any model fix and `secs` is the whole run's wall time in seconds). A run cut by `STOP_CHECK_TIMEOUT` is `fail`. No event for a skipped run (`check_skipped`, unchanged tree), a folder with no `test_command`, or a run cut off at the hook deadline (no verdict: `stop_deadline`). `learn-report.sh` reads `outcome` for test runs, failures, green first time and minutes to green (from the event timestamps).

## 9. Fixtures (`tests/fixtures/learn/`)

Everything here is synthetic. The user is `/Users/fixture`, and the test fails if any other `/Users/<name>` appears.

- `claude/projects/`: 12 transcripts.
  - Counted sessions, 17 prompts in total:
    - `a1`: shop, 10-12. Holds an `isMeta` Caveat line, a `<command-name>` line, a sidechain block, `ToolSearch`/`TodoWrite` calls and a `cd ... &&` command.
    - `a2`: blog, 10-12. Holds a malformed line, two interrupt lines, an array-of-text prompt and a repeated `bun test`.
    - `a3`: shop, 10-13. Holds a `Skill` call.
    - `b1`: `~`, 10-14.
    - `b2`: shop, 10-14. Holds a prompt with an `API_TOKEN=` value.
    - `b3`: blog, 10-14.
  - Excluded sessions:
    - `e1`: observer directory
    - `e2`: `sdk-cli`
    - `e3`: `/private/tmp` sandbox, with the same 4-step sequence as the counted sessions
    - `e4`: `task3-repo`
    - `e5`: `/private/var/folders`
    - `e6`: the learner's own `.work`, excluded only when `AGENT_HOME=/Users/fixture/.agent`
  - The miner's case: `git fetch > git rebase > bun test > git push` appears in `a1`, `a2` and `a3` (3 sessions, 2 days).
- `events.jsonl`: 8 events plus one malformed line. Under the fixture `AGENT_HOME`, `learn_filter events` keeps 4.
- `work/prompts.jsonl`, `work/toolseq.jsonl`: the golden extractor output (section 6).
- `agents-CLAUDE.md`: the fixture global rules file. Its one rule covers the dates pattern.
- `claude-stub` and `stub/*.json`: section 7.

## 10. Choices this step made where the spec was silent

- An archived approved or rejected proposal blocks its fingerprint, and so does a snooze that has not run out. The spec only names `rejected.txt` and open proposals.
- A rerun refreshes only the counts and the evidence. It keeps the proposal text and patch the owner may already be reading.
- `rejected.txt` lines may carry a note after the fingerprint.
- The patch sits in a `` ```diff `` fence.
- The `after_interrupt` and `prompts` fields and the `Skill:` token prefix are additions (section 6).
- The `sdk-cli` exclusion is exactly `sdk-cli`. Other entrypoints, including other SDK ones, still count.
- `learn_model_call` is in `lib.sh` so that B, C and D share one token cap and one call path.
- `LEARN_MAX_SNIPPETS` defaults to 200 (about 160 stage-1 hits today) and `LEARN_CALL_TIMEOUT` to 300 s. The spec gave neither value.
