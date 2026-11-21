use json
use t 'test'

-- Parse and stringify.
v := json.parse(' {"name": "Ada", "n": [1, -2.5, true, null], "o": {}, "e": []} ')!
t.eq('Ada', v['name'].as_str().?)
t.eq(4, v['n'].len())
t.eq(1, v['n'][0].as_int().?)
t.eq(-2.5, v['n'][1].as_float().?)
t.eq(true, v['n'][2].as_bool().?)
t.eq(true, v['n'][3].is_null())
t.eq(true, v['missing'].is_null())
t.eq(true, v['n'][9].is_null())
t.eq(true, v['name'][0].is_null())
t.eq(true, (v.get('missing') ?else json.Value.int(7)).eq(json.Value.int(7)))
t.eq(true, (v['n'].at(4) ?else json.Value.int(7)).eq(json.Value.int(7)))
t.eq(true, v.eq(json.parse('{"e": [], "o": {}, "n": [1.0, -2.5, true, null], "name": "Ada"}')!))
t.eq(false, v.eq(json.parse('{"e": [], "o": {}, "n": [1, -2.5, true], "name": "Ada"}')!))
t.eq(false, json.Value.int(1).eq(json.Value.str('1')))
t.eq('object', v.kind())
t.eq('array', v['n'].kind())
t.eq('number', v['n'][1].kind())
t.eq('{"name":"Ada","n":[1,-2.5,true,null],"o":{},"e":[]}', json.stringify(v))
t.eq('{\n  "a": [\n    1,\n    {}\n  ],\n  "b": []\n}', json.stringify(json.parse('{"a":[1,{}],"b":[]}')!, 2))

-- Key order is kept. A duplicate key keeps its first position and takes the last value.
t.eq('{"b":3,"a":2}', json.stringify(json.parse('{"b":1,"a":2,"b":3}')!))
-- Past 16 keys, duplicates are found through a map.
big := json.parse('{"k0":0,"k1":1,"k2":2,"k3":3,"k4":4,"k5":5,"k6":6,"k7":7,"k8":8,"k9":9,"k10":10,"k11":11,"k12":12,"k13":13,"k14":14,"k15":15,"k16":16,"k17":17,"k3":33,"k17":77}')!
t.eq(18, big.len())
t.eq(33, big['k3'].as_int().?)
t.eq(77, big['k17'].as_int().?)

-- Numbers: integers that fit `int` stay `int`.
t.eq(9223372036854775807, json.parse('9223372036854775807')!.as_int().?)
t.eq(-9223372036854775807 - 1, json.parse('-9223372036854775808')!.as_int().?)
t.eq(-1, json.parse('9223372036854775808')!.as_int() ?else -1)
t.eq(9223372036854775808.0, json.parse('9223372036854775808')!.as_float().?)
t.eq('[1,1.5,100,0,1e+21,1e-7,0.000001,-3.25,1.5e+300]', json.stringify(json.parse('[1, 1.50, 1e2, -0, 1e21, 1e-7, 1e-6, -3.25, 1.5e300]')!))
t.eq('null', json.stringify(json.Value.float(0.0 / 0.0)))
t.eq('0.30000000000000004', json.fmt_float(0.1 + 0.2))

-- Strings and escapes.
s := json.parse('"a\\"b\\\\c\\/d\\n\\t\\u00e9\\ud83d\\ude00\\u0001"')!.as_str().?
t.eq('a"b\\c/d\n\té😀\x01', s)
t.eq('"a\\"b\\\\c/d\\n\\té😀\\u0001"', json.stringify(json.Value.str(s)))

-- Errors.
var diag json.Diag = {}
fn fails(src str, diag &&json.Diag) -> bool:
    _ = json.parse(src, diag) !else:
        return true
    return false

t.eq(true, fails('[1,', &&diag))
t.eq('Expected a value, found the end of input.', diag.msg)
t.eq(true, fails('{\n  "a": tru\n}', &&diag))
t.eq(2, diag.line)
t.eq(8, diag.col)
t.eq(true, fails('01', &&diag))
t.eq('A number can not have a leading zero.', diag.msg)
t.eq(true, fails('[1] x', &&diag))
t.eq('Expected the end of input after the value, found `x`.', diag.msg)
t.eq(true, fails('"\\ud800"', &&diag))
t.eq(true, fails('"\\udc00"', &&diag))
t.eq(true, fails('"a\tb"', &&diag))
t.eq(true, fails('{"a" 1}', &&diag))
t.eq(true, fails('{a: 1}', &&diag))
t.eq(true, fails('[1,]', &&diag))
t.eq(true, fails('1.', &&diag))
t.eq(true, fails('-', &&diag))
t.eq(true, fails('"\\x"', &&diag))
t.eq(true, fails('', &&diag))
t.eq(true, fails('['.repeat(300), &&diag))
t.eq('Arrays and objects nest deeper than 256 levels.', diag.msg)
t.eq(error.Unicode, json.parse(str([]byte{0x22, 0xff, 0x22})).unwrap_error())
t.eq(error.Syntax, json.parse('nul').unwrap_error())

