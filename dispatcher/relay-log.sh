#!/usr/bin/env bash
# relay-log.sh STATE_DIR yes|no TEXT - the dispatcher's one write: append a line to "## Relayed instructions"
# in a session's STATE.md (PLAN 4.1: every relayed instruction is logged; 4.2: the dispatcher has no Edit or Write).
#
#   STATE_DIR  a repo's .agent/ folder or $AGENT_HOME/sessions/<id>/, and it must already hold a STATE.md
#   yes|no     whether the user said "yes" to the read-back (no = a safe instruction relayed without one)
#   TEXT       what was relayed; control characters become spaces or are dropped, cut at 300 characters
#
# Writes `- YYYY-MM-DD HH:MM | confirmed|unconfirmed | TEXT` under the section (a "- (none)" placeholder is
# replaced; a missing section is added at the end), keeps the file mode, writes through a temp file and a rename,
# and logs a `relay` event. It never creates a STATE.md, never follows a symlinked STATE.md and writes nowhere else.
# Exit 64 for a usage error, 1 for a refusal.
set -euo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../bin/lib.sh
. "$SELF_DIR/../bin/lib.sh"

refuse() { echo "relay-log: $*" >&2; exit 1; }
[ $# -eq 3 ] || { echo "usage: relay-log.sh STATE_DIR yes|no TEXT" >&2; exit 64; }

real_path() { perl -MCwd=abs_path -e 'my $p = abs_path($ARGV[0]); print $p if defined $p' -- "$1" 2>/dev/null || true; }

arg_dir=$1
# shellcheck disable=SC2088
case "$arg_dir" in "~/"*) arg_dir="$HOME/${arg_dir#"~/"}" ;; esac
case "$2" in yes) conf=confirmed ;; no) conf=unconfirmed ;; *) refuse "the second argument is yes or no" ;; esac

TEXT=$(printf '%s' "$3" | LC_ALL=C tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' | sed 's/  */ /g; s/^ //; s/ $//')
TEXT=${TEXT:0:300}
[ -n "$TEXT" ] || refuse "no text to log"

dir=$(real_path "$arg_dir")
[ -n "$dir" ] && [ -d "$dir" ] || refuse "$arg_dir is not a folder"
ok=0
[ "${dir##*/}" = ".agent" ] && ok=1
ah=$(real_path "$AGENT_HOME")
if [ -n "$ah" ] && [ "${dir%/*}" = "$ah/sessions" ]; then ok=1; fi
[ "$ok" -eq 1 ] || refuse "$arg_dir is not a session state folder (a .agent/ folder or sessions/<id>/)"
STATE=$dir/STATE.md
[ -f "$STATE" ] && [ ! -L "$STATE" ] || refuse "$dir has no STATE.md of its own (it is missing or a symlink); nothing was written"

ENTRY="- $(date '+%Y-%m-%d %H:%M') | $conf | $TEXT"
TMP=$(mktemp "$dir/.STATE.relay.XXXXXX")
trap 'rm -f "$TMP"' EXIT
perl -e '
  my ($file, $entry) = @ARGV;
  open(my $in, "<", $file) or die "read $file: $!";
  my @L = <$in>; close $in;
  chomp @L;
  my ($s) = grep { $L[$_] =~ /^## Relayed instructions\s*$/ } 0 .. $#L;
  if (!defined $s) {
    push @L, "" if @L && $L[-1] ne "";
    push @L, "## Relayed instructions", $entry;
  } else {
    my $e = scalar @L;
    for my $i ($s + 1 .. $#L) { if ($L[$i] =~ /^## /) { $e = $i; last } }
    my ($last, $none) = ($s, undef);
    for my $i ($s + 1 .. $e - 1) {
      next if $L[$i] =~ /^\s*$/;
      $last = $i;
      $none = $i if $L[$i] =~ /^\s*[-*]\s+\(?none\)?\.?\s*$/i;
    }
    if (defined $none) { $L[$none] = $entry } else { splice @L, $last + 1, 0, $entry }
  }
  print join("\n", @L), "\n";
' "$STATE" "$ENTRY" >"$TMP"
mode=$(stat -f %Lp "$STATE" 2>/dev/null || stat -c %a "$STATE")
chmod "$mode" "$TMP"
mv "$TMP" "$STATE"

SID=dispatcher; NAME=dispatcher; CWD=$dir
ev relay "$(jq -nc --arg d "$dir" --arg c "$conf" --arg t "$TEXT" '{state_dir:$d,confirmed:$c,text:$t}')"
echo "logged in $STATE"
