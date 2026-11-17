use t 'test'

-- Values of `Slice` can share a buffer (`ys := xs`, a sub-slice). The ops that resize in place copy the
-- buffer first when another value holds it, and the ops that return a new list always copy. Keeping both
-- values must not leak or double free managed elements. Heap strings make a mistake show up as an
-- unreleased refcount.

-- appended leaves the receiver as it was.
a := []str{'x' + '0'}
c := a.appended('a' + 'b')
t.eq(1, a.len())
t.eq(2, c.len())
t.eq('ab', c[1])

-- A second appended from the same receiver does not overwrite the first result.
d := a.appended('c' + 'd')
t.eq('ab', c[1])
t.eq('cd', d[1])

-- append on a copy that shares the buffer copies first, so the other value keeps its elements.
e := []str{'x' + '1'}
f := e
e.append('e' + 'f')
f.append('g' + 'h')
t.eq('ef', e[1])
t.eq('gh', f[1])
t.eq(2, e.len())
t.eq(2, f.len())

-- The value reuses its buffer after the copy that shared it is gone.
g := []str{'x' + '2'}
begin:
    h := g
    t.eq(1, h.len())
g.append('i' + 'j')
g.append('k' + 'l')
t.eq('kl', g[2])

-- `+` is an alias of appended and `+=` of append.
p := []str{'x' + '3'}
q := p + {'m' + 'n'}
t.eq(1, p.len())
t.eq('mn', q[1])
p += 'o' + 'p'
t.eq('op', p[1])

-- removed and inserted leave the receiver as it was.
r := []str{'r' + '0', 'r' + '1', 'r' + '2'}
r2 := r.removed(0)
t.eq(3, r.len())
t.eq(2, r2.len())
t.eq('r1', r2[0])

s := []str{'s' + '0', 's' + '1'}
s2 := s.inserted(1, 'i' + 'n')
t.eq(2, s.len())
t.eq(3, s2.len())
t.eq('in', s2[1])

-- remove and insert on a value that shares the buffer copy first.
r3 := r
r.remove(0)
t.eq('r1', r[0])
t.eq('r0', r3[0])
t.eq(3, r3.len())
s3 := s
s.insert(0, 'z' + 'z')
t.eq('zz', s[0])
t.eq('s0', s3[0])

-- size_down on a shared buffer keeps the cut elements alive for the other value. They are destructed
-- once the shorter value owns the buffer again and grows.
u := []str{'u' + '0', 'u' + '1', 'u' + '2'}
begin:
    u2 := u
    u.size_down(1)
    t.eq(1, u.len())
    t.eq('u2', u2[2])
u.append('u' + '9')
t.eq('u9', u[1])
t.eq(2, u.len())

w := []str{'w' + '0'}
w2 := w
w.size_up(3, 'p' + 'q')
t.eq(3, w.len())
t.eq('pq', w[2])
t.eq(1, w2.len())

-- A sub-slice keeps its elements when the slice it came from grows.
v := []str{'v' + '0', 'v' + '1'}
sub := v[0..1]
v.append('v' + '2')
t.eq('v0', sub[0])
t.eq(3, v.len())

-- A sub-slice that grows copies, so the slice it came from keeps its elements.
sub2 := v[0..1]
sub2.append('s' + 'b')
t.eq('v1', v[1])
t.eq('sb', sub2[1])

-- Appending the elements of a copy that shares the buffer. Appending its own span is a borrow error.
x := []str{'a' + '1', 'b' + '2'}
y := x
x.append(y.span())
t.eq(4, x.len())
t.eq('b2', x[3])

--cytest: pass
