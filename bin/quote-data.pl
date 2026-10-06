#!/usr/bin/env perl
# quote-data.pl - helper for guard.sh: the segment splitter cuts at ; | & ( ) without looking at quotes, so the
# pattern in `grep -nE 'gh release create|npm publish' f` became a second command `npm publish' f` (a false deny).
# usage: quote-data.pl < text
# Prints the text with the characters ; | & ( ) < > blanked (replaced by a space) inside the quoted strings that
# are DATA: arguments, after the command word, of a command that never runs its arguments (grep, egrep, fgrep,
# rg, echo, printf, git commit/tag, gh pr|issue create/comment/edit). Everything else is printed as it was,
# so quoted text handed to bash -c, eval, ssh, watch, an interpreter or any unknown command is still split
# and scanned as before. Same length, same lines: the guard's other checks see the same tokens.
# The text is lexed the way bash reads it (quotes, escapes, $(...) nesting, comments). Anything this lexer
# could get wrong leaves the WHOLE text unchanged (the old, stricter behaviour): a heredoc (its body is not
# shell), a backtick, case/esac, ${...} holding quotes or substitutions, an unterminated quote or $(.
# Only a quoted string that opens and closes on one line is blanked, and a double-quoted one only when it holds
# no $( substitution (that is code). Core perl only; exit non-zero means the guard fails closed.
use strict;
use warnings;

local $/;
my $s = <STDIN>;
$s = '' unless defined $s;
my $n = length $s;

sub unchanged { print $s; exit 0 }
unchanged() if $s =~ /\besac\b/;

