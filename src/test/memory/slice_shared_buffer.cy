use t 'test'

-- `Slice` ops may return a slice that shares the receiver's buffer. Keeping both must not leak
-- or double free managed elements. Heap strings make a mistake show up as an unreleased refcount.

-- append keeps the receiver.
a := []str{'x' + '0'}
c := a.append('a' + 'b')
t.eq(1, a.len())
t.eq(2, c.len())
t.eq('ab', c[1])

-- A second append from the same receiver copies since the buffer is shared.
d := a.append('c' + 'd')
t.eq('ab', c[1])
t.eq('cd', d[1])

-- The receiver reuses its buffer after the result that shared it is gone.
e := []str{'x' + '1'}
begin:
    f := e.append('e' + 'f')
    t.eq('ef', f[1])
e = e.append('g' + 'h')
t.eq(2, e.len())
t.eq('gh', e[1])

-- `+` is an alias of append.
g := []str{'x' + '2'}
h := g + {'i' + 'j'}
t.eq('ij', h[1])

-- remove, insert, size_down and size_up keep the receiver.
r := []str{'r' + '0', 'r' + '1', 'r' + '2'}
r2 := r.remove(0)
t.eq(2, r2.len())
t.eq('r1', r2[0])

s := []str{'s' + '0', 's' + '1'}
s2 := s.insert(1, 'i' + 'n')
t.eq(3, s2.len())
t.eq('in', s2[1])

u := []str{'u' + '0', 'u' + '1', 'u' + '2'}
u2 := u.size_down(1)
t.eq(1, u2.len())

w := []str{'w' + '0'}
w2 := w.size_up(3, 'p' + 'q')
t.eq(3, w2.len())
t.eq('pq', w2[2])

-- Sub-slices of a slice that later grows in place.
v := []str{'v' + '0', 'v' + '1'}
sub := v[0..1]
v = v.append('v' + '2')
t.eq('v0', sub[0])
t.eq(3, v.len())

--cytest: pass
