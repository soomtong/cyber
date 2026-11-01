use v5.34;
use warnings;
use Time::HiRes qw(time);

sub fib {
    my ($n) = @_;
    return $n < 2 ? $n : fib($n - 1) + fib($n - 2);
}

my $start = time;
my $res = fib(30);
say 'time: ', (time - $start) * 1000;
say $res;
