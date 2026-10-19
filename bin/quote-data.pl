#!/usr/bin/env perl
# quote-data.pl - helper for guard.sh: tells quoted DATA from code, so text inside a grep pattern or an echo
# string is not taken for commands or files. Two modes, both print the text with the same length and lines:
#
#   quote-data.pl < text           (for the segment splitter)
#     The splitter cuts at ; | & ( ) without looking at quotes, so `grep -nE 'gh release create|npm publish' f`
#     became a second command `npm publish' f` (a false deny). This blanks ; | & ( ) < > (to a space) inside the
#     quoted strings that are data: arguments, after the command word, of a command that never runs its
#     arguments (grep, egrep, fgrep, rg, echo, printf, curl, jq, git commit/tag, gh pr|issue create/comment/edit).
#     curl and jq carry JSON: a ; in `curl -d '{"run":"ls; rm -rf /tmp/x"}' ~/out` made `~/out` an rm operand.
#     Quoted text handed to bash -c, eval, ssh, watch, an interpreter or any unknown command is left as it was,
#     so it is still split and scanned. Only a string that opens and closes on one line is blanked, a
#     double-quoted one only when it holds no $( substitution (that is code), and never a redirect target.
#     For any command, the quoted part of a VALUE before the command word (FOO="a; b", a redirect target, a
#     wrapper option value such as sudo -u 'a b') has ; | & ( ) < >, spaces and newlines turned into '_': bash
#     reads it as one word, and split up its tail was taken for the command (FOO="a; b" npm publish passed).
#
#   quote-data.pl patterns < text  (for the .env reader check, rule 5)
#     `grep -n "ching.env" f` named no .env file: ching.env is the pattern. This overwrites (with '_') the
#     pattern word of grep/egrep/fgrep/rg/git grep: the first operand when no -e/-f is given, and every -e
#     value. Stops at the first option that may take a value; a word holding < > ` or $( is never overwritten.
#
# The text is lexed the way bash reads it (quotes, escapes, $(...) nesting, comments). Anything this lexer
# could get wrong leaves the WHOLE text unchanged (the old, stricter behaviour): a heredoc (its body is not
# shell), a backtick, case/esac, ${...} holding quotes or substitutions, an unterminated quote or $(.
# Core perl only; exit non-zero means the guard fails closed.
use strict;
use warnings;

my $MODE = $ARGV[0] // 'blank';
local $/;
my $s = <STDIN>;
$s = '' unless defined $s;
my $n = length $s;
my $i = 0;

sub unchanged { print $s; exit 0 }
unchanged() if $s =~ /\besac\b/;

