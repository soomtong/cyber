-- Prints what the tile for a floor costs, from the floor's width and length in meters and the price of a square
-- meter of tile. The numbers come from the command line, from prompts at a terminal or from three lines of a pipe:
--   cyber examples/tile_cost.cy 4.5 3.2 12.99
--   cyber examples/tile_cost.cy
--   printf '4.5\n3.2\n12.99\n' | cyber examples/tile_cost.cy
use os

-- The longest side, 10 km, and the highest price keep the cost well inside the digits of a float.
const MaxSide  = 10_000.0
const MaxPrice = 1_000_000.0

-- `x` rounded to cents with the digits in groups of three: 1,234.50.
fn money(x float) -> str:
    return x.fmt({places=2, sep=','})

-- A number that the program asks for.
type Field:
    name str
    max  float

const Fields = [3]Field{
    {name='Width (m)', max=MaxSide},
    {name='Length (m)', max=MaxSide},
    {name='Price per m²', max=MaxPrice},
}

-- The number in `text` for `field`, or `none` after saying what is wrong with it.
fn parse_field(field Field, text str) -> ?float:
    x := float.parse(text.trim()) !else:
        eprint('`%{text.trim()}` is not a number.')
        return none
    -- Written so that NaN, which is neither above 0 nor at most the limit, is turned away too.
    if !(x > 0 and x <= field.max):
        eprint('%{field.name} must be above 0 and at most %{field.max.fmt({places=0, sep=','})}.')
        return none
    return x

-- Asks until the answer is good at a terminal. From a pipe, the next line decides.
fn ask(field Field) -> !?float:
    while os.input('%{field.name}: ')! |line|:
        if parse_field(field, line) |x|:
            return x
        if !os.stdin().is_terminal():
            return none
    return none

-- The width, the length and the price, from `texts` or from the input when `texts` is empty.
fn read_numbers(texts []str) -> !?[]float:
    if texts.len() > 0 and texts.len() != Fields.len():
        eprint('Give the width, the length and the price, or nothing to be asked for them.')
        return none
    var numbers []float = {}
    for Fields |i, field|:
        x := (if (texts.len() > 0) parse_field(field, texts[i]) else ask(field)!) ?else return none
        numbers += x
    return numbers

fn main() -> !void:
    numbers := read_numbers(os.args()[1..])! ?else os.exit(1)
    width, length, price := numbers[0], numbers[1], numbers[2]
    area := width * length
    print('Area: %{area.fmt({places=2, sep=','})} m²')
    print('Cost: %{money(area * price)}')
