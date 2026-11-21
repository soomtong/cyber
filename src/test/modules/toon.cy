use json
use toon
use t 'test'

fn enc(src str) -> str:
    try:
        return toon.encode(json.parse(src)!)!
    else |err|:
        panic('encode failed: %{err}')

fn dec(src str) -> str:
    try:
        return json.stringify(toon.decode(src)!)
    else |err|:
        panic('decode failed: %{err}')

-- Objects, inline arrays and tables.
t.eq('id: 123\nname: Ada\nactive: true', enc('{"id": 123, "name": "Ada", "active": true}'))
t.eq('user:\n  id: 1\n  tags[2]: a,b\n  empty: []\n  none:', enc('{"user": {"id": 1, "tags": ["a", "b"], "empty": [], "none": {}}}'))
t.eq('items[2]{sku,qty,price}:\n  A1,2,9.99\n  B2,1,14.5', enc('{"items": [{"sku": "A1", "qty": 2, "price": 9.99}, {"sku": "B2", "qty": 1, "price": 14.5}]}'))
t.eq('orders[2]{id,customer{name,country}}:\n  1,Ada,DK\n  2,Bob,UK', enc('{"orders": [{"id": 1, "customer": {"name": "Ada", "country": "DK"}}, {"id": 2, "customer": {"country": "UK", "name": "Bob"}}]}'))

-- Keyed tables: objects whose values are uniform objects.
t.eq('env[2:]{region,replicas}:\n  prod: eu,6\n  dev: us,1', enc('{"env": {"prod": {"region": "eu", "replicas": 6}, "dev": {"region": "us", "replicas": 1}}}'))

-- List form for mixed arrays, objects as list items and arrays of arrays.
t.eq('items[3]:\n  - 1\n  - a: 1\n    b: 2\n  - text', enc('{"items": [1, {"a": 1, "b": 2}, "text"]}'))
t.eq('pairs[2]:\n  - [2]: 1,2\n  - [0]:', enc('{"pairs": [[1, 2], []]}'))
t.eq('items[1]:\n  - users[2]{id}:\n      1\n      2\n    status: ok', enc('{"items": [{"users": [{"id": 1}, {"id": 2}], "status": "ok"}]}'))

-- Root forms.
t.eq('[2]: 1,2', enc('[1, 2]'))
t.eq('[2]{a}:\n  1\n  2', enc('[{"a": 1}, {"a": 2}]'))
t.eq('[]', enc('[]'))
t.eq('', enc('{}'))
t.eq('hello', enc('"hello"'))
t.eq('null', enc('null'))

-- Quoting.
t.eq('[9]: "","true","42","-x","a:b"," s","#c","a,b",x y', enc('["", "true", "42", "-x", "a:b", " s", "#c", "a,b", "x y"]'))
t.eq('"my-key": 1\n"": 2\n"1a": 3', enc('{"my-key": 1, "": 2, "1a": 3}'))
t.eq('s: "a\\nb\\t\\"\\\\\\u0001"', enc('{"s": "a\\nb\\t\\"\\\\\\u0001"}'))

-- Numbers use the canonical form.
t.eq('[6]: 1,1.5,1000000,0,1e+21,1e-7', enc('[1.0, 1.50, 1e6, -0.0, 1e21, 1e-7]'))

-- Delimiters and indentation.
v := json.parse('{"t": [{"a": "x,y", "b": 1}], "p": ["a|b", "c"]}')!
t.eq('t[1|]{a|b}:\n  x,y|1\np[2|]: "a|b"|c', toon.encode(v, {delim=.pipe})!)
t.eq('t[1\t]{a\tb}:\n    x,y\t1\np[2\t]: a|b\tc', toon.encode(v, {delim=.tab, indent=4})!)

-- Decoding.
t.eq('{"id":123,"name":"Ada","active":true}', dec('id: 123\nname: Ada\nactive: true'))
t.eq('{"items":[{"sku":"A1","qty":2,"price":9.99},{"sku":"B2","qty":1,"price":14.5}]}', dec('items[2]{sku,qty,price}:\n  A1,2,9.99\n  B2,1,14.5'))
t.eq('{"env":{"prod":{"r":6},"dev":{"r":1}}}', dec('env[2:]{r}:\n  prod: 6\n  dev: 1'))
t.eq('{"a":["x",{"b":1,"c":2},[1,2],{}]}', dec('a[4]:\n  - x\n  - b: 1\n    c: 2\n  - [2]: 1,2\n  -'))
t.eq('{"n":[1,1.5,"05",1e400,-1000]}', dec('n[5]: 1,1.5000,05,1e400,-1E+03'))
t.eq('{"s":"a:b","k":"-x"}', dec('# comment\ns: "a:b"\n\nk: -x\n'))
t.eq('"hello"', dec('hello'))
t.eq('{}', dec(''))
t.eq('[]', dec('[]'))
t.eq('{"a":{"b":1}}', json.stringify(toon.decode('a:\n    b: 1', {indent=4}, &&json.Diag{})!))

-- Round trip.
src := '{"users":[{"id":1,"name":"Ada","tags":["a"]},{"id":2,"name":"Bob","tags":[]}],"meta":{"page":1,"next":null},"m":{"x":{"v":1.5},"y":{"v":-2}}}'
t.eq(src, toon.to_json(toon.from_json(src)!)!)

-- Errors.
var diag json.Diag = {}
fn fails(src str, opts toon.DecodeOptions, diag &&json.Diag) -> bool:
    _ = toon.decode(src, opts, diag) !else:
        return true
    return false

t.eq(true, fails('a[3]: 1,2', {}, &&diag))
t.eq('The header declares 3 values, found 2.', diag.msg)
t.eq(1, diag.line)
t.eq(false, fails('a[3]: 1,2', {strict=false}, &&diag))
t.eq(true, fails('a: 1\n   b: 2', {}, &&diag))
t.eq(2, diag.line)
t.eq(true, fails('a: 1\na: 2', {}, &&diag))
t.eq('Duplicate key `a`.', diag.msg)
t.eq(true, fails('t[2]{a,b}:\n  1,2\n  3', {}, &&diag))
t.eq(3, diag.line)
t.eq(true, fails('a: "x\\q"', {}, &&diag))
t.eq(true, fails('a[2]{x}', {}, &&diag) == false)
t.eq(true, fails('a\nb', {}, &&diag))
t.eq(true, fails('[1]: x\nb: 1', {}, &&diag))
t.eq(error.Unicode, toon.decode(str([]byte{0x61, 0x3a, 0x20, 0xff})).unwrap_error())
t.eq(error.Unicode, toon.encode(json.Value.str(str([]byte{0xff}))).unwrap_error())

-- A `number` encodes in canonical form, and `exact` keeps decoded numbers as text.
t.eq('[3]: 9223372036854775808,1e+999,0.1', enc('[9223372036854775808, 1e999, 0.1000000000000000055511151231257827]'))
t.eq('{"a":[1.50,2]}', json.stringify(toon.decode('a[2]: 1.50,2', toon.DecodeOptions{exact=true}, &&diag)!))

--cytest: pass
