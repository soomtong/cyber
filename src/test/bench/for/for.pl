use v5.34;
use warnings;
use Time::HiRes qw(time);

my $start = time;

my @list;
for my $i (0 .. 999_999) {
    push @list, $i;
}

my $sum = 0;
for my $i (@list) {
    $sum += $i;
}

say 'time: ', (time - $start) * 1000;
say $sum;
