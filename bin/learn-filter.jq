# learn-filter.jq - the ONE exclusion definition for the Phase 6 learner (spec 4.4). Every learner component
# decides what counts through these defs, so counts stay comparable between components and between runs; the
# rules are pinned by tests/t_proposals.sh. Use it as a jq module:
#
#   jq -R -c -L "$LIB_DIR" --arg work "$(learn_work_dir)" \
#     'include "learn-filter"; fromjson? // empty | select(learn_human_prompt($work))' FILE
#
# or through the bash wrappers in lib.sh (learn_filter MODE FILE..., learn_skip_project DIR). $work is the
# learner's own working directory, $AGENT_HOME/proposals/.work: its claude -p runs are never counted.
#
# Excluded: the claude-mem observer project; entrypoint sdk-cli (headless runs); cwd or project directory under
# /tmp, /private/tmp, /var/folders, /private/var/folders or a task*-repo folder; the learner's .work; sidechain
# lines. A human prompt is also not: isMeta, a tool result, or text that (after leading blanks) is empty or
# starts with "<" (command and system wrappers), "Caveat:" or "[Request interrupted". The registry
# ($AGENT_HOME/sessions) is never read, so registry-only sessions cannot count.

def learn_under($d): . == $d or startswith($d + "/");

# input: a cwd (string or null) -> true when nothing in it may be counted
def learn_cwd_excluded($work):
  (. // "") as $p
  | ($p | test("^(/private)?/tmp(/|$)"))
    or ($p | test("^(/private)?/var/folders/"))
    or ($p | test("/task[^/]*-repo(/|$)"))
    or ($p | test("/\\.claude-mem/observer-sessions(/|$)"))
    or ($work != "" and ($p | learn_under($work)));

# a cwd as Claude Code names its project directory under ~/.claude/projects (every non-alphanumeric -> "-")
def learn_encode: gsub("[^A-Za-z0-9]"; "-");

# input: a project directory NAME (basename) -> true when the whole directory is skipped unread. The encoding
# loses "/" and ".", so the task*-repo test may also catch a folder such as tasks/my-repo (over-excludes only).
def learn_project_excluded($work):
  . as $d
  | ($d | test("-claude-mem-observer-sessions(-|$)"))
    or ($d | test("^-(private-)?tmp(-|$)"))
    or ($d | test("^-(private-)?var-folders-"))
    or ($d | test("-task[^/]*-repo(-|$)"))
    or ($work != "" and (($work | learn_encode) as $w | $d == $w or ($d | startswith($w + "-"))));

# input: any transcript line -> true for a user/assistant line of a session that may be counted
def learn_session_ok($work):
  type == "object"
  and (.type == "user" or .type == "assistant")
  and (.isSidechain != true)
  and (.entrypoint != "sdk-cli")
  and ((.cwd // "") | learn_cwd_excluded($work) | not);

# input: a user line -> its text with outer blanks trimmed; "" for a tool result or a non-text message.
# An array message joins its text blocks with a newline.
def learn_prompt_text:
  (.message.content? // "") as $c
  | (if ($c | type) == "string" then $c
     elif ($c | type) == "array" then
       if any($c[]; type == "object" and .type == "tool_result") then ""
       else [$c[] | select(type == "object" and .type == "text") | (.text // "")] | join("\n") end
     else "" end)
  | sub("^\\s+"; "") | sub("\\s+$"; "");

def learn_wrapper_text: . == "" or startswith("<") or startswith("Caveat:") or startswith("[Request interrupted");

# input: a transcript line -> true for a counted human prompt
def learn_human_prompt($work):
  learn_session_ok($work)
  and .type == "user"
  and (.isMeta != true)
  and (has("toolUseResult") | not)
  and (learn_prompt_text | learn_wrapper_text | not);

# input: a transcript line -> true for the "[Request interrupted by user...]" marker line
def learn_interrupt:
  type == "object" and .type == "user" and (.isMeta != true) and (learn_prompt_text | startswith("[Request interrupted"));

# input: an events.jsonl line -> true when it may be counted. The learner's own bookkeeping (learn_run,
# proposal) is always kept: those events carry the .work cwd or none.
def learn_event_ok($work):
  type == "object"
  and ((.kind == "learn_run" or .kind == "proposal") or ((.cwd // "") | learn_cwd_excluded($work) | not));
