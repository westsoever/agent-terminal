#!/usr/bin/env perl
# learn-redact.pl - the learner's one redaction definition (spec 4.2, 7): replaces credentials with [REDACTED]
# before any quote reaches a proposal file or the model. Called through lib.sh learn_redact.
#
#   learn-redact.pl < text            redact the whole text (multi-line PEM blocks included)
#   learn-redact.pl --jsonl < lines   one JSON value per line: redact every string inside it. A line with nothing
#                                     to redact is printed byte for byte; a changed one is re-encoded (sorted keys);
#                                     a line that is not JSON is redacted as text.
#
# What counts as a credential:
#   1. NAME=value / NAME: value / "NAME": "value", where NAME holds one of the guard's credential words. These are
#      the words of guard.sh var_is_secret (TOKEN SECRET PASSWORD API_KEY PRIVATE_KEY; t_proposals.sh fails if
#      the guard gains a word this list lacks) plus APIKEY and PASSWD. Case-insensitive, so prose such as
#      "token: x" loses one word: over-redaction is the safe side.
#   2. Value shapes that need no name: PEM private key blocks, sk-... (Anthropic/OpenAI), GitHub gh?_ and
#      github_pat_, AWS AKIA/ASIA, Slack xox?-, Stripe sk_/rk_ live/test and whsec_, Supabase sbp_ and
#      sb_secret_, Google AIza, JWTs (eyJ.eyJ.sig), Bearer tokens, and the password in scheme://user:pw@host.
# Core perl only (JSON::PP is core). Never fails on odd input: unreadable JSON falls back to text mode.
use strict;
use warnings;

my $R = '[REDACTED]';
my $WORDS = join '|', qw(TOKEN SECRET PASSWORD PASSWD API_KEY APIKEY PRIVATE_KEY);

sub redact {
  my ($s) = @_;
  return $s unless defined $s && length $s;
  $s =~ s/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\z)/$R/gs;
  $s =~ s/\bsk-[A-Za-z0-9_-]{20,}/$R/g;
  $s =~ s/\bgh[pousr]_[A-Za-z0-9]{20,}/$R/g;
  $s =~ s/\bgithub_pat_[A-Za-z0-9_]{20,}/$R/g;
  $s =~ s/\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/$R/g;
  $s =~ s/\bxox[abposr]-[A-Za-z0-9-]{10,}/$R/g;
  $s =~ s/\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}/$R/g;
  $s =~ s/\bwhsec_[A-Za-z0-9]{16,}/$R/g;
  $s =~ s/\bsbp_[A-Za-z0-9]{20,}/$R/g;
  $s =~ s/\bsb_secret_[A-Za-z0-9_-]{16,}/$R/g;
  $s =~ s/\bAIza[0-9A-Za-z_-]{35}/$R/g;
  $s =~ s/\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/$R/g;
  $s =~ s/(\bBearer\s+)[A-Za-z0-9._~+\/=-]{16,}/$1$R/g;
  $s =~ s{(\b[A-Za-z][A-Za-z0-9+.-]*://[^/\s:@]+:)[^@\s/]+@}{$1$R\@}g;
  # NAME=value: keep the name and the quotes' place, drop the value ([REDACTED] itself is left as it is)
  $s =~ s/\b([A-Za-z0-9_]*(?:$WORDS)[A-Za-z0-9_]*)(["']?[ \t]*[:=][ \t]*)("[^"\n]*"|'[^'\n]*'|[^\s"',;]+)/
          my $q = substr($3, 0, 1); ($q eq '"' || $q eq "'") ? "$1$2$q$R$q" : "$1$2$R"/gie;
  return $s;
}

if (@ARGV && $ARGV[0] eq '--jsonl') {
  require JSON::PP;
  my $js = JSON::PP->new->utf8->canonical->allow_nonref;
  my $changed;
  my $walk;
  $walk = sub {
    my ($v) = @_;
    if (ref $v eq 'HASH') { $v->{$_} = $walk->($v->{$_}) for keys %$v; return $v }
    if (ref $v eq 'ARRAY') { $_ = $walk->($_) for @$v; return $v }
    if (defined $v && !ref $v && !JSON::PP::is_bool($v)) {
      # numbers stay numbers: only a value that is a string on the JSON side is touched
      my $r = redact($v);
      if ($r ne $v) { $changed = 1; return $r }
    }
    return $v;
  };
  while (my $line = <STDIN>) {
    chomp $line;
    my $v = eval { $js->decode($line) };
    if ($@ || !defined $v && $line ne 'null') { print redact($line), "\n"; next }
    $changed = 0;
    $v = $walk->($v);
    print $changed ? $js->encode($v) : $line, "\n";
  }
} else {
  local $/;
  my $all = <STDIN>;
  print redact(defined $all ? $all : '');
}
