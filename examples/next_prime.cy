-- Prints prime numbers one at a time, until you stop asking for the next one.
-- At a terminal, Enter asks for the next prime and `q` stops. From a pipe, each line asks for one more.
-- A count on the command line prints that many primes without asking:
--   cyber examples/next_prime.cy
--   printf '\n\n\n' | cyber examples/next_prime.cy
--   cyber examples/next_prime.cy 10
use os

-- The 100,000th prime is 1,299,709. Each new prime is tested by the primes up to its square root.
const MaxCount = 100_000

-- The primes in order: 2, 3, 5, 7, 11, ... A number is prime when no smaller prime up to its square root divides it,
-- so the generator keeps the primes it found and tries only odd numbers after 2.
generator fn primes() -> int:
    yield 2
    var odd_primes []int = {}
    n := 3
    while:
        if !has_divisor(n, odd_primes):
            odd_primes += n
            yield n
        n += 2

-- Whether a prime in `primes`, which are in order, divides the odd number `n`. The primes above the square root of
-- `n` are not tried: if one of them divided `n`, so would a smaller one.
fn has_divisor(n int, primes []int) -> bool:
    for primes |p|:
        if p > n / p:
            return false
        if n % p == 0:
            return true
    return false

-- The count in `text`, or `none` after saying what is wrong with it.
fn parse_count(text str) -> ?int:
    n := int.parse(text.trim()) !else:
        eprint('`%{text.trim()}` is not a whole number.')
        return none
    if n < 1 or n > MaxCount:
        eprint('Choose 1 to %{MaxCount.fmt(.dec, {sep=','})} primes.')
        return none
    return n

-- Prints the primes and asks after each one. An answer that starts with `q` or the end of the input stops.
fn ask_each() -> !void:
    for primes() |p|:
        print(p)
        answer := os.input('Next? (Enter, or q to stop) ')! ?else return
        if answer.trim().starts_with('q'):
            return

fn main() -> !void:
    args := os.args()
    if args.len() <= 1:
        return ask_each()
    count := parse_count(args[1]) ?else os.exit(1)
    gen := primes()
    for 0..count:
        print(gen.next().?)
