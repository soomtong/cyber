use test

-- `Object.to_string()` reads the boxed value by its runtime type.
-- The call does not consume the box: the Object is used again after each call.

type Foo:
    a int

-- bool.
test.eq(Object(^true).to_string(), 'true')
test.eq(Object(^false).to_string(), 'false')

-- Raw integers print as hex.
test.eq(Object(^(as[r8] 200)).to_string(), '0xc8')
test.eq(Object(^(as[r16] 60000)).to_string(), '0xea60')
test.eq(Object(^(as[r32] 4000000000)).to_string(), '0xee6b2800')
test.eq(Object(^(as[r64] 123)).to_string(), '0x7b')

-- Signed integers keep their sign at every width.
test.eq(Object(^(as[i8] -5)).to_string(), '-5')
test.eq(Object(^(as[i16] -300)).to_string(), '-300')
test.eq(Object(^(as[i32] -70000)).to_string(), '-70000')
test.eq(Object(^1).to_string(), '1')
test.eq(Object(^-9).to_string(), '-9')

-- A float always has a decimal point.
test.eq(Object(^3.0).to_string(), '3.0')
test.eq(Object(^float(3)).to_string(), '3.0')
test.eq(Object(^1.5).to_string(), '1.5')

-- error and symbol.
test.eq(Object(^error.Boom).to_string(), 'error.Boom')
test.eq(Object(^symbol.red).to_string(), 'symbol.red')

-- str, a literal and a heap string.
test.eq(Object(^'abc').to_string(), 'abc')
test.eq(Object(^('ab' + 'cd')).to_string(), 'abcd')

-- Any other type.
test.eq(Object(^Foo{a=1}).to_string(), 'Object')

-- The Object stays valid after the call.
o := Object(^3.0)
s := o.to_string()
test.eq(s, '3.0')
test.eq(o.to_string(), '3.0')
test.eq(o.downcast(^float).*, 3.0)
test.eq('%{o.to_string()}!', '3.0!')

t := Object(^('ab' + 'cd'))
test.eq(t.to_string(), 'abcd')
u := t
test.eq(u.to_string(), 'abcd')
test.eq(t.downcast(^str).*, 'abcd')

-- The reference that was boxed stays valid.
r := ^7
b := Object(r)
test.eq(b.to_string(), '7')
test.eq(r.*, 7)

--cytest: pass