-- Build values.
var obj json.Object = {}
obj.set('x', json.Value.int(1))
obj.set('y', json.array({json.Value.str('a'), json.Value.null}))
obj.set('x', json.Value.bool(false))
t.eq(true, obj.contains('y'))
t.eq(true, obj.remove('y'))
t.eq(false, obj.remove('y'))
t.eq('{"x":false}', json.stringify(json.Value.object(obj)))
t.eq('{"k":"v"}', json.stringify(json.object({{key='k', value=json.Value.str('v')}})))

-- Convert Cyber values.
type Color enum:
    case red
    case green

type Shape enum:
    case circle float
    case point

type User:
    id    int
    name  str
    tags  []str
    score ?float
    color Color
    shape Shape
    b     byte

u := User{id=1, name='Ada', tags={'a', 'b'}, score=none, color=.green, shape=Shape.circle(2.5), b=7}
t.eq('{"id":1,"name":"Ada","tags":["a","b"],"score":null,"color":"green","shape":{"circle":2.5},"b":7}', json.encode(u))
t.eq('"point"', json.encode(Shape.point))
var m Map[str, int] = {b=2, a=1}
t.eq('{"a":1,"b":2}', json.encode(&m))
t.eq('[1,2]', json.encode([]int{1, 2}))

-- `to` and `decode`: the reverse of `from`.
back := json.decode(User, json.encode(u))!
t.eq(1, back.id)
t.eq('Ada', back.name)
t.eq(2, back.tags.len())
t.eq('b', back.tags[1])
t.eq(true, back.score == none)
t.eq(Color.green, back.color)
t.eq(2.5, back.shape.!circle)
t.eq(7, back.b)
t.eq(json.encode(u), json.encode(back))

type Item:
    name  str
    qty   i32
    note  ?str
    sizes []Size

type Size:
    w int
    h int

-- A missing optional field is `none`, members that are not fields are ignored, a whole float converts to an integer.
item := json.decode(Item, '{"name": "pen", "qty": 3e2, "extra": [1], "sizes": [{"w": 1, "h": 2}]}')!
t.eq('pen', item.name)
t.eq(300, item.qty)
t.eq(true, item.note == none)
t.eq(2, item.sizes[0].h)
t.eq(1.0, json.to(float, json.Value.int(1))!)
t.eq(true, json.to(?str, json.Value.null)! == none)
t.eq('x', json.to(?str, json.Value.str('x'))!.?)
t.eq('"point"', json.encode(json.to(Shape, json.Value.str('point'))!))
t.eq(true, json.to(json.Value, json.Value.int(5))!.eq(json.Value.int(5)))
mm := json.decode(Map[str, []int], '{"a": [1, 2], "b": []}')!
t.eq(2, mm['a'][1])
t.eq(0, mm['b'].len())

-- Failures say where and why. A struct that fails part way releases the fields it has made.
fn to_fails(src str, err error, path str, msg str):
    var diag json.Diag = {}
    _ = json.decode(Item, src, &&diag) !else |e|:
        t.eq(err, e)
        t.eq(path, diag.path)
        t.eq(msg, diag.msg)
        return
    t.fail()

to_fails('{"qty": 1}', error.MissingField, '$', 'Missing the field `name`.')
to_fails('[]', error.Type, '$', 'Expected an object, found array.')
to_fails('{"name": "a", "qty": 1.5}', error.Type, '$.qty', 'Expected an integer, found `1.5`.')
to_fails('{"name": "a", "qty": 3000000000}', error.Overflow, '$.qty', 'The number `3000000000` does not fit `i32`.')
to_fails('{"name": "a", "qty": 1e300}', error.Overflow, '$.qty', 'The number `1e+300` does not fit `int`.')
to_fails('{"name": "a", "qty": 1, "note": true}', error.Type, '$.note', 'Expected a string, found bool.')
to_fails('{"name": "a", "qty": 1, "note": "n", "sizes": [{"w": 1, "h": 2}, {"w": 1}]}', error.MissingField,
    '$.sizes[1]', 'Missing the field `h`.')
to_fails('{"name": "a", "qty": 1, "sizes": [{"w": 1, "h": true}]}', error.Type, '$.sizes[0].h', 'Expected an integer, found bool.')
to_fails('{"name": "a"', error.Syntax, '', 'Expected `,` or `}` in an object, found the end of input.')

fn to_fails_v(v json.Value) -> str:
    var diag json.Diag = {}
    _ = json.to(Map[str, Shape], v, &&diag) !else |e|:
        return '%{e} %{diag.path} %{diag.msg}'
    return 'ok'

t.eq('error.Type $["a b"] `square` is not a case of `Shape` without a payload.', to_fails_v(json.parse('{"a b": "square"}')!))
t.eq('error.Type $.a.circle Expected a number, found string.', to_fails_v(json.parse('{"a": {"circle": "x"}}')!))
t.eq('error.Type $.a Expected an object with one member for `Shape`, found 2 members.', to_fails_v(json.parse('{"a": {"circle": 1, "point": 2}}')!))
t.eq('error.Type $.a Expected a string or an object, found number.', to_fails_v(json.parse('{"a": 1}')!))
t.eq('ok', to_fails_v(json.parse('{"a": {"circle": 1}, "b": "point"}')!))

