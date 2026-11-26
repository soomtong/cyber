-- Prints e to the Nth decimal place, up to `MaxPlaces`.
-- The number comes from the command line, from a prompt at a terminal or from a pipe:
--   cyber examples/e_digits.cy 50
--   cyber examples/e_digits.cy
--   echo 50 | cyber examples/e_digits.cy
use os

const MaxPlaces = 1000

-- The first `n` decimal digits of e - 2, by Sale's spigot. e - 2 = 1/2! + 1/3! + ... is the number 0.111... in the
-- mixed radix 1/2, 1/3, 1/4, ...: every term starts at 1. Each pass multiplies it by 10 and carries one decimal digit
-- out of the front. The last of `n + 10` terms weighs 1/(n + 11)!, far below the digits that are kept.
fn e_digits(n int) -> []int:
    len := n + 10
    terms := []int(len, 1)
    var digits []int = {}
    for 0..n:
        carry := 0
        for len..>0 |i|:
            x := 10 * terms[i - 1] + carry
            terms[i - 1] = x % (i + 1)
            carry = x / (i + 1)
        digits += carry
    return digits

-- e with `places` decimal places, cut off (not rounded).
fn e_text(places int) -> str:
    if places == 0:
        return '2'
    return '2.%{e_digits(places).join('')}'

-- The number of decimal places in `text`, or `none` after saying what is wrong with it.
fn parse_places(text str) -> ?int:
    n := int.parse(text.trim()) !else:
        eprint('`%{text.trim()}` is not a whole number.')
        return none
    if n < 0 or n > MaxPlaces:
        eprint('Choose 0 to %{MaxPlaces} decimal places.')
        return none
    return n

-- Asks until the answer is good at a terminal. From a pipe, the first line decides.
fn ask_places() -> !?int:
    while os.input('Decimal places of e (0 to %{MaxPlaces}): ')! |line|:
        if parse_places(line) |n|:
            return n
        if !os.stdin().is_terminal():
            return none
    return none

fn main() -> !void:
    args := os.args()
    places := if (args.len() > 1) parse_places(args[1]) else ask_places()!
    print(e_text(places ?else os.exit(1)))
