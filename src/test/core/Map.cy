use t 'test'

-- Empty map.
a := Map[str, int]{}
t.eq(0, a.size())

-- Ignores last comma for multiline initializer.
a = {
    foo = 123,
    bar = 234,
}
-- Get size.
t.eq(2, a.size())

-- String literal in initializer.
a = {
    'c' = 234
}
t.eq(a['c'], 234)

-- Str keys.
a = {}
a['abc'] = 123
t.eq(123, a['abc'])

-- int key.
int_key_m := Map[int, int]{}
int_key_m[32] = 1
t.eq(1, int_key_m[32])
int_key_m[0xff] = 3
t.eq(3, int_key_m[0xff])

-- float key.
float_key_m := Map[float, int]{}
float_key_m[1.02] = 2
t.eq(2, float_key_m[1.02])

-- Indexing ident key.
a = {
    b = 32
}
t.eq(a['b'], 32)

-- Nested `Map`.
b := Map[str, ^Map[str,int]]{}
b['a'] = ^Map[str, int]{b=5}
t.eq(5, b['a']['b'])

-- Nested `Array`.
c := Map[str, ^Array[int]]{
    b = ^{1, 2}
}
t.eq(2, c['b'][1])

-- Nested `^ArrayStore`.
d := Map[str, ^ArrayStore[int]]{
    b = ^{1, 2}
}
t.eq(2, d['b'][1])
d['b'] = ^{}
t.eq(0, d['b'].len())

-- str value.
str_val_m := Map[str, str]{
    b = 'hello'
}
t.eq('hello', str_val_m['b'])

-- Iterator.
m := Map[str, int]{a=2, b=3, c=4}
sum := 0
codeSum := 0
for m |entry|:
    sum += entry.value
    codeSum += int(entry.key[0])
t.eq(9, sum)

-- Nested iteration.
m = {a=1, b=2, c=3}
res := 0
codeSum = 0
for m |e1|:
    innerSum := 0
    for m |e2|:
        innerSum += e2.value
        codeSum += int(e2.key[0])
    res += innerSum * e1.value
    codeSum += int(e1.key[0])
t.eq(36, res)
t.eq(294*4, codeSum)

-- Iterate rc values.
span_m := Map[str, ^int]{a=^2, b=^3, c=^4}
sum = 0
codeSum = 0
for span_m |e|:
    sum += e.value.*
    codeSum += int(e.key[0])
t.eq(9, sum)
t.eq(294, codeSum)

-- Remove from map.
m = {a=2, b=3, c=4}
t.eq(m.get('a').?, 2)
m.remove('a')
t.eq(m.size(), 2)
t.assert(m.get('a') == none)
t.eq(m['b'], 3)
t.eq(m['c'], 4)

-- Remove rc key from map.
m = {}
t.eq(m.size(), 0)
m[str(1)] = 123
m.remove('1')
t.eq(m.size(), 0)

-- contains()
m = {a=123}
t.eq(m.contains('a'), true)
t.eq(m.contains('b'), false)

-- get()
m = {a=123}
t.eq(m.get('a').?, 123)
t.assert(m.get('b') == none)

-- Force rehash.
type S:
    a str
    b int
m2 := Map[str, S]{}
for 0..10 |i|:
    m2[str(i)] = S{a=str(i), b=i}
for 0..10 |i|:
    t.eq(str(i), m2[str(i)].a)
    t.eq(i, m2[str(i)].b)

-- Replacing a value keeps the size and does not use up vacant slots.
m3 := Map[str, int]{}
for 0..100 |i|:
    m3['a'] = i
t.eq(1, m3.size())
t.eq(99, m3['a'])

-- Reusing a tombstone slot.
m4 := Map[int, int]{}
for 0..100 |i|:
    m4[i] = i
    m4[i + 1] = i
    m4.remove(i)
t.eq(1, m4.size())
t.eq(99, m4[100])

-- Growing moves managed keys and values, and drops tombstones.
type Box:
    s str
    n int
m5 := Map[str, Box]{}
for 0..300 |i|:
    m5['k%{i}'] = Box{s='v%{i}', n=i}
    if i % 3 == 0:
        m5.remove('k%{i}')
t.eq(200, m5.size())
for 0..300 |i|:
    if i % 3 == 0:
        t.eq(false, m5.contains('k%{i}'))
    else:
        t.eq('v%{i}', m5['k%{i}'].s)
cnt := 0
for m5 |e|:
    t.eq('k%{e.value.n}', e.key)
    cnt += 1
t.eq(200, cnt)

-- keys()
km := Map[str, int]{a=1, b=2, c=3}
keys := km.keys()
t.eq(3, keys.len())
t.eq(true, keys.contains('a'))
t.eq(true, keys.contains('b'))
t.eq(true, keys.contains('c'))
t.eq(false, keys.contains('d'))
km_int := Map[int, str]{}
t.eq(0, km_int.keys().len())
km_int[7] = 'x'
t.eq(0, km_int.keys().index(7).?)

-- Narrow int keys. A wrapped key is the same key as its wrapped value.
m_i8 := Map[i8, int]{}
m_i8[i8(-56)] = 1
m_i8[i8(100) + i8(100)] = 2
t.eq(1, m_i8.size())
t.eq(2, m_i8[i8(-56)])
t.eq(true, m_i8.contains(i8(100) + i8(100)))
t.eq(false, m_i8.contains(i8(56)))
m_i16 := Map[i16, int]{}
m_i16[i16(-3)] = 3
t.eq(3, m_i16[i16(-3)])
m_i32 := Map[i32, int]{}
m_i32[i32.max + i32(1)] = 4
t.eq(4, m_i32[i32.min])

-- Raw int keys.
m_byte := Map[byte, int]{}
m_byte[byte(44)] = 1
m_byte[byte(200) + byte(100)] = 2
t.eq(1, m_byte.size())
t.eq(2, m_byte[byte(44)])
m_r16 := Map[r16, int]{}
m_r16[r16(0xffff)] = 5
t.eq(5, m_r16[~r16(0)])
m_r32 := Map[r32, int]{}
m_r32[r32(7)] = 6
t.eq(6, m_r32[r32(7)])
m_r64 := Map[r64, int]{}
m_r64[r64(0xffffffffffffffff)] = 7
t.eq(7, m_r64[~r64(0)])

-- bool, symbol, error and f32 keys.
m_bool := Map[bool, int]{}
m_bool[true] = 1
m_bool[false] = 2
t.eq(1, m_bool[true])
t.eq(2, m_bool[false])
m_sym := Map[symbol, int]{}
m_sym[symbol.red] = 1
m_sym[symbol.blue] = 2
t.eq(1, m_sym[symbol.red])
t.eq(2, m_sym[symbol.blue])
t.eq(false, m_sym.contains(symbol.green))
m_err := Map[error, int]{}
m_err[error.NotFound] = 1
t.eq(1, m_err[error.NotFound])
t.eq(false, m_err.contains(error.Other))
m_f32 := Map[f32, int]{}
m_f32[f32(1.5)] = 1
t.eq(1, m_f32[f32(1.5)])
t.eq(false, m_f32.contains(f32(2.5)))

-- Expression keys: `(expr)=value` evaluates the key. A name without parentheses is a string key.
k := 'z'
m_expr := Map[str, int]{(k)=1, (k + 'y')=2, k=3}
t.eq(1, m_expr['z'])
t.eq(2, m_expr['zy'])
t.eq(3, m_expr['k'])
m_int_expr := Map[int, str]{(1 + 1)='x', 3='y'}
t.eq('x', m_int_expr[2])
t.eq('y', m_int_expr[3])

--cytest: pass