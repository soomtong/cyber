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
fn fails(src str, diag &json.Diag) -> bool:
    _ = json.parse(src, diag) !else:
        return true
    return false

t.eq(true, fails('[1,', &diag))
t.eq('Expected a value, found the end of input.', diag.msg)
t.eq(true, fails('{\n  "a": tru\n}', &diag))
t.eq(2, diag.line)
t.eq(8, diag.col)
t.eq(true, fails('01', &diag))
t.eq('A number can not have a leading zero.', diag.msg)
t.eq(true, fails('[1] x', &diag))
t.eq('Expected the end of input after the value, found `x`.', diag.msg)
t.eq(true, fails('"\\ud800"', &diag))
t.eq(true, fails('"\\udc00"', &diag))
t.eq(true, fails('"a\tb"', &diag))
t.eq(true, fails('{"a" 1}', &diag))
t.eq(true, fails('{a: 1}', &diag))
t.eq(true, fails('[1,]', &diag))
t.eq(true, fails('1.', &diag))
t.eq(true, fails('-', &diag))
t.eq(true, fails('1e999', &diag))
t.eq(true, fails('"\\x"', &diag))
t.eq(true, fails('', &diag))
t.eq(true, fails('['.repeat(300), &diag))
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

--cytest: pass
