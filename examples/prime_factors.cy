-- Prints the prime factors of a whole number from 1 to `MaxNumber`.
-- The number comes from the command line, from a prompt at a terminal or from a pipe:
--   cyber examples/prime_factors.cy 360
--   cyber examples/prime_factors.cy
--   echo 360 | cyber examples/prime_factors.cy
use os

-- Trial division tries the divisors up to the square root, about 500,000 of them for the largest number.
const MaxNumber = 1_000_000_000_000

-- `n` with its digits in groups of three: 1,000,000.
fn grouped(n int) -> str:
    return n.fmt(.dec, {sep=','})

-- A prime that divides a number `power` times.
type Factor:
    prime int
    power int

-- The prime factors of `n`, smallest first, by trial division. Each prime is divided out as often as it goes, so a
-- later divisor that divides what is left is a prime. Above the square root of the rest, only the rest itself can.
fn prime_factors(n int) -> []Factor:
    var factors []Factor = {}
    rest := n
    d := 2
    while d <= rest / d:
        power := 0
        while rest % d == 0:
            rest /= d
            power += 1
        if power > 0:
            factors += Factor{prime=d, power=power}
        d += if (d == 2) 1 else 2
    if rest > 1:
        factors += Factor{prime=rest, power=1}
    return factors

-- `factors` as a product of powers: 2^3 × 3^2 × 5.
fn product_text(factors []Factor) -> str:
    var terms []str = {}
    for factors |f|:
        terms += if (f.power == 1) '%{f.prime}' else '%{f.prime}^%{f.power}'
    return terms.join(' × ')

-- The number in `text`, or `none` after saying what is wrong with it.
fn parse_number(text str) -> ?int:
    n := int.parse(text.trim()) !else:
        eprint('`%{text.trim()}` is not a whole number.')
        return none
    if n < 1 or n > MaxNumber:
        eprint('Choose a number from 1 to %{grouped(MaxNumber)}.')
        return none
    return n

-- Asks until the answer is good at a terminal. From a pipe, the first line decides.
fn ask_number() -> !?int:
    while os.input('Number to factor (1 to %{grouped(MaxNumber)}): ')! |line|:
        if parse_number(line) |n|:
            return n
        if !os.stdin().is_terminal():
            return none
    return none

fn main() -> !void:
    args := os.args()
    n := (if (args.len() > 1) parse_number(args[1]) else ask_number()!) ?else os.exit(1)
    factors := prime_factors(n)
    if factors.len() == 0:
        print('1 has no prime factors.')
    else factors.len() == 1 and factors[0].power == 1:
        print('%{n} is prime.')
    else:
        print('%{n} = %{product_text(factors)}')
