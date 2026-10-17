#!/usr/bin/env bash
# ask-check.sh < MESSAGE: does a finished turn (the agent's last message) need the owner?
# Prints two lines: "input" or "done", then the sentence that asks (empty for done), markup removed, at most
# 200 characters, so the agent terminal can show what the agent wants.
# The tail is read: the last 6 non-empty lines, after code blocks and # headings are dropped (a "?" inside inline
# code or a URL does not count).
#   input  a sentence there ends in "?" (the last one is the ask), else a sentence there asks the owner to do or
#          decide something ("let me know", "tell me", "should I", "you'll need to", "left the check to you" ...)
#   done   anything else, and sentences that say nothing is needed ("no action needed from you")
# Used by stop-check.sh (the state and the notification) and safe to run by hand on a transcript's last text.
set -euo pipefail
exec perl -CSD -e '
  local $/; my $t = <STDIN> // "";
  $t =~ s/^\s*```.*?^\s*```[^\n]*$//msg;   # code blocks
  # inline code and URLs stay in the text, but a "?" in them is no question: hidden as U+E000 until printed
  $t =~ s/`([^`\n]*)`/(my $c = $1) =~ tr{?}{\x{E000}}; $c/ge;
  $t =~ s{(\b[a-z][a-z0-9+.-]*://\S+)}{(my $c = $1) =~ tr{?}{\x{E000}}; $c}gie;
  my @lines = grep { /\S/ && !/^\s*#/ } split /\n/, $t;
  @lines = @lines[-6 .. -1] if @lines > 6;
  my @sent;                                # the tail sentences, in order
  for my $l (@lines) {
    $l =~ s/\*\*|__//g;
    $l =~ s/^\s*(?:[-*>]|\d+[.)])\s+//;
    $l =~ s/^\s+|\s+$//g;
    push @sent, grep { /\S/ } split /(?<=[.?!])["\x27)\]]*\s+(?=\S)/, $l;
  }
  my $none = qr/\b(?:no (?:action|input|decision)s? (?:is )?(?:needed|required)|nothing (?:else )?(?:is )?(?:needed )?(?:for|from) you|(?:don\x27t|do not|no) need to)\b/i;
  my $asks = join "|", map { "\\b$_\\b" } (
    "let me know", "tell me", "(?:left|leave|leaving)\\b.{0,40}\\bto you",
    "you(?:\x27ll| will)? (?:need|have) to", "(?:can|could|would) you", "do you want",
    "(?:should|shall) I", "want me to", "up to you", "over to you", "say the word",
    "please (?:confirm|approve|choose|pick|decide|check|test|run|try|allow|review|answer|reply|look|send|grant|enable|add|restart|open)",
    "your (?:call|go-ahead|approval|ok|okay|answer|decision|input|choice|confirmation)",
    "(?:need|needs|waiting (?:for|on)) (?:your|you)");
  $asks = qr/$asks/i;
  my ($kind, $ask) = ("done", "");
  for my $s (reverse @sent) {
    if ($s =~ /\?["\x27)\]*_]*$/) { ($kind, $ask) = ("input", $s); last }
  }
  if ($kind eq "done") {
    for my $s (reverse @sent) {
      next if $s =~ $none;
      if ($s =~ $asks) { ($kind, $ask) = ("input", $s); last }
    }
  }
  $ask =~ s/^[*_]+|[*_]+$//g;
  $ask =~ tr{\x{E000}}{?};
  $ask = substr($ask, 0, 197) . "..." if length($ask) > 200;
  print "$kind\n$ask\n";
'
