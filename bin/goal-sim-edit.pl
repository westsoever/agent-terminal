#!/usr/bin/env perl
# goal-sim-edit.pl - helper for guard.sh rule 11 (gate settings in GOAL.md).
# usage: goal-sim-edit.pl TOOL FILE < hook-json
# Prints FILE's text as it would be after the Edit (TOOL=Edit) or MultiEdit (anything else) in the hook JSON,
# so the guard can compare the gated lines before and after. The edit strings are data: they are matched with
# index/substr only and never reach a regex or code. Edits apply in order on the evolving text; an old_string
# that is empty or not found changes nothing (the Edit tool itself would fail on it). Core modules only.
# Exit non-zero (open failure, bad JSON) means "could not simulate"; the guard then denies.
use strict;
use warnings;
use JSON::PP;

my ($tool, $file) = @ARGV;
local $/;
my $in = decode_json(scalar <STDIN>)->{tool_input};
open my $fh, '<:raw', $file or exit 3;
my $t = <$fh>;
close $fh;
$t = '' unless defined $t;

my @edits = $tool eq 'MultiEdit' ? @{ $in->{edits} || [] } : ($in);
for my $e (@edits) {
    my ($o, $n) = ($e->{old_string}, $e->{new_string});
    next unless defined $o && defined $n && !ref $o && !ref $n && length $o;
    utf8::encode($o);
    utf8::encode($n);
    my $i = index($t, $o);
    next if $i < 0;
    if ($e->{replace_all}) {
        my ($p, $out) = (0, '');
        while (($i = index($t, $o, $p)) >= 0) {
            $out .= substr($t, $p, $i - $p) . $n;
            $p = $i + length $o;
        }
        $t = $out . substr($t, $p);
    } else {
        substr($t, $i, length $o) = $n;
    }
}
binmode STDOUT;
print $t;
