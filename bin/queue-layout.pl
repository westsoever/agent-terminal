#!/usr/bin/perl
# queue-layout.pl - the grid behind queue.sh tile. Reads records on stdin, one per line:
#   S x y w h name          a display: visible frame, top-left coordinates (queue-term.js screens)
#   M x y                   origin of the main display
#   W id x y w h ttys on    a Terminal window (queue-term.js windows); only windows with on=1 are laid out
#   P id epoch              a window parked on the main display since epoch
#   F id                    a window whose real frame differs from the one given: printed whatever its target
# Prints "id x y w h" for each window that has to move (more than TOLERANCE px off its cell, or forced).
# Each display lays out the windows shown on it: 1 fills it, 2 side by side, 3 in three columns, 4 as 2x2,
# then ceil(sqrt(n)) columns, a shorter last row sharing the full width. Order: by window id (the order they
# were opened), and on the main display the parked windows after its own, oldest first. So a window keeps its
# place while others come and go.
use strict;
use warnings;
use POSIX qw(ceil);

my $TOLERANCE = 20;   # Terminal rounds a frame to whole character cells; smaller differences are not moves
my (@screens, %parked, %force, @windows, $mx, $my);
while (my $line = <STDIN>) {
  my @f = split ' ', $line;
  next unless @f;
  if    ($f[0] eq 'S' && @f >= 5) { push @screens, [ @f[1 .. 4] ] }
  elsif ($f[0] eq 'M' && @f >= 3) { ($mx, $my) = @f[1, 2] }
  elsif ($f[0] eq 'P' && @f >= 3) { $parked{ $f[1] } = $f[2] }
  elsif ($f[0] eq 'F' && @f >= 2) { $force{ $f[1] } = 1 }
  elsif ($f[0] eq 'W' && @f >= 8 && $f[7] eq '1') { push @windows, [ @f[1 .. 5] ] }
}

my %on;   # display index -> its windows
for my $w (@windows) {
  my ($id, $x, $y, $w_, $h) = @$w;
  my ($cx, $cy) = ($x + $w_ / 2, $y + $h / 2);
  for my $i (0 .. $#screens) {
    my ($sx, $sy, $sw, $sh) = @{ $screens[$i] };
    if ($cx >= $sx && $cx < $sx + $sw && $cy >= $sy && $cy < $sy + $sh) { push @{ $on{$i} }, $w; last }
  }
}

for my $i (sort { $a <=> $b } keys %on) {
  my ($sx, $sy, $sw, $sh) = @{ $screens[$i] };
  my $main = defined $mx && $sx == $mx && $sy == $my;
  my $key = sub { my $id = $_[0][0]; ($main && exists $parked{$id}) ? 1e10 + $parked{$id} : $id };
  my @list = sort { $key->($a) <=> $key->($b) } @{ $on{$i} };
  my $n = @list;
  my $cols = $n <= 3 ? $n : $n == 4 ? 2 : ceil(sqrt($n));
  my $rows = ceil($n / $cols);
  for my $k (0 .. $n - 1) {
    my ($r, $c) = (int($k / $cols), $k % $cols);
    my $inrow = $r == $rows - 1 ? $n - $cols * ($rows - 1) : $cols;
    my ($cw, $ch) = (int($sw / $inrow), int($sh / $rows));
    my ($x, $y) = ($sx + $c * $cw, $sy + $r * $ch);
    my $w = $c == $inrow - 1 ? $sw - $c * $cw : $cw;
    my $h = $r == $rows - 1 ? $sh - $r * $ch : $ch;
    my ($id, $ox, $oy, $ow, $oh) = @{ $list[$k] };
    next unless $force{$id} || abs($ox - $x) > $TOLERANCE || abs($oy - $y) > $TOLERANCE
      || abs($ow - $w) > $TOLERANCE || abs($oh - $h) > $TOLERANCE;
    print "$id $x $y $w $h\n";
  }
}
