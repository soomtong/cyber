use t 'test'

-- Op assign to variable.
a := 1
a += 10
t.eq(a, 11)

a = 100
a *= 2
t.eq(a, 200)
a /= 4
t.eq(a, 50)
a -= 1
t.eq(a, 49)

-- Op assign to field.
type S:
    foo int
s := S{foo=1}
s.foo += 10
t.eq(s.foo, 11)

-- Op assign to index.
b := []int{1}
b[0] += 1
t.eq(b[0], 2)

-- Op assign through a reference changes the value it points to.
out := ^[]str{}
out.* += 'x'
out.* += 'y'
t.eq(out.len(), 2)
t.eq(out[1], 'y')

--cytest: pass