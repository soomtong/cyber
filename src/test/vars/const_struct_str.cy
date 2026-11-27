use test

-- A const struct or fixed array may hold strings. It is expanded at each use, so a copy is its own value.
type Field:
    name str
    max  float

const Width = Field{name='Width', max=10.0}
test.eq(Width.name, 'Width')
test.eq(Width.max, 10.0)

const Fields = [3]Field{
    {name='Width', max=10.0},
    {name='Length', max=10.0},
    {name='Price', max=100.0},
}
test.eq(Fields.len(), 3)
var names []str = {}
for Fields |f|:
    names += f.name
test.eq(names.join(','), 'Width,Length,Price')

copy := Fields
copy[0].name = 'changed'
test.eq(copy[0].name, 'changed')
test.eq(Fields[0].name, 'Width')

-- With a type specifier.
const S str = 'abc'
test.eq(S, 'abc')
const Words [2]str = {'a', 'bb'}
test.eq(Words[1], 'bb')
const Nums [2]int = {1, 2}
test.eq(Nums[0] + Nums[1], 3)

-- Used from a function.
fn last_name() -> str:
    return Fields[2].name
test.eq(last_name(), 'Price')

--cytest: pass