my %DATA = map { $_ => 1 } qw(grep egrep fgrep rg echo printf);
# wrappers that run their command directly (no shell re-parse of the words: not eval, watch, ssh, parallel, bash)
my %WRAP = map { $_ => 1 } qw(sudo env command exec time nohup nice ionice xargs timeout caffeinate then do else if elif while until ! {);
my %VALUE_OPT = (xargs => qr/^-[IJadELnPRSs]$/, sudo => qr/^-[ugpCDRrtU]$/, env => qr/^-[uCP]$/,
                 timeout => qr/^-[sk]$/, exec => qr/^-a$/);

my @blank;   # [start, end] of quote contents to blank

sub new_frame { return { t => 'T', cs => $_[0], depth => 0, words => [], cur => '', plain => 1, spans => [] } }

sub end_word {
    my $f = shift;
    return if $f->{cur} eq '';
    push @{ $f->{words} }, { text => $f->{cur}, plain => $f->{plain} };
    $f->{cur} = ''; $f->{plain} = 1;
}

sub base { my $w = shift; $w =~ s{.*/}{}; return $w }

sub data_from { # words -> index of the first word whose quoted strings are data, or -1
    my @w = @{ $_[0] };
    my ($k, $wrap) = (0, '');
    while ($k < @w) {
        my $x = $w[$k]{text};
        if ($x =~ /^(?:[0-9]*[<>]|&>)/) { $k++; $k++ if $x =~ /^[0-9]*[<>&]+$/; next }   # redirection
        return -1 if $wrap eq 'sudo' && $x =~ /^(?:-[A-Za-z]*[si]|--shell|--login)/;   # sudo -s/-i hand the words to a shell
        if ($x =~ /^-/) { $k++ if $wrap ne '' && $VALUE_OPT{$wrap} && $x =~ $VALUE_OPT{$wrap}; $k++; next }
        if ($x =~ /=/ || $x =~ /^[0-9]/) { $k++; next }
        last unless $w[$k]{plain};
        if ($WRAP{ base($x) }) { $wrap = base($x); $k++; next }
        last;
    }
    return -1 if $k >= @w || !$w[$k]{plain};
    my $b = base($w[$k]{text});
    return $k + 1 if $DATA{$b};
    my @sub;   # the first non-option words after git/gh (-C, -c, -R, --repo take a value)
    my $j = $k + 1;
    while ($j < @w && @sub < 2) {
        my $x = $w[$j]{text};
        last unless $w[$j]{plain};
        if ($x =~ /^(?:-C|-c|-R|--repo)$/) { $j += 2; next }
        if ($x =~ /^-/) { $j++; next }
        push @sub, $x; $j++;
    }
    if ($b eq 'git' && @sub && $sub[0] =~ /^(?:commit|tag)$/) {   # the strings after the subcommand word only
        for my $q ($k + 1 .. $#w) { return $q + 1 if $w[$q]{text} eq $sub[0] }
    }
    if ($b eq 'gh' && @sub == 2 && $sub[0] =~ /^(?:pr|issue)$/ && $sub[1] =~ /^(?:create|comment|edit)$/) {
        for my $q ($k + 1 .. $#w) { return $q + 1 if $w[$q]{text} eq $sub[1] }
    }
    return -1;
}

sub end_cmd {
    my $f = shift;
    end_word($f);
    my $from = data_from($f->{words});
    if ($from >= 0) {
        my %redir;   # a redirection target is a path, never data: `echo x >> '.agent/a>b/../GOAL.md'`
        my @w = @{ $f->{words} };
        for my $q (0 .. $#w) {
            next unless $w[$q]{text} =~ /^(?:[0-9]*[<>]|&>)/;
            $redir{$q} = 1;
            $redir{ $q + 1 } = 1 if $w[$q]{text} =~ /^[0-9]*[<>&]+$/;
        }
        for my $sp (@{ $f->{spans} }) {
            next if $sp->{w} < $from || $sp->{sub} || $redir{ $sp->{w} };
            next if index(substr($s, $sp->{s}, $sp->{e} - $sp->{s}), "\n") >= 0;   # one line only
            push @blank, [ $sp->{s} + 1, $sp->{e} ];
        }
    }
    $f->{words} = []; $f->{spans} = [];
}

sub skip_brace { # index of "${" -> index after its "}"; quotes or substitutions inside: unchanged
    my $i = $_[0] + 2;
    while ($i < $n) {
        my $c = substr($s, $i, 1);
        return $i + 1 if $c eq '}';
        unchanged() if $c eq "'" || $c eq '"' || $c eq '`' || $c eq '$' || $c eq '\\';
        $i++;
    }
    unchanged();
}

my @st = (new_frame(0));
my $i = 0;
while ($i < $n) {
    my $c = substr($s, $i, 1);
    my $nx = substr($s, $i + 1, 1);
    my $top = $st[-1];
    my $t = $top->{t};
    if ($t eq 'S') {
        if ($c eq "'") { pop @st; push @{ $top->{f}{spans} }, { s => $top->{s}, e => $i, w => $top->{w}, sub => 0 } }
        $i++; next;
    }
    if ($t eq 'A' || $t eq 'D') {
        if ($c eq '\\') { $i += 2; next }
        my $close = $t eq 'A' ? "'" : '"';
        if ($c eq $close) {
            pop @st; push @{ $top->{f}{spans} }, { s => $top->{s}, e => $i, w => $top->{w}, sub => $top->{sub} };
            $i++; next;
        }
        if ($t eq 'D') {
            unchanged() if $c eq '`';
            if ($c eq '$' && $nx eq '(') { $top->{sub} = 1; push @st, new_frame(1); $i += 2; next }
            if ($c eq '$' && $nx eq '{') { $i = skip_brace($i); next }
        }
        $i++; next;
    }
    # unquoted (top level or inside $(...))
    if ($c eq '\\') { $top->{cur} .= substr($s, $i, 2); $top->{plain} = 0; $i += 2; next }
    if ($c eq "'" || $c eq '"' || ($c eq '$' && $nx eq "'")) {
        my $q = $c eq '$' ? 'A' : $c eq "'" ? 'S' : 'D';
        my $start = $c eq '$' ? $i + 1 : $i;
        $top->{cur} .= 'Q'; $top->{plain} = 0;
        push @st, { t => $q, s => $start, f => $top, w => scalar @{ $top->{words} }, sub => 0 };
        $i = $start + 1; next;
    }
    unchanged() if $c eq '`';
    if ($c eq '$' && $nx eq '(') { $top->{cur} .= '$('; $top->{plain} = 0; push @st, new_frame(1); $i += 2; next }
    if ($c eq '$' && $nx eq '{') { my $e = skip_brace($i); $top->{cur} .= substr($s, $i, $e - $i); $top->{plain} = 0; $i = $e; next }
    if ($c eq '#' && $top->{cur} eq '') { my $e = index($s, "\n", $i); $i = $e < 0 ? $n : $e; next }
    if ($c eq '<' && $nx eq '<') {
        unchanged() if substr($s, $i + 2, 1) ne '<';   # a heredoc: its body is not shell
        $top->{cur} .= '<<<'; $i += 3; next;
    }
    if ($c eq ' ' || $c eq "\t") { end_word($top); $i++; next }
    if ($c eq "\n" || $c eq ';' || $c eq '&' || $c eq '|') { end_cmd($top); $i++; next }
    if ($c eq '(') { end_cmd($top); $top->{depth}++; $i++; next }
    if ($c eq ')') {
        end_cmd($top);
        if ($top->{depth} > 0) { $top->{depth}-- }
        elsif ($top->{cs}) { pop @st }
        $i++; next;
    }
    $top->{cur} .= $c; $i++;
}
unchanged() if @st != 1;   # an unterminated quote or $(
end_cmd($st[0]);
for my $b (@blank) {
    for my $p ($b->[0] .. $b->[1] - 1) {
        substr($s, $p, 1) = ' ' if index(';|&()<>', substr($s, $p, 1)) >= 0;
    }
}
print $s;
