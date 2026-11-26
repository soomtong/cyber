-- Prints the Fibonacci sequence up to the Nth number, up to `MaxCount` numbers.
-- The count comes from the command line, from a prompt at a terminal or from a pipe:
--   cyber examples/fibonacci_sequence.cy 10
--   cyber examples/fibonacci_sequence.cy
--   echo 10 | cyber examples/fibonacci_sequence.cy
use os

-- F(92) is the last Fibonacci number that fits in an `int`. One more and `+` panics with 'Integer overflow.'.
const MaxCount = 93

-- The first `n` Fibonacci numbers, 0 first. Each is the sum of the two before it.
fn fibonacci(n int) -> []int:
    var seq []int = {}
    for 0..n |i|:
        seq += if (i < 2) i else seq[i - 1] + seq[i - 2]
    return seq

-- The count in `text`, or `none` after saying what is wrong with it.
fn parse_count(text str) -> ?int:
    n := int.parse(text.trim()) !else:
        eprint('`%{text.trim()}` is not a whole number.')
        return none
    if n < 1 or n > MaxCount:
        eprint('Choose 1 to %{MaxCount} numbers.')
        return none
    return n

-- Asks until the answer is good at a terminal. From a pipe, the first line decides.
fn ask_count() -> !?int:
    while os.input('How many Fibonacci numbers (1 to %{MaxCount}): ')! |line|:
        if parse_count(line) |n|:
            return n
        if !os.stdin().is_terminal():
            return none
    return none

fn main() -> !void:
    args := os.args()
    count := if (args.len() > 1) parse_count(args[1]) else ask_count()!
    print(fibonacci(count ?else os.exit(1)).join(', '))
