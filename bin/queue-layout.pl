#!/usr/bin/perl
# queue-layout.pl - the grid behind queue.sh tile. Reads records on stdin, one per line:
#   S x y w h name          a display: visible frame, top-left coordinates (queue-term.js screens)
#   M x y                   origin of the main display
#   W id x y w h ttys on    a Terminal window (queue-term.js windows); only windows with on=1 are laid out
#   P id x y w h            a window parked on the main display; x y w h is the frame it goes back to
# Prints one line per change:
#   move id x y w h         a window shown on its display that is off its cell (by more than TOLERANCE px)
#   park id x y w h         a parked window whose cell changed: the frame it will go back to
# The main display is never laid out: windows there keep their place and size. Every other display is a grid of
# the windows that live there, the parked ones included: a parked window keeps its cell, empty while it is away,
# so the grid only changes when a window is opened or closed. 1 fills the display, 2 side by side, 3 in three
# columns, 4 as 2x2, then ceil(sqrt(n)) columns, a shorter last row sharing the full width. Each window takes
# the free cell nearest to where it is now, so a window stays where you know it.
use strict;
use warnings;
use POSIX qw(ceil);

my $TOLERANCE = 20;   # Terminal rounds a frame to whole character cells; smaller differences are not moves
my (@screens, @members, $mx, $my);
while (my $line = <STDIN>) {
  my @f = split ' ', $line;
  next unless @f;
  if    ($f[0] eq 'S' && @f >= 5) { push @screens, [ @f[1 .. 4] ] }
  elsif ($f[0] eq 'M' && @f >= 3) { ($mx, $my) = @f[1, 2] }
  elsif ($f[0] eq 'P' && @f >= 6) { push @members, [ 'park', @f[1 .. 5] ] }
  elsif ($f[0] eq 'W' && @f >= 8 && $f[7] eq '1') { push @members, [ 'move', @f[1 .. 5] ] }
}

my %on;   # display index -> the windows that live there
for my $m (@members) {
  my (undef, $id, $x, $y, $w, $h) = @$m;
  my ($cx, $cy) = ($x + $w / 2, $y + $h / 2);
  for my $i (0 .. $#screens) {
    my ($sx, $sy, $sw, $sh) = @{ $screens[$i] };
    next unless $cx >= $sx && $cx < $sx + $sw && $cy >= $sy && $cy < $sy + $sh;
    push @{ $on{$i} }, $m unless defined $mx && $sx == $mx && $sy == $my;
    last;
  }
}

for my $i (sort { $a <=> $b } keys %on) {
  my ($sx, $sy, $sw, $sh) = @{ $screens[$i] };
  my $n = @{ $on{$i} };
  my $cols = $n <= 3 ? $n : $n == 4 ? 2 : ceil(sqrt($n));
  my $rows = ceil($n / $cols);
  my @cells;
  for my $k (0 .. $n - 1) {
    my ($r, $c) = (int($k / $cols), $k % $cols);
    my $inrow = $r == $rows - 1 ? $n - $cols * ($rows - 1) : $cols;
    my ($cw, $ch) = (int($sw / $inrow), int($sh / $rows));
    my ($x, $y) = ($sx + $c * $cw, $sy + $r * $ch);
    push @cells, [ $x, $y, $c == $inrow - 1 ? $sw - $c * $cw : $cw, $r == $rows - 1 ? $sh - $r * $ch : $ch ];
  }
  # each window takes the free cell nearest to where it is now, closest pairs first, so a grid that grows or
  # shrinks moves every window as little as it can (ties: lower window id, then the earlier cell)
  my $centre = sub { ($_[0] + $_[2] / 2, $_[1] + $_[3] / 2) };
  my @pairs;
  for my $m (0 .. $n - 1) {
    my ($mx_, $my_) = $centre->(@{ $on{$i}[$m] }[2 .. 5]);
    for my $c (0 .. $n - 1) {
      my ($cx, $cy) = $centre->(@{ $cells[$c] });
      push @pairs, [ ($mx_ - $cx) ** 2 + ($my_ - $cy) ** 2, $on{$i}[$m][1], $c, $m ];
    }
  }
  my (%taken_m, %taken_c, @assign);
  for my $p (sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] || $a->[2] <=> $b->[2] } @pairs) {
    next if $taken_m{ $p->[3] } || $taken_c{ $p->[2] };
    $taken_m{ $p->[3] } = $taken_c{ $p->[2] } = 1;
    push @assign, [ $p->[3], $p->[2] ];
  }
  for my $a_ (sort { $on{$i}[ $a->[0] ][1] <=> $on{$i}[ $b->[0] ][1] } @assign) {
    my ($x, $y, $w, $h) = @{ $cells[ $a_->[1] ] };
    my ($what, $id, $ox, $oy, $ow, $oh) = @{ $on{$i}[ $a_->[0] ] };
    next unless abs($ox - $x) > $TOLERANCE || abs($oy - $y) > $TOLERANCE || abs($ow - $w) > $TOLERANCE || abs($oh - $h) > $TOLERANCE;
    print "$what $id $x $y $w $h\n";
  }
}
