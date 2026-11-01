use v5.34;
use warnings;
use Time::HiRes qw(time);

my $str = ('abcdefghijklmnopqrstuvwxyz123456' x 1_000_000) . 'waldo';

my $start = time;
my $idx = 0;
for (1 .. 50) {
    $idx = index($str, 'waldo');
}

say 'time: ', (time - $start) * 1000;
say $idx;