-- Numbers that `int` or `float` can not hold are kept as `Value.number` text.
nums := json.parse('[9223372036854775807, 9223372036854775808, -9223372036854775809, 12345678901234567890123, 1e999, 0.1000000000000000055511151231257827]')!
t.eq('[9223372036854775807,9223372036854775808,-9223372036854775809,12345678901234567890123,1e999,0.1]', json.stringify(nums))
t.eq(9223372036854775807, nums[0].as_int().?)
t.eq('9223372036854775808', nums[1].number_text().?)
t.eq(true, nums[1].as_int() == none)
t.eq(9223372036854775808.0, nums[1].as_float().?)
t.eq(true, nums[4].as_float() == none)
t.eq('number', nums[4].kind())
t.eq('1.2345678901234567890123e+22', nums[3].number_text().?)
-- `exact` keeps every number with a fraction or an exponent.
ex := json.parse('[0.1000000000000000055511151231257827, 1.50, 1e2, -0.0, 1E-7, 123.456e5, 7]', json.ParseOptions{exact=true})!
t.eq('[0.1000000000000000055511151231257827,1.50,1e2,-0.0,1E-7,123.456e5,7]', json.stringify(ex))
t.eq(7, ex[6].as_int().?)
t.eq('1.5', ex[1].number_text().?)
t.eq('100', ex[2].number_text().?)
t.eq('0', ex[3].number_text().?)
t.eq('1e-7', ex[4].number_text().?)
t.eq('12345600', ex[5].number_text().?)
t.eq(1.5, ex[1].as_float().?)
var exdiag json.Diag = {}
t.eq(true, (json.parse('[1.0', json.ParseOptions{exact=true}, &&exdiag) !else json.Value.null).is_null())
t.eq('Expected `,` or `]` in an array, found the end of input.', exdiag.msg)
-- `fmt_number` writes any number token in the form of `fmt_float`.
t.eq('0', json.fmt_number('-0'))
t.eq('100', json.fmt_number('100.000'))
t.eq('0.000001', json.fmt_number('1e-6'))
t.eq('1e+21', json.fmt_number('1000000000000000000000'))
t.eq('-1.5e-7', json.fmt_number('-0.00000015'))
t.eq('123456789012345678901', json.fmt_number('1.23456789012345678901e20'))
t.eq('1e99999999999999999999', json.fmt_number('1e99999999999999999999'))
-- A `number` equals another number of the same value.
t.eq(true, json.Value.number('1e2').eq(json.Value.int(100)))
t.eq(true, json.Value.int(100).eq(json.Value.number('100.0')))
t.eq(true, json.Value.number('0.1').eq(json.Value.float(0.1)))
t.eq(false, json.Value.number('0.10000000000000000555').eq(json.Value.float(0.1)))
t.eq(false, json.Value.number('1').eq(json.Value.str('1')))
t.eq(true, nums.eq(json.parse(json.stringify(nums))!))
-- `to` reads a `number`: `str` takes the text of any number, integers and floats when the value fits.
t.eq('9223372036854775808', json.to(str, nums[1])!)
t.eq('42', json.to(str, json.Value.int(42))!)
t.eq('1.5', json.to(str, json.Value.float(1.5))!)
t.eq(9223372036854775808.0, json.to(float, nums[1])!)
t.eq(300, json.to(int, json.Value.number('3.0e2'))!)
t.eq(error.Overflow, json.to(int, nums[1]).unwrap_error())
t.eq(error.Overflow, json.to(int, json.Value.number('1.5e30')).unwrap_error())
t.eq(error.Type, json.to(int, json.Value.number('1.5')).unwrap_error())
t.eq(error.Type, json.to(int, json.Value.number('1e-7')).unwrap_error())
t.eq(error.Type, json.to(int, json.Value.number('1E-99999999999999999999')).unwrap_error())
t.eq(error.Overflow, json.to(int, json.Value.number('1E+99999999999999999999')).unwrap_error())
-- An `r64` from 2^63 does not fit `int` and is kept as number text.
r64_max := r64.ones
t.eq('18446744073709551615', json.encode(r64_max))
t.eq('7', json.encode(r64(7)))
t.eq(r64_max, json.to(r64, json.from(r64_max))!)
t.eq(r64(9223372036854775807) + r64(1), json.to(r64, json.parse('9223372036854775808')!)!)
t.eq(r64(5), json.to(r64, json.parse('5')!)!)
t.eq(error.Overflow, json.to(r64, json.parse('18446744073709551616')!).unwrap_error())
t.eq(error.Overflow, json.to(r64, json.parse('-1')!).unwrap_error())
t.eq(error.Overflow, json.to(float, nums[4]).unwrap_error())
t.eq(error.Type, json.to(str, json.Value.bool(true)).unwrap_error())

--cytest: pass
