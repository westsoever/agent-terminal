#!/usr/bin/env bash
# learn-extract.sh - the learner's extractor (Phase 6 spec 5.1; formats in docs/learn-contracts.md section 6).
# Deterministic, no model call. Reads only what changed since the last run and writes, under
# $AGENT_HOME/proposals/.work (every path through proposal_safe_path, files 0600):
#
#   prompts.jsonl   one counted human prompt per line, cumulative: {sid, ts, cwd, text<=600,
#                   prev_assistant_tail<=300, after_interrupt}; text and tail are redacted (learn_redact)
#   toolseq.jsonl   one line per session with at least one tool token: {sid, day, cwd, tokens[], prompts[]}
#   events.jsonl    the countable events (learn_event_ok) of $AGENT_HOME/events.jsonl and its rotated
#                   events-<UTC stamp>.jsonl files, cumulative (the weekly report reads this)
#   offsets         byte offsets, one TSV line per source file: key, dev:ino, offset, head length, head sha1, path
#   extract-state.json  what a later run needs to carry on: per transcript the last assistant text and a pending
#                   interrupt, per session its first cwd, day, tokens and prompt marks, and whether any of its
#                   lines counts (the report drops the events of sessions where none does, such as sdk-cli runs)
#
# Transcripts are $CLAUDE_DIR/projects/*/*.jsonl (one level: subagent files are never read). A project
# directory that learn_project_excluded skips is never opened. Every judgement about what counts is a def of
# bin/learn-filter.jq (learn_session_ok, learn_human_prompt, learn_interrupt, learn_prompt_text,
# learn_event_ok); this script only adds the bookkeeping. perl does the byte-offset reads, jq the parsing.
#
# Offsets: a file is read from its stored offset up to its last newline, so a line still being written is
# read whole on a later run. A transcript that shrank, was replaced (other inode) or whose first bytes changed
# is read again from 0, and its sessions' earlier prompts and tokens are dropped first. Events files are keyed
# by inode, so a rotated file (the old live file, renamed) carries on from its offset and the new live file
# starts at 0. A transcript that disappears (Claude Code's 30-day cleanup) keeps what was extracted from it.
# Malformed lines are skipped. Deleting .work rebuilds everything from what is on disk.
#
# Exit: 0 ok | 1 a step failed (the old .work is left as it was) | 3 .work cannot be used.
# Env: AGENT_HOME CLAUDE_DIR TZ (days are local dates)
set -euo pipefail
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"
umask 077

case "${1:-}" in -h|--help) sed -n '2,/^# Env:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;; esac

