use v5.34;
use warnings;
use Time::HiRes qw(time);

# Same as index.pl but the needle starts with a byte that never appears in the haystack.
my $str = ('abcdefghijklmnopqrstuvwxyz123456' x 1_000_000) . 'Waldo';

my $start = time;
my $idx = 0;
for (1 .. 50) {
    $idx = index($str, 'Waldo');
}

say 'time: ', (time - $start) * 1000;
say $idx;
