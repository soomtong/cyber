-- Prints PI to the Nth decimal place, up to `MaxPlaces`.
-- The number comes from the command line, from a prompt at a terminal or from a pipe:
--   cyber examples/pi_digits.cy 50
--   cyber examples/pi_digits.cy
--   echo 50 | cyber examples/pi_digits.cy
use os

const MaxPlaces = 1000

-- The first `n` decimal digits of PI, 3 first, by the spigot of Rabinowitz and Wagon. PI is held as a number in a
-- mixed radix (1/3, 2/5, 3/7, ...) whose places all start at 2. Each pass multiplies it by 10 and carries one
-- decimal digit out of the front.
fn pi_digits(n int) -> []int:
    len := 10 * n / 3 + 1
    places := []int(len, 2)
    var digits []int = {}
    for 0..n:
        carry := 0
        for len..>0 |i|:
            x := 10 * places[i - 1] + carry * i
            places[i - 1] = x % (2 * i - 1)
            carry = x / (2 * i - 1)
        places[0] = carry % 10
        digits += carry / 10
    -- A pass can carry out 10: it adds one to the digits before it.
    for digits.len() - 1..>0 |i|:
        if digits[i] >= 10:
            digits[i] -= 10
            digits[i - 1] += 1
    return digits

-- PI with `places` decimal places, cut off (not rounded).
fn pi_text(places int) -> str:
    -- A later carry can still change the last digits, so a few more are made than are shown.
    digits := pi_digits(places + 4)
    if places == 0:
        return '3'
    return '3.%{digits[1..places + 1].join('')}'

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
    while os.input('Decimal places of PI (0 to %{MaxPlaces}): ')! |line|:
        if parse_places(line) |n|:
            return n
        if !os.stdin().is_terminal():
            return none
    return none

fn main() -> !void:
    args := os.args()
    places := if (args.len() > 1) parse_places(args[1]) else ask_places()!
    print(pi_text(places ?else os.exit(1)))