OFFS=$(proposal_safe_path .work/offsets) || exit 3
WD=${OFFS%/*}
for f in prompts.jsonl toolseq.jsonl events.jsonl extract-state.json; do
  proposal_safe_path ".work/$f" >/dev/null || exit 3
done
PROMPTS=$WD/prompts.jsonl TOOLSEQ=$WD/toolseq.jsonl EVOUT=$WD/events.jsonl STATE=$WD/extract-state.json
LEARN_WORK=$(learn_work_dir)

TMP=$(mktemp -d "${TMPDIR:-/tmp}/kaching-learn-extract.XXXXXX")
trap 'rm -rf "$TMP"; rm -f "$WD"/.extract-new.*' EXIT
die() { echo "learn-extract: $1" >&2; exit 1; }

# ---------- carried state; offsets and state must come from the same run, else everything is rebuilt ----------
GEN=0
if [ -f "$OFFS" ] && [ -f "$STATE" ] && [ -f "$PROMPTS" ]; then
  og=$(sed -n '1s/^# gen //p' "$OFFS")
  sg=$(jq -r '.gen // empty' "$STATE" 2>/dev/null || true)
  if [ -n "$og" ] && [ "$og" = "$sg" ]; then GEN=$og; fi
fi
if [ "$GEN" = 0 ]; then   # first run, or .work damaged: start again from 0
  printf '{"files":{},"sessions":{}}\n' >"$TMP/state.json"
  : >"$TMP/offsets.old"
  : >"$TMP/prompts.old"
  : >"$TMP/events.old"
else
  cp "$STATE" "$TMP/state.json"
  cp "$OFFS" "$TMP/offsets.old"
  cp "$PROMPTS" "$TMP/prompts.old"
  if [ -f "$EVOUT" ]; then cp "$EVOUT" "$TMP/events.old"; else : >"$TMP/events.old"; fi
fi

# ---------- the byte-offset reader (perl) ----------
# perl -e READER MODE OLD NEW < paths: prints, for every file with new complete lines or a reset, the line
# "\001<reset 0|1>\t<path>" and then those lines. MODE path: transcripts, keyed by path (a different inode is a
# reset; a vanished file keeps its entry). MODE inode: events files, keyed by dev:ino (vanished ones dropped).
# OLD holds the stored entries of every mode; NEW gets this mode's entries.
# shellcheck disable=SC2016 # perl source
READER='
use strict; use warnings; use Digest::SHA qw(sha1_hex);
my ($mode, $old, $new) = @ARGV;
my (%st, @order);
if (open(my $in, "<", $old)) {
  while (<$in>) {
    chomp; next if /^#/;
    my @f = split /\t/, $_, -1;
    next unless @f == 7 && $f[0] eq $mode;
    shift @f; $st{$f[0]} = [@f]; push @order, $f[0];
  }
  close $in;
}
sub head { my ($p, $n) = @_; return sha1_hex("") if $n <= 0; open(my $h, "<:raw", $p) or return "";
  my $b = ""; read($h, $b, $n); close $h; return sha1_hex($b); }
binmode STDOUT;
my (%seen, @out);
while (my $p = <STDIN>) {
  chomp $p; next if $p eq "";
  my @s = stat($p); next unless @s && -f _;
  my ($dev, $ino, $size) = @s[0, 1, 7];
  my $key = $mode eq "inode" ? "$dev:$ino" : $p;
  next if $seen{$key}++;
  my ($start, $reset) = (0, 0);
  if (my $o = $st{$key}) {
    my (undef, $oino, $off, $hlen, $hsha) = @$o;
    if (($mode eq "path" && $oino ne "$dev:$ino") || $size < $off || head($p, $hlen) ne $hsha) { $reset = 1 }
    else { $start = $off }
  }
  my $fh;
  unless (open($fh, "<:raw", $p)) { $seen{$key} = 0; next }   # unreadable now: keep the old entry
  seek($fh, $start, 0);
  my ($end, $pend, $buf, $marked) = ($start, "", "", 0);
  if ($reset) { print "\001$reset\t$p\n"; $marked = 1 }
  while (read($fh, $buf, 1 << 20)) {
    $pend .= $buf;
    my $nl = rindex($pend, "\n");
    next if $nl < 0;
    print "\001$reset\t$p\n" unless $marked++;
    print substr($pend, 0, $nl + 1);
    $end += $nl + 1;
    $pend = substr($pend, $nl + 1);
  }
  close $fh;
  my $hlen = $end < 256 ? $end : 256;
  push @out, join("\t", $mode, $key, "$dev:$ino", $end, $hlen, head($p, $hlen), $p);
}
for my $k (@order) {   # transcripts that vanished (or could not be read) keep their entry
  next if $seen{$k} || $mode ne "path";
  push @out, join("\t", $mode, @{$st{$k}});
}
open(my $o, ">", $new) or die "cannot write $new\n";
print $o "$_\n" for @out;
close $o or die "cannot write $new\n";
'

# ---------- transcripts ----------
: >"$TMP/files"
if [ -d "$CLAUDE_DIR/projects" ]; then
  skip=$(for d in "$CLAUDE_DIR"/projects/*/; do [ -d "$d" ] || continue; d=${d%/}; printf '%s\n' "${d##*/}"; done \
    | jq -Rr --arg w "$LEARN_WORK" -L "$LIB_DIR" 'include "learn-filter"; select(learn_project_excluded($w))') \
    || die "cannot judge the project directories"
  for d in "$CLAUDE_DIR"/projects/*/; do
    [ -d "$d" ] || continue
    d=${d%/}
    if [ -n "$skip" ] && printf '%s\n' "$skip" | grep -qxF -- "${d##*/}"; then continue; fi
    for f in "$d"/*.jsonl; do if [ -f "$f" ]; then printf "%s\n" "$f"; fi; done >>"$TMP/files"
  done
fi
perl -e "$READER" path "$TMP/offsets.old" "$TMP/offsets.path" <"$TMP/files" >"$TMP/raw" || die "cannot read the transcripts"

# The fold: one pass over the new lines, carrying the state. Emits {"prompt":...} per counted prompt, then one
# {"state":..., "dropped":[sids]} at the end (dropped: sessions of transcripts read again from 0).
# shellcheck disable=SC2016 # jq source
FOLD='
include "learn-filter";
def plumbing: "ToolSearch", "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "TaskStop",
  "TaskOutput", "mcp__claude-in-chrome__tabs_context_mcp";
# a leading `cd <dir> &&` or `cd <dir>;` (repeated) is not part of the command
def strip_cd:
  "^cd\\s+(\"[^\"]*\"|\u0027[^\u0027]*\u0027|[^\\s;&|]+)\\s*(&&|;)\\s*" as $re
  | if startswith("cd") and test($re) then sub($re; "") | strip_cd else . end;
# Bash: the first two words that are not flags or NAME=value; git -C <dir> and -c <k=v> skip their argument
def bash_token:
  (tostring | .[0:2000] | sub("^\\s+"; "") | strip_cd | [splits("\\s+")] | map(select(. != ""))) as $w
  | ($w[0:16] | map(.)) as $h   # the first words are enough (a heredoc can hold thousands); map(.) copies the slice
  | (if ($h[0] // "") == "git" then
       reduce ($h[1:] | map(.))[] as $x ({out: ["git"], skip: false};
         if .skip then .skip = false elif $x == "-C" or $x == "-c" then .skip = true else .out += [$x] end)
       | .out
     else $h end)
  | [limit(2; .[] | select((startswith("-") | not) and (test("^[A-Za-z_][A-Za-z0-9_]*=") | not)))]
  | join(" ") | if . == "" then "Bash" else . end;
def tool_token:
  (.name // "" | tostring) as $n
  | if $n == "" or any(plumbing; . == $n) then empty
    elif $n == "Bash" then (.input.command // "" | bash_token)
    elif $n == "Skill" then ((.input.skill // "") | tostring) as $s | if $s == "" then "Skill" else "Skill:" + $s end
    else $n end;
def local_day: tostring | (try (sub("\\.[0-9]+"; "") | fromdateiso8601 | strflocaltime("%Y-%m-%d")) catch .[0:10]);
def newfile: {tail: "", intr: false, sids: []};
# The file being read is kept in .c (its tail, interrupt flag, sids and their sessions) and written back to .s
# when the next file starts: an update then copies a small object, not the maps of every file and session.
def flush:
  if .f == null then . else
    .s.files[.f] = {tail: .c.tail, intr: .c.intr, sids: .c.sids}
    | reduce (.c.sess | to_entries[]) as $e (.; .s.sessions[$e.key] = $e.value)
  end;
def touch($sid):
  (if .c.sess[$sid] == null then .c.sess[$sid] = (.s.sessions[$sid] // {}) else . end)
  | if (.c.sids | index([$sid])) then . else .c.sids += [$sid] end;

foreach ((inputs | select(. != "")), "\u0001END") as $raw (
  {s: $st[0], f: null, c: null, emit: null, dropped: []};
  .emit = null
  | if ($raw | startswith("\u0001")) then
      flush
      | if $raw == "\u0001END" then .emit = "END"
        else ($raw[1:] | split("\t")) as $m
          | .f = ($m[1:] | map(.) | join("\t"))
          | if $m[0] == "1" then
              (.s.files[.f].sids // []) as $old
              | .dropped += $old
              | reduce $old[] as $sid (.; del(.s.sessions[$sid]))
              | .c = newfile + {sess: {}}
            else .c = ((.s.files[.f] // newfile) + {sess: {}}) end
        end
    else
      ($raw | fromjson? // null) as $L
      | if ($L | type) == "object" and ($L.type == "user" or $L.type == "assistant") and .f != null then
          (if ($L.sessionId | type) == "string" and $L.sessionId != "" then $L.sessionId
           else .f | split("/") | last | sub("\\.jsonl$"; "") end) as $sid
          | touch($sid)
          | (if .c.sess[$sid].seen then . else .c.sess[$sid].seen = true end)
          | if ($L | learn_session_ok($work)) then
              (if .c.sess[$sid].ok then . else .c.sess[$sid].ok = true end)
              | (if .c.sess[$sid].cwd == null and ($L.cwd | type) == "string" then .c.sess[$sid].cwd = $L.cwd else . end)
              | if $L.type == "assistant" then
                  ($L.message.content? // [] | if type == "array" then . else [] end) as $c
                  | ([$c[] | select(type == "object" and .type == "text") | (.text // "" | tostring)] | join("\n")) as $txt
                  | (if ($txt | test("\\S")) then .c.tail = $txt else . end)
                  | reduce ($c[] | select(type == "object" and .type == "tool_use") | tool_token) as $tok (.;
                      if (.c.sess[$sid].tokens // [] | last) == $tok then .
                      else .c.sess[$sid].tokens += [$tok]
                        | (if .c.sess[$sid].day == null then .c.sess[$sid].day = ($L.timestamp | local_day) else . end)
                      end)
                elif ($L | learn_interrupt) then .c.intr = true
                elif ($L.timestamp | type) == "string" and ($L | learn_human_prompt($work)) then
                  .emit = {sid: $sid, ts: $L.timestamp, cwd: ($L.cwd // "" | tostring), text: ($L | learn_prompt_text),
                           prev_assistant_tail: .c.tail, after_interrupt: .c.intr}
                  | .c.intr = false
                  | .c.sess[$sid].prompts += [{i: (.c.sess[$sid].tokens // [] | length), ts: $L.timestamp}]
                else . end
            else . end
        else . end
    end;
  if .emit == "END" then {state: .s, dropped: (.dropped | unique)}
  elif .emit != null then {prompt: .emit}
  else empty end)
'
jq -n -R -c -L "$LIB_DIR" --arg work "$LEARN_WORK" --slurpfile st "$TMP/state.json" "$FOLD" <"$TMP/raw" >"$TMP/fold" \
  || die "the transcript pass failed"
rm -f "$TMP/raw"
tail -n 1 "$TMP/fold" | jq -c '.state' >"$TMP/state.new" || die "the transcript pass gave no state"
tail -n 1 "$TMP/fold" | jq -c '.dropped' >"$TMP/dropped" || die "the transcript pass gave no state"

# new prompts: redact the whole text and tail first, then cut (a cut could split a secret and hide it)
{ grep '^{"prompt":' "$TMP/fold" || true; } | jq -c '.prompt' | learn_redact --jsonl \
  | jq -c '{sid, ts, cwd, text: (.text | .[0:600]), prev_assistant_tail: (.prev_assistant_tail | .[-300:]),
            after_interrupt}' >"$TMP/prompts.add" || die "cannot redact the new prompts"
rm -f "$TMP/fold"

# prompts.jsonl: the old lines minus the sessions read again, then the new ones; (sid, ts) stays unique
{ jq -c --slurpfile drop "$TMP/dropped" '($drop[0] | map({key: ., value: true}) | from_entries) as $d | select($d[.sid] | not)' \
    "$TMP/prompts.old"; cat "$TMP/prompts.add"; } \
  | jq -n -c '
      foreach (inputs | select(type == "object")) as $p ({seen: {}, out: null};
          "\($p.sid)@\($p.ts)" as $k
          | if .seen[$k] then .out = null else .seen[$k] = true | .out = $p end;
          .out // empty)' >"$TMP/prompts.new" || die "cannot merge prompts.jsonl"

# toolseq.jsonl: every countable session with a token, rebuilt from the state
jq -c '.sessions | to_entries | map(select(.value.ok == true and ((.value.tokens // []) | length) > 0))
       | sort_by(.value.day, .key) | .[]
       | {sid: .key, day: .value.day, cwd: (.value.cwd // ""), tokens: .value.tokens, prompts: (.value.prompts // [])}' \
  "$TMP/state.new" >"$TMP/toolseq.new" || die "cannot build toolseq.jsonl"

# ---------- events: the live file and the rotated ones, oldest first ----------
: >"$TMP/evfiles"
for f in "$AGENT_HOME"/events-[0-9]*.jsonl; do if [ -f "$f" ]; then printf "%s\n" "$f"; fi; done | sort >>"$TMP/evfiles"
if [ -f "$AGENT_HOME/events.jsonl" ]; then printf '%s\n' "$AGENT_HOME/events.jsonl" >>"$TMP/evfiles"; fi
perl -e "$READER" inode "$TMP/offsets.old" "$TMP/offsets.inode" <"$TMP/evfiles" \
  | jq -R -c -L "$LIB_DIR" --arg work "$LEARN_WORK" \
      'include "learn-filter"; select(startswith("\u0001") | not) | fromjson? // empty | select(learn_event_ok($work))' \
      >"$TMP/events.add" || die "cannot read the events files"
cat "$TMP/events.old" "$TMP/events.add" >"$TMP/events.new"

# ---------- write: the outputs first, the offsets last (offsets and state share a generation number) ----------
GEN=$((GEN + 1))
jq -c --argjson g "$GEN" '. + {gen: $g}' "$TMP/state.new" >"$TMP/state.out" || die "cannot write the state"
{ printf '# gen %s\n' "$GEN"; cat "$TMP/offsets.path" "$TMP/offsets.inode"; } >"$TMP/offsets.new"
put() { # tmpfile target: atomic replace inside .work, mode 0600
  local t="$WD/.extract-new.${2##*/}"
  if ! cp "$1" "$t" || ! chmod 600 "$t" || ! mv -f "$t" "$2"; then die "cannot write $2"; fi
}
put "$TMP/prompts.new" "$PROMPTS"
put "$TMP/toolseq.new" "$TOOLSEQ"
put "$TMP/events.new" "$EVOUT"
put "$TMP/state.out" "$STATE"
put "$TMP/offsets.new" "$OFFS"
exit 0