my %DATA = map { $_ => 1 } qw(grep egrep fgrep rg echo printf curl jq);
# wrappers that run their command directly (no shell re-parse of the words: not eval, watch, ssh, parallel, bash)
my %WRAP = map { $_ => 1 } qw(sudo env command exec time nohup nice ionice xargs timeout caffeinate then do else if elif while until ! {);
my %VALUE_OPT = (xargs => qr/^-[IJadELnPRSs]$/, sudo => qr/^-[ugpCDRrtU]$/, env => qr/^-[uCP]$/,
                 timeout => qr/^-[sk]$/, exec => qr/^-a$/);
# long grep/rg options that take no value (any other long option without '=' may take the next word)
my $BOOL_LONG = qr/^--(?:recursive|line-number|ignore-case|count|files-with-matches|files-without-match|extended-regexp|fixed-strings|basic-regexp|perl-regexp|word-regexp|line-regexp|no-filename|with-filename|only-matching|invert-match|quiet|silent|no-messages|hidden|no-ignore|smart-case|case-sensitive|no-heading|heading|vimgrep|json|null|text)$/;

my @blank;   # [start, end) of quote contents to blank (default mode)
my @over;    # [start, end) of pattern words to overwrite (patterns mode)
my @value;   # [start, end) of quoted values before the command word to join into one word (default mode)

sub new_frame { return { t => 'T', cs => $_[0], depth => 0, words => [], cur => '', plain => 1, ws => 0, spans => [] } }

sub wadd { # frame, text: grow the current word (remembering where it starts)
    my ($f, $txt) = @_;
    $f->{ws} = $i if $f->{cur} eq '';
    $f->{cur} .= $txt;
}

sub end_word {
    my $f = shift;
    return if $f->{cur} eq '';
    my $raw = substr($s, $f->{ws}, $i - $f->{ws});
    (my $lit = $raw) =~ tr/'"\\//d;
    push @{ $f->{words} }, { text => $f->{cur}, plain => $f->{plain}, s => $f->{ws}, e => $i, raw => $raw, lit => $lit };
    $f->{cur} = ''; $f->{plain} = 1;
}

sub base { my $w = shift; $w =~ s{.*/}{}; return $w }
sub is_redir { return $_[0] =~ /^(?:[0-9]*[<>]|&>)/ }

sub cmd_index { # words -> index of the command word (past assignments, redirections, direct wrappers), or -1
    my @w = @{ $_[0] };
    my ($k, $wrap) = (0, '');
    while ($k < @w) {
        my $x = $w[$k]{text};
        if (is_redir($x)) { $k++; $k++ if $x =~ /^[0-9]*[<>&]+$/; next }
        return -1 if $wrap eq 'sudo' && $x =~ /^(?:-[A-Za-z]*[si]|--shell|--login)/;   # sudo -s/-i hand the words to a shell
        if ($x =~ /^-/) { $k++ if $wrap ne '' && $VALUE_OPT{$wrap} && $x =~ $VALUE_OPT{$wrap}; $k++; next }
        if ($x =~ /=/ || $x =~ /^[0-9]/) { $k++; next }
        last unless $w[$k]{plain};
        if ($WRAP{ base($x) }) { $wrap = base($x); $k++; next }
        last;
    }
    return -1 if $k >= @w || !$w[$k]{plain};
    return $k;
}

sub prefix_values { # words -> indices of the value words before the command word: assignments (FOO="a; b"),
    # redirect targets and wrapper option values. Their quoted text is a value, never the command.
    my @w = @{ $_[0] };
    my ($k, $wrap, @v) = (0, '');
    while ($k < @w) {
        my $x = $w[$k]{text};
        if (is_redir($x)) { push @v, $k; if ($x =~ /^[0-9]*[<>&]+$/) { $k++; push @v, $k } $k++; next }
        last if $wrap eq 'sudo' && $x =~ /^(?:-[A-Za-z]*[si]|--shell|--login)/;
        if ($x =~ /^-/) { if ($wrap ne '' && $VALUE_OPT{$wrap} && $x =~ $VALUE_OPT{$wrap}) { $k++; push @v, $k } $k++; next }
        if ($x =~ /^[A-Za-z_][A-Za-z0-9_]*\+?=/) { push @v, $k; $k++; next }
        if ($x =~ /=/ || $x =~ /^[0-9]/) { $k++; next }
        last unless $w[$k]{plain};
        if ($WRAP{ base($x) }) { $wrap = base($x); $k++; next }
        last;
    }
    return @v;
}

sub subwords { # words, k -> the first two non-option words after the command word k, with their indices
    my ($w, $k) = @_;
    my @sub;
    my $j = $k + 1;
    while ($j < @$w && @sub < 2) {
        my $x = $w->[$j]{text};
        last unless $w->[$j]{plain};
        if ($x =~ /^(?:-C|-c|-R|--repo)$/) { $j += 2; next }
        if ($x =~ /^-/) { $j++; next }
        push @sub, [ $x, $j ]; $j++;
    }
    return @sub;
}

sub data_from { # words -> index of the first word whose quoted strings are data, or -1
    my $w = $_[0];
    my $k = cmd_index($w);
    return -1 if $k < 0;
    my $b = base($w->[$k]{text});
    return $k + 1 if $DATA{$b};
    my @sub = subwords($w, $k);
    return $sub[0][1] + 1 if $b eq 'git' && @sub && $sub[0][0] =~ /^(?:commit|tag)$/;   # the strings after the subcommand only
    return $sub[1][1] + 1 if $b eq 'gh' && @sub == 2 && $sub[0][0] =~ /^(?:pr|issue)$/ && $sub[1][0] =~ /^(?:create|comment|edit)$/;
    return -1;
}

sub pattern_words { # words -> indices of grep/rg pattern words
    my $w = $_[0];
    my $k = cmd_index($w);
    return () if $k < 0;
    my $b = base($w->[$k]{text});
    my $vl;   # short options that take a value
    if ($b =~ /^(?:grep|egrep|fgrep)$/) { $vl = 'ABCDdefm' }
    elsif ($b eq 'rg') { $vl = 'ABCEMTdefgjmrt' }
    elsif ($b eq 'git') {
        my @sub = subwords($w, $k);
        return () unless @sub && $sub[0][0] eq 'grep';
        $k = $sub[0][1]; $vl = 'ABCefm';
    } else { return () }
    # -e/-f anywhere (grep and rg also take options after the operands): every operand is a file
    my $pos = 1;
    for my $q ($k + 1 .. $#$w) { $pos = 0 if $w->[$q]{lit} =~ /^(?:--regexp|--file|-[A-Za-z]*[ef])/ }
    my @pat;
    my $q = $k + 1;
    while ($q < @$w) {
        my $x = $w->[$q]{lit};
        last if is_redir($w->[$q]{text});
        if ($x eq '-e' || $x eq '--regexp') { push @pat, $q + 1; $q += 2; next }
        if ($x =~ /^--regexp=/) { push @pat, $q; $q++; next }
        if ($x eq '--') { push @pat, $q + 1 if $pos; last }
        if ($x =~ /^--[^=]+=/ || $x =~ $BOOL_LONG) { $q++; next }
        last if $x =~ /^--/;
        if ($x =~ /^-(.+)$/) {
            my $c = $1;
            if ($c =~ /^[^$vl]*e$/) { push @pat, $q + 1; $q += 2; next }   # a cluster ending in -e: the next word
            last if $c =~ /[$vl]/;
            $q++; next;
        }
        push @pat, $q if $pos;
        last;
    }
    return grep { $_ < @$w && $w->[$_]{raw} !~ /[<>`\n]|\$\(/ && !is_redir($w->[$_]{text}) } @pat;
}

sub end_cmd {
    my $f = shift;
    end_word($f);
    my @w = @{ $f->{words} };
    if ($MODE eq 'patterns') {
        push @over, [ $w[$_]{s}, $w[$_]{e} ] for pattern_words(\@w);
    } else {
        # a value before the command word is one word to bash, whatever it holds (spaces, ; | &, newlines): make it
        # one word for the splitter and the tokenizer too, or its tail is taken for the command (FOO="a; b" npm publish)
        my %val = map { $_ => 1 } prefix_values(\@w);
        for my $sp (@{ $f->{spans} }) {
            push @value, [ $sp->{s} + 1, $sp->{e} ] if $val{ $sp->{w} } && !$sp->{sub};
        }
        my $from = data_from(\@w);
        if ($from >= 0) {
            my %redir;   # a redirection target is a path, never data: `echo x >> '.agent/a>b/../GOAL.md'`
            for my $q (0 .. $#w) {
                next unless is_redir($w[$q]{text});
                $redir{$q} = 1;
                $redir{ $q + 1 } = 1 if $w[$q]{text} =~ /^[0-9]*[<>&]+$/;
            }
            for my $sp (@{ $f->{spans} }) {
                next if $sp->{w} < $from || $sp->{sub} || $redir{ $sp->{w} };
                next if index(substr($s, $sp->{s}, $sp->{e} - $sp->{s}), "\n") >= 0;   # one line only
                push @blank, [ $sp->{s} + 1, $sp->{e} ];
            }
        }
    }
    $f->{words} = []; $f->{spans} = [];
}

sub skip_brace { # index of "${" -> index after its "}"; quotes or substitutions inside: unchanged
    my $j = $_[0] + 2;
    while ($j < $n) {
        my $c = substr($s, $j, 1);
        return $j + 1 if $c eq '}';
        unchanged() if $c eq "'" || $c eq '"' || $c eq '`' || $c eq '$' || $c eq '\\';
        $j++;
    }
    unchanged();
}

my @st = (new_frame(0));
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
    if ($c eq '\\') { wadd($top, substr($s, $i, 2)); $top->{plain} = 0; $i += 2; next }
    if ($c eq "'" || $c eq '"' || ($c eq '$' && $nx eq "'")) {
        my $q = $c eq '$' ? 'A' : $c eq "'" ? 'S' : 'D';
        my $start = $c eq '$' ? $i + 1 : $i;
        wadd($top, 'Q'); $top->{plain} = 0;
        push @st, { t => $q, s => $start, f => $top, w => scalar @{ $top->{words} }, sub => 0 };
        $i = $start + 1; next;
    }
    unchanged() if $c eq '`';
    if ($c eq '$' && $nx eq '(') { wadd($top, '$('); $top->{plain} = 0; push @st, new_frame(1); $i += 2; next }
    if ($c eq '$' && $nx eq '{') { my $e = skip_brace($i); wadd($top, substr($s, $i, $e - $i)); $top->{plain} = 0; $i = $e; next }
    if ($c eq '#' && $top->{cur} eq '') { my $e = index($s, "\n", $i); $i = $e < 0 ? $n : $e; next }
    if ($c eq '<' && $nx eq '<') {
        unchanged() if substr($s, $i + 2, 1) ne '<';   # a heredoc: its body is not shell
        wadd($top, '<<<'); $i += 3; next;
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
    wadd($top, $c); $i++;
}
unchanged() if @st != 1;   # an unterminated quote or $(
end_cmd($st[0]);
for my $b (@blank) {
    for my $p ($b->[0] .. $b->[1] - 1) {
        substr($s, $p, 1) = ' ' if index(';|&()<>', substr($s, $p, 1)) >= 0;
    }
}
for my $b (@value) {
    for my $p ($b->[0] .. $b->[1] - 1) {
        substr($s, $p, 1) = '_' if index(";|&()<> \t\n", substr($s, $p, 1)) >= 0;
    }
}
for my $b (@over) { substr($s, $b->[0], $b->[1] - $b->[0]) = '_' x ($b->[1] - $b->[0]) }
print $s;
